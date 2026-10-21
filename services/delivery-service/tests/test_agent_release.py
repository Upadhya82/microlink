"""An agent can hand an accepted order back before they have collected it.

Accepting an order they then cannot do used to be a dead end: an agent may
hold only one active order (REQ-AGENT-3), so the stuck one locked them out
of every other delivery and nothing in the app could clear it. These run
against the real routes over in-memory SQLite, with shop-service and the
event bus stubbed.

    cd services/delivery-service
    JWT_SECRET=<32+ chars> python -m pytest tests/test_agent_release.py -q
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
from app.expiry import expired_orders
from app.models import (
    DeliveryAgentProfile,
    Order,
    OrderRejection,
    OrderStatus,
    VehicleType,
)
from app.routers import orders_router

CUSTOMER_ID = "11111111-1111-1111-1111-111111111111"
AGENT_ID = "44444444-4444-4444-4444-444444444444"
OTHER_AGENT_ID = "77777777-7777-7777-7777-777777777777"
SHOP_ID = "66666666-6666-6666-6666-666666666666"
OWNER_ID = "22222222-2222-2222-2222-222222222222"
ADMIN_ID = "33333333-3333-3333-3333-333333333333"


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
OTHER_AGENT = _auth(OTHER_AGENT_ID, "delivery_agent")
CUSTOMER = _auth(CUSTOMER_ID, "user")


class AgentReleaseTests(unittest.TestCase):
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
            for name in (
                "notify_users",
                "publish_event",
                "_owns_shop",
                "_shop_owner_id",
                "_admin_ids",
            )
        }

        async def notify_users(user_ids, title, body, kind="general", link=None):
            self.notifications.append(
                {"user_ids": list(user_ids), "title": title, "body": body}
            )

        async def publish_event(event_type, payload):
            self.events.append({"event": event_type, "data": payload})

        async def owns_shop(shop_id, user_id):
            return False

        async def shop_owner_id(shop_id):
            return OWNER_ID

        async def admin_ids():
            return [ADMIN_ID]

        orders_router.notify_users = notify_users
        orders_router.publish_event = publish_event
        orders_router._owns_shop = owns_shop
        orders_router._shop_owner_id = shop_owner_id
        orders_router._admin_ids = admin_ids

        session = self.Session()
        # Online, with no position recorded: the available list then skips
        # the radius filter, so these tests do not depend on coordinates.
        for user_id in (AGENT_ID, OTHER_AGENT_ID):
            session.add(
                DeliveryAgentProfile(
                    user_id=user_id, vehicle_type=VehicleType.bike, is_available=True
                )
            )
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
            accepted_at=datetime.now(timezone.utc) if agent_id else None,
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

    def _release(self, order_id, headers=AGENT, reason="My bike has broken down"):
        body = {} if reason is None else {"reason": reason}
        return self.client.post(
            f"/delivery/orders/{order_id}/release", headers=headers, json=body
        )

    def _notified(self, user_id) -> list[str]:
        return [n["title"] for n in self.notifications if user_id in n["user_ids"]]

    def _available(self, headers=AGENT) -> list[str]:
        response = self.client.get("/delivery/orders/available", headers=headers)
        self.assertEqual(response.status_code, 200, response.text)
        return [row["id"] for row in response.json()]

    # --- the happy path ---
    def test_releasing_puts_the_order_back_on_offer(self):
        order_id = self._order()
        response = self._release(order_id)
        self.assertEqual(response.status_code, 200, response.text)
        stored = self._stored(order_id)
        self.assertEqual(stored.status, OrderStatus.pending)
        self.assertIsNone(stored.agent_id)
        self.assertIsNone(stored.accepted_at)
        self.assertIsNotNone(stored.reopened_at)

    def test_the_order_is_not_cancelled(self):
        """The customer still wants their delivery; only the driver changed."""
        order_id = self._order()
        self._release(order_id)
        self.assertIsNone(self._stored(order_id).cancelled_at)

    def test_the_agent_can_accept_another_order_afterwards(self):
        """The whole point: the one-at-a-time rule no longer traps them."""
        stuck = self._order()
        waiting = self._order(status=OrderStatus.pending, agent_id=None)

        blocked = self.client.patch(f"/delivery/orders/{waiting}/accept", headers=AGENT)
        self.assertEqual(blocked.status_code, 409)
        self.assertIn("active delivery", blocked.json()["detail"])

        self._release(stuck)
        accepted = self.client.patch(f"/delivery/orders/{waiting}/accept", headers=AGENT)
        self.assertEqual(accepted.status_code, 200, accepted.text)

    def test_the_released_order_does_not_come_back_to_the_same_agent(self):
        order_id = self._order()
        self._release(order_id)
        self.assertNotIn(order_id, self._available(AGENT))

    def test_another_agent_is_offered_it(self):
        order_id = self._order()
        self._release(order_id)
        self.assertIn(order_id, self._available(OTHER_AGENT))

    def test_another_agent_can_accept_it(self):
        order_id = self._order()
        self._release(order_id)
        response = self.client.patch(
            f"/delivery/orders/{order_id}/accept", headers=OTHER_AGENT
        )
        self.assertEqual(response.status_code, 200, response.text)
        self.assertEqual(self._stored(order_id).agent_id, OTHER_AGENT_ID)

    def test_the_old_agents_eta_is_cleared(self):
        session = self.Session()
        order = Order(
            customer_id=CUSTOMER_ID,
            shop_id=SHOP_ID,
            agent_id=AGENT_ID,
            items="[]",
            delivery_address="1 Test Rd",
            delivery_lat=6.93,
            delivery_lng=79.86,
            status=OrderStatus.accepted,
            agent_eta_minutes=12,
            agent_notified_at=datetime.now(timezone.utc),
        )
        session.add(order)
        session.commit()
        order_id = order.id
        session.close()

        self._release(order_id)
        stored = self._stored(order_id)
        self.assertIsNone(stored.agent_eta_minutes)
        self.assertIsNone(stored.agent_notified_at)

    # --- the customer hears about it ---
    def test_the_customer_is_told_with_the_reason(self):
        order_id = self._order()
        self._release(order_id, reason="The shop is closed")
        told = [n for n in self.notifications if CUSTOMER_ID in n["user_ids"]]
        self.assertEqual(len(told), 1)
        self.assertEqual(told[0]["title"], "Looking for another driver")
        self.assertIn("The shop is closed", told[0]["body"])

    def test_an_event_is_published(self):
        order_id = self._order()
        self._release(order_id)
        released = [e for e in self.events if e["event"] == "order.released"]
        self.assertEqual(len(released), 1)
        self.assertEqual(released[0]["data"]["agent_id"], AGENT_ID)

    def test_the_release_is_recorded_on_the_order_history(self):
        order_id = self._order()
        self._release(order_id)
        response = self.client.get(f"/delivery/orders/{order_id}", headers=CUSTOMER)
        statuses = [e["status"] for e in response.json()["events"]]
        self.assertIn("released", statuses)

    # --- what is refused ---
    def test_a_collected_order_is_cancelled_rather_than_re_offered(self):
        """The parcel is in the driver bag -- no other driver can take it on."""
        for order_status in (OrderStatus.picked_up, OrderStatus.in_transit):
            with self.subTest(status=order_status):
                order_id = self._order(status=order_status)
                response = self._release(order_id)
                self.assertEqual(response.status_code, 200, response.text)
                self.assertFalse(response.json()["returned_to_pool"])
                stored = self._stored(order_id)
                self.assertEqual(stored.status, OrderStatus.cancelled)
                self.assertEqual(stored.cancelled_by, "agent")
                self.assertEqual(stored.cancelled_at is None, False)

    def test_a_collected_order_is_not_offered_to_anybody_else(self):
        order_id = self._order(status=OrderStatus.in_transit)
        self._release(order_id)
        self.assertNotIn(order_id, self._available(OTHER_AGENT))

    def test_giving_up_after_pickup_still_frees_the_agent(self):
        """The reason any of this exists: one stuck order blocked them all."""
        stuck = self._order(status=OrderStatus.in_transit)
        waiting = self._order(status=OrderStatus.pending, agent_id=None)

        blocked = self.client.patch(f"/delivery/orders/{waiting}/accept", headers=AGENT)
        self.assertEqual(blocked.status_code, 409)

        self._release(stuck)
        accepted = self.client.patch(f"/delivery/orders/{waiting}/accept", headers=AGENT)
        self.assertEqual(accepted.status_code, 200, accepted.text)

    def test_the_customer_shop_and_admins_all_hear_the_parcel_is_coming_back(self):
        order_id = self._order(status=OrderStatus.in_transit)
        self._release(order_id, reason="I have been taken ill")
        self.assertEqual(
            self._notified(CUSTOMER_ID), ["Your delivery could not be completed"]
        )
        self.assertEqual(self._notified(OWNER_ID), ["A parcel is being returned"])
        self.assertEqual(self._notified(ADMIN_ID), ["A driver dropped a collected order"])
        told = [n for n in self.notifications if CUSTOMER_ID in n["user_ids"]][0]
        self.assertIn("I have been taken ill", told["body"])

    def test_giving_up_after_pickup_publishes_a_cancellation(self):
        order_id = self._order(status=OrderStatus.in_transit)
        self._release(order_id)
        cancelled = [e for e in self.events if e["event"] == "order.cancelled"]
        self.assertEqual(len(cancelled), 1)
        self.assertEqual(cancelled[0]["data"]["cancelled_by"], "agent")

    def test_another_agents_order_cannot_be_handed_back(self):
        order_id = self._order()
        response = self._release(order_id, headers=OTHER_AGENT)
        self.assertEqual(response.status_code, 403)
        self.assertEqual(self._stored(order_id).agent_id, AGENT_ID)

    def test_an_unaccepted_order_has_nothing_to_hand_back(self):
        order_id = self._order(status=OrderStatus.pending, agent_id=None)
        response = self._release(order_id)
        self.assertEqual(response.status_code, 403)

    def test_a_delivered_order_cannot_be_handed_back(self):
        order_id = self._order(status=OrderStatus.delivered)
        response = self._release(order_id)
        self.assertEqual(response.status_code, 400)
        self.assertIn("already been delivered", response.json()["detail"])

    def test_the_customer_cannot_release_an_order(self):
        order_id = self._order()
        response = self._release(order_id, headers=CUSTOMER)
        self.assertEqual(response.status_code, 403)

    def test_a_reason_is_required(self):
        for reason in (None, "", "  ", "x"):
            with self.subTest(reason=reason):
                order_id = self._order()
                response = self._release(order_id, reason=reason)
                self.assertEqual(response.status_code, 422)
                self.assertEqual(self._stored(order_id).status, OrderStatus.accepted)

    def test_releasing_twice_is_refused(self):
        order_id = self._order()
        self.assertEqual(self._release(order_id).status_code, 200)
        self.assertEqual(self._release(order_id).status_code, 403)

    def test_a_rejected_then_released_order_keeps_one_rejection_row(self):
        """The Reject button and this share a row, so the second must update it."""
        order_id = self._order(status=OrderStatus.pending, agent_id=None)
        self.client.post(f"/delivery/orders/{order_id}/reject", headers=AGENT, json={})
        session = self.Session()
        order = session.get(Order, order_id)
        order.agent_id = AGENT_ID
        order.status = OrderStatus.accepted
        session.commit()
        session.close()

        self.assertEqual(self._release(order_id).status_code, 200)
        session = self.Session()
        try:
            rows = (
                session.query(OrderRejection)
                .filter(OrderRejection.order_id == order_id)
                .all()
            )
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0].reason, "released")
        finally:
            session.close()

    # --- the unclaimed sweep ---
    def test_a_released_order_gets_a_fresh_wait_before_the_sweep_cancels_it(self):
        """Counting from `created_at` would cancel it before anyone saw it."""
        now = datetime.now(timezone.utc)
        order_id = self._order()
        session = self.Session()
        order = session.get(Order, order_id)
        order.created_at = now - timedelta(hours=6)
        session.commit()
        session.close()

        self._release(order_id)
        released = self._stored(order_id)
        self.assertEqual(expired_orders([released], now), [])
        # ...and it is still swept once the new wait is itself too long.
        self.assertEqual(
            [o.id for o in expired_orders([released], now + timedelta(hours=6))],
            [order_id],
        )


if __name__ == "__main__":
    unittest.main()
