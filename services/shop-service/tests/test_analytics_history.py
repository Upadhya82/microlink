"""Owner analytics over a chosen period: the bucketing rules in app/logic.py.

    cd services/shop-service
    JWT_SECRET=<32+ chars> python -m pytest tests/test_analytics_history.py -q
"""

import unittest
from datetime import date, datetime, timezone

from app import logic

SL = 330  # Sri Lanka, UTC+05:30


class PeriodKeyTests(unittest.TestCase):
    def test_each_granularity(self):
        day = date(2026, 3, 7)
        self.assertEqual(logic.period_key(day, "day"), "2026-03-07")
        self.assertEqual(logic.period_key(day, "month"), "2026-03")
        self.assertEqual(logic.period_key(day, "year"), "2026")

    def test_an_unknown_granularity_is_refused(self):
        with self.assertRaises(ValueError):
            logic.period_key(date(2026, 1, 1), "week")


class PeriodKeysTests(unittest.TestCase):
    def test_days_across_a_month_end(self):
        self.assertEqual(
            logic.period_keys(date(2026, 2, 27), date(2026, 3, 2), "day"),
            ["2026-02-27", "2026-02-28", "2026-03-01", "2026-03-02"],
        )

    def test_months_across_a_new_year(self):
        self.assertEqual(
            logic.period_keys(date(2025, 11, 15), date(2026, 2, 1), "month"),
            ["2025-11", "2025-12", "2026-01", "2026-02"],
        )

    def test_years(self):
        self.assertEqual(
            logic.period_keys(date(2024, 6, 1), date(2026, 1, 1), "year"),
            ["2024", "2025", "2026"],
        )

    def test_a_backwards_range_is_empty(self):
        self.assertEqual(logic.period_keys(date(2026, 2, 1), date(2026, 1, 1), "day"), [])


class CountByPeriodTests(unittest.TestCase):
    def test_counts_use_the_local_date(self):
        # 31 Dec 19:00 UTC is already 1 Jan 00:30 in Sri Lanka.
        moments = [
            datetime(2025, 12, 31, 19, 0, tzinfo=timezone.utc),
            datetime(2026, 1, 15, 8, 0, tzinfo=timezone.utc),
            datetime(2025, 12, 10, 8, 0, tzinfo=timezone.utc),
        ]
        counts = logic.count_by_period(moments, date(2025, 12, 1), date(2026, 1, 31), "month", SL)
        self.assertEqual(counts, {"2025-12": 1, "2026-01": 2})

    def test_moments_outside_the_period_are_ignored(self):
        moments = [datetime(2024, 5, 1, tzinfo=timezone.utc)]
        counts = logic.count_by_period(moments, date(2026, 1, 1), date(2026, 12, 31), "year", SL)
        self.assertEqual(counts, {"2026": 0})

    def test_the_window_is_local_midnight_to_midnight(self):
        begin, after = logic.local_window_utc(date(2026, 1, 1), date(2026, 1, 31), SL)
        self.assertEqual(begin, datetime(2025, 12, 31, 18, 30, tzinfo=timezone.utc))
        self.assertEqual(after, datetime(2026, 1, 31, 18, 30, tzinfo=timezone.utc))


if __name__ == "__main__":
    unittest.main()
