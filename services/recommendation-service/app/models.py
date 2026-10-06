import enum
import uuid
from datetime import datetime, timezone

from sqlalchemy import DateTime, Enum, String, UniqueConstraint
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.database import Base


def _uuid() -> str:
    return str(uuid.uuid4())


def _now() -> datetime:
    return datetime.now(timezone.utc)


class InteractionType(str, enum.Enum):
    view = "view"
    click = "click"
    order = "order"
    favorite = "favorite"


class Interaction(Base):
    __tablename__ = "interactions"

    id: Mapped[str] = mapped_column(UUID(as_uuid=False), primary_key=True, default=_uuid)
    user_id: Mapped[str] = mapped_column(String(36), index=True, nullable=False)
    shop_id: Mapped[str] = mapped_column(String(36), index=True, nullable=False)
    interaction_type: Mapped[InteractionType] = mapped_column(
        Enum(InteractionType, name="interaction_type"), nullable=False
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=_now, index=True
    )


class Dismissal(Base):
    __tablename__ = "dismissals"
    __table_args__ = (UniqueConstraint("user_id", "shop_id", name="uq_dismissal_user_shop"),)

    id: Mapped[str] = mapped_column(UUID(as_uuid=False), primary_key=True, default=_uuid)
    user_id: Mapped[str] = mapped_column(String(36), index=True, nullable=False)
    shop_id: Mapped[str] = mapped_column(String(36), index=True, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)


class Favorite(Base):
    """A user's saved/favorited shop -- same shape as [Dismissal] (one row
    per user+shop, unique), just the opposite signal. Separate from
    [Interaction]'s `favorite` type, which only ever accumulates rows and
    has no "unfavorite"; this table is the real toggle backing the heart
    button on Shop Detail."""

    __tablename__ = "favorites"
    __table_args__ = (UniqueConstraint("user_id", "shop_id", name="uq_favorite_user_shop"),)

    id: Mapped[str] = mapped_column(UUID(as_uuid=False), primary_key=True, default=_uuid)
    user_id: Mapped[str] = mapped_column(String(36), index=True, nullable=False)
    shop_id: Mapped[str] = mapped_column(String(36), index=True, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=_now)
