"""Item 4: which shops get the "often delayed" marker.

    cd services/delivery-service
    JWT_SECRET=<32+ chars> python -m pytest tests/test_timeliness.py -q
"""

import unittest
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace

from app import timeliness
from app.config import settings

NOW = datetime(2026, 10, 19, 12, 0, tzinfo=timezone.utc)


def _order(*, wait_minutes=5.0, late=False, finished=True):
    """An order with the timestamps the calculation reads."""
    accepted = NOW - timedelta(hours=2)
    picked_up = accepted + timedelta(minutes=wait_minutes) if finished else None
    promised = accepted + timedelta(minutes=45)
    delivered = promised + timedelta(minutes=10 if late else -5) if finished else None
    return SimpleNamespace(
        accepted_at=accepted,
        picked_up_at=picked_up,
        delivered_at=delivered,
        promised_by=promised,
    )


class MedianTests(unittest.TestCase):
    def test_an_odd_count_takes_the_middle(self):
        self.assertEqual(timeliness.median([5, 1, 9]), 5)

    def test_an_even_count_averages_the_two_middle_values(self):
        self.assertEqual(timeliness.median([10, 20, 30, 40]), 25)

    def test_nothing_has_no_median(self):
        self.assertIsNone(timeliness.median([]))

    def test_one_value_is_its_own_median(self):
        self.assertEqual(timeliness.median([7.5]), 7.5)


class PickupWaitTests(unittest.TestCase):
    def test_the_wait_is_accept_to_pickup(self):
        accepted = NOW
        self.assertEqual(
            timeliness.pickup_wait_minutes(accepted, accepted + timedelta(minutes=12)),
            12.0,
        )

    def test_an_order_not_yet_collected_has_no_wait(self):
        self.assertIsNone(timeliness.pickup_wait_minutes(NOW, None))
        self.assertIsNone(timeliness.pickup_wait_minutes(None, NOW))

    def test_a_backwards_clock_is_not_counted_as_a_fast_shop(self):
        self.assertIsNone(
            timeliness.pickup_wait_minutes(NOW, NOW - timedelta(minutes=5))
        )

    def test_naive_timestamps_are_treated_as_utc(self):
        # SQLite hands these back without a timezone; comparing the two
        # would otherwise raise.
        naive = datetime(2026, 10, 19, 12, 0)
        self.assertEqual(
            timeliness.pickup_wait_minutes(naive, naive + timedelta(minutes=8)), 8.0
        )


class WasLateTests(unittest.TestCase):
    def test_after_the_promise_is_late(self):
        self.assertTrue(timeliness.was_late(NOW + timedelta(minutes=1), NOW))

    def test_on_time_is_not_late(self):
        self.assertFalse(timeliness.was_late(NOW - timedelta(minutes=1), NOW))

    def test_an_order_with_no_promise_is_not_judged(self):
        self.assertIsNone(timeliness.was_late(NOW, None))
        self.assertIsNone(timeliness.was_late(None, NOW))


class ShopTimelinessTests(unittest.TestCase):
    def _verdict(self, orders, **kwargs):
        return timeliness.shop_timeliness("shop-1", orders, **kwargs)

    def test_a_prompt_shop_is_not_marked(self):
        orders = [_order(wait_minutes=4) for _ in range(6)]
        verdict = self._verdict(orders)
        self.assertFalse(verdict.delay_prone)
        self.assertEqual(verdict.median_pickup_wait_min, 4.0)
        self.assertEqual(verdict.late_ratio, 0.0)

    def test_a_slow_median_pickup_marks_the_shop(self):
        orders = [_order(wait_minutes=20) for _ in range(6)]
        verdict = self._verdict(orders)
        self.assertTrue(verdict.delay_prone)
        self.assertEqual(verdict.median_pickup_wait_min, 20.0)

    def test_exactly_the_threshold_wait_is_not_slow_enough(self):
        # The rule is "over 15 minutes", so 15 itself does not qualify.
        orders = [_order(wait_minutes=settings.slow_pickup_minutes) for _ in range(6)]
        self.assertFalse(self._verdict(orders).delay_prone)

    def test_enough_late_orders_mark_the_shop_even_when_pickups_are_quick(self):
        # 40% late out of 10, with a 4-minute median handover.
        orders = [_order(wait_minutes=4, late=True) for _ in range(4)]
        orders += [_order(wait_minutes=4) for _ in range(6)]
        verdict = self._verdict(orders)
        self.assertTrue(verdict.delay_prone)
        self.assertEqual(verdict.late_ratio, 0.4)

    def test_just_under_the_late_share_does_not_mark_the_shop(self):
        orders = [_order(wait_minutes=4, late=True) for _ in range(3)]
        orders += [_order(wait_minutes=4) for _ in range(7)]
        verdict = self._verdict(orders)
        self.assertFalse(verdict.delay_prone)
        self.assertEqual(verdict.late_ratio, 0.3)

    def test_too_few_orders_is_never_a_pattern(self):
        # Four slow orders: bad luck, not evidence.
        orders = [_order(wait_minutes=40, late=True) for _ in range(4)]
        verdict = self._verdict(orders)
        self.assertFalse(verdict.delay_prone)
        self.assertEqual(verdict.order_count, 4)
        # The figures are still reported, so the owner can see them.
        self.assertEqual(verdict.median_pickup_wait_min, 40.0)

    def test_exactly_the_minimum_order_count_is_judged(self):
        orders = [_order(wait_minutes=40) for _ in range(settings.min_orders_for_timeliness)]
        self.assertTrue(self._verdict(orders).delay_prone)

    def test_orders_still_in_progress_do_not_count_as_instant(self):
        orders = [_order(wait_minutes=30) for _ in range(5)]
        orders += [_order(finished=False) for _ in range(5)]
        verdict = self._verdict(orders)
        # The five unfinished ones contribute no wait, so the median is the
        # 30 minutes actually measured -- not pulled down towards zero.
        self.assertEqual(verdict.median_pickup_wait_min, 30.0)
        self.assertTrue(verdict.delay_prone)

    def test_a_shop_with_no_measurable_orders_is_not_marked(self):
        orders = [_order(finished=False) for _ in range(8)]
        verdict = self._verdict(orders)
        self.assertIsNone(verdict.median_pickup_wait_min)
        self.assertFalse(verdict.delay_prone)

    def test_the_thresholds_can_be_changed(self):
        orders = [_order(wait_minutes=10) for _ in range(6)]
        self.assertFalse(self._verdict(orders).delay_prone)
        # A stricter product decision marks the same shop.
        self.assertTrue(self._verdict(orders, slow_pickup_minutes=5).delay_prone)

    def test_a_higher_minimum_spares_a_small_shop(self):
        orders = [_order(wait_minutes=40) for _ in range(6)]
        self.assertTrue(self._verdict(orders).delay_prone)
        self.assertFalse(self._verdict(orders, min_orders=10).delay_prone)


if __name__ == "__main__":
    unittest.main()
