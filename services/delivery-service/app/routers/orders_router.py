import json
import secrets

import httpx
import uuid
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import func, or_, select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app import stock
from app.auth import CurrentUser, get_current_user, require_roles
from app.config import settings
from app.database import get_db
from app.event_bus import notify_users, publish_event
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
    OrderCancelRequest,
    OrderCreateRequest,
    OrderDetailResponse,
    OrderEventResponse,
    OrderRateRequest,
    OrderRejectRequest,
    OrderRejectResponse,
    OrderReleaseRequest,
    OrderReleaseResponse,
    OrderResponse,
    OrderStatusUpdateRequest,
)
from app.scoring import estimate_minutes, is_within_geofence, promised_minutes

router = APIRouter(prefix="/delivery/orders", tags=["delivery-orders"])

# Item 8: who ended an order. Only CANCELLED_BY_CUSTOMER counts towards the
# customer's daily limit; only CANCELLED_BY_SHOP counts towards a shop's
# cancellation streak.
CANCELLED_BY_CUSTOMER = "customer"
CANCELLED_BY_SHOP = "shop"
CANCELLED_BY_ADMIN = "admin"
# The agent gave up a delivery they had already collected. Counts towards
# neither the customer's limit nor the shop's streak -- neither of them did
# anything -- but it does alert the admins, because the parcel is in limbo.
CANCELLED_BY_AGENT = "agent"

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

# An offer can go away for reasons that have nothing to do with another
# agent, and "somebody else took it" is simply untrue when the customer
# cancelled -- the agent goes looking for a job that no longer exists
# instead of moving on. Only the states an agent can actually arrive at are
# listed; anything else really is another agent holding it.
_NOT_OFFERABLE = {
    OrderStatus.cancelled: "This order was cancelled and is no longer on offer.",
    OrderStatus.delivered: "This order has already been delivered.",
}


def _offer_refusal(order: Order) -> str:
    """Why this offer is no longer open, in the agent's own terms."""
    return _NOT_OFFERABLE.get(order.status, _ALREADY_TAKEN)


# An agent can give up a delivery at either stage, but the two are not the
# same thing. Before pickup nothing has moved, so the order simply goes back
# on offer. After pickup the agent is holding the customer's goods: the
# delivery has to end, and the shop and the admins have to hear that a parcel
# is coming back, or it just disappears with whoever was carrying it.
_RELEASABLE = (OrderStatus.accepted, OrderStatus.picked_up, OrderStatus.in_transit)
_NOT_RELEASABLE = {
    OrderStatus.pending: "This order has no agent assigned, so there is nothing to give up.",
    OrderStatus.delivered: "This order has already been delivered.",
    OrderStatus.cancelled: "This order was cancelled.",
}


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


async def fetch_shop(shop_id: str) -> dict | None:
    """The shop's public record, or None when shop-service cannot answer.

    None covers every way that can go wrong -- the service being down, the
    shop not existing, a bad response -- because every caller here treats
    them the same: carry on without it rather than fail the request.
    """
    try:
        async with httpx.AsyncClient(timeout=4.0) as client:
            response = await client.get(f"{settings.shop_service_url}/shops/{shop_id}")
            if response.status_code != 200:
                return None
            return response.json()
    except Exception:
        return None


def pickup_from(
    shop: dict | None,
    lat: float | None,
    lng: float | None,
    address: str | None,
) -> tuple[float | None, float | None, str | None]:
    """Where the agent collects the order, given what the caller sent.

    A point the caller did send (Request Delivery lets the customer move it)
    is kept; otherwise it is the shop's own. No shop, or a shop with no
    coordinates, leaves the order as the caller sent it -- a missing pin is
    far better than a refused order.
    """
    if lat is not None and lng is not None:
        return lat, lng, address
    if shop is None:
        return lat, lng, address
    shop_lat, shop_lng = shop.get("latitude"), shop.get("longitude")
    if not isinstance(shop_lat, (int, float)) or not isinstance(shop_lng, (int, float)):
        return lat, lng, address
    return float(shop_lat), float(shop_lng), address or shop.get("address") or None


async def resolve_pickup(
    shop_id: str,
    lat: float | None,
    lng: float | None,
    address: str | None,
) -> tuple[float | None, float | None, str | None, str | None]:
    """Where the agent collects the order, and what the shop is called.

    Checkout only says where the order is going, so a cart order arrived
    with no pickup point at all: no shop pin on the tracking map and
    nothing for the agent to navigate to. The name rides along on the same
    request because the customer's order list had no way to say which shop
    an order came from -- see `Order.shop_name` for why it is copied onto
    the order rather than looked up each time it is read.

    The shop is therefore asked even when the caller chose their own pickup
    point, which it used not to be: the point is still theirs, but the name
    is wanted either way.
    """
    shop = await fetch_shop(shop_id)
    name = (shop or {}).get("name") or None
    return (*pickup_from(shop, lat, lng, address), name)


async def _owns_shop(shop_id: str, user_id: str) -> bool:
    """Ask shop-service whether this user owns that shop.

    Returns False on any failure, so an unreachable shop-service denies
    access rather than handing out pickup codes to whoever asks.
    """
    return (await fetch_shop(shop_id) or {}).get("owner_id") == user_id


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
    # SRS 6.2: block people who keep cancelling. Item 8: only the
    # customer's OWN cancellations count -- a shop cancelling its orders, or
    # the unclaimed-order sweep, is not the customer's doing and must not
    # lock them out. Orders cancelled before cancelled_by existed are NULL,
    # so they no longer count either.
    since = _now() - timedelta(hours=24)
    recent_cancellations = (
        db.query(func.count(Order.id))
        .filter(
            Order.customer_id == current_user.id,
            Order.status == OrderStatus.cancelled,
            Order.cancelled_by == CANCELLED_BY_CUSTOMER,
            Order.updated_at >= since,
        )
        .scalar()
    )
    if recent_cancellations >= settings.max_cancellations_per_day:
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="You have cancelled too many requests today. Please try again tomorrow.",
        )

    # Item 12: hold the stock BEFORE the order is saved. A shop that cannot
    # fill the order means no order at all, so there is nothing to undo.
    try:
        lines = stock.order_lines(payload.items)
    except stock.InvalidLine as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY, detail=str(exc)
        )

    order_id = str(uuid.uuid4())
    reserved_at = None
    if lines:
        try:
            await stock.reserve(payload.shop_id, order_id, lines)
        except stock.StockShort as exc:
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=exc.detail)
        except stock.StockServiceUnavailable:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="We could not check the shop's stock just now. Please try again.",
            )
        reserved_at = _now()

    pickup_lat, pickup_lng, pickup_address, shop_name = await resolve_pickup(
        payload.shop_id, payload.pickup_lat, payload.pickup_lng, payload.pickup_address
    )
    _pickup_code, _delivery_code = _new_code_pair()
    order = Order(
        id=order_id,
        stock_reserved_at=reserved_at,
        customer_id=current_user.id,
        shop_id=payload.shop_id,
        shop_name=shop_name,
        agent_id=None,
        items=json.dumps(payload.items),
        pickup_address=pickup_address,
        pickup_lat=pickup_lat,
        pickup_lng=pickup_lng,
        delivery_address=payload.delivery_address,
        delivery_lat=payload.delivery_lat,
        delivery_lng=payload.delivery_lng,
        item_description=payload.item_description,
        status=OrderStatus.pending,
        total_amount=payload.total_amount,
        pickup_code=_pickup_code,
        delivery_code=_delivery_code,
    )
    try:
        db.add(order)
        db.flush()
        _write_event(db, order.id, OrderStatus.pending.value)
        db.commit()
    except Exception:
        # The stock is held for an order that does not exist. Hand it back
        # before answering, or those units are lost until the shop notices.
        db.rollback()
        if reserved_at is not None:
            await stock.release(payload.shop_id, order_id)
        raise
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
    # The customer's own orders, so their delivery code travels with them.
    return [
        OrderResponse.from_model(
            order, viewer_id=current_user.id, viewer_role=current_user.role
        )
        for order in orders
    ]


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

    # Passing the viewer matters: without it from_model reveals neither code,
    # and with the wrong one it would reveal both to the agent.
    response = OrderDetailResponse.from_model(
        order,
        viewer_id=current_user.id,
        viewer_role=current_user.role,
        is_shop_owner=is_shop_owner,
    )
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
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=_offer_refusal(order))

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
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=_offer_refusal(order))

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


def _release_refusal(order: Order) -> str:
    """Why this order cannot be given up, in the agent's own terms."""
    return _NOT_RELEASABLE.get(order.status, "This order can no longer be given up.")


async def _announce_agent_dropout(order: Order, reason: str) -> None:
    """Tell everyone that a collected parcel is coming back.

    The customer is waiting for goods that are not coming, the shop is the
    only place the parcel can go, and an admin has to know that stock is
    sitting in a stranger's bag -- so unlike a pre-pickup hand-back, this
    one cannot be quiet.
    """
    short = order.id[:8]
    reason_tail = f" Reason: {reason}" if reason else ""

    await notify_users(
        [order.customer_id],
        "Your delivery could not be completed",
        f"The driver carrying order {short} could not finish the delivery.{reason_tail} "
        "The items are being returned to the shop, and the order has been "
        "cancelled so you can order again.",
        kind="order",
        link={"route": "order", "id": order.id},
    )

    owner_id = await _shop_owner_id(order.shop_id)
    if owner_id:
        await notify_users(
            [owner_id],
            "A parcel is being returned",
            f"The driver for order {short} gave up the delivery after "
            f"collecting it.{reason_tail} Expect the items back at the shop.",
            kind="order",
            link={"route": "order", "id": order.id},
        )

    admins = await _admin_ids()
    if admins:
        await notify_users(
            admins,
            "A driver dropped a collected order",
            f"Order {short} was cancelled by its driver after pickup.{reason_tail} "
            "The items were with the driver and need to be accounted for.",
            kind="order",
            link={"route": "order", "id": order.id},
        )


@router.post("/{order_id}/release", response_model=OrderReleaseResponse)
async def release_order(
    order_id: str,
    payload: OrderReleaseRequest,
    current_user: CurrentUser = Depends(require_delivery_agent),
    db: Session = Depends(get_db),
):
    """The assigned agent gives up a delivery they cannot finish.

    An agent who accepts an order they then cannot do -- the bike breaks
    down, the shop is shut, they are taken ill mid-trip -- used to have no
    way out of it. Because an agent may hold only one active order
    (REQ-AGENT-3), that one stuck order also locked them out of every other
    delivery, with nothing to do but wait for support.

    What happens next depends on whether they have the parcel:

    * Before pickup, nothing has moved. The order goes back on offer, so
      the customer keeps the delivery they asked for and the next agent
      nearby sees it.
    * After pickup, the agent is carrying the customer's goods. The
      delivery cannot be quietly passed on, so the order is cancelled and
      the customer, the shop and the admins are all told the parcel is
      coming back.

    Either way the agent is free to accept their next order.
    """
    _require_verified_agent(current_user)

    order = _get_order_or_404(db, order_id)
    if order.agent_id != current_user.id:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Only the agent assigned to this order can give it up.",
        )
    if order.status not in _RELEASABLE:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST, detail=_release_refusal(order)
        )

    reason = payload.reason.strip()
    now = _now()
    collected = order.status in (OrderStatus.picked_up, OrderStatus.in_transit)
    previous_status = order.status

    # Claim the change in one statement, for the same reason accepting is one
    # statement: the customer may be cancelling, or the shop confirming the
    # pickup, at this exact moment. 0 rows means something else won.
    if collected:
        values = {
            "status": OrderStatus.cancelled,
            "cancelled_by": CANCELLED_BY_AGENT,
            "cancel_reason": reason,
            "cancelled_at": now,
        }
    else:
        values = {
            "agent_id": None,
            "status": OrderStatus.pending,
            "accepted_at": None,
            "promised_by": None,
            "reopened_at": now,
            # The customer is waiting again, so they are owed the "still
            # looking for a driver" message again. Left set, a hand-back
            # half an hour in would be the one wait they are never told
            # about -- the one where an agent has already given up.
            "unclaimed_notice_at": None,
            # The ETA belonged to the agent who has just left.
            "agent_eta_minutes": None,
            "agent_notified_at": None,
        }
    claimed = db.execute(
        update(Order)
        .where(
            Order.id == order.id,
            Order.status == previous_status,
            Order.agent_id == current_user.id,
        )
        .values(**values)
        .execution_options(synchronize_session=False)
    ).rowcount
    if claimed != 1:
        db.rollback()
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=_HANDOVER_RACE)

    if not collected:
        # Without this the order reappears at the top of this agent's own
        # available list a second later, which is exactly what they just
        # said they cannot do. Same table the Reject button uses, so the
        # "hidden for good" rule is already there.
        rejection = (
            db.query(OrderRejection)
            .filter(
                OrderRejection.order_id == order.id,
                OrderRejection.agent_id == current_user.id,
            )
            .first()
        )
        if rejection is None:
            rejection = OrderRejection(order_id=order.id, agent_id=current_user.id)
            db.add(rejection)
        rejection.reason = "released"
        rejection.hidden_until = None

    _write_event(db, order.id, OrderStatus.cancelled.value if collected else "released")
    db.commit()

    if collected:
        # Item 12: the shop's stock goes back on the shelf. Best effort --
        # giving up must not fail because shop-service is down; the order
        # keeps `stock_released_at` empty and the expiry sweep tries again.
        await stock.release_for_order(db, order)

    db.refresh(order)

    if collected:
        await publish_event(
            "order.cancelled",
            {
                "order_id": order.id,
                "shop_id": order.shop_id,
                "customer_id": order.customer_id,
                "cancelled_by": CANCELLED_BY_AGENT,
                "reason": reason,
            },
        )
        await _announce_agent_dropout(order, reason)
    else:
        await publish_event(
            "order.released",
            {"order_id": order.id, "agent_id": current_user.id, "reason": reason},
        )
        # The customer's screen is about to go from "a driver is on the way"
        # back to "looking for a driver", so this explains why before they
        # notice it themselves.
        await notify_users(
            [order.customer_id],
            "Looking for another driver",
            f"Your driver could not complete order {order.id[:8]} ({reason}). "
            "We are finding you another one.",
            kind="order",
            link={"route": "order", "id": order.id},
        )

    return OrderReleaseResponse(
        order_id=order.id,
        status=order.status.value,
        reason=reason,
        returned_to_pool=not collected,
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

    # The two handovers must be proved, not just asserted. Checked before the
    # geofence so a wrong code gives a clear answer rather than a distance.
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

    await _complete_handover(
        db,
        order,
        new_status,
        confirmed_by=CONFIRMED_BY_AGENT,
        agent_lat=agent_lat,
        agent_lng=agent_lng,
    )
    return OrderResponse.from_model(
        order,
        viewer_id=current_user.id,
        viewer_role=current_user.role,
    )


# Who confirmed a handover, carried on the status event for the activity log.
CONFIRMED_BY_AGENT = "agent"
CONFIRMED_BY_SHOP = "shop_owner"
CONFIRMED_BY_CUSTOMER = "customer"

_HANDOVER_RACE = "This order was just updated. Refresh to see where it is now."


async def _complete_handover(
    db: Session,
    order: Order,
    new_status: OrderStatus,
    *,
    confirmed_by: str,
    agent_lat: float | None = None,
    agent_lng: float | None = None,
) -> None:
    """Record a pickup or a delivery, whoever confirmed it.

    The agent proves a handover with the other side's code, at the right
    place. The shop owner and the customer confirm it from their own
    accounts instead -- which still works when the agent's phone has no
    signal, the moment that used to leave an order stuck.
    """
    # The caller checked the status; claim the change only if it still holds,
    # so the agent and the customer confirming at the same moment cannot both
    # count the delivery.
    claimed = db.execute(
        update(Order)
        .where(Order.id == order.id, Order.status == order.status)
        .values(status=new_status)
    ).rowcount
    if claimed != 1:
        db.rollback()
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=_HANDOVER_RACE)

    now = _now()
    order.status = new_status
    if new_status == OrderStatus.picked_up:
        order.picked_up_at = now
    if new_status == OrderStatus.delivered:
        order.delivered_at = now
    _write_event(db, order.id, new_status.value, agent_lat, agent_lng)

    # A confirmed pickup means the parcel has left the counter, so the trip
    # has started. Recording in_transit here saves a button that only ever
    # said what had already happened.
    auto_transit = False
    if new_status == OrderStatus.picked_up:
        order.status = OrderStatus.in_transit
        _write_event(db, order.id, OrderStatus.in_transit.value, agent_lat, agent_lng)
        auto_transit = True

    profile = _get_agent_profile(db, order.agent_id) if order.agent_id else None
    if new_status == OrderStatus.delivered and profile is not None:
        profile.total_deliveries += 1
        # Old rows without a promise time count as on time.
        if order.promised_by is None or now <= order.promised_by:
            profile.on_time_deliveries += 1

    db.commit()
    db.refresh(order)

    await publish_event(
        "order.status_changed",
        {"order_id": order.id, "status": new_status.value, "confirmed_by": confirmed_by},
    )
    if auto_transit:
        await publish_event(
            "order.status_changed",
            {
                "order_id": order.id,
                "status": OrderStatus.in_transit.value,
                "confirmed_by": confirmed_by,
            },
        )
    if new_status == OrderStatus.delivered:
        await publish_event("order.delivered", {"order_id": order.id, "confirmed_by": confirmed_by})
        # The shop owner handed the parcel over at the counter and hears
        # nothing more about it otherwise; this closes the loop for them.
        owner_id = await _shop_owner_id(order.shop_id)
        if owner_id is not None:
            await notify_users(
                [owner_id],
                "Parcel received",
                f"The customer has received the parcel for order {order.id[:8]}.",
                kind="order",
                link={"route": "order", "id": order.id},
            )

    # Confirmed by someone else: the agent may be the one without signal, so
    # this is waiting for them when they reconnect.
    if confirmed_by != CONFIRMED_BY_AGENT and order.agent_id:
        if new_status == OrderStatus.picked_up:
            title = "Pickup confirmed by the shop"
            body = f"The shop confirmed you collected order {order.id[:8]}. Head to the customer."
        else:
            title = "Delivery confirmed by the customer"
            body = f"The customer confirmed they received order {order.id[:8]}. Well done!"
        await notify_users(
            [order.agent_id], title, body, kind="order", link={"route": "order", "id": order.id}
        )


def _pickup_refusal(order: Order) -> str:
    return {
        OrderStatus.pending: "No driver has accepted this order yet.",
        OrderStatus.cancelled: "This order was cancelled.",
    }.get(order.status, "This order has already been picked up.")


def _delivery_refusal(order: Order) -> str:
    return {
        OrderStatus.pending: "The driver has not collected your order from the shop yet.",
        OrderStatus.accepted: "The driver has not collected your order from the shop yet.",
        OrderStatus.delivered: "This order is already marked as delivered.",
        OrderStatus.cancelled: "This order was cancelled.",
    }.get(order.status, "This order cannot be confirmed now.")


@router.post("/{order_id}/confirm-pickup", response_model=OrderResponse)
async def confirm_pickup(
    order_id: str,
    current_user: CurrentUser = Depends(require_roles("shop_owner")),
    db: Session = Depends(get_db),
):
    """The shop owner confirms they handed the order to its agent.

    The other way to prove a pickup, beside the agent typing the owner's
    code: it needs the owner's phone online, not the agent's.
    """
    order = _get_order_or_404(db, order_id)
    if not await _owns_shop(order.shop_id, current_user.id):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Only this shop's owner can confirm the pickup.",
        )
    if order.status != OrderStatus.accepted or order.agent_id is None:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=_pickup_refusal(order))

    await _complete_handover(db, order, OrderStatus.picked_up, confirmed_by=CONFIRMED_BY_SHOP)
    return OrderResponse.from_model(order, viewer_id=current_user.id, viewer_role=current_user.role)


@router.post("/{order_id}/confirm-delivery", response_model=OrderResponse)
async def confirm_delivery(
    order_id: str,
    current_user: CurrentUser = Depends(require_customer),
    db: Session = Depends(get_db),
):
    """The customer confirms they received their order.

    The other way to prove a delivery, beside the agent typing the
    customer's code. Only after pickup: before that there is nothing in the
    agent's hands to receive.
    """
    order = _get_order_or_404(db, order_id)
    if order.customer_id != current_user.id:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Only the customer who placed this order can confirm it arrived.",
        )
    if order.status not in (OrderStatus.picked_up, OrderStatus.in_transit):
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=_delivery_refusal(order))

    await _complete_handover(db, order, OrderStatus.delivered, confirmed_by=CONFIRMED_BY_CUSTOMER)
    return OrderResponse.from_model(order, viewer_id=current_user.id, viewer_role=current_user.role)


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


async def _admin_ids() -> list[str]:
    """The admin accounts to alert, from user-service.

    Internal endpoint, blocked at the gateway. Returns an empty list on any
    failure: a missed alert is a smaller problem than a cancellation that
    fails because user-service is busy.
    """
    try:
        async with httpx.AsyncClient(timeout=4.0) as client:
            response = await client.get(
                f"{settings.user_service_url}/users/internal/admin-ids"
            )
            if response.status_code != 200:
                return []
            ids = response.json().get("admin_ids")
            return [i for i in ids if isinstance(i, str)] if isinstance(ids, list) else []
    except Exception:
        return []


async def _announce_cancellation(order, cancelled_by: str, reason: str) -> None:
    """Tell everyone affected except whoever did it (item 8).

    Cancelling used to publish `order.cancelled` and nothing else, and no
    service turned that into a notification, so a customer whose order
    vanished was never told anything.
    """
    owner_id = await _shop_owner_id(order.shop_id)
    reason_tail = f" Reason: {reason}" if reason else ""

    if cancelled_by == CANCELLED_BY_CUSTOMER:
        recipients = [user_id for user_id in (owner_id, order.agent_id) if user_id]
        title = "An order was cancelled"
        body = "The customer cancelled their order." + reason_tail
    elif cancelled_by == CANCELLED_BY_SHOP:
        recipients = [user_id for user_id in (order.customer_id, order.agent_id) if user_id]
        title = "Your order was cancelled by the shop"
        body = "The shop cancelled your order." + reason_tail
    else:
        recipients = [
            user_id
            for user_id in (order.customer_id, owner_id, order.agent_id)
            if user_id
        ]
        title = "An order was cancelled by an admin"
        body = "An administrator cancelled this order." + reason_tail

    if not recipients:
        return
    await notify_users(
        recipients,
        title,
        body,
        kind="order",
        link={"route": "order", "id": order.id},
    )


async def _check_shop_cancellation_streak(db: Session, order) -> None:
    """Alert admins on a shop's Nth cancellation inside the window (item 8).

    Exactly the Nth: the 4th and 5th produce nothing, so a shop having a bad
    week does not bury the admins. Counted from `cancelled_at`, so orders
    cancelled before this column existed do not count.
    """
    window_start = _now() - timedelta(days=settings.shop_cancellation_window_days)
    count = (
        db.query(func.count(Order.id))
        .filter(
            Order.shop_id == order.shop_id,
            Order.cancelled_by == CANCELLED_BY_SHOP,
            Order.cancelled_at >= window_start,
        )
        .scalar()
    ) or 0

    if count != settings.shop_cancellation_alert_count:
        return

    owner_id = await _shop_owner_id(order.shop_id)
    days = settings.shop_cancellation_window_days
    if owner_id:
        await notify_users(
            [owner_id],
            "You have cancelled several orders",
            f"Your shop has cancelled {count} orders in the last {days} days. "
            "Too many cancellations will be reviewed by an administrator.",
            kind="order",
            link={"route": "shop", "id": order.shop_id},
        )

    admins = await _admin_ids()
    await publish_event(
        "shop.cancellation_threshold",
        {
            "shop_id": order.shop_id,
            "owner_id": owner_id,
            "count": count,
            "window_days": days,
            "admin_ids": admins,
        },
    )


@router.patch("/{order_id}/cancel", response_model=OrderResponse)
async def cancel_order(
    order_id: str,
    payload: OrderCancelRequest | None = None,
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Item 8: the customer, the shop that owns the order, or an admin can
    cancel it while it is pending or accepted. Everyone else affected is
    told, with the reason when there is one."""
    order = _get_order_or_404(db, order_id)

    is_admin = current_user.role == "admin"
    is_customer = current_user.id == order.customer_id
    # Only asked when it could matter: an unreachable shop-service must not
    # turn a customer's own cancellation into a 403.
    is_shop_owner = (
        False
        if (is_admin or is_customer)
        else await _owns_shop(order.shop_id, current_user.id)
    )

    if not (is_admin or is_customer or is_shop_owner):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="You do not have permission to cancel this order",
        )

    if order.status not in (OrderStatus.pending, OrderStatus.accepted):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Cannot cancel an order already in transit or delivered",
        )

    reason = (payload.reason or "").strip() if payload is not None else ""
    if is_customer:
        cancelled_by = CANCELLED_BY_CUSTOMER
    elif is_shop_owner:
        cancelled_by = CANCELLED_BY_SHOP
    else:
        cancelled_by = CANCELLED_BY_ADMIN

    # The customer is shown this reason, so a shop or an admin has to give
    # one. A customer cancelling their own order does not owe anybody an
    # explanation.
    if cancelled_by != CANCELLED_BY_CUSTOMER and not reason:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="Please give a reason the customer can be shown.",
        )

    order.status = OrderStatus.cancelled
    order.cancelled_by = cancelled_by
    order.cancel_reason = reason or None
    order.cancelled_at = _now()
    _write_event(db, order.id, OrderStatus.cancelled.value)
    db.commit()

    # Item 12: the shop's stock goes back on the shelf. Best effort -- a
    # cancellation must not fail because shop-service is down; the order keeps
    # `stock_released_at` empty and the expiry sweep tries again.
    await stock.release_for_order(db, order)

    db.refresh(order)

    await publish_event(
        "order.cancelled",
        {
            "order_id": order.id,
            "shop_id": order.shop_id,
            "customer_id": order.customer_id,
            "cancelled_by": cancelled_by,
            "reason": order.cancel_reason,
        },
    )
    await _announce_cancellation(order, cancelled_by, reason)
    if cancelled_by == CANCELLED_BY_SHOP:
        await _check_shop_cancellation_streak(db, order)
    return OrderResponse.from_model(
        order,
        viewer_id=current_user.id,
        viewer_role=current_user.role,
        is_shop_owner=is_shop_owner,
    )


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


@router.get("/shop/{shop_id}", response_model=list[OrderResponse])
async def list_shop_orders(
    shop_id: str,
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Orders placed with one shop, for its owner.

    This is where the owner reads the pickup code out to the agent, so the
    response carries it for them and for nobody else.
    """
    is_admin = current_user.role == "admin"
    if not is_admin and not await _owns_shop(shop_id, current_user.id):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="You can only view orders for your own shop",
        )

    orders = (
        db.query(Order)
        .filter(Order.shop_id == shop_id)
        .order_by(Order.created_at.desc())
        .limit(100)
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
