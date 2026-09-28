"""Cross-service event bus subscriber: turns every event flowing over the
shared bus into a row in the activity log. Runs as a background task started
from the FastAPI lifespan (see app.main), completely outside the request
lifecycle -- there is no Depends(get_db) here, so we open and close our own
session per event."""

import json
import logging

from app.database import SessionLocal
from app.models import ActivityLog

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
        db.commit()
    except Exception:
        logger.exception("Failed to record activity log entry for envelope: %r", envelope)
        db.rollback()
    finally:
        db.close()
