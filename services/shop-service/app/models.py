import enum
import uuid
from datetime import datetime, timezone

from sqlalchemy import (
    Boolean,
    DateTime,
    Enum,
    Float,
    ForeignKey,
    Integer,
    String,
    Text,
    UniqueConstraint,
)
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.database import Base


def _uuid() -> str:
    return str(uuid.uuid4())


def _now() -> datetime:
    return datetime.now(timezone.utc)


class ShopCategory(str, enum.Enum):
    grocery = "grocery"
    restaurant = "restaurant"
    pharmacy = "pharmacy"
    electronics = "electronics"
    clothing = "clothing"
    hardware = "hardware"
    stationery = "stationery"
    bakery = "bakery"
    other = "other"


class AnalyticsEventType(str, enum.Enum):
    view = "view"
    search_impression = "search_impression"


class Shop(Base):
    __tablename__ = "shops"

    id: Mapped[str] = mapped_column(UUID(as_uuid=False), primary_key=True, default=_uuid)
    owner_id: Mapped[str] = mapped_column(String(36), index=True, nullable=False)
    name: Mapped[str] = mapped_column(String(150), nullable=False)
    description: Mapped[str] = mapped_column(Text, default="")
    category: Mapped[ShopCategory] = mapped_column(
        Enum(ShopCategory, name="shop_category"), default=ShopCategory.other, nullable=False
    )
    address: Mapped[str] = mapped_column(String(300), default="")
    latitude: Mapped[float] = mapped_column(Float, nullable=False)
    longitude: Mapped[float] = mapped_column(Float, nullable=False)
    phone: Mapped[str | None] = mapped_column(String(30), nullable=True)
    # Cover photo. Kept so the other members' screens that only know one image still work.
    image_url: Mapped[str | None] = mapped_column(String(500), nullable=True)
    opening_time: Mapped[str] = mapped_column(String(5), default="09:00")
    closing_time: Mapped[str] = mapped_column(String(5), default="18:00")

    # `is_open` is the old true/false flag the other members' code reads.
    # `status` is the SRS version (open / closed / temporarily_closed). The
    # service always keeps the two in step: is_open == (status == "open").
    is_open: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    status: Mapped[str] = mapped_column(String(20), default="open")
    status_reason: Mapped[str | None] = mapped_column(String(200), nullable=True)
    reopen_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    delivery_available: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)

    # Trust score. Recomputed from `shop_ratings` (last 90 days) - see app/ratings.py.
    rating_avg: Mapped[float] = mapped_column(Float, default=0.0)
    rating_count: Mapped[int] = mapped_column(Integer, default=0)

    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=_now, onupdate=_now
    )

    alerts: Mapped[list["ShopAlert"]] = relationship(
        back_populates="shop", cascade="all, delete-orphan"
    )
    products: Mapped[list["Product"]] = relationship(
        back_populates="shop", cascade="all, delete-orphan"
    )
    photo_rows: Mapped[list["ShopPhoto"]] = relationship(
        back_populates="shop", cascade="all, delete-orphan", order_by="ShopPhoto.position"
    )
    rating_rows: Mapped[list["ShopRating"]] = relationship(
        back_populates="shop", cascade="all, delete-orphan"
    )


class ShopPhoto(Base):
    """One extra photo of a shop (SRS REQ-SHOP-1 allows up to 10)."""

    __tablename__ = "shop_photos"

    id: Mapped[str] = mapped_column(UUID(as_uuid=False), primary_key=True, default=_uuid)
    shop_id: Mapped[str] = mapped_column(
        UUID(as_uuid=False), ForeignKey("shops.id"), nullable=False, index=True
    )
    url: Mapped[str] = mapped_column(String(500), nullable=False)
    position: Mapped[int] = mapped_column(Integer, default=0)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)

    shop: Mapped["Shop"] = relationship(back_populates="photo_rows")


class ShopRating(Base):
    """A customer's rating of a shop: one row per (shop, user)."""

    __tablename__ = "shop_ratings"
    __table_args__ = (UniqueConstraint("shop_id", "user_id", name="uq_shop_ratings_shop_user"),)

    id: Mapped[str] = mapped_column(UUID(as_uuid=False), primary_key=True, default=_uuid)
    shop_id: Mapped[str] = mapped_column(
        UUID(as_uuid=False), ForeignKey("shops.id"), nullable=False, index=True
    )
    user_id: Mapped[str] = mapped_column(String(36), index=True, nullable=False)
    rating: Mapped[int] = mapped_column(Integer, nullable=False)
    comment: Mapped[str] = mapped_column(Text, default="")
    # REQ-SHOP-6: the owner may reply once to each review.
    owner_reply: Mapped[str | None] = mapped_column(Text, nullable=True)
    replied_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=_now, onupdate=_now
    )

    shop: Mapped["Shop"] = relationship(back_populates="rating_rows")


class ShopAlert(Base):
    __tablename__ = "shop_alerts"

    id: Mapped[str] = mapped_column(UUID(as_uuid=False), primary_key=True, default=_uuid)
    shop_id: Mapped[str] = mapped_column(
        UUID(as_uuid=False), ForeignKey("shops.id"), nullable=False, index=True
    )
    message: Mapped[str] = mapped_column(String(300), nullable=False)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    # REQ-SHOP-3: general / closure / relocation / special_offer
    alert_type: Mapped[str] = mapped_column(String(20), default="general")
    new_address: Mapped[str | None] = mapped_column(String(300), nullable=True)
    starts_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    ends_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)

    shop: Mapped["Shop"] = relationship(back_populates="alerts")


class Product(Base):
    __tablename__ = "products"

    id: Mapped[str] = mapped_column(UUID(as_uuid=False), primary_key=True, default=_uuid)
    shop_id: Mapped[str] = mapped_column(
        UUID(as_uuid=False), ForeignKey("shops.id"), nullable=False, index=True
    )
    name: Mapped[str] = mapped_column(String(150), nullable=False)
    description: Mapped[str] = mapped_column(Text, default="")
    price: Mapped[float] = mapped_column(Float, nullable=False)
    stock_quantity: Mapped[int] = mapped_column(Integer, default=0)
    category: Mapped[str] = mapped_column(String(60), default="")
    # `is_available` is the old true/false flag. `stock_status` is the SRS
    # version (in_stock / low_stock / out_of_stock). Kept in step by the service.
    is_available: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    stock_status: Mapped[str] = mapped_column(String(20), default="in_stock")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=_now, onupdate=_now
    )

    shop: Mapped["Shop"] = relationship(back_populates="products")


class ShopAnalyticsEvent(Base):
    __tablename__ = "shop_analytics_events"

    id: Mapped[str] = mapped_column(UUID(as_uuid=False), primary_key=True, default=_uuid)
    shop_id: Mapped[str] = mapped_column(
        UUID(as_uuid=False), ForeignKey("shops.id"), nullable=False, index=True
    )
    event_type: Mapped[AnalyticsEventType] = mapped_column(
        Enum(AnalyticsEventType, name="analytics_event_type"), nullable=False
    )
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now, index=True)
