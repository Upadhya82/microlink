import json
from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator

from app.models import VehicleType


class AgentProfileUpsertRequest(BaseModel):
    vehicle_type: Literal["bike", "scooter", "car", "van"]
    license_plate: str | None = Field(default=None, max_length=30)


class AgentLocationUpdateRequest(BaseModel):
    lat: float = Field(ge=-90, le=90)
    lng: float = Field(ge=-180, le=180)


class AgentAvailabilityUpdateRequest(BaseModel):
    is_available: bool


class AgentProfileResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    user_id: str
    vehicle_type: VehicleType
    license_plate: str | None
    current_lat: float | None
    current_lng: float | None
    is_available: bool
    rating_avg: float
    rating_count: int
    total_deliveries: int
    created_at: datetime
    updated_at: datetime
    distance_km: float | None = None


class AgentPerformanceResponse(BaseModel):
    agent_user_id: str
    total_deliveries: int
    rating_avg: float
    rating_count: int


class OrderCreateRequest(BaseModel):
    shop_id: str
    items: list[dict]
    delivery_address: str = Field(min_length=1, max_length=300)
    delivery_lat: float = Field(ge=-90, le=90)
    delivery_lng: float = Field(ge=-180, le=180)
    total_amount: float = Field(gt=0)


class OrderStatusUpdateRequest(BaseModel):
    status: Literal["accepted", "picked_up", "in_transit", "delivered", "cancelled"]


class OrderResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    customer_id: str
    shop_id: str
    agent_id: str | None
    items: list[dict]
    delivery_address: str
    delivery_lat: float
    delivery_lng: float
    status: str
    total_amount: float
    created_at: datetime
    updated_at: datetime

    @field_validator("items", mode="before")
    @classmethod
    def _parse_items(cls, value):
        if isinstance(value, str):
            return json.loads(value)
        return value

    @classmethod
    def from_model(cls, order) -> "OrderResponse":
        return cls.model_validate(order)


class OrderEventResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    order_id: str
    status: str
    created_at: datetime


class OrderDetailResponse(OrderResponse):
    events: list[OrderEventResponse] = Field(default_factory=list)
