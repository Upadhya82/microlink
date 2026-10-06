"""Request and response shapes for shop-service.

Compatibility rule: every field that existed before is still here with the
same name and type, so the other members' screens and services (home screen,
live map, owner dashboard, recommendation-service, smoke test) keep working.
New fields are all optional or have defaults.
"""

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator

from app.models import ShopCategory

ShopStatusLiteral = Literal["open", "closed", "temporarily_closed"]
StockStatusLiteral = Literal["in_stock", "low_stock", "out_of_stock"]
AlertTypeLiteral = Literal["general", "closure", "relocation", "special_offer"]


# ------------------------------------------------------------------ shops
class ShopCreateRequest(BaseModel):
    name: str = Field(min_length=1, max_length=150)
    description: str = Field(default="", max_length=2000)
    category: ShopCategory = ShopCategory.other
    address: str = Field(default="", max_length=300)
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)
    phone: str | None = Field(default=None, max_length=30)
    image_url: str | None = Field(default=None, max_length=500)
    opening_time: str = Field(default="09:00", max_length=5)
    closing_time: str = Field(default="18:00", max_length=5)
    delivery_available: bool = False
    # Optional extra photos (REQ-SHOP-1, at most 10 in total).
    photos: list[str] = Field(default_factory=list, max_length=10)


class ShopUpdateRequest(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=150)
    description: str | None = Field(default=None, max_length=2000)
    category: ShopCategory | None = None
    address: str | None = Field(default=None, max_length=300)
    latitude: float | None = Field(default=None, ge=-90, le=90)
    longitude: float | None = Field(default=None, ge=-180, le=180)
    phone: str | None = Field(default=None, max_length=30)
    image_url: str | None = Field(default=None, max_length=500)
    opening_time: str | None = Field(default=None, max_length=5)
    closing_time: str | None = Field(default=None, max_length=5)
    delivery_available: bool | None = None


class ShopStatusUpdateRequest(BaseModel):
    """Old clients send {"is_open": true}. New clients can send a full status."""

    is_open: bool | None = None
    status: ShopStatusLiteral | None = None
    reason: str | None = Field(default=None, max_length=200)
    reopen_at: datetime | None = None

    @model_validator(mode="after")
    def _need_one(self):
        if self.is_open is None and self.status is None:
            raise ValueError("Send either is_open or status.")
        return self


class ShopPhotoCreateRequest(BaseModel):
    url: str = Field(min_length=8, max_length=500)


class ShopPhotoResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    shop_id: str
    url: str
    position: int


class ShopResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    # --- fields that already existed (do not rename or retype) ---
    id: str
    owner_id: str
    name: str
    description: str
    category: ShopCategory
    address: str
    latitude: float
    longitude: float
    phone: str | None
    image_url: str | None
    opening_time: str
    closing_time: str
    is_open: bool
    rating_avg: float
    rating_count: int
    created_at: datetime
    updated_at: datetime
    distance_km: float | None = None

    # --- new, all optional ---
    status: str | None = None
    status_reason: str | None = None
    reopen_at: datetime | None = None
    delivery_available: bool = False
    photos: list[str] = Field(default_factory=list)
    trust_score: float = 0.0  # same number as rating_avg, named as in the SRS
    # Product availability indicators (REQ-SEARCH-4)
    product_count: int = 0
    in_stock_count: int = 0
    low_stock_count: int = 0
    out_of_stock_count: int = 0
    availability: str = "none"  # none | all_in_stock | limited | all_out
    matched_product: str | None = None  # set when the search text matched a product name


class LandmarkInfo(BaseModel):
    query: str
    name: str
    latitude: float
    longitude: float
    source: str  # "openstreetmap" or "builtin"


class LandmarkSearchResponse(BaseModel):
    landmark: LandmarkInfo
    radius_km: float
    shops: list[ShopResponse]


# ----------------------------------------------------------------- alerts
class ShopAlertCreateRequest(BaseModel):
    message: str = Field(min_length=1, max_length=300)
    alert_type: AlertTypeLiteral = "general"
    new_address: str | None = Field(default=None, max_length=300)
    starts_at: datetime | None = None
    ends_at: datetime | None = None

    @model_validator(mode="after")
    def _check(self):
        if self.alert_type == "relocation" and not (self.new_address or "").strip():
            raise ValueError("A relocation alert needs the new address.")
        if self.starts_at and self.ends_at and self.ends_at < self.starts_at:
            raise ValueError("The end date must be after the start date.")
        return self


class ShopAlertResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    shop_id: str
    message: str
    is_active: bool
    created_at: datetime
    alert_type: str = "general"
    new_address: str | None = None
    starts_at: datetime | None = None
    ends_at: datetime | None = None


# --------------------------------------------------------------- products
class ProductCreateRequest(BaseModel):
    name: str = Field(min_length=1, max_length=150)
    description: str = Field(default="", max_length=2000)
    price: float = Field(gt=0)
    # Optional on purpose: the smoke test creates a product without a quantity.
    stock_quantity: int | None = Field(default=None, ge=0)
    category: str = Field(default="", max_length=60)
    stock_status: StockStatusLiteral | None = None
    is_available: bool | None = None


class ProductUpdateRequest(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=150)
    description: str | None = Field(default=None, max_length=2000)
    price: float | None = Field(default=None, gt=0)
    stock_quantity: int | None = Field(default=None, ge=0)
    category: str | None = Field(default=None, max_length=60)
    stock_status: StockStatusLiteral | None = None
    is_available: bool | None = None


class ProductResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    shop_id: str
    name: str
    description: str
    price: float
    stock_quantity: int
    category: str
    is_available: bool
    created_at: datetime
    updated_at: datetime
    stock_status: str = "in_stock"


# ---------------------------------------------------------------- reviews
class RatingCreateRequest(BaseModel):
    rating: int = Field(ge=1, le=5)
    comment: str = Field(default="", max_length=500)


class ReviewReplyRequest(BaseModel):
    reply: str = Field(min_length=1, max_length=500)


class ReviewResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    shop_id: str
    user_id: str
    rating: int
    comment: str
    owner_reply: str | None = None
    replied_at: datetime | None = None
    created_at: datetime


# -------------------------------------------------------------- analytics
class ShopAnalyticsResponse(BaseModel):
    # existing keys (the owner dashboard reads these)
    shop_id: str
    total_views: int
    total_search_impressions: int
    product_count: int
    active_alert_count: int
    views_last_7_days: list[dict]
    # new keys (REQ-SHOP-5)
    average_rating: float = 0.0
    rating_count: int = 0
    stock_summary: dict[str, int] = Field(default_factory=dict)
    peak_hours: list[dict] = Field(default_factory=list)
