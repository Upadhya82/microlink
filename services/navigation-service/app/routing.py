"""Real road routing via OSRM (Open Source Routing Machine).

The public OSRM demo server routes over the same OpenStreetMap road network
the app's map tiles come from, and needs no API key. It only carries the
`driving` (car) profile, so for walking/cycling we keep OSRM's road geometry
and distance but recompute the ETA from a mode speed. Every failure path
returns ``None`` so the caller can fall back to straight-line geometry and the
endpoint never hard-fails.
"""

import logging

import httpx

from app.config import settings
from app.schemas import Coordinate

logger = logging.getLogger(settings.service_name)

# Road speeds (km/h) used to derive an ETA for modes OSRM's public server
# doesn't route natively.
_MODE_SPEED_KMH = {"walking": 4.8, "cycling": 15.0, "driving": 30.0}


async def road_route(
    points: list[Coordinate], mode: str
) -> tuple[list[Coordinate], float, float] | None:
    """Ask OSRM for a route through ``points`` that follows real streets.

    Returns ``(polyline, distance_km, duration_minutes)`` where ``polyline`` is
    the full road geometry, or ``None`` if OSRM is unreachable or has no route
    (points in the sea, no connecting road, network down, ...).
    """
    if len(points) < 2:
        return None

    coordinates = ";".join(f"{point.lng},{point.lat}" for point in points)
    url = f"{settings.osrm_base_url}/route/v1/driving/{coordinates}"
    params = {"overview": "full", "geometries": "geojson", "steps": "false"}

    try:
        async with httpx.AsyncClient(timeout=8.0) as client:
            response = await client.get(url, params=params)
            response.raise_for_status()
            data = response.json()
    except Exception:
        logger.warning(
            "OSRM routing request failed; falling back to straight-line geometry",
            exc_info=True,
        )
        return None

    if data.get("code") != "Ok" or not data.get("routes"):
        return None

    route = data["routes"][0]
    line = route.get("geometry", {}).get("coordinates", [])
    if len(line) < 2:
        return None

    # OSRM/GeoJSON coordinates are [lng, lat]; our Coordinate is (lat, lng).
    polyline = [Coordinate(lat=lat, lng=lng) for lng, lat in line]
    distance_km = route["distance"] / 1000.0

    if mode == "driving":
        duration_minutes = route["duration"] / 60.0
    else:
        speed_kmh = _MODE_SPEED_KMH.get(mode, _MODE_SPEED_KMH["walking"])
        duration_minutes = (distance_km / speed_kmh) * 60.0

    return polyline, distance_km, duration_minutes
