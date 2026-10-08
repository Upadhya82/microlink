"""Distance helpers. Pure Python (no third-party imports) so they are easy to test."""

from dataclasses import dataclass
from math import asin, cos, radians, sin, sqrt

EARTH_RADIUS_KM = 6371.0


def haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Great-circle distance between two lat/lng points, in kilometres."""
    lat1, lon1, lat2, lon2 = map(radians, [lat1, lon1, lat2, lon2])
    dlat = lat2 - lat1
    dlon = lon2 - lon1
    a = sin(dlat / 2) ** 2 + cos(lat1) * cos(lat2) * sin(dlon / 2) ** 2
    return 2 * EARTH_RADIUS_KM * asin(sqrt(a))


@dataclass(frozen=True)
class BoundingBox:
    min_lat: float
    max_lat: float
    min_lng: float
    max_lng: float


def bounding_box(lat: float, lng: float, radius_km: float) -> BoundingBox | None:
    """A lat/lng rectangle that fully contains the circle of `radius_km`.

    It is only a cheap pre-filter so the database returns fewer rows before the
    exact haversine check runs in Python. Returns None near the poles or the
    date line, where a simple rectangle is not safe - the caller then skips the
    pre-filter and the exact check still gives the right answer.
    """
    if abs(lat) > 85:
        return None
    lat_delta = radius_km / 111.0
    lng_delta = radius_km / (111.0 * max(cos(radians(lat)), 0.01))
    box = BoundingBox(lat - lat_delta, lat + lat_delta, lng - lng_delta, lng + lng_delta)
    if box.min_lng < -180 or box.max_lng > 180 or box.min_lat < -90 or box.max_lat > 90:
        return None
    return box
