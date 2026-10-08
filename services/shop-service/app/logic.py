"""Business rules for shop discovery, written as plain Python functions.

This module deliberately imports nothing outside the standard library. That
keeps every rule easy to read, and lets `tests/test_logic.py` check them
without a database, Redis or FastAPI.

Each function below maps to a line in the SRS:
  * stock status ........ REQ-SHOP-4  (In Stock / Low Stock / Out of Stock)
  * shop status ......... REQ-SHOP-2  (Open / Closed / Temporarily Closed)
  * trust score ......... REQ-CROWD-3 (average of the last 90 days of ratings)
  * sorting ............. SRS 5.3.2   (sorted by distance and trust score)
  * landmark lookup ..... REQ-SEARCH-3
"""

from __future__ import annotations

import re
from datetime import date, datetime, timedelta, timezone
from typing import Any, Iterable, Sequence

SHOP_STATUSES = ("open", "closed", "temporarily_closed")
STOCK_STATUSES = ("in_stock", "low_stock", "out_of_stock")
ALERT_TYPES = ("general", "closure", "relocation", "special_offer")

DEFAULT_LOW_STOCK_THRESHOLD = 5


# --------------------------------------------------------------------------
# Shop status (REQ-SHOP-2)
# --------------------------------------------------------------------------
def status_from_is_open(is_open: bool) -> str:
    """Old clients only know a true/false `is_open`. Map it to a status."""
    return "open" if is_open else "closed"


def is_open_from_status(status: str | None) -> bool:
    """Only the plain 'open' status counts as 'Open Now' in search results."""
    return status == "open"


# --------------------------------------------------------------------------
# Stock status (REQ-SHOP-4)
# --------------------------------------------------------------------------
def derive_stock_status(quantity: int | None, threshold: int = DEFAULT_LOW_STOCK_THRESHOLD) -> str:
    """Work out the status from a quantity.

    0 or less -> out_of_stock, up to `threshold` -> low_stock, else in_stock.
    A missing quantity means "the owner did not say", so we assume in_stock.
    """
    if quantity is None:
        return "in_stock"
    if quantity <= 0:
        return "out_of_stock"
    if quantity <= threshold:
        return "low_stock"
    return "in_stock"


def resolve_stock_status(
    *,
    quantity: int | None,
    explicit_status: str | None,
    is_available: bool | None,
    current_status: str | None = None,
    stored_quantity: int | None = None,
    threshold: int = DEFAULT_LOW_STOCK_THRESHOLD,
) -> str:
    """Decide the stock status after a create/update request.

    Order of priority:
      1. The owner explicitly picked a status -> use it.
      2. The owner switched "available" off -> out_of_stock.
      3. A quantity was sent -> derive from it (so quantity 0 = Out of Stock).
      4. The owner switched "available" on without a quantity -> back to a
         normal status (from the stored quantity if we have one).
      5. Nothing relevant changed -> keep the current status.
    """
    if explicit_status is not None:
        if explicit_status not in STOCK_STATUSES:
            raise ValueError(f"Unknown stock status: {explicit_status}")
        return explicit_status
    if is_available is False:
        return "out_of_stock"
    if quantity is not None:
        return derive_stock_status(quantity, threshold)
    if is_available is True:
        if stored_quantity is not None and stored_quantity > 0:
            return derive_stock_status(stored_quantity, threshold)
        return "in_stock"
    return current_status if current_status in STOCK_STATUSES else "in_stock"


def is_available_from_stock(stock_status: str | None) -> bool:
    """Older clients read a true/false `is_available`. Keep it in sync."""
    return stock_status != "out_of_stock"


def availability_level(in_stock: int, low_stock: int, out_of_stock: int) -> str:
    """One word the app can turn into a badge on the shop list card.

    none ........ the shop has not listed any products yet
    all_in_stock  every listed product is in stock
    limited ..... some products are low or out of stock
    all_out ..... every listed product is out of stock
    """
    total = in_stock + low_stock + out_of_stock
    if total == 0:
        return "none"
    if out_of_stock == total:
        return "all_out"
    if low_stock == 0 and out_of_stock == 0:
        return "all_in_stock"
    return "limited"


# --------------------------------------------------------------------------
# Alerts
# --------------------------------------------------------------------------
def alert_is_active(
    is_active: bool,
    starts_at: datetime | None,
    ends_at: datetime | None,
    now: datetime,
) -> bool:
    """An alert shows on the shop page while it is switched on and inside its dates."""
    if not is_active:
        return False
    if starts_at is not None and _aware(starts_at) > now:
        return False
    if ends_at is not None and _aware(ends_at) < now:
        return False
    return True


# --------------------------------------------------------------------------
# Trust score (REQ-CROWD-3)
# --------------------------------------------------------------------------
def _aware(value: datetime) -> datetime:
    """Treat a datetime without a timezone as UTC so comparisons never crash."""
    return value if value.tzinfo is not None else value.replace(tzinfo=timezone.utc)


def rating_summary(
    ratings: Iterable[tuple[int, datetime]],
    now: datetime,
    window_days: int = 90,
) -> tuple[float, int]:
    """(average, count) over ratings given inside the last `window_days` days."""
    cutoff = now - timedelta(days=window_days)
    values = [value for value, when in ratings if _aware(when) >= cutoff]
    if not values:
        return 0.0, 0
    return round(sum(values) / len(values), 2), len(values)


# --------------------------------------------------------------------------
# Analytics helpers (REQ-SHOP-5)
# --------------------------------------------------------------------------
def to_local(moment: datetime, offset_minutes: int) -> datetime:
    return _aware(moment).astimezone(timezone(timedelta(minutes=offset_minutes)))


def fill_last_days(
    timestamps: Iterable[datetime],
    today: date,
    days: int = 7,
    offset_minutes: int = 0,
) -> list[dict[str, Any]]:
    """Views per day for the last `days` days, oldest first, zeros included.

    A chart looks wrong when empty days are missing, so every day is returned.
    """
    counts: dict[date, int] = {}
    for moment in timestamps:
        day = to_local(moment, offset_minutes).date()
        counts[day] = counts.get(day, 0) + 1
    result = []
    for back in range(days - 1, -1, -1):
        day = today - timedelta(days=back)
        result.append({"date": day.isoformat(), "views": counts.get(day, 0)})
    return result


def peak_hours(
    timestamps: Iterable[datetime],
    offset_minutes: int = 0,
    top: int = 3,
) -> list[dict[str, Any]]:
    """The busiest hours of the day (local time), highest first. Empty hours are skipped."""
    histogram = [0] * 24
    for moment in timestamps:
        histogram[to_local(moment, offset_minutes).hour] += 1
    ranked = sorted(range(24), key=lambda hour: (-histogram[hour], hour))
    result = []
    for hour in ranked[:top]:
        if histogram[hour] == 0:
            break
        result.append(
            {"hour": hour, "label": f"{hour:02d}:00-{(hour + 1) % 24:02d}:00", "views": histogram[hour]}
        )
    return result


# --------------------------------------------------------------------------
# Search (REQ-SEARCH-1, REQ-SEARCH-2)
# --------------------------------------------------------------------------
def escape_like(text: str) -> str:
    """Escape % and _ so a user typing them does not change the SQL pattern."""
    return text.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


def matching_categories(query: str, categories: Sequence[str]) -> list[str]:
    """Categories that a free-text query is talking about.

    "bak" and "bakery shop" both match the bakery category, so typing a
    category name finds those shops even when the shop's own name does not
    contain the word.
    """
    text = query.strip().lower()
    if len(text) < 2:
        return []
    return [c for c in categories if text in c or c in text]


def sort_shops(rows: Sequence[Any], sort: str, has_location: bool) -> list[Any]:
    """Order search results. Each row needs distance_km, rating_avg, created_at.

    smart (default): nearest first when a location is known, ties broken by
    the higher trust score. Without a location: best trust score first.
    """
    inf = float("inf")

    def distance(row: Any) -> float:
        value = getattr(row, "distance_km", None)
        return inf if value is None else value

    if sort == "newest":
        return sorted(rows, key=lambda r: _aware(r.created_at), reverse=True)
    if sort == "rating":
        return sorted(rows, key=lambda r: (-(r.rating_avg or 0.0), distance(r)))
    if has_location:
        return sorted(rows, key=lambda r: (distance(r), -(r.rating_avg or 0.0)))
    newest_first = sorted(rows, key=lambda r: _aware(r.created_at), reverse=True)
    return sorted(newest_first, key=lambda r: -(r.rating_avg or 0.0))  # stable sort keeps newest first on ties


# --------------------------------------------------------------------------
# Landmark lookup (REQ-SEARCH-3)
# --------------------------------------------------------------------------
# A small built-in list used only when the online geocoder (OpenStreetMap
# Nominatim) cannot be reached, so landmark search still works in a demo with
# poor internet. Coordinates are approximate town / junction centres.
LANDMARKS: dict[str, tuple[str, float, float]] = {
    "diyagama": ("Diyagama, Homagama", 6.8398, 80.0118),
    "diyagama junction": ("Diyagama Junction", 6.8398, 80.0118),
    "homagama": ("Homagama", 6.8441, 80.0020),
    "homagama town": ("Homagama Town", 6.8441, 80.0020),
    "kottawa": ("Kottawa", 6.8412, 79.9654),
    "maharagama": ("Maharagama", 6.8480, 79.9265),
    "nugegoda": ("Nugegoda", 6.8649, 79.8997),
    "colombo fort": ("Colombo Fort", 6.9334, 79.8503),
    "fort railway station": ("Colombo Fort Railway Station", 6.9334, 79.8503),
    "central bus stand": ("Central Bus Stand, Pettah", 6.9344, 79.8512),
    "pettah": ("Pettah, Colombo", 6.9344, 79.8512),
    "negombo": ("Negombo", 7.2083, 79.8358),
    "kandy": ("Kandy", 7.2906, 80.6337),
    "galle": ("Galle", 6.0329, 80.2170),
}


def normalize_landmark(text: str) -> str:
    """Lower-case, drop punctuation and extra spaces: "Central  Bus-Stand!" -> "central bus stand"."""
    cleaned = re.sub(r"[^a-z0-9 ]+", " ", text.lower())
    return re.sub(r"\s+", " ", cleaned).strip()


def lookup_landmark(text: str) -> dict[str, Any] | None:
    """Find a landmark in the built-in list. Exact match first, then partial."""
    key = normalize_landmark(text)
    if not key:
        return None
    if key in LANDMARKS:
        name, lat, lng = LANDMARKS[key]
        return {"name": name, "latitude": lat, "longitude": lng, "source": "builtin"}
    for known, (name, lat, lng) in sorted(LANDMARKS.items(), key=lambda item: -len(item[0])):
        if (len(known) >= 4 and known in key) or (len(key) >= 4 and key in known):
            return {"name": name, "latitude": lat, "longitude": lng, "source": "builtin"}
    return None
