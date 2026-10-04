from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.orm import Session

from app.auth import get_current_user, require_admin
from app.database import get_db
from app.event_bus import publish_event
from app.models import User, UserPreferences, UserRole
from app.schemas import (
    PreferencesResponse,
    PreferencesUpdateRequest,
    UserPublicResponse,
    UserResponse,
    UserUpdateRequest,
)

router = APIRouter(prefix="/users", tags=["users"])


@router.get("/me", response_model=UserResponse)
async def get_my_profile(current_user: User = Depends(get_current_user)):
    return current_user


@router.patch("/me", response_model=UserResponse)
async def update_my_profile(
    payload: UserUpdateRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    if payload.full_name is not None:
        current_user.full_name = payload.full_name
    if payload.phone is not None:
        current_user.phone = payload.phone
    db.commit()
    db.refresh(current_user)
    return current_user


@router.get("/me/preferences", response_model=PreferencesResponse)
async def get_my_preferences(
    current_user: User = Depends(get_current_user), db: Session = Depends(get_db)
):
    prefs = db.query(UserPreferences).filter(UserPreferences.user_id == current_user.id).first()
    if prefs is None:
        prefs = UserPreferences(user_id=current_user.id)
        db.add(prefs)
        db.commit()
        db.refresh(prefs)
    return prefs


@router.put("/me/preferences", response_model=PreferencesResponse)
async def update_my_preferences(
    payload: PreferencesUpdateRequest,
    current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    prefs = db.query(UserPreferences).filter(UserPreferences.user_id == current_user.id).first()
    if prefs is None:
        prefs = UserPreferences(user_id=current_user.id)
        db.add(prefs)

    for field, value in payload.model_dump(exclude_unset=True).items():
        setattr(prefs, field, value)

    db.commit()
    db.refresh(prefs)
    return prefs


@router.get("", response_model=list[UserResponse])
async def list_users(
    role: UserRole | None = Query(default=None),
    is_verified: bool | None = Query(default=None),
    _admin: User = Depends(require_admin),
    db: Session = Depends(get_db),
):
    query = db.query(User)
    if role is not None:
        query = query.filter(User.role == role)
    if is_verified is not None:
        query = query.filter(User.is_verified == is_verified)
    return query.order_by(User.created_at.desc()).all()


@router.get("/{user_id}", response_model=UserPublicResponse)
async def get_user_public(
    user_id: str,
    _current_user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    user = db.get(User, user_id)
    if user is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="User not found")
    return user


@router.patch("/{user_id}/verify", response_model=UserResponse)
async def verify_user(
    user_id: str,
    _admin: User = Depends(require_admin),
    db: Session = Depends(get_db),
):
    user = db.get(User, user_id)
    if user is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="User not found")
    if user.role not in (UserRole.shop_owner, UserRole.delivery_agent):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Only shop owner or delivery agent accounts require verification",
        )
    user.is_verified = True
    db.commit()
    db.refresh(user)

    await publish_event(
        "user.verified", {"user_id": user.id, "role": user.role.value}
    )
    return user


@router.patch("/{user_id}/deactivate", response_model=UserResponse)
async def deactivate_user(
    user_id: str,
    _admin: User = Depends(require_admin),
    db: Session = Depends(get_db),
):
    user = db.get(User, user_id)
    if user is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="User not found")
    user.is_active = False
    db.commit()
    db.refresh(user)

    await publish_event("user.deactivated", {"user_id": user.id})
    return user
