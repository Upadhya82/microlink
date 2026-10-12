"""The in-app notification centre, read side.

There is no POST here on purpose: notifications are only ever created by the
event-bus subscriber (app/activity.py), fed by other services calling their
own event_bus.notify_users(). That keeps "who may notify whom" a
service-to-service concern rather than something a phone could forge.

Routes live under /notifications (not /admin/...) because they belong to
every role, not just admins; the gateway maps that prefix to this service.
"""

import uuid

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.orm import Session

from app.auth import CurrentUser, get_current_user
from app.database import get_db
from app.models import Notification
from app.schemas import MarkAllReadResponse, NotificationResponse, UnreadCountResponse

router = APIRouter(prefix="/notifications", tags=["notifications"])


@router.get("/me", response_model=list[NotificationResponse])
async def list_my_notifications(
    unread_only: bool = Query(default=False),
    limit: int = Query(default=50, ge=1, le=200),
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    query = db.query(Notification).filter(Notification.user_id == current_user.id)
    if unread_only:
        query = query.filter(Notification.is_read.is_(False))
    return query.order_by(Notification.created_at.desc()).limit(limit).all()


@router.get("/me/unread-count", response_model=UnreadCountResponse)
async def my_unread_count(
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    # The app polls this every ~30s for the bell badge, so keep it a COUNT
    # rather than fetching rows.
    unread = (
        db.query(Notification)
        .filter(Notification.user_id == current_user.id, Notification.is_read.is_(False))
        .count()
    )
    return UnreadCountResponse(unread=unread)


@router.post("/me/read-all", response_model=MarkAllReadResponse)
async def mark_all_read(
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    updated = (
        db.query(Notification)
        .filter(Notification.user_id == current_user.id, Notification.is_read.is_(False))
        .update({Notification.is_read: True}, synchronize_session=False)
    )
    db.commit()
    return MarkAllReadResponse(updated=updated)


# Declared after /me/... so those literal paths are never read as an id.
@router.patch("/{notification_id}/read", response_model=NotificationResponse)
async def mark_read(
    notification_id: str,
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    try:
        # The column is a Postgres uuid; a non-uuid id would otherwise reach
        # the driver and come back as a 500 instead of a clean 404.
        uuid.UUID(notification_id)
    except ValueError:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="Notification not found"
        )
    notification = db.get(Notification, notification_id)
    # Someone else's notification is reported as missing rather than
    # forbidden, so ids can't be probed for existence.
    if notification is None or notification.user_id != current_user.id:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="Notification not found"
        )
    if not notification.is_read:
        notification.is_read = True
        db.commit()
        db.refresh(notification)
    return notification
