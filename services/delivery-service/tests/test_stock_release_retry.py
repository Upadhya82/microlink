"""Item 12: stock still held for a cancelled order is handed back later.

A cancellation must not fail because shop-service is down, so the release can
be left owed. The expiry sweep picks those orders up again. These tests check
which orders it picks, against a real (SQLite) database.

    cd services/delivery-service
    JWT_SECRET=<32+ chars> python -m pytest tests/test_stock_release_retry.py -q
"""

import asyncio
import unittest
from datetime import datetime, timezone

from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app import expiry, stock
from app.database import Base
from app.models import Order, OrderStatus


class _Releases:
    """Stands in for shop-service: records calls, answers as told."""

    def __init__(self, succeed=True):
        self.succeed = succeed
        self.calls: list[tuple[str, str]] = []

    async def __call__(self, shop_id: str, order_id: str) -> bool:
        self.calls.append((shop_id, order_id))
        return self.succeed


class RetryOwedReleasesTests(unittest.TestCase):
    def setUp(self):
        self.engine = create_engine(
            "sqlite:///:memory:",
            connect_args={"check_same_thread": False},
            poolclass=StaticPool,
        )
        Base.metadata.create_all(self.engine)
        self.Session = sessionmaker(bind=self.engine, autoflush=False)
        self.db = self.Session()
        self.original_release = stock.release

    def tearDown(self):
        stock.release = self.original_release
        self.db.close()
        self.engine.dispose()

    def _order(self, *, status, reserved, released) -> str:
        now = datetime.now(timezone.utc)
        order = Order(
            customer_id="customer-1",
            shop_id="shop-1",
            items="[]",
            delivery_address="1 Test Rd",
            delivery_lat=6.9271,
            delivery_lng=79.8612,
            status=status,
            stock_reserved_at=now if reserved else None,
            stock_released_at=now if released else None,
        )
        self.db.add(order)
        self.db.commit()
        return order.id

    def _use(self, releases):
        stock.release = releases

    def test_a_cancelled_order_still_holding_stock_is_released(self):
        order_id = self._order(
            status=OrderStatus.cancelled, reserved=True, released=False
        )
        releases = _Releases()
        self._use(releases)

        self.assertEqual(asyncio.run(expiry.retry_owed_releases(self.db)), 1)
        self.assertEqual(releases.calls, [("shop-1", order_id)])
        self.db.expire_all()
        self.assertIsNotNone(self.db.get(Order, order_id).stock_released_at)

    def test_an_order_already_released_is_left_alone(self):
        self._order(status=OrderStatus.cancelled, reserved=True, released=True)
        releases = _Releases()
        self._use(releases)

        self.assertEqual(asyncio.run(expiry.retry_owed_releases(self.db)), 0)
        self.assertEqual(releases.calls, [])

    def test_an_order_that_never_reserved_is_left_alone(self):
        self._order(status=OrderStatus.cancelled, reserved=False, released=False)
        releases = _Releases()
        self._use(releases)

        self.assertEqual(asyncio.run(expiry.retry_owed_releases(self.db)), 0)
        self.assertEqual(releases.calls, [])

    def test_a_live_order_keeps_its_stock(self):
        for status in (OrderStatus.pending, OrderStatus.accepted, OrderStatus.delivered):
            self._order(status=status, reserved=True, released=False)
        releases = _Releases()
        self._use(releases)

        self.assertEqual(asyncio.run(expiry.retry_owed_releases(self.db)), 0)
        self.assertEqual(releases.calls, [])

    def test_a_release_that_fails_again_is_still_owed(self):
        order_id = self._order(
            status=OrderStatus.cancelled, reserved=True, released=False
        )
        releases = _Releases(succeed=False)
        self._use(releases)

        self.assertEqual(asyncio.run(expiry.retry_owed_releases(self.db)), 0)
        self.assertEqual(len(releases.calls), 1)
        self.db.expire_all()
        self.assertIsNone(self.db.get(Order, order_id).stock_released_at)

        # The next sweep tries once more.
        releases.succeed = True
        self.assertEqual(asyncio.run(expiry.retry_owed_releases(self.db)), 1)
        self.db.expire_all()
        self.assertIsNotNone(self.db.get(Order, order_id).stock_released_at)

    def test_the_sweep_is_capped_so_one_pass_cannot_run_away(self):
        for _ in range(4):
            self._order(status=OrderStatus.cancelled, reserved=True, released=False)
        releases = _Releases()
        self._use(releases)

        self.assertEqual(asyncio.run(expiry.retry_owed_releases(self.db, limit=2)), 2)
        self.assertEqual(len(releases.calls), 2)


class ExpiredOrdersReleaseTests(unittest.TestCase):
    """The unclaimed-order sweep gives the stock back as it cancels."""

    def setUp(self):
        self.engine = create_engine(
            "sqlite:///:memory:",
            connect_args={"check_same_thread": False},
            poolclass=StaticPool,
        )
        Base.metadata.create_all(self.engine)
        self.Session = sessionmaker(bind=self.engine, autoflush=False)
        self.db = self.Session()
        self.original_release = stock.release
        self.original_notify = expiry.notify_users
        self.original_publish = expiry.publish_event

        async def _quiet(*args, **kwargs):
            return None

        expiry.notify_users = _quiet
        expiry.publish_event = _quiet

    def tearDown(self):
        stock.release = self.original_release
        expiry.notify_users = self.original_notify
        expiry.publish_event = self.original_publish
        self.db.close()
        self.engine.dispose()

    def test_an_order_nobody_accepted_returns_its_stock(self):
        stale = datetime(2020, 1, 1, tzinfo=timezone.utc)
        order = Order(
            customer_id="customer-1",
            shop_id="shop-1",
            items="[]",
            delivery_address="1 Test Rd",
            delivery_lat=6.9271,
            delivery_lng=79.8612,
            status=OrderStatus.pending,
            stock_reserved_at=stale,
            created_at=stale,
        )
        self.db.add(order)
        self.db.commit()
        order_id = order.id

        releases = _Releases()
        stock.release = releases

        cancelled = asyncio.run(expiry.cancel_unclaimed(self.db))
        self.assertEqual(cancelled, [order_id])
        self.assertEqual(releases.calls, [("shop-1", order_id)])
        self.db.expire_all()
        self.assertIsNotNone(self.db.get(Order, order_id).stock_released_at)


if __name__ == "__main__":
    unittest.main()
