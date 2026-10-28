import enum
import uuid
from datetime import datetime, timezone

from sqlalchemy import Boolean, DateTime, Enum, Float, ForeignKey, Integer, LargeBinary, String
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.database import Base


def _uuid() -> str:
    return str(uuid.uuid4())


def _now() -> datetime:
    return datetime.now(timezone.utc)


class UserRole(str, enum.Enum):
    user = "user"
    shop_owner = "shop_owner"
    delivery_agent = "delivery_agent"
    admin = "admin"


class User(Base):
    __tablename__ = "users"

    id: Mapped[str] = mapped_column(UUID(as_uuid=False), primary_key=True, default=_uuid)
    email: Mapped[str] = mapped_column(String(255), unique=True, index=True, nullable=False)
    hashed_password: Mapped[str] = mapped_column(String(255), nullable=False)
    full_name: Mapped[str] = mapped_column(String(120), nullable=False)
    phone: Mapped[str | None] = mapped_column(String(30), nullable=True)
    # Shop owners only: the trading name an admin sees when reviewing the
    # application, which is not necessarily the applicant's own name.
    business_name: Mapped[str | None] = mapped_column(String(120), nullable=True)
    role: Mapped[UserRole] = mapped_column(
        Enum(UserRole, name="user_role"), default=UserRole.user, nullable=False
    )
    is_verified: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    # Why an admin turned a shop owner / delivery agent application down.
    # The column was added by run_light_migrations but never mapped here, so
    # the reason was set on the object, returned once, and never saved --
    # the applicant had no way to find out why. Cleared on approval.
    rejection_reason: Mapped[str | None] = mapped_column(String(300), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=_now, onupdate=_now
    )

    preferences: Mapped["UserPreferences | None"] = relationship(
        back_populates="user", uselist=False, cascade="all, delete-orphan"
    )


class UserPreferences(Base):
    __tablename__ = "user_preferences"

    id: Mapped[str] = mapped_column(UUID(as_uuid=False), primary_key=True, default=_uuid)
    user_id: Mapped[str] = mapped_column(
        UUID(as_uuid=False), ForeignKey("users.id"), unique=True, nullable=False
    )
    preferred_categories: Mapped[str] = mapped_column(String(500), default="")
    max_distance_km: Mapped[float] = mapped_column(Float, default=5.0)
    notifications_enabled: Mapped[bool] = mapped_column(Boolean, default=True)
    language: Mapped[str] = mapped_column(String(10), default="en")

    user: Mapped["User"] = relationship(back_populates="preferences")


class UserDocument(Base):
    """A verification document a shop owner or delivery agent uploaded.

    REQ-AGENT-1 (ID, driving licence, police clearance, vehicle registration)
    and REQ-ADMIN-1/2 (the admin reviewing them before approving the
    account). Stored in Postgres for the same reason shop photos are: there
    is no object storage in this deployment, and these are a handful of
    compressed images or small PDFs per user.
    """

    __tablename__ = "user_documents"

    id: Mapped[str] = mapped_column(UUID(as_uuid=False), primary_key=True, default=_uuid)
    user_id: Mapped[str] = mapped_column(
        UUID(as_uuid=False), ForeignKey("users.id"), nullable=False, index=True
    )
    doc_type: Mapped[str] = mapped_column(String(40), nullable=False)
    file_name: Mapped[str] = mapped_column(String(255), default="")
    content_type: Mapped[str] = mapped_column(String(100), default="image/jpeg")
    # Deferred: listing a user's documents must not drag every file into
    # memory just to render a list of names.
    data: Mapped[bytes] = mapped_column(LargeBinary, nullable=False, deferred=True)
    size_bytes: Mapped[int] = mapped_column(Integer, default=0)
    note: Mapped[str | None] = mapped_column(String(300), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
