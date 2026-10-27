"""Older orders get their shop's name filled in.

`Order.shop_name` is copied on at checkout, so every order placed before
that column existed has NULL -- and NULL is a customer opening their order
history and still not being told which shop an order came from, which is
the whole thing the column was added to fix. They are filled in once at
startup, from shop-service.

    cd services/delivery-service
    JWT_SECRET=<32+ chars> python -m pytest tests/test_shop_name_backfill.py -q
"""

import asyncio
import unittest

import httpx
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app import backfill
from app.backfill import backfill_shop_names, shops_needing_names
from app.database import Base
from app.models import Order, OrderStatus

CUSTOMER_ID = "11111111-1111-1111-1111-111111111111"


class _ShopService(httpx.AsyncBaseTransport):
    """Answers /shops/{id} from a dict, and counts what it was asked."""

    def __init__(self, names: dict[str, str], raise_error: bool = False):
        self.names = names
        self.raise_error = raise_error
        self.asked: list[str] = []

    async def handle_async_request(self, request):
        shop_id = request.url.path.rsplit("/", 1)[-1]
        self.asked.append(shop_id)
        if self.raise_error:
            raise httpx.ConnectError("shop-service is down", request=request)
        if shop_id not in self.names:
            return httpx.Response(404, json={"detail": "Shop not found"})
        return httpx.Response(200, json={"id": shop_id, "name": self.names[shop_id]})


class BackfillTests(unittest.TestCase):
    def setUp(self):
        self.engine = create_engine(
            "sqlite:///:memory:",
            connect_args={"check_same_thread": False},
            poolclass=StaticPool,
        )
        Base.metadata.create_all(self.engine)
        self.Session = sessionmaker(bind=self.engine, autoflush=False)
        self.db = self.Session()
        self.original_client = httpx.AsyncClient

    def tearDown(self):
        httpx.AsyncClient = self.original_client
        self.db.close()
        self.engine.dispose()

    def _shop_service(self, names, raise_error=False):
        transport = _ShopService(names, raise_error)
        original = self.original_client

        def factory(*args, **kw):
            kw["transport"] = transport
            return original(*args, **kw)

        httpx.AsyncClient = factory
        return transport

    def _order(self, shop_id="shop-1", shop_name=None) -> str:
        order = Order(
            customer_id=CUSTOMER_ID,
            shop_id=shop_id,
            shop_name=shop_name,
            items="[]",
            delivery_address="1 Test Rd",
            delivery_lat=6.93,
            delivery_lng=79.86,
            status=OrderStatus.delivered,
        )
        self.db.add(order)
        self.db.commit()
        return order.id

    def _run(self, **kwargs):
        return asyncio.run(backfill_shop_names(self.db, **kwargs))

    def _name_of(self, order_id):
        self.db.expire_all()
        return self.db.get(Order, order_id).shop_name

    def test_an_older_order_is_named(self):
        order_id = self._order()
        self._shop_service({"shop-1": "Thusitha Bakers"})
        self.assertEqual(self._run(), 1)
        self.assertEqual(self._name_of(order_id), "Thusitha Bakers")

    def test_one_request_per_shop_not_per_order(self):
        """A regular customer has many orders from the same few places."""
        for _ in range(5):
            self._order("shop-1")
        self._order("shop-2")
        transport = self._shop_service({"shop-1": "Bakers", "shop-2": "Grocers"})

        self.assertEqual(self._run(), 6)
        self.assertEqual(sorted(transport.asked), ["shop-1", "shop-2"])

    def test_an_order_that_already_has_a_name_is_left_alone(self):
        order_id = self._order(shop_name="What it was called then")
        transport = self._shop_service({"shop-1": "Renamed Since"})

        self.assertEqual(self._run(), 0)
        self.assertEqual(transport.asked, [])
        self.assertEqual(self._name_of(order_id), "What it was called then")

    def test_a_deleted_shop_leaves_the_order_as_it_was(self):
        # The app falls back to the pickup address; refusing to name the
        # others over this one would help nobody.
        gone = self._order("shop-gone")
        still_there = self._order("shop-1")
        self._shop_service({"shop-1": "Bakers"})

        self.assertEqual(self._run(), 1)
        self.assertIsNone(self._name_of(gone))
        self.assertEqual(self._name_of(still_there), "Bakers")

    def test_shop_service_being_down_changes_nothing_and_does_not_raise(self):
        order_id = self._order()
        self._shop_service({"shop-1": "Bakers"}, raise_error=True)

        self.assertEqual(self._run(), 0)
        self.assertIsNone(self._name_of(order_id))

    def test_a_blank_name_is_not_written_over_the_null(self):
        order_id = self._order()
        self._shop_service({"shop-1": "   "})

        self.assertEqual(self._run(), 0)
        self.assertIsNone(self._name_of(order_id))

    def test_a_second_run_has_nothing_left_to_do(self):
        self._order()
        transport = self._shop_service({"shop-1": "Bakers"})
        self._run()
        transport.asked.clear()

        self.assertEqual(self._run(), 0)
        self.assertEqual(transport.asked, [])

    def test_one_start_does_not_talk_to_every_shop_on_a_large_database(self):
        for i in range(6):
            self._order("shop-%d" % i)
        self.assertEqual(len(shops_needing_names(self.db, limit=4)), 4)

        transport = self._shop_service({"shop-%d" % i: "Shop %d" % i for i in range(6)})
        self.assertEqual(self._run(limit=4), 4)
        self.assertEqual(len(transport.asked), 4)
        # The rest are picked up next time.
        self.assertEqual(len(shops_needing_names(self.db)), 2)

    def test_run_backfill_swallows_a_failure_rather_than_killing_startup(self):
        self._order()

        def exploding_factory(*args, **kw):
            raise RuntimeError("boom")

        httpx.AsyncClient = exploding_factory
        asyncio.run(backfill.run_backfill(self.Session))  # must not raise


if __name__ == "__main__":
    unittest.main()
