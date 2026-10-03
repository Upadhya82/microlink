from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field

from app.models import TravelMode


class Coordinate(BaseModel):
    lat: float = Field(ge=-90, le=90)
    lng: float = Field(ge=-180, le=180)


class RouteRequest(BaseModel):
    origin: Coordinate
    destination: Coordinate
    waypoints: list[Coordinate] = []
    mode: Literal["driving", "walking", "cycling"] = "driving"
    language: str = "en"


class RouteLeg(BaseModel):
    model_config = ConfigDict(populate_by_name=True)

    from_: Coordinate = Field(alias="from")
    to: Coordinate
    distance_km: float
    duration_minutes: float


class RouteResponse(BaseModel):
    distance_km: float
    duration_minutes: float
    legs: list[RouteLeg]
    polyline: list[Coordinate]
    voice_locale: str


class OptimizeStop(BaseModel):
    lat: float = Field(ge=-90, le=90)
    lng: float = Field(ge=-180, le=180)
    label: str


class OptimizeRequest(BaseModel):
    origin: Coordinate
    stops: list[OptimizeStop]


class OptimizeResponse(BaseModel):
    ordered_stops: list[OptimizeStop]
    legs: list[RouteLeg]
    total_distance_km: float
    total_duration_minutes: float


class RouteHistoryResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    user_id: str
    origin_lat: float
    origin_lng: float
    destination_lat: float
    destination_lng: float
    mode: TravelMode
    distance_km: float
    duration_minutes: float
    created_at: datetime
