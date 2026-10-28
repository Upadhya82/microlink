"""What happens to a product after a sale: hide it when sold out, and tell the owner.

Two rules, both driven by stock_router after a reservation:

  * Sold out -- a customer bought the last item. The product is hidden from
    customers (is_hidden, hidden_reason "sold_out") and the owner is told.
    It stays hidden until the owner restocks it and taps "Unhide". If the
    order that sold it out is cancelled, the item is back on the shelf, so
    the hide is undone automatically (see `after_release`).
  * Running low -- a sale took the product down to `low_stock_threshold`
    (5) or fewer. The owner is told once per drop, with the product's name.
    That includes a product that was added with 5 or fewer: its first sale
    warns the owner too (`low_stock_notified` remembers it was sent).

The decision itself is `logic.stock_alert_after_sale`, a pure function the
tests can check without a database.
"""

import logging

from app import logic
from app.config import settings
from app.event_bus import notify_users
from app.models import Product, Shop

logger = logging.getLogger(settings.service_name)

SOLD_OUT = "sold_out"
HIDDEN_BY_OWNER = "owner"


def after_sale(product: Product, sold: int) -> str | None:
    """Update a product whose stock a sale has just lowered by `sold`.

    Hides it when it is now sold out. Returns the alert to send the owner
    ("sold_out", "low_stock" or None). Does not commit.
    """
    after = product.stock_quantity
    before = after + sold
    threshold = settings.low_stock_threshold
    alert = logic.stock_alert_after_sale(before, after, threshold)
    # The pure rule only sees a drop from above the threshold. A product
    # that was already at or under it (added with 5, or restocked to 4) has
    # not crossed anything, so it is warned the first time it sells unless
    # that warning was already sent. Stock above the threshold before this
    # sale means a restock happened, so an old warning no longer counts.
    already_warned = bool(getattr(product, "low_stock_notified", False)) and before <= threshold
    if alert is None and 0 < after <= threshold and not already_warned:
        alert = "low_stock"
    if alert == SOLD_OUT:
        product.is_hidden = True
        product.hidden_reason = SOLD_OUT
    if alert in ("low_stock", SOLD_OUT):
        product.low_stock_notified = True
    elif after > threshold:
        product.low_stock_notified = False
    return alert


def after_release(product: Product) -> None:
    """Undo a sold-out hide once a cancelled order puts stock back. Does not commit.

    Only a hide the sale caused is undone; a product the owner hid
    themselves stays hidden.
    """
    if (
        product.is_hidden
        and product.hidden_reason == SOLD_OUT
        and product.stock_quantity >= settings.min_listable_stock
    ):
        product.is_hidden = False
        product.hidden_reason = None


async def notify_owner(shop: Shop | None, alerts: list[tuple[str, int, str]]) -> None:
    """Send one notification per (product name, units left, alert) to the shop owner.

    Best effort: the sale has already succeeded, so a failure here is logged
    rather than turned into an error.
    """
    if shop is None or not shop.owner_id or not alerts:
        return
    link = {"route": "shop_owner", "id": shop.id}
    for name, left, alert in alerts:
        try:
            if alert == SOLD_OUT:
                await notify_users(
                    [shop.owner_id],
                    f"{name} is sold out",
                    f"The last {name} at {shop.name} was just ordered, so it is now "
                    "hidden from customers. Restock it, then tap Unhide in your "
                    "Products tab to show it again.",
                    kind="shop_alert",
                    link=link,
                )
            elif alert == "low_stock":
                await notify_users(
                    [shop.owner_id],
                    f"{name} is running low on stock",
                    f"Only {left} {name} left at {shop.name}. Restock soon so "
                    "customers can keep ordering it.",
                    kind="shop_alert",
                    link=link,
                )
        except Exception:
            logger.exception("Could not send the %s alert for %s", alert, name)
