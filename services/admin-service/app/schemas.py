import json
from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator

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


class AdCreateRequest(BaseModel):
    advertiser_name: str = Field(min_length=1, max_length=150)
    title: str = Field(min_length=1, max_length=150)
    subtitle: str = Field(default="", max_length=300)
    image_url: str = Field(min_length=1, max_length=500)
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
    status: AdStatus
    start_date: datetime | None
    end_date: datetime | None
    reviewed_by: str | None
    created_at: datetime
    updated_at: datetime
