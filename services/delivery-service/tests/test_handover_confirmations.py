"""The shop owner and the customer can confirm the two handovers themselves.

Beside the agent typing a code: these work when the agent's phone has no
signal, which used to leave an order stuck at "Heading to the shop". Run
against the real routes over in-memory SQLite, with shop-service and the
event bus stubbed.

    cd services/delivery-service
    JWT_SECRET=<32+ chars> python -m pytest tests/test_handover_confirmations.py -q
"""

import asyncio
import unittest
from datetime import datetime, timedelta, timezone

import jwt
from fastapi import FastAPI, HTTPException
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app.config import settings
from app.database import Base, get_db
from app.models import DeliveryAgentProfile, Order, OrderStatus, VehicleType
from app.routers import orders_router

CUSTOMER_ID = "11111111-1111-1111-1111-111111111111"
OWNER_ID = "22222222-2222-2222-2222-222222222222"
OTHER_OWNER_ID = "33333333-3333-3333-3333-333333333333"
AGENT_ID = "44444444-4444-4444-4444-444444444444"
OTHER_CUSTOMER_ID = "55555555-5555-5555-5555-555555555555"
SHOP_ID = "66666666-6666-6666-6666-666666666666"


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


OWNER = _auth(OWNER_ID, "shop_owner")
OTHER_OWNER = _auth(OTHER_OWNER_ID, "shop_owner")
CUSTOMER = _auth(CUSTOMER_ID, "user")
OTHER_CUSTOMER = _auth(OTHER_CUSTOMER_ID, "user")
AGENT = _auth(AGENT_ID, "delivery_agent")


class HandoverConfirmationTests(unittest.TestCase):
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

        self.notifications: list[dict] = []
        self.events: list[dict] = []
        self.originals = {
            name: getattr(orders_router, name)
            for name in ("notify_users", "publish_event", "_owns_shop", "_shop_owner_id")
        }

        async def notify_users(user_ids, title, body, kind="general", link=None):
            self.notifications.append({"user_ids": list(user_ids), "title": title})

        async def publish_event(event_type, payload):
            self.events.append({"event": event_type, "data": payload})

        async def owns_shop(shop_id, user_id):
            return shop_id == SHOP_ID and user_id == OWNER_ID

        async def shop_owner_id(shop_id):
            return OWNER_ID

        orders_router.notify_users = notify_users
        orders_router.publish_event = publish_event
        orders_router._owns_shop = owns_shop
        orders_router._shop_owner_id = shop_owner_id

        session = self.Session()
        session.add(DeliveryAgentProfile(user_id=AGENT_ID, vehicle_type=VehicleType.bike))
        session.commit()
        session.close()

    def tearDown(self):
        for name, original in self.originals.items():
            setattr(orders_router, name, original)
        self.engine.dispose()

    # --- helpers ---
    def _order(self, status=OrderStatus.accepted, agent_id=AGENT_ID) -> str:
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

    def _stored(self, order_id) -> Order:
        session = self.Session()
        try:
            return session.get(Order, order_id)
        finally:
            session.close()

    def _deliveries(self) -> int:
        session = self.Session()
        try:
            return session.query(DeliveryAgentProfile).first().total_deliveries
        finally:
            session.close()

    def _confirm_pickup(self, order_id, headers=OWNER):
        return self.client.post(f"/delivery/orders/{order_id}/confirm-pickup", headers=headers)

    def _confirm_delivery(self, order_id, headers=CUSTOMER):
        return self.client.post(f"/delivery/orders/{order_id}/confirm-delivery", headers=headers)

    def _notified(self, user_id) -> list[str]:
        return [n["title"] for n in self.notifications if user_id in n["user_ids"]]

    # --- the shop owner confirms the pickup ---
    def test_the_owner_confirming_the_pickup_puts_the_order_on_its_way(self):
        order_id = self._order()
        response = self._confirm_pickup(order_id)
        self.assertEqual(response.status_code, 200, response.text)
        stored = self._stored(order_id)
        self.assertEqual(stored.status, OrderStatus.in_transit)
        self.assertIsNotNone(stored.picked_up_at)

    def test_the_agent_hears_the_shop_confirmed_for_them(self):
        order_id = self._order()
        self._confirm_pickup(order_id)
        self.assertEqual(self._notified(AGENT_ID), ["Pickup confirmed by the shop"])

    def test_the_event_says_the_shop_confirmed_it(self):
        order_id = self._order()
        self._confirm_pickup(order_id)
        changes = [e["data"] for e in self.events if e["event"] == "order.status_changed"]
        self.assertEqual([c["status"] for c in changes], ["picked_up", "in_transit"])
        self.assertTrue(all(c["confirmed_by"] == "shop_owner" for c in changes))

    def test_another_shops_owner_cannot_confirm_the_pickup(self):
        order_id = self._order()
        self.assertEqual(self._confirm_pickup(order_id, OTHER_OWNER).status_code, 403)
        self.assertEqual(self._stored(order_id).status, OrderStatus.accepted)

    def test_a_customer_cannot_confirm_the_pickup(self):
        order_id = self._order()
        self.assertEqual(self._confirm_pickup(order_id, CUSTOMER).status_code, 403)

    def test_there_is_no_pickup_before_a_driver_accepts(self):
        order_id = self._order(status=OrderStatus.pending, agent_id=None)
        response = self._confirm_pickup(order_id)
        self.assertEqual(response.status_code, 400)
        self.assertIn("No driver", response.json()["detail"])

    def test_a_pickup_cannot_be_confirmed_twice(self):
        order_id = self._order()
        self._confirm_pickup(order_id)
        response = self._confirm_pickup(order_id)
        self.assertEqual(response.status_code, 400)
        self.assertIn("already been picked up", response.json()["detail"])

    # --- the customer confirms the delivery ---
    def test_the_customer_confirming_receipt_delivers_the_order(self):
        order_id = self._order(status=OrderStatus.in_transit)
        response = self._confirm_delivery(order_id)
        self.assertEqual(response.status_code, 200, response.text)
        stored = self._stored(order_id)
        self.assertEqual(stored.status, OrderStatus.delivered)
        self.assertIsNotNone(stored.delivered_at)

    def test_the_agent_is_credited_and_both_others_are_told(self):
        order_id = self._order(status=OrderStatus.in_transit)
        self._confirm_delivery(order_id)
        self.assertEqual(self._deliveries(), 1)
        self.assertEqual(self._notified(AGENT_ID), ["Delivery confirmed by the customer"])
        self.assertEqual(self._notified(OWNER_ID), ["Parcel received"])

    def test_another_customer_cannot_confirm_the_delivery(self):
        order_id = self._order(status=OrderStatus.in_transit)
        self.assertEqual(self._confirm_delivery(order_id, OTHER_CUSTOMER).status_code, 403)
        self.assertEqual(self._stored(order_id).status, OrderStatus.in_transit)

    def test_nothing_can_be_received_before_the_pickup(self):
        order_id = self._order(status=OrderStatus.accepted)
        response = self._confirm_delivery(order_id)
        self.assertEqual(response.status_code, 400)
        self.assertIn("not collected", response.json()["detail"])

    def test_a_delivery_the_agent_already_confirmed_is_not_counted_again(self):
        order_id = self._order(status=OrderStatus.in_transit)
        agent = self.client.patch(
            f"/delivery/orders/{order_id}/status",
            json={"status": "delivered", "code": "8122"},
            headers=AGENT,
        )
        self.assertEqual(agent.status_code, 200, agent.text)
        response = self._confirm_delivery(order_id)
        self.assertEqual(response.status_code, 400)
        self.assertEqual(self._deliveries(), 1)

    # --- the agent's code still works, and the race is closed ---
    def test_the_agent_can_still_confirm_the_pickup_with_the_code(self):
        order_id = self._order()
        response = self.client.patch(
            f"/delivery/orders/{order_id}/status",
            json={"status": "picked_up", "code": "4276"},
            headers=AGENT,
        )
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(self._stored(order_id).status, OrderStatus.in_transit)
        changes = [e["data"] for e in self.events if e["event"] == "order.status_changed"]
        self.assertTrue(all(c["confirmed_by"] == "agent" for c in changes))
        # Nobody else confirmed, so the agent is not told what they just did.
        self.assertEqual(self._notified(AGENT_ID), [])

    def test_a_confirmation_that_lost_a_race_changes_nothing(self):
        order_id = self._order(status=OrderStatus.in_transit)
        slow = self.Session()
        stale = slow.get(Order, order_id)  # read before the other confirmation lands
        fast = self.Session()
        fast.get(Order, order_id).status = OrderStatus.delivered
        fast.commit()
        fast.close()

        with self.assertRaises(HTTPException) as caught:
            asyncio.run(
                orders_router._complete_handover(
                    slow, stale, OrderStatus.delivered, confirmed_by="customer"
                )
            )
        slow.close()
        self.assertEqual(caught.exception.status_code, 409)
        self.assertEqual(self._deliveries(), 0)


if __name__ == "__main__":
    unittest.main()
