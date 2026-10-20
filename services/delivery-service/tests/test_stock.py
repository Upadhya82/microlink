"""Item 12: delivery-service reserves stock before it saves an order.

`order_lines` is a plain function, so the awkward carts are checked directly.
The reserve/release calls are checked against a stub shop-service rather than
a real one, because what matters is what delivery-service does with each
answer: a 409 must stop the order, and an unreachable shop-service must not
produce an order whose stock was never checked.

    cd services/delivery-service
    JWT_SECRET=<32+ chars> python -m pytest tests/test_stock.py -q
"""

import asyncio
import unittest
from datetime import datetime, timezone

import httpx

from app import stock
from app.models import OrderStatus


def _run(coro):
    return asyncio.run(coro)


class _FakeOrder:
    """Just the fields `release_for_order` looks at."""

    def __init__(self, *, reserved=True, released=False, status=OrderStatus.cancelled):
        self.id = "order-1"
        self.shop_id = "shop-1"
        self.status = status
        self.stock_reserved_at = datetime.now(timezone.utc) if reserved else None
        self.stock_released_at = datetime.now(timezone.utc) if released else None


class _FakeDb:
    def __init__(self):
        self.commits = 0

    def commit(self):
        self.commits += 1


class _StubTransport(httpx.AsyncBaseTransport):
    """Answers shop-service's two stock endpoints with canned responses."""

    def __init__(self, status_code=200, body=None, raise_error=False):
        self.status_code = status_code
        self.body = body if body is not None else {"order_id": "order-1", "changed": True}
        self.raise_error = raise_error
        self.requests: list[httpx.Request] = []

    async def handle_async_request(self, request):
        self.requests.append(request)
        if self.raise_error:
            raise httpx.ConnectError("shop-service is down", request=request)
        return httpx.Response(self.status_code, json=self.body)


def _with_transport(transport):
    """Point app.stock's httpx client at a stub for one test."""
    original = httpx.AsyncClient

    def factory(*args, **kwargs):
        kwargs["transport"] = transport
        return original(*args, **kwargs)

    return original, factory


class OrderLineTests(unittest.TestCase):
    def test_a_normal_cart_becomes_one_line_per_product(self):
        lines = stock.order_lines(
            [
                {"product_id": "p1", "quantity": 2, "price": 100},
                {"product_id": "p2", "quantity": 1, "price": 50},
            ]
        )
        self.assertEqual(
            sorted(lines, key=lambda line: line["product_id"]),
            [
                {"product_id": "p1", "quantity": 2},
                {"product_id": "p2", "quantity": 1},
            ],
        )

    def test_the_same_product_twice_is_merged(self):
        lines = stock.order_lines(
            [
                {"product_id": "p1", "quantity": 2},
                {"product_id": "p1", "quantity": 3},
            ]
        )
        self.assertEqual(lines, [{"product_id": "p1", "quantity": 5}])

    def test_a_request_delivery_order_has_nothing_to_reserve(self):
        # REQ-DELIV-3: no cart at all, just "please fetch this for me".
        self.assertEqual(stock.order_lines([]), [])

    def test_a_free_text_item_without_a_product_id_is_skipped(self):
        lines = stock.order_lines(
            [{"name": "whatever the shop has", "quantity": 1}, {"product_id": "p1"}]
        )
        self.assertEqual(lines, [{"product_id": "p1", "quantity": 1}])

    def test_a_missing_quantity_means_one(self):
        self.assertEqual(
            stock.order_lines([{"product_id": "p1"}]),
            [{"product_id": "p1", "quantity": 1}],
        )

    def test_a_quantity_of_zero_is_refused(self):
        with self.assertRaises(stock.InvalidLine):
            stock.order_lines([{"product_id": "p1", "quantity": 0}])

    def test_a_negative_quantity_is_refused(self):
        with self.assertRaises(stock.InvalidLine):
            stock.order_lines([{"product_id": "p1", "quantity": -2}])

    def test_a_quantity_that_is_not_a_whole_number_is_refused(self):
        for bad in (1.5, "2", True, None):
            with self.assertRaises(stock.InvalidLine):
                stock.order_lines([{"product_id": "p1", "quantity": bad}])

    def test_a_line_that_is_not_an_object_is_refused(self):
        with self.assertRaises(stock.InvalidLine):
            stock.order_lines(["just a string"])


class ReserveTests(unittest.TestCase):
    def setUp(self):
        self.original = httpx.AsyncClient

    def tearDown(self):
        httpx.AsyncClient = self.original

    def _use(self, transport):
        original, factory = _with_transport(transport)
        httpx.AsyncClient = factory
        return original

    def test_a_200_reserves_quietly(self):
        transport = _StubTransport(200)
        self._use(transport)
        _run(stock.reserve("shop-1", "order-1", [{"product_id": "p1", "quantity": 1}]))
        self.assertEqual(len(transport.requests), 1)
        self.assertTrue(
            transport.requests[0].url.path.endswith("/shops/shop-1/stock/reserve")
        )

    def test_nothing_to_reserve_makes_no_call_at_all(self):
        transport = _StubTransport(200)
        self._use(transport)
        _run(stock.reserve("shop-1", "order-1", []))
        self.assertEqual(transport.requests, [])

    def test_a_409_raises_stock_short_and_keeps_the_wording(self):
        transport = _StubTransport(409, {"detail": "Not enough stock: Rice 5kg."})
        self._use(transport)
        with self.assertRaises(stock.StockShort) as caught:
            _run(
                stock.reserve(
                    "shop-1", "order-1", [{"product_id": "p1", "quantity": 9}]
                )
            )
        self.assertEqual(caught.exception.detail, "Not enough stock: Rice 5kg.")

    def test_a_409_without_a_readable_reason_still_says_something(self):
        transport = _StubTransport(409, {"detail": {"not": "a string"}})
        self._use(transport)
        with self.assertRaises(stock.StockShort) as caught:
            _run(
                stock.reserve(
                    "shop-1", "order-1", [{"product_id": "p1", "quantity": 9}]
                )
            )
        self.assertIn("stock", caught.exception.detail.lower())

    def test_an_unknown_shop_is_treated_as_unorderable(self):
        transport = _StubTransport(404, {"detail": "Shop not found"})
        self._use(transport)
        with self.assertRaises(stock.StockShort):
            _run(
                stock.reserve(
                    "shop-1", "order-1", [{"product_id": "p1", "quantity": 1}]
                )
            )

    def test_an_unreachable_shop_service_is_not_treated_as_success(self):
        transport = _StubTransport(raise_error=True)
        self._use(transport)
        with self.assertRaises(stock.StockServiceUnavailable):
            _run(
                stock.reserve(
                    "shop-1", "order-1", [{"product_id": "p1", "quantity": 1}]
                )
            )

    def test_a_server_error_from_shop_service_is_not_treated_as_success(self):
        transport = _StubTransport(500, {"detail": "boom"})
        self._use(transport)
        with self.assertRaises(stock.StockServiceUnavailable):
            _run(
                stock.reserve(
                    "shop-1", "order-1", [{"product_id": "p1", "quantity": 1}]
                )
            )


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.original = httpx.AsyncClient

    def tearDown(self):
        httpx.AsyncClient = self.original

    def _use(self, transport):
        _, factory = _with_transport(transport)
        httpx.AsyncClient = factory

    def test_a_release_reports_success(self):
        self._use(_StubTransport(200))
        self.assertTrue(_run(stock.release("shop-1", "order-1")))

    def test_an_unreachable_shop_service_reports_failure_without_raising(self):
        self._use(_StubTransport(raise_error=True))
        self.assertFalse(_run(stock.release("shop-1", "order-1")))

    def test_an_order_that_reserved_nothing_is_not_released(self):
        self._use(_StubTransport(200))
        db = _FakeDb()
        order = _FakeOrder(reserved=False)
        self.assertFalse(_run(stock.release_for_order(db, order)))
        self.assertEqual(db.commits, 0)

    def test_an_order_already_released_is_not_released_again(self):
        self._use(_StubTransport(200))
        db = _FakeDb()
        order = _FakeOrder(reserved=True, released=True)
        self.assertFalse(_run(stock.release_for_order(db, order)))
        self.assertEqual(db.commits, 0)

    def test_a_successful_release_is_recorded(self):
        self._use(_StubTransport(200))
        db = _FakeDb()
        order = _FakeOrder()
        self.assertTrue(_run(stock.release_for_order(db, order)))
        self.assertIsNotNone(order.stock_released_at)
        self.assertEqual(db.commits, 1)

    def test_a_failed_release_leaves_the_order_still_owing(self):
        self._use(_StubTransport(raise_error=True))
        db = _FakeDb()
        order = _FakeOrder()
        self.assertFalse(_run(stock.release_for_order(db, order)))
        # Left empty on purpose: the expiry sweep retries exactly these.
        self.assertIsNone(order.stock_released_at)
        self.assertEqual(db.commits, 0)

    def test_cancelling_twice_only_returns_the_stock_once(self):
        self._use(_StubTransport(200))
        db = _FakeDb()
        order = _FakeOrder()
        self.assertTrue(_run(stock.release_for_order(db, order)))
        self.assertFalse(_run(stock.release_for_order(db, order)))
        self.assertEqual(db.commits, 1)


if __name__ == "__main__":
    unittest.main()
