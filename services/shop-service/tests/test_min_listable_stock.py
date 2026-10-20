"""REQ: a product needs a minimum stock before customers may see it (item 11).

Two layers:
  * `logic.is_listable` on its own, with no database;
  * the product endpoints over an in-memory SQLite database, which is where
    the "who sees what" rule actually lives.

    cd services/shop-service
    JWT_SECRET=<32+ chars> python -m pytest tests/test_min_listable_stock.py -q
"""

import unittest
from datetime import datetime, timedelta, timezone

import jwt
from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app import logic
from app.config import settings
from app.database import Base, get_db
from app.models import Product, Shop, ShopCategory
from app.routers import products_router, shops_router

OWNER_ID = "11111111-1111-1111-1111-111111111111"
CUSTOMER_ID = "22222222-2222-2222-2222-222222222222"
ADMIN_ID = "33333333-3333-3333-3333-333333333333"
SHOP_ID = "44444444-4444-4444-4444-444444444444"
OTHER_SHOP_ID = "55555555-5555-5555-5555-555555555555"


def _token(user_id: str, role: str) -> str:
    return jwt.encode(
        {
            "sub": user_id,
            "role": role,
            "verified": True,
            "exp": datetime.now(timezone.utc) + timedelta(hours=1),
        },
        settings.jwt_secret,
        algorithm=settings.jwt_algorithm,
    )


def _auth(user_id: str, role: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {_token(user_id, role)}"}


class IsListableTests(unittest.TestCase):
    """The rule on its own: 5 is listable, 4 is not, "nothing said" is not."""

    def test_at_or_above_the_minimum_is_listable(self):
        self.assertTrue(logic.is_listable(5))
        self.assertTrue(logic.is_listable(6))
        self.assertTrue(logic.is_listable(500))

    def test_below_the_minimum_is_not_listable(self):
        self.assertFalse(logic.is_listable(4))
        self.assertFalse(logic.is_listable(1))
        self.assertFalse(logic.is_listable(0))

    def test_a_missing_quantity_is_not_listable(self):
        self.assertFalse(logic.is_listable(None))

    def test_the_minimum_can_be_changed(self):
        self.assertTrue(logic.is_listable(2, minimum=2))
        self.assertFalse(logic.is_listable(2, minimum=3))

    def test_the_setting_is_separate_from_the_low_stock_label(self):
        # Exactly 5 is listable, and is still labelled "low stock".
        self.assertTrue(logic.is_listable(5, settings.min_listable_stock))
        self.assertEqual(
            logic.derive_stock_status(5, settings.low_stock_threshold), "low_stock"
        )


class ProductListingRuleTests(unittest.TestCase):
    """The create threshold and the customer/owner split, over the real routes."""

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
        app.dependency_overrides[get_db] = override_get_db
        self.client = TestClient(app)

        session = self.Session()
        for shop_id, owner in ((SHOP_ID, OWNER_ID), (OTHER_SHOP_ID, "other-owner")):
            session.add(
                Shop(
                    id=shop_id,
                    owner_id=owner,
                    name=f"Shop {shop_id[:4]}",
                    category=ShopCategory.grocery,
                    latitude=6.9271,
                    longitude=79.8612,
                )
            )
        session.commit()
        session.close()

    def tearDown(self):
        self.engine.dispose()

    # --- helpers ---
    def _create(self, quantity, name="Rice 5kg", shop_id=SHOP_ID):
        body = {"name": name, "price": 100.0}
        if quantity is not None:
            body["stock_quantity"] = quantity
        return self.client.post(
            f"/shops/{shop_id}/products", json=body, headers=_auth(OWNER_ID, "shop_owner")
        )

    def _add_product(self, quantity, name="Stored", shop_id=SHOP_ID) -> str:
        """Put a product straight into the database, past the create rule."""
        session = self.Session()
        product = Product(
            shop_id=shop_id,
            name=name,
            price=100.0,
            stock_quantity=quantity,
            stock_status=logic.derive_stock_status(quantity, settings.low_stock_threshold),
            is_available=quantity > 0,
        )
        session.add(product)
        session.commit()
        product_id = product.id
        session.close()
        return product_id

    def _names(self, headers=None, params=None) -> list[str]:
        response = self.client.get(
            f"/shops/{SHOP_ID}/products", headers=headers or {}, params=params or {}
        )
        self.assertEqual(response.status_code, 200)
        return [item["name"] for item in response.json()]

    # --- create ---
    def test_create_below_the_minimum_is_refused(self):
        response = self._create(4)
        self.assertEqual(response.status_code, 422)
        self.assertIn("at least 5", response.json()["detail"])

    def test_create_at_the_minimum_is_allowed_and_visible_to_customers(self):
        self.assertEqual(self._create(5, name="Exactly five").status_code, 201)
        self.assertIn("Exactly five", self._names())

    def test_create_above_the_minimum_is_visible(self):
        self.assertEqual(self._create(6, name="Six").status_code, 201)
        self.assertIn("Six", self._names())

    def test_create_without_a_quantity_is_refused(self):
        self.assertEqual(self._create(None).status_code, 422)

    def test_create_with_zero_is_refused(self):
        self.assertEqual(self._create(0).status_code, 422)

    def test_a_refused_create_stores_nothing(self):
        self._create(4)
        session = self.Session()
        self.assertEqual(session.query(Product).count(), 0)
        session.close()

    # --- who sees what ---
    def test_a_product_that_falls_below_the_minimum_leaves_the_customer_list(self):
        product_id = self._add_product(5, name="Sells down")
        response = self.client.patch(
            f"/shops/{SHOP_ID}/products/{product_id}",
            json={"stock_quantity": 4},
            headers=_auth(OWNER_ID, "shop_owner"),
        )
        self.assertEqual(response.status_code, 200)
        self.assertNotIn("Sells down", self._names())
        self.assertIn("Sells down", self._names(headers=_auth(OWNER_ID, "shop_owner")))
        self.assertIn("Sells down", self._names(headers=_auth(ADMIN_ID, "admin")))

    def test_restocking_brings_the_product_back(self):
        product_id = self._add_product(4, name="Restocked")
        self.assertNotIn("Restocked", self._names())
        self.client.patch(
            f"/shops/{SHOP_ID}/products/{product_id}",
            json={"stock_quantity": 5},
            headers=_auth(OWNER_ID, "shop_owner"),
        )
        self.assertIn("Restocked", self._names())

    def test_an_owner_of_another_shop_is_treated_as_a_customer(self):
        self._add_product(4, name="Hidden")
        self.assertNotIn("Hidden", self._names(headers=_auth("other-owner", "shop_owner")))

    def test_a_made_up_query_parameter_does_not_lift_the_filter(self):
        self._add_product(4, name="Hidden")
        self.assertNotIn(
            "Hidden",
            self._names(headers=_auth(CUSTOMER_ID, "customer"), params={"show_all": "true"}),
        )

    def test_an_expired_token_is_refused_rather_than_ignored(self):
        self._add_product(4, name="Hidden")
        expired = jwt.encode(
            {
                "sub": CUSTOMER_ID,
                "role": "customer",
                "exp": datetime.now(timezone.utc) - timedelta(hours=1),
            },
            settings.jwt_secret,
            algorithm=settings.jwt_algorithm,
        )
        response = self.client.get(
            f"/shops/{SHOP_ID}/products", headers={"Authorization": f"Bearer {expired}"}
        )
        self.assertEqual(response.status_code, 401)

    def test_the_stock_status_filter_still_only_returns_listable_products(self):
        self._add_product(0, name="Gone")
        self._add_product(5, name="Low but listable")
        self.assertEqual(self._names(params={"stock_status": "out_of_stock"}), [])

    # --- shop cards ---
    def test_shop_cards_count_only_listable_products(self):
        self._add_product(9, name="Plenty")
        self._add_product(5, name="Just enough")
        self._add_product(4, name="Hidden")
        self._add_product(0, name="Gone")
        response = self.client.get("/shops", params={"limit": 50})
        self.assertEqual(response.status_code, 200)
        card = next(item for item in response.json() if item["id"] == SHOP_ID)
        self.assertEqual(card["product_count"], 2)
        self.assertEqual(card["in_stock_count"], 1)
        self.assertEqual(card["low_stock_count"], 1)
        self.assertEqual(card["out_of_stock_count"], 0)

    def test_a_shop_whose_products_are_all_hidden_advertises_nothing(self):
        self._add_product(4)
        response = self.client.get("/shops", params={"limit": 50})
        card = next(item for item in response.json() if item["id"] == SHOP_ID)
        self.assertEqual(card["product_count"], 0)
        self.assertEqual(card["availability"], "none")


if __name__ == "__main__":
    unittest.main()
