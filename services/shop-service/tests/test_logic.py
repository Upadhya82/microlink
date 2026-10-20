"""Tests for the pure business rules. Standard library only - no database,
Redis or FastAPI needed:

    cd services/shop-service
    python -m unittest discover -s tests -v
"""

import os
import sys
import unittest
from datetime import date, datetime, timedelta, timezone
from types import SimpleNamespace

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from app import geo, logic  # noqa: E402

UTC = timezone.utc
NOW = datetime(2026, 10, 6, 12, 0, tzinfo=UTC)


class StockStatusTests(unittest.TestCase):
    def test_quantity_rules(self):
        self.assertEqual(logic.derive_stock_status(0), "out_of_stock")
        self.assertEqual(logic.derive_stock_status(1), "low_stock")
        self.assertEqual(logic.derive_stock_status(5), "low_stock")
        self.assertEqual(logic.derive_stock_status(6), "in_stock")
        self.assertEqual(logic.derive_stock_status(None), "in_stock")

    def test_threshold_is_configurable(self):
        self.assertEqual(logic.derive_stock_status(8, threshold=10), "low_stock")

    def test_create_without_quantity_is_in_stock(self):
        # the project's smoke test creates a product with no quantity
        got = logic.resolve_stock_status(quantity=None, explicit_status=None, is_available=None)
        self.assertEqual(got, "in_stock")

    def test_explicit_status_wins(self):
        got = logic.resolve_stock_status(quantity=100, explicit_status="low_stock", is_available=True)
        self.assertEqual(got, "low_stock")

    def test_quantity_zero_means_out_of_stock(self):
        # SRS: "owner reduces quantity to zero -> Out of Stock"
        got = logic.resolve_stock_status(quantity=0, explicit_status=None, is_available=True)
        self.assertEqual(got, "out_of_stock")

    def test_owner_dashboard_toggle_off(self):
        # the dashboard sends {"is_available": false}
        got = logic.resolve_stock_status(
            quantity=None, explicit_status=None, is_available=False, current_status="in_stock"
        )
        self.assertEqual(got, "out_of_stock")

    def test_toggle_on_restores_from_stored_quantity(self):
        got = logic.resolve_stock_status(
            quantity=None, explicit_status=None, is_available=True,
            current_status="out_of_stock", stored_quantity=3,
        )
        self.assertEqual(got, "low_stock")
        got = logic.resolve_stock_status(
            quantity=None, explicit_status=None, is_available=True,
            current_status="out_of_stock", stored_quantity=0,
        )
        self.assertEqual(got, "in_stock")

    def test_nothing_changed_keeps_status(self):
        got = logic.resolve_stock_status(
            quantity=None, explicit_status=None, is_available=None, current_status="low_stock"
        )
        self.assertEqual(got, "low_stock")

    def test_unknown_status_rejected(self):
        with self.assertRaises(ValueError):
            logic.resolve_stock_status(quantity=1, explicit_status="plenty", is_available=None)

    def test_old_flag_follows_status(self):
        self.assertFalse(logic.is_available_from_stock("out_of_stock"))
        self.assertTrue(logic.is_available_from_stock("low_stock"))
        self.assertTrue(logic.is_available_from_stock("in_stock"))

    def test_availability_levels(self):
        self.assertEqual(logic.availability_level(0, 0, 0), "none")
        self.assertEqual(logic.availability_level(4, 0, 0), "all_in_stock")
        self.assertEqual(logic.availability_level(3, 1, 0), "limited")
        self.assertEqual(logic.availability_level(3, 0, 1), "limited")
        self.assertEqual(logic.availability_level(0, 0, 4), "all_out")
        self.assertEqual(logic.availability_level(0, 2, 2), "limited")


class ShopStatusTests(unittest.TestCase):
    def test_old_flag_maps_to_status(self):
        self.assertEqual(logic.status_from_is_open(True), "open")
        self.assertEqual(logic.status_from_is_open(False), "closed")

    def test_only_open_counts_as_open_now(self):
        self.assertTrue(logic.is_open_from_status("open"))
        self.assertFalse(logic.is_open_from_status("closed"))
        self.assertFalse(logic.is_open_from_status("temporarily_closed"))
        self.assertFalse(logic.is_open_from_status(None))


class AlertTests(unittest.TestCase):
    def test_alert_windows(self):
        past, future = NOW - timedelta(days=1), NOW + timedelta(days=1)
        self.assertTrue(logic.alert_is_active(True, None, None, NOW))
        self.assertFalse(logic.alert_is_active(False, None, None, NOW))
        self.assertFalse(logic.alert_is_active(True, future, None, NOW))  # not started yet
        self.assertFalse(logic.alert_is_active(True, None, past, NOW))  # already ended
        self.assertTrue(logic.alert_is_active(True, past, future, NOW))

    def test_naive_datetimes_do_not_crash(self):
        naive_past = datetime(2026, 10, 1, 0, 0)
        self.assertTrue(logic.alert_is_active(True, naive_past, None, NOW))


class TrustScoreTests(unittest.TestCase):
    def test_average_of_recent_ratings_only(self):
        ratings = [
            (5, NOW - timedelta(days=1)),
            (3, NOW - timedelta(days=89)),
            (1, NOW - timedelta(days=91)),  # too old - ignored
        ]
        self.assertEqual(logic.rating_summary(ratings, NOW), (4.0, 2))

    def test_no_recent_ratings(self):
        self.assertEqual(logic.rating_summary([(5, NOW - timedelta(days=200))], NOW), (0.0, 0))
        self.assertEqual(logic.rating_summary([], NOW), (0.0, 0))

    def test_rounding(self):
        ratings = [(5, NOW), (4, NOW), (4, NOW)]
        self.assertEqual(logic.rating_summary(ratings, NOW), (4.33, 3))


class AnalyticsTests(unittest.TestCase):
    def test_seven_days_zero_filled_oldest_first(self):
        views = [NOW, NOW - timedelta(hours=1), NOW - timedelta(days=2)]
        result = logic.fill_last_days(views, today=date(2026, 10, 6), days=7)
        self.assertEqual(len(result), 7)
        self.assertEqual(result[0]["date"], "2026-09-30")
        self.assertEqual(result[-1], {"date": "2026-10-06", "views": 2})
        self.assertEqual(result[-3], {"date": "2026-10-04", "views": 1})
        self.assertEqual(sum(day["views"] for day in result), 3)

    def test_local_time_moves_a_view_to_the_next_day(self):
        late = datetime(2026, 10, 6, 20, 0, tzinfo=UTC)  # 01:30 next day in Sri Lanka (UTC+5:30)
        result = logic.fill_last_days([late], today=date(2026, 10, 7), days=2, offset_minutes=330)
        self.assertEqual(result[-1], {"date": "2026-10-07", "views": 1})

    def test_peak_hours(self):
        views = [datetime(2026, 10, 6, 9, m, tzinfo=UTC) for m in (1, 5, 9)]
        views += [datetime(2026, 10, 6, 17, 30, tzinfo=UTC)]
        views += [datetime(2026, 10, 6, 17, 10, tzinfo=UTC)]
        result = logic.peak_hours(views, offset_minutes=0, top=3)
        self.assertEqual(result[0], {"hour": 9, "label": "09:00-10:00", "views": 3})
        self.assertEqual(result[1]["hour"], 17)
        self.assertEqual(len(result), 2)  # empty hours are not listed

    def test_peak_hours_empty(self):
        self.assertEqual(logic.peak_hours([]), [])


class SearchTests(unittest.TestCase):
    def test_escape_like(self):
        self.assertEqual(logic.escape_like("50%_off"), "50\\%\\_off")
        self.assertEqual(logic.escape_like("a\\b"), "a\\\\b")

    def test_matching_categories(self):
        cats = ["grocery", "bakery", "pharmacy", "other"]
        self.assertEqual(logic.matching_categories("bakery", cats), ["bakery"])
        self.assertEqual(logic.matching_categories("bak", cats), ["bakery"])
        self.assertEqual(logic.matching_categories("grocery store", cats), ["grocery"])
        self.assertEqual(logic.matching_categories("b", cats), [])
        self.assertEqual(logic.matching_categories("pizza", cats), [])

    def _row(self, name, distance, rating, days_old):
        return SimpleNamespace(
            name=name, distance_km=distance, rating_avg=rating, created_at=NOW - timedelta(days=days_old)
        )

    def test_smart_sort_with_location_is_distance_then_rating(self):
        rows = [self._row("far", 3.0, 5, 1), self._row("near-low", 0.5, 2, 1), self._row("near-high", 0.5, 4, 1)]
        names = [r.name for r in logic.sort_shops(rows, "smart", has_location=True)]
        self.assertEqual(names, ["near-high", "near-low", "far"])

    def test_smart_sort_without_location_is_rating_then_newest(self):
        rows = [self._row("old-good", None, 4, 30), self._row("new-good", None, 4, 1), self._row("best", None, 5, 90)]
        names = [r.name for r in logic.sort_shops(rows, "smart", has_location=False)]
        self.assertEqual(names, ["best", "new-good", "old-good"])

    def test_rating_sort(self):
        rows = [self._row("a", 1.0, 3, 1), self._row("b", 2.0, 5, 1), self._row("c", 0.5, 5, 1)]
        names = [r.name for r in logic.sort_shops(rows, "rating", has_location=True)]
        self.assertEqual(names, ["c", "b", "a"])

    def test_newest_sort(self):
        rows = [self._row("a", 1.0, 3, 10), self._row("b", 2.0, 5, 1)]
        self.assertEqual([r.name for r in logic.sort_shops(rows, "newest", True)], ["b", "a"])


class LandmarkTests(unittest.TestCase):
    def test_exact_and_messy_input(self):
        place = logic.lookup_landmark("  Central   Bus-Stand! ")
        self.assertEqual(place["name"], "Central Bus Stand, Pettah")
        self.assertEqual(place["source"], "builtin")

    def test_partial_match(self):
        self.assertEqual(logic.lookup_landmark("Homagama bus halt")["name"], "Homagama")

    def test_short_or_unknown_text_does_not_match(self):
        self.assertIsNone(logic.lookup_landmark("bus"))
        self.assertIsNone(logic.lookup_landmark("Atlantis"))
        self.assertIsNone(logic.lookup_landmark("   "))

    def test_builtin_points_are_inside_sri_lanka(self):
        for name, lat, lng in logic.LANDMARKS.values():
            self.assertTrue(5.5 < lat < 10.0 and 79.0 < lng < 82.0, name)


class GeoTests(unittest.TestCase):
    def test_haversine_known_distances(self):
        self.assertAlmostEqual(geo.haversine_km(6.9, 79.8, 6.9, 79.8), 0.0, places=6)
        # Colombo Fort -> Kandy is roughly 94 km in a straight line
        self.assertTrue(90 < geo.haversine_km(6.9334, 79.8503, 7.2906, 80.6337) < 100)
        # one degree of latitude is about 111 km
        self.assertAlmostEqual(geo.haversine_km(0, 0, 1, 0), 111.19, delta=0.2)

    def test_bounding_box_contains_the_circle(self):
        lat, lng, radius = 6.84, 80.01, 5.0
        box = geo.bounding_box(lat, lng, radius)
        self.assertIsNotNone(box)
        # points exactly `radius` km away north / east must be inside the box
        north = (lat + radius / 111.19, lng)
        east = (lat, lng + radius / (111.19 * 0.9929))
        for point_lat, point_lng in (north, east):
            self.assertTrue(box.min_lat <= point_lat <= box.max_lat)
            self.assertTrue(box.min_lng <= point_lng <= box.max_lng)

    def test_bounding_box_skipped_where_unsafe(self):
        self.assertIsNone(geo.bounding_box(89, 0, 5))  # near the pole
        self.assertIsNone(geo.bounding_box(0, 179.99, 50))  # crosses the date line


class LandmarkSuggestionTests(unittest.TestCase):
    """Item 1: the names the app offers when the box is empty."""

    def test_there_are_suggestions_to_offer(self):
        suggestions = logic.landmark_suggestions()
        self.assertTrue(suggestions)

    def test_every_suggestion_resolves_through_the_normal_lookup(self):
        # A suggestion that cannot be looked up would be a dead end.
        for item in logic.landmark_suggestions():
            self.assertIsNotNone(
                logic.lookup_landmark(item["name"]), item["name"]
            )

    def test_aliases_for_the_same_place_are_collapsed(self):
        names = [item["name"] for item in logic.landmark_suggestions(limit=100)]
        self.assertEqual(len(names), len(set(names)))
        points = [
            (item["latitude"], item["longitude"])
            for item in logic.landmark_suggestions(limit=100)
        ]
        self.assertEqual(len(points), len(set(points)))

    def test_they_are_in_alphabetical_order(self):
        names = [item["name"] for item in logic.landmark_suggestions(limit=100)]
        self.assertEqual(names, sorted(names))

    def test_the_limit_is_respected(self):
        self.assertEqual(len(logic.landmark_suggestions(limit=3)), 3)
        self.assertEqual(logic.landmark_suggestions(limit=0), [])

    def test_each_one_says_it_came_from_the_built_in_list(self):
        for item in logic.landmark_suggestions():
            self.assertEqual(item["source"], "builtin")


if __name__ == "__main__":
    unittest.main()


class ReverseGeocodeFormattingTests(unittest.TestCase):
    def test_picks_the_three_most_specific_address_parts(self):
        result = logic.format_reverse_geocode(
            {
                "lat": "6.8412",
                "lon": "79.8731",
                "address": {
                    "house_number": "12",
                    "road": "Galle Road",
                    "suburb": "Dehiwala",
                    "city": "Colombo",
                    "country": "Sri Lanka",
                },
            }
        )
        self.assertEqual(result["address"], "12, Galle Road, Dehiwala")
        self.assertEqual(result["name"], "12")
        self.assertAlmostEqual(result["latitude"], 6.8412)
        self.assertAlmostEqual(result["longitude"], 79.8731)

    def test_falls_back_to_display_name_without_a_structured_address(self):
        result = logic.format_reverse_geocode(
            {"lat": "7.2906", "lon": "80.6337", "display_name": "Kandy, Central Province, Sri Lanka"}
        )
        self.assertEqual(result["address"], "Kandy, Central Province, Sri Lanka")
        self.assertEqual(result["name"], "Kandy")

    def test_duplicate_parts_are_not_repeated(self):
        result = logic.format_reverse_geocode(
            {"lat": "6.0", "lon": "80.0", "address": {"village": "Weligama", "town": "Weligama"}}
        )
        self.assertEqual(result["address"], "Weligama")

    def test_missing_or_invalid_coordinates_give_none(self):
        self.assertIsNone(logic.format_reverse_geocode({"address": {"road": "Galle Road"}}))
        self.assertIsNone(logic.format_reverse_geocode({"lat": "abc", "lon": "80.0"}))
        self.assertIsNone(logic.format_reverse_geocode(None))

    def test_point_with_no_address_at_all_gives_none(self):
        self.assertIsNone(logic.format_reverse_geocode({"lat": "6.0", "lon": "80.0"}))
