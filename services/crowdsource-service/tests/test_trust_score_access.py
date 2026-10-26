"""Who may read whose trust score.

    cd services/crowdsource-service
    JWT_SECRET=<32+ chars> python -m pytest tests/test_trust_score_access.py -q

GET /crowdsource/trust-score/{user_id} had no authentication at all: any
caller could read any account's standing, and because the lookup creates the
row when it is missing, could also fill user_trust_scores with rows for user
ids that were never real accounts. Regular users have /trust-score/me, which
needs no id and cannot name somebody else.
"""

import unittest
from datetime import datetime, timedelta, timezone

import jwt
from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.config import settings
from app.database import Base, get_db
from app.models import UserTrustScore
from app.routers import trust_router

ADMIN_ID = "11111111-1111-1111-1111-111111111111"
ALICE_ID = "22222222-2222-2222-2222-222222222222"
BOB_ID = "33333333-3333-3333-3333-333333333333"
NOBODY_ID = "99999999-9999-9999-9999-999999999999"


def _auth(user_id: str, role: str = "user") -> dict[str, str]:
    token = jwt.encode(
        {
            "sub": user_id,
            "role": role,
            "verified": True,
            "exp": datetime.now(timezone.utc) + timedelta(hours=1),
        },
        settings.jwt_secret,
        algorithm=settings.jwt_algorithm,
    )
    return {"Authorization": f"Bearer {token}"}


class TrustScoreAccessTests(unittest.TestCase):
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
        app.include_router(trust_router.router)
        app.dependency_overrides[get_db] = override_get_db
        self.client = TestClient(app)

        session = self.Session()
        session.add(UserTrustScore(user_id=ALICE_ID, score=73.0))
        session.commit()
        session.close()

    def tearDown(self):
        self.engine.dispose()

    def _rows(self) -> int:
        session = self.Session()
        try:
            return session.query(UserTrustScore).count()
        finally:
            session.close()

    def test_a_stranger_cannot_read_somebody_elses_score(self):
        response = self.client.get(
            f"/crowdsource/trust-score/{ALICE_ID}", headers=_auth(BOB_ID)
        )
        self.assertEqual(response.status_code, 403)

    def test_a_signed_out_caller_cannot_read_any_score(self):
        response = self.client.get(f"/crowdsource/trust-score/{ALICE_ID}")
        self.assertEqual(response.status_code, 401)

    def test_an_admin_can_read_anybodys_score(self):
        response = self.client.get(
            f"/crowdsource/trust-score/{ALICE_ID}", headers=_auth(ADMIN_ID, "admin")
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["score"], 73.0)

    def test_naming_your_own_id_is_allowed(self):
        response = self.client.get(
            f"/crowdsource/trust-score/{ALICE_ID}", headers=_auth(ALICE_ID)
        )
        self.assertEqual(response.status_code, 200)

    def test_a_refused_read_creates_no_row(self):
        before = self._rows()
        self.client.get(f"/crowdsource/trust-score/{NOBODY_ID}", headers=_auth(BOB_ID))
        self.client.get(f"/crowdsource/trust-score/{NOBODY_ID}")
        self.assertEqual(self._rows(), before)

    def test_me_still_works_and_starts_a_new_account_at_fifty(self):
        response = self.client.get("/crowdsource/trust-score/me", headers=_auth(BOB_ID))
        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual(body["score"], 50.0)
        self.assertEqual(body["user_id"], BOB_ID)
        self.assertEqual(body["min_confirm_trust"], settings.min_confirm_trust)

    def test_me_is_not_mistaken_for_a_user_id(self):
        """/trust-score/me is declared first, so "me" is never read as an id."""
        response = self.client.get("/crowdsource/trust-score/me", headers=_auth(BOB_ID))
        self.assertNotEqual(response.json()["user_id"], "me")


if __name__ == "__main__":
    unittest.main()
