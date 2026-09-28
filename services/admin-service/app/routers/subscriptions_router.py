import json

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session

from app.auth import CurrentUser, require_admin
from app.database import get_db
from app.models import SubscriptionPlan
from app.schemas import (
    SubscriptionPlanCreateRequest,
    SubscriptionPlanResponse,
    SubscriptionPlanUpdateRequest,
)

router = APIRouter(prefix="/admin", tags=["subscription plans"])


@router.get("/subscription-plans", response_model=list[SubscriptionPlanResponse])
async def list_subscription_plans(db: Session = Depends(get_db)):
    return (
        db.query(SubscriptionPlan)
        .filter(SubscriptionPlan.is_active == True)  # noqa: E712
        .order_by(SubscriptionPlan.created_at.desc())
        .all()
    )


@router.post(
    "/subscription-plans",
    response_model=SubscriptionPlanResponse,
    status_code=status.HTTP_201_CREATED,
)
async def create_subscription_plan(
    payload: SubscriptionPlanCreateRequest,
    current_user: CurrentUser = Depends(require_admin),
    db: Session = Depends(get_db),
):
    plan = SubscriptionPlan(
        name=payload.name,
        description=payload.description,
        price_monthly=payload.price_monthly,
        features=json.dumps(payload.features),
    )
    db.add(plan)
    db.commit()
    db.refresh(plan)
    return plan


@router.patch("/subscription-plans/{plan_id}", response_model=SubscriptionPlanResponse)
async def update_subscription_plan(
    plan_id: str,
    payload: SubscriptionPlanUpdateRequest,
    current_user: CurrentUser = Depends(require_admin),
    db: Session = Depends(get_db),
):
    plan = db.get(SubscriptionPlan, plan_id)
    if plan is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Subscription plan not found")

    if payload.name is not None:
        plan.name = payload.name
    if payload.description is not None:
        plan.description = payload.description
    if payload.price_monthly is not None:
        plan.price_monthly = payload.price_monthly
    if payload.features is not None:
        plan.features = json.dumps(payload.features)
    if payload.is_active is not None:
        plan.is_active = payload.is_active

    db.commit()
    db.refresh(plan)
    return plan


@router.delete("/subscription-plans/{plan_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_subscription_plan(
    plan_id: str,
    current_user: CurrentUser = Depends(require_admin),
    db: Session = Depends(get_db),
):
    plan = db.get(SubscriptionPlan, plan_id)
    if plan is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Subscription plan not found")
    plan.is_active = False
    db.commit()
