"""How many products a shop really offers, and what happens when that drops.

Items 10 and 11 are the same rule read two ways: a product customers can
see is one that is not hidden and has at least `min_listable_stock` units
(1 by default), and a shop needs `min_products_to_verify` of those before an
admin can verify it. Keeping
both counts here means the verify endpoint, the product endpoints and the
stock reservation cannot disagree about what a shop has on its shelves.

A shop that is already verified and falls below the threshold stays
visible -- hiding it the moment one sale sells a product out would make
shops appear and disappear all day -- but its owner is told once, so they
can restock before an admin notices.
"""

import logging
from datetime import datetime, timezone

from sqlalchemy import and_, func
from sqlalchemy.orm import Session

from app.config import settings
from app.event_bus import notify_users
from app.models import Product, Shop

logger = logging.getLogger(settings.service_name)


def visible_to_customers():
    """The filter for "a customer can see this product".

    Not hidden (selling the last item hides it until the owner unhides it)
    and with at least `min_listable_stock` in stock. Every customer-facing
    query uses this one condition, so the product list, the shop cards, the
    search and the verify threshold cannot disagree.
    """
    return and_(
        Product.is_hidden.is_(False),
        Product.stock_quantity >= settings.min_listable_stock,
    )


def listable_product_count(db: Session, shop_id: str) -> int:
    """How many of a shop's products a customer can see."""
    return (
        db.query(func.count(Product.id))
        .filter(Product.shop_id == shop_id, visible_to_customers())
        .scalar()
    ) or 0


def meets_verification_threshold(count: int) -> bool:
    return count >= settings.min_products_to_verify


async def review_product_count(db: Session, shop: Shop | None) -> int | None:
    """Check a shop's listable count after its products changed.

    Warns the owner the first time a verified shop drops below the
    threshold, and forgets the warning once it climbs back, so the next
    drop is worth telling them about again. Returns the current count, or
    None when there was no shop to check.

    Best effort on purpose: this runs after a change the owner has already
    been told succeeded, so a failure here is logged and swallowed rather
    than turned into an error about something that did work.
    """
    if shop is None:
        return None
    try:
        count = listable_product_count(db, shop.id)
        if not shop.is_verified:
            # A shop its neighbours have already confirmed is waiting on
            # nothing but this count, so a restock is what verifies it. The
            # other order -- products first, confirmations later -- is
            # handled by the confirm endpoint calling the same function.
            from app import community  # imported here: community imports this module

            await community.try_auto_verify(db, shop, count)
            # Otherwise an unverified shop is told by the verify endpoint's
            # 409 and the "N of 5" line on its dashboard; no need to nag it.
            return count

        if meets_verification_threshold(count):
            if shop.low_product_warning_at is not None:
                shop.low_product_warning_at = None
                db.commit()
            return count

        if shop.low_product_warning_at is not None:
            return count  # already told them; do not repeat it on every sale

        shop.low_product_warning_at = datetime.now(timezone.utc)
        db.commit()
        if shop.owner_id:
            await notify_users(
                [shop.owner_id],
                "Your shop is running low on listed products",
                f"{shop.name} now has {count} product(s) customers can see. "
                f"Shops need {settings.min_products_to_verify} products in "
                "stock. Restock (and unhide any sold-out products) to keep "
                "your shop looking open for business.",
                kind="shop_alert",
                link={"route": "shop", "id": shop.id},
            )
        return count
    except Exception:
        logger.exception("Could not review the product count for shop %s", shop.id)
        return None
