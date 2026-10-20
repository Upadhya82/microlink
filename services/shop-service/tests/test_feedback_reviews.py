"""Item 3: post-delivery feedback appears in the shop's reviews.

    cd services/shop-service
    JWT_SECRET=<32+ chars> python -m pytest tests/test_feedback_reviews.py -q
"""

import asyncio
import unittest

from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool

from app import feedback_reviews
from app.database import Base
from app.models import Shop, ShopCategory, ShopRating

SHOP_ID = "11111111-1111-1111-1111-111111111111"
USER_ID = "22222222-2222-2222-2222-222222222222"
OTHER_USER_ID = "33333333-3333-3333-3333-333333333333"


def _envelope(**overrides) -> dict:
    data = {
        "order_id": "order-1",
        "user_id": USER_ID,
        "rating": 5,
        "shop_id": SHOP_ID,
        "comment": "Arrived hot, very fast",
    }
    data.update(overrides)
    return {
        "event": "feedback.submitted",
        "source": "crowdsource-service",
        "data": data,
    }


class ReviewFromEventTests(unittest.TestCase):
    """What the listener accepts, with no database involved."""

    def test_a_normal_envelope_becomes_a_review(self):
        row = feedback_reviews.review_from_event(_envelope())
        self.assertEqual(row["shop_id"], SHOP_ID)
        self.assertEqual(row["user_id"], USER_ID)
        self.assertEqual(row["rating"], 5)
        self.assertEqual(row["comment"], "Arrived hot, very fast")
        self.assertEqual(row["order_id"], "order-1")
        self.assertEqual(row["source"], "order")

    def test_feedback_with_no_shop_is_ignored(self):
        # The "request delivery" flow has no shop to review.
        self.assertIsNone(feedback_reviews.review_from_event(_envelope(shop_id=None)))
        self.assertIsNone(feedback_reviews.review_from_event(_envelope(shop_id="")))

    def test_another_event_type_is_ignored(self):
        envelope = _envelope()
        envelope["event"] = "order.cancelled"
        self.assertIsNone(feedback_reviews.review_from_event(envelope))

    def test_a_rating_out_of_range_is_ignored(self):
        for rating in (0, 6, -1, 99):
            self.assertIsNone(
                feedback_reviews.review_from_event(_envelope(rating=rating)), rating
            )

    def test_a_rating_that_is_not_a_whole_number_is_ignored(self):
        for rating in (4.5, "5", True, None):
            self.assertIsNone(
                feedback_reviews.review_from_event(_envelope(rating=rating)), rating
            )

    def test_a_missing_user_is_ignored(self):
        self.assertIsNone(feedback_reviews.review_from_event(_envelope(user_id=None)))

    def test_a_missing_comment_becomes_an_empty_one(self):
        self.assertEqual(
            feedback_reviews.review_from_event(_envelope(comment=None))["comment"], ""
        )

    def test_whitespace_is_trimmed(self):
        self.assertEqual(
            feedback_reviews.review_from_event(_envelope(comment="  good  "))["comment"],
            "good",
        )

    def test_rubbish_envelopes_do_not_raise(self):
        for envelope in ({}, {"event": "feedback.submitted"}, {"event": "feedback.submitted", "data": "x"}):
            self.assertIsNone(feedback_reviews.review_from_event(envelope))


class SaveOrderReviewTests(unittest.TestCase):
    def setUp(self):
        self.engine = create_engine(
            "sqlite:///:memory:",
            connect_args={"check_same_thread": False},
            poolclass=StaticPool,
        )
        Base.metadata.create_all(self.engine)
        self.Session = sessionmaker(bind=self.engine, autoflush=False)
        self.db = self.Session()
        self.db.add(
            Shop(
                id=SHOP_ID,
                owner_id="owner-1",
                name="Corner Shop",
                category=ShopCategory.grocery,
                latitude=6.9271,
                longitude=79.8612,
            )
        )
        self.db.commit()

    def tearDown(self):
        self.db.close()
        self.engine.dispose()

    def _save(self, **overrides):
        row = feedback_reviews.review_from_event(_envelope(**overrides))
        return feedback_reviews.save_order_review(self.db, row)

    def _reviews(self) -> list[ShopRating]:
        self.db.expire_all()
        return self.db.query(ShopRating).order_by(ShopRating.created_at).all()

    def test_the_feedback_is_stored_as_a_review(self):
        saved = self._save()
        self.assertIsNotNone(saved)
        reviews = self._reviews()
        self.assertEqual(len(reviews), 1)
        self.assertEqual(reviews[0].source, "order")
        self.assertEqual(reviews[0].order_id, "order-1")
        self.assertEqual(reviews[0].rating, 5)

    def test_it_counts_towards_the_shops_score(self):
        self._save(rating=4)
        self.db.expire_all()
        shop = self.db.get(Shop, SHOP_ID)
        self.assertEqual(shop.rating_count, 1)
        self.assertAlmostEqual(shop.rating_avg, 4.0, places=3)

    def test_a_replayed_event_updates_the_same_row(self):
        self._save(rating=5)
        self._save(rating=2, comment="Changed my mind")
        reviews = self._reviews()
        self.assertEqual(len(reviews), 1)
        self.assertEqual(reviews[0].rating, 2)
        self.assertEqual(reviews[0].comment, "Changed my mind")

    def test_feedback_from_two_customers_makes_two_reviews(self):
        self._save()
        self._save(user_id=OTHER_USER_ID, order_id="order-2")
        self.assertEqual(len(self._reviews()), 2)

    def test_an_order_review_sits_beside_the_customers_own_shop_review(self):
        # The same person may rate the shop AND rate their delivery; one must
        # not overwrite the other.
        self.db.add(
            ShopRating(
                shop_id=SHOP_ID,
                user_id=USER_ID,
                rating=3,
                comment="Typed on the shop page",
                source="shop",
            )
        )
        self.db.commit()

        self._save(rating=5)
        reviews = self._reviews()
        self.assertEqual(len(reviews), 2)
        self.assertEqual({r.source for r in reviews}, {"shop", "order"})

    def test_feedback_for_an_unknown_shop_is_dropped(self):
        row = feedback_reviews.review_from_event(
            _envelope(shop_id="99999999-9999-9999-9999-999999999999")
        )
        self.assertIsNone(feedback_reviews.save_order_review(self.db, row))
        self.assertEqual(self._reviews(), [])

    def test_the_handler_swallows_a_broken_event(self):
        # A failure here must not kill the subscriber, or every later event
        # is lost with it.
        asyncio.run(feedback_reviews.handle_event({"event": "nonsense"}, self.Session))
        asyncio.run(feedback_reviews.handle_event(_envelope(rating=99), self.Session))
        self.assertEqual(self._reviews(), [])

    def test_the_handler_stores_a_good_event(self):
        asyncio.run(feedback_reviews.handle_event(_envelope(), self.Session))
        self.assertEqual(len(self._reviews()), 1)


def _timeliness_envelope(**overrides) -> dict:
    data = {
        "shop_id": SHOP_ID,
        "delay_prone": True,
        "median_pickup_wait_min": 22.5,
        "late_ratio": 0.5,
        "order_count": 9,
        "window_days": 30,
    }
    data.update(overrides)
    return {"event": "shop.timeliness", "source": "delivery-service", "data": data}


class TimelinessFromEventTests(unittest.TestCase):
    """Item 4: what the listener will store, with no database involved."""

    def test_a_normal_verdict_is_accepted(self):
        row = feedback_reviews.timeliness_from_event(_timeliness_envelope())
        self.assertEqual(row["shop_id"], SHOP_ID)
        self.assertTrue(row["delay_prone"])
        self.assertEqual(row["median_pickup_wait_min"], 22.5)

    def test_a_prompt_verdict_is_accepted_too(self):
        row = feedback_reviews.timeliness_from_event(
            _timeliness_envelope(delay_prone=False, median_pickup_wait_min=3)
        )
        self.assertFalse(row["delay_prone"])
        self.assertEqual(row["median_pickup_wait_min"], 3.0)

    def test_a_missing_wait_is_allowed(self):
        row = feedback_reviews.timeliness_from_event(
            _timeliness_envelope(median_pickup_wait_min=None)
        )
        self.assertIsNone(row["median_pickup_wait_min"])

    def test_a_nonsense_wait_is_dropped_rather_than_stored(self):
        for wait in ("slow", -5, True):
            row = feedback_reviews.timeliness_from_event(
                _timeliness_envelope(median_pickup_wait_min=wait)
            )
            self.assertIsNone(row["median_pickup_wait_min"], wait)

    def test_a_verdict_without_a_shop_is_ignored(self):
        self.assertIsNone(
            feedback_reviews.timeliness_from_event(_timeliness_envelope(shop_id=None))
        )

    def test_a_verdict_that_does_not_say_yes_or_no_is_ignored(self):
        for value in (None, "yes", 1):
            self.assertIsNone(
                feedback_reviews.timeliness_from_event(
                    _timeliness_envelope(delay_prone=value)
                ),
                value,
            )

    def test_another_event_type_is_ignored(self):
        envelope = _timeliness_envelope()
        envelope["event"] = "order.cancelled"
        self.assertIsNone(feedback_reviews.timeliness_from_event(envelope))

    def test_feedback_is_not_mistaken_for_a_timeliness_verdict(self):
        self.assertIsNone(feedback_reviews.timeliness_from_event(_envelope()))


class SaveTimelinessTests(SaveOrderReviewTests):
    """Item 4: the verdict lands on the shop."""

    def test_the_marker_is_stored(self):
        row = feedback_reviews.timeliness_from_event(_timeliness_envelope())
        shop = feedback_reviews.save_timeliness(self.db, row)
        self.assertIsNotNone(shop)
        self.db.expire_all()
        stored = self.db.get(Shop, SHOP_ID)
        self.assertTrue(stored.delay_prone)
        self.assertEqual(stored.median_pickup_wait_min, 22.5)
        self.assertIsNotNone(stored.timeliness_updated_at)

    def test_a_later_verdict_clears_the_marker(self):
        feedback_reviews.save_timeliness(
            self.db, feedback_reviews.timeliness_from_event(_timeliness_envelope())
        )
        feedback_reviews.save_timeliness(
            self.db,
            feedback_reviews.timeliness_from_event(
                _timeliness_envelope(delay_prone=False, median_pickup_wait_min=4)
            ),
        )
        self.db.expire_all()
        stored = self.db.get(Shop, SHOP_ID)
        self.assertFalse(stored.delay_prone)
        self.assertEqual(stored.median_pickup_wait_min, 4.0)

    def test_a_verdict_for_an_unknown_shop_is_dropped(self):
        row = feedback_reviews.timeliness_from_event(
            _timeliness_envelope(shop_id="99999999-9999-9999-9999-999999999999")
        )
        self.assertIsNone(feedback_reviews.save_timeliness(self.db, row))

    def test_the_handler_routes_a_timeliness_event(self):
        asyncio.run(
            feedback_reviews.handle_event(_timeliness_envelope(), self.Session)
        )
        self.db.expire_all()
        self.assertTrue(self.db.get(Shop, SHOP_ID).delay_prone)
        # ... and did not write a review while doing it.
        self.assertEqual(self._reviews(), [])


if __name__ == "__main__":
    unittest.main()
