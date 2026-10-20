"""The gateway refuses service-to-service paths (item 12).

shop-service's stock reserve/release move product stock behind an order.
delivery-service is the only caller allowed to, and it reaches shop-service
directly inside the compose network, so the public way in is closed.

    cd api-gateway
    python -m pytest -q
"""

import unittest

from app.main import _is_internal, _resolve_target, _strip_api_prefix


class InternalPathTests(unittest.TestCase):
    def test_the_stock_endpoints_are_internal(self):
        for path in (
            "shops/abc/stock/reserve",
            "shops/abc/stock/release",
            "shops/44444444-4444-4444-4444-444444444444/stock/reserve",
        ):
            self.assertTrue(_is_internal(path), path)

    def test_the_app_prefix_is_stripped_before_the_check(self):
        # The app calls /api/<path>; the block has to apply there too.
        self.assertTrue(_is_internal(_strip_api_prefix("api/shops/abc/stock/reserve")))

    def test_ordinary_shop_paths_still_go_through(self):
        for path in (
            "shops",
            "shops/abc",
            "shops/abc/products",
            "shops/abc/reviews",
            "shops/owner/me",
            "shops/landmark",
        ):
            self.assertFalse(_is_internal(path), path)
            self.assertIsNotNone(_resolve_target(path), path)

    def test_a_path_that_merely_mentions_stock_is_not_blocked(self):
        # The block is about /shops/<id>/stock/..., not the word "stock".
        self.assertFalse(_is_internal("shops/abc/products?q=stock"))
        self.assertFalse(_is_internal("admin/stock/report"))

    def test_the_stock_path_is_not_reachable_under_another_prefix(self):
        self.assertFalse(_is_internal("orders/abc/stock/reserve"))


if __name__ == "__main__":
    unittest.main()
