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
from sqlalchemy.orm import Mapped, mapped_column

from app.database import Base


def _uuid() -> str:
    return str(uuid.uuid4())


def _now() -> datetime:
    return datetime.now(timezone.utc)


class VehicleType(str, enum.Enum):
    bike = "bike"
    scooter = "scooter"
    car = "car"
    van = "van"


class OrderStatus(str, enum.Enum):
    pending = "pending"
    accepted = "accepted"
    picked_up = "picked_up"
    in_transit = "in_transit"
    delivered = "delivered"
    cancelled = "cancelled"


class DeliveryAgentProfile(Base):
    __tablename__ = "delivery_agent_profiles"

    id: Mapped[str] = mapped_column(UUID(as_uuid=False), primary_key=True, default=_uuid)
    user_id: Mapped[str] = mapped_column(String(36), unique=True, index=True, nullable=False)
    vehicle_type: Mapped[VehicleType] = mapped_column(
        Enum(VehicleType, name="vehicle_type"), nullable=False
    )
    license_plate: Mapped[str | None] = mapped_column(String(30), nullable=True)

    # SRS REQ-AGENT-1: registration details the admin reviews before approval.
    phone: Mapped[str | None] = mapped_column(String(20), nullable=True)
    id_document_url: Mapped[str | None] = mapped_column(String(500), nullable=True)
    license_photo_url: Mapped[str | None] = mapped_column(String(500), nullable=True)
    police_report_url: Mapped[str | None] = mapped_column(String(500), nullable=True)

    # SRS use case "Verify Delivery Agent Identity": the admin approves or
    # rejects (with a reason). The login permission itself (the `verified`
    # token flag) still lives in user-service.
    application_status: Mapped[str] = mapped_column(
        String(20), default="pending", server_default="pending", nullable=False
    )
    review_note: Mapped[str | None] = mapped_column(String(300), nullable=True)
    reviewed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    current_lat: Mapped[float | None] = mapped_column(Float, nullable=True)
    current_lng: Mapped[float | None] = mapped_column(Float, nullable=True)
    # Item 13: when that position was last shared. The available-orders list
    # is filtered against it, so a driver seeing an empty list has to be told
    # how old it is -- a stale position is why Colombo orders went missing.
    location_updated_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    is_available: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)

    # SRS REQ-AGENT-5: performance profile.
    rating_avg: Mapped[float] = mapped_column(Float, default=0.0)
    rating_count: Mapped[int] = mapped_column(Integer, default=0)
    total_deliveries: Mapped[int] = mapped_column(Integer, default=0)
    on_time_deliveries: Mapped[int] = mapped_column(Integer, default=0, nullable=False)

    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=_now, onupdate=_now
    )


class Order(Base):
    """One delivery request. (SRS: "Request Delivery Assistance" -- no cart and
    no payment. `total_amount` holds the fee the customer offers the agent, it
    is NOT charged by the system.)"""

    __tablename__ = "orders"

    id: Mapped[str] = mapped_column(UUID(as_uuid=False), primary_key=True, default=_uuid)
    customer_id: Mapped[str] = mapped_column(String(36), index=True, nullable=False)
    shop_id: Mapped[str] = mapped_column(String(36), index=True, nullable=False)
    agent_id: Mapped[str | None] = mapped_column(String(36), index=True, nullable=True)
    items: Mapped[str] = mapped_column(Text, nullable=False)

    # SRS REQ-DELIV-2: pickup (pre-filled with the shop, editable), drop, note.
    pickup_address: Mapped[str | None] = mapped_column(String(300), nullable=True)
    pickup_lat: Mapped[float | None] = mapped_column(Float, nullable=True)
    pickup_lng: Mapped[float | None] = mapped_column(Float, nullable=True)
    delivery_address: Mapped[str] = mapped_column(String(300), nullable=False)
    delivery_lat: Mapped[float] = mapped_column(Float, nullable=False)
    delivery_lng: Mapped[float] = mapped_column(Float, nullable=False)
    item_description: Mapped[str | None] = mapped_column(String(200), nullable=True)

    status: Mapped[OrderStatus] = mapped_column(
        Enum(OrderStatus, name="order_status"), default=OrderStatus.pending, nullable=False
    )
    total_amount: Mapped[float] = mapped_column(Float, nullable=False, default=0.0)

    # Item 8: who cancelled, and why. NULL on orders cancelled before this
    # shipped, which is honest -- nobody recorded it -- and those count
    # towards neither the customer's limit nor a shop's cancellation streak.
    # "customer" | "shop" | "admin" | "system" (the unclaimed-order sweep).
    cancelled_by: Mapped[str | None] = mapped_column(String(20), nullable=True)
    cancel_reason: Mapped[str | None] = mapped_column(String(200), nullable=True)
    cancelled_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )

    # Item 12: shop-service holds this order's stock between these two
    # timestamps. `stock_reserved_at` with no `stock_released_at` on a
    # cancelled order means the shop is still holding stock for an order that
    # no longer exists, which the expiry sweep retries.
    stock_reserved_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    stock_released_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )

    accepted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    # When an agent last handed this order back to the pool. The wait for an
    # agent is counted from here rather than `created_at` once it is set,
    # otherwise a released order is old enough for the unclaimed sweep to
    # cancel it the moment the next agent could have seen it.
    reopened_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    # When the customer was told that nobody had taken the order yet. Set so
    # the sweep tells them once rather than every thirty seconds, and cleared
    # when an agent hands the order back, because the waiting starts again.
    unclaimed_notice_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    picked_up_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    delivered_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    # Set when an agent accepts; used to decide "on-time" when it is delivered.
    promised_by: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)

    # SRS REQ-AGENT-4: "Notify Customer" with an ETA.
    agent_eta_minutes: Mapped[int | None] = mapped_column(Integer, nullable=True)
    agent_notified_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )

    # SRS REQ-AGENT-5 / 5.6.2: the customer rates the agent after delivery.
    rating: Mapped[int | None] = mapped_column(Integer, nullable=True)
    rating_comment: Mapped[str | None] = mapped_column(String(300), nullable=True)
    rated_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    # Handover verification (two codes, two moments):
    #   pickup_code   shown to the SHOP OWNER, typed in by the agent at collection
    #   delivery_code shown to the CUSTOMER,   typed in by the agent at handover
    # Each one proves the agent physically met that person, which a status
    # button alone cannot. Never returned to the agent -- see OrderResponse.
    pickup_code: Mapped[str | None] = mapped_column(String(8), nullable=True)
    delivery_code: Mapped[str | None] = mapped_column(String(8), nullable=True)

    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=_now, onupdate=_now
    )


class OrderEvent(Base):
    __tablename__ = "order_events"

    id: Mapped[str] = mapped_column(UUID(as_uuid=False), primary_key=True, default=_uuid)
    order_id: Mapped[str] = mapped_column(
        UUID(as_uuid=False), ForeignKey("orders.id"), nullable=False, index=True
    )
    status: Mapped[str] = mapped_column(String(30), nullable=False)
    # Where the agent was when they pressed the button (audit trail, SRS 6.2).
    agent_lat: Mapped[float | None] = mapped_column(Float, nullable=True)
    agent_lng: Mapped[float | None] = mapped_column(Float, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


class OrderRejection(Base):
    """SRS "Accept / Reject Order": an agent turned this offer down (or let the
    30-second timer run out), so it must disappear from THAT agent's list.
    `hidden_until` is empty for a real reject (hidden for good) and a time for
    a timeout (hidden for a few minutes, then it comes back)."""

    __tablename__ = "order_rejections"
    __table_args__ = (UniqueConstraint("order_id", "agent_id", name="uq_rejection_order_agent"),)

    id: Mapped[str] = mapped_column(UUID(as_uuid=False), primary_key=True, default=_uuid)
    order_id: Mapped[str] = mapped_column(
        UUID(as_uuid=False), ForeignKey("orders.id"), nullable=False, index=True
    )
    agent_id: Mapped[str] = mapped_column(String(36), index=True, nullable=False)
    reason: Mapped[str] = mapped_column(String(20), nullable=False, default="declined")
    hidden_until: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
