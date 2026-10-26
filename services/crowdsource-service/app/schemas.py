from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator

from app.models import RoadConditionType, RoadReportSeverity, RoadReportStatus, ShopReportStatus


# --- Order feedback -----------------------------------------------------


class OrderFeedbackCreateRequest(BaseModel):
    order_id: str = Field(min_length=1, max_length=36)
    rating: int = Field(ge=1, le=5)
    comment: str = Field(default="", max_length=2000)
    shop_id: str | None = None


class OrderFeedbackResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    order_id: str
    user_id: str
    rating: int
    comment: str
    created_at: datetime
    shop_id: str | None = None


# --- Road condition reports ----------------------------------------------


class RoadConditionReportCreateRequest(BaseModel):
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)
    condition_type: RoadConditionType
    description: str = Field(default="", max_length=2000)
    severity: RoadReportSeverity = RoadReportSeverity.medium


class RoadConditionReportStatusUpdateRequest(BaseModel):
    status: Literal["verified", "resolved", "rejected"]
    reason: str | None = None


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
    has_photo: bool = False


class NewShopReportCreateRequest(BaseModel):
    shop_name: str = Field(min_length=1, max_length=150)
    category: str = Field(min_length=1, max_length=60)
    address: str = Field(default="", max_length=300)
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)
    description: str = Field(default="", max_length=2000)
    phone: str | None = Field(default=None, max_length=30)
    opening_time: str | None = Field(default=None, max_length=10)
    closing_time: str | None = Field(default=None, max_length=10)


class NewShopReportStatusUpdateRequest(BaseModel):
    status: Literal["approved", "rejected"]
    reason: str | None = None


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
    phone: str | None = None
    opening_time: str | None = None
    closing_time: str | None = None
    status: ShopReportStatus
    has_photo: bool = False
    # One field for the app to read, whether or not a photo was uploaded.
    photo_path: str | None = None
    # How many nearby people answered "is this shop really there?", and how
    # many said yes. Shown next to the report so a reviewer can see what the
    # share is based on rather than just the percentage.
    responses: int = 0
    confirmations: int = 0
    confirmed_ratio: float = 0.0
    is_confirmed: bool = False
    comments: list[str] = []
    comments_detail: list[dict] = []
    # The phone number belongs to this MicroLink account, so the suggestion
    # went straight to the admins (fast_track) without asking neighbours.
    phone_user_id: str | None = None
    phone_user_name: str | None = None
    fast_track: bool = False
    created_at: datetime
    updated_at: datetime

    @model_validator(mode="after")
    def _derive_photo_path(self):
        if self.has_photo:
            self.photo_path = f"/crowdsource/shop-reports/{self.id}/photo"
        self.fast_track = bool(self.phone_user_id)
        return self


class ApprovedSuggestionResponse(BaseModel):
    """A user-suggested shop an admin approved, for the "User Suggestions" rail on Home.

    Deliberately leaves out who suggested it and what neighbours commented:
    every customer sees this list, and those belong to the moderation desk.
    """

    model_config = ConfigDict(from_attributes=True)

    id: str
    shop_name: str
    category: str
    address: str
    latitude: float
    longitude: float
    description: str
    phone: str | None = None
    opening_time: str | None = None
    closing_time: str | None = None
    has_photo: bool = False
    photo_path: str | None = None
    # When the admin approved it (the report's last change was the approval).
    approved_at: datetime
    # Set when the app sent its location.
    distance_km: float | None = None

    @model_validator(mode="after")
    def _derive_photo_path(self):
        if self.has_photo:
            self.photo_path = f"/crowdsource/shop-reports/{self.id}/photo"
        return self


# --- Trust score -----------------------------------------------------------


class TrustScoreResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    user_id: str
    score: float
    total_reports: int
    validated_reports: int
    updated_at: datetime
    # Item 7: whether this account may confirm somebody else's shop report.
    # Only filled in for /trust-score/me, where the caller's verified flag is
    # known; null elsewhere, which the app reads as "do not know".
    can_confirm_shops: bool | None = None
    min_confirm_trust: int | None = None


# ------------------------------------------------- shop corrections (CROWD-5)
# Only these fields may be suggested. Anything else a client sends is
# ignored rather than rejected, so a newer app cannot break an older server.
CORRECTABLE_FIELDS = ("name", "address", "phone", "opening_time", "closing_time")


class ShopCorrectionCreateRequest(BaseModel):
    shop_id: str = Field(min_length=1, max_length=36)
    shop_name: str | None = Field(default=None, max_length=150)
    name: str | None = Field(default=None, max_length=150)
    address: str | None = Field(default=None, max_length=300)
    phone: str | None = Field(default=None, max_length=30)
    opening_time: str | None = Field(default=None, max_length=10)
    closing_time: str | None = Field(default=None, max_length=10)
    note: str | None = Field(default=None, max_length=300)

    def non_empty_changes(self) -> dict:
        """The suggested fields the user actually filled in."""
        out = {}
        for field in CORRECTABLE_FIELDS:
            value = getattr(self, field, None)
            if isinstance(value, str) and value.strip():
                out[field] = value.strip()
        return out


class ShopCorrectionStatusRequest(BaseModel):
    status: Literal["approved", "rejected"]
    reason: str | None = None


class ShopCorrectionResponse(BaseModel):
    id: str
    reporter_id: str
    shop_id: str
    shop_name: str
    changes: dict
    note: str | None
    status: ShopReportStatus
    created_at: datetime
    updated_at: datetime


class ShopReportConfirmRequest(BaseModel):
    """One person's answer about a reported shop."""

    confirms: bool
    comment: str | None = Field(default=None, max_length=500)
