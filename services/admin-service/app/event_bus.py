import json
import logging
from typing import Any, Awaitable, Callable

import redis.asyncio as redis

from app.config import settings

logger = logging.getLogger(settings.service_name)

EVENTS_CHANNEL = "microlink.events"

_redis: redis.Redis | None = None


def get_redis() -> redis.Redis:
    global _redis
    if _redis is None:
        _redis = redis.Redis(
            host=settings.redis_host, port=settings.redis_port, decode_responses=True
        )
    return _redis


async def publish_event(event_type: str, payload: dict[str, Any]) -> None:
    """Publish a domain event onto the shared bus. Never raises -- a broken
    event bus should not take down the request that triggered the event."""
    client = get_redis()
    message = json.dumps(
        {"event": event_type, "source": settings.service_name, "data": payload}
    )
    try:
        await client.publish(EVENTS_CHANNEL, message)
    except Exception:
        logger.exception("Failed to publish event %s", event_type)


async def subscribe_events(handler: Callable[[dict], Awaitable[None]]) -> None:
    """Long-running task: listen on the shared events channel and invoke
    handler(envelope) for every message. Intended to be started as an
    asyncio background task from the FastAPI lifespan."""
    client = get_redis()
    pubsub = client.pubsub()
    await pubsub.subscribe(EVENTS_CHANNEL)
    async for message in pubsub.listen():
        if message["type"] != "message":
            continue
        try:
            envelope = json.loads(message["data"])
            await handler(envelope)
        except Exception:
            logger.exception("Failed to handle event message")
