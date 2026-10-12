"""A small in-memory sliding-window rate limiter for the public auth routes.

It stops one client from hammering login (password guessing) or register
(account spam) through the gateway. State lives in this process only, which is
fine for the single gateway container in docker-compose; if the gateway is
ever scaled to several replicas, move the counters to Redis.

The client address is ``request.client.host``. Behind a reverse proxy that is
the proxy's address, so run uvicorn with ``--proxy-headers`` and
``--forwarded-allow-ips`` set to the proxy so it reports the real client.
"""

import time
from collections import defaultdict, deque

# (HTTP method, normalised path) -> (max requests, window in seconds)
LIMITS: dict[tuple[str, str], tuple[int, int]] = {
    ("POST", "/auth/login"): (10, 60),
    ("POST", "/auth/register"): (5, 600),
}

_MAX_TRACKED_KEYS = 10_000

_hits: dict[tuple[str, str, str], deque[float]] = defaultdict(deque)


def rule_for(method: str, path: str) -> tuple[int, int] | None:
    return LIMITS.get((method.upper(), "/" + path.strip("/")))


def check(client: str, method: str, path: str) -> int | None:
    """Record a request. Returns None if allowed, else seconds until retry."""
    rule = rule_for(method, path)
    if rule is None:
        return None
    limit, window = rule
    now = time.monotonic()
    key = (client, method.upper(), "/" + path.strip("/"))

    if len(_hits) > _MAX_TRACKED_KEYS:
        _prune(now)

    hits = _hits[key]
    while hits and now - hits[0] >= window:
        hits.popleft()
    if len(hits) >= limit:
        return max(1, int(window - (now - hits[0])) + 1)
    hits.append(now)
    return None


def _prune(now: float) -> None:
    longest = max(window for _, window in LIMITS.values())
    for key in [k for k, v in _hits.items() if not v or now - v[-1] >= longest]:
        del _hits[key]
