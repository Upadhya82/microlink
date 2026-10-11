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
    # Required for picked_up (the shop owner's code) and delivered (the
    # customer's). Ignored for the other transitions.
    code: str | None = Field(default=None, max_length=8)


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
    # Only ever populated for the person who is supposed to read it out.
    pickup_code: str | None = None
    delivery_code: str | None = None
    created_at: datetime
    updated_at: datetime

    @field_validator("items", mode="before")
    @classmethod
    def _parse_items(cls, value):
        if isinstance(value, str):
            return json.loads(value)
        return value

    @classmethod
    def from_model(
        cls,
        order,
        *,
        viewer_id: str | None = None,
        viewer_role: str | None = None,
        is_shop_owner: bool = False,
    ):
        """Build the response, revealing each code only to the person who
        must read it aloud.

        The agent types the codes in, so showing them to the agent would let
        a dishonest one mark an order collected and delivered without ever
        meeting anyone -- which is the whole thing these codes exist to stop.
        """
        response = cls.model_validate(order)
        is_customer = viewer_id is not None and viewer_id == order.customer_id
        is_admin = viewer_role == "admin"
        # The shop owner is identified by shop-service, not here; admins get
        # both for support, and the customer gets their own.
        response.pickup_code = order.pickup_code if (is_admin or is_shop_owner) else None
        response.delivery_code = order.delivery_code if (is_customer or is_admin) else None
        return response


class OrderEventResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    order_id: str
    status: str
    created_at: datetime


class OrderDetailResponse(OrderResponse):
    events: list[OrderEventResponse] = Field(default_factory=list)
