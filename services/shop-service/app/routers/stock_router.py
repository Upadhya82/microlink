"""Hold and return product stock for an order (item 12).

delivery-service calls these two endpoints: it reserves before it saves an
order, and releases on every path that ends one (customer cancel, the
five-minute auto-expiry, a shop cancelling). Nothing else in MicroLink ever
changes `stock_quantity` behind a sale.

Why a conditional UPDATE rather than read-then-write: two customers ordering
the last units arrive at the same moment, and
``UPDATE ... WHERE stock_quantity >= :q`` lets the database decide which one
gets them. A row count of 0 means somebody else got there first, and the
whole reservation is rolled back -- an order is all-or-nothing, never
partly filled.

These routes are internal. api-gateway blocks /shops/*/stock/* so no app
can reach them; inside the compose network delivery-service reaches
shop-service directly.
"""

import logging
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select, update
from sqlalchemy.orm import Session

from app import listings, logic
from app.config import settings
from app.database import get_db
from app.models import Product, Shop, StockReservation
from app.schemas import (
    StockLine,
    StockOperationResponse,
    StockReleaseRequest,
    StockReserveRequest,
)

router = APIRouter(prefix="/shops/{shop_id}/stock", tags=["stock"])

logger = logging.getLogger(settings.service_name)


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _restate_stock(db: Session, product: Product) -> None:
    """Put `stock_status` and `is_available` back in step with the quantity.

    Always derived from the quantity: selling the last unit makes a product
    out of stock, and cancelling that order has to make it available again.
    An owner's own "out of stock" switch is not distinguishable from a
    derived one (both clear `is_available`), so an owner who flips it while
    an order is live may have to flip it again after that order is
    cancelled. Reserving refuses out-of-stock products, so this only
    happens to a product switched off mid-order.
    """
    product.stock_status = logic.derive_stock_status(
        product.stock_quantity, settings.low_stock_threshold
    )
    product.is_available = logic.is_available_from_stock(product.stock_status)


def _open_reservations(db: Session, shop_id: str, order_id: str) -> list[StockReservation]:
    return (
        db.query(StockReservation)
        .filter(
            StockReservation.shop_id == shop_id,
            StockReservation.order_id == order_id,
            StockReservation.released_at.is_(None),
        )
        .all()
    )


@router.post("/reserve", response_model=StockOperationResponse)
async def reserve_stock(
    shop_id: str,
    payload: StockReserveRequest,
    db: Session = Depends(get_db),
):
    """Hold every line of an order, or none of them."""
    if db.get(Shop, shop_id) is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Shop not found")

    # Idempotent: the same order reserved twice (a double tap, a retry after a
    # timeout) must not take the stock twice.
    existing = _open_reservations(db, shop_id, payload.order_id)
    if existing:
        return StockOperationResponse(
            order_id=payload.order_id,
            changed=False,
            lines=[
                StockLine(product_id=row.product_id, quantity=row.quantity)
                for row in existing
            ],
        )

    # One line per product, so a cart listing the same product twice cannot
    # slip past the per-line check.
    wanted: dict[str, int] = {}
    for line in payload.lines:
        wanted[line.product_id] = wanted.get(line.product_id, 0) + line.quantity

    short: list[str] = []
    for product_id, quantity in wanted.items():
        result = db.execute(
            update(Product)
            .where(
                Product.id == product_id,
                Product.shop_id == shop_id,
                Product.stock_quantity >= quantity,
                Product.stock_status != "out_of_stock",
            )
            .values(stock_quantity=Product.stock_quantity - quantity)
        )
        if result.rowcount != 1:
            # Deleted, out of stock, another shop's product, or somebody else
            # took the last units a moment ago. Say which, by name.
            row = db.execute(
                select(Product.name, Product.stock_quantity, Product.shop_id).where(
                    Product.id == product_id
                )
            ).first()
            if row is None or row.shop_id != shop_id:
                short.append(f"a product that is no longer sold here (asked {quantity})")
            else:
                short.append(
                    f"{row.name} (asked {quantity}, {row.stock_quantity} left)"
                )

    if short:
        db.rollback()
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Not enough stock: " + ", ".join(short) + ".",
        )

    for product_id, quantity in wanted.items():
        db.add(
            StockReservation(
                order_id=payload.order_id,
                shop_id=shop_id,
                product_id=product_id,
                quantity=quantity,
            )
        )

    db.flush()
    for product_id in wanted:
        product = db.get(Product, product_id)
        if product is not None:
            db.refresh(product)
            _restate_stock(db, product)
    db.commit()

    logger.info(
        "Reserved stock for order %s at shop %s: %s", payload.order_id, shop_id, wanted
    )
    # Item 10: the sale may have taken the shop below the number of products
    # customers can see.
    await listings.review_product_count(db, db.get(Shop, shop_id))
    return StockOperationResponse(
        order_id=payload.order_id,
        changed=True,
        lines=[
            StockLine(product_id=product_id, quantity=quantity)
            for product_id, quantity in wanted.items()
        ],
    )


@router.post("/release", response_model=StockOperationResponse)
async def release_stock(
    shop_id: str,
    payload: StockReleaseRequest,
    db: Session = Depends(get_db),
):
    """Put an order's held stock back. Safe to call more than once."""
    if db.get(Shop, shop_id) is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Shop not found")

    held = _open_reservations(db, shop_id, payload.order_id)
    if not held:
        # Nothing to give back: already released, or an order placed before
        # reservations existed. Both are a success, not an error.
        return StockOperationResponse(order_id=payload.order_id, changed=False)

    released: list[StockLine] = []
    for row in held:
        db.execute(
            update(Product)
            .where(Product.id == row.product_id, Product.shop_id == shop_id)
            .values(stock_quantity=Product.stock_quantity + row.quantity)
        )
        row.released_at = _now()
        released.append(StockLine(product_id=row.product_id, quantity=row.quantity))

    db.flush()
    for row in held:
        product = db.get(Product, row.product_id)
        if product is not None:
            db.refresh(product)
            _restate_stock(db, product)
    db.commit()

    logger.info(
        "Released stock for order %s at shop %s: %d line(s)",
        payload.order_id,
        shop_id,
        len(released),
    )
    # A release can lift the shop back over the line, which clears the warning.
    await listings.review_product_count(db, db.get(Shop, shop_id))
    return StockOperationResponse(
        order_id=payload.order_id, changed=True, lines=released
    )
