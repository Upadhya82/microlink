from datetime import datetime

from pydantic import BaseModel, ConfigDict, EmailStr, Field, field_validator

from app.models import UserRole

# Roles anyone may pick on the public register endpoint. Admins are created
# with app/scripts/create_admin.py instead.
#
# Item 16: a shop owner or delivery agent must apply through
# /auth/register-application, which takes their documents in the same
# request. /auth/register let them create an account with no documents at
# all -- an account they could not log into, and which no admin had anything
# to review -- so it now refuses those two roles outright.
REGISTERABLE_ROLES = {UserRole.user}

# Roles that exist but must come in through /auth/register-application.
ROLES_NEEDING_APPLICATION = {UserRole.shop_owner, UserRole.delivery_agent}


def check_password_strength(value: str) -> str:
    """REQ-AUTH-1: at least 8 characters, one uppercase letter, one number.

    Raised as one message listing everything that is wrong, so the user fixes
    their password in a single attempt instead of being told about each rule
    in turn.
    """
    problems = []
    if len(value) < 8:
        problems.append("at least 8 characters")
    if not any(c.isupper() for c in value):
        problems.append("one uppercase letter")
    if not any(c.isdigit() for c in value):
        problems.append("one number")
    if problems:
        raise ValueError("Password needs " + ", ".join(problems) + ".")
    return value


class RegisterRequest(BaseModel):
    email: EmailStr
    # max_length 72: bcrypt silently truncates past 72 bytes, so a longer
    # password would not mean what the user thinks it means.
    password: str = Field(min_length=8, max_length=72)
    full_name: str = Field(min_length=1, max_length=120)
    phone: str | None = Field(default=None, max_length=30)
    business_name: str | None = Field(default=None, max_length=120)
    role: UserRole = UserRole.user

    @field_validator("password")
    @classmethod
    def _password_strength(cls, value: str) -> str:
        return check_password_strength(value)


class LoginRequest(BaseModel):
    email: EmailStr
    password: str


class UserResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    # Plain str, not EmailStr: addresses are checked when they come in
    # (register, login, create_admin). Re-checking on the way out meant one
    # stored address the validator dislikes -- admin@microlink.test -- made
    # every user list containing it fail with a 500.
    email: str
    full_name: str
    phone: str | None
    business_name: str | None = None
    role: UserRole
    is_verified: bool
    is_active: bool
    rejection_reason: str | None = None
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


# Document types an applicant may upload (REQ-AGENT-1, REQ-ADMIN-1/2).
# Which ones are actually required depends on the role, and the app decides
# that; the backend accepts any of them from any applicant so a shop owner
# who also drives is not blocked from supplying a licence.
class RejectUserRequest(BaseModel):
    """REQ-ADMIN-3 / the registration activity diagram's "rejected
    notification": a rejection always carries a reason, because the
    applicant is told it."""

    reason: str = Field(min_length=3, max_length=300)


DOCUMENT_TYPES = (
    "national_id",
    "business_registration",
    "driving_licence",
    "police_clearance",
    "vehicle_registration",
    "profile_photo",
)


class UserDocumentResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    user_id: str
    doc_type: str
    file_name: str
    content_type: str
    size_bytes: int
    note: str | None
    created_at: datetime

    @property
    def file_url(self) -> str:
        return f"/users/documents/{self.id}/file"
