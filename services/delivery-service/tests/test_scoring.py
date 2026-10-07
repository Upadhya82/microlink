"""Unit tests for the pure delivery rules in app/scoring.py.

Run from services/delivery-service:   python -m unittest discover -s tests -v
(No database, Redis or web server is needed.)
"""

import unittest

from app.scoring import (
    estimate_minutes,
    is_within_geofence,
    on_time_percentage,
    performance_score,
    promised_minutes,
)

# Two real places about 1.1 km apart (Colombo).
SHOP = (6.9271, 79.8612)
NEAR_SHOP = (6.9272, 79.8613)  # ~15 m away
FAR_AWAY = (6.9371, 79.8612)  # ~1.1 km away


class EstimateMinutesTests(unittest.TestCase):
    def test_ten_km_at_twenty_five_kmh_is_twenty_four_minutes(self):
        self.assertEqual(estimate_minutes(10, 25), 24)

    def test_never_less_than_one_minute(self):
        self.assertEqual(estimate_minutes(0, 25), 1)
        self.assertEqual(estimate_minutes(0.01, 25), 1)

    def test_bad_speed_does_not_crash(self):
        self.assertEqual(estimate_minutes(5, 0), 1)


class PromisedMinutesTests(unittest.TestCase):
    def test_adds_buffer_to_travel_time(self):
        # 5 km + 5 km at 30 km/h = 10 + 10 minutes, plus a 15 minute buffer.
        self.assertEqual(promised_minutes([5, 5], 30, 15, 45), 35)

    def test_uses_default_when_nothing_is_measurable(self):
        self.assertEqual(promised_minutes([], 25, 15, 45), 45)


class OnTimePercentageTests(unittest.TestCase):
    def test_none_before_first_delivery(self):
        self.assertIsNone(on_time_percentage(0, 0))

    def test_three_of_four_is_75(self):
        self.assertEqual(on_time_percentage(3, 4), 75.0)


class PerformanceScoreTests(unittest.TestCase):
    def test_none_before_first_delivery(self):
        self.assertIsNone(performance_score(0.0, 0, 0, 0))

    def test_perfect_agent_scores_five(self):
        self.assertEqual(performance_score(5.0, 10, 10, 10), 5.0)

    def test_always_late_and_one_star_scores_one(self):
        self.assertEqual(performance_score(1.0, 4, 0, 4), 1.0)

    def test_unrated_agent_gets_a_neutral_rating(self):
        # rating part = 3.0 (60%), on-time part = 5.0 (40%) -> 3.8
        self.assertEqual(performance_score(0.0, 0, 2, 2), 3.8)

    def test_score_stays_between_one_and_five(self):
        for rating in (0.0, 1.0, 3.3, 5.0):
            for on_time in (0, 1, 2):
                score = performance_score(rating, 3, on_time, 2)
                self.assertGreaterEqual(score, 1.0)
                self.assertLessEqual(score, 5.0)


class GeofenceTests(unittest.TestCase):
    def test_inside_the_radius(self):
        self.assertTrue(is_within_geofence(*NEAR_SHOP, *SHOP, radius_m=300))

    def test_outside_the_radius(self):
        self.assertFalse(is_within_geofence(*FAR_AWAY, *SHOP, radius_m=300))

    def test_unknown_when_a_coordinate_is_missing(self):
        self.assertIsNone(is_within_geofence(None, None, *SHOP, radius_m=300))
        self.assertIsNone(is_within_geofence(*NEAR_SHOP, None, None, radius_m=300))


if __name__ == "__main__":
    unittest.main()
