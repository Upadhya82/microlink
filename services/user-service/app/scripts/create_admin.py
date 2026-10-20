"""Create or promote an admin account directly in the database.

Admin accounts cannot be created through `POST /auth/register` (see
REGISTERABLE_ROLES in app/schemas.py) since that endpoint is reachable by
anyone. This script is the supported way to provision the first admin, or
any later one, and is meant to be run inside the user-service container:

    docker compose exec user-service python -m app.scripts.create_admin \\
        admin@microlink.lk "Admin1234" "Admin User"

If the email already exists, its role is promoted to admin instead of
creating a duplicate account.

The email and password must pass the same checks as registration. An
address like admin@microlink.test (a reserved domain) used to be accepted
here, and could then never log in.
"""

import sys

from pydantic import EmailStr, TypeAdapter, ValidationError

from app.auth import hash_password
from app.database import SessionLocal
from app.models import User, UserPreferences, UserRole
from app.schemas import check_password_strength


def validate_credentials(email: str, password: str) -> str:
    """Return the normalised email, or raise ValueError saying what is wrong."""
    try:
        email = TypeAdapter(EmailStr).validate_python(email)
    except ValidationError as exc:
        raise ValueError(f"Invalid email {email!r}: {exc.errors()[0]['msg']}") from None
    check_password_strength(password)
    return email


def create_admin(email: str, password: str, full_name: str) -> None:
    email = validate_credentials(email, password)
    db = SessionLocal()
    try:
        existing = db.query(User).filter(User.email == email).first()
        if existing is not None:
            existing.role = UserRole.admin
            existing.is_verified = True
            db.commit()
            print(f"Promoted existing user {email} to admin.")
            return

        user = User(
            email=email,
            hashed_password=hash_password(password),
            full_name=full_name,
            role=UserRole.admin,
            is_verified=True,
        )
        db.add(user)
        db.flush()
        db.add(UserPreferences(user_id=user.id))
        db.commit()
        print(f"Created admin account {email}.")
    finally:
        db.close()


if __name__ == "__main__":
    if len(sys.argv) != 4:
        print("Usage: python -m app.scripts.create_admin <email> <password> <full_name>")
        sys.exit(1)
    try:
        create_admin(sys.argv[1], sys.argv[2], sys.argv[3])
    except ValueError as exc:
        print(exc)
        sys.exit(1)
