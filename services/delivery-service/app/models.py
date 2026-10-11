import enum
import uuid
from datetime import datetime, timezone

from sqlalchemy import Boolean, DateTime, Enum, Float, ForeignKey, Integer, String, Text
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
    current_lat: Mapped[float | None] = mapped_column(Float, nullable=True)
    current_lng: Mapped[float | None] = mapped_column(Float, nullable=True)
    is_available: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    rating_avg: Mapped[float] = mapped_column(Float, default=0.0)
    rating_count: Mapped[int] = mapped_column(Integer, default=0)
    total_deliveries: Mapped[int] = mapped_column(Integer, default=0)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=_now, onupdate=_now
    )


class Order(Base):
    __tablename__ = "orders"

    id: Mapped[str] = mapped_column(UUID(as_uuid=False), primary_key=True, default=_uuid)
    customer_id: Mapped[str] = mapped_column(String(36), index=True, nullable=False)
    shop_id: Mapped[str] = mapped_column(String(36), index=True, nullable=False)
    agent_id: Mapped[str | None] = mapped_column(String(36), index=True, nullable=True)
    items: Mapped[str] = mapped_column(Text, nullable=False)
    delivery_address: Mapped[str] = mapped_column(String(300), nullable=False)
    delivery_lat: Mapped[float] = mapped_column(Float, nullable=False)
    delivery_lng: Mapped[float] = mapped_column(Float, nullable=False)
    status: Mapped[OrderStatus] = mapped_column(
        Enum(OrderStatus, name="order_status"), default=OrderStatus.pending, nullable=False
    )
    total_amount: Mapped[float] = mapped_column(Float, nullable=False)
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
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
