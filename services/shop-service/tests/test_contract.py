"""Compatibility checks against the rest of MicroLink.

Other members' code already depends on shop-service: the owner dashboard, the
home screen, the live map, favourites, recommendation-service and
scripts/smoke_test.sh. These tests make sure the fields and routes they use
are still here. They read the source files only (no packages needed):

    cd services/shop-service
    python -m unittest tests.test_contract -v
"""

import ast
import os
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "app")


def _read(*parts: str) -> str:
    with open(os.path.join(APP, *parts), encoding="utf-8") as handle:
        return handle.read()


def _class_fields(source: str, class_name: str) -> dict[str, str]:
    """{field name: annotation source} for a class body."""
    tree = ast.parse(source)
    for node in tree.body:
        if isinstance(node, ast.ClassDef) and node.name == class_name:
            return {
                item.target.id: ast.unparse(item.annotation)
                for item in node.body
                if isinstance(item, ast.AnnAssign) and isinstance(item.target, ast.Name)
            }
    raise AssertionError(f"class {class_name} not found")


class ResponseShapes(unittest.TestCase):
    """Flutter's Shop.fromJson / Product.fromJson and the dashboard read these keys."""

    def test_shop_response_keeps_every_old_field(self):
        fields = _class_fields(_read("schemas.py"), "ShopResponse")
        for key in (
            "id", "owner_id", "name", "description", "category", "address", "latitude",
            "longitude", "phone", "image_url", "opening_time", "closing_time", "is_open",
            "rating_avg", "rating_count", "created_at", "updated_at", "distance_km",
        ):
            self.assertIn(key, fields, f"ShopResponse lost {key}")

    def test_new_shop_fields_are_optional_or_defaulted(self):
        source = _read("schemas.py")
        tree = ast.parse(source)
        shop = next(n for n in tree.body if isinstance(n, ast.ClassDef) and n.name == "ShopResponse")
        defaults = {
            item.target.id: item.value is not None
            for item in shop.body
            if isinstance(item, ast.AnnAssign) and isinstance(item.target, ast.Name)
        }
        for key in ("status", "status_reason", "reopen_at", "delivery_available", "photos",
                    "trust_score", "product_count", "availability", "matched_product"):
            self.assertTrue(defaults.get(key), f"{key} must have a default so old data still validates")

    def test_product_response_keeps_old_fields(self):
        fields = _class_fields(_read("schemas.py"), "ProductResponse")
        for key in ("id", "shop_id", "name", "description", "price", "stock_quantity",
                    "category", "is_available", "created_at", "updated_at"):
            self.assertIn(key, fields)

    def test_alert_response_keeps_old_fields(self):
        fields = _class_fields(_read("schemas.py"), "ShopAlertResponse")
        for key in ("id", "shop_id", "message", "is_active", "created_at"):
            self.assertIn(key, fields)

    def test_analytics_keeps_the_keys_the_dashboard_reads(self):
        fields = _class_fields(_read("schemas.py"), "ShopAnalyticsResponse")
        for key in ("shop_id", "total_views", "total_search_impressions", "product_count",
                    "active_alert_count", "views_last_7_days"):
            self.assertIn(key, fields)


class RequestShapes(unittest.TestCase):
    def test_product_can_be_created_without_a_quantity(self):
        # scripts/smoke_test.sh posts {"name","price","description"} only
        fields = _class_fields(_read("schemas.py"), "ProductCreateRequest")
        self.assertIn("None", fields["stock_quantity"])

    def test_dashboard_product_toggle_still_accepted(self):
        # the dashboard PATCHes {"is_available": bool}
        fields = _class_fields(_read("schemas.py"), "ProductUpdateRequest")
        self.assertIn("is_available", fields)

    def test_old_status_body_still_accepted(self):
        # the dashboard PATCHes /status with {"is_open": bool}
        fields = _class_fields(_read("schemas.py"), "ShopStatusUpdateRequest")
        self.assertIn("is_open", fields)

    def test_alert_needs_only_a_message(self):
        # the dashboard posts {"message": "..."} only
        source = _read("schemas.py")
        self.assertIn('alert_type: AlertTypeLiteral = "general"', source)

    def test_shop_create_needs_only_the_old_fields(self):
        source = _read("schemas.py")
        tree = ast.parse(source)
        shop = next(n for n in tree.body if isinstance(n, ast.ClassDef) and n.name == "ShopCreateRequest")
        required = [
            item.target.id
            for item in shop.body
            if isinstance(item, ast.AnnAssign) and isinstance(item.target, ast.Name) and item.value is None
        ]
        self.assertEqual(sorted(required), [])  # every field has a default or a Field(...)


class Routes(unittest.TestCase):
    """Paths other code calls (through the gateway: /api/shops/...)."""

    def _has(self, filename: str, snippet: str):
        self.assertIn(snippet, _read("routers", filename), f"{filename} is missing {snippet}")

    def test_shop_routes(self):
        self._has("shops_router.py", 'prefix="/shops"')
        self._has("shops_router.py", '@router.post("", ')  # bare POST /shops (no trailing slash)
        self._has("shops_router.py", '@router.get("", ')
        self._has("shops_router.py", '"/owner/me"')
        self._has("shops_router.py", '"/external"')
        self._has("shops_router.py", '"/{shop_id}/status"')

    def test_product_routes(self):
        self._has("products_router.py", 'prefix="/shops/{shop_id}/products"')
        self._has("products_router.py", '@router.patch("/{product_id}"')
        self._has("products_router.py", '@router.delete("/{product_id}"')

    def test_alert_routes(self):
        self._has("alerts_router.py", 'prefix="/shops/{shop_id}/alerts"')
        self._has("alerts_router.py", '@router.delete("/{alert_id}"')

    def test_analytics_route(self):
        self._has("analytics_router.py", 'prefix="/shops/{shop_id}/analytics"')

    def test_recommendation_service_query_parameters_exist(self):
        # recommendation-service calls GET /shops?is_open=true&limit=100&lat=..&lng=..
        source = _read("routers", "shops_router.py")
        for param in ("is_open:", "limit:", "lat:", "lng:", "radius_km:"):
            self.assertIn(param, source)

    def test_main_registers_every_router(self):
        main = _read("main.py")
        for name in ("shops_router", "products_router", "alerts_router", "analytics_router", "reviews_router"):
            self.assertIn(f"app.include_router({name}.router)", main)
        self.assertIn('"/health"', main)  # docker / gateway health checks


class Environment(unittest.TestCase):
    def test_config_uses_the_variables_docker_compose_passes(self):
        # services/shop-service in docker-compose.yml sets these
        fields = _class_fields(_read("config.py"), "Settings")
        for key in ("postgres_user", "postgres_password", "postgres_host", "postgres_port",
                    "postgres_db", "redis_host", "redis_port", "jwt_secret", "jwt_algorithm"):
            self.assertIn(key, fields)

    def test_event_channel_matches_the_team_convention(self):
        self.assertIn('EVENTS_CHANNEL = "microlink.events"', _read("event_bus.py"))


if __name__ == "__main__":
    unittest.main()
