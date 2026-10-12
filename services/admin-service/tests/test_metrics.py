import json
import unittest
from datetime import datetime, timedelta, timezone

from app.metrics import (
    active_users,
    count_orders_since,
    delivery_stats,
    is_error_event,
    parse_payload,
    read_cpu_and_memory,
    users_by_role,
)


class Row:
    """Stand-in for an ActivityLog row."""

    def __init__(self, payload, created_at, event_type="x"):
        self.payload = json.dumps(payload) if isinstance(payload, dict) else payload
        self.created_at = created_at
        self.event_type = event_type


NOW = datetime(2026, 10, 10, 12, 0, tzinfo=timezone.utc)


class ParsePayloadTests(unittest.TestCase):
    def test_parses_json_text(self):
        self.assertEqual(parse_payload('{"a": 1}'), {"a": 1})

    def test_passes_through_a_dict(self):
        self.assertEqual(parse_payload({"a": 1}), {"a": 1})

    def test_bad_data_becomes_empty_rather_than_raising(self):
        self.assertEqual(parse_payload("not json"), {})
        self.assertEqual(parse_payload(None), {})
        self.assertEqual(parse_payload("[1,2]"), {})


class ActiveUsersTests(unittest.TestCase):
    def test_counts_distinct_users_in_the_window(self):
        rows = [
            Row({"user_id": "u1"}, NOW - timedelta(minutes=1)),
            Row({"user_id": "u1"}, NOW - timedelta(minutes=2)),
            Row({"user_id": "u2"}, NOW - timedelta(minutes=3)),
        ]
        self.assertEqual(active_users(rows, now=NOW), 2)

    def test_ignores_rows_outside_the_window(self):
        rows = [
            Row({"user_id": "u1"}, NOW - timedelta(minutes=1)),
            Row({"user_id": "old"}, NOW - timedelta(minutes=99)),
        ]
        self.assertEqual(active_users(rows, now=NOW), 1)

    def test_accepts_the_other_actor_key_names(self):
        rows = [
            Row({"customer_id": "c1"}, NOW),
            Row({"agent_id": "a1"}, NOW),
            Row({"owner_id": "o1"}, NOW),
        ]
        self.assertEqual(active_users(rows, now=NOW), 3)

    def test_rows_with_no_user_do_not_count(self):
        self.assertEqual(active_users([Row({"shop_id": "s1"}, NOW)], now=NOW), 0)

    def test_naive_timestamps_are_treated_as_utc(self):
        rows = [Row({"user_id": "u1"}, datetime(2026, 10, 10, 11, 59))]
        self.assertEqual(active_users(rows, now=NOW), 1)


class UsersByRoleTests(unittest.TestCase):
    def test_counts_each_role(self):
        payloads = [
            json.dumps({"role": "user"}),
            json.dumps({"role": "user"}),
            json.dumps({"role": "shop_owner"}),
        ]
        self.assertEqual(users_by_role(payloads), {"user": 2, "shop_owner": 1})

    def test_payloads_without_a_role_are_skipped(self):
        self.assertEqual(users_by_role([json.dumps({"id": "x"}), "junk"]), {})


class DeliveryStatsTests(unittest.TestCase):
    def test_revenue_and_average_duration(self):
        created = [
            ({"order_id": "o1", "total_amount": 500.0}, NOW - timedelta(minutes=30)),
            ({"order_id": "o2", "total_amount": 250.0}, NOW - timedelta(minutes=20)),
        ]
        delivered = [
            ({"order_id": "o1"}, NOW - timedelta(minutes=10)),
            ({"order_id": "o2"}, NOW - timedelta(minutes=10)),
        ]
        stats = delivery_stats(created, delivered)
        self.assertEqual(stats["delivered_count"], 2)
        self.assertEqual(stats["revenue"], 750.0)
        # 20 minutes and 10 minutes.
        self.assertEqual(stats["average_delivery_minutes"], 15.0)

    def test_undelivered_orders_are_not_revenue(self):
        created = [({"order_id": "o1", "total_amount": 500.0}, NOW)]
        stats = delivery_stats(created, [])
        self.assertEqual(stats["revenue"], 0.0)
        self.assertEqual(stats["delivered_count"], 0)

    def test_delivery_without_a_matching_order_is_ignored(self):
        stats = delivery_stats([], [({"order_id": "ghost"}, NOW)])
        self.assertEqual(stats["delivered_count"], 0)

    def test_no_deliveries_gives_no_average(self):
        self.assertIsNone(delivery_stats([], [])["average_delivery_minutes"])

    def test_clock_skew_is_excluded_from_the_average(self):
        # Delivered "before" it was created: replayed events or a bad clock.
        created = [({"order_id": "o1", "total_amount": 100}, NOW)]
        delivered = [({"order_id": "o1"}, NOW - timedelta(minutes=5))]
        stats = delivery_stats(created, delivered)
        self.assertEqual(stats["revenue"], 100.0)
        self.assertIsNone(stats["average_delivery_minutes"])


class CountOrdersTests(unittest.TestCase):
    def test_counts_rows_at_or_after_the_cutoff(self):
        rows = [
            Row({}, NOW - timedelta(hours=1)),
            Row({}, NOW - timedelta(days=2)),
        ]
        self.assertEqual(count_orders_since(rows, NOW - timedelta(days=1)), 1)


class ErrorEventTests(unittest.TestCase):
    def test_recognises_error_shaped_event_names(self):
        for name in ("payment.failed", "user.login_locked", "shop.error", "report.rejected"):
            self.assertTrue(is_error_event(name), name)

    def test_normal_events_are_not_errors(self):
        for name in ("order.created", "shop.verified", ""):
            self.assertFalse(is_error_event(name), name)


class HostMetricsTests(unittest.TestCase):
    def test_returns_the_expected_keys_on_any_platform(self):
        # Must degrade to nulls off Linux rather than raising.
        result = read_cpu_and_memory()
        self.assertIn("load_average_1m", result)
        self.assertIn("cpu_count", result)
        self.assertIn("memory_used_percent", result)


if __name__ == "__main__":
    unittest.main()
