"""Item 8: who may cancel an order, who is told, and when admins are alerted.

Run against the real route over an in-memory SQLite database. shop-service
and the event bus are stubbed: what matters here is who delivery-service
decides to notify, not that Redis is up.

    cd services/delivery-service
    JWT_SECRET=<32+ chars> python -m pytest tests/test_cancellations.py -q
"""

import unittest
from datetime import datetime, timedelta, timezone

import jwt
from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app import stock
from app.config import settings
from app.database import Base, get_db
from app.models import Order, OrderStatus
from app.routers import orders_router

CUSTOMER_ID = "11111111-1111-1111-1111-111111111111"
OWNER_ID = "22222222-2222-2222-2222-222222222222"
OTHER_OWNER_ID = "33333333-3333-3333-3333-333333333333"
AGENT_ID = "44444444-4444-4444-4444-444444444444"
ADMIN_ID = "55555555-5555-5555-5555-555555555555"
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


class CancellationTests(unittest.TestCase):
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

        # --- stub everything that leaves the service ---
        self.notifications: list[dict] = []
        self.events: list[dict] = []
        self.released: list[str] = []
        self.shop_service_up = True

        self.originals = {
            "notify_users": orders_router.notify_users,
            "publish_event": orders_router.publish_event,
            "owns_shop": orders_router._owns_shop,
            "shop_owner_id": orders_router._shop_owner_id,
            "admin_ids": orders_router._admin_ids,
            "release": stock.release,
        }

        async def notify_users(user_ids, title, body, kind="general", link=None):
            self.notifications.append(
                {"user_ids": list(user_ids), "title": title, "body": body}
            )

        async def publish_event(event_type, payload):
            self.events.append({"event": event_type, "data": payload})

        async def owns_shop(shop_id, user_id):
            # An unreachable shop-service denies ownership, as in production.
            return self.shop_service_up and shop_id == SHOP_ID and user_id == OWNER_ID

        async def shop_owner_id(shop_id):
            return OWNER_ID if self.shop_service_up else None

        async def admin_ids():
            return [ADMIN_ID] if self.shop_service_up else []

        async def release(shop_id, order_id):
            self.released.append(order_id)
            return True

        orders_router.notify_users = notify_users
        orders_router.publish_event = publish_event
        orders_router._owns_shop = owns_shop
        orders_router._shop_owner_id = shop_owner_id
        orders_router._admin_ids = admin_ids
        stock.release = release

    def tearDown(self):
        orders_router.notify_users = self.originals["notify_users"]
        orders_router.publish_event = self.originals["publish_event"]
        orders_router._owns_shop = self.originals["owns_shop"]
        orders_router._shop_owner_id = self.originals["shop_owner_id"]
        orders_router._admin_ids = self.originals["admin_ids"]
        stock.release = self.originals["release"]
        self.engine.dispose()

    # --- helpers ---
    def _order(
        self,
        *,
        status=OrderStatus.pending,
        agent_id=None,
        shop_id=SHOP_ID,
        customer_id=CUSTOMER_ID,
        cancelled_by=None,
        cancelled_at=None,
        reserved=True,
    ) -> str:
        order = Order(
            customer_id=customer_id,
            shop_id=shop_id,
            agent_id=agent_id,
            items="[]",
            pickup_address="Shop, Colombo",
            pickup_lat=6.9271,
            pickup_lng=79.8612,
            delivery_address="1 Test Rd",
            delivery_lat=6.93,
            delivery_lng=79.86,
            status=status,
            cancelled_by=cancelled_by,
            cancelled_at=cancelled_at,
            stock_reserved_at=datetime.now(timezone.utc) if reserved else None,
        )
        session = self.Session()
        session.add(order)
        session.commit()
        order_id = order.id
        session.close()
        return order_id

    def _cancel(self, order_id, headers, reason=None):
        body = {} if reason is None else {"reason": reason}
        return self.client.request(
            "PATCH",
            f"/delivery/orders/{order_id}/cancel",
            json=body,
            headers=headers,
        )

    def _stored(self, order_id) -> Order:
        session = self.Session()
        try:
            order = session.get(Order, order_id)
            session.refresh(order)
            return order
        finally:
            session.close()

    def _notified(self) -> set[str]:
        return {
            user_id
            for notification in self.notifications
            for user_id in notification["user_ids"]
        }

    # --- who may cancel ---
    def test_the_shop_owner_can_cancel_their_own_order(self):
        order_id = self._order()
        response = self._cancel(
            order_id, _auth(OWNER_ID, "shop_owner"), reason="Out of gas"
        )
        self.assertEqual(response.status_code, 200)
        stored = self._stored(order_id)
        self.assertEqual(stored.status, OrderStatus.cancelled)
        self.assertEqual(stored.cancelled_by, "shop")
        self.assertEqual(stored.cancel_reason, "Out of gas")
        self.assertIsNotNone(stored.cancelled_at)

    def test_an_owner_of_another_shop_cannot_cancel_it(self):
        order_id = self._order()
        response = self._cancel(
            order_id, _auth(OTHER_OWNER_ID, "shop_owner"), reason="Nope"
        )
        self.assertEqual(response.status_code, 403)
        self.assertEqual(self._stored(order_id).status, OrderStatus.pending)

    def test_the_customer_can_still_cancel_without_a_reason(self):
        order_id = self._order()
        response = self._cancel(order_id, _auth(CUSTOMER_ID, "user"))
        self.assertEqual(response.status_code, 200)
        stored = self._stored(order_id)
        self.assertEqual(stored.cancelled_by, "customer")
        self.assertIsNone(stored.cancel_reason)

    def test_an_admin_can_cancel_with_a_reason(self):
        order_id = self._order()
        response = self._cancel(
            order_id, _auth(ADMIN_ID, "admin"), reason="Fraudulent order"
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(self._stored(order_id).cancelled_by, "admin")

    def test_a_shop_must_give_a_reason(self):
        order_id = self._order()
        response = self._cancel(order_id, _auth(OWNER_ID, "shop_owner"))
        self.assertEqual(response.status_code, 422)
        self.assertEqual(self._stored(order_id).status, OrderStatus.pending)

    def test_a_blank_reason_does_not_count_as_a_reason(self):
        order_id = self._order()
        response = self._cancel(order_id, _auth(OWNER_ID, "shop_owner"), reason="   ")
        self.assertEqual(response.status_code, 422)

    def test_an_admin_must_give_a_reason_too(self):
        order_id = self._order()
        self.assertEqual(
            self._cancel(order_id, _auth(ADMIN_ID, "admin")).status_code, 422
        )

    def test_a_stranger_cannot_cancel(self):
        order_id = self._order()
        response = self._cancel(order_id, _auth("nobody", "user"), reason="x")
        self.assertEqual(response.status_code, 403)

    # --- when cancelling is allowed ---
    def test_a_shop_cannot_cancel_after_pickup(self):
        order_id = self._order(status=OrderStatus.in_transit, agent_id=AGENT_ID)
        response = self._cancel(order_id, _auth(OWNER_ID, "shop_owner"), reason="late")
        self.assertEqual(response.status_code, 400)

    def test_an_accepted_order_can_still_be_cancelled(self):
        order_id = self._order(status=OrderStatus.accepted, agent_id=AGENT_ID)
        response = self._cancel(order_id, _auth(OWNER_ID, "shop_owner"), reason="late")
        self.assertEqual(response.status_code, 200)

    def test_cancelling_twice_is_refused_the_second_time(self):
        order_id = self._order()
        first = self._cancel(order_id, _auth(OWNER_ID, "shop_owner"), reason="late")
        self.assertEqual(first.status_code, 200)
        before = len(self.notifications)

        second = self._cancel(order_id, _auth(OWNER_ID, "shop_owner"), reason="late")
        self.assertEqual(second.status_code, 400)
        # No second round of "your order was cancelled".
        self.assertEqual(len(self.notifications), before)

    def test_the_stock_is_returned_once(self):
        order_id = self._order()
        self._cancel(order_id, _auth(CUSTOMER_ID, "user"))
        self._cancel(order_id, _auth(CUSTOMER_ID, "user"))
        self.assertEqual(self.released, [order_id])

    # --- who is told ---
    def test_a_shop_cancellation_tells_the_customer_with_the_reason(self):
        order_id = self._order()
        self._cancel(order_id, _auth(OWNER_ID, "shop_owner"), reason="Power cut")
        self.assertIn(CUSTOMER_ID, self._notified())
        self.assertTrue(
            any("Power cut" in n["body"] for n in self.notifications),
            self.notifications,
        )

    def test_a_shop_cancellation_also_tells_the_assigned_driver(self):
        order_id = self._order(status=OrderStatus.accepted, agent_id=AGENT_ID)
        self._cancel(order_id, _auth(OWNER_ID, "shop_owner"), reason="Power cut")
        self.assertEqual(self._notified(), {CUSTOMER_ID, AGENT_ID})

    def test_a_customer_cancellation_tells_the_owner_and_the_driver(self):
        order_id = self._order(status=OrderStatus.accepted, agent_id=AGENT_ID)
        self._cancel(order_id, _auth(CUSTOMER_ID, "user"))
        self.assertEqual(self._notified(), {OWNER_ID, AGENT_ID})

    def test_with_no_driver_only_the_owner_is_told(self):
        order_id = self._order()
        self._cancel(order_id, _auth(CUSTOMER_ID, "user"))
        self.assertEqual(self._notified(), {OWNER_ID})

    def test_an_admin_cancellation_tells_all_three(self):
        order_id = self._order(status=OrderStatus.accepted, agent_id=AGENT_ID)
        self._cancel(order_id, _auth(ADMIN_ID, "admin"), reason="Duplicate order")
        self.assertEqual(self._notified(), {CUSTOMER_ID, OWNER_ID, AGENT_ID})

    def test_the_cancellation_event_says_who_did_it(self):
        order_id = self._order()
        self._cancel(order_id, _auth(OWNER_ID, "shop_owner"), reason="Power cut")
        cancelled = [e for e in self.events if e["event"] == "order.cancelled"]
        self.assertEqual(len(cancelled), 1)
        self.assertEqual(cancelled[0]["data"]["cancelled_by"], "shop")
        self.assertEqual(cancelled[0]["data"]["reason"], "Power cut")

    def test_a_cancellation_survives_an_unreachable_shop_service(self):
        """The customer's own cancellation must not fail, only go unannounced."""
        order_id = self._order()
        self.shop_service_up = False
        response = self._cancel(order_id, _auth(CUSTOMER_ID, "user"))
        self.assertEqual(response.status_code, 200)
        self.assertEqual(self._stored(order_id).status, OrderStatus.cancelled)
        self.assertEqual(self.notifications, [])

    # --- the admin alert ---
    def _cancel_n_shop_orders(self, count, *, days_ago=0):
        when = datetime.now(timezone.utc) - timedelta(days=days_ago)
        for index in range(count):
            self._order(
                status=OrderStatus.cancelled,
                cancelled_by="shop",
                cancelled_at=when,
            )

    def test_the_third_cancellation_in_the_window_alerts_admins(self):
        self._cancel_n_shop_orders(2)
        order_id = self._order()
        self._cancel(order_id, _auth(OWNER_ID, "shop_owner"), reason="Closed early")

        alerts = [e for e in self.events if e["event"] == "shop.cancellation_threshold"]
        self.assertEqual(len(alerts), 1)
        self.assertEqual(alerts[0]["data"]["count"], 3)
        self.assertEqual(alerts[0]["data"]["shop_id"], SHOP_ID)
        self.assertEqual(alerts[0]["data"]["admin_ids"], [ADMIN_ID])
        # The owner is warned as well.
        self.assertTrue(
            any(n["user_ids"] == [OWNER_ID] for n in self.notifications),
            self.notifications,
        )

    def test_the_second_cancellation_alerts_nobody(self):
        self._cancel_n_shop_orders(1)
        order_id = self._order()
        self._cancel(order_id, _auth(OWNER_ID, "shop_owner"), reason="Closed early")
        self.assertEqual(
            [e for e in self.events if e["event"] == "shop.cancellation_threshold"], []
        )

    def test_the_fourth_cancellation_does_not_alert_again(self):
        self._cancel_n_shop_orders(3)
        order_id = self._order()
        self._cancel(order_id, _auth(OWNER_ID, "shop_owner"), reason="Closed early")
        self.assertEqual(
            [e for e in self.events if e["event"] == "shop.cancellation_threshold"], []
        )

    def test_a_cancellation_older_than_the_window_does_not_count(self):
        self._cancel_n_shop_orders(2, days_ago=8)
        order_id = self._order()
        self._cancel(order_id, _auth(OWNER_ID, "shop_owner"), reason="Closed early")
        self.assertEqual(
            [e for e in self.events if e["event"] == "shop.cancellation_threshold"], []
        )

    def test_a_customer_cancellation_does_not_count_towards_the_shop(self):
        # Two customer cancellations plus one shop cancellation is not three.
        for _ in range(2):
            self._order(
                status=OrderStatus.cancelled,
                cancelled_by="customer",
                cancelled_at=datetime.now(timezone.utc),
            )
        order_id = self._order()
        self._cancel(order_id, _auth(OWNER_ID, "shop_owner"), reason="Closed early")
        self.assertEqual(
            [e for e in self.events if e["event"] == "shop.cancellation_threshold"], []
        )

    def test_another_shops_cancellations_do_not_count(self):
        for _ in range(2):
            self._order(
                shop_id="99999999-9999-9999-9999-999999999999",
                status=OrderStatus.cancelled,
                cancelled_by="shop",
                cancelled_at=datetime.now(timezone.utc),
            )
        order_id = self._order()
        self._cancel(order_id, _auth(OWNER_ID, "shop_owner"), reason="Closed early")
        self.assertEqual(
            [e for e in self.events if e["event"] == "shop.cancellation_threshold"], []
        )

    def test_a_customer_cancellation_never_triggers_the_shop_alert(self):
        self._cancel_n_shop_orders(2)
        order_id = self._order()
        self._cancel(order_id, _auth(CUSTOMER_ID, "user"))
        self.assertEqual(
            [e for e in self.events if e["event"] == "shop.cancellation_threshold"], []
        )


class CustomerDailyLimitTests(unittest.TestCase):
    """Only the customer's own cancellations may lock them out of ordering."""

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

        self.original_publish = orders_router.publish_event

        async def publish_event(event_type, payload):
            return None

        orders_router.publish_event = publish_event

    def tearDown(self):
        orders_router.publish_event = self.original_publish
        self.engine.dispose()

    def _cancelled(self, count, cancelled_by):
        session = self.Session()
        for _ in range(count):
            session.add(
                Order(
                    customer_id=CUSTOMER_ID,
                    shop_id=SHOP_ID,
                    items="[]",
                    delivery_address="1 Test Rd",
                    delivery_lat=6.93,
                    delivery_lng=79.86,
                    status=OrderStatus.cancelled,
                    cancelled_by=cancelled_by,
                    cancelled_at=datetime.now(timezone.utc),
                )
            )
        session.commit()
        session.close()

    def _place(self):
        return self.client.post(
            "/delivery/orders",
            json={
                "shop_id": SHOP_ID,
                "delivery_address": "1 Test Rd",
                "delivery_lat": 6.93,
                "delivery_lng": 79.86,
                "items": [],
            },
            headers=_auth(CUSTOMER_ID, "user"),
        )

    def test_too_many_of_the_customers_own_cancellations_blocks_ordering(self):
        self._cancelled(settings.max_cancellations_per_day, "customer")
        self.assertEqual(self._place().status_code, 429)

    def test_shop_cancellations_do_not_block_the_customer(self):
        self._cancelled(settings.max_cancellations_per_day + 2, "shop")
        self.assertEqual(self._place().status_code, 201)

    def test_auto_expired_orders_do_not_block_the_customer(self):
        self._cancelled(settings.max_cancellations_per_day + 2, "system")
        self.assertEqual(self._place().status_code, 201)

    def test_orders_cancelled_before_this_shipped_do_not_block_the_customer(self):
        # cancelled_by is NULL on them: nobody recorded who cancelled.
        self._cancelled(settings.max_cancellations_per_day + 2, None)
        self.assertEqual(self._place().status_code, 201)


if __name__ == "__main__":
    unittest.main()
