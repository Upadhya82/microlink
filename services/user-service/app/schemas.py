from datetime import datetime

from pydantic import BaseModel, ConfigDict, EmailStr, Field

from app.models import UserRole

# Roles anyone may pick on the public register endpoint. Admins are created
# with app/scripts/create_admin.py instead.
REGISTERABLE_ROLES = {UserRole.user, UserRole.shop_owner, UserRole.delivery_agent}


class RegisterRequest(BaseModel):
    email: EmailStr
    password: str = Field(min_length=8, max_length=72)
    full_name: str = Field(min_length=1, max_length=120)
    phone: str | None = Field(default=None, max_length=30)
    role: UserRole = UserRole.user


class LoginRequest(BaseModel):
    email: EmailStr
    password: str


class UserResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    email: EmailStr
    full_name: str
    phone: str | None
    role: UserRole
    is_verified: bool
    is_active: bool
    created_at: datetime


class UserPublicResponse(BaseModel):
    """What other users may see about an account (no email or phone)."""

    model_config = ConfigDict(from_attributes=True)

    id: str
    full_name: str
    role: UserRole
    is_verified: bool


class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    user: UserResponse


class UserUpdateRequest(BaseModel):
    full_name: str | None = Field(default=None, min_length=1, max_length=120)
    phone: str | None = Field(default=None, max_length=30)


class PreferencesResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    preferred_categories: str
    max_distance_km: float
    notifications_enabled: bool
    language: str


class PreferencesUpdateRequest(BaseModel):
    preferred_categories: str | None = Field(default=None, max_length=500)
    max_distance_km: float | None = Field(default=None, gt=0, le=100)
    notifications_enabled: bool | None = None
    language: str | None = Field(default=None, max_length=10)
