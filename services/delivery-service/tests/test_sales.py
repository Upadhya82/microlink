"""The shop owner's sales over a chosen period (app/sales.py).

    cd services/delivery-service
    python -m pytest tests/test_sales.py -q
"""

import json
import unittest
from dataclasses import dataclass
from datetime import date, datetime, timezone

from app.sales import (
    items_sold,
    local_window_utc,
    order_value,
    period_keys,
    summarize,
)


@dataclass
class FakeOrder:
    status: str
    items: str
    total_amount: float
    created_at: datetime
    delivered_at: datetime | None = None


def _items(*lines):
    return json.dumps(
        [
            {"product_id": pid, "name": name, "quantity": qty, "price": price}
            for pid, name, qty, price in lines
        ]
    )


def _at(year, month, day, hour=6):
    return datetime(year, month, day, hour, tzinfo=timezone.utc)


class OrderValueTests(unittest.TestCase):
    def test_value_is_price_times_quantity(self):
        self.assertEqual(order_value(_items(("p1", "Rice", 2, 250.0), ("p2", "Milk", 1, 120.0)), 0), 620.0)

    def test_an_order_without_priced_lines_uses_the_total(self):
        self.assertEqual(order_value("[]", 350.0), 350.0)
        self.assertEqual(order_value(json.dumps([{"name": "Parcel"}]), 90.0), 90.0)

    def test_items_sold_adds_quantities(self):
        self.assertEqual(items_sold(_items(("p1", "Rice", 2, 250.0), ("p2", "Milk", 3, 120.0))), 5)


class PeriodTests(unittest.TestCase):
    def test_months_across_a_new_year(self):
        self.assertEqual(
            period_keys(date(2025, 11, 5), date(2026, 2, 1), "month"),
            ["2025-11", "2025-12", "2026-01", "2026-02"],
        )

    def test_years(self):
        self.assertEqual(period_keys(date(2024, 3, 1), date(2026, 1, 1), "year"), ["2024", "2025", "2026"])

    def test_the_window_is_in_sri_lanka_time(self):
        begin, after = local_window_utc(date(2026, 1, 1), date(2026, 1, 1))
        self.assertEqual(begin, datetime(2025, 12, 31, 18, 30, tzinfo=timezone.utc))
        self.assertEqual(after, datetime(2026, 1, 1, 18, 30, tzinfo=timezone.utc))


class SummarizeTests(unittest.TestCase):
    def setUp(self):
        self.orders = [
            FakeOrder("delivered", _items(("p1", "Rice", 2, 250.0)), 500.0, _at(2026, 1, 10), _at(2026, 1, 10, 9)),
            FakeOrder("delivered", _items(("p1", "Rice", 1, 250.0), ("p2", "Milk", 2, 120.0)), 490.0, _at(2026, 3, 2), _at(2026, 3, 2, 8)),
            FakeOrder("cancelled", _items(("p2", "Milk", 5, 120.0)), 600.0, _at(2026, 3, 3)),
            FakeOrder("pending", _items(("p2", "Milk", 1, 120.0)), 120.0, _at(2026, 3, 4)),
            # Outside the period: not counted anywhere.
            FakeOrder("delivered", _items(("p1", "Rice", 9, 250.0)), 2250.0, _at(2025, 6, 1), _at(2025, 6, 1)),
        ]

    def test_totals_count_only_delivered_orders_as_sales(self):
        result = summarize(self.orders, date(2026, 1, 1), date(2026, 12, 31), "month")
        totals = result["totals"]
        self.assertEqual(totals["sales"], 990.0)
        self.assertEqual(totals["delivered_orders"], 2)
        self.assertEqual(totals["items_sold"], 5)
        self.assertEqual(totals["orders_placed"], 4)
        self.assertEqual(totals["cancelled_orders"], 1)

    def test_every_month_has_a_bucket_even_with_no_sales(self):
        buckets = summarize(self.orders, date(2026, 1, 1), date(2026, 12, 31), "month")["buckets"]
        self.assertEqual(len(buckets), 12)
        by_period = {b["period"]: b for b in buckets}
        self.assertEqual(by_period["2026-01"]["sales"], 500.0)
        self.assertEqual(by_period["2026-02"]["sales"], 0.0)
        self.assertEqual(by_period["2026-03"]["sales"], 490.0)
        self.assertEqual(by_period["2026-03"]["orders_placed"], 3)

    def test_best_sellers_are_ranked_by_quantity(self):
        top = summarize(self.orders, date(2026, 1, 1), date(2026, 12, 31), "year")["top_products"]
        self.assertEqual([p["name"] for p in top], ["Rice", "Milk"])
        self.assertEqual(top[0]["quantity"], 3)
        self.assertEqual(top[0]["sales"], 750.0)

    def test_a_sale_is_counted_on_its_local_delivery_day(self):
        # Delivered 31 Dec 20:00 UTC = 1 Jan 01:30 in Sri Lanka.
        order = FakeOrder(
            "delivered", _items(("p1", "Rice", 1, 100.0)), 100.0,
            _at(2025, 12, 31, 19), datetime(2025, 12, 31, 20, tzinfo=timezone.utc),
        )
        result = summarize([order], date(2026, 1, 1), date(2026, 1, 31), "day")
        self.assertEqual(result["totals"]["sales"], 100.0)
        self.assertEqual(result["buckets"][0]["period"], "2026-01-01")
        self.assertEqual(result["buckets"][0]["sales"], 100.0)

    def test_an_empty_period_is_all_zeros(self):
        result = summarize([], date(2026, 5, 1), date(2026, 5, 3), "day")
        self.assertEqual([b["sales"] for b in result["buckets"]], [0.0, 0.0, 0.0])
        self.assertEqual(result["top_products"], [])


if __name__ == "__main__":
    unittest.main()
