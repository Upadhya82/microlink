import json
import uuid
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import func, or_, select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.auth import CurrentUser, get_current_user, require_roles
from app.config import settings
from app.database import get_db
from app.event_bus import publish_event
from app.geo import haversine_km, haversine_m
from app.models import (
    DeliveryAgentProfile,
    Order,
    OrderEvent,
    OrderRejection,
    OrderStatus,
)
from app.schemas import (
    NotifyCustomerRequest,
    NotifyCustomerResponse,
    OrderCreateRequest,
    OrderDetailResponse,
    OrderEventResponse,
    OrderRateRequest,
    OrderRejectRequest,
    OrderRejectResponse,
    OrderResponse,
    OrderStatusUpdateRequest,
)
from app.scoring import estimate_minutes, is_within_geofence, promised_minutes

router = APIRouter(prefix="/delivery/orders", tags=["delivery-orders"])

require_customer = require_roles("user")
require_delivery_agent = require_roles("delivery_agent")
require_admin = require_roles("admin")

# Forward-only status transition graph (SRS "Update Order Status": state machine).
_NEXT_STATUS = {
    OrderStatus.accepted: OrderStatus.picked_up,
    OrderStatus.picked_up: OrderStatus.in_transit,
    OrderStatus.in_transit: OrderStatus.delivered,
}

# An agent may hold only ONE of these at a time (SRS REQ-AGENT-3).
ACTIVE_STATUSES = (OrderStatus.accepted, OrderStatus.picked_up, OrderStatus.in_transit)

_ALREADY_TAKEN = "This order has already been accepted by another agent"
_ONE_AT_A_TIME = "You already have an active delivery. Finish it before accepting another one."


def _now() -> datetime:
    return datetime.now(timezone.utc)


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
    # A malformed id used to crash Postgres (HTTP 500). Treat it as "not found".
    try:
        uuid.UUID(order_id)
    except ValueError:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Order not found")
    order = db.get(Order, order_id)
    if order is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Order not found")
    return order


def _get_agent_profile(db: Session, user_id: str) -> DeliveryAgentProfile | None:
    return (
        db.query(DeliveryAgentProfile)
        .filter(DeliveryAgentProfile.user_id == user_id)
        .first()
    )


def _write_event(
    db: Session,
    order_id: str,
    status_value: str,
    agent_lat: float | None = None,
    agent_lng: float | None = None,
) -> None:
    db.add(
        OrderEvent(
            order_id=order_id, status=status_value, agent_lat=agent_lat, agent_lng=agent_lng
        )
    )


def _agent_position(profile: DeliveryAgentProfile | None) -> tuple[float, float] | None:
    if profile is None or profile.current_lat is None or profile.current_lng is None:
        return None
    return profile.current_lat, profile.current_lng


def _promised_minutes_for(order: Order, profile: DeliveryAgentProfile | None) -> int:
    """How long to promise for this delivery: agent -> shop, then shop -> customer."""
    legs: list[float] = []
    position = _agent_position(profile)
    if order.pickup_lat is not None and order.pickup_lng is not None:
        if position is not None:
            legs.append(haversine_km(position[0], position[1], order.pickup_lat, order.pickup_lng))
        legs.append(
            haversine_km(order.pickup_lat, order.pickup_lng, order.delivery_lat, order.delivery_lng)
        )
    elif position is not None:
        legs.append(haversine_km(position[0], position[1], order.delivery_lat, order.delivery_lng))
    return promised_minutes(
        legs, settings.average_speed_kmh, settings.eta_buffer_minutes, settings.default_trip_minutes
    )


# ------------------------------------------------------------------ create


@router.post("", response_model=OrderResponse, status_code=status.HTTP_201_CREATED)
async def create_order(
    payload: OrderCreateRequest,
    current_user: CurrentUser = Depends(require_customer),
    db: Session = Depends(get_db),
):
    """SRS REQ-DELIV-1/2/4: a customer requests delivery assistance."""
    # SRS 6.2: block people who keep cancelling.
    since = _now() - timedelta(hours=24)
    recent_cancellations = (
        db.query(func.count(Order.id))
        .filter(
            Order.customer_id == current_user.id,
            Order.status == OrderStatus.cancelled,
            Order.updated_at >= since,
        )
        .scalar()
    )
    if recent_cancellations >= settings.max_cancellations_per_day:
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="You have cancelled too many requests today. Please try again tomorrow.",
        )

    order = Order(
        customer_id=current_user.id,
        shop_id=payload.shop_id,
        agent_id=None,
        items=json.dumps(payload.items),
        pickup_address=payload.pickup_address,
        pickup_lat=payload.pickup_lat,
        pickup_lng=payload.pickup_lng,
        delivery_address=payload.delivery_address,
        delivery_lat=payload.delivery_lat,
        delivery_lng=payload.delivery_lng,
        item_description=payload.item_description,
        status=OrderStatus.pending,
        total_amount=payload.total_amount,
    )
    db.add(order)
    db.flush()
    _write_event(db, order.id, OrderStatus.pending.value)
    db.commit()
    db.refresh(order)

    await publish_event(
        "order.created",
        {
            "order_id": order.id,
            "customer_id": order.customer_id,
            "shop_id": order.shop_id,
            "offered_fee": order.total_amount,
            "pickup_lat": order.pickup_lat,
            "pickup_lng": order.pickup_lng,
            "delivery_lat": order.delivery_lat,
            "delivery_lng": order.delivery_lng,
        },
    )
    return OrderResponse.from_model(order)


# -------------------------------------------------------------------- list


@router.get("", response_model=list[OrderResponse])
async def list_all_orders(
    status_filter: OrderStatus | None = Query(default=None, alias="status"),
    limit: int = Query(default=100, ge=1, le=500),
    current_user: CurrentUser = Depends(require_admin),
    db: Session = Depends(get_db),
):
    """Admin oversight: every delivery request, newest first."""
    query = db.query(Order)
    if status_filter is not None:
        query = query.filter(Order.status == status_filter)
    orders = query.order_by(Order.created_at.desc()).limit(limit).all()
    return [OrderResponse.from_model(order) for order in orders]


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
    """SRS "View Available Orders" / REQ-AGENT-2: pending requests inside the
    agent's radius, nearest first, with the distance to the pickup point."""
    _require_verified_agent(current_user)

    profile = _get_agent_profile(db, current_user.id)
    # SRS pre-condition: the agent must have toggled their status to Online.
    if profile is not None and not profile.is_available:
        return []

    now = _now()
    hidden_from_me = select(OrderRejection.order_id).where(
        OrderRejection.agent_id == current_user.id,
        or_(OrderRejection.hidden_until.is_(None), OrderRejection.hidden_until > now),
    )
    orders = (
        db.query(Order)
        .filter(
            Order.status == OrderStatus.pending,
            Order.agent_id.is_(None),
            Order.id.not_in(hidden_from_me),
        )
        .all()
    )

    position = _agent_position(profile)
    rows: list[tuple[float | None, Order]] = []
    for order in orders:
        distance = None
        if position is not None:
            # Distance to where the agent must go first: the pickup point.
            if order.pickup_lat is not None and order.pickup_lng is not None:
                target = (order.pickup_lat, order.pickup_lng)
            else:
                target = (order.delivery_lat, order.delivery_lng)
            distance = haversine_km(position[0], position[1], target[0], target[1])
            if distance > settings.agent_service_radius_km:
                continue
        rows.append((distance, order))

    if position is not None:
        rows.sort(key=lambda row: row[0])
    else:
        rows.sort(key=lambda row: row[1].created_at, reverse=True)

    responses = []
    for distance, order in rows:
        response = OrderResponse.from_model(order)
        response.distance_km = round(distance, 2) if distance is not None else None
        responses.append(response)
    return responses


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

    response = OrderDetailResponse.from_model(order)
    response.events = [OrderEventResponse.model_validate(e) for e in events]
    return response


# ------------------------------------------------- accept / reject (agent)


@router.patch("/{order_id}/accept", response_model=OrderResponse)
async def accept_order(
    order_id: str,
    current_user: CurrentUser = Depends(require_delivery_agent),
    db: Session = Depends(get_db),
):
    """SRS "Accept / Reject Order" + REQ-AGENT-3.

    Two agents can tap Accept at the same instant, so "read the order, check it
    is free, then write" is NOT safe. We do the check and the write in ONE SQL
    statement (UPDATE ... WHERE status = pending AND agent_id IS NULL) and look
    at how many rows changed: 0 rows means somebody else won (HTTP 409)."""
    _require_verified_agent(current_user)

    order = _get_order_or_404(db, order_id)
    if order.status != OrderStatus.pending or order.agent_id is not None:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=_ALREADY_TAKEN)

    already_busy = (
        db.query(Order.id)
        .filter(Order.agent_id == current_user.id, Order.status.in_(ACTIVE_STATUSES))
        .first()
    )
    if already_busy is not None:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=_ONE_AT_A_TIME)

    profile = _get_agent_profile(db, current_user.id)
    now = _now()
    promised_by = now + timedelta(minutes=_promised_minutes_for(order, profile))
    position = _agent_position(profile)

    try:
        result = db.execute(
            update(Order)
            .where(
                Order.id == order.id,
                Order.status == OrderStatus.pending,
                Order.agent_id.is_(None),
            )
            .values(
                agent_id=current_user.id,
                status=OrderStatus.accepted,
                accepted_at=now,
                promised_by=promised_by,
            )
            .execution_options(synchronize_session=False)
        )
        if result.rowcount != 1:
            db.rollback()
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=_ALREADY_TAKEN)
        _write_event(
            db,
            order.id,
            OrderStatus.accepted.value,
            position[0] if position else None,
            position[1] if position else None,
        )
        db.commit()
    except IntegrityError:
        # The database's "one active order per agent" index fired.
        db.rollback()
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=_ONE_AT_A_TIME)

    db.refresh(order)
    await publish_event("order.accepted", {"order_id": order.id, "agent_id": order.agent_id})
    return OrderResponse.from_model(order)


@router.post("/{order_id}/reject", response_model=OrderRejectResponse)
async def reject_order(
    order_id: str,
    payload: OrderRejectRequest | None = None,
    current_user: CurrentUser = Depends(require_delivery_agent),
    db: Session = Depends(get_db),
):
    """SRS "Accept / Reject Order": Reject, or the 30-second timer expiring,
    removes the offer from THIS agent's list so it reaches the next agent."""
    _require_verified_agent(current_user)
    payload = payload or OrderRejectRequest()

    order = _get_order_or_404(db, order_id)
    if order.status != OrderStatus.pending or order.agent_id is not None:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=_ALREADY_TAKEN)

    hidden_until = None
    if payload.reason == "timeout":
        hidden_until = _now() + timedelta(minutes=settings.reject_timeout_hide_minutes)

    rejection = (
        db.query(OrderRejection)
        .filter(OrderRejection.order_id == order.id, OrderRejection.agent_id == current_user.id)
        .first()
    )
    if rejection is None:
        rejection = OrderRejection(order_id=order.id, agent_id=current_user.id)
        db.add(rejection)
    rejection.reason = payload.reason
    rejection.hidden_until = hidden_until
    db.commit()

    await publish_event(
        "order.rejected",
        {"order_id": order.id, "agent_id": current_user.id, "reason": payload.reason},
    )
    return OrderRejectResponse(
        order_id=order.id, reason=payload.reason, hidden_until=hidden_until
    )


# --------------------------------------------------------- status updates


@router.patch("/{order_id}/status", response_model=OrderResponse)
async def update_order_status(
    order_id: str,
    payload: OrderStatusUpdateRequest,
    current_user: CurrentUser = Depends(require_delivery_agent),
    db: Session = Depends(get_db),
):
    """SRS "Update Order Status": forward-only state machine + geofencing."""
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

    profile = _get_agent_profile(db, current_user.id)
    agent_lat, agent_lng = payload.lat, payload.lng
    if agent_lat is None:
        position = _agent_position(profile)
        if position is not None:
            agent_lat, agent_lng = position

    # Geofencing: confirm pickup only AT the shop, confirm delivery only AT the
    # customer. If we cannot know where somebody is, we cannot check, so we skip.
    if settings.geofence_enabled and new_status in (OrderStatus.picked_up, OrderStatus.delivered):
        if new_status == OrderStatus.picked_up:
            target_lat, target_lng = order.pickup_lat, order.pickup_lng
            place = "the shop (pickup point)"
        else:
            target_lat, target_lng = order.delivery_lat, order.delivery_lng
            place = "the customer's address"
        inside = is_within_geofence(
            agent_lat, agent_lng, target_lat, target_lng, settings.geofence_radius_m
        )
        if inside is False:
            metres = round(haversine_m(agent_lat, agent_lng, target_lat, target_lng))
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=(
                    f"You are about {metres} m from {place}. "
                    f"Move within {round(settings.geofence_radius_m)} m to confirm."
                ),
            )

    now = _now()
    order.status = new_status
    if new_status == OrderStatus.picked_up:
        order.picked_up_at = now
    if new_status == OrderStatus.delivered:
        order.delivered_at = now
    _write_event(db, order.id, new_status.value, agent_lat, agent_lng)

    if new_status == OrderStatus.delivered and profile is not None:
        profile.total_deliveries += 1
        # Old rows without a promise time count as on time.
        if order.promised_by is None or now <= order.promised_by:
            profile.on_time_deliveries += 1

    db.commit()
    db.refresh(order)

    await publish_event(
        "order.status_changed", {"order_id": order.id, "status": order.status.value}
    )
    if new_status == OrderStatus.delivered:
        await publish_event("order.delivered", {"order_id": order.id})

    return OrderResponse.from_model(order)


@router.post("/{order_id}/notify-customer", response_model=NotifyCustomerResponse)
async def notify_customer(
    order_id: str,
    payload: NotifyCustomerRequest | None = None,
    current_user: CurrentUser = Depends(require_delivery_agent),
    db: Session = Depends(get_db),
):
    """SRS REQ-AGENT-4: the "Notify Customer" button. Works out an ETA from the
    agent's GPS to the delivery address, saves it on the order (the customer's
    tracking screen shows it) and publishes `order.agent_notified` so a future
    push-notification service can send it to the phone."""
    payload = payload or NotifyCustomerRequest()
    order = _get_order_or_404(db, order_id)

    if order.agent_id != current_user.id:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Only the assigned agent may notify the customer",
        )
    if order.status not in ACTIVE_STATUSES:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="You can only notify the customer while the delivery is in progress",
        )

    profile = _get_agent_profile(db, current_user.id)
    if payload.lat is not None and profile is not None:
        profile.current_lat, profile.current_lng = payload.lat, payload.lng
    position = (
        (payload.lat, payload.lng) if payload.lat is not None else _agent_position(profile)
    )
    if position is None:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Share your location first so the ETA can be calculated",
        )

    distance_km = haversine_km(position[0], position[1], order.delivery_lat, order.delivery_lng)
    eta = estimate_minutes(distance_km, settings.average_speed_kmh)
    message = f"Your delivery agent is on the way! ETA: {eta} minute{'s' if eta != 1 else ''}."

    order.agent_eta_minutes = eta
    order.agent_notified_at = _now()
    db.commit()

    await publish_event(
        "order.agent_notified",
        {
            "order_id": order.id,
            "customer_id": order.customer_id,
            "agent_id": current_user.id,
            "eta_minutes": eta,
            "message": message,
        },
    )
    return NotifyCustomerResponse(order_id=order.id, eta_minutes=eta, message=message)


# ------------------------------------------------------ cancel and rating


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
    _write_event(db, order.id, OrderStatus.cancelled.value)
    db.commit()
    db.refresh(order)

    await publish_event("order.cancelled", {"order_id": order.id})
    return OrderResponse.from_model(order)


@router.post("/{order_id}/rate", response_model=OrderResponse)
async def rate_order(
    order_id: str,
    payload: OrderRateRequest,
    current_user: CurrentUser = Depends(require_customer),
    db: Session = Depends(get_db),
):
    """SRS 5.6.2 / REQ-AGENT-5: after delivery the customer rates the agent
    (one rating per order). This is what feeds the agent's average rating."""
    order = _get_order_or_404(db, order_id)

    if order.customer_id != current_user.id:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN, detail="You can only rate your own orders"
        )
    if order.status != OrderStatus.delivered or order.agent_id is None:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="You can rate an order once it has been delivered",
        )
    if order.rating is not None:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT, detail="This order has already been rated"
        )

    order.rating = payload.rating
    order.rating_comment = payload.comment
    order.rated_at = _now()

    profile = (
        db.query(DeliveryAgentProfile)
        .filter(DeliveryAgentProfile.user_id == order.agent_id)
        .with_for_update()
        .first()
    )
    if profile is not None:
        total = profile.rating_avg * profile.rating_count + payload.rating
        profile.rating_count += 1
        profile.rating_avg = round(total / profile.rating_count, 2)

    db.commit()
    db.refresh(order)

    await publish_event(
        "order.rated",
        {"order_id": order.id, "agent_id": order.agent_id, "rating": payload.rating},
    )
    return OrderResponse.from_model(order)
