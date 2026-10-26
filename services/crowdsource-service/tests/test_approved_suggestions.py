"""The Home "User Suggestions" rail: approved shop suggestions, read-only.

    cd services/crowdsource-service
    JWT_SECRET=<32+ chars> python -m pytest tests/test_approved_suggestions.py -q
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
from app.models import NewShopReport, ShopReportStatus
from app.routers import shop_reports_router

CUSTOMER_ID = "11111111-1111-1111-1111-111111111111"
REPORTER_ID = "22222222-2222-2222-2222-222222222222"

# Colombo Fort, and two places at known distances from it.
HERE = (6.9334, 79.8503)
NEAR = (6.9271, 79.8612)   # about 1.4 km
FAR = (7.2906, 80.6337)    # Kandy, about 95 km


def _auth(user_id: str = CUSTOMER_ID, role: str = "customer") -> dict[str, str]:
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


class ApprovedSuggestionsTests(unittest.TestCase):
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
        app.dependency_overrides[get_db] = override_get_db
        self.client = TestClient(app)

    def tearDown(self):
        self.engine.dispose()

    def _report(self, name, status, point=NEAR, approved_minutes_ago=0):
        session = self.Session()
        when = datetime.now(timezone.utc) - timedelta(minutes=approved_minutes_ago)
        session.add(
            NewShopReport(
                reporter_id=REPORTER_ID,
                shop_name=name,
                category="grocery",
                address="1 Test Rd",
                latitude=point[0],
                longitude=point[1],
                status=status,
                created_at=when,
                updated_at=when,
            )
        )
        session.commit()
        session.close()

    def _get(self, params=None, headers=None):
        response = self.client.get(
            "/crowdsource/shop-reports/approved",
            params=params or {},
            headers=_auth() if headers is None else headers,
        )
        self.assertEqual(response.status_code, 200)
        return response.json()

    def test_only_approved_suggestions_are_listed(self):
        self._report("Approved shop", ShopReportStatus.approved)
        self._report("Pending shop", ShopReportStatus.pending)
        self._report("Rejected shop", ShopReportStatus.rejected)
        names = [item["shop_name"] for item in self._get()]
        self.assertEqual(names, ["Approved shop"])

    def test_who_suggested_it_is_not_shared(self):
        self._report("Approved shop", ShopReportStatus.approved)
        item = self._get()[0]
        self.assertNotIn("reporter_id", item)
        self.assertNotIn("comments", item)

    def test_newest_approval_first_without_a_location(self):
        self._report("Older", ShopReportStatus.approved, approved_minutes_ago=60)
        self._report("Newer", ShopReportStatus.approved, approved_minutes_ago=1)
        names = [item["shop_name"] for item in self._get()]
        self.assertEqual(names, ["Newer", "Older"])

    def test_nearest_first_with_a_location(self):
        self._report("Far", ShopReportStatus.approved, point=FAR, approved_minutes_ago=1)
        self._report("Near", ShopReportStatus.approved, point=NEAR, approved_minutes_ago=60)
        items = self._get({"lat": HERE[0], "lng": HERE[1]})
        self.assertEqual([item["shop_name"] for item in items], ["Near", "Far"])
        self.assertLess(items[0]["distance_km"], 5)

    def test_the_limit_is_respected(self):
        for index in range(4):
            self._report(f"Shop {index}", ShopReportStatus.approved)
        self.assertEqual(len(self._get({"limit": 2})), 2)

    def test_a_token_is_required(self):
        response = self.client.get("/crowdsource/shop-reports/approved")
        self.assertIn(response.status_code, (401, 403))


if __name__ == "__main__":
    unittest.main()
