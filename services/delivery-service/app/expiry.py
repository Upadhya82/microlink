"""Keeping the customer informed while their order waits for an agent.

An order that sits in the available list with nobody accepting it leaves the
customer watching a spinner with no idea anything is wrong. The answer used
to be to cancel it for them after an hour. That is the wrong way round: an
order nobody has taken *yet* is not a failed order, it is an order still
waiting, and ending it is the customer's call, not the system's.

So after `settings.unclaimed_notice_minutes` the customer is simply told --
no agent has accepted this yet, it is still waiting, you can keep waiting or
cancel it -- and the order stays on offer until an agent takes it or the
customer ends it. They are told once per spell of waiting; an order an agent
hands back starts the clock again, because from the customer's side it is
waiting afresh.

The sweep that cancels is kept behind `settings.cancel_unclaimed_orders`,
off by default, for a deployment that has to cap how long an order may hold
a shop's reserved stock (item 12).

Pure helpers plus a loop, so which orders are due can be unit tested without
a database or a running event loop.
"""

import asyncio
import logging
from datetime import datetime, timedelta, timezone

from sqlalchemy.orm import Session

from app import stock
from app.config import settings
from app.event_bus import notify_users, publish_event
from app.models import Order, OrderEvent, OrderStatus

logger = logging.getLogger("delivery-service.expiry")

# How long an order may wait for an agent before it is cancelled. Read from
# settings so the window can be tuned per deployment; see
# `unclaimed_timeout_minutes` in app/config.py for why it is not five.
# Only acted on when `settings.cancel_unclaimed_orders` is true.
UNCLAIMED_TIMEOUT_MINUTES = settings.unclaimed_timeout_minutes

# How long an order waits before the customer is told nobody has taken it.
UNCLAIMED_NOTICE_MINUTES = settings.unclaimed_notice_minutes

# Item 8: nobody chose this cancellation, so it is attributed to the system.
CANCELLED_BY_SYSTEM = "system"

# How often to look. Well under the timeout, so an order is never cancelled
# much later than the timeout promises.
SWEEP_SECONDS = 30


def _as_utc(value: datetime) -> datetime:
    """Treat a naive timestamp as UTC.

    Postgres hands these back with a timezone, SQLite in the tests does not,
    and comparing the two raises. Normalising here keeps the rule itself
    simple.
    """
    return value if value.tzinfo is not None else value.replace(tzinfo=timezone.utc)


def waiting_since(order) -> datetime:
    """When this order started waiting for an agent.

    Normally when it was placed, but an order an agent handed back starts
    waiting again from that moment. Counting from `created_at` would make a
    released order instantly older than the timeout, so the sweep would
    cancel it before any other agent ever saw it in their list.
    """
    reopened = getattr(order, "reopened_at", None)
    if reopened is not None:
        return _as_utc(reopened)
    return _as_utc(order.created_at)


def expired_orders(orders, now: datetime, timeout_minutes: int = UNCLAIMED_TIMEOUT_MINUTES):
    """The orders that have waited too long with no agent assigned."""
    cutoff = now - timedelta(minutes=timeout_minutes)
    return [
        order
        for order in orders
        if order.status == OrderStatus.pending
        and order.agent_id is None
        and waiting_since(order) <= cutoff
    ]


def orders_awaiting_notice(
    orders, now: datetime, notice_minutes: int = UNCLAIMED_NOTICE_MINUTES
):
    """The waiting orders whose customer has not been told yet.

    `unclaimed_notice_at` is what stops the sweep sending the same message
    every thirty seconds: it is set when the customer is told, and cleared
    again when an agent hands the order back.
    """
    cutoff = now - timedelta(minutes=notice_minutes)
    return [
        order
        for order in orders
        if order.status == OrderStatus.pending
        and order.agent_id is None
        and getattr(order, "unclaimed_notice_at", None) is None
        and waiting_since(order) <= cutoff
    ]


async def notify_unclaimed(db: Session, now: datetime | None = None) -> list[str]:
    """Tell customers whose order is still waiting for an agent.

    The order is left exactly as it is. The message exists to hand the
    decision back to the person whose order it is, not to announce one that
    has already been made for them.
    """
    now = now or datetime.now(timezone.utc)
    waiting = (
        db.query(Order)
        .filter(
            Order.status == OrderStatus.pending,
            Order.agent_id.is_(None),
            Order.unclaimed_notice_at.is_(None),
        )
        .all()
    )
    due = orders_awaiting_notice(waiting, now)
    if not due:
        return []

    # Marked before the messages go out, so a sweep that fails partway
    # through cannot send the same customer the same message again.
    for order in due:
        order.unclaimed_notice_at = now
    db.commit()

    minutes = UNCLAIMED_NOTICE_MINUTES
    for order in due:
        await notify_users(
            [order.customer_id],
            "Still looking for a driver",
            f"No delivery agent has accepted your order in {minutes} minutes. "
            "It is still waiting and drivers can still take it. "
            "Open the order to keep waiting, or cancel it if you would "
            "rather not.",
            kind="order",
            link={"route": "order", "id": order.id},
        )
    logger.info("Told %d customer(s) their order is still waiting", len(due))
    return [order.id for order in due]


async def cancel_unclaimed(db: Session, now: datetime | None = None) -> list[str]:
    """Cancel every order that has waited too long. Returns their ids.

    Does nothing unless `settings.cancel_unclaimed_orders` is on; by default
    an order waits until an agent takes it or the customer ends it.
    """
    if not settings.cancel_unclaimed_orders:
        return []
    now = now or datetime.now(timezone.utc)
    waiting = (
        db.query(Order)
        .filter(Order.status == OrderStatus.pending, Order.agent_id.is_(None))
        .all()
    )
    stale = expired_orders(waiting, now)
    if not stale:
        return []

    for order in stale:
        order.status = OrderStatus.cancelled
        # Item 8: recorded as the system's doing, so it counts towards
        # neither the customer's daily limit nor the shop's streak.
        order.cancelled_by = CANCELLED_BY_SYSTEM
        order.cancelled_at = now
        order.cancel_reason = (
            f"No delivery agent accepted it within {UNCLAIMED_TIMEOUT_MINUTES} minutes"
        )
        # Without this the tracking timeline just stops at "pending" and the
        # customer sees no reason their order went away.
        db.add(OrderEvent(order_id=order.id, status=OrderStatus.cancelled.value))
    db.commit()

    for order in stale:
        # Item 12: an expired order gives its stock back, which can lift a
        # product back over the listing threshold.
        await stock.release_for_order(db, order)
        await publish_event(
            "order.status_changed",
            {"order_id": order.id, "status": OrderStatus.cancelled.value},
        )
        await notify_users(
            [order.customer_id],
            "No delivery agent available",
            "No agent accepted your order within "
            f"{UNCLAIMED_TIMEOUT_MINUTES} minutes, so it has been cancelled. "
            "Please try again.",
            kind="order",
            link={"route": "order", "id": order.id},
        )
    logger.info("Cancelled %d unclaimed order(s)", len(stale))
    return [order.id for order in stale]


async def retry_owed_releases(db: Session, limit: int = 50) -> int:
    """Return stock that is still held for an order that was cancelled.

    A cancellation never fails just because shop-service is down, so the
    release can be left owed. Releasing is idempotent, so retrying it here
    costs nothing when it already went through.
    """
    owed = (
        db.query(Order)
        .filter(
            Order.status == OrderStatus.cancelled,
            Order.stock_reserved_at.is_not(None),
            Order.stock_released_at.is_(None),
        )
        .order_by(Order.updated_at)
        .limit(limit)
        .all()
    )
    released = 0
    for order in owed:
        if await stock.release_for_order(db, order):
            released += 1
    if released:
        logger.info("Returned stock for %d cancelled order(s) on retry", released)
    return released


async def run_expiry_loop(session_factory) -> None:
    """Sweep for unclaimed orders until the service shuts down."""
    while True:
        try:
            await asyncio.sleep(SWEEP_SECONDS)
            db = session_factory()
            try:
                await notify_unclaimed(db)
                await cancel_unclaimed(db)
                await retry_owed_releases(db)
            finally:
                db.close()
        except asyncio.CancelledError:
            raise
        except Exception:
            # A failed sweep must not kill the loop; the next one retries.
            logger.exception("Unclaimed-order sweep failed; will retry")
