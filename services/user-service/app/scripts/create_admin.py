"""Create or promote an admin account directly in the database.

Admin accounts cannot be created through `POST /auth/register` (see
REGISTERABLE_ROLES in app/schemas.py) since that endpoint is reachable by
anyone. This script is the supported way to provision the first admin, or
any later one, and is meant to be run inside the user-service container:

    docker compose exec user-service python -m app.scripts.create_admin \\
        admin@microlink.test "a strong password" "Admin User"

If the email already exists, its role is promoted to admin instead of
creating a duplicate account.
"""

import sys

from app.auth import hash_password
from app.database import SessionLocal
from app.models import User, UserPreferences, UserRole


def create_admin(email: str, password: str, full_name: str) -> None:
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
    create_admin(sys.argv[1], sys.argv[2], sys.argv[3])
