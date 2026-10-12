"""Which closed shops get followed up, and when.

The real rule takes a fortnight to play out, so the clock is passed in and
the decision is tested directly.

Needs the service image's dependencies, so the module skips itself on a bare
local interpreter:

    docker compose exec shop-service python -m unittest tests.test_dormant
"""

import unittest
from datetime import datetime, timedelta, timezone

try:
    from app.dormant import (
        CLOSED_DAYS_BEFORE_PROMPT,
        DAYS_BEFORE_BROADCAST,
        mark_closed,
        mark_open,
        needs_follower_broadcast,
        needs_owner_prompt,
    )

    HAVE_DEPS = True
except ImportError:  # pragma: no cover - depends on where the suite runs
    # app.dormant pulls in httpx and SQLAlchemy, which only the service
    # image has. The rules themselves are plain date arithmetic.
    HAVE_DEPS = False
    CLOSED_DAYS_BEFORE_PROMPT = DAYS_BEFORE_BROADCAST = 0

NOW = datetime(2026, 10, 11, 12, 0, tzinfo=timezone.utc)


class FakeShop:
    def __init__(self, is_open=False, closed_days=None, prompted_days=None,
                 broadcast=False, tz=True):
        self.id = "shop-1"
        self.name = "Kamal Stores"
        self.owner_id = "owner-1"
        self.is_open = is_open
        self.closed_since = self._ago(closed_days, tz)
        self.inactivity_prompt_at = self._ago(prompted_days, tz)
        self.inactivity_broadcast_at = NOW if broadcast else None

    @staticmethod
    def _ago(days, tz):
        if days is None:
            return None
        value = NOW - timedelta(days=days)
        return value if tz else value.replace(tzinfo=None)


@unittest.skipUnless(HAVE_DEPS, "needs the service image dependencies")
class OwnerPrompt(unittest.TestCase):
    def test_a_shop_closed_for_a_fortnight_is_flagged(self):
        shop = FakeShop(closed_days=CLOSED_DAYS_BEFORE_PROMPT)
        self.assertEqual(needs_owner_prompt([shop], NOW), [shop])

    def test_a_shop_closed_for_less_than_that_is_left_alone(self):
        shop = FakeShop(closed_days=CLOSED_DAYS_BEFORE_PROMPT - 1)
        self.assertEqual(needs_owner_prompt([shop], NOW), [])

    def test_an_open_shop_is_never_flagged(self):
        shop = FakeShop(is_open=True, closed_days=90)
        self.assertEqual(needs_owner_prompt([shop], NOW), [])

    def test_the_owner_is_not_asked_twice(self):
        shop = FakeShop(closed_days=40, prompted_days=20)
        self.assertEqual(needs_owner_prompt([shop], NOW), [])

    def test_a_shop_with_no_closing_date_is_skipped(self):
        # An older row written before this feature existed.
        shop = FakeShop(closed_days=None)
        self.assertEqual(needs_owner_prompt([shop], NOW), [])

    def test_a_naive_timestamp_is_treated_as_utc(self):
        shop = FakeShop(closed_days=CLOSED_DAYS_BEFORE_PROMPT + 1, tz=False)
        self.assertEqual(needs_owner_prompt([shop], NOW), [shop])


@unittest.skipUnless(HAVE_DEPS, "needs the service image dependencies")
class FollowerBroadcast(unittest.TestCase):
    def test_followers_are_told_once_the_owner_has_had_their_chance(self):
        shop = FakeShop(closed_days=30, prompted_days=DAYS_BEFORE_BROADCAST)
        self.assertEqual(needs_follower_broadcast([shop], NOW), [shop])

    def test_followers_are_not_told_before_that(self):
        shop = FakeShop(closed_days=30, prompted_days=DAYS_BEFORE_BROADCAST - 1)
        self.assertEqual(needs_follower_broadcast([shop], NOW), [])

    def test_followers_are_not_told_if_the_owner_was_never_asked(self):
        shop = FakeShop(closed_days=30)
        self.assertEqual(needs_follower_broadcast([shop], NOW), [])

    def test_followers_are_told_only_once(self):
        shop = FakeShop(closed_days=60, prompted_days=30, broadcast=True)
        self.assertEqual(needs_follower_broadcast([shop], NOW), [])

    def test_a_reopened_shop_is_dropped_from_the_broadcast(self):
        shop = FakeShop(is_open=True, closed_days=60, prompted_days=30)
        self.assertEqual(needs_follower_broadcast([shop], NOW), [])


@unittest.skipUnless(HAVE_DEPS, "needs the service image dependencies")
class ClockHandling(unittest.TestCase):
    def test_closing_starts_the_clock(self):
        shop = FakeShop(is_open=True)
        shop.closed_since = None
        mark_closed(shop, NOW)
        self.assertEqual(shop.closed_since, NOW)

    def test_closing_an_already_closed_shop_does_not_restart_the_clock(self):
        # Otherwise every status edit would push the fortnight back and the
        # follow-up would never fire.
        shop = FakeShop(closed_days=10)
        original = shop.closed_since
        mark_closed(shop, NOW)
        self.assertEqual(shop.closed_since, original)

    def test_reopening_clears_the_whole_sequence(self):
        shop = FakeShop(closed_days=40, prompted_days=20, broadcast=True)
        mark_open(shop)
        self.assertIsNone(shop.closed_since)
        self.assertIsNone(shop.inactivity_prompt_at)
        self.assertIsNone(shop.inactivity_broadcast_at)


if __name__ == "__main__":
    unittest.main()
