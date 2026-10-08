"""Owner analytics (SRS REQ-SHOP-5).

Keeps every key the owner dashboard already reads (total_views,
total_search_impressions, product_count, active_alert_count,
views_last_7_days) and adds: average rating, stock summary and peak hours.

Not included, and why: order count and revenue are owned by delivery-service,
and "popular products" needs per-product view/order data that no service
records yet.
"""

from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import func, or_
from sqlalchemy.orm import Session

from app import logic
from app.auth import CurrentUser, get_current_user
from app.config import settings
from app.database import get_db
from app.models import AnalyticsEventType, Product, Shop, ShopAlert, ShopAnalyticsEvent
from app.schemas import ShopAnalyticsResponse

router = APIRouter(prefix="/shops/{shop_id}/analytics", tags=["shop analytics"])

PEAK_HOURS_WINDOW_DAYS = 30
MAX_EVENT_ROWS = 20000


def _count_events(db: Session, shop_id: str, event_type: AnalyticsEventType) -> int:
    return (
        db.query(func.count(ShopAnalyticsEvent.id))
        .filter(ShopAnalyticsEvent.shop_id == shop_id, ShopAnalyticsEvent.event_type == event_type)
        .scalar()
        or 0
    )


@router.get("", response_model=ShopAnalyticsResponse)
async def get_shop_analytics(
    shop_id: str,
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    shop = db.get(Shop, shop_id)
    if shop is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Shop not found")
    if current_user.role != "admin" and shop.owner_id != current_user.id:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN, detail="You do not own this shop"
        )

    now = datetime.now(timezone.utc)
    now_local = logic.to_local(now, settings.local_utc_offset_minutes)

    total_views = _count_events(db, shop_id, AnalyticsEventType.view)
    total_impressions = _count_events(db, shop_id, AnalyticsEventType.search_impression)

    product_count = db.query(func.count(Product.id)).filter(Product.shop_id == shop_id).scalar() or 0
    stock_rows = (
        db.query(Product.stock_status, func.count(Product.id))
        .filter(Product.shop_id == shop_id)
        .group_by(Product.stock_status)
        .all()
    )
    stock_summary = {"in_stock": 0, "low_stock": 0, "out_of_stock": 0}
    for stock_status, count in stock_rows:
        stock_summary[stock_status or "in_stock"] = count

    active_alert_count = (
        db.query(func.count(ShopAlert.id))
        .filter(
            ShopAlert.shop_id == shop_id,
            ShopAlert.is_active == True,  # noqa: E712
            or_(ShopAlert.starts_at.is_(None), ShopAlert.starts_at <= now),
            or_(ShopAlert.ends_at.is_(None), ShopAlert.ends_at >= now),
        )
        .scalar()
        or 0
    )

    # One query for the recent view times; both the 7-day chart and the peak
    # hours are worked out from it in local time.
    since = now - timedelta(days=PEAK_HOURS_WINDOW_DAYS)
    view_times = [
        row[0]
        for row in db.query(ShopAnalyticsEvent.created_at)
        .filter(
            ShopAnalyticsEvent.shop_id == shop_id,
            ShopAnalyticsEvent.event_type == AnalyticsEventType.view,
            ShopAnalyticsEvent.created_at >= since,
        )
        .order_by(ShopAnalyticsEvent.created_at.desc())
        .limit(MAX_EVENT_ROWS)
        .all()
    ]

    return ShopAnalyticsResponse(
        shop_id=shop_id,
        total_views=total_views,
        total_search_impressions=total_impressions,
        product_count=product_count,
        active_alert_count=active_alert_count,
        views_last_7_days=logic.fill_last_days(
            view_times, today=now_local.date(), days=7, offset_minutes=settings.local_utc_offset_minutes
        ),
        average_rating=shop.rating_avg or 0.0,
        rating_count=shop.rating_count or 0,
        stock_summary=stock_summary,
        peak_hours=logic.peak_hours(view_times, offset_minutes=settings.local_utc_offset_minutes),
    )
