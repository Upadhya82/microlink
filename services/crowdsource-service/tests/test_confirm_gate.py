"""Item 7: who may confirm a neighbour's shop report.

The rule itself is a plain function, and the endpoint is checked over an
in-memory SQLite database so the 403s are real responses rather than an
assumption about the dependency order.

    cd services/crowdsource-service
    JWT_SECRET=<32+ chars> python -m pytest tests/test_confirm_gate.py -q
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
from app.models import NewShopReport, ShopReportStatus, UserTrustScore
from app.routers import shop_reports_router, trust_router
from app.trust import can_confirm_reports

CONFIRMER_ID = "11111111-1111-1111-1111-111111111111"
REPORTER_ID = "22222222-2222-2222-2222-222222222222"
ADMIN_ID = "33333333-3333-3333-3333-333333333333"


def _auth(user_id: str, *, verified: bool = True, role: str = "user") -> dict[str, str]:
    token = jwt.encode(
        {
            "sub": user_id,
            "role": role,
            "verified": verified,
            "exp": datetime.now(timezone.utc) + timedelta(hours=1),
        },
        settings.jwt_secret,
        algorithm=settings.jwt_algorithm,
    )
    return {"Authorization": f"Bearer {token}"}


class ConfirmRuleTests(unittest.TestCase):
    """The rule on its own."""

    def test_a_verified_account_at_the_threshold_may_confirm(self):
        self.assertTrue(can_confirm_reports(is_verified=True, score=50.0, minimum=50))

    def test_one_point_below_the_threshold_may_not(self):
        self.assertFalse(can_confirm_reports(is_verified=True, score=49.0, minimum=50))

    def test_an_unverified_account_may_not_however_trusted(self):
        self.assertFalse(can_confirm_reports(is_verified=False, score=100.0, minimum=50))

    def test_a_new_account_with_no_score_yet_starts_at_fifty(self):
        self.assertTrue(can_confirm_reports(is_verified=True, score=None, minimum=50))
        self.assertFalse(can_confirm_reports(is_verified=True, score=None, minimum=51))


class ConfirmEndpointTests(unittest.TestCase):
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
        app.include_router(shop_reports_router.router)
        app.include_router(trust_router.router)
        app.dependency_overrides[get_db] = override_get_db
        self.client = TestClient(app)

        # Keep the event bus out of it.
        self.originals = {
            "notify_users": shop_reports_router.notify_users,
            "publish_event": shop_reports_router.publish_event,
        }

        async def quiet(*args, **kwargs):
            return None

        shop_reports_router.notify_users = quiet
        shop_reports_router.publish_event = quiet

        self.report_id = self._report()

    def tearDown(self):
        shop_reports_router.notify_users = self.originals["notify_users"]
        shop_reports_router.publish_event = self.originals["publish_event"]
        self.engine.dispose()

    def _report(self, status=ShopReportStatus.pending, reporter=REPORTER_ID) -> str:
        session = self.Session()
        report = NewShopReport(
            reporter_id=reporter,
            shop_name="Corner shop",
            category="grocery",
            address="1 Test Rd",
            latitude=6.9271,
            longitude=79.8612,
            status=status,
        )
        session.add(report)
        session.commit()
        report_id = report.id
        session.close()
        return report_id

    def _set_score(self, user_id: str, score: float) -> None:
        session = self.Session()
        row = (
            session.query(UserTrustScore)
            .filter(UserTrustScore.user_id == user_id)
            .first()
        )
        if row is None:
            session.add(UserTrustScore(user_id=user_id, score=score))
        else:
            row.score = score
        session.commit()
        session.close()

    def _confirm(self, headers, *, confirms=True, report_id=None):
        return self.client.post(
            f"/crowdsource/shop-reports/{report_id or self.report_id}/confirm",
            json={"confirms": confirms},
            headers=headers,
        )

    # --- the gate ---
    def test_a_verified_account_at_the_threshold_is_allowed(self):
        self._set_score(CONFIRMER_ID, settings.min_confirm_trust)
        self.assertEqual(self._confirm(_auth(CONFIRMER_ID)).status_code, 200)

    def test_an_unverified_account_is_refused(self):
        response = self._confirm(_auth(CONFIRMER_ID, verified=False))
        self.assertEqual(response.status_code, 403)
        self.assertIn("verified", response.json()["detail"].lower())

    def test_an_unverified_shop_owner_token_is_refused(self):
        response = self._confirm(
            _auth(CONFIRMER_ID, verified=False, role="shop_owner")
        )
        self.assertEqual(response.status_code, 403)

    def test_a_score_below_the_threshold_is_refused(self):
        self._set_score(CONFIRMER_ID, settings.min_confirm_trust - 1)
        response = self._confirm(_auth(CONFIRMER_ID))
        self.assertEqual(response.status_code, 403)
        self.assertIn("cannot confirm", response.json()["detail"].lower())

    def test_a_refused_confirmation_is_not_recorded(self):
        self._set_score(CONFIRMER_ID, settings.min_confirm_trust - 1)
        self._confirm(_auth(CONFIRMER_ID))
        session = self.Session()
        report = session.get(NewShopReport, self.report_id)
        self.assertEqual(report.status, ShopReportStatus.pending)
        session.close()

    # --- rules that were already there must still hold ---
    def test_the_reporter_still_cannot_confirm_their_own(self):
        self._set_score(REPORTER_ID, 100)
        self.assertEqual(self._confirm(_auth(REPORTER_ID)).status_code, 400)

    def test_an_already_reviewed_report_is_still_refused(self):
        reviewed = self._report(status=ShopReportStatus.approved)
        self._set_score(CONFIRMER_ID, 100)
        self.assertEqual(
            self._confirm(_auth(CONFIRMER_ID), report_id=reviewed).status_code, 400
        )

    def test_changing_the_answer_still_updates_one_row(self):
        self._set_score(CONFIRMER_ID, 100)
        self.assertEqual(self._confirm(_auth(CONFIRMER_ID), confirms=True).status_code, 200)
        self.assertEqual(self._confirm(_auth(CONFIRMER_ID), confirms=False).status_code, 200)
        session = self.Session()
        from app.models import ShopReportConfirmation

        rows = (
            session.query(ShopReportConfirmation)
            .filter(ShopReportConfirmation.user_id == CONFIRMER_ID)
            .all()
        )
        session.close()
        self.assertEqual(len(rows), 1)
        self.assertFalse(rows[0].confirms)


class TrustScoreVerdictTests(ConfirmEndpointTests):
    """/trust-score/me tells the app whether to offer the confirm screen."""

    def test_a_verified_account_is_told_it_can_confirm(self):
        self._set_score(CONFIRMER_ID, settings.min_confirm_trust)
        response = self.client.get(
            "/crowdsource/trust-score/me", headers=_auth(CONFIRMER_ID)
        )
        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertTrue(body["can_confirm_shops"])
        self.assertEqual(body["min_confirm_trust"], settings.min_confirm_trust)

    def test_an_unverified_account_is_told_it_cannot(self):
        response = self.client.get(
            "/crowdsource/trust-score/me",
            headers=_auth(CONFIRMER_ID, verified=False),
        )
        self.assertFalse(response.json()["can_confirm_shops"])

    def test_a_low_score_is_told_it_cannot(self):
        self._set_score(CONFIRMER_ID, settings.min_confirm_trust - 10)
        response = self.client.get(
            "/crowdsource/trust-score/me", headers=_auth(CONFIRMER_ID)
        )
        self.assertFalse(response.json()["can_confirm_shops"])

    def test_the_verdict_is_not_guessed_for_somebody_else(self):
        """Read for another account, can_confirm_shops is null rather than a
        guess: that verdict needs the caller's own verified flag, which this
        endpoint does not have. Asked as an admin because reading somebody
        else's score now requires it -- see tests/test_trust_score_access.py.
        """
        response = self.client.get(
            f"/crowdsource/trust-score/{CONFIRMER_ID}",
            headers=_auth(ADMIN_ID, role="admin"),
        )
        self.assertEqual(response.status_code, 200)
        self.assertIsNone(response.json()["can_confirm_shops"])


if __name__ == "__main__":
    unittest.main()
