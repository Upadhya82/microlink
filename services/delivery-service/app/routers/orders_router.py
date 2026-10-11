import json
import secrets

import httpx

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session

from app.auth import CurrentUser, get_current_user, require_roles
from app.config import settings
from app.database import get_db
from app.event_bus import notify_users, publish_event
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


def _new_code() -> str:
    """A 4-digit handover code.

    secrets, not random: these authorise a state change, so they must not be
    predictable from another order's code. 4 digits is the length people
    will actually read over a counter, and guessing is not a real threat
    because the code only works for one specific order that the guesser
    would already have to be assigned to.
    """
    return f"{secrets.randbelow(10000):04d}"


def _new_code_pair() -> tuple[str, str]:
    """Pickup and delivery codes that are guaranteed to differ.

    Two independent draws collide once in ten thousand orders, and on those
    orders the code the shop owner reads out would also close the delivery
    -- the agent could mark the parcel delivered without ever meeting the
    customer. Cheap to rule out, so it is ruled out.
    """
    pickup = _new_code()
    delivery = _new_code()
    while delivery == pickup:
        delivery = _new_code()
    return pickup, delivery


# Status -> what the customer is told when the agent moves the order along.
_STATUS_MESSAGES: dict[str, tuple[str, str]] = {
    "picked_up": ("Your order has been picked up", "The agent has collected your order from the shop."),
    "in_transit": ("Your order is on the way", "Your delivery agent is heading to your drop-off point."),
    "delivered": ("Your order has been delivered", "Enjoy! Tap to rate your delivery."),
}


def _nearby_available_agents(db: Session, lat: float, lng: float) -> list[str]:
    """Agents to tell about a new order (REQ-DELIV-4).

    Available, approved agents within `agent_service_radius_km` of the
    pickup. Agents whose location we do not know yet are *included* rather
    than excluded: not having sent a GPS ping is not evidence of being far
    away, and silently skipping them would starve new agents of work.
    """
    profiles = (
        db.query(DeliveryAgentProfile)
        .filter(DeliveryAgentProfile.is_available.is_(True))
        .all()
    )
    radius = settings.agent_service_radius_km
    targets: list[str] = []
    for profile in profiles:
        if profile.current_lat is None or profile.current_lng is None:
            targets.append(profile.user_id)
            continue
        if haversine_km(lat, lng, profile.current_lat, profile.current_lng) <= radius:
            targets.append(profile.user_id)
    return targets


@router.post("", response_model=OrderResponse, status_code=status.HTTP_201_CREATED)
async def create_order(
    payload: OrderCreateRequest,
    current_user: CurrentUser = Depends(require_customer),
    db: Session = Depends(get_db),
):
    _pickup_code, _delivery_code = _new_code_pair()
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
        pickup_code=_pickup_code,
        delivery_code=_delivery_code,
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
    # REQ-DELIV-4: without this the order sits in a list nobody is watching.
    await notify_users(
        _nearby_available_agents(db, order.delivery_lat, order.delivery_lng),
        "New delivery request nearby",
        f"A customer needs a delivery to {order.delivery_address}.",
        kind="delivery_request",
        link={"route": "driver_home"},
    )
    return OrderResponse.from_model(order, viewer_id=current_user.id, viewer_role=current_user.role)


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
    return [
        OrderResponse.from_model(order, viewer_id=current_user.id, viewer_role=current_user.role)
        for order in orders
    ]


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

    return [
        OrderResponse.from_model(order, viewer_id=current_user.id, viewer_role=current_user.role)
        for order in orders
    ]


@router.get("/{order_id}", response_model=OrderDetailResponse)
async def get_order(
    order_id: str,
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    order = _get_order_or_404(db, order_id)

    # The shop owner needs this screen too: it is where they read the pickup
    # code to the agent at the counter.
    is_shop_owner = False
    if current_user.role == "shop_owner":
        is_shop_owner = await _owns_shop(order.shop_id, current_user.id)

    if (
        current_user.role != "admin"
        and current_user.id != order.customer_id
        and current_user.id != order.agent_id
        and not is_shop_owner
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

    # from_model, not model_validate: validating the row straight into the
    # response handed both handover codes to whoever asked, the agent
    # included, which defeats the point of having two codes.
    response = OrderDetailResponse.from_model(
        order,
        viewer_id=current_user.id,
        viewer_role=current_user.role,
        is_shop_owner=is_shop_owner,
    )
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

    await notify_users(
        [order.customer_id],
        "A delivery agent accepted your order",
        "Your order has been picked up by an agent and is being prepared for delivery.",
        kind="order",
        link={"route": "order", "id": order.id},
    )
    await publish_event(
        "order.accepted", {"order_id": order.id, "agent_id": order.agent_id}
    )
    return OrderResponse.from_model(order, viewer_id=current_user.id, viewer_role=current_user.role)


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

    # The two handovers must be proved, not just asserted.
    required_code = {
        OrderStatus.picked_up: order.pickup_code,
        OrderStatus.delivered: order.delivery_code,
    }.get(new_status)
    if required_code is not None:
        supplied = (payload.code or "").strip()
        if not supplied:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=(
                    "Ask the shop owner for the pickup code."
                    if new_status == OrderStatus.picked_up
                    else "Ask the customer for the delivery code."
                ),
            )
        # compare_digest: constant time, so a wrong code cannot be narrowed
        # down by timing how long the rejection took.
        if not secrets.compare_digest(supplied, required_code):
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="That code does not match. Please check and try again.",
            )

    order.status = new_status
    db.commit()
    db.refresh(order)

    _write_event(db, order.id, new_status.value)
    db.commit()

    # Confirming the pickup code means the agent is holding the parcel at the
    # shop, so the trip has started. Recording in_transit here saves a button
    # that only ever said what had already happened.
    auto_transit = False
    if new_status == OrderStatus.picked_up:
        order.status = OrderStatus.in_transit
        db.commit()
        db.refresh(order)
        _write_event(db, order.id, OrderStatus.in_transit.value)
        db.commit()
        auto_transit = True

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
    message = _STATUS_MESSAGES.get(new_status.value)
    if message is not None:
        await notify_users(
            [order.customer_id],
            message[0],
            message[1],
            kind="order",
            link={"route": "order", "id": order.id},
        )
    if auto_transit:
        transit = _STATUS_MESSAGES.get(OrderStatus.in_transit.value)
        if transit is not None:
            await notify_users(
                [order.customer_id],
                transit[0],
                transit[1],
                kind="order",
                link={"route": "order", "id": order.id},
            )
        await publish_event(
            "order.status_changed",
            {"order_id": order.id, "status": OrderStatus.in_transit.value},
        )
    if new_status == OrderStatus.delivered:
        await publish_event(
            "order.delivered",
            {"order_id": order.id, "total_amount": order.total_amount},
        )
        # The shop owner handed the parcel over at the counter and hears
        # nothing more about it otherwise; this closes the loop for them.
        owner_id = await _shop_owner_id(order.shop_id)
        if owner_id is not None:
            await notify_users(
                [owner_id],
                "Parcel received",
                "The customer has received the parcel for order "
                f"{order.id[:8]}.",
                kind="order",
                link={"route": "order", "id": order.id},
            )

    return OrderResponse.from_model(order, viewer_id=current_user.id, viewer_role=current_user.role)


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
    if order.agent_id:
        await notify_users(
            [order.agent_id],
            "A delivery was cancelled",
            f"The customer cancelled the delivery to {order.delivery_address}.",
            kind="order",
            link={"route": "driver_home"},
        )
    return OrderResponse.from_model(order, viewer_id=current_user.id, viewer_role=current_user.role)


async def _shop_owner_id(shop_id: str) -> str | None:
    """Who owns this shop, for notifying them about their own orders.

    Returns None on any failure: a missed notification is a far smaller
    problem than a request that fails because shop-service is busy.
    """
    try:
        async with httpx.AsyncClient(timeout=4.0) as client:
            response = await client.get(f"{settings.shop_service_url}/shops/{shop_id}")
            if response.status_code != 200:
                return None
            return response.json().get("owner_id")
    except Exception:
        return None


async def _owns_shop(shop_id: str, user_id: str) -> bool:
    """Ask shop-service whether this user owns that shop.

    Returns False on any failure, so an unreachable shop-service denies
    access rather than handing out pickup codes to whoever asks.
    """
    try:
        async with httpx.AsyncClient(timeout=4.0) as client:
            response = await client.get(f"{settings.shop_service_url}/shops/{shop_id}")
            if response.status_code != 200:
                return False
            return response.json().get("owner_id") == user_id
    except Exception:
        return False


@router.get("/shop/{shop_id}", response_model=list[OrderResponse])
async def list_shop_orders(
    shop_id: str,
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Orders placed with a shop, for its owner -- including the pickup code
    they read out to the collecting agent."""
    is_admin = current_user.role == "admin"
    if not is_admin and not await _owns_shop(shop_id, current_user.id):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="You can only view orders for your own shop.",
        )
    orders = (
        db.query(Order)
        .filter(Order.shop_id == shop_id)
        .order_by(Order.created_at.desc())
        .all()
    )
    return [
        OrderResponse.from_model(
            order,
            viewer_id=current_user.id,
            viewer_role=current_user.role,
            is_shop_owner=True,
        )
        for order in orders
    ]
