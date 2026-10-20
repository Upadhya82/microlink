"""Which waiting orders have gone stale.

The rule is pure, so it is tested without a database or a running loop.
"""

import unittest
from datetime import datetime, timedelta, timezone

from app.config import settings
from app.expiry import UNCLAIMED_TIMEOUT_MINUTES, expired_orders
from app.models import OrderStatus

NOW = datetime(2026, 10, 11, 12, 0, tzinfo=timezone.utc)


class FakeOrder:
    def __init__(self, status, agent_id, age_minutes, tz=True):
        self.id = f"order-{age_minutes}-{status}"
        self.status = status
        self.agent_id = agent_id
        created = NOW - timedelta(minutes=age_minutes)
        self.created_at = created if tz else created.replace(tzinfo=None)


class ExpiredOrders(unittest.TestCase):
    def test_an_order_waiting_longer_than_the_timeout_expires(self):
        order = FakeOrder(OrderStatus.pending, None, UNCLAIMED_TIMEOUT_MINUTES + 1)
        self.assertEqual(expired_orders([order], NOW), [order])

    def test_an_order_still_inside_the_timeout_is_left_alone(self):
        order = FakeOrder(OrderStatus.pending, None, UNCLAIMED_TIMEOUT_MINUTES - 1)
        self.assertEqual(expired_orders([order], NOW), [])

    def test_an_order_exactly_at_the_timeout_expires(self):
        # Exactly the promised wait has passed, so it is up.
        order = FakeOrder(OrderStatus.pending, None, UNCLAIMED_TIMEOUT_MINUTES)
        self.assertEqual(expired_orders([order], NOW), [order])

    def test_an_accepted_order_never_expires_however_old(self):
        order = FakeOrder(OrderStatus.accepted, "agent-1", 600)
        self.assertEqual(expired_orders([order], NOW), [])

    def test_an_order_that_has_an_agent_never_expires(self):
        # Belt and braces: status and agent are checked independently, so a
        # half-written row cannot have a waiting customer's order cancelled
        # out from under an agent who already took it.
        order = FakeOrder(OrderStatus.pending, "agent-1", 600)
        self.assertEqual(expired_orders([order], NOW), [])

    def test_a_delivered_order_never_expires(self):
        order = FakeOrder(OrderStatus.delivered, "agent-1", 600)
        self.assertEqual(expired_orders([order], NOW), [])

    def test_a_naive_timestamp_is_treated_as_utc(self):
        # SQLite hands back naive datetimes; comparing them to an aware "now"
        # raises, which would kill the sweep rather than cancel the order.
        order = FakeOrder(OrderStatus.pending, None, UNCLAIMED_TIMEOUT_MINUTES + 1, tz=False)
        self.assertEqual(expired_orders([order], NOW), [order])

    def test_only_the_stale_orders_come_back_from_a_mixed_list(self):
        # Relative to the configured wait, not a fixed number of minutes:
        # the window is a setting now and this test should follow it.
        stale = FakeOrder(OrderStatus.pending, None, UNCLAIMED_TIMEOUT_MINUTES + 10)
        fresh = FakeOrder(OrderStatus.pending, None, UNCLAIMED_TIMEOUT_MINUTES - 1)
        taken = FakeOrder(
            OrderStatus.accepted, "agent-1", UNCLAIMED_TIMEOUT_MINUTES + 10
        )
        self.assertEqual(expired_orders([stale, fresh, taken], NOW), [stale])

    def test_the_timeout_can_be_overridden(self):
        order = FakeOrder(OrderStatus.pending, None, 3)
        self.assertEqual(expired_orders([order], NOW, timeout_minutes=2), [order])
        self.assertEqual(expired_orders([order], NOW, timeout_minutes=10), [])


class UnclaimedTimeoutIsASettingTests(unittest.TestCase):
    """The wait is configurable, and long enough to be useful.

    It used to be a hard-coded five minutes, which meant an order placed
    while no driver happened to be online was cancelled almost immediately
    -- and the stock it had reserved (item 12) sprang back, so the next
    customer saw the full quantity again.
    """

    def test_the_timeout_comes_from_settings(self):
        self.assertEqual(
            UNCLAIMED_TIMEOUT_MINUTES, settings.unclaimed_timeout_minutes
        )

    def test_it_is_long_enough_for_a_driver_to_come_online(self):
        self.assertGreaterEqual(UNCLAIMED_TIMEOUT_MINUTES, 30)

    def test_an_order_keeps_its_stock_for_the_whole_window(self):
        # Half an hour in, with no agent, the order is still live -- so the
        # reservation it holds is still the shop's true stock.
        order = FakeOrder(OrderStatus.pending, None, 30)
        self.assertEqual(expired_orders([order], NOW), [])

    def test_a_shorter_window_can_still_be_configured(self):
        order = FakeOrder(OrderStatus.pending, None, 10)
        self.assertEqual(expired_orders([order], NOW, timeout_minutes=5), [order])


if __name__ == "__main__":
    unittest.main()
