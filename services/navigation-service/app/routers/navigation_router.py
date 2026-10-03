from fastapi import APIRouter, Depends, Query, Request
from sqlalchemy.orm import Session

from app import auth
from app.auth import CurrentUser, get_current_user
from app.database import get_db
from app.geo import haversine_km
from app.locales import VOICE_LOCALES, get_voice_locale
from app.models import RouteHistory, TravelMode
from app.routing import road_route
from app.schemas import (
    Coordinate,
    OptimizeRequest,
    OptimizeResponse,
    OptimizeStop,
    RouteHistoryResponse,
    RouteLeg,
    RouteRequest,
    RouteResponse,
)

router = APIRouter(prefix="/navigation", tags=["navigation"])

# Fallback speed assumptions, in km/h, per travel mode. Used only when the
# OSRM routing engine (see app/routing.py) can't be reached -- then distance
# and duration fall back to straight-line (haversine) geometry between points,
# scaled by a flat speed assumption for the chosen mode.
SPEED_KMH: dict[str, float] = {
    "driving": 30.0,
    "walking": 5.0,
    "cycling": 15.0,
}


def _leg(origin: Coordinate, destination: Coordinate, speed_kmh: float) -> RouteLeg:
    distance_km = haversine_km(origin.lat, origin.lng, destination.lat, destination.lng)
    duration_minutes = (distance_km / speed_kmh) * 60
    return RouteLeg(
        **{"from": origin},
        to=destination,
        distance_km=distance_km,
        duration_minutes=duration_minutes,
    )


def _try_get_current_user(request: Request) -> CurrentUser | None:
    """Best-effort auth: if a bearer token is present and valid, return the
    user it identifies; otherwise return None without raising. Used by
    endpoints that must work for anonymous callers but still want to log
    activity for authenticated ones."""
    header = request.headers.get("Authorization")
    if not header or not header.lower().startswith("bearer "):
        return None
    token = header.split(" ", 1)[1].strip()
    if not token:
        return None
    try:
        payload = auth._decode_token(token)
        return CurrentUser(
            id=payload["sub"],
            role=payload["role"],
            is_verified=payload.get("verified", False),
        )
    except Exception:
        return None


@router.post("/route", response_model=RouteResponse)
async def compute_route(
    payload: RouteRequest,
    request: Request,
    db: Session = Depends(get_db),
):
    speed_kmh = SPEED_KMH[payload.mode]
    points: list[Coordinate] = [payload.origin, *payload.waypoints, payload.destination]

    # Legs stay as straight-line summaries between the requested points; the
    # turn-by-turn road shape lives in `polyline`.
    legs: list[RouteLeg] = [_leg(start, end, speed_kmh) for start, end in zip(points, points[1:])]

    routed = await road_route(points, payload.mode)
    if routed is not None:
        polyline, total_distance_km, total_duration_minutes = routed
    else:
        polyline = points
        total_distance_km = sum(leg.distance_km for leg in legs)
        total_duration_minutes = sum(leg.duration_minutes for leg in legs)

    voice_locale = get_voice_locale(payload.language)

    current_user = _try_get_current_user(request)
    if current_user is not None:
        history = RouteHistory(
            user_id=current_user.id,
            origin_lat=payload.origin.lat,
            origin_lng=payload.origin.lng,
            destination_lat=payload.destination.lat,
            destination_lng=payload.destination.lng,
            mode=TravelMode(payload.mode),
            distance_km=total_distance_km,
            duration_minutes=total_duration_minutes,
        )
        db.add(history)
        db.commit()

    return RouteResponse(
        distance_km=total_distance_km,
        duration_minutes=total_duration_minutes,
        legs=legs,
        polyline=polyline,
        voice_locale=voice_locale,
    )


@router.post("/optimize", response_model=OptimizeResponse)
async def optimize_stops(
    payload: OptimizeRequest,
    current_user: CurrentUser = Depends(get_current_user),
):
    speed_kmh = SPEED_KMH["driving"]

    remaining = list(payload.stops)
    ordered_stops: list[OptimizeStop] = []
    current_point = Coordinate(lat=payload.origin.lat, lng=payload.origin.lng)

    while remaining:
        nearest_index = min(
            range(len(remaining)),
            key=lambda i: haversine_km(
                current_point.lat, current_point.lng, remaining[i].lat, remaining[i].lng
            ),
        )
        nearest = remaining.pop(nearest_index)
        ordered_stops.append(nearest)
        current_point = Coordinate(lat=nearest.lat, lng=nearest.lng)

    legs: list[RouteLeg] = []
    current_point = Coordinate(lat=payload.origin.lat, lng=payload.origin.lng)
    for stop in ordered_stops:
        stop_point = Coordinate(lat=stop.lat, lng=stop.lng)
        legs.append(_leg(current_point, stop_point, speed_kmh))
        current_point = stop_point

    total_distance_km = sum(leg.distance_km for leg in legs)
    total_duration_minutes = sum(leg.duration_minutes for leg in legs)

    return OptimizeResponse(
        ordered_stops=ordered_stops,
        legs=legs,
        total_distance_km=total_distance_km,
        total_duration_minutes=total_duration_minutes,
    )


@router.get("/voice-locales", response_model=dict[str, str])
async def voice_locales():
    return VOICE_LOCALES


@router.get("/history/me", response_model=list[RouteHistoryResponse])
async def my_route_history(
    limit: int = Query(default=50, ge=1, le=200),
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    return (
        db.query(RouteHistory)
        .filter(RouteHistory.user_id == current_user.id)
        .order_by(RouteHistory.created_at.desc())
        .limit(limit)
        .all()
    )
