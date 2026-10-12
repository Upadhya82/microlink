"""Cancel orders that no delivery agent picked up.

An order that sits in the available list with nobody accepting it leaves the
customer watching a spinner with no idea anything is wrong. After a short
wait the order is cancelled and the customer is told to try again, which is
honest about what happened and lets them re-order straight away.

Pure helper plus a loop, so the decision of which orders have expired can be
unit tested without a database or a running event loop.
"""

import asyncio
import logging
from datetime import datetime, timedelta, timezone

from sqlalchemy.orm import Session

from app.event_bus import notify_users, publish_event
from app.models import Order, OrderEvent, OrderStatus

logger = logging.getLogger("delivery-service.expiry")

# How long an order may wait for an agent before it is cancelled.
UNCLAIMED_TIMEOUT_MINUTES = 5

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


def expired_orders(orders, now: datetime, timeout_minutes: int = UNCLAIMED_TIMEOUT_MINUTES):
    """The orders that have waited too long with no agent assigned."""
    cutoff = now - timedelta(minutes=timeout_minutes)
    return [
        order
        for order in orders
        if order.status == OrderStatus.pending
        and order.agent_id is None
        and _as_utc(order.created_at) <= cutoff
    ]


async def cancel_unclaimed(db: Session, now: datetime | None = None) -> list[str]:
    """Cancel every order that has waited too long. Returns their ids."""
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
        # Without this the tracking timeline just stops at "pending" and the
        # customer sees no reason their order went away.
        db.add(OrderEvent(order_id=order.id, status=OrderStatus.cancelled.value))
    db.commit()

    for order in stale:
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


async def run_expiry_loop(session_factory) -> None:
    """Sweep for unclaimed orders until the service shuts down."""
    while True:
        try:
            await asyncio.sleep(SWEEP_SECONDS)
            db = session_factory()
            try:
                await cancel_unclaimed(db)
            finally:
                db.close()
        except asyncio.CancelledError:
            raise
        except Exception:
            # A failed sweep must not kill the loop; the next one retries.
            logger.exception("Unclaimed-order sweep failed; will retry")
