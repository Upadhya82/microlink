"""Per-account brute-force protection for login.

The gateway already limits attempts per client address; this adds a limit per
*email*, so a distributed attacker (many addresses, one victim) is slowed too.
Counters live in Redis and expire on their own. If Redis is unreachable the
guard fails open -- login keeps working, it just loses this extra protection.
"""

import hashlib
import logging

from app.event_bus import get_redis_client

logger = logging.getLogger(__name__)

MAX_FAILURES = 10
WINDOW_SECONDS = 15 * 60


def _key(email: str) -> str:
    digest = hashlib.sha256(email.strip().lower().encode("utf-8")).hexdigest()
    return f"login_failures:{digest}"


async def seconds_locked(email: str) -> int:
    """Seconds the account stays locked, or 0 if login may be attempted."""
    try:
        redis = get_redis_client()
        count = await redis.get(_key(email))
        if count is not None and int(count) >= MAX_FAILURES:
            return max(1, await redis.ttl(_key(email)))
    except Exception:
        logger.warning("login guard unavailable (Redis); allowing attempt", exc_info=True)
    return 0


async def record_failure(email: str) -> None:
    try:
        redis = get_redis_client()
        key = _key(email)
        if await redis.incr(key) == 1:
            await redis.expire(key, WINDOW_SECONDS)
    except Exception:
        logger.warning("login guard unavailable (Redis); failure not counted", exc_info=True)


async def clear(email: str) -> None:
    try:
        await get_redis_client().delete(_key(email))
    except Exception:
        logger.warning("login guard unavailable (Redis); counter not cleared", exc_info=True)
