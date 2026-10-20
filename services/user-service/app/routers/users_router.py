from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import or_
from sqlalchemy.orm import Session

from app.auth import get_current_user, require_admin
from app.database import get_db
from app.event_bus import notify_users, publish_event
from app.models import User, UserPreferences, UserRole
from app.schemas import (
    PreferencesResponse,
    PreferencesUpdateRequest,
    RejectUserRequest,
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


@router.get("/internal/admin-ids")
async def list_admin_ids(db: Session = Depends(get_db)):
    """Which accounts are admins, for a service that needs to alert them.

    Internal (item 8): api-gateway blocks /users/internal/*, so no app can
    reach this. Inside the compose network delivery-service calls it when a
    shop's cancellations cross the alert threshold -- it has no admin token
    of its own, and admins live in this service's database.

    Ids only, deliberately: no names, no email addresses.
    """
    rows = db.query(User.id).filter(User.role == UserRole.admin).all()
    return {"admin_ids": [row.id for row in rows]}


@router.get("", response_model=list[UserResponse])
async def list_users(
    role: UserRole | None = Query(default=None),
    is_verified: bool | None = Query(default=None),
    q: str | None = Query(default=None, max_length=100, description="Search name or email"),
    limit: int = Query(default=200, ge=1, le=500),
    _admin: User = Depends(require_admin),
    db: Session = Depends(get_db),
):
    query = db.query(User)
    if role is not None:
        query = query.filter(User.role == role)
    if is_verified is not None:
        query = query.filter(User.is_verified == is_verified)
    if q:
        # REQ-ADMIN-3: find an account by name or email.
        pattern = f"%{q.strip()}%"
        query = query.filter(or_(User.full_name.ilike(pattern), User.email.ilike(pattern)))
    return query.order_by(User.created_at.desc()).limit(limit).all()


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
    user.rejection_reason = None
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

@router.patch("/{user_id}/reject", response_model=UserResponse)
async def reject_user(
    user_id: str,
    payload: RejectUserRequest,
    _admin: User = Depends(require_admin),
    db: Session = Depends(get_db),
):
    """REQ-ADMIN-1/2: turn down a shop owner or agent application, with a
    reason the applicant is actually told."""
    user = db.get(User, user_id)
    if user is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="User not found")
    if user.role not in (UserRole.shop_owner, UserRole.delivery_agent):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Only shop owner or delivery agent applications can be rejected",
        )
    user.is_verified = False
    user.rejection_reason = payload.reason
    db.commit()
    db.refresh(user)

    await publish_event(
        "user.rejected", {"user_id": user.id, "role": user.role.value, "reason": payload.reason}
    )
    await notify_users(
        [user.id],
        "Your application was not approved",
        payload.reason,
        kind="account",
        link={"route": "documents"},
    )
    return user


@router.patch("/{user_id}/activate", response_model=UserResponse)
async def activate_user(
    user_id: str,
    _admin: User = Depends(require_admin),
    db: Session = Depends(get_db),
):
    """REQ-ADMIN-3: undo a deactivation."""
    user = db.get(User, user_id)
    if user is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="User not found")
    user.is_active = True
    db.commit()
    db.refresh(user)

    await publish_event("user.activated", {"user_id": user.id})
    return user


@router.delete("/{user_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_user(
    user_id: str,
    admin: User = Depends(require_admin),
    db: Session = Depends(get_db),
):
    """REQ-ADMIN-3. Deleting an admin, or yourself, is refused -- it is far
    too easy to lock the whole platform out by accident."""
    user = db.get(User, user_id)
    if user is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="User not found")
    if user.id == admin.id:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST, detail="You cannot delete your own account"
        )
    if user.role == UserRole.admin:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST, detail="Admin accounts cannot be deleted here"
        )
    db.delete(user)
    db.commit()
    await publish_event("user.deleted", {"user_id": user_id})
