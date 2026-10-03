from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session

from app.auth import CurrentUser, require_admin
from app.database import get_db
from app.models import ActivityLog
from app.schemas import ActivityLogResponse

router = APIRouter(prefix="/admin", tags=["activity log"])


@router.get("/activity-log", response_model=list[ActivityLogResponse])
async def list_activity_log(
    event_type: str | None = Query(default=None),
    source_service: str | None = Query(default=None),
    limit: int = Query(default=100, ge=1, le=500),
    current_user: CurrentUser = Depends(require_admin),
    db: Session = Depends(get_db),
):
    query = db.query(ActivityLog)
    if event_type is not None:
        query = query.filter(ActivityLog.event_type == event_type)
    if source_service is not None:
        query = query.filter(ActivityLog.source_service == source_service)
    return query.order_by(ActivityLog.created_at.desc()).limit(limit).all()
