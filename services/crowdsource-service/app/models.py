import enum
import uuid
from datetime import datetime, timezone

from sqlalchemy import DateTime, Enum, Float, Integer, String, Text
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.database import Base


def _uuid() -> str:
    return str(uuid.uuid4())


def _now() -> datetime:
    return datetime.now(timezone.utc)


class RoadConditionType(str, enum.Enum):
    pothole = "pothole"
    flooding = "flooding"
    construction = "construction"
    accident = "accident"
    blocked = "blocked"
    other = "other"


class RoadReportSeverity(str, enum.Enum):
    low = "low"
    medium = "medium"
    high = "high"


class RoadReportStatus(str, enum.Enum):
    pending = "pending"
    verified = "verified"
    resolved = "resolved"
    rejected = "rejected"


class ShopReportStatus(str, enum.Enum):
    pending = "pending"
    approved = "approved"
    rejected = "rejected"


class OrderFeedback(Base):
    __tablename__ = "order_feedback"

    id: Mapped[str] = mapped_column(UUID(as_uuid=False), primary_key=True, default=_uuid)
    order_id: Mapped[str] = mapped_column(String(36), index=True, nullable=False)
    user_id: Mapped[str] = mapped_column(String(36), index=True, nullable=False)
    rating: Mapped[int] = mapped_column(Integer, nullable=False)
    comment: Mapped[str] = mapped_column(Text, default="")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


class RoadConditionReport(Base):
    __tablename__ = "road_condition_reports"

    id: Mapped[str] = mapped_column(UUID(as_uuid=False), primary_key=True, default=_uuid)
    reporter_id: Mapped[str] = mapped_column(String(36), index=True, nullable=False)
    latitude: Mapped[float] = mapped_column(Float, nullable=False)
    longitude: Mapped[float] = mapped_column(Float, nullable=False)
    condition_type: Mapped[RoadConditionType] = mapped_column(
        Enum(RoadConditionType, name="road_condition_type"), nullable=False
    )
    description: Mapped[str] = mapped_column(Text, default="")
    severity: Mapped[RoadReportSeverity] = mapped_column(
        Enum(RoadReportSeverity, name="road_report_severity"),
        default=RoadReportSeverity.medium,
        nullable=False,
    )
    status: Mapped[RoadReportStatus] = mapped_column(
        Enum(RoadReportStatus, name="road_report_status"),
        default=RoadReportStatus.pending,
        nullable=False,
    )
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=_now, onupdate=_now
    )


class NewShopReport(Base):
    __tablename__ = "new_shop_reports"

    id: Mapped[str] = mapped_column(UUID(as_uuid=False), primary_key=True, default=_uuid)
    reporter_id: Mapped[str] = mapped_column(String(36), index=True, nullable=False)
    shop_name: Mapped[str] = mapped_column(String(150), nullable=False)
    category: Mapped[str] = mapped_column(String(60), nullable=False)
    address: Mapped[str] = mapped_column(String(300), default="")
    latitude: Mapped[float] = mapped_column(Float, nullable=False)
    longitude: Mapped[float] = mapped_column(Float, nullable=False)
    description: Mapped[str] = mapped_column(Text, default="")
    status: Mapped[ShopReportStatus] = mapped_column(
        Enum(ShopReportStatus, name="shop_report_status"),
        default=ShopReportStatus.pending,
        nullable=False,
    )
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=_now, onupdate=_now
    )


class UserTrustScore(Base):
    __tablename__ = "user_trust_scores"

    id: Mapped[str] = mapped_column(UUID(as_uuid=False), primary_key=True, default=_uuid)
    user_id: Mapped[str] = mapped_column(String(36), unique=True, index=True, nullable=False)
    score: Mapped[float] = mapped_column(Float, default=50.0, nullable=False)
    total_reports: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    validated_reports: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=_now, onupdate=_now
    )
