"""A shop's sales over a chosen period, for the owner's "Performance over time".

Plain Python (standard library only) so tests/test_sales.py can check every
rule without a database.

Rules
-----
* A sale is a **delivered** order, counted on the day it was delivered
  (or the day it was placed, for an old order with no delivery time).
* Its value is the sum of its product lines (price x quantity), the prices the
  customer was charged at checkout. An order with no priced lines -- the
  "request a delivery" flow carries none -- falls back to `total_amount`.
* Orders placed and orders cancelled are counted on the day they were placed,
  so the owner can see demand and how much of it was lost.
* Dates are Sri Lanka local dates (UTC+05:30), the same as shop-service.
"""

from __future__ import annotations

import json
from datetime import date, datetime, timedelta, timezone
from typing import Any, Iterable

LOCAL_UTC_OFFSET_MINUTES = 330
GRANULARITIES = ("day", "month", "year")
MAX_DAILY_SPAN_DAYS = 366
TOP_PRODUCTS = 5


def _local_date(moment: datetime, offset_minutes: int = LOCAL_UTC_OFFSET_MINUTES) -> date:
    aware = moment if moment.tzinfo else moment.replace(tzinfo=timezone.utc)
    return aware.astimezone(timezone(timedelta(minutes=offset_minutes))).date()


def local_today(offset_minutes: int = LOCAL_UTC_OFFSET_MINUTES) -> date:
    return _local_date(datetime.now(timezone.utc), offset_minutes)


def local_window_utc(
    start: date, end: date, offset_minutes: int = LOCAL_UTC_OFFSET_MINUTES
) -> tuple[datetime, datetime]:
    """[start of `start`, start of the day after `end`) in local time, as UTC."""
    tz = timezone(timedelta(minutes=offset_minutes))
    begin = datetime(start.year, start.month, start.day, tzinfo=tz)
    after = datetime(end.year, end.month, end.day, tzinfo=tz) + timedelta(days=1)
    return begin.astimezone(timezone.utc), after.astimezone(timezone.utc)


def period_key(day: date, granularity: str) -> str:
    if granularity == "day":
        return day.isoformat()
    if granularity == "month":
        return f"{day.year:04d}-{day.month:02d}"
    if granularity == "year":
        return f"{day.year:04d}"
    raise ValueError(f"Unknown granularity: {granularity}")


def period_keys(start: date, end: date, granularity: str) -> list[str]:
    """Every bucket from `start` to `end` inclusive, oldest first, none skipped."""
    if end < start:
        return []
    if granularity == "day":
        return [(start + timedelta(days=i)).isoformat() for i in range((end - start).days + 1)]
    if granularity == "month":
        keys = []
        year, month = start.year, start.month
        while (year, month) <= (end.year, end.month):
            keys.append(f"{year:04d}-{month:02d}")
            month += 1
            if month == 13:
                year, month = year + 1, 1
        return keys
    if granularity == "year":
        return [f"{year:04d}" for year in range(start.year, end.year + 1)]
    raise ValueError(f"Unknown granularity: {granularity}")


def _lines(items: Any) -> list[dict]:
    if isinstance(items, str):
        try:
            items = json.loads(items)
        except ValueError:
            return []
    return [item for item in items or [] if isinstance(item, dict)]


def _number(value: Any) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _quantity(item: dict) -> int:
    raw = item.get("quantity", 1)
    if isinstance(raw, bool) or not isinstance(raw, (int, float)):
        return 1
    return max(int(raw), 0)


def order_value(items: Any, total_amount: float | None) -> float:
    """What the customer paid for the goods in one order."""
    value = 0.0
    priced = False
    for item in _lines(items):
        price = _number(item.get("price"))
        if price is None:
            continue
        priced = True
        value += price * _quantity(item)
    if priced:
        return round(value, 2)
    return round(float(total_amount or 0.0), 2)


def items_sold(items: Any) -> int:
    return sum(_quantity(item) for item in _lines(items))


def summarize(
    orders: Iterable[Any],
    start: date,
    end: date,
    granularity: str,
    offset_minutes: int = LOCAL_UTC_OFFSET_MINUTES,
) -> dict[str, Any]:
    """Buckets, totals and best sellers for one shop's orders.

    Each order needs `status`, `items`, `total_amount`, `created_at` and
    `delivered_at` attributes (an ORM row or anything shaped like one).
    """
    keys = period_keys(start, end, granularity)
    buckets = {
        key: {"period": key, "orders_placed": 0, "delivered_orders": 0, "sales": 0.0, "items_sold": 0}
        for key in keys
    }
    totals = {
        "orders_placed": 0,
        "delivered_orders": 0,
        "cancelled_orders": 0,
        "sales": 0.0,
        "items_sold": 0,
    }
    products: dict[str, dict[str, Any]] = {}

    for order in orders:
        status = getattr(order, "status", None)
        status = getattr(status, "value", status)
        created = getattr(order, "created_at", None)

        if created is not None:
            placed_day = _local_date(created, offset_minutes)
            if start <= placed_day <= end:
                key = period_key(placed_day, granularity)
                buckets[key]["orders_placed"] += 1
                totals["orders_placed"] += 1
                if status == "cancelled":
                    totals["cancelled_orders"] += 1

        if status != "delivered":
            continue
        moment = getattr(order, "delivered_at", None) or created
        if moment is None:
            continue
        day = _local_date(moment, offset_minutes)
        if not (start <= day <= end):
            continue

        items = getattr(order, "items", None)
        value = order_value(items, getattr(order, "total_amount", 0.0))
        count = items_sold(items)
        key = period_key(day, granularity)
        buckets[key]["delivered_orders"] += 1
        buckets[key]["sales"] = round(buckets[key]["sales"] + value, 2)
        buckets[key]["items_sold"] += count
        totals["delivered_orders"] += 1
        totals["sales"] = round(totals["sales"] + value, 2)
        totals["items_sold"] += count

        for item in _lines(items):
            name = str(item.get("name") or "").strip()
            if not name:
                continue
            ident = str(item.get("product_id") or name)
            entry = products.setdefault(ident, {"name": name, "quantity": 0, "sales": 0.0})
            quantity = _quantity(item)
            entry["quantity"] += quantity
            price = _number(item.get("price"))
            if price is not None:
                entry["sales"] = round(entry["sales"] + price * quantity, 2)

    top = sorted(products.values(), key=lambda p: (-p["quantity"], -p["sales"], p["name"]))
    return {
        "buckets": [buckets[key] for key in keys],
        "totals": totals,
        "top_products": top[:TOP_PRODUCTS],
    }
