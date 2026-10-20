"""Which shops keep drivers waiting (item 4).

A customer choosing between two shops has no way to know that one of them
regularly takes twenty minutes to hand a parcel over. Delivery-service is
the only service that knows: it holds the timestamps for when an order was
accepted, picked up and delivered.

So it works the figure out per shop on a schedule and publishes
`shop.timeliness`; shop-service stores it and the app shows an "Often
delayed" chip. The alternative -- having shop-service ask about every shop
whenever a list is rendered -- would put a cross-service call on the search
path, which is the one place that has to stay fast.

A shop is delay-prone when it has at least `min_orders_for_timeliness`
orders in the window and EITHER the median accept-to-pickup wait is over
`slow_pickup_minutes` OR at least `late_order_ratio` of its orders arrived
after the time promised. Every threshold is a setting
(see app/config.py), because the right numbers are a product decision.

`shop_timeliness` is a plain function over plain tuples, so the awkward
cases -- an even number of orders, an order still in progress, a shop with
four orders -- are testable without a database.
"""

import asyncio
import logging
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone

from sqlalchemy.orm import Session

from app.config import settings
from app.event_bus import publish_event
from app.models import Order, OrderStatus

logger = logging.getLogger("delivery-service.timeliness")

# How often to recompute. Hourly: the figure moves over weeks, and a shop
# that has just had a bad afternoon should not be branded within minutes.
SWEEP_SECONDS = 3600


@dataclass(frozen=True)
class ShopTimeliness:
    """What gets published for one shop."""

    shop_id: str
    order_count: int
    median_pickup_wait_min: float | None
    late_ratio: float
    delay_prone: bool


def median(values: list[float]) -> float | None:
    """The middle value, averaging the two middle ones for an even count."""
    if not values:
        return None
    ordered = sorted(values)
    middle = len(ordered) // 2
    if len(ordered) % 2 == 1:
        return ordered[middle]
    return (ordered[middle - 1] + ordered[middle]) / 2


def _as_utc(value: datetime) -> datetime:
    """Postgres returns aware timestamps, SQLite in the tests does not."""
    return value if value.tzinfo is not None else value.replace(tzinfo=timezone.utc)


def pickup_wait_minutes(accepted_at: datetime | None, picked_up_at: datetime | None):
    """How long the driver waited between accepting and collecting.

    None when either end is missing (an order still in progress, or one from
    before these timestamps existed): unknown is not the same as zero.
    """
    if accepted_at is None or picked_up_at is None:
        return None
    minutes = (_as_utc(picked_up_at) - _as_utc(accepted_at)).total_seconds() / 60.0
    # A clock that went backwards is not evidence of a fast shop.
    return None if minutes < 0 else minutes


def was_late(delivered_at: datetime | None, promised_by: datetime | None) -> bool | None:
    """Whether a delivered order missed the time it was promised by."""
    if delivered_at is None or promised_by is None:
        return None
    return _as_utc(delivered_at) > _as_utc(promised_by)


def shop_timeliness(
    shop_id: str,
    orders: list,
    *,
    min_orders: int | None = None,
    slow_pickup_minutes: float | None = None,
    late_ratio_threshold: float | None = None,
) -> ShopTimeliness:
    """Work out one shop's timeliness from its finished orders."""
    min_orders = min_orders if min_orders is not None else settings.min_orders_for_timeliness
    slow_pickup_minutes = (
        slow_pickup_minutes
        if slow_pickup_minutes is not None
        else settings.slow_pickup_minutes
    )
    late_ratio_threshold = (
        late_ratio_threshold
        if late_ratio_threshold is not None
        else settings.late_order_ratio
    )

    waits: list[float] = []
    late_flags: list[bool] = []
    for order in orders:
        wait = pickup_wait_minutes(
            getattr(order, "accepted_at", None), getattr(order, "picked_up_at", None)
        )
        if wait is not None:
            waits.append(wait)
        late = was_late(
            getattr(order, "delivered_at", None), getattr(order, "promised_by", None)
        )
        if late is not None:
            late_flags.append(late)

    median_wait = median(waits)
    late_ratio = (sum(late_flags) / len(late_flags)) if late_flags else 0.0

    # Too few orders to judge: a shop with one slow handover is not a
    # pattern, and branding it would be unfair and probably wrong.
    enough = len(orders) >= min_orders
    slow_pickups = median_wait is not None and median_wait > slow_pickup_minutes
    often_late = bool(late_flags) and late_ratio >= late_ratio_threshold

    return ShopTimeliness(
        shop_id=shop_id,
        order_count=len(orders),
        median_pickup_wait_min=round(median_wait, 1) if median_wait is not None else None,
        late_ratio=round(late_ratio, 3),
        delay_prone=enough and (slow_pickups or often_late),
    )


def recent_orders_by_shop(db: Session, now: datetime | None = None) -> dict[str, list]:
    """Finished orders per shop inside the window."""
    now = now or datetime.now(timezone.utc)
    cutoff = now - timedelta(days=settings.timeliness_window_days)
    rows = (
        db.query(Order)
        .filter(
            Order.status == OrderStatus.delivered,
            Order.created_at >= cutoff,
        )
        .all()
    )
    grouped: dict[str, list] = {}
    for order in rows:
        grouped.setdefault(order.shop_id, []).append(order)
    return grouped


async def publish_timeliness(db: Session, now: datetime | None = None) -> int:
    """Recompute every shop's timeliness and publish it. Returns the count."""
    grouped = recent_orders_by_shop(db, now)
    published = 0
    for shop_id, orders in grouped.items():
        result = shop_timeliness(shop_id, orders)
        await publish_event(
            "shop.timeliness",
            {
                "shop_id": result.shop_id,
                "delay_prone": result.delay_prone,
                "median_pickup_wait_min": result.median_pickup_wait_min,
                "late_ratio": result.late_ratio,
                "order_count": result.order_count,
                "window_days": settings.timeliness_window_days,
            },
        )
        published += 1
    if published:
        logger.info("Published timeliness for %d shop(s)", published)
    return published


async def run_timeliness_loop(session_factory) -> None:
    """Recompute and publish until the service shuts down."""
    while True:
        try:
            await asyncio.sleep(SWEEP_SECONDS)
            db = session_factory()
            try:
                await publish_timeliness(db)
            finally:
                db.close()
        except asyncio.CancelledError:
            raise
        except Exception:
            # A failed sweep must not kill the loop; the next one retries.
            logger.exception("Timeliness sweep failed; will retry")
