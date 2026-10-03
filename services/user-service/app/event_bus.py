import json
import logging
from typing import Any

import redis.asyncio as redis

from app.config import settings

logger = logging.getLogger(settings.service_name)

# Every service publishes to this one channel; admin-service listens on it to
# build the live activity feed.
EVENTS_CHANNEL = "microlink.events"

_redis_client: redis.Redis | None = None


def get_redis_client() -> redis.Redis:
    global _redis_client
    if _redis_client is None:
        _redis_client = redis.Redis(
            host=settings.redis_host,
            port=settings.redis_port,
            decode_responses=True,
        )
    return _redis_client


async def publish_event(event_type: str, payload: dict[str, Any]) -> None:
    """Publish a domain event onto the shared bus. Never raises -- a broken
    event bus should not take down the request that triggered the event."""
    message = json.dumps({"event": event_type, "source": settings.service_name, "data": payload})
    try:
        await get_redis_client().publish(EVENTS_CHANNEL, message)
    except Exception:
        logger.exception("Failed to publish event %s", event_type)
