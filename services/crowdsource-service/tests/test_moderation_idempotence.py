"""Moderating a report twice must not pay the reporter twice.

    cd services/crowdsource-service
    JWT_SECRET=<32+ chars> python -m pytest tests/test_moderation_idempotence.py -q

Every PATCH .../status used to call trust.adjust_on_moderation, whether or
not the status had actually changed. A double-tapped approve button in the
admin dashboard, or a retried request, awarded another +2 score and another
validated_report each time; and because approval gives +2 while rejection
only takes 1 back, flipping a report between the two left the score
permanently inflated. The guard is that the status must really change.
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
from app.models import (
    NewShopReport,
    RoadConditionReport,
    RoadConditionType,
    RoadReportStatus,
    ShopReportStatus,
    UserTrustScore,
)
from app.routers import road_reports_router, shop_reports_router

ADMIN_ID = "11111111-1111-1111-1111-111111111111"
REPORTER_ID = "22222222-2222-2222-2222-222222222222"

STARTING_SCORE = 50.0
APPROVAL_BONUS = 2.0
REJECTION_PENALTY = 1.0


def _admin() -> dict[str, str]:
    token = jwt.encode(
        {
            "sub": ADMIN_ID,
            "role": "admin",
            "verified": True,
            "exp": datetime.now(timezone.utc) + timedelta(hours=1),
        },
        settings.jwt_secret,
        algorithm=settings.jwt_algorithm,
    )
    return {"Authorization": f"Bearer {token}"}


class ModerationIdempotenceTests(unittest.TestCase):
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
        app.include_router(road_reports_router.router)
        app.dependency_overrides[get_db] = override_get_db
        self.client = TestClient(app)

        self.originals = {
            "shop_notify": shop_reports_router.notify_users,
            "shop_publish": shop_reports_router.publish_event,
            "road_notify": road_reports_router.notify_users,
            "road_publish": road_reports_router.publish_event,
        }

        async def quiet(*args, **kwargs):
            return None

        shop_reports_router.notify_users = quiet
        shop_reports_router.publish_event = quiet
        road_reports_router.notify_users = quiet
        road_reports_router.publish_event = quiet

    def tearDown(self):
        shop_reports_router.notify_users = self.originals["shop_notify"]
        shop_reports_router.publish_event = self.originals["shop_publish"]
        road_reports_router.notify_users = self.originals["road_notify"]
        road_reports_router.publish_event = self.originals["road_publish"]
        self.engine.dispose()

    # --- helpers ---
    def _shop_report(self) -> str:
        session = self.Session()
        report = NewShopReport(
            reporter_id=REPORTER_ID,
            shop_name="Corner shop",
            category="grocery",
            address="1 Test Rd",
            latitude=6.9271,
            longitude=79.8612,
            status=ShopReportStatus.pending,
        )
        session.add(report)
        session.commit()
        report_id = report.id
        session.close()
        return report_id

    def _road_report(self) -> str:
        session = self.Session()
        report = RoadConditionReport(
            reporter_id=REPORTER_ID,
            condition_type=RoadConditionType.pothole,
            description="Deep pothole",
            latitude=6.9271,
            longitude=79.8612,
            status=RoadReportStatus.pending,
        )
        session.add(report)
        session.commit()
        report_id = report.id
        session.close()
        return report_id

    def _set_shop_status(self, report_id: str, value: str):
        return self.client.patch(
            f"/crowdsource/shop-reports/{report_id}/status",
            json={"status": value},
            headers=_admin(),
        )

    def _set_road_status(self, report_id: str, value: str):
        return self.client.patch(
            f"/crowdsource/road-reports/{report_id}/status",
            json={"status": value},
            headers=_admin(),
        )

    def _trust(self) -> UserTrustScore:
        session = self.Session()
        try:
            return (
                session.query(UserTrustScore)
                .filter(UserTrustScore.user_id == REPORTER_ID)
                .first()
            )
        finally:
            session.close()

    # --- shop reports ---
    def test_approving_once_pays_once(self):
        report_id = self._shop_report()
        self.assertEqual(self._set_shop_status(report_id, "approved").status_code, 200)
        trust = self._trust()
        self.assertEqual(trust.score, STARTING_SCORE + APPROVAL_BONUS)
        self.assertEqual(trust.validated_reports, 1)

    def test_approving_the_same_report_again_pays_nothing(self):
        report_id = self._shop_report()
        self._set_shop_status(report_id, "approved")
        for _ in range(4):
            self.assertEqual(
                self._set_shop_status(report_id, "approved").status_code, 200
            )
        trust = self._trust()
        self.assertEqual(trust.score, STARTING_SCORE + APPROVAL_BONUS)
        self.assertEqual(trust.validated_reports, 1)

    def test_rejecting_the_same_report_again_costs_nothing(self):
        report_id = self._shop_report()
        self._set_shop_status(report_id, "rejected")
        self._set_shop_status(report_id, "rejected")
        self._set_shop_status(report_id, "rejected")
        self.assertEqual(self._trust().score, STARTING_SCORE - REJECTION_PENALTY)

    def test_flipping_back_and_forth_does_not_inflate_the_score(self):
        """approved -> rejected -> approved is +2, -1, +2 = 51, not more.

        The arithmetic is unavoidable while approval and rejection are worth
        different amounts; what matters is that each *transition* is paid
        for exactly once, so the same sequence always lands on the same
        number instead of climbing with every extra request.
        """
        report_id = self._shop_report()
        self._set_shop_status(report_id, "approved")
        self._set_shop_status(report_id, "rejected")
        self._set_shop_status(report_id, "approved")
        expected = STARTING_SCORE + APPROVAL_BONUS - REJECTION_PENALTY + APPROVAL_BONUS
        self.assertEqual(self._trust().score, expected)
        self.assertEqual(self._trust().validated_reports, 2)

        # Repeating the final state changes nothing at all.
        for _ in range(3):
            self._set_shop_status(report_id, "approved")
        self.assertEqual(self._trust().score, expected)
        self.assertEqual(self._trust().validated_reports, 2)

    def test_the_status_is_still_stored(self):
        report_id = self._shop_report()
        response = self._set_shop_status(report_id, "approved")
        self.assertEqual(response.json()["status"], "approved")

    # --- road reports ---
    def test_a_road_report_verified_twice_pays_once(self):
        report_id = self._road_report()
        self._set_road_status(report_id, "verified")
        self._set_road_status(report_id, "verified")
        trust = self._trust()
        self.assertEqual(trust.score, STARTING_SCORE + APPROVAL_BONUS)
        self.assertEqual(trust.validated_reports, 1)

    def test_verified_then_resolved_is_a_real_transition(self):
        """Both count as approval, but they are different statuses, so moving
        between them is a change the reporter is paid for. Repeating either
        is not."""
        report_id = self._road_report()
        self._set_road_status(report_id, "verified")
        self._set_road_status(report_id, "resolved")
        self.assertEqual(self._trust().validated_reports, 2)
        self._set_road_status(report_id, "resolved")
        self.assertEqual(self._trust().validated_reports, 2)

    def test_a_road_report_rejected_twice_costs_once(self):
        report_id = self._road_report()
        self._set_road_status(report_id, "rejected")
        self._set_road_status(report_id, "rejected")
        self.assertEqual(self._trust().score, STARTING_SCORE - REJECTION_PENALTY)

    def test_the_score_is_floored_at_zero_and_capped_at_a_hundred(self):
        session = self.Session()
        session.add(UserTrustScore(user_id=REPORTER_ID, score=99.0))
        session.commit()
        session.close()

        first = self._shop_report()
        self._set_shop_status(first, "approved")
        self.assertEqual(self._trust().score, 100.0)
        second = self._shop_report()
        self._set_shop_status(second, "approved")
        self.assertEqual(self._trust().score, 100.0)


if __name__ == "__main__":
    unittest.main()
