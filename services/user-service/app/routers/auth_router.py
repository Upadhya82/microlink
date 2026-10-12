from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile, status
from sqlalchemy.orm import Session

from app.auth import create_access_token, hash_password, verify_password
from app.database import get_db
from app import login_guard
from app.event_bus import publish_event
from app.images import ImageRejected, process_document
from app.models import User, UserDocument, UserPreferences, UserRole
from app.schemas import (
    DOCUMENT_TYPES,
    REGISTERABLE_ROLES,
    LoginRequest,
    RegisterRequest,
    TokenResponse,
    UserResponse,
    check_password_strength,
)

router = APIRouter(prefix="/auth", tags=["auth"])

# Roles an admin must approve before the account is usable (REQ-AUTH-4).
# Declared once so registration and login can never disagree about which
# roles are gated.
_ROLES_NEEDING_VERIFICATION = {UserRole.shop_owner, UserRole.delivery_agent}


@router.post("/register", response_model=TokenResponse, status_code=status.HTTP_201_CREATED)
async def register(payload: RegisterRequest, db: Session = Depends(get_db)):
    if payload.role not in REGISTERABLE_ROLES:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="This role cannot be self-registered. Contact an administrator.",
        )

    existing = db.query(User).filter(User.email == payload.email).first()
    if existing is not None:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT, detail="An account with this email already exists"
        )

    needs_verification = payload.role in _ROLES_NEEDING_VERIFICATION
    user = User(
        email=payload.email,
        hashed_password=hash_password(payload.password),
        full_name=payload.full_name,
        phone=payload.phone,
        business_name=payload.business_name,
        role=payload.role,
        is_verified=not needs_verification,
    )
    db.add(user)
    db.flush()
    db.add(UserPreferences(user_id=user.id))
    db.commit()
    db.refresh(user)

    await publish_event(
        "user.registered",
        {"user_id": user.id, "email": user.email, "role": user.role.value},
    )

    token = create_access_token(user.id, user.role, user.is_verified)
    return TokenResponse(access_token=token, user=UserResponse.model_validate(user))


# Documents each gated role must supply before an admin will look at the
# application. Mirrors kRequiredDocsByRole in the app.
REQUIRED_DOCUMENTS: dict[UserRole, tuple[str, ...]] = {
    UserRole.shop_owner: ("national_id", "business_registration", "profile_photo"),
    UserRole.delivery_agent: (
        "national_id",
        "driving_licence",
        "police_clearance",
        "vehicle_registration",
        "profile_photo",
    ),
}


@router.post(
    "/register-application",
    response_model=TokenResponse,
    status_code=status.HTTP_201_CREATED,
)
async def register_application(
    email: str = Form(...),
    password: str = Form(...),
    full_name: str = Form(...),
    role: str = Form(...),
    phone: str | None = Form(default=None),
    business_name: str | None = Form(default=None),
    doc_types: list[str] = Form(...),
    files: list[UploadFile] = File(...),
    db: Session = Depends(get_db),
):
    """Register a shop owner or delivery agent together with their documents.

    One request, one transaction. Registering first and uploading afterwards
    left applicants with an account they could not log into and no documents
    attached when an upload failed -- an account nobody could use and no
    admin could action. Here nothing is written unless every document is
    accepted, so "no documents" simply means "no account".
    """
    try:
        user_role = UserRole(role)
    except ValueError:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST, detail="Unknown account type."
        )
    if user_role not in REQUIRED_DOCUMENTS:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="This account type does not need document review. Use /auth/register.",
        )
    if user_role not in REGISTERABLE_ROLES:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="This role cannot be self-registered. Contact an administrator.",
        )

    # Validate the whole application before touching the database, so a bad
    # password or a missing licence costs the applicant nothing.
    if len(doc_types) != len(files):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Each document must be sent with its type.",
        )
    supplied = set(doc_types)
    unknown = supplied - set(DOCUMENT_TYPES)
    if unknown:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Unknown document type: {', '.join(sorted(unknown))}.",
        )
    missing = [d for d in REQUIRED_DOCUMENTS[user_role] if d not in supplied]
    if missing:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Please attach: " + ", ".join(d.replace("_", " ") for d in missing) + ".",
        )

    try:
        check_password_strength(password)
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc))

    if db.query(User).filter(User.email == email).first() is not None:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="An account with this email already exists",
        )

    # Process every file up front: a document we cannot read must stop the
    # registration, not land halfway through it.
    processed: list[tuple[str, bytes, str, str]] = []
    for doc_type, upload in zip(doc_types, files):
        raw = await upload.read()
        try:
            data, content_type = process_document(raw, upload.content_type)
        except ImageRejected as exc:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail=f"{doc_type.replace('_', ' ').capitalize()}: {exc}",
            )
        processed.append((doc_type, data, content_type, upload.filename or doc_type))

    user = User(
        email=email,
        hashed_password=hash_password(password),
        full_name=full_name,
        phone=phone,
        business_name=business_name,
        role=user_role,
        is_verified=False,
    )
    db.add(user)
    db.flush()
    db.add(UserPreferences(user_id=user.id))
    for doc_type, data, content_type, file_name in processed:
        db.add(
            UserDocument(
                user_id=user.id,
                doc_type=doc_type,
                file_name=file_name,
                content_type=content_type,
                data=data,
                size_bytes=len(data),
            )
        )
    db.commit()
    db.refresh(user)

    await publish_event(
        "user.registered",
        {"user_id": user.id, "email": user.email, "role": user.role.value},
    )

    token = create_access_token(user.id, user.role, user.is_verified)
    return TokenResponse(access_token=token, user=UserResponse.model_validate(user))


@router.post("/login", response_model=TokenResponse)
async def login(payload: LoginRequest, db: Session = Depends(get_db)):
    locked_for = await login_guard.seconds_locked(payload.email)
    if locked_for:
        raise HTTPException(
            status_code=status.HTTP_429_TOO_MANY_REQUESTS,
            detail="Too many failed attempts. Please try again later.",
            headers={"Retry-After": str(locked_for)},
        )

    user = db.query(User).filter(User.email == payload.email).first()
    if user is None or not verify_password(payload.password, user.hashed_password):
        await login_guard.record_failure(payload.email)
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED, detail="Incorrect email or password"
        )
    if not user.is_active:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN, detail="This account has been deactivated"
        )
    # REQ-AUTH-4: shop owners and delivery agents are gated at login, not just
    # at the actions they try to perform -- letting them in to an empty
    # dashboard looked like the app was broken rather than like they were
    # still waiting on approval.
    if user.role in _ROLES_NEEDING_VERIFICATION and not user.is_verified:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail=(
                "Your account is waiting for admin approval. "
                "You will be able to log in once it has been reviewed."
            ),
        )

    await login_guard.clear(payload.email)
    token = create_access_token(user.id, user.role, user.is_verified)
    return TokenResponse(access_token=token, user=UserResponse.model_validate(user))
