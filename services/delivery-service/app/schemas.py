import json
from datetime import datetime
from typing import Literal

from pydantic import (
    BaseModel,
    ConfigDict,
    Field,
    computed_field,
    field_validator,
    model_validator,
)

from app.geo import haversine_km
from app.models import VehicleType


def _check_link(value: str | None) -> str | None:
    """Documents are stored as links (there is no file-upload service yet)."""
    if value is None:
        return None
    value = value.strip()
    if value == "":
        return None
    if not value.lower().startswith(("http://", "https://")):
        raise ValueError("must be a link that starts with http:// or https://")
    return value


def _check_pair(lat: float | None, lng: float | None, label: str) -> None:
    if (lat is None) != (lng is None):
        raise ValueError(f"{label} latitude and longitude must be given together")


# ----------------------------------------------------------------- agents


class AgentProfileUpsertRequest(BaseModel):
    """SRS REQ-AGENT-1: vehicle + contact + the documents the admin reviews."""

    vehicle_type: Literal["bike", "scooter", "car", "van"]
    license_plate: str | None = Field(default=None, max_length=30)
    phone: str | None = Field(default=None, pattern=r"^\+?[0-9][0-9 \-]{6,18}$")
    id_document_url: str | None = Field(default=None, max_length=500)
    license_photo_url: str | None = Field(default=None, max_length=500)
    police_report_url: str | None = Field(default=None, max_length=500)

    @field_validator("id_document_url", "license_photo_url", "police_report_url")
    @classmethod
    def _links_only(cls, value: str | None) -> str | None:
        return _check_link(value)


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
    phone: str | None = None
    id_document_url: str | None = None
    license_photo_url: str | None = None
    police_report_url: str | None = None
    application_status: str = "pending"
    review_note: str | None = None
    reviewed_at: datetime | None = None
    current_lat: float | None
    current_lng: float | None
    is_available: bool
    rating_avg: float
    rating_count: int
    total_deliveries: int
    on_time_deliveries: int = 0
    created_at: datetime
    updated_at: datetime
    distance_km: float | None = None

    @computed_field  # type: ignore[prop-decorator]
    @property
    def documents_complete(self) -> bool:
        """True when everything REQ-AGENT-1 asks for has been submitted."""
        return all(
            [self.phone, self.id_document_url, self.license_photo_url, self.police_report_url]
        )


class AgentReviewRequest(BaseModel):
    """Admin decision on an agent application (SRS: approve, or reject WITH a reason)."""

    decision: Literal["approved", "rejected"]
    reason: str | None = Field(default=None, max_length=300)

    @model_validator(mode="after")
    def _rejection_needs_a_reason(self):
        if self.decision == "rejected" and not (self.reason and self.reason.strip()):
            raise ValueError("a reason is required when rejecting an application")
        return self


class AgentPerformanceResponse(BaseModel):
    """SRS REQ-AGENT-5: average rating, on-time %, total deliveries, score."""

    agent_user_id: str
    total_deliveries: int
    rating_avg: float
    rating_count: int
    on_time_deliveries: int = 0
    on_time_percentage: float | None = None
    performance_score: float | None = None


# ----------------------------------------------------------------- orders


class OrderCreateRequest(BaseModel):
    """SRS REQ-DELIV-2: pickup (editable), drop, optional note (max 200).
    REQ-DELIV-3: no cart and no payment -- `total_amount` is only the fee the
    customer OFFERS the agent (may be 0, settled outside the app)."""

    shop_id: str
    delivery_address: str = Field(min_length=1, max_length=300)
    delivery_lat: float = Field(ge=-90, le=90)
    delivery_lng: float = Field(ge=-180, le=180)
    pickup_address: str | None = Field(default=None, max_length=300)
    pickup_lat: float | None = Field(default=None, ge=-90, le=90)
    pickup_lng: float | None = Field(default=None, ge=-180, le=180)
    item_description: str | None = Field(default=None, max_length=200)
    total_amount: float = Field(default=0.0, ge=0)
    items: list[dict] = Field(default_factory=list)

    @model_validator(mode="after")
    def _pickup_is_a_pair(self):
        _check_pair(self.pickup_lat, self.pickup_lng, "pickup")
        return self


class OrderStatusUpdateRequest(BaseModel):
    status: Literal["accepted", "picked_up", "in_transit", "delivered", "cancelled"]
    # The agent's GPS at the moment of the tap (used for the geofence check).
    lat: float | None = Field(default=None, ge=-90, le=90)
    lng: float | None = Field(default=None, ge=-180, le=180)

    @model_validator(mode="after")
    def _position_is_a_pair(self):
        _check_pair(self.lat, self.lng, "agent position")
        return self


class OrderRejectRequest(BaseModel):
    # "declined" = the agent tapped Reject. "timeout" = the 30 s timer ran out.
    reason: Literal["declined", "timeout"] = "declined"


class OrderRejectResponse(BaseModel):
    order_id: str
    reason: str
    hidden_until: datetime | None = None


class NotifyCustomerRequest(BaseModel):
    lat: float | None = Field(default=None, ge=-90, le=90)
    lng: float | None = Field(default=None, ge=-180, le=180)

    @model_validator(mode="after")
    def _position_is_a_pair(self):
        _check_pair(self.lat, self.lng, "agent position")
        return self


class NotifyCustomerResponse(BaseModel):
    order_id: str
    eta_minutes: int
    message: str


class OrderRateRequest(BaseModel):
    rating: int = Field(ge=1, le=5)
    comment: str | None = Field(default=None, max_length=300)


class OrderResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    customer_id: str
    shop_id: str
    agent_id: str | None
    items: list[dict]
    pickup_address: str | None = None
    pickup_lat: float | None = None
    pickup_lng: float | None = None
    delivery_address: str
    delivery_lat: float
    delivery_lng: float
    item_description: str | None = None
    status: str
    total_amount: float
    accepted_at: datetime | None = None
    picked_up_at: datetime | None = None
    delivered_at: datetime | None = None
    promised_by: datetime | None = None
    agent_eta_minutes: int | None = None
    agent_notified_at: datetime | None = None
    rating: int | None = None
    rating_comment: str | None = None
    created_at: datetime
    updated_at: datetime
    # Filled in by the server, not stored: distance from the asking agent to
    # the pickup point (available-orders list) and shop -> customer distance.
    distance_km: float | None = None
    trip_distance_km: float | None = None

    @field_validator("items", mode="before")
    @classmethod
    def _parse_items(cls, value):
        if isinstance(value, str):
            return json.loads(value)
        return value

    @classmethod
    def from_model(cls, order) -> "OrderResponse":
        response = cls.model_validate(order)
        if order.pickup_lat is not None and order.pickup_lng is not None:
            response.trip_distance_km = round(
                haversine_km(
                    order.pickup_lat, order.pickup_lng, order.delivery_lat, order.delivery_lng
                ),
                2,
            )
        return response


class OrderEventResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    order_id: str
    status: str
    created_at: datetime


class OrderDetailResponse(OrderResponse):
    events: list[OrderEventResponse] = Field(default_factory=list)
