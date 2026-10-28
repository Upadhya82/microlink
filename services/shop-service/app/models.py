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
    LargeBinary,
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
    # When the shop last stopped being open, and what we have already done
    # about a long silence. All three are cleared the moment it reopens.
    closed_since: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    inactivity_prompt_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    inactivity_broadcast_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )

    delivery_available: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    # REQ-ADMIN-1: a shop is listed as soon as it is created, but carries an
    # "unverified" marker until an admin has checked it. Hiding unverified
    # shops entirely would make the crowd-sourced listings useless, so the
    # app shows them with a badge instead.
    is_verified: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False, index=True)
    verified_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    verified_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    # "admin" or "community" -- which of the two routes verified this shop.
    verified_via: Mapped[str | None] = mapped_column(String(20), nullable=True)
    # When an admin last tapped "Leave pending" on it: looked at, not ready
    # (usually too few products), parked with a note. The review queue keeps
    # these out of its main list until the shop becomes ready. A dedicated
    # column rather than "has a status_reason", because an owner closing
    # their own shop with a reason also sets that. Cleared on verification.
    left_pending_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    # Item 10: when the owner was told their verified shop had dropped below
    # the listable-product threshold. Cleared when it climbs back, so the
    # next drop warns them again rather than staying silent forever.
    low_product_warning_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    # Item 4: delivery-service works this out from its own order timestamps
    # and publishes `shop.timeliness`; this service only stores what it is
    # told, so the search path never has to ask another service.
    delay_prone: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    median_pickup_wait_min: Mapped[float | None] = mapped_column(Float, nullable=True)
    timeliness_updated_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )

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
    # For an uploaded photo this is the app-relative path that serves `data`
    # (/shops/{shop_id}/photos/{id}/file); for a linked photo it is the
    # external URL. The app treats both the same -- see mediaUrl() client
    # side -- so screens never need to know which kind they are showing.
    url: Mapped[str] = mapped_column(String(500), nullable=False)
    # Deferred: a shop listing loads ten of these rows and never needs the
    # bytes, so they must not ride along on every query.
    data: Mapped[bytes | None] = mapped_column(LargeBinary, nullable=True, deferred=True)
    content_type: Mapped[str | None] = mapped_column(String(100), nullable=True)
    size_bytes: Mapped[int | None] = mapped_column(Integer, nullable=True)
    position: Mapped[int] = mapped_column(Integer, default=0)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)

    shop: Mapped["Shop"] = relationship(back_populates="photo_rows")


class ShopRating(Base):
    """A customer's rating of a shop: one row per (shop, user, source).

    Item 3: there are two ways a rating arrives. "Rate this shop" on the
    shop page writes source="shop"; the feedback a customer leaves after a
    delivered order arrives over the event bus and writes source="order",
    carrying the order it came from so the app can label it "Verified
    order". The same person may do both, which is why `source` is part of
    the unique key rather than one silently overwriting the other.
    """

    __tablename__ = "shop_ratings"
    __table_args__ = (
        UniqueConstraint(
            "shop_id", "user_id", "source", name="uq_shop_ratings_shop_user_source"
        ),
    )

    id: Mapped[str] = mapped_column(UUID(as_uuid=False), primary_key=True, default=_uuid)
    shop_id: Mapped[str] = mapped_column(
        UUID(as_uuid=False), ForeignKey("shops.id"), nullable=False, index=True
    )
    user_id: Mapped[str] = mapped_column(String(36), index=True, nullable=False)
    rating: Mapped[int] = mapped_column(Integer, nullable=False)
    comment: Mapped[str] = mapped_column(Text, default="")
    # "shop" = typed on the shop page, "order" = feedback after a delivery.
    source: Mapped[str] = mapped_column(String(20), default="shop", nullable=False)
    # Set for source="order": which delivered order the feedback came from.
    order_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
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
    # Percentage off, 0-90. Stored rather than a second "sale price" column
    # so the original price is never lost and "was Rs.X" stays truthful.
    discount_percent: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    stock_quantity: Mapped[int] = mapped_column(Integer, default=0)
    category: Mapped[str] = mapped_column(String(60), default="")
    # Product photo, same storage approach as shop photos. Deferred so a
    # product list never drags every image into memory.
    image: Mapped[bytes | None] = mapped_column(LargeBinary, nullable=True, deferred=True)
    has_image: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    # `is_available` is the old true/false flag. `stock_status` is the SRS
    # version (in_stock / low_stock / out_of_stock). Kept in step by the service.
    is_available: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    stock_status: Mapped[str] = mapped_column(String(20), default="in_stock")
    # Hidden products are left out of everything customers see. Set
    # automatically when a customer buys the last item (hidden_reason
    # "sold_out"); only the owner clears it, with "Unhide" on their dashboard.
    # A sold-out hide is also undone when the order that caused it is
    # cancelled, because the item is back on the shelf.
    is_hidden: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    hidden_reason: Mapped[str | None] = mapped_column(String(20), nullable=True)
    # Whether the owner has been told this product is running low since it
    # last had more than `low_stock_threshold` in stock. Lets a product that
    # was added with 5 or fewer still get its one warning on the first sale,
    # without repeating it on every sale after that.
    low_stock_notified: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
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


class StockReservation(Base):
    """Stock held for one order line, from checkout until the order ends.

    delivery-service reserves before it saves an order, so two customers can
    never be sold the same last item, and releases on every cancellation
    path. One row per (order, product): that is what makes reserving twice
    (a double tap, a network retry) a no-op rather than a double deduction.
    `released_at` is set instead of deleting the row, so a second release
    returns nothing.
    """

    __tablename__ = "stock_reservations"
    __table_args__ = (
        UniqueConstraint("order_id", "product_id", name="uq_stock_reservations_order_product"),
    )

    id: Mapped[str] = mapped_column(UUID(as_uuid=False), primary_key=True, default=_uuid)
    # Orders live in delivery-service's database, so this is deliberately not
    # a foreign key -- each service owns its own tables.
    order_id: Mapped[str] = mapped_column(String(36), index=True, nullable=False)
    shop_id: Mapped[str] = mapped_column(
        UUID(as_uuid=False), ForeignKey("shops.id"), nullable=False, index=True
    )
    # Cascades: if the owner deletes the product the held stock goes with it,
    # rather than the delete failing on a row delivery-service owns.
    product_id: Mapped[str] = mapped_column(
        UUID(as_uuid=False),
        ForeignKey("products.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    quantity: Mapped[int] = mapped_column(Integer, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    released_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )


class ProductCategory(Base):
    """One of the predefined product categories a shop owner picks from.

    Seeded with a default list on first start (app/product_categories.py);
    an admin adds more, usually by accepting a category owners typed under
    "Others". `slug` is what a product stores in its `category` column.
    """

    __tablename__ = "product_categories"

    id: Mapped[str] = mapped_column(UUID(as_uuid=False), primary_key=True, default=_uuid)
    slug: Mapped[str] = mapped_column(String(60), unique=True, index=True, nullable=False)
    label: Mapped[str] = mapped_column(String(80), nullable=False)
    is_default: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    created_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


class DismissedProductCategory(Base):
    """An "Others" category an admin looked at and chose not to add.

    Keeps it out of the review list; the products keep their category.
    """

    __tablename__ = "dismissed_product_categories"

    id: Mapped[str] = mapped_column(UUID(as_uuid=False), primary_key=True, default=_uuid)
    name_key: Mapped[str] = mapped_column(String(150), unique=True, index=True, nullable=False)
    dismissed_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    dismissed_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


class ShopExistenceConfirmation(Base):
    """One nearby customer vouching that a registered shop really is there.

    Enough of these verify the shop without an admin (see app/community.py).
    The confirmer's own position is kept, not just the distance, so a
    confirmation can be audited later if a shop turns out not to exist --
    the distance alone could not be checked again once the shop moved.

    One row per (shop, user): the unique key is what makes "three
    confirmations" mean three people rather than one person tapping thrice.
    """

    __tablename__ = "shop_existence_confirmations"
    __table_args__ = (
        UniqueConstraint("shop_id", "user_id", name="uq_shop_confirmation_shop_user"),
    )

    id: Mapped[str] = mapped_column(UUID(as_uuid=False), primary_key=True, default=_uuid)
    shop_id: Mapped[str] = mapped_column(
        UUID(as_uuid=False), ForeignKey("shops.id"), nullable=False, index=True
    )
    user_id: Mapped[str] = mapped_column(String(36), index=True, nullable=False)
    latitude: Mapped[float] = mapped_column(Float, nullable=False)
    longitude: Mapped[float] = mapped_column(Float, nullable=False)
    distance_km: Mapped[float] = mapped_column(Float, nullable=False)
    trust_score: Mapped[float | None] = mapped_column(Float, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
