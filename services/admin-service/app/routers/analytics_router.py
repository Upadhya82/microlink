from datetime import datetime, timedelta, timezone

import httpx
from fastapi import APIRouter, Depends
from sqlalchemy import func
from sqlalchemy.orm import Session

from app.auth import CurrentUser, require_admin
from app.database import get_db
from app.metrics import active_users, count_orders_since, delivery_stats, users_by_role
from app.models import ActivityLog
from app.schemas import AnalyticsOverviewResponse

router = APIRouter(prefix="/admin", tags=["analytics"])

# Where the "top searched categories" figure comes from. shop-service owns
# search, so admin-service proxies rather than duplicating the counting.
_TRENDING_URL = "http://shop-service:8000/shops/trending"


async def _top_searches() -> list[dict]:
    """REQ-ADMIN-6. Swallows failures to an empty list: the whole analytics
    page must not 500 because one optional panel's upstream is down."""
    try:
        async with httpx.AsyncClient(timeout=3.0) as client:
            response = await client.get(_TRENDING_URL)
            response.raise_for_status()
            data = response.json()
    except Exception:
        return []
    if not isinstance(data, list):
        return []
    rows: list[dict] = []
    for item in data[:10]:
        if isinstance(item, dict):
            rows.append(item)
        elif isinstance(item, str):
            rows.append({"term": item})
    return rows


@router.get("/analytics/overview", response_model=AnalyticsOverviewResponse)
async def get_analytics_overview(
    current_user: CurrentUser = Depends(require_admin),
    db: Session = Depends(get_db),
):
    total_events = db.query(func.count(ActivityLog.id)).scalar() or 0

    type_rows = (
        db.query(ActivityLog.event_type, func.count(ActivityLog.id))
        .group_by(ActivityLog.event_type)
        .all()
    )
    events_by_type = {event_type: count for event_type, count in type_rows}

    since = datetime.now(timezone.utc) - timedelta(days=30)
    daily_rows = (
        db.query(
            func.date(ActivityLog.created_at).label("day"),
            func.count(ActivityLog.id).label("count"),
        )
        .filter(ActivityLog.created_at >= since)
        .group_by(func.date(ActivityLog.created_at))
        .order_by(func.date(ActivityLog.created_at))
        .all()
    )
    events_last_30_days = [{"date": str(row.day), "count": row.count} for row in daily_rows]

    # --- REQ-ADMIN-6: users, orders, revenue, delivery time, top searches.
    now = datetime.now(timezone.utc)
    today = now - timedelta(days=1)
    week = now - timedelta(days=7)
    month = now - timedelta(days=30)

    registration_payloads = [
        row.payload
        for row in db.query(ActivityLog).filter(ActivityLog.event_type == "user.registered").all()
    ]
    roles = users_by_role(registration_payloads)

    order_rows = db.query(ActivityLog).filter(ActivityLog.event_type == "order.created").all()
    delivered_rows = (
        db.query(ActivityLog).filter(ActivityLog.event_type == "order.delivered").all()
    )
    stats = delivery_stats(
        [(row.payload, row.created_at) for row in order_rows],
        [(row.payload, row.created_at) for row in delivered_rows],
    )

    day_rows = db.query(ActivityLog).filter(ActivityLog.created_at >= today).all()

    return AnalyticsOverviewResponse(
        total_events=total_events,
        events_by_type=events_by_type,
        events_last_30_days=events_last_30_days,
        users_by_role=roles,
        total_users=sum(roles.values()),
        daily_active_users=active_users(day_rows, now=now),
        orders_today=count_orders_since(order_rows, today),
        orders_this_week=count_orders_since(order_rows, week),
        orders_this_month=count_orders_since(order_rows, month),
        revenue_delivered=stats["revenue"],
        average_delivery_minutes=stats["average_delivery_minutes"],
        top_searches=await _top_searches(),
    )
