"""A cart order gets the shop's location as its pickup point, so the agent
has somewhere to navigate to."""

import asyncio
import unittest

import httpx

from app.routers import orders_router


class _ShopService(httpx.AsyncBaseTransport):
    def __init__(self, status_code=200, body=None, raise_error=False):
        self.status_code = status_code
        self.body = body
        self.raise_error = raise_error
        self.requests: list[httpx.Request] = []

    async def handle_async_request(self, request):
        self.requests.append(request)
        if self.raise_error:
            raise httpx.ConnectError("shop-service is down", request=request)
        return httpx.Response(self.status_code, json=self.body)


SHOP = {"id": "shop-1", "latitude": 6.8121, "longitude": 79.9874, "address": "12 Main St, Kottawa"}


class ResolvePickupTests(unittest.TestCase):
    def setUp(self):
        self.original = httpx.AsyncClient

    def tearDown(self):
        httpx.AsyncClient = self.original

    def _shop_service(self, **kwargs):
        transport = _ShopService(**kwargs)
        original = self.original

        def factory(*args, **kw):
            kw["transport"] = transport
            return original(*args, **kw)

        httpx.AsyncClient = factory
        return transport

    def _resolve(self, lat=None, lng=None, address=None):
        return asyncio.run(orders_router.resolve_pickup("shop-1", lat, lng, address))

    def test_a_cart_order_is_picked_up_at_the_shop(self):
        transport = self._shop_service(body=SHOP)
        self.assertEqual(self._resolve(), (6.8121, 79.9874, "12 Main St, Kottawa"))
        self.assertTrue(transport.requests[0].url.path.endswith("/shops/shop-1"))

    def test_a_point_the_customer_chose_is_kept_without_asking_the_shop(self):
        transport = self._shop_service(body=SHOP)
        self.assertEqual(self._resolve(6.9, 79.9, "Gate 2"), (6.9, 79.9, "Gate 2"))
        self.assertEqual(transport.requests, [])

    def test_an_address_the_customer_typed_is_kept_with_the_shop_location(self):
        self._shop_service(body=SHOP)
        self.assertEqual(self._resolve(address="Back entrance"), (6.8121, 79.9874, "Back entrance"))

    def test_an_unreachable_shop_service_leaves_the_order_without_a_point(self):
        self._shop_service(raise_error=True)
        self.assertEqual(self._resolve(), (None, None, None))

    def test_an_unknown_shop_leaves_the_order_without_a_point(self):
        self._shop_service(status_code=404, body={"detail": "Shop not found"})
        self.assertEqual(self._resolve(), (None, None, None))

    def test_a_shop_without_coordinates_leaves_the_order_without_a_point(self):
        self._shop_service(body={"id": "shop-1", "address": "Somewhere"})
        self.assertEqual(self._resolve(), (None, None, None))


if __name__ == "__main__":
    unittest.main()
