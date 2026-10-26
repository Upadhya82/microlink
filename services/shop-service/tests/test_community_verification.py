"""Nearby customers vouching a registered shop into verified status.

    cd services/shop-service
    JWT_SECRET=<32+ chars> python -m pytest tests/test_community_verification.py -q

The case this exists for: a shop registered in Homagama that no admin has
ever visited. It is visible from the start (search has never filtered on
is_verified), but only an admin could lift the "not verified" chip off it.
Now three nearby customers can.
"""

import unittest
from datetime import datetime, timedelta, timezone

import jwt
from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app import community, listings, logic
from app.config import settings
from app.database import Base, get_db
from app.models import Product, Shop, ShopCategory, ShopExistenceConfirmation
from app.routers import products_router, shops_router

OWNER_ID = "11111111-1111-1111-1111-111111111111"
SHOP_ID = "33333333-3333-3333-3333-333333333333"
ADMIN_ID = "22222222-2222-2222-2222-222222222222"

# Homagama town, and the shop itself a few hundred metres away.
HOMAGAMA = (6.8441, 80.0020)
SHOP_LAT, SHOP_LNG = 6.8450, 80.0035
# Far enough to be out of confirm_radius_km: Colombo Fort, ~25 km away.
COLOMBO = (6.9334, 79.8503)


def _auth(user_id: str, role: str = "customer", verified: bool = True) -> dict[str, str]:
    token = jwt.encode(
        {
            "sub": user_id,
            "role": role,
            "verified": verified,
            "exp": datetime.now(timezone.utc) + timedelta(hours=1),
        },
        settings.jwt_secret,
        algorithm=settings.jwt_algorithm,
    )
    return {"Authorization": f"Bearer {token}"}


def _customer(index: int) -> str:
    return f"c{index:07d}-0000-0000-0000-000000000000"


class CommunityVerificationTests(unittest.TestCase):
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

        # Keep the event bus out of it, and record what the owner was told.
        self.notifications: list[dict] = []
        self.events: list[tuple[str, dict]] = []
        self.originals = {
            "shops_notify": shops_router.notify_users,
            "shops_publish": shops_router.publish_event,
            "community_notify": community.notify_users,
            "community_publish": community.publish_event,
            "community_fetch": community.fetch_trust_score,
            "listings_notify": listings.notify_users,
        }

        async def quiet(*args, **kwargs):
            return None

        async def record_notify(user_ids, title, body, kind="general", link=None):
            self.notifications.append(
                {"user_ids": list(user_ids), "title": title, "body": body}
            )

        async def record_event(event_type, payload):
            self.events.append((event_type, payload))

        # crowdsource-service is not running in a unit test; the score it
        # would have returned is injected instead.
        self.trust_score: float | None = 50.0

        async def fake_fetch(user_id, bearer_token):
            return self.trust_score

        shops_router.notify_users = quiet
        shops_router.publish_event = quiet
        community.notify_users = record_notify
        community.publish_event = record_event
        community.fetch_trust_score = fake_fetch
        listings.notify_users = quiet

        session = self.Session()
        session.add(
            Shop(
                id=SHOP_ID,
                owner_id=OWNER_ID,
                name="Homagama Stores",
                category=ShopCategory.grocery,
                latitude=SHOP_LAT,
                longitude=SHOP_LNG,
            )
        )
        session.commit()
        session.close()

    def tearDown(self):
        shops_router.notify_users = self.originals["shops_notify"]
        shops_router.publish_event = self.originals["shops_publish"]
        community.notify_users = self.originals["community_notify"]
        community.publish_event = self.originals["community_publish"]
        community.fetch_trust_score = self.originals["community_fetch"]
        listings.notify_users = self.originals["listings_notify"]
        self.engine.dispose()

    # --- helpers ---
    def _stock(self, count=None, quantity=10, shop_id=SHOP_ID):
        """Give the shop enough listable products to satisfy item 10."""
        count = settings.min_products_to_verify if count is None else count
        session = self.Session()
        for index in range(count):
            session.add(
                Product(
                    shop_id=shop_id,
                    name=f"Product {index}",
                    price=100.0,
                    stock_quantity=quantity,
                    stock_status=logic.derive_stock_status(
                        quantity, settings.low_stock_threshold
                    ),
                    is_available=quantity > 0,
                )
            )
        session.commit()
        session.close()

    def _confirm(self, user_id, position=HOMAGAMA, role="customer", verified=True):
        return self.client.post(
            f"/shops/{SHOP_ID}/confirm",
            json={"latitude": position[0], "longitude": position[1]},
            headers=_auth(user_id, role, verified),
        )

    def _confirm_enough(self):
        """One short of the threshold, from distinct nearby customers."""
        for index in range(settings.community_confirmations_to_verify - 1):
            response = self._confirm(_customer(index))
            self.assertEqual(response.status_code, 201, response.text)

    def _shop(self) -> Shop:
        session = self.Session()
        try:
            return session.get(Shop, SHOP_ID)
        finally:
            session.close()

    def _count(self) -> int:
        session = self.Session()
        try:
            return community.confirmation_count(session, SHOP_ID)
        finally:
            session.close()

    # ----------------------------------------------------- the happy path
    def test_enough_nearby_customers_verify_the_shop(self):
        self._stock()
        self._confirm_enough()
        self.assertFalse(self._shop().is_verified)

        response = self._confirm(_customer(99))
        self.assertEqual(response.status_code, 201, response.text)
        body = response.json()
        self.assertTrue(body["is_verified"])
        self.assertEqual(body["verified_via"], "community")
        self.assertEqual(body["confirmations"], settings.community_confirmations_to_verify)

        shop = self._shop()
        self.assertTrue(shop.is_verified)
        self.assertEqual(shop.verified_via, "community")
        self.assertEqual(shop.verified_by, "community")
        self.assertIsNotNone(shop.verified_at)

    def test_the_owner_is_told_and_the_event_is_published(self):
        self._stock()
        self._confirm_enough()
        self.notifications.clear()
        self.events.clear()

        self._confirm(_customer(99))

        self.assertEqual(len(self.notifications), 1)
        self.assertEqual(self.notifications[0]["user_ids"], [OWNER_ID])
        self.assertIn("neighbours", self.notifications[0]["title"])

        published = [payload for name, payload in self.events if name == "shop.verified"]
        self.assertEqual(len(published), 1)
        self.assertEqual(published[0]["verified_via"], "community")
        self.assertEqual(published[0]["shop_id"], SHOP_ID)

    def test_one_short_of_the_threshold_does_not_verify(self):
        self._stock()
        self._confirm_enough()
        self.assertFalse(self._shop().is_verified)
        self.assertEqual(self._count(), settings.community_confirmations_to_verify - 1)

    # ------------------------------------------------- who may not confirm
    def test_the_same_person_cannot_confirm_twice(self):
        self._stock()
        first = self._confirm(_customer(1))
        self.assertEqual(first.status_code, 201)
        # Not an error: a retry on a poor connection must be harmless.
        second = self._confirm(_customer(1))
        self.assertEqual(second.status_code, 201)
        self.assertEqual(self._count(), 1)
        self.assertFalse(self._shop().is_verified)

    def test_three_taps_by_one_person_cannot_verify_a_shop(self):
        self._stock()
        for _ in range(settings.community_confirmations_to_verify + 2):
            self._confirm(_customer(1))
        self.assertEqual(self._count(), 1)
        self.assertFalse(self._shop().is_verified)

    def test_the_owner_cannot_confirm_their_own_shop(self):
        self._stock()
        response = self._confirm(OWNER_ID, role="shop_owner")
        self.assertEqual(response.status_code, 400)
        self.assertIn("your own shop", response.json()["detail"])
        self.assertEqual(self._count(), 0)

    def test_an_unverified_account_cannot_confirm(self):
        self._stock()
        response = self._confirm(_customer(1), verified=False)
        self.assertEqual(response.status_code, 403)
        self.assertEqual(self._count(), 0)

    def test_a_customer_too_far_away_cannot_confirm(self):
        self._stock()
        response = self._confirm(_customer(1), position=COLOMBO)
        self.assertEqual(response.status_code, 400)
        self.assertIn("km away", response.json()["detail"])
        self.assertEqual(self._count(), 0)

    def test_a_low_trust_account_cannot_confirm(self):
        self._stock()
        self.trust_score = settings.min_confirm_trust - 1
        response = self._confirm(_customer(1))
        self.assertEqual(response.status_code, 403)
        self.assertEqual(self._count(), 0)

    def test_an_unreachable_crowdsource_service_is_treated_as_the_default(self):
        # None means "could not read it"; a new account's 50 is assumed, so
        # an outage in a service that only restricts does not block anyone.
        self._stock()
        self.trust_score = None
        self.assertEqual(self._confirm(_customer(1)).status_code, 201)
        self.assertEqual(self._count(), 1)

    def test_signing_in_is_required(self):
        response = self.client.post(
            f"/shops/{SHOP_ID}/confirm",
            json={"latitude": HOMAGAMA[0], "longitude": HOMAGAMA[1]},
        )
        self.assertEqual(response.status_code, 401)

    def test_a_position_is_required(self):
        response = self.client.post(
            f"/shops/{SHOP_ID}/confirm", json={}, headers=_auth(_customer(1))
        )
        self.assertEqual(response.status_code, 422)

    def test_an_already_verified_shop_refuses_confirmations(self):
        self._stock()
        session = self.Session()
        session.get(Shop, SHOP_ID).is_verified = True
        session.commit()
        session.close()

        response = self._confirm(_customer(1))
        self.assertEqual(response.status_code, 400)
        self.assertIn("already verified", response.json()["detail"])

    def test_confirming_a_shop_that_does_not_exist_is_a_404(self):
        response = self.client.post(
            "/shops/99999999-9999-9999-9999-999999999999/confirm",
            json={"latitude": HOMAGAMA[0], "longitude": HOMAGAMA[1]},
            headers=_auth(_customer(1)),
        )
        self.assertEqual(response.status_code, 404)

    # ---------------------------------------- item 10 still has to be met
    def test_a_vouched_shop_with_no_products_stays_unverified(self):
        # No stock at all: the neighbourhood says it exists, but verifying an
        # empty storefront is what item 10 forbids.
        for index in range(settings.community_confirmations_to_verify):
            self.assertEqual(self._confirm(_customer(index)).status_code, 201)
        self.assertFalse(self._shop().is_verified)

    def test_its_owner_is_told_what_is_missing(self):
        for index in range(settings.community_confirmations_to_verify):
            self._confirm(_customer(index))
        owner_notes = [n for n in self.notifications if n["user_ids"] == [OWNER_ID]]
        self.assertEqual(len(owner_notes), 1)
        self.assertIn("one step left", owner_notes[0]["title"])
        self.assertIn("it has 0", owner_notes[0]["body"])

    def test_it_is_told_once_not_on_every_confirmation(self):
        for index in range(settings.community_confirmations_to_verify + 3):
            self._confirm(_customer(index))
        owner_notes = [n for n in self.notifications if n["user_ids"] == [OWNER_ID]]
        self.assertEqual(len(owner_notes), 1)

    def test_restocking_afterwards_verifies_it_without_another_confirmation(self):
        """The other order: confirmations first, products later."""
        for index in range(settings.community_confirmations_to_verify):
            self._confirm(_customer(index))
        self.assertFalse(self._shop().is_verified)

        # The owner adds the products through the real endpoint, which is
        # what runs listings.review_product_count.
        headers = _auth(OWNER_ID, "shop_owner")
        for index in range(settings.min_products_to_verify):
            response = self.client.post(
                f"/shops/{SHOP_ID}/products",
                json={"name": f"Rice {index}", "price": 250.0, "stock_quantity": 10},
                headers=headers,
            )
            self.assertEqual(response.status_code, 201, response.text)

        self.assertTrue(self._shop().is_verified)
        self.assertEqual(self._shop().verified_via, "community")

    def test_products_without_enough_confirmations_do_not_verify_anything(self):
        self._stock()
        headers = _auth(OWNER_ID, "shop_owner")
        self.client.post(
            f"/shops/{SHOP_ID}/products",
            json={"name": "Rice", "price": 250.0, "stock_quantity": 10},
            headers=headers,
        )
        self.assertFalse(self._shop().is_verified)

    # --------------------------------------------- what the app is shown
    def test_the_confirmations_endpoint_reports_the_standing(self):
        self._stock()
        self._confirm(_customer(1))
        response = self.client.get(f"/shops/{SHOP_ID}/confirmations")
        self.assertEqual(response.status_code, 200)
        body = response.json()
        self.assertEqual(body["confirmations"], 1)
        self.assertEqual(body["required"], settings.community_confirmations_to_verify)
        self.assertFalse(body["is_verified"])
        self.assertFalse(body["confirmed_by_me"])  # nobody signed in
        self.assertEqual(body["products_still_needed"], 0)

    def test_it_knows_whether_the_caller_already_confirmed(self):
        self._stock()
        self._confirm(_customer(1))
        mine = self.client.get(
            f"/shops/{SHOP_ID}/confirmations", headers=_auth(_customer(1))
        )
        self.assertTrue(mine.json()["confirmed_by_me"])
        theirs = self.client.get(
            f"/shops/{SHOP_ID}/confirmations", headers=_auth(_customer(2))
        )
        self.assertFalse(theirs.json()["confirmed_by_me"])

    def test_it_reports_how_many_products_are_still_needed(self):
        response = self.client.get(f"/shops/{SHOP_ID}/confirmations")
        self.assertEqual(
            response.json()["products_still_needed"], settings.min_products_to_verify
        )

    def test_the_shop_card_carries_the_tally(self):
        self._stock()
        self._confirm(_customer(1))
        self._confirm(_customer(2))
        response = self.client.get("/shops", params={"limit": 50})
        card = next(item for item in response.json() if item["id"] == SHOP_ID)
        self.assertEqual(card["community_confirmations"], 2)
        self.assertEqual(
            card["confirmations_required"], settings.community_confirmations_to_verify
        )

    def test_an_unverified_shop_is_still_listed_to_nearby_customers(self):
        """The premise this feature was asked about: it was never hidden."""
        response = self.client.get(
            "/shops", params={"lat": HOMAGAMA[0], "lng": HOMAGAMA[1], "radius_km": 10}
        )
        self.assertEqual(response.status_code, 200)
        ids = [item["id"] for item in response.json()]
        self.assertIn(SHOP_ID, ids)
        card = next(item for item in response.json() if item["id"] == SHOP_ID)
        self.assertFalse(card["is_verified"])

    # ------------------------------------------------- the admin route too
    def test_an_admin_verifying_is_recorded_as_admin(self):
        self._stock()
        response = self.client.patch(
            f"/shops/{SHOP_ID}/verify",
            json={"is_verified": True},
            headers=_auth(ADMIN_ID, "admin"),
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(self._shop().verified_via, "admin")

    def test_community_confirmations_never_overwrite_an_admins_decision(self):
        self._stock()
        self.client.patch(
            f"/shops/{SHOP_ID}/verify",
            json={"is_verified": True},
            headers=_auth(ADMIN_ID, "admin"),
        )
        # Un-verified again by the admin: the shop was wrong, so the stale
        # confirmations must not put it straight back.
        session = self.Session()
        for index in range(settings.community_confirmations_to_verify):
            session.add(
                ShopExistenceConfirmation(
                    shop_id=SHOP_ID,
                    user_id=_customer(index),
                    latitude=HOMAGAMA[0],
                    longitude=HOMAGAMA[1],
                    distance_km=0.2,
                )
            )
        session.commit()
        session.close()

        self.client.patch(
            f"/shops/{SHOP_ID}/verify",
            json={"is_verified": False},
            headers=_auth(ADMIN_ID, "admin"),
        )
        self.assertFalse(self._shop().is_verified)
        self.assertIsNone(self._shop().verified_via)
        # The overruled evidence is gone, so nothing can re-verify it.
        self.assertEqual(self._count(), 0)

    def test_un_verifying_survives_the_owners_next_product_edit(self):
        """The hole this closes: the confirmations used to still be standing
        after an admin un-verified a shop, so the next product change ran
        try_auto_verify and put the shop straight back."""
        self._stock()
        for index in range(settings.community_confirmations_to_verify):
            self._confirm(_customer(index))
        self.assertTrue(self._shop().is_verified)

        self.client.patch(
            f"/shops/{SHOP_ID}/verify",
            json={"is_verified": False},
            headers=_auth(ADMIN_ID, "admin"),
        )
        self.assertFalse(self._shop().is_verified)

        response = self.client.post(
            f"/shops/{SHOP_ID}/products",
            json={"name": "Tea", "price": 300.0, "stock_quantity": 10},
            headers=_auth(OWNER_ID, "shop_owner"),
        )
        self.assertEqual(response.status_code, 201, response.text)
        self.assertFalse(self._shop().is_verified)

    def test_the_neighbours_can_confirm_again_after_an_admin_overrules_them(self):
        self._stock()
        for index in range(settings.community_confirmations_to_verify):
            self._confirm(_customer(index))
        self.client.patch(
            f"/shops/{SHOP_ID}/verify",
            json={"is_verified": False},
            headers=_auth(ADMIN_ID, "admin"),
        )
        for index in range(settings.community_confirmations_to_verify):
            self.assertEqual(self._confirm(_customer(index)).status_code, 201)
        self.assertTrue(self._shop().is_verified)

    # ------------------------------------------------------- the pure rule
    def test_the_rule_rejects_a_missing_position(self):
        with self.assertRaises(community.ConfirmationRefused):
            community.can_confirm_shop(
                is_verified=True, trust_score=80.0, distance_km=None, is_owner=False
            )

    def test_the_rule_accepts_a_nearby_verified_account(self):
        community.can_confirm_shop(
            is_verified=True, trust_score=50.0, distance_km=0.5, is_owner=False
        )

    def test_the_rule_treats_a_missing_score_as_the_starting_fifty(self):
        community.can_confirm_shop(
            is_verified=True, trust_score=None, distance_km=0.5, is_owner=False
        )

    def test_the_distance_is_measured_from_the_shop(self):
        shop = self._shop()
        near = community.distance_to_shop(shop, *HOMAGAMA)
        far = community.distance_to_shop(shop, *COLOMBO)
        self.assertLess(near, 1.0)
        self.assertGreater(far, settings.confirm_radius_km)


if __name__ == "__main__":
    unittest.main()
