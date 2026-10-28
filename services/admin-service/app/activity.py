"""Cross-service event bus subscriber: turns every event flowing over the
shared bus into a row in the activity log, and into notification rows for
the users an event concerns. Runs as a background task started from the
FastAPI lifespan (see app.main), completely outside the request lifecycle --
there is no Depends(get_db) here, so we open and close our own session per
event."""

import json
import logging

from app.database import SessionLocal
from app.models import ActivityLog, Notification
from app.notify_rules import link_route, notifications_from_event, superseded_by_event

logger = logging.getLogger("admin-service.activity")


async def handle_event(envelope: dict) -> None:
    db = SessionLocal()
    try:
        log = ActivityLog(
            event_type=envelope["event"],
            source_service=envelope["source"],
            payload=json.dumps(envelope.get("data", {})),
        )
        db.add(log)
        # Same transaction as the log row: either both land or neither does,
        # so a notification is never recorded for an event we failed to log.
        for row in notifications_from_event(envelope):
            db.add(Notification(**row))
        stale = superseded_by_event(envelope)
        if stale is not None:
            user_id, routes = stale
            for old in (
                db.query(Notification)
                .filter(Notification.user_id == user_id, Notification.is_read.is_(False))
                .all()
            ):
                if link_route(old.link) in routes:
                    old.is_read = True
        db.commit()
    except Exception:
        logger.exception("Failed to record activity log entry for envelope: %r", envelope)
        db.rollback()
    finally:
        db.close()
