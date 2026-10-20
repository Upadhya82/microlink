"""Hold a shop's stock while an order exists (item 12).

An order used to be saved without anyone checking the shop had the goods, and
nothing ever lowered a product's stock, so two customers could be sold the
same last item. Now delivery-service asks shop-service to reserve every line
BEFORE the order row is written, and to release it again on every path that
ends the order.

The line-reading rule is a plain function so the awkward cases -- the
"request delivery" flow with no products, a repeated product, a quantity of
zero -- can be tested without a database or a running shop-service.
"""

import logging
from datetime import datetime, timezone

import httpx
from sqlalchemy.orm import Session

from app.config import settings

logger = logging.getLogger("delivery-service.stock")

RESERVE_TIMEOUT_SECONDS = 6.0


class InvalidLine(ValueError):
    """A product line that cannot be reserved (bad quantity or product id)."""


class StockShort(Exception):
    """The shop cannot fill the order. Carries shop-service's wording."""

    def __init__(self, detail: str):
        super().__init__(detail)
        self.detail = detail


class StockServiceUnavailable(Exception):
    """shop-service could not be reached, so nothing was reserved."""


def order_lines(items: list[dict]) -> list[dict]:
    """The product lines of an order, merged per product and ready to reserve.

    Returns an empty list when there is nothing to reserve: the "request
    delivery" flow (REQ-DELIV-3) carries no products at all, and a line
    without a product id is a free-text item, not something in the catalogue.

    Raises InvalidLine when a product line carries a quantity that cannot be
    reserved, so the caller can answer 422 rather than quietly ordering one.
    """
    merged: dict[str, int] = {}
    for item in items:
        if not isinstance(item, dict):
            raise InvalidLine("Each order line must be an object")
        product_id = item.get("product_id")
        if not product_id or not isinstance(product_id, str):
            continue  # free-text item: nothing in the catalogue to hold
        raw = item.get("quantity", 1)
        if isinstance(raw, bool) or not isinstance(raw, int):
            raise InvalidLine(f"Quantity for {product_id} must be a whole number")
        if raw < 1:
            raise InvalidLine(f"Quantity for {product_id} must be at least 1")
        merged[product_id] = merged.get(product_id, 0) + raw
    return [
        {"product_id": product_id, "quantity": quantity}
        for product_id, quantity in merged.items()
    ]


async def reserve(shop_id: str, order_id: str, lines: list[dict]) -> None:
    """Hold every line, or raise.

    StockShort when the shop is short (the order must not be saved);
    StockServiceUnavailable when shop-service cannot be reached, because
    saving an order whose stock was never checked is the bug being fixed.
    Reserving the same order twice is a no-op in shop-service, so a retry
    after a timeout is safe.
    """
    if not lines:
        return
    url = f"{settings.shop_service_url}/shops/{shop_id}/stock/reserve"
    try:
        async with httpx.AsyncClient(timeout=RESERVE_TIMEOUT_SECONDS) as client:
            response = await client.post(
                url, json={"order_id": order_id, "lines": lines}
            )
    except Exception as exc:
        logger.warning("Could not reach shop-service to reserve %s: %s", order_id, exc)
        raise StockServiceUnavailable from exc

    if response.status_code == 409:
        raise StockShort(_detail(response, "The shop does not have enough stock."))
    if response.status_code == 404:
        raise StockShort("That shop is no longer available.")
    if response.status_code >= 400:
        logger.warning(
            "Reserving stock for %s failed: %s %s",
            order_id,
            response.status_code,
            response.text[:200],
        )
        raise StockServiceUnavailable


async def release(shop_id: str, order_id: str) -> bool:
    """Give an order's held stock back. True when shop-service confirmed it.

    Best effort on purpose: a cancellation must succeed even while
    shop-service is down. The caller records that the release is still owed,
    and the expiry sweep tries again.
    """
    url = f"{settings.shop_service_url}/shops/{shop_id}/stock/release"
    try:
        async with httpx.AsyncClient(timeout=RESERVE_TIMEOUT_SECONDS) as client:
            response = await client.post(url, json={"order_id": order_id})
    except Exception as exc:
        logger.warning("Could not reach shop-service to release %s: %s", order_id, exc)
        return False
    if response.status_code >= 400:
        logger.warning(
            "Releasing stock for %s failed: %s %s",
            order_id,
            response.status_code,
            response.text[:200],
        )
        return False
    return True


def _detail(response: httpx.Response, fallback: str) -> str:
    try:
        detail = response.json().get("detail")
    except Exception:
        return fallback
    return detail if isinstance(detail, str) and detail else fallback


async def release_for_order(db: Session, order) -> bool:
    """Release one order's held stock and record that it was returned.

    The single place that decides whether a release is owed, so the cancel
    endpoint, a shop cancelling (item 8) and the expiry sweep cannot disagree:
    only an order that reserved stock and has not had it back gets released,
    which is what makes cancelling twice return the stock once.
    """
    if order.stock_reserved_at is None or order.stock_released_at is not None:
        return False
    if await release(order.shop_id, order.id):
        order.stock_released_at = datetime.now(timezone.utc)
        db.commit()
        return True
    logger.warning(
        "Stock for cancelled order %s is still held by shop %s; will retry",
        order.id,
        order.shop_id,
    )
    return False
