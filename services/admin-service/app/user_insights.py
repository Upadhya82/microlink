"""User insights for the admin "User Insights" tab: who uses MicroLink, and where.

Plain Python with no imports beyond the standard library, so
`tests/test_user_insights.py` can check every rule without a database or the
other services.

Where a user is
---------------
user-service stores no address, and this feature must not change how anyone
signs up. So a user's area is worked out from data the system already has:

  * shop owner ...... the location of their (first) shop          (shop-service)
  * delivery agent .. their last shared live location             (delivery-service)
  * customer ........ the address of their most recent delivery   (delivery-service)
  * anyone else ..... where they last suggested a shop or reported
                      a road problem -- only when none of the
                      above is known                              (crowdsource-service)

That point is matched to the nearest of Sri Lanka's 25 districts (by its
centre and main towns), which gives the district and its province. It is an estimate -- a point near
a district border can land in the neighbour -- and the app says so. A user
with no known point is counted island-wide as "Location not known" and is
left out of any province or district filter. Only the district and province
leave this service; exact coordinates never do.
"""

from __future__ import annotations

import math
from datetime import datetime, timedelta, timezone
from typing import Any, Iterable

# The roles this tab reports on, in the names the app's own UI uses as its
# keys (see insightRoles in admin_user_insights_tab.dart).
ROLES = ("customer", "shop_owner", "delivery_agent")

# What user-service calls each of them. Its UserRole enum has no "customer":
# a plain shopper is "user" there. Asking it for ?role=customer answered 422,
# which failed the whole tab with a 502, and any row that had arrived would
# then have been dropped by the `role not in ROLES` check below -- so the
# count would have been zero even if the request had succeeded. The two
# vocabularies are mapped here rather than renamed, because the app keys its
# labels, colours and icons off "customer".
ROLE_QUERY_NAMES = {
    "customer": "user",
    "shop_owner": "shop_owner",
    "delivery_agent": "delivery_agent",
}

# The same mapping the other way, for the role on an incoming user row.
_REPORTING_ROLE = {source: name for name, source in ROLE_QUERY_NAMES.items()}


def reporting_role(raw_role: str) -> str | None:
    """This tab's name for a user-service role, or None if it is not counted
    (an admin, or anything unrecognised)."""
    return _REPORTING_ROLE.get(raw_role)

UNKNOWN_AREA = "Location not known"

# Sri Lanka's bounding box, a little generous. A point outside it (a test
# account in another country, a 0,0 default) is "not known", not "Jaffna".
_LAT_RANGE = (5.7, 10.0)
_LNG_RANGE = (79.4, 82.1)

# district -> (province, approximate centre latitude, longitude)
DISTRICTS: dict[str, tuple[str, float, float]] = {
    # Western
    "Colombo": ("Western", 6.88, 80.00),
    "Gampaha": ("Western", 7.09, 80.02),
    "Kalutara": ("Western", 6.60, 80.15),
    # Central
    "Kandy": ("Central", 7.29, 80.70),
    "Matale": ("Central", 7.65, 80.70),
    "Nuwara Eliya": ("Central", 6.97, 80.77),
    # Southern
    "Galle": ("Southern", 6.18, 80.30),
    "Matara": ("Southern", 6.05, 80.55),
    "Hambantota": ("Southern", 6.25, 81.10),
    # Northern
    "Jaffna": ("Northern", 9.67, 80.05),
    "Kilinochchi": ("Northern", 9.38, 80.40),
    "Mannar": ("Northern", 8.85, 80.05),
    "Vavuniya": ("Northern", 8.80, 80.50),
    "Mullaitivu": ("Northern", 9.15, 80.65),
    # Eastern
    "Batticaloa": ("Eastern", 7.75, 81.55),
    "Ampara": ("Eastern", 7.25, 81.60),
    "Trincomalee": ("Eastern", 8.55, 81.10),
    # North Western
    "Kurunegala": ("North Western", 7.60, 80.30),
    "Puttalam": ("North Western", 8.00, 79.90),
    # North Central
    "Anuradhapura": ("North Central", 8.30, 80.45),
    "Polonnaruwa": ("North Central", 7.95, 81.00),
    # Uva
    "Badulla": ("Uva", 6.95, 81.10),
    "Monaragala": ("Uva", 6.75, 81.30),
    # Sabaragamuwa
    "Ratnapura": ("Sabaragamuwa", 6.65, 80.45),
    "Kegalle": ("Sabaragamuwa", 7.20, 80.35),
}

# Extra reference points for districts whose towns sit far from the centre,
# so a border town is matched to the right side. Mostly the busy Western
# Province, where a district centre alone puts Panadura in Colombo and
# Negombo in Puttalam's direction.
_EXTRA_POINTS: dict[str, tuple[tuple[float, float], ...]] = {
    "Colombo": ((6.93, 79.86), (6.84, 80.00), (6.77, 79.88), (6.95, 80.21)),
    "Gampaha": ((7.21, 79.84), (7.09, 79.99), (7.00, 79.95), (7.14, 80.10)),
    "Kalutara": ((6.71, 79.91), (6.58, 79.96), (6.72, 80.06), (6.43, 80.00)),
    "Kandy": ((7.29, 80.63), (7.25, 80.60)),
    "Galle": ((6.03, 80.22), (6.24, 80.05)),
    "Matara": ((5.95, 80.54),),
    "Puttalam": ((7.75, 79.82), (8.04, 79.83)),
    "Kurunegala": ((7.49, 80.36),),
    "Ratnapura": ((6.68, 80.40),),
    "Kegalle": ((7.25, 80.35),),
    "Ampara": ((7.30, 81.67), (7.10, 81.83)),
    "Trincomalee": ((8.57, 81.23),),
    "Batticaloa": ((7.71, 81.69),),
    "Jaffna": ((9.66, 80.02),),
}


def _reference_points(district: str) -> tuple[tuple[float, float], ...]:
    _province, lat, lng = DISTRICTS[district]
    return ((lat, lng),) + _EXTRA_POINTS.get(district, ())


PROVINCES: tuple[str, ...] = (
    "Western",
    "Central",
    "Southern",
    "Northern",
    "Eastern",
    "North Western",
    "North Central",
    "Uva",
    "Sabaragamuwa",
)


def districts_by_province() -> dict[str, list[str]]:
    """Every province with its districts, in the order above, for the filters."""
    result: dict[str, list[str]] = {province: [] for province in PROVINCES}
    for district, (province, _lat, _lng) in DISTRICTS.items():
        result[province].append(district)
    return result


def _distance_km(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    radius = 6371.0
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    d_phi = math.radians(lat2 - lat1)
    d_lambda = math.radians(lng2 - lng1)
    a = math.sin(d_phi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(d_lambda / 2) ** 2
    return 2 * radius * math.asin(math.sqrt(a))


def locate(lat: float | None, lng: float | None) -> tuple[str | None, str | None]:
    """(district, province) for a point in Sri Lanka, or (None, None)."""
    if lat is None or lng is None:
        return None, None
    try:
        lat, lng = float(lat), float(lng)
    except (TypeError, ValueError):
        return None, None
    if not (_LAT_RANGE[0] <= lat <= _LAT_RANGE[1] and _LNG_RANGE[0] <= lng <= _LNG_RANGE[1]):
        return None, None
    district = min(
        DISTRICTS,
        key=lambda name: min(
            _distance_km(lat, lng, ref_lat, ref_lng)
            for ref_lat, ref_lng in _reference_points(name)
        ),
    )
    return district, DISTRICTS[district][0]


def _parse_time(value: Any) -> datetime | None:
    if isinstance(value, datetime):
        moment = value
    elif isinstance(value, str) and value:
        try:
            moment = datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            return None
    else:
        return None
    return moment if moment.tzinfo else moment.replace(tzinfo=timezone.utc)


def user_points(
    shops: Iterable[dict],
    agents: Iterable[dict],
    orders: Iterable[dict],
    shop_reports: Iterable[dict] = (),
    road_reports: Iterable[dict] = (),
) -> dict[str, tuple[float, float, str]]:
    """user id -> (lat, lng, where the point came from), from the other services' data.

    A shop owner with several shops is placed at the first one listed; a
    customer at the newest order (the lists arrive newest first, so the
    first order seen for a customer wins).

    Shop suggestions and road reports come last, and only fill in users with
    no better point: a customer who has never ordered is otherwise "Location
    not known", but someone who suggested a shop or reported a pothole was
    standing in that area. Newest report first, like the orders.
    """
    points: dict[str, tuple[float, float, str]] = {}
    for shop in shops:
        owner = str(shop.get("owner_id") or "")
        if owner and owner not in points and shop.get("latitude") is not None:
            points[owner] = (shop["latitude"], shop.get("longitude"), "shop")
    for agent in agents:
        user = str(agent.get("user_id") or "")
        if user and user not in points and agent.get("current_lat") is not None:
            points[user] = (agent["current_lat"], agent.get("current_lng"), "live location")
    for order in orders:
        customer = str(order.get("customer_id") or "")
        if customer and customer not in points and order.get("delivery_lat") is not None:
            points[customer] = (
                order["delivery_lat"],
                order.get("delivery_lng"),
                "last delivery address",
            )
    for rows, source in (
        (shop_reports, "suggested a shop here"),
        (road_reports, "reported a road problem here"),
    ):
        for report in rows:
            reporter = str(report.get("reporter_id") or "")
            if reporter and reporter not in points and report.get("latitude") is not None:
                points[reporter] = (report["latitude"], report.get("longitude"), source)
    return points


def build_insights(
    users: Iterable[dict],
    points: dict[str, tuple[float, float, str]],
    now: datetime | None = None,
) -> dict[str, Any]:
    """The whole response for the User Insights tab.

    Admins are not counted: the tab is about the people using the platform.
    """
    now = now or datetime.now(timezone.utc)
    week_ago = now - timedelta(days=7)

    totals = {role: 0 for role in ROLES}
    new_this_week = {role: 0 for role in ROLES}
    rows: list[dict[str, Any]] = []

    for user in users:
        role = reporting_role(str(user.get("role") or ""))
        if role is None:
            continue
        user_id = str(user.get("id") or "")
        created_at = _parse_time(user.get("created_at"))

        totals[role] += 1
        if created_at is not None and created_at >= week_ago:
            new_this_week[role] += 1

        district = province = source = None
        point = points.get(user_id)
        if point is not None:
            district, province = locate(point[0], point[1])
            source = point[2] if district else None

        rows.append(
            {
                "id": user_id,
                "full_name": str(user.get("full_name") or ""),
                "email": str(user.get("email") or ""),
                "role": role,
                "is_active": user.get("is_active") is not False,
                "is_verified": user.get("is_verified") is not False,
                "created_at": created_at.isoformat() if created_at else None,
                "district": district,
                "province": province,
                "location_source": source,
            }
        )

    rows.sort(key=lambda row: row["created_at"] or "", reverse=True)
    return {
        "totals": {**totals, "total": sum(totals.values())},
        "new_this_week": new_this_week,
        "located_users": sum(1 for row in rows if row["district"]),
        "provinces": list(PROVINCES),
        "districts": districts_by_province(),
        "users": rows,
        "generated_at": now.isoformat(),
    }
