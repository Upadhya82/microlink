import json
from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from app.models import AdStatus, ComplaintCategory, ComplaintStatus


class ActivityLogResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    event_type: str
    source_service: str
    payload: dict
    created_at: datetime

    @field_validator("payload", mode="before")
    @classmethod
    def _parse_payload(cls, value):
        if isinstance(value, str):
            try:
                return json.loads(value)
            except (TypeError, ValueError):
                return {}
        return value


class ComplaintCreateRequest(BaseModel):
    subject: str = Field(min_length=1, max_length=200)
    description: str = Field(min_length=1, max_length=3000)
    category: Literal["shop", "delivery", "agent", "other"] = "other"


class ComplaintUpdateRequest(BaseModel):
    status: Literal["open", "in_review", "resolved", "dismissed"]
    admin_response: str | None = None


class ComplaintResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    complainant_id: str
    subject: str
    description: str
    category: ComplaintCategory
    status: ComplaintStatus
    admin_response: str | None
    created_at: datetime
    updated_at: datetime


class SubscriptionPlanCreateRequest(BaseModel):
    name: str = Field(min_length=1, max_length=150)
    description: str = Field(default="", max_length=2000)
    price_monthly: float = Field(ge=0)
    features: list[str] = Field(default_factory=list)


class SubscriptionPlanUpdateRequest(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=150)
    description: str | None = Field(default=None, max_length=2000)
    price_monthly: float | None = Field(default=None, ge=0)
    features: list[str] | None = None
    is_active: bool | None = None


class SubscriptionPlanResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    name: str
    description: str
    price_monthly: float
    features: list[str]
    is_active: bool
    created_at: datetime

    @field_validator("features", mode="before")
    @classmethod
    def _parse_features(cls, value):
        if isinstance(value, str):
            try:
                return json.loads(value)
            except (TypeError, ValueError):
                return []
        return value


class AnalyticsOverviewResponse(BaseModel):
    total_events: int
    events_by_type: dict[str, int]
    events_last_30_days: list[dict]
    # REQ-ADMIN-6
    users_by_role: dict[str, int] = {}
    total_users: int = 0
    daily_active_users: int = 0
    orders_today: int = 0
    orders_this_week: int = 0
    orders_this_month: int = 0
    revenue_delivered: float = 0.0
    average_delivery_minutes: float | None = None
    top_searches: list[dict] = []


class ServiceHealth(BaseModel):
    name: str
    healthy: bool
    status_code: int | None = None
    latency_ms: int | None = None


class MonitorResponse(BaseModel):
    """REQ-ADMIN-4: the live system activity monitor."""

    generated_at: datetime
    active_users: int
    active_window_minutes: int
    orders_per_minute: float
    orders_last_hour: int
    events_last_hour: int
    load_average_1m: float | None = None
    cpu_count: int | None = None
    memory_used_percent: float | None = None
    recent_errors: list[dict] = []
    services: list[ServiceHealth] = []
    service_name: str = "admin-service"


class AdCreateRequest(BaseModel):
    advertiser_name: str = Field(min_length=1, max_length=150)
    title: str = Field(min_length=1, max_length=150)
    subtitle: str = Field(default="", max_length=300)
    # Optional now: an advertiser normally uploads the banner instead of
    # finding a public link for it.
    image_url: str = Field(default="", max_length=500)
    shop_id: str | None = None
    start_date: datetime | None = None
    end_date: datetime | None = None


class AdReviewUpdateRequest(BaseModel):
    """Lets an admin polish an ad's content to match the advertiser's brand
    before approving it -- separate from the approve/reject decision itself."""

    advertiser_name: str | None = Field(default=None, min_length=1, max_length=150)
    title: str | None = Field(default=None, min_length=1, max_length=150)
    subtitle: str | None = Field(default=None, max_length=300)
    image_url: str | None = Field(default=None, min_length=1, max_length=500)
    start_date: datetime | None = None
    end_date: datetime | None = None


class AdStatusUpdateRequest(BaseModel):
    status: Literal["pending", "approved", "rejected"]


class AdResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    shop_id: str | None
    advertiser_name: str
    submitted_by_user_id: str
    title: str
    subtitle: str
    image_url: str
    has_image: bool = False
    # Where the uploaded banner is served from, so the app has one field to
    # read whether the advertiser uploaded a file or gave a link.
    image_path: str | None = None
    status: AdStatus
    start_date: datetime | None
    end_date: datetime | None
    reviewed_by: str | None
    created_at: datetime
    updated_at: datetime

    @model_validator(mode="after")
    def _derive_image_path(self):
        if self.has_image:
            self.image_path = f"/ads/{self.id}/image"
        return self


class NotificationResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    user_id: str
    title: str
    body: str
    kind: str
    link: dict
    is_read: bool
    created_at: datetime

    @field_validator("link", mode="before")
    @classmethod
    def _parse_link(cls, value):
        # Stored as JSON text (see models.Notification) so a bad hint from a
        # publishing service can never break reading the row back.
        if isinstance(value, str):
            try:
                parsed = json.loads(value)
            except (TypeError, ValueError):
                return {}
            return parsed if isinstance(parsed, dict) else {}
        return value or {}


class UnreadCountResponse(BaseModel):
    unread: int


class MarkAllReadResponse(BaseModel):
    updated: int
