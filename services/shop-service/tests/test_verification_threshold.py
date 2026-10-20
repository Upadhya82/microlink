"""Item 10: a shop needs enough listable products before it can be verified.

    cd services/shop-service
    JWT_SECRET=<32+ chars> python -m pytest tests/test_verification_threshold.py -q
"""

import unittest
from datetime import datetime, timedelta, timezone

import jwt
from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app import listings, logic
from app.config import settings
from app.database import Base, get_db
from app.models import Product, Shop, ShopCategory
from app.routers import products_router, shops_router, stock_router

OWNER_ID = "11111111-1111-1111-1111-111111111111"
ADMIN_ID = "22222222-2222-2222-2222-222222222222"
SHOP_ID = "33333333-3333-3333-3333-333333333333"
OTHER_SHOP_ID = "44444444-4444-4444-4444-444444444444"


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


class VerificationThresholdTests(unittest.TestCase):
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
        app.include_router(shops_router.router)
        app.include_router(products_router.router)
        app.include_router(stock_router.router)
        app.dependency_overrides[get_db] = override_get_db
        self.client = TestClient(app)

        # Keep the event bus out of it, and record who was warned.
        self.notifications: list[dict] = []
        self.originals = {
            "shops_notify": shops_router.notify_users,
            "shops_publish": shops_router.publish_event,
            "listings_notify": listings.notify_users,
        }

        async def quiet(*args, **kwargs):
            return None

        async def record(user_ids, title, body, kind="general", link=None):
            self.notifications.append(
                {"user_ids": list(user_ids), "title": title, "body": body}
            )

        shops_router.notify_users = quiet
        shops_router.publish_event = quiet
        listings.notify_users = record

        session = self.Session()
        for shop_id in (SHOP_ID, OTHER_SHOP_ID):
            session.add(
                Shop(
                    id=shop_id,
                    owner_id=OWNER_ID,
                    name=f"Shop {shop_id[:4]}",
                    category=ShopCategory.grocery,
                    latitude=6.9271,
                    longitude=79.8612,
                )
            )
        session.commit()
        session.close()

    def tearDown(self):
        shops_router.notify_users = self.originals["shops_notify"]
        shops_router.publish_event = self.originals["shops_publish"]
        listings.notify_users = self.originals["listings_notify"]
        self.engine.dispose()

    # --- helpers ---
    def _products(self, count, quantity=10, shop_id=SHOP_ID) -> list[str]:
        session = self.Session()
        ids = []
        for index in range(count):
            product = Product(
                shop_id=shop_id,
                name=f"Product {index}",
                price=100.0,
                stock_quantity=quantity,
                stock_status=logic.derive_stock_status(
                    quantity, settings.low_stock_threshold
                ),
                is_available=quantity > 0,
            )
            session.add(product)
            session.flush()
            ids.append(product.id)
        session.commit()
        session.close()
        return ids

    def _verify(self, is_verified=True, shop_id=SHOP_ID):
        return self.client.patch(
            f"/shops/{shop_id}/verify",
            json={"is_verified": is_verified},
            headers=_auth(ADMIN_ID, "admin"),
        )

    def _shop(self, shop_id=SHOP_ID) -> Shop:
        session = self.Session()
        try:
            shop = session.get(Shop, shop_id)
            session.refresh(shop)
            return shop
        finally:
            session.close()

    def _set_verified(self, shop_id=SHOP_ID):
        session = self.Session()
        session.get(Shop, shop_id).is_verified = True
        session.commit()
        session.close()

    # --- the threshold ---
    def test_one_short_of_the_threshold_is_refused(self):
        self._products(settings.min_products_to_verify - 1)
        response = self._verify()
        self.assertEqual(response.status_code, 409)
        self.assertIn("at least 5", response.json()["detail"])
        self.assertIn("it has 4", response.json()["detail"])
        self.assertFalse(self._shop().is_verified)

    def test_exactly_the_threshold_is_allowed(self):
        self._products(settings.min_products_to_verify)
        self.assertEqual(self._verify().status_code, 200)
        self.assertTrue(self._shop().is_verified)

    def test_a_shop_with_no_products_is_refused(self):
        self.assertEqual(self._verify().status_code, 409)

    def test_products_below_the_stock_threshold_do_not_count(self):
        # Five products, but one has only four units: that is four listable.
        self._products(4, quantity=10)
        self._products(1, quantity=4)
        response = self._verify()
        self.assertEqual(response.status_code, 409)
        self.assertIn("it has 4", response.json()["detail"])

    def test_another_shops_products_do_not_count(self):
        self._products(settings.min_products_to_verify, shop_id=OTHER_SHOP_ID)
        self.assertEqual(self._verify().status_code, 409)

    def test_deleting_a_product_can_take_a_shop_back_under(self):
        ids = self._products(settings.min_products_to_verify)
        self.assertEqual(self._verify().status_code, 200)

        response = self.client.delete(
            f"/shops/{SHOP_ID}/products/{ids[0]}",
            headers=_auth(OWNER_ID, "shop_owner"),
        )
        self.assertEqual(response.status_code, 204)
        # Still verified and still visible: it is not un-verified by a sale.
        self.assertTrue(self._shop().is_verified)
        self.assertEqual(listings.listable_product_count(self.Session(), SHOP_ID), 4)

    def test_un_verifying_is_always_allowed(self):
        self._set_verified()
        response = self._verify(is_verified=False)
        self.assertEqual(response.status_code, 200)
        self.assertFalse(self._shop().is_verified)

    # --- the count in the response ---
    def test_the_response_reports_the_listable_count(self):
        self._products(3, quantity=10)
        self._products(2, quantity=2)
        response = self.client.get("/shops", params={"limit": 50})
        card = next(item for item in response.json() if item["id"] == SHOP_ID)
        self.assertEqual(card["listable_product_count"], 3)

    def test_the_count_is_zero_for_a_shop_with_nothing_listable(self):
        self._products(2, quantity=1)
        response = self.client.get("/shops", params={"limit": 50})
        card = next(item for item in response.json() if item["id"] == SHOP_ID)
        self.assertEqual(card["listable_product_count"], 0)

    # --- the owner is warned once ---
    def test_a_verified_shop_dropping_below_warns_the_owner_once(self):
        ids = self._products(settings.min_products_to_verify)
        self._verify()
        self.notifications.clear()

        # Sell one product down below the listing threshold.
        self.client.patch(
            f"/shops/{SHOP_ID}/products/{ids[0]}",
            json={"stock_quantity": 1},
            headers=_auth(OWNER_ID, "shop_owner"),
        )
        self.assertEqual(len(self.notifications), 1)
        self.assertEqual(self.notifications[0]["user_ids"], [OWNER_ID])
        self.assertIn("4 product", self.notifications[0]["body"])
        self.assertIsNotNone(self._shop().low_product_warning_at)

        # A second drop must not warn again.
        self.client.patch(
            f"/shops/{SHOP_ID}/products/{ids[1]}",
            json={"stock_quantity": 1},
            headers=_auth(OWNER_ID, "shop_owner"),
        )
        self.assertEqual(len(self.notifications), 1)

    def test_restocking_clears_the_warning_so_the_next_drop_is_told(self):
        ids = self._products(settings.min_products_to_verify)
        self._verify()
        self.notifications.clear()

        headers = _auth(OWNER_ID, "shop_owner")
        url = f"/shops/{SHOP_ID}/products/{ids[0]}"
        self.client.patch(url, json={"stock_quantity": 1}, headers=headers)
        self.assertEqual(len(self.notifications), 1)

        self.client.patch(url, json={"stock_quantity": 20}, headers=headers)
        self.assertIsNone(self._shop().low_product_warning_at)

        self.client.patch(url, json={"stock_quantity": 1}, headers=headers)
        self.assertEqual(len(self.notifications), 2)

    def test_an_unverified_shop_is_not_nagged(self):
        ids = self._products(settings.min_products_to_verify)
        self.client.patch(
            f"/shops/{SHOP_ID}/products/{ids[0]}",
            json={"stock_quantity": 1},
            headers=_auth(OWNER_ID, "shop_owner"),
        )
        self.assertEqual(self.notifications, [])

    def test_a_sale_can_warn_the_owner_too(self):
        ids = self._products(settings.min_products_to_verify, quantity=5)
        self._verify()
        self.notifications.clear()

        response = self.client.post(
            f"/shops/{SHOP_ID}/stock/reserve",
            json={"order_id": "order-1", "lines": [{"product_id": ids[0], "quantity": 5}]},
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(len(self.notifications), 1)
        self.assertIn("4 product", self.notifications[0]["body"])

    def test_cancelling_that_order_clears_the_warning(self):
        ids = self._products(settings.min_products_to_verify, quantity=5)
        self._verify()
        self.client.post(
            f"/shops/{SHOP_ID}/stock/reserve",
            json={"order_id": "order-1", "lines": [{"product_id": ids[0], "quantity": 5}]},
        )
        self.assertIsNotNone(self._shop().low_product_warning_at)

        self.client.post(
            f"/shops/{SHOP_ID}/stock/release", json={"order_id": "order-1"}
        )
        self.assertIsNone(self._shop().low_product_warning_at)


if __name__ == "__main__":
    unittest.main()
