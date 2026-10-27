"""Item 12: stock is held when an order is placed and returned when it ends.

The interesting cases are all about two things happening at once, so these
run against a real (SQLite) database through the real routes:

    cd services/shop-service
    JWT_SECRET=<32+ chars> python -m pytest tests/test_stock_reservations.py -q
"""

import unittest

from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app import logic, stock_alerts
from app.config import settings
from app.database import Base, get_db
from app.models import Product, Shop, ShopCategory, StockReservation
from app.routers import products_router, stock_router

SHOP_ID = "44444444-4444-4444-4444-444444444444"
OTHER_SHOP_ID = "55555555-5555-5555-5555-555555555555"


class StockReservationTests(unittest.TestCase):
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
        app.include_router(stock_router.router)
        app.include_router(products_router.router)
        app.dependency_overrides[get_db] = override_get_db
        self.client = TestClient(app)

        # Capture owner notifications instead of publishing them to Redis.
        self.notifications: list[dict] = []
        self._original_notify = stock_alerts.notify_users

        async def capture(user_ids, title, body, kind="general", link=None):
            self.notifications.append({"user_ids": user_ids, "title": title, "body": body})

        stock_alerts.notify_users = capture

        session = self.Session()
        for shop_id in (SHOP_ID, OTHER_SHOP_ID):
            session.add(
                Shop(
                    id=shop_id,
                    owner_id="owner-1",
                    name=f"Shop {shop_id[:4]}",
                    category=ShopCategory.grocery,
                    latitude=6.9271,
                    longitude=79.8612,
                )
            )
        session.commit()
        session.close()

    def tearDown(self):
        stock_alerts.notify_users = self._original_notify
        self.engine.dispose()

    # --- helpers ---
    def _product(self, quantity: int, name="Rice 5kg", shop_id=SHOP_ID) -> str:
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

    def _reserve(self, order_id: str, lines, shop_id=SHOP_ID):
        return self.client.post(
            f"/shops/{shop_id}/stock/reserve",
            json={"order_id": order_id, "lines": lines},
        )

    def _release(self, order_id: str, shop_id=SHOP_ID):
        return self.client.post(
            f"/shops/{shop_id}/stock/release", json={"order_id": order_id}
        )

    def _stock(self, product_id: str) -> int:
        session = self.Session()
        try:
            return session.get(Product, product_id).stock_quantity
        finally:
            session.close()

    def _hidden(self, product_id: str) -> bool:
        session = self.Session()
        try:
            return session.get(Product, product_id).is_hidden
        finally:
            session.close()

    def _customer_names(self) -> list[str]:
        return [
            item["name"]
            for item in self.client.get(f"/shops/{SHOP_ID}/products").json()
        ]

    def _status(self, product_id: str) -> str:
        session = self.Session()
        try:
            return session.get(Product, product_id).stock_status
        finally:
            session.close()

    # --- the happy path ---
    def test_reserving_lowers_the_stock(self):
        product_id = self._product(10)
        response = self._reserve("order-1", [{"product_id": product_id, "quantity": 3}])
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.json()["changed"])
        self.assertEqual(self._stock(product_id), 7)

    def test_an_order_for_exactly_the_remaining_stock_succeeds(self):
        product_id = self._product(5)
        response = self._reserve("order-1", [{"product_id": product_id, "quantity": 5}])
        self.assertEqual(response.status_code, 200)
        self.assertEqual(self._stock(product_id), 0)
        self.assertEqual(self._status(product_id), "out_of_stock")
        # ... and the product leaves the customer's list (item 11).
        names = [
            item["name"]
            for item in self.client.get(f"/shops/{SHOP_ID}/products").json()
        ]
        self.assertNotIn("Rice 5kg", names)

    # --- the last item, and running low ---
    def test_customers_can_order_the_very_last_item(self):
        product_id = self._product(1, name="Last one")
        self.assertIn("Last one", self._customer_names())
        response = self._reserve("order-1", [{"product_id": product_id, "quantity": 1}])
        self.assertEqual(response.status_code, 200)
        self.assertEqual(self._stock(product_id), 0)

    def test_selling_the_last_item_hides_the_product_and_tells_the_owner(self):
        product_id = self._product(1, name="Last one")
        self._reserve("order-1", [{"product_id": product_id, "quantity": 1}])
        self.assertTrue(self._hidden(product_id))
        self.assertNotIn("Last one", self._customer_names())
        self.assertEqual(len(self.notifications), 1)
        self.assertEqual(self.notifications[0]["user_ids"], ["owner-1"])
        self.assertIn("Last one", self.notifications[0]["title"])
        self.assertIn("sold out", self.notifications[0]["title"])

    def test_selling_down_to_five_warns_the_owner_with_the_name(self):
        product_id = self._product(8, name="Sugar 1kg")
        self._reserve("order-1", [{"product_id": product_id, "quantity": 3}])
        self.assertEqual(self._stock(product_id), 5)
        self.assertFalse(self._hidden(product_id))
        self.assertEqual(len(self.notifications), 1)
        self.assertIn("Sugar 1kg", self.notifications[0]["title"])
        self.assertIn("running low", self.notifications[0]["title"])
        self.assertIn("Only 5", self.notifications[0]["body"])

    def test_the_low_stock_warning_is_not_repeated_on_every_sale(self):
        product_id = self._product(6, name="Sugar 1kg")
        self._reserve("order-1", [{"product_id": product_id, "quantity": 1}])
        self._reserve("order-2", [{"product_id": product_id, "quantity": 1}])
        self._reserve("order-3", [{"product_id": product_id, "quantity": 1}])
        self.assertEqual(len(self.notifications), 1)

    def test_a_sale_that_stays_above_five_sends_nothing(self):
        product_id = self._product(10)
        self._reserve("order-1", [{"product_id": product_id, "quantity": 2}])
        self.assertEqual(self.notifications, [])

    def test_a_hidden_product_cannot_be_ordered(self):
        product_id = self._product(10, name="Hidden by owner")
        session = self.Session()
        product = session.get(Product, product_id)
        product.is_hidden = True
        product.hidden_reason = "owner"
        session.commit()
        session.close()

        response = self._reserve("order-1", [{"product_id": product_id, "quantity": 1}])
        self.assertEqual(response.status_code, 409)
        self.assertIn("no longer available", response.json()["detail"])
        self.assertEqual(self._stock(product_id), 10)

    def test_cancelling_does_not_unhide_a_product_the_owner_hid(self):
        product_id = self._product(3, name="Owner hid it")
        self._reserve("order-1", [{"product_id": product_id, "quantity": 3}])
        session = self.Session()
        session.get(Product, product_id).hidden_reason = "owner"
        session.commit()
        session.close()

        self._release("order-1")
        self.assertTrue(self._hidden(product_id))

    # --- refusals ---
    def test_one_more_than_is_in_stock_is_refused_and_changes_nothing(self):
        product_id = self._product(5)
        response = self._reserve("order-1", [{"product_id": product_id, "quantity": 6}])
        self.assertEqual(response.status_code, 409)
        self.assertIn("Rice 5kg", response.json()["detail"])
        self.assertEqual(self._stock(product_id), 5)

    def test_a_short_second_line_rolls_the_first_line_back(self):
        plenty = self._product(10, name="Plenty")
        scarce = self._product(1, name="Scarce")
        response = self._reserve(
            "order-1",
            [
                {"product_id": plenty, "quantity": 2},
                {"product_id": scarce, "quantity": 5},
            ],
        )
        self.assertEqual(response.status_code, 409)
        self.assertIn("Scarce", response.json()["detail"])
        self.assertEqual(self._stock(plenty), 10)
        self.assertEqual(self._stock(scarce), 1)

    def test_nothing_is_recorded_when_a_reservation_is_refused(self):
        product_id = self._product(1)
        self._reserve("order-1", [{"product_id": product_id, "quantity": 5}])
        session = self.Session()
        self.assertEqual(session.query(StockReservation).count(), 0)
        session.close()

    def test_a_product_marked_out_of_stock_cannot_be_reserved(self):
        product_id = self._product(10)
        session = self.Session()
        product = session.get(Product, product_id)
        product.stock_status = "out_of_stock"
        product.is_available = False
        session.commit()
        session.close()
        response = self._reserve("order-1", [{"product_id": product_id, "quantity": 1}])
        self.assertEqual(response.status_code, 409)
        self.assertEqual(self._stock(product_id), 10)

    def test_a_deleted_product_is_refused(self):
        product_id = self._product(10)
        session = self.Session()
        session.delete(session.get(Product, product_id))
        session.commit()
        session.close()
        response = self._reserve("order-1", [{"product_id": product_id, "quantity": 1}])
        self.assertEqual(response.status_code, 409)
        self.assertIn("no longer sold", response.json()["detail"])

    def test_a_product_from_another_shop_is_refused(self):
        product_id = self._product(10, shop_id=OTHER_SHOP_ID)
        response = self._reserve("order-1", [{"product_id": product_id, "quantity": 1}])
        self.assertEqual(response.status_code, 409)
        self.assertEqual(self._stock(product_id), 10)

    def test_a_quantity_of_zero_or_less_is_rejected_by_the_schema(self):
        product_id = self._product(10)
        for quantity in (0, -3):
            response = self._reserve(
                "order-1", [{"product_id": product_id, "quantity": quantity}]
            )
            self.assertEqual(response.status_code, 422)
        self.assertEqual(self._stock(product_id), 10)

    def test_an_unknown_shop_is_a_404(self):
        response = self._reserve(
            "order-1",
            [{"product_id": "x", "quantity": 1}],
            shop_id="99999999-9999-9999-9999-999999999999",
        )
        self.assertEqual(response.status_code, 404)

    # --- idempotency ---
    def test_the_same_order_reserved_twice_takes_the_stock_once(self):
        product_id = self._product(10)
        lines = [{"product_id": product_id, "quantity": 4}]
        first = self._reserve("order-1", lines)
        second = self._reserve("order-1", lines)
        self.assertEqual(first.status_code, 200)
        self.assertEqual(second.status_code, 200)
        self.assertTrue(first.json()["changed"])
        self.assertFalse(second.json()["changed"])
        self.assertEqual(self._stock(product_id), 6)

    def test_the_same_product_twice_in_one_order_is_counted_once(self):
        product_id = self._product(10)
        response = self._reserve(
            "order-1",
            [
                {"product_id": product_id, "quantity": 3},
                {"product_id": product_id, "quantity": 4},
            ],
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(self._stock(product_id), 3)

    def test_the_same_product_twice_is_also_checked_as_a_total(self):
        product_id = self._product(5)
        response = self._reserve(
            "order-1",
            [
                {"product_id": product_id, "quantity": 3},
                {"product_id": product_id, "quantity": 3},
            ],
        )
        self.assertEqual(response.status_code, 409)
        self.assertEqual(self._stock(product_id), 5)

    # --- releasing ---
    def test_releasing_puts_the_stock_back(self):
        product_id = self._product(10)
        self._reserve("order-1", [{"product_id": product_id, "quantity": 4}])
        response = self._release("order-1")
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.json()["changed"])
        self.assertEqual(self._stock(product_id), 10)

    def test_releasing_twice_returns_the_stock_once(self):
        product_id = self._product(10)
        self._reserve("order-1", [{"product_id": product_id, "quantity": 4}])
        self._release("order-1")
        second = self._release("order-1")
        self.assertEqual(second.status_code, 200)
        self.assertFalse(second.json()["changed"])
        self.assertEqual(self._stock(product_id), 10)

    def test_releasing_an_order_that_never_reserved_is_a_no_op(self):
        response = self._release("order-never-existed")
        self.assertEqual(response.status_code, 200)
        self.assertFalse(response.json()["changed"])

    def test_a_release_can_bring_a_product_back_into_the_list(self):
        product_id = self._product(6, name="Comes back")
        self._reserve("order-1", [{"product_id": product_id, "quantity": 6}])
        # The last item sold: the product is hidden from customers.
        names = [
            item["name"]
            for item in self.client.get(f"/shops/{SHOP_ID}/products").json()
        ]
        self.assertNotIn("Comes back", names)

        self._release("order-1")
        names = [
            item["name"]
            for item in self.client.get(f"/shops/{SHOP_ID}/products").json()
        ]
        self.assertIn("Comes back", names)
        self.assertEqual(self._stock(product_id), 6)
        self.assertFalse(self._hidden(product_id))

    def test_a_release_restores_the_stock_status(self):
        product_id = self._product(5)
        self._reserve("order-1", [{"product_id": product_id, "quantity": 5}])
        self.assertEqual(self._status(product_id), "out_of_stock")
        self._release("order-1")
        self.assertEqual(self._status(product_id), "low_stock")

    def test_two_orders_are_released_independently(self):
        product_id = self._product(10)
        self._reserve("order-1", [{"product_id": product_id, "quantity": 3}])
        self._reserve("order-2", [{"product_id": product_id, "quantity": 2}])
        self.assertEqual(self._stock(product_id), 5)
        self._release("order-1")
        self.assertEqual(self._stock(product_id), 8)
        self._release("order-2")
        self.assertEqual(self._stock(product_id), 10)

    # --- two buyers after the same units ---
    def test_the_second_buyer_of_the_last_units_is_refused(self):
        """Two orders for the last 5: one gets them, stock lands on 0, not -5."""
        product_id = self._product(5)
        first = self._reserve("order-1", [{"product_id": product_id, "quantity": 5}])
        second = self._reserve("order-2", [{"product_id": product_id, "quantity": 5}])
        self.assertEqual(first.status_code, 200)
        self.assertEqual(second.status_code, 409)
        self.assertEqual(self._stock(product_id), 0)

    def test_a_partly_available_second_order_is_refused_whole(self):
        product_id = self._product(5)
        self._reserve("order-1", [{"product_id": product_id, "quantity": 3}])
        second = self._reserve("order-2", [{"product_id": product_id, "quantity": 3}])
        self.assertEqual(second.status_code, 409)
        # Not 2 units sold and 1 missing: the second order took nothing.
        self.assertEqual(self._stock(product_id), 2)

    def test_the_hold_is_one_conditional_update_per_line(self):
        """What makes simultaneous orders safe is the database doing the check.

        SQLite cannot run the two requests at once, so the guarantee is
        checked here by reading the source: the quantity must be compared
        inside the UPDATE, never read first and written back.
        """
        import inspect

        source = inspect.getsource(stock_router.reserve_stock)
        self.assertIn("update(Product)", source)
        self.assertIn("Product.stock_quantity >= quantity", source)
        self.assertIn("result.rowcount != 1", source)


if __name__ == "__main__":
    unittest.main()
