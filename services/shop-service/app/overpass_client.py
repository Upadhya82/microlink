"""Free, no-key alternative to Google Places: queries OpenStreetMap's public
Overpass API for real nearby points of interest (pharmacies, restaurants,
etc.) so search results aren't limited to what's been added to MicroLink's
own database yet. Uses the same OpenStreetMap data already powering the
app's live map (flutter_map), so no new API key or billing account is
needed -- the tradeoff (documented in the project's build notes) is
patchier small-business coverage than Google Places has in some areas.

Results are clearly tagged `source: "openstreetmap"` by the caller so nothing
here is ever confused with a real, ownable MicroLink shop record.
"""

import logging

import httpx

from app import logic
from app.config import settings

logger = logging.getLogger("shop-service")

OVERPASS_URL = "https://overpass-api.de/api/interpreter"

# MicroLink's shop categories -> the OSM tags that best match them. "other"
# has no good single OSM tag to search, so external search is skipped for it
# rather than returning an overly broad, noisy result set.
_CATEGORY_TAGS: dict[str, list[tuple[str, str]]] = {
    "grocery": [("shop", "supermarket"), ("shop", "convenience"), ("shop", "grocery")],
    "restaurant": [("amenity", "restaurant"), ("amenity", "fast_food"), ("amenity", "cafe")],
    "pharmacy": [("amenity", "pharmacy")],
    "electronics": [("shop", "electronics")],
    "clothing": [("shop", "clothes")],
    "hardware": [("shop", "hardware"), ("shop", "doityourself")],
    "stationery": [("shop", "stationery")],
    "bakery": [("shop", "bakery")],
}


def _build_query(category: str, lat: float, lng: float, radius_m: int) -> str | None:
    tags = _CATEGORY_TAGS.get(category)
    if not tags:
        return None
    clauses = "\n".join(
        f'  node["{k}"="{v}"](around:{radius_m},{lat},{lng});\n'
        f'  way["{k}"="{v}"](around:{radius_m},{lat},{lng});'
        for k, v in tags
    )
    return f"[out:json][timeout:10];\n(\n{clauses}\n);\nout center 30;"


def _extract_address(tags: dict) -> str:
    parts = [
        tags.get("addr:housenumber"),
        tags.get("addr:street"),
        tags.get("addr:city") or tags.get("addr:suburb"),
    ]
    return ", ".join(p for p in parts if p)


async def search_nearby_places(category: str, lat: float, lng: float, radius_km: float) -> list[dict]:
    """Never raises -- Overpass is a shared public service with no uptime
    guarantee, so a failure here degrades to "no external results" rather
    than breaking the whole shop search."""
    query = _build_query(category, lat, lng, radius_m=int(radius_km * 1000))
    if query is None:
        return []

    try:
        # Overpass's public instance 406s requests that don't look like a
        # real client (no User-Agent, wrong Accept header) -- both are
        # required by its usage policy, not just good practice here.
        headers = {
            "User-Agent": "MicroLink/1.0 (local shop discovery app)",
            "Accept": "application/json",
        }
        async with httpx.AsyncClient(timeout=12.0) as client:
            response = await client.post(OVERPASS_URL, data={"data": query}, headers=headers)
            response.raise_for_status()
            elements = response.json().get("elements", [])
    except Exception:
        logger.warning("Overpass API request failed", exc_info=True)
        return []

    places: list[dict] = []
    for el in elements:
        tags = el.get("tags", {})
        name = tags.get("name")
        if not name:
            continue  # Unnamed POIs aren't useful to show as a "shop".

        point = el if el["type"] == "node" else el.get("center")
        if point is None or "lat" not in point:
            continue

        places.append(
            {
                "id": f"osm-{el['type']}-{el['id']}",
                "name": name,
                "category": category,
                "address": _extract_address(tags),
                "latitude": point["lat"],
                "longitude": point["lon"],
                "phone": tags.get("phone") or tags.get("contact:phone"),
                "opening_hours": tags.get("opening_hours"),
                "source": "openstreetmap",
            }
        )
    return places


async def geocode_landmark(text: str) -> dict | None:
    """Turn a landmark name ("Central Bus Stand") into a point (SRS REQ-SEARCH-3).

    1. Ask OpenStreetMap's free Nominatim geocoder (no API key), limited to Sri Lanka.
    2. If that is slow or unreachable (rural / poor internet), fall back to a
       small built-in list of well-known places in app/logic.py.

    Never raises. Returns {"name", "latitude", "longitude", "source"} or None.
    """
    query = text.strip()
    if not query:
        return None

    try:
        # Nominatim's usage policy requires an identifying User-Agent.
        headers = {"User-Agent": "MicroLink/1.0 (local shop discovery app)", "Accept": "application/json"}
        params = {"q": query, "format": "jsonv2", "limit": 1, "countrycodes": "lk"}
        async with httpx.AsyncClient(timeout=settings.geocode_timeout_seconds) as client:
            response = await client.get(settings.nominatim_url, params=params, headers=headers)
            response.raise_for_status()
            results = response.json()
        if results:
            top = results[0]
            name = (top.get("display_name") or query).split(",")[0].strip() or query
            return {
                "name": name,
                "latitude": float(top["lat"]),
                "longitude": float(top["lon"]),
                "source": "openstreetmap",
            }
    except Exception:
        logger.warning("Nominatim geocoding failed - trying the built-in list", exc_info=True)

    return logic.lookup_landmark(query)


async def reverse_geocode(lat: float, lng: float) -> dict | None:
    """Turn a point the user dropped on the map into a readable address.

    Needed because a customer can pick a delivery location anywhere in Sri
    Lanka by dragging a pin, and "6.9271, 79.8612" is not something a
    delivery agent can navigate to.

    Never raises. Returns {"name", "address", "latitude", "longitude",
    "source"} or None when the point cannot be resolved (mid-ocean, geocoder
    unreachable), leaving the caller to fall back to raw coordinates.
    """
    try:
        headers = {"User-Agent": "MicroLink/1.0 (local shop discovery app)", "Accept": "application/json"}
        params = {"lat": lat, "lon": lng, "format": "jsonv2", "zoom": 18, "addressdetails": 1}
        async with httpx.AsyncClient(timeout=settings.geocode_timeout_seconds) as client:
            response = await client.get(settings.nominatim_reverse_url, params=params, headers=headers)
            response.raise_for_status()
            payload = response.json()
    except Exception:
        logger.warning("Nominatim reverse geocoding failed", exc_info=True)
        return None

    place = logic.format_reverse_geocode(payload)
    if place is None:
        return None
    return {**place, "source": "openstreetmap"}
