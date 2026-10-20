"""Stored emails are reported as they are; new ones are checked on the way in."""

from datetime import datetime, timezone
from types import SimpleNamespace

import pytest

from app.models import UserRole
from app.schemas import UserResponse
from app.scripts.create_admin import validate_credentials


def _user(email):
    return SimpleNamespace(
        id="3f2b8c1e-9d4a-4e6b-8f0c-1a2b3c4d5e6f",
        email=email,
        full_name="Someone",
        phone=None,
        business_name=None,
        role=UserRole.admin,
        is_verified=True,
        is_active=True,
        rejection_reason=None,
        created_at=datetime.now(timezone.utc),
    )


def test_response_reports_a_reserved_domain_instead_of_failing():
    # The address create_admin's own docstring used to suggest. One such row
    # used to turn GET /users?is_verified=true into a 500.
    assert UserResponse.model_validate(_user("admin@microlink.test")).email == (
        "admin@microlink.test"
    )


def test_create_admin_accepts_a_normal_account():
    assert validate_credentials("admin1@microlink.lk", "Test1234") == "admin1@microlink.lk"


@pytest.mark.parametrize("email", ["admin@microlink.test", "not-an-email", "a@b"])
def test_create_admin_rejects_an_email_that_could_never_log_in(email):
    with pytest.raises(ValueError, match="Invalid email"):
        validate_credentials(email, "Test1234")


def test_create_admin_applies_the_registration_password_rules():
    with pytest.raises(ValueError, match="uppercase"):
        validate_credentials("admin1@microlink.lk", "test1234")
