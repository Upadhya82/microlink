import enum
import uuid
from datetime import datetime, timezone

from sqlalchemy import Boolean, DateTime, Enum, Float, LargeBinary, String, Text
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.database import Base


def _uuid() -> str:
    return str(uuid.uuid4())


def _now() -> datetime:
    return datetime.now(timezone.utc)


class ComplaintCategory(str, enum.Enum):
    shop = "shop"
    delivery = "delivery"
    agent = "agent"
    other = "other"


class ComplaintStatus(str, enum.Enum):
    open = "open"
    in_review = "in_review"
    resolved = "resolved"
    dismissed = "dismissed"


class ActivityLog(Base):
    __tablename__ = "activity_logs"

    id: Mapped[str] = mapped_column(UUID(as_uuid=False), primary_key=True, default=_uuid)
    event_type: Mapped[str] = mapped_column(String(150), index=True, nullable=False)
    source_service: Mapped[str] = mapped_column(String(100), index=True, nullable=False)
    payload: Mapped[str] = mapped_column(Text, default="{}")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now, index=True)


class Notification(Base):
    """One in-app notification for one user (the use-case diagram's "View
    Notifications", available to every role).

    Rows are written by the event-bus subscriber in app/activity.py, never by
    a request handler -- any service that wants to notify someone publishes a
    `notify.users` event through its own event_bus.notify_users() helper.
    `link` is a small JSON object stored as text ({"route": "order", "id":
    "..."}) that tells the app where tapping the row should go; it is Text
    rather than JSON so a malformed hint can never break the insert.
    """

    __tablename__ = "notifications"

    id: Mapped[str] = mapped_column(UUID(as_uuid=False), primary_key=True, default=_uuid)
    user_id: Mapped[str] = mapped_column(String(36), index=True, nullable=False)
    title: Mapped[str] = mapped_column(String(200), nullable=False)
    body: Mapped[str] = mapped_column(Text, default="")
    kind: Mapped[str] = mapped_column(String(40), default="general", nullable=False)
    link: Mapped[str] = mapped_column(Text, default="{}")
    is_read: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False, index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now, index=True)


class Complaint(Base):
    __tablename__ = "complaints"

    id: Mapped[str] = mapped_column(UUID(as_uuid=False), primary_key=True, default=_uuid)
    complainant_id: Mapped[str] = mapped_column(String(36), index=True, nullable=False)
    subject: Mapped[str] = mapped_column(String(200), nullable=False)
    description: Mapped[str] = mapped_column(Text, nullable=False)
    category: Mapped[ComplaintCategory] = mapped_column(
        Enum(ComplaintCategory, name="complaint_category"),
        default=ComplaintCategory.other,
        nullable=False,
    )
    status: Mapped[ComplaintStatus] = mapped_column(
        Enum(ComplaintStatus, name="complaint_status"),
        default=ComplaintStatus.open,
        nullable=False,
    )
    admin_response: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=_now, onupdate=_now
    )


class SubscriptionPlan(Base):
    __tablename__ = "subscription_plans"

    id: Mapped[str] = mapped_column(UUID(as_uuid=False), primary_key=True, default=_uuid)
    name: Mapped[str] = mapped_column(String(150), nullable=False)
    description: Mapped[str] = mapped_column(Text, default="")
    price_monthly: Mapped[float] = mapped_column(Float, nullable=False)
    features: Mapped[str] = mapped_column(Text, default="[]")
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


class AdStatus(str, enum.Enum):
    pending = "pending"
    approved = "approved"
    rejected = "rejected"


class Advertisement(Base):
    """A paid shop/company banner shown on the customer Home screen.

    Anyone (a shop owner, or an external company with no MicroLink account
    of their own) can be the subject of an ad, but submission always goes
    through an authenticated user -- `submitted_by_user_id` is who sent it
    in, `shop_id` is optional since a submission may promote a shop the
    submitter doesn't own, or an outside company with no shop at all.
    """

    __tablename__ = "advertisements"

    id: Mapped[str] = mapped_column(UUID(as_uuid=False), primary_key=True, default=_uuid)
    shop_id: Mapped[str | None] = mapped_column(String(36), index=True, nullable=True)
    advertiser_name: Mapped[str] = mapped_column(String(150), nullable=False)
    submitted_by_user_id: Mapped[str] = mapped_column(String(36), index=True, nullable=False)
    title: Mapped[str] = mapped_column(String(150), nullable=False)
    subtitle: Mapped[str] = mapped_column(String(300), default="")
    # Either a link the advertiser gave, or an image they uploaded. The
    # uploaded bytes win when both are present.
    image_url: Mapped[str] = mapped_column(String(500), default="")
    image: Mapped[bytes | None] = mapped_column(LargeBinary, nullable=True, deferred=True)
    has_image: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    status: Mapped[AdStatus] = mapped_column(
        Enum(AdStatus, name="ad_status"), default=AdStatus.pending, nullable=False
    )
    start_date: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    end_date: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    reviewed_by: Mapped[str | None] = mapped_column(String(36), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=_now, onupdate=_now
    )
