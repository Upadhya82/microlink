"""Fill in the shop name on orders placed before it was recorded.

`Order.shop_name` is copied onto an order when it is placed, so the
customer's own order list can say where they ordered from. Every order that
already existed when that column was added has NULL there, and NULL is a
customer looking at their history and still not being told which shop an
order came from -- which is the whole complaint the column exists to answer.

So they are filled in once, from shop-service, grouped by shop: one request
per distinct shop rather than one per order, because a regular customer has
many orders from the same few places.

Best effort, on purpose. A shop that has since been deleted stays NULL and
the app falls back to the pickup address; shop-service being down means the
next start tries again. Neither is worth refusing to boot over.
"""

import logging

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models import Order

logger = logging.getLogger("delivery-service.backfill")

# A ceiling so one start cannot spend minutes talking to shop-service on a
# large database. Whatever is left is picked up by the next start.
MAX_SHOPS_PER_RUN = 200


def shops_needing_names(db: Session, limit: int = MAX_SHOPS_PER_RUN) -> list[str]:
    """Distinct shops with at least one unnamed order, oldest first."""
    rows = db.execute(
        select(Order.shop_id)
        .where(Order.shop_name.is_(None))
        .group_by(Order.shop_id)
        .limit(limit)
    ).all()
    return [row[0] for row in rows]


def apply_name(db: Session, shop_id: str, name: str) -> int:
    """Name every unnamed order from one shop. Returns how many."""
    updated = (
        db.query(Order)
        .filter(Order.shop_id == shop_id, Order.shop_name.is_(None))
        .update({Order.shop_name: name}, synchronize_session=False)
    )
    db.commit()
    return updated


async def backfill_shop_names(db: Session, limit: int = MAX_SHOPS_PER_RUN) -> int:
    """Name the orders that have no name yet. Returns how many were named."""
    # Imported here rather than at module scope: orders_router imports the
    # models this module reads, and importing it at the top would make the
    # two modules import each other.
    from app.routers.orders_router import fetch_shop

    shop_ids = shops_needing_names(db, limit)
    if not shop_ids:
        return 0

    named = 0
    for shop_id in shop_ids:
        shop = await fetch_shop(shop_id)
        name = (shop or {}).get("name")
        if not isinstance(name, str) or not name.strip():
            continue
        named += apply_name(db, shop_id, name.strip())
    if named:
        logger.info(
            "Filled in the shop name on %d older order(s) from %d shop(s)",
            named,
            len(shop_ids),
        )
    return named


async def run_backfill(session_factory) -> None:
    """Run the backfill once, and never let it take the service down with it."""
    db = session_factory()
    try:
        await backfill_shop_names(db)
    except Exception:
        logger.exception("Could not fill in older orders' shop names; will retry on next start")
    finally:
        db.close()
