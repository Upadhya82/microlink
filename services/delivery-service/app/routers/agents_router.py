from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.orm import Session

from app.auth import CurrentUser, get_current_user, require_roles
from app.database import get_db
from app.event_bus import publish_event
from app.models import DeliveryAgentProfile, Order
from app.schemas import (
    AgentAvailabilityUpdateRequest,
    AgentLocationUpdateRequest,
    AgentPerformanceResponse,
    AgentProfileResponse,
    AgentProfileUpsertRequest,
    AgentReviewRequest,
)
from app.scoring import on_time_percentage, performance_score

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
    """SRS REQ-AGENT-1: submit vehicle, phone and the documents the admin
    checks (ID, driver's licence photo, police report). Fields that are left
    out are kept as they were, so the agent can add documents later."""
    profile = (
        db.query(DeliveryAgentProfile)
        .filter(DeliveryAgentProfile.user_id == current_user.id)
        .first()
    )
    if profile is None:
        profile = DeliveryAgentProfile(user_id=current_user.id, is_available=False)
        db.add(profile)

    profile.vehicle_type = payload.vehicle_type
    profile.license_plate = payload.license_plate
    # Sending the details again after a rejection puts the application back in
    # the admin's queue.
    if profile.application_status == "rejected":
        profile.application_status = "pending"
        profile.review_note = None
        profile.reviewed_at = None
    for field in ("phone", "id_document_url", "license_photo_url", "police_report_url"):
        value = getattr(payload, field)
        if value is not None:
            setattr(profile, field, value)

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
    application_status: str | None = Query(default=None, pattern="^(pending|approved|rejected)$"),
    current_user: CurrentUser = Depends(require_roles("admin")),
    db: Session = Depends(get_db),
):
    """Admin: all agents with the documents they submitted (to review them)."""
    query = db.query(DeliveryAgentProfile)
    if is_available is not None:
        query = query.filter(DeliveryAgentProfile.is_available == is_available)
    if application_status is not None:
        query = query.filter(DeliveryAgentProfile.application_status == application_status)
    return query.order_by(DeliveryAgentProfile.created_at.desc()).all()


@router.get("/{agent_user_id}/performance", response_model=AgentPerformanceResponse)
async def get_agent_performance(
    agent_user_id: str,
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """SRS REQ-AGENT-5. The agent and admins may read it, and so may a customer
    who has an order with that agent (the tracking screen shows the rating)."""
    if current_user.role != "admin" and current_user.id != agent_user_id:
        has_order_together = (
            db.query(Order.id)
            .filter(Order.agent_id == agent_user_id, Order.customer_id == current_user.id)
            .first()
        )
        if has_order_together is None:
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
        on_time_deliveries=profile.on_time_deliveries,
        on_time_percentage=on_time_percentage(profile.on_time_deliveries, profile.total_deliveries),
        performance_score=performance_score(
            profile.rating_avg,
            profile.rating_count,
            profile.on_time_deliveries,
            profile.total_deliveries,
        ),
    )


@router.get("/{agent_user_id}", response_model=AgentProfileResponse)
async def get_agent_for_admin(
    agent_user_id: str,
    current_user: CurrentUser = Depends(require_roles("admin")),
    db: Session = Depends(get_db),
):
    """Admin: open one agent's full application (SRS "Verify Delivery Agent Identity")."""
    return _get_profile_or_404(db, agent_user_id)


@router.patch("/{agent_user_id}/review", response_model=AgentProfileResponse)
async def review_agent_application(
    agent_user_id: str,
    payload: AgentReviewRequest,
    current_user: CurrentUser = Depends(require_roles("admin")),
    db: Session = Depends(get_db),
):
    """SRS use case "Verify Delivery Agent Identity": the admin records the
    decision here. To let an approved agent actually work, the admin app also
    calls user-service `PATCH /users/{id}/verify` (that is what sets the
    `verified` flag in the agent's login token)."""
    profile = _get_profile_or_404(db, agent_user_id)
    profile.application_status = payload.decision
    profile.review_note = payload.reason.strip() if payload.reason else None
    profile.reviewed_at = datetime.now(timezone.utc)
    db.commit()
    db.refresh(profile)

    await publish_event(
        "agent.reviewed",
        {
            "agent_user_id": profile.user_id,
            "decision": payload.decision,
            "reviewed_by": current_user.id,
        },
    )
    return profile
