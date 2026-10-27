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
    # Nullable so rows written before this column existed stay valid. Without
    # it shop-service's feedback.submitted listener has no shop to score.
    shop_id: Mapped[str | None] = mapped_column(String(36), index=True, nullable=True)
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
    # REQ-CROWD-4: an optional photo of the blocked / flooded road. Deferred
    # so listing reports on the map never drags the images along.
    photo: Mapped[bytes | None] = mapped_column(LargeBinary, nullable=True, deferred=True)
    has_photo: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
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
    phone: Mapped[str | None] = mapped_column(String(30), nullable=True)
    opening_time: Mapped[str | None] = mapped_column(String(10), nullable=True)
    closing_time: Mapped[str | None] = mapped_column(String(10), nullable=True)
    status: Mapped[ShopReportStatus] = mapped_column(
        Enum(ShopReportStatus, name="shop_report_status"),
        default=ShopReportStatus.pending,
        nullable=False,
    )
    # Which shop an approval actually produced, so a redelivered
    # shop_report.approved event cannot create the same shop twice.
    created_shop_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    # Set when the phone number given belongs to a MicroLink account: the
    # suggestion then goes straight to the admins ("fast track") instead of
    # asking the neighbours to confirm it.
    phone_user_id: Mapped[str | None] = mapped_column(String(36), nullable=True)
    # A photo of the shop front helps the admin decide without visiting.
    photo: Mapped[bytes | None] = mapped_column(LargeBinary, nullable=True, deferred=True)
    has_photo: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
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


class ShopCorrectionReport(Base):
    """REQ-CROWD-5: a user suggesting a fix to an existing shop's details.

    `changes` is JSON text rather than columns because the set of correctable
    fields is shop-service's business, not ours -- it applies whichever of
    them it recognises when the correction is approved.
    """

    __tablename__ = "shop_correction_reports"

    id: Mapped[str] = mapped_column(UUID(as_uuid=False), primary_key=True, default=_uuid)
    reporter_id: Mapped[str] = mapped_column(String(36), index=True, nullable=False)
    shop_id: Mapped[str] = mapped_column(String(36), index=True, nullable=False)
    shop_name: Mapped[str] = mapped_column(String(150), default="")
    changes: Mapped[str] = mapped_column(Text, default="{}")
    note: Mapped[str | None] = mapped_column(String(300), nullable=True)
    status: Mapped[ShopReportStatus] = mapped_column(
        Enum(ShopReportStatus, name="shop_report_status"),
        default=ShopReportStatus.pending,
        nullable=False,
    )
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=_now, onupdate=_now
    )


class ShopReportConfirmation(Base):
    """One nearby customer's answer to "does this shop really exist?".

    A single person reporting a shop is a claim; several people nearby
    agreeing is evidence. The administrator is only asked to look once
    enough of the answers are positive, which keeps made-up and mistaken
    reports off the review queue.

    One row per person per report, so nobody can vote a report through on
    their own by answering repeatedly.
    """

    __tablename__ = "shop_report_confirmations"
    __table_args__ = (UniqueConstraint("report_id", "user_id", name="uq_report_user"),)

    id: Mapped[str] = mapped_column(UUID(as_uuid=False), primary_key=True, default=_uuid)
    report_id: Mapped[str] = mapped_column(
        UUID(as_uuid=False), ForeignKey("new_shop_reports.id"), nullable=False, index=True
    )
    user_id: Mapped[str] = mapped_column(String(36), nullable=False, index=True)
    # True = "yes, this shop is there", False = "no, there is nothing here".
    confirms: Mapped[bool] = mapped_column(Boolean, nullable=False)
    comment: Mapped[str | None] = mapped_column(String(500), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


class ShopReportCommentReply(Base):
    """A reply to a neighbour's comment on a shop suggestion.

    Any signed-in user can reply, so people who did not confirm the shop can
    still join the conversation. Plain id columns rather than foreign keys,
    so tidying up old reports or comments never trips over a reply.
    """

    __tablename__ = "shop_report_comment_replies"

    id: Mapped[str] = mapped_column(UUID(as_uuid=False), primary_key=True, default=_uuid)
    report_id: Mapped[str] = mapped_column(String(36), nullable=False, index=True)
    # The ShopReportConfirmation (the comment) this answers.
    comment_id: Mapped[str] = mapped_column(String(36), nullable=False, index=True)
    user_id: Mapped[str] = mapped_column(String(36), nullable=False, index=True)
    text: Mapped[str] = mapped_column(String(500), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


class SuggestionCommentReply(Base):
    """A reply to a neighbour's comment on a shop suggestion.

    Any signed-in user can reply, on pending and approved suggestions alike,
    so a conversation can grow under each comment ("It opens at 7, not 8").
    """

    __tablename__ = "suggestion_comment_replies"

    id: Mapped[str] = mapped_column(UUID(as_uuid=False), primary_key=True, default=_uuid)
    report_id: Mapped[str] = mapped_column(
        UUID(as_uuid=False), ForeignKey("new_shop_reports.id"), nullable=False, index=True
    )
    # The comment (a confirmation row with text) this answers.
    comment_id: Mapped[str] = mapped_column(
        UUID(as_uuid=False), ForeignKey("shop_report_confirmations.id"), nullable=False, index=True
    )
    user_id: Mapped[str] = mapped_column(String(36), nullable=False, index=True)
    text: Mapped[str] = mapped_column(String(500), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


class SuggestionGeneralComment(Base):
    """A comment anyone signed in can leave on a shop suggestion.

    Separate from ShopReportConfirmation (one "is it there?" answer per
    neighbour, with an optional comment): this is open discussion. A row
    with `parent_id` set is a reply to another general comment.
    """

    __tablename__ = "suggestion_general_comments"

    id: Mapped[str] = mapped_column(UUID(as_uuid=False), primary_key=True, default=_uuid)
    report_id: Mapped[str] = mapped_column(
        UUID(as_uuid=False), ForeignKey("new_shop_reports.id"), nullable=False, index=True
    )
    parent_id: Mapped[str | None] = mapped_column(String(36), nullable=True, index=True)
    user_id: Mapped[str] = mapped_column(String(36), nullable=False, index=True)
    text: Mapped[str] = mapped_column(String(500), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
