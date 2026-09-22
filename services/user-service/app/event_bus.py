import json
import redis.asyncio as redis
from app.config import settings

_redis_client = None


async def get_redis_client():
    global _redis_client
    if _redis_client is None:
        _redis_client = redis.Redis(
            host=settings.redis_host,
            port=settings.redis_port,
            decode_responses=True,
        )
    return _redis_client


async def publish_event(topic: str, data: dict) -> None:
    try:
        client = await get_redis_client()
        await client.publish(topic, json.dumps(data))
    except Exception:
        pass
