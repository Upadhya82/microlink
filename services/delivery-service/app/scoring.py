"""Small, pure helper functions for the delivery rules in the SRS.

Nothing in here touches the database or the web framework, so every function
can be unit-tested on its own (see tests/test_scoring.py).
"""

import math

from app.geo import haversine_m


def estimate_minutes(distance_km: float, speed_kmh: float) -> int:
    """Travel time in whole minutes (at least 1) for a distance at a speed."""
    if distance_km <= 0 or speed_kmh <= 0:
        return 1
    return max(1, math.ceil(distance_km / speed_kmh * 60))


def promised_minutes(
    leg_distances_km: list[float],
    speed_kmh: float,
    buffer_minutes: int,
    default_minutes: int,
) -> int:
    """How long we promise the customer the whole delivery will take.

    `leg_distances_km` holds the legs we could measure (agent -> shop, then
    shop -> customer). If we could not measure anything we fall back to a flat
    default instead of guessing.
    """
    if not leg_distances_km:
        return default_minutes
    travel = sum(estimate_minutes(d, speed_kmh) for d in leg_distances_km)
    return travel + buffer_minutes


def on_time_percentage(on_time: int, total: int) -> float | None:
    """Percentage of deliveries finished before their promised time."""
    if total <= 0:
        return None
    return round(100.0 * on_time / total, 1)


def performance_score(
    rating_avg: float, rating_count: int, on_time: int, total: int
) -> float | None:
    """SRS REQ-AGENT-5: one score from 1 to 5 for an agent.

    60% = average customer rating (a neutral 3 until the agent is rated),
    40% = on-time rate stretched onto the same 1-5 scale.
    Returns None until the agent has finished at least one delivery.
    """
    if total <= 0:
        return None
    rating_part = rating_avg if rating_count > 0 else 3.0
    on_time_part = 1.0 + 4.0 * (on_time / total)
    score = 0.6 * rating_part + 0.4 * on_time_part
    return round(min(5.0, max(1.0, score)), 2)


def is_within_geofence(
    agent_lat: float | None,
    agent_lng: float | None,
    target_lat: float | None,
    target_lng: float | None,
    radius_m: float,
) -> bool | None:
    """True / False when we can check, None when a coordinate is missing."""
    if any(v is None for v in (agent_lat, agent_lng, target_lat, target_lng)):
        return None
    return haversine_m(agent_lat, agent_lng, target_lat, target_lng) <= radius_m
