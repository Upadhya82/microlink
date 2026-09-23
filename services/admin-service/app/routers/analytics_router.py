from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, Depends
from sqlalchemy import func
from sqlalchemy.orm import Session

from app.auth import CurrentUser, require_admin
from app.database import get_db
from app.models import ActivityLog
from app.schemas import AnalyticsOverviewResponse

router = APIRouter(prefix="/admin", tags=["analytics"])


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

    return AnalyticsOverviewResponse(
        total_events=total_events,
        events_by_type=events_by_type,
        events_last_30_days=events_last_30_days,
    )
