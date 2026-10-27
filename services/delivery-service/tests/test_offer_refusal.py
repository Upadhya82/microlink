"""What an agent is told when an offer they tapped is no longer open.

Accept and Reject both refused anything that was not still pending with one
sentence: "This order has already been accepted by another agent". That is
only true some of the time. When the customer cancels while the offer is on
an agent's screen -- which is exactly when a stale tap happens -- the agent
is told a rival took the job and goes looking for the next one, when the
real answer is that there is no job. The refusal now names the actual
reason, the way `_release_refusal` already does on the release path.

    cd services/delivery-service
    JWT_SECRET=<32+ chars> python -m pytest tests/test_offer_refusal.py -q
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
from app.models import DeliveryAgentProfile, Order, OrderStatus, VehicleType
from app.routers import orders_router

CUSTOMER_ID = "11111111-1111-1111-1111-111111111111"
AGENT_ID = "44444444-4444-4444-4444-444444444444"
OTHER_AGENT_ID = "77777777-7777-7777-7777-777777777777"
SHOP_ID = "66666666-6666-6666-6666-666666666666"
OWNER_ID = "22222222-2222-2222-2222-222222222222"


def _auth(user_id: str, role: str) -> dict[str, str]:
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


AGENT = _auth(AGENT_ID, "delivery_agent")


class OfferRefusalTests(unittest.TestCase):
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
        app.include_router(orders_router.router)
        app.dependency_overrides[get_db] = override_get_db
        self.client = TestClient(app)

        self.originals = {
            name: getattr(orders_router, name)
            for name in ("notify_users", "publish_event", "_shop_owner_id")
        }

        async def notify_users(user_ids, title, body, kind="general", link=None):
            return None

        async def publish_event(event_type, payload):
            return None

        async def shop_owner_id(shop_id):
            return OWNER_ID

        orders_router.notify_users = notify_users
        orders_router.publish_event = publish_event
        orders_router._shop_owner_id = shop_owner_id

        session = self.Session()
        session.add(
            DeliveryAgentProfile(
                user_id=AGENT_ID, vehicle_type=VehicleType.bike, is_available=True
            )
        )
        session.commit()
        session.close()

    def tearDown(self):
        for name, original in self.originals.items():
            setattr(orders_router, name, original)
        self.engine.dispose()

    def _order(self, status=OrderStatus.pending, agent_id=None) -> str:
        order = Order(
            customer_id=CUSTOMER_ID,
            shop_id=SHOP_ID,
            agent_id=agent_id,
            items="[]",
            delivery_address="1 Test Rd",
            delivery_lat=6.93,
            delivery_lng=79.86,
            status=status,
            pickup_code="4276",
            delivery_code="8122",
        )
        session = self.Session()
        session.add(order)
        session.commit()
        order_id = order.id
        session.close()
        return order_id

    # --- accept ---
    def test_a_cancelled_order_says_it_was_cancelled(self):
        order_id = self._order(status=OrderStatus.cancelled)
        response = self.client.patch(f"/delivery/orders/{order_id}/accept", headers=AGENT)
        self.assertEqual(response.status_code, 409)
        detail = response.json()["detail"]
        self.assertIn("cancelled", detail.lower())
        self.assertNotIn("another agent", detail.lower())

    def test_a_delivered_order_says_it_is_done(self):
        order_id = self._order(status=OrderStatus.delivered, agent_id=OTHER_AGENT_ID)
        response = self.client.patch(f"/delivery/orders/{order_id}/accept", headers=AGENT)
        self.assertEqual(response.status_code, 409)
        self.assertIn("delivered", response.json()["detail"].lower())

    def test_an_order_another_agent_holds_still_says_so(self):
        """The message that was wrong everywhere is still right here."""
        order_id = self._order(status=OrderStatus.accepted, agent_id=OTHER_AGENT_ID)
        response = self.client.patch(f"/delivery/orders/{order_id}/accept", headers=AGENT)
        self.assertEqual(response.status_code, 409)
        self.assertIn("another agent", response.json()["detail"].lower())

    def test_a_pending_order_is_still_acceptable(self):
        order_id = self._order()
        response = self.client.patch(f"/delivery/orders/{order_id}/accept", headers=AGENT)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["status"], "accepted")

    # --- reject ---
    def test_rejecting_a_cancelled_order_says_it_was_cancelled(self):
        """Reject shares the guard, so it shared the wrong sentence too."""
        order_id = self._order(status=OrderStatus.cancelled)
        response = self.client.post(f"/delivery/orders/{order_id}/reject", headers=AGENT)
        self.assertEqual(response.status_code, 409)
        detail = response.json()["detail"]
        self.assertIn("cancelled", detail.lower())
        self.assertNotIn("another agent", detail.lower())

    def test_rejecting_an_order_another_agent_holds_still_says_so(self):
        order_id = self._order(status=OrderStatus.accepted, agent_id=OTHER_AGENT_ID)
        response = self.client.post(f"/delivery/orders/{order_id}/reject", headers=AGENT)
        self.assertEqual(response.status_code, 409)
        self.assertIn("another agent", response.json()["detail"].lower())


if __name__ == "__main__":
    unittest.main()
