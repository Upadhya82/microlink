import json

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session

from app.auth import CurrentUser, get_current_user, require_roles
from app.database import get_db
from app.event_bus import publish_event
from app.geo import haversine_km
from app.models import DeliveryAgentProfile, Order, OrderEvent, OrderStatus
from app.schemas import (
    OrderCreateRequest,
    OrderDetailResponse,
    OrderEventResponse,
    OrderResponse,
    OrderStatusUpdateRequest,
)

router = APIRouter(prefix="/delivery/orders", tags=["delivery-orders"])

require_customer = require_roles("user")
require_delivery_agent = require_roles("delivery_agent")

# Forward-only status transition graph.
_NEXT_STATUS = {
    OrderStatus.accepted: OrderStatus.picked_up,
    OrderStatus.picked_up: OrderStatus.in_transit,
    OrderStatus.in_transit: OrderStatus.delivered,
}


def _require_verified_agent(current_user: CurrentUser) -> None:
    if not current_user.is_verified:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail=(
                "Your delivery agent account must be verified by an admin "
                "before you can accept deliveries"
            ),
        )


def _get_order_or_404(db: Session, order_id: str) -> Order:
    order = db.get(Order, order_id)
    if order is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Order not found")
    return order


def _write_event(db: Session, order_id: str, status_value: str) -> None:
    db.add(OrderEvent(order_id=order_id, status=status_value))


@router.post("", response_model=OrderResponse, status_code=status.HTTP_201_CREATED)
async def create_order(
    payload: OrderCreateRequest,
    current_user: CurrentUser = Depends(require_customer),
    db: Session = Depends(get_db),
):
    order = Order(
        customer_id=current_user.id,
        shop_id=payload.shop_id,
        agent_id=None,
        items=json.dumps(payload.items),
        delivery_address=payload.delivery_address,
        delivery_lat=payload.delivery_lat,
        delivery_lng=payload.delivery_lng,
        status=OrderStatus.pending,
        total_amount=payload.total_amount,
    )
    db.add(order)
    db.commit()
    db.refresh(order)

    _write_event(db, order.id, OrderStatus.pending.value)
    db.commit()

    await publish_event(
        "order.created",
        {
            "order_id": order.id,
            "customer_id": order.customer_id,
            "shop_id": order.shop_id,
            "total_amount": order.total_amount,
        },
    )
    return OrderResponse.from_model(order)


@router.get("/me", response_model=list[OrderResponse])
async def list_my_orders(
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    query = db.query(Order)
    if current_user.role == "delivery_agent":
        query = query.filter(Order.agent_id == current_user.id)
    else:
        query = query.filter(Order.customer_id == current_user.id)

    orders = query.order_by(Order.created_at.desc()).all()
    return [OrderResponse.from_model(order) for order in orders]


@router.get("/available", response_model=list[OrderResponse])
async def list_available_orders(
    current_user: CurrentUser = Depends(require_delivery_agent),
    db: Session = Depends(get_db),
):
    _require_verified_agent(current_user)

    orders = (
        db.query(Order)
        .filter(Order.status == OrderStatus.pending, Order.agent_id.is_(None))
        .all()
    )

    profile = (
        db.query(DeliveryAgentProfile)
        .filter(DeliveryAgentProfile.user_id == current_user.id)
        .first()
    )

    if profile is not None and profile.current_lat is not None and profile.current_lng is not None:
        orders.sort(
            key=lambda o: haversine_km(
                profile.current_lat, profile.current_lng, o.delivery_lat, o.delivery_lng
            )
        )
    else:
        orders.sort(key=lambda o: o.created_at, reverse=True)

    return [OrderResponse.from_model(order) for order in orders]


@router.get("/{order_id}", response_model=OrderDetailResponse)
async def get_order(
    order_id: str,
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    order = _get_order_or_404(db, order_id)

    if (
        current_user.role != "admin"
        and current_user.id != order.customer_id
        and current_user.id != order.agent_id
    ):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="You do not have permission to view this order",
        )

    events = (
        db.query(OrderEvent)
        .filter(OrderEvent.order_id == order_id)
        .order_by(OrderEvent.created_at.asc())
        .all()
    )

    response = OrderDetailResponse.model_validate(order)
    response.events = [OrderEventResponse.model_validate(e) for e in events]
    return response


@router.patch("/{order_id}/accept", response_model=OrderResponse)
async def accept_order(
    order_id: str,
    current_user: CurrentUser = Depends(require_delivery_agent),
    db: Session = Depends(get_db),
):
    _require_verified_agent(current_user)

    order = _get_order_or_404(db, order_id)
    if order.status != OrderStatus.pending or order.agent_id is not None:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="This order has already been accepted by another agent",
        )

    order.agent_id = current_user.id
    order.status = OrderStatus.accepted
    db.commit()
    db.refresh(order)

    _write_event(db, order.id, OrderStatus.accepted.value)
    db.commit()

    await publish_event(
        "order.accepted", {"order_id": order.id, "agent_id": order.agent_id}
    )
    return OrderResponse.from_model(order)


@router.patch("/{order_id}/status", response_model=OrderResponse)
async def update_order_status(
    order_id: str,
    payload: OrderStatusUpdateRequest,
    current_user: CurrentUser = Depends(require_delivery_agent),
    db: Session = Depends(get_db),
):
    order = _get_order_or_404(db, order_id)

    if order.agent_id != current_user.id:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Only the assigned agent may update this order's status",
        )

    new_status = OrderStatus(payload.status)
    expected_next = _NEXT_STATUS.get(order.status)
    if new_status != expected_next:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=(
                f"Cannot transition order from '{order.status.value}' to "
                f"'{new_status.value}'"
            ),
        )

    order.status = new_status
    db.commit()
    db.refresh(order)

    _write_event(db, order.id, new_status.value)
    db.commit()

    if new_status == OrderStatus.delivered:
        profile = (
            db.query(DeliveryAgentProfile)
            .filter(DeliveryAgentProfile.user_id == current_user.id)
            .first()
        )
        if profile is not None:
            profile.total_deliveries += 1
            db.commit()

    await publish_event(
        "order.status_changed", {"order_id": order.id, "status": order.status.value}
    )
    if new_status == OrderStatus.delivered:
        await publish_event("order.delivered", {"order_id": order.id})

    return OrderResponse.from_model(order)


@router.patch("/{order_id}/cancel", response_model=OrderResponse)
async def cancel_order(
    order_id: str,
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    order = _get_order_or_404(db, order_id)

    if current_user.role != "admin" and current_user.id != order.customer_id:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="You do not have permission to cancel this order",
        )

    if order.status not in (OrderStatus.pending, OrderStatus.accepted):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Cannot cancel an order already in transit or delivered",
        )

    order.status = OrderStatus.cancelled
    db.commit()
    db.refresh(order)

    _write_event(db, order.id, OrderStatus.cancelled.value)
    db.commit()

    await publish_event("order.cancelled", {"order_id": order.id})
    return OrderResponse.from_model(order)
