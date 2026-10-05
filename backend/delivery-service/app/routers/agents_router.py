from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.orm import Session

from app.auth import CurrentUser, get_current_user, require_roles
from app.database import get_db
from app.models import DeliveryAgentProfile
from app.schemas import (
    AgentAvailabilityUpdateRequest,
    AgentLocationUpdateRequest,
    AgentPerformanceResponse,
    AgentProfileResponse,
    AgentProfileUpsertRequest,
)

router = APIRouter(prefix="/delivery/agents", tags=["delivery-agents"])

require_delivery_agent = require_roles("delivery_agent")


def _get_profile_or_404(db: Session, user_id: str) -> DeliveryAgentProfile:
    profile = (
        db.query(DeliveryAgentProfile)
        .filter(DeliveryAgentProfile.user_id == user_id)
        .first()
    )
    if profile is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND, detail="Delivery agent profile not found"
        )
    return profile


@router.post("/profile", response_model=AgentProfileResponse)
async def upsert_profile(
    payload: AgentProfileUpsertRequest,
    current_user: CurrentUser = Depends(require_delivery_agent),
    db: Session = Depends(get_db),
):
    profile = (
        db.query(DeliveryAgentProfile)
        .filter(DeliveryAgentProfile.user_id == current_user.id)
        .first()
    )
    if profile is None:
        profile = DeliveryAgentProfile(
            user_id=current_user.id,
            vehicle_type=payload.vehicle_type,
            license_plate=payload.license_plate,
            is_available=False,
        )
        db.add(profile)
    else:
        profile.vehicle_type = payload.vehicle_type
        profile.license_plate = payload.license_plate

    db.commit()
    db.refresh(profile)
    return profile


@router.get("/me", response_model=AgentProfileResponse)
async def get_my_profile(
    current_user: CurrentUser = Depends(require_delivery_agent),
    db: Session = Depends(get_db),
):
    return _get_profile_or_404(db, current_user.id)


@router.patch("/me/location", response_model=AgentProfileResponse)
async def update_my_location(
    payload: AgentLocationUpdateRequest,
    current_user: CurrentUser = Depends(require_delivery_agent),
    db: Session = Depends(get_db),
):
    profile = _get_profile_or_404(db, current_user.id)
    profile.current_lat = payload.lat
    profile.current_lng = payload.lng
    db.commit()
    db.refresh(profile)
    return profile


@router.patch("/me/availability", response_model=AgentProfileResponse)
async def update_my_availability(
    payload: AgentAvailabilityUpdateRequest,
    current_user: CurrentUser = Depends(require_delivery_agent),
    db: Session = Depends(get_db),
):
    profile = _get_profile_or_404(db, current_user.id)

    if payload.is_available and not current_user.is_verified:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail=(
                "Your delivery agent account must be verified by an admin "
                "before you can go available"
            ),
        )

    profile.is_available = payload.is_available
    db.commit()
    db.refresh(profile)
    return profile


@router.get("", response_model=list[AgentProfileResponse])
async def list_agents(
    is_available: bool | None = Query(default=None),
    current_user: CurrentUser = Depends(require_roles("admin")),
    db: Session = Depends(get_db),
):
    query = db.query(DeliveryAgentProfile)
    if is_available is not None:
        query = query.filter(DeliveryAgentProfile.is_available == is_available)
    return query.order_by(DeliveryAgentProfile.created_at.desc()).all()


@router.get("/{agent_user_id}/performance", response_model=AgentPerformanceResponse)
async def get_agent_performance(
    agent_user_id: str,
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    if current_user.role != "admin" and current_user.id != agent_user_id:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="You do not have permission to view this agent's performance",
        )

    profile = _get_profile_or_404(db, agent_user_id)
    return AgentPerformanceResponse(
        agent_user_id=profile.user_id,
        total_deliveries=profile.total_deliveries,
        rating_avg=profile.rating_avg,
        rating_count=profile.rating_count,
    )
