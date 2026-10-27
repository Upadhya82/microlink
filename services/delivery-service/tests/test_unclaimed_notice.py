"""Telling the customer their order is still waiting, instead of ending it.

An order nobody has accepted yet is not a failed order. It used to be
cancelled for the customer after an hour, which took the decision away from
the only person entitled to make it -- and before that the agent's own
screen dropped the offer after thirty seconds, so an order could go
unanswered while the one driver nearby was looking straight at it.

Now the customer is told after `unclaimed_notice_minutes` and the order
stays on offer until an agent takes it or the customer ends it.

    cd services/delivery-service
    JWT_SECRET=<32+ chars> python -m pytest tests/test_unclaimed_notice.py -q
"""

import asyncio
import unittest
from datetime import datetime, timedelta, timezone

from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app import expiry
from app.config import settings
from app.database import Base
from app.expiry import (
    UNCLAIMED_NOTICE_MINUTES,
    orders_awaiting_notice,
    waiting_since,
)
from app.models import Order, OrderStatus

NOW = datetime(2026, 10, 27, 12, 0, tzinfo=timezone.utc)
CUSTOMER_ID = "11111111-1111-1111-1111-111111111111"
AGENT_ID = "44444444-4444-4444-4444-444444444444"
SHOP_ID = "66666666-6666-6666-6666-666666666666"


class FakeOrder:
    """Just the fields the rule reads."""

    def __init__(
        self,
        status=OrderStatus.pending,
        agent_id=None,
        minutes_ago=UNCLAIMED_NOTICE_MINUTES + 1,
        notified=False,
        reopened_minutes_ago=None,
    ):
        self.status = status
        self.agent_id = agent_id
        self.created_at = NOW - timedelta(minutes=minutes_ago)
        self.reopened_at = (
            None
            if reopened_minutes_ago is None
            else NOW - timedelta(minutes=reopened_minutes_ago)
        )
        self.unclaimed_notice_at = NOW if notified else None


class WhichOrdersAreDueTests(unittest.TestCase):
    def test_an_order_past_the_window_is_due(self):
        order = FakeOrder()
        self.assertEqual(orders_awaiting_notice([order], NOW), [order])

    def test_an_order_still_inside_the_window_is_left_alone(self):
        order = FakeOrder(minutes_ago=UNCLAIMED_NOTICE_MINUTES - 1)
        self.assertEqual(orders_awaiting_notice([order], NOW), [])

    def test_an_order_exactly_at_the_window_is_due(self):
        order = FakeOrder(minutes_ago=UNCLAIMED_NOTICE_MINUTES)
        self.assertEqual(orders_awaiting_notice([order], NOW), [order])

    def test_a_customer_already_told_is_not_told_again(self):
        """The sweep runs every thirty seconds; the message goes once."""
        order = FakeOrder(minutes_ago=90, notified=True)
        self.assertEqual(orders_awaiting_notice([order], NOW), [])

    def test_an_order_an_agent_has_taken_is_not_due(self):
        order = FakeOrder(status=OrderStatus.accepted, agent_id=AGENT_ID)
        self.assertEqual(orders_awaiting_notice([order], NOW), [])

    def test_a_cancelled_order_is_not_due(self):
        order = FakeOrder(status=OrderStatus.cancelled, minutes_ago=90)
        self.assertEqual(orders_awaiting_notice([order], NOW), [])

    def test_a_handed_back_order_waits_from_the_hand_back(self):
        """An order released a moment ago is waiting again, not for an hour."""
        order = FakeOrder(minutes_ago=90, reopened_minutes_ago=1)
        self.assertEqual(waiting_since(order), NOW - timedelta(minutes=1))
        self.assertEqual(orders_awaiting_notice([order], NOW), [])

    def test_the_window_is_short_so_it_reaches_someone_still_watching(self):
        self.assertEqual(UNCLAIMED_NOTICE_MINUTES, settings.unclaimed_notice_minutes)
        self.assertLessEqual(UNCLAIMED_NOTICE_MINUTES, 5)


class _SweepBase(unittest.TestCase):
    """Shared fixture: a real orders table and a captured notifier."""

    def setUp(self):
        self.engine = create_engine(
            "sqlite:///:memory:",
            connect_args={"check_same_thread": False},
            poolclass=StaticPool,
        )
        Base.metadata.create_all(self.engine)
        self.Session = sessionmaker(bind=self.engine, autoflush=False)

        self.sent: list[dict] = []
        self.originals = {
            name: getattr(expiry, name) for name in ("notify_users", "publish_event")
        }

        async def notify_users(user_ids, title, body, kind="general", link=None):
            self.sent.append(
                {"user_ids": list(user_ids), "title": title, "body": body, "link": link}
            )

        async def publish_event(event_type, payload):
            return None

        expiry.notify_users = notify_users
        expiry.publish_event = publish_event

    def tearDown(self):
        for name, original in self.originals.items():
            setattr(expiry, name, original)
        self.engine.dispose()

    def _order(self, minutes_ago=UNCLAIMED_NOTICE_MINUTES + 1) -> str:
        order = Order(
            customer_id=CUSTOMER_ID,
            shop_id=SHOP_ID,
            items="[]",
            delivery_address="1 Test Rd",
            delivery_lat=6.93,
            delivery_lng=79.86,
            status=OrderStatus.pending,
            created_at=NOW - timedelta(minutes=minutes_ago),
        )
        session = self.Session()
        session.add(order)
        session.commit()
        order_id = order.id
        session.close()
        return order_id

    def _sweep(self, fn=None):
        db = self.Session()
        try:
            return asyncio.run((fn or expiry.notify_unclaimed)(db, NOW))
        finally:
            db.close()

    def _reload(self, order_id) -> Order:
        session = self.Session()
        try:
            return session.get(Order, order_id)
        finally:
            session.close()

class NotifyUnclaimedTests(_SweepBase):
    def test_the_customer_is_told_and_nobody_else(self):
        order_id = self._order()
        self.assertEqual(self._sweep(), [order_id])
        self.assertEqual(len(self.sent), 1)
        self.assertEqual(self.sent[0]["user_ids"], [CUSTOMER_ID])

    def test_the_message_offers_a_choice_rather_than_announcing_one(self):
        self._order()
        self._sweep()
        body = self.sent[0]["body"].lower()
        self.assertIn("still waiting", body)
        self.assertIn("cancel", body)
        # The thing it must never say, because it is not what happened.
        self.assertNotIn("has been cancelled", body)

    def test_the_message_opens_the_order(self):
        """Nothing to decide with, otherwise: the cancel button is there."""
        order_id = self._order()
        self._sweep()
        self.assertEqual(self.sent[0]["link"], {"route": "order", "id": order_id})

    def test_the_order_keeps_waiting(self):
        order_id = self._order()
        self._sweep()
        order = self._reload(order_id)
        self.assertEqual(order.status, OrderStatus.pending)
        self.assertIsNone(order.agent_id)
        self.assertIsNone(order.cancelled_at)

    def test_a_second_sweep_does_not_tell_them_twice(self):
        self._order()
        self._sweep()
        self.assertEqual(self._sweep(), [])
        self.assertEqual(len(self.sent), 1)

    def test_an_order_inside_the_window_is_left_alone(self):
        self._order(minutes_ago=UNCLAIMED_NOTICE_MINUTES - 1)
        self.assertEqual(self._sweep(), [])
        self.assertEqual(self.sent, [])


class CancellingIsOffByDefaultTests(_SweepBase):
    """The old auto-cancel is kept, but nothing uses it unless asked."""

    def test_an_order_is_not_cancelled_however_long_it_waits(self):
        order_id = self._order(minutes_ago=settings.unclaimed_timeout_minutes + 60)
        self.assertEqual(self._sweep(expiry.cancel_unclaimed), [])
        self.assertEqual(self._reload(order_id).status, OrderStatus.pending)

    def test_a_deployment_that_needs_the_cap_can_switch_it_back_on(self):
        order_id = self._order(minutes_ago=settings.unclaimed_timeout_minutes + 60)
        settings.cancel_unclaimed_orders = True
        try:
            self.assertEqual(self._sweep(expiry.cancel_unclaimed), [order_id])
        finally:
            settings.cancel_unclaimed_orders = False
        self.assertEqual(self._reload(order_id).status, OrderStatus.cancelled)

    def test_the_default_really_is_off(self):
        self.assertFalse(settings.cancel_unclaimed_orders)


if __name__ == "__main__":
    unittest.main()
