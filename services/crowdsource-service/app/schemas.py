from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field

from app.models import RoadConditionType, RoadReportSeverity, RoadReportStatus, ShopReportStatus


# --- Order feedback -----------------------------------------------------


class OrderFeedbackCreateRequest(BaseModel):
    order_id: str = Field(min_length=1, max_length=36)
    rating: int = Field(ge=1, le=5)
    comment: str = Field(default="", max_length=2000)


class OrderFeedbackResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    order_id: str
    user_id: str
    rating: int
    comment: str
    created_at: datetime


# --- Road condition reports ----------------------------------------------


class RoadConditionReportCreateRequest(BaseModel):
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)
    condition_type: RoadConditionType
    description: str = Field(default="", max_length=2000)
    severity: RoadReportSeverity = RoadReportSeverity.medium


class RoadConditionReportStatusUpdateRequest(BaseModel):
    status: Literal["verified", "resolved", "rejected"]


class RoadConditionReportResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    reporter_id: str
    latitude: float
    longitude: float
    condition_type: RoadConditionType
    description: str
    severity: RoadReportSeverity
    status: RoadReportStatus
    created_at: datetime
    updated_at: datetime
    distance_km: float | None = None


# --- New shop reports -----------------------------------------------------


class NewShopReportCreateRequest(BaseModel):
    shop_name: str = Field(min_length=1, max_length=150)
    category: str = Field(min_length=1, max_length=60)
    address: str = Field(default="", max_length=300)
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)
    description: str = Field(default="", max_length=2000)


class NewShopReportStatusUpdateRequest(BaseModel):
    status: Literal["approved", "rejected"]


class NewShopReportResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    reporter_id: str
    shop_name: str
    category: str
    address: str
    latitude: float
    longitude: float
    description: str
    status: ShopReportStatus
    created_at: datetime
    updated_at: datetime


# --- Trust score -----------------------------------------------------------


class TrustScoreResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    user_id: str
    score: float
    total_reports: int
    validated_reports: int
    updated_at: datetime
