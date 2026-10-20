"""Real road routing via OSRM (Open Source Routing Machine).

The public OSRM demo server routes over the same OpenStreetMap road network
the app's map tiles come from, and needs no API key. It only carries the
`driving` (car) profile, so for walking/cycling we keep OSRM's road geometry
and distance but recompute the ETA from a mode speed. Every failure path
returns ``None`` so the caller can fall back to straight-line geometry and the
endpoint never hard-fails.
"""

import asyncio
import logging
import math

import httpx

from app.config import settings
from app.geo import haversine_km
from app.instructions import pick_route, steps_from_legs
from app.schemas import Coordinate

logger = logging.getLogger(settings.service_name)

# Road speeds (km/h) used to derive an ETA for modes OSRM's public server
# doesn't route natively.
_MODE_SPEED_KMH = {"walking": 4.8, "cycling": 15.0, "driving": 30.0}

# Detour alternatives (item 2, local trips). OSRM only offers a second route
# when one is clearly different and not much longer, which on a short town
# trip is almost never -- so the customer's "Other routes" choice never
# appeared. When OSRM has nothing to offer, the trip is also routed through a
# point to either side of the straight line, and whichever of those really
# uses other roads is offered instead.
_DETOUR_MIN_TRIP_KM = 0.8  # shorter than this, there is no meaningful other way
_DETOUR_OFFSET_RATIO = 0.3  # how far to the side, as a share of the trip
_DETOUR_MIN_OFFSET_KM = 0.3
_DETOUR_MAX_OFFSET_KM = 3.0
_DETOUR_MAX_STRETCH = 1.5  # over 50% longer than the main route is no fair option
_DETOUR_MAX_SHARED = 0.8  # sharing more than this much road = the same route
# Runs after the main request (8 s), and the app gives up at 15 s.
_DETOUR_TIMEOUT_S = 5.0


async def road_route(
    points: list[Coordinate],
    mode: str,
    preference: str = "fastest",
    language: str = "en",
) -> tuple[list[Coordinate], float, float, list[dict]] | None:
    """Ask OSRM for a route through ``points`` that follows real streets.

    Returns ``(polyline, distance_km, duration_minutes, steps, alternatives)``
    where ``polyline`` is the full road geometry, ``steps`` are the
    turn-by-turn instructions and ``alternatives`` is the same four-tuple for
    each other route OSRM offered (item 2). ``None`` if OSRM is unreachable
    or has no route (points in the sea, no connecting road, network down).
    """
    if len(points) < 2:
        return None

    try:
        async with httpx.AsyncClient(timeout=8.0) as client:
            # Alternatives only exist for a plain A->B request; OSRM ignores
            # the flag once there are waypoints, so asking then wastes bytes.
            data = await _osrm(client, points, alternatives=len(points) == 2)
    except Exception:
        logger.warning(
            "OSRM routing request failed; falling back to straight-line geometry",
            exc_info=True,
        )
        return None

    if data.get("code") != "Ok" or not data.get("routes"):
        return None

    route = pick_route(data["routes"], preference)
    if route is None:
        return None

    chosen = _as_path(route, mode, language)
    if chosen is None:
        return None

    # Item 2: the alternatives were already being fetched and thrown away.
    # Keep the usable ones, in OSRM's order, excluding the chosen one.
    alternatives = []
    for other in data["routes"]:
        if other is route:
            continue
        path = _as_path(other, mode, language)
        if path is not None:
            alternatives.append(path)

    if not alternatives and len(points) == 2:
        alternatives = await _detour_alternatives(points[0], points[1], chosen, mode, language)

    polyline, distance_km, duration_minutes, steps = chosen
    return polyline, distance_km, duration_minutes, steps, alternatives


async def _osrm(
    client: httpx.AsyncClient,
    points: list[Coordinate],
    *,
    alternatives: bool,
    continue_straight: bool = False,
) -> dict:
    coordinates = ";".join(f"{point.lng},{point.lat}" for point in points)
    params = {
        "overview": "full",
        "geometries": "geojson",
        "steps": "true",
        "alternatives": "true" if alternatives else "false",
    }
    if continue_straight:
        # No U-turn at a via point: the route has to carry on through it.
        params["continue_straight"] = "true"
    response = await client.get(
        f"{settings.osrm_base_url}/route/v1/driving/{coordinates}", params=params
    )
    response.raise_for_status()
    return response.json()


def detour_points(origin: Coordinate, destination: Coordinate) -> list[Coordinate]:
    """Two via points, one each side of the straight line, level with its
    middle. Empty for a trip too short to have a meaningful other way."""
    mid_lat = (origin.lat + destination.lat) / 2
    mid_lng = (origin.lng + destination.lng) / 2
    km_per_deg_lat = 110.574
    km_per_deg_lng = 111.320 * math.cos(math.radians(mid_lat))
    dx = (destination.lng - origin.lng) * km_per_deg_lng
    dy = (destination.lat - origin.lat) * km_per_deg_lat
    trip_km = math.hypot(dx, dy)
    if trip_km < _DETOUR_MIN_TRIP_KM:
        return []
    offset_km = min(
        max(trip_km * _DETOUR_OFFSET_RATIO, _DETOUR_MIN_OFFSET_KM), _DETOUR_MAX_OFFSET_KM
    )
    # Unit vector at right angles to the trip.
    px, py = -dy / trip_km, dx / trip_km
    return [
        Coordinate(
            lat=mid_lat + side * py * offset_km / km_per_deg_lat,
            lng=mid_lng + side * px * offset_km / km_per_deg_lng,
        )
        for side in (1, -1)
    ]


def shared_fraction(path: list[Coordinate], reference: list[Coordinate]) -> float:
    """How much of ``path``'s length runs along ``reference``.

    Both come from the same OSRM road graph, so a shared road is made of the
    very same node coordinates -- an exact match, no tolerance needed.
    """
    on_reference = {(round(p.lat, 5), round(p.lng, 5)) for p in reference}
    total = shared = 0.0
    for a, b in zip(path, path[1:]):
        length = haversine_km(a.lat, a.lng, b.lat, b.lng)
        total += length
        if (round(a.lat, 5), round(a.lng, 5)) in on_reference and (
            round(b.lat, 5),
            round(b.lng, 5),
        ) in on_reference:
            shared += length
    return shared / total if total > 0 else 1.0


def _without_via_stop(route: dict) -> dict:
    """Merge a detour's two legs into one, dropping the "you have arrived" /
    "head out" pair at the via point -- the driver never asked to stop there."""
    legs = [leg for leg in route.get("legs") or [] if isinstance(leg, dict)]
    if len(legs) < 2:
        return route
    steps: list = []
    for index, leg in enumerate(legs):
        for step in leg.get("steps") or []:
            if not isinstance(step, dict):
                continue
            kind = (step.get("maneuver") or {}).get("type")
            if (kind == "arrive" and index < len(legs) - 1) or (kind == "depart" and index > 0):
                continue
            steps.append(step)
    return {**route, "legs": [{"steps": steps}]}


async def _detour_alternatives(
    origin: Coordinate,
    destination: Coordinate,
    chosen: tuple[list[Coordinate], float, float, list[dict]],
    mode: str,
    language: str,
) -> list[tuple[list[Coordinate], float, float, list[dict]]]:
    """Other routes for a trip OSRM had only one answer for. Any failure just
    means fewer options; it never costs the customer the main route."""
    vias = detour_points(origin, destination)
    if not vias:
        return []

    async def fetch(via: Coordinate):
        try:
            async with httpx.AsyncClient(timeout=_DETOUR_TIMEOUT_S) as client:
                data = await _osrm(
                    client, [origin, via, destination], alternatives=False, continue_straight=True
                )
        except Exception:
            logger.info("OSRM detour request failed; offering one route fewer", exc_info=True)
            return None
        routes = data.get("routes") if data.get("code") == "Ok" else None
        if not routes or not isinstance(routes[0], dict):
            return None
        return _as_path(_without_via_stop(routes[0]), mode, language)

    main_polyline, main_distance_km = chosen[0], chosen[1]
    kept: list[tuple[list[Coordinate], float, float, list[dict]]] = []
    for path in await asyncio.gather(*(fetch(via) for via in vias)):
        if path is None or path[1] > main_distance_km * _DETOUR_MAX_STRETCH:
            continue
        # Bent through a via point that snapped back onto the same roads, or
        # onto the same roads as the other detour: not a different route.
        if shared_fraction(path[0], main_polyline) > _DETOUR_MAX_SHARED:
            continue
        if any(shared_fraction(path[0], other[0]) > _DETOUR_MAX_SHARED for other in kept):
            continue
        kept.append(path)
    return kept


def _as_path(
    route: dict, mode: str, language: str
) -> tuple[list[Coordinate], float, float, list[dict]] | None:
    """One OSRM route in the shape the rest of the service uses."""
    if not isinstance(route, dict):
        return None
    line = route.get("geometry", {}).get("coordinates", [])
    if len(line) < 2:
        return None

    # OSRM/GeoJSON coordinates are [lng, lat]; our Coordinate is (lat, lng).
    polyline = [Coordinate(lat=lat, lng=lng) for lng, lat in line]
    distance = route.get("distance")
    if not isinstance(distance, (int, float)):
        return None
    distance_km = distance / 1000.0

    if mode == "driving":
        duration = route.get("duration")
        if not isinstance(duration, (int, float)):
            return None
        duration_minutes = duration / 60.0
    else:
        speed_kmh = _MODE_SPEED_KMH.get(mode, _MODE_SPEED_KMH["walking"])
        duration_minutes = (distance_km / speed_kmh) * 60.0

    steps = steps_from_legs(route.get("legs") or [], language)
    return polyline, distance_km, duration_minutes, steps
