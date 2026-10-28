"""What an applicant hears after an admin reviews their documents.

A shop owner or delivery agent cannot sign in until approved, so a rejection
reason has to survive in the database and come back at login -- the in-app
notification alone sits behind a login they cannot complete. Runs the real
routes over in-memory SQLite, with Redis and the event bus stubbed.
"""

import unittest

from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.ext.compiler import compiles
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app import login_guard
from app.auth import create_access_token, hash_password
from app.database import Base, get_db
from app.models import User, UserRole
from app.routers import auth_router, users_router


@compiles(UUID, "sqlite")
def _uuid_as_varchar(type_, compiler, **kw):  # pragma: no cover - DDL helper
    return "VARCHAR(36)"


PASSWORD = "Applicant1"


class ApplicationReviewTests(unittest.TestCase):
    def setUp(self):
        self.engine = create_engine(
            "sqlite:///:memory:",
            connect_args={"check_same_thread": False},
            poolclass=StaticPool,
        )
        Base.metadata.create_all(self.engine)
        self.Session = sessionmaker(bind=self.engine, autoflush=False)

        def override_get_db():
            db = self.Session()
            try:
                yield db
            finally:
                db.close()

        app = FastAPI()
        app.include_router(auth_router.router)
        app.include_router(users_router.router)
        app.dependency_overrides[get_db] = override_get_db
        self.client = TestClient(app)

        self.notifications: list[dict] = []
        self.originals = {
            "notify": users_router.notify_users,
            "publish_users": users_router.publish_event,
            "publish_auth": auth_router.publish_event,
            "locked": login_guard.seconds_locked,
            "failure": login_guard.record_failure,
            "clear": login_guard.clear,
        }

        async def notify_users(user_ids, title, body, kind="general", link=None):
            self.notifications.append({"user_ids": list(user_ids), "title": title, "body": body})

        async def publish_event(event_type, payload):
            return None

        async def no_lock(email):
            return 0

        async def nothing(email):
            return None

        users_router.notify_users = notify_users
        users_router.publish_event = publish_event
        auth_router.publish_event = publish_event
        login_guard.seconds_locked = no_lock
        login_guard.record_failure = nothing
        login_guard.clear = nothing

        session = self.Session()
        admin = User(
            email="admin@microlink.lk",
            hashed_password=hash_password("Admin1234"),
            full_name="Admin",
            role=UserRole.admin,
            is_verified=True,
        )
        applicant = User(
            email="owner@microlink.lk",
            hashed_password=hash_password(PASSWORD),
            full_name="Sunil Fernando",
            role=UserRole.shop_owner,
            is_verified=False,
        )
        session.add_all([admin, applicant])
        session.commit()
        self.admin_headers = {
            "Authorization": f"Bearer {create_access_token(admin.id, admin.role, True)}"
        }
        self.applicant_id = applicant.id
        session.close()

    def tearDown(self):
        users_router.notify_users = self.originals["notify"]
        users_router.publish_event = self.originals["publish_users"]
        auth_router.publish_event = self.originals["publish_auth"]
        login_guard.seconds_locked = self.originals["locked"]
        login_guard.record_failure = self.originals["failure"]
        login_guard.clear = self.originals["clear"]
        self.engine.dispose()

    def _reject(self, reason="The NIC photo is blurred."):
        return self.client.patch(
            f"/users/{self.applicant_id}/reject",
            json={"reason": reason},
            headers=self.admin_headers,
        )

    def _login(self):
        return self.client.post(
            "/auth/login", json={"email": "owner@microlink.lk", "password": PASSWORD}
        )

    def test_the_rejection_reason_is_saved(self):
        self.assertEqual(self._reject().status_code, 200)
        session = self.Session()
        try:
            self.assertEqual(
                session.get(User, self.applicant_id).rejection_reason,
                "The NIC photo is blurred.",
            )
        finally:
            session.close()

    def test_the_admin_list_shows_the_reason_afterwards(self):
        self._reject()
        rows = self.client.get(
            "/users", params={"is_verified": "false"}, headers=self.admin_headers
        ).json()
        mine = next(r for r in rows if r["id"] == self.applicant_id)
        self.assertEqual(mine["rejection_reason"], "The NIC photo is blurred.")

    def test_a_rejected_applicant_is_told_why_at_login(self):
        self._reject()
        response = self._login()
        self.assertEqual(response.status_code, 403)
        detail = response.json()["detail"]
        self.assertIn("not approved", detail)
        self.assertIn("The NIC photo is blurred.", detail)

    def test_a_pending_applicant_is_still_told_to_wait(self):
        response = self._login()
        self.assertEqual(response.status_code, 403)
        self.assertIn("waiting for admin approval", response.json()["detail"])

    def test_the_rejection_notification_names_the_role_and_reason(self):
        self._reject()
        told = [n for n in self.notifications if self.applicant_id in n["user_ids"]]
        self.assertEqual(len(told), 1)
        self.assertIn("shop owner", told[0]["body"])
        self.assertIn("The NIC photo is blurred.", told[0]["body"])

    def test_verifying_after_a_rejection_clears_the_reason_and_lets_them_in(self):
        self._reject()
        verified = self.client.patch(
            f"/users/{self.applicant_id}/verify", headers=self.admin_headers
        )
        self.assertEqual(verified.status_code, 200)
        self.assertIsNone(verified.json()["rejection_reason"])
        self.assertEqual(self._login().status_code, 200)


if __name__ == "__main__":
    unittest.main()
