"""GET /delivery/orders/shop/{shop_id}/sales -- the owner's sales over a period.

Added for the shop owner's "Performance over time" analytics. Read-only and
separate from the existing order routes, which are unchanged. The rules are
in app/sales.py.
"""

from datetime import date

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import or_
from sqlalchemy.orm import Session

from app import sales
from app.auth import CurrentUser, get_current_user
from app.database import get_db
from app.models import Order
from app.routers.orders_router import _owns_shop

router = APIRouter(prefix="/delivery/orders", tags=["shop-sales"])


@router.get("/shop/{shop_id}/sales")
async def shop_sales(
    shop_id: str,
    start: date = Query(..., description="First local day (YYYY-MM-DD)"),
    end: date | None = Query(default=None, description="Last local day (YYYY-MM-DD). Default: today."),
    granularity: str = Query(default="month", pattern="^(day|month|year)$"),
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    if current_user.role != "admin" and not await _owns_shop(shop_id, current_user.id):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="You can only view sales for your own shop",
        )

    end = end or sales.local_today()
    if end < start:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="The end date must be on or after the start date.",
        )
    if granularity == "day" and (end - start).days + 1 > sales.MAX_DAILY_SPAN_DAYS:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="Pick a period of one year or less to see it day by day.",
        )

    begin_utc, after_utc = sales.local_window_utc(start, end)
    orders = (
        db.query(Order)
        .filter(
            Order.shop_id == shop_id,
            or_(
                (Order.created_at >= begin_utc) & (Order.created_at < after_utc),
                (Order.delivered_at >= begin_utc) & (Order.delivered_at < after_utc),
            ),
        )
        .all()
    )

    summary = sales.summarize(orders, start, end, granularity)
    return {
        "shop_id": shop_id,
        "start": start.isoformat(),
        "end": end.isoformat(),
        "granularity": granularity,
        **summary,
    }
