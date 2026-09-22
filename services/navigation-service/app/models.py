import enum
import uuid
from datetime import datetime, timezone

from sqlalchemy import DateTime, Enum, Float, String
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.database import Base


def _uuid() -> str:
    return str(uuid.uuid4())


def _now() -> datetime:
    return datetime.now(timezone.utc)


class TravelMode(str, enum.Enum):
    driving = "driving"
    walking = "walking"
    cycling = "cycling"


class RouteHistory(Base):
    __tablename__ = "route_history"

    id: Mapped[str] = mapped_column(UUID(as_uuid=False), primary_key=True, default=_uuid)
    user_id: Mapped[str] = mapped_column(String(36), index=True, nullable=False)
    origin_lat: Mapped[float] = mapped_column(Float, nullable=False)
    origin_lng: Mapped[float] = mapped_column(Float, nullable=False)
    destination_lat: Mapped[float] = mapped_column(Float, nullable=False)
    destination_lng: Mapped[float] = mapped_column(Float, nullable=False)
    mode: Mapped[TravelMode] = mapped_column(
        Enum(TravelMode, name="travel_mode"), default=TravelMode.driving, nullable=False
    )
    distance_km: Mapped[float] = mapped_column(Float, nullable=False)
    duration_minutes: Mapped[float] = mapped_column(Float, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=_now, index=True
    )
