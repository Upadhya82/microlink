"""Who lives or works near a shop, so they can be told about it.

MicroLink does not store where people live. So "nearby" is worked out from
places the system already knows, within NOTIFY_RADIUS_KM (5 km):

  * customers, by the address of their newest delivery    (delivery-service)
  * delivery agents, by their last shared live location   (delivery-service)
  * shop owners, by the location of their shop            (shop-service)
  * people who suggested a shop or reported a road problem
    near there, or answered a suggestion near there       (this service)

Used twice: when a shop is suggested (to ask neighbours to confirm it) and
when an admin approves one (to tell them it is on MicroLink). The other
services are read through internal endpoints the api-gateway blocks for
apps, so no user token is needed. If a service does not answer, the people
it would have added are simply not notified -- nothing else fails.

`users_near` is a pure function so tests/test_nearby_people.py can check it.
"""

from __future__ import annotations

import asyncio
import logging
from typing import Iterable

import httpx

from app.geo import haversine_km

logger = logging.getLogger("crowdsource-service.nearby-people")

NOTIFY_RADIUS_KM = 5.0
MAX_NOTIFIED = 500

_SHOPS_URL = "http://shop-service:8000/shops"


def users_near(
    lat: float,
    lng: float,
    *,
    shops: Iterable[dict] = (),
    agents: Iterable[dict] = (),
    orders: Iterable[dict] = (),
    points: Iterable[tuple] = (),
    radius_km: float = NOTIFY_RADIUS_KM,
) -> set[str]:
    """User ids whose known place is within `radius_km` of (lat, lng).

    A customer counts by their newest order only (the lists arrive newest
    first), so someone who moved away is not told about shops near their
    old home.
    """
    found: set[str] = set()

    def close(point_lat, point_lng) -> bool:
        if point_lat is None or point_lng is None:
            return False
        try:
            return haversine_km(lat, lng, float(point_lat), float(point_lng)) <= radius_km
        except (TypeError, ValueError):
            return False

    for shop in shops:
        owner = str(shop.get("owner_id") or "")
        if owner and close(shop.get("latitude"), shop.get("longitude")):
            found.add(owner)
    for agent in agents:
        user = str(agent.get("user_id") or "")
        if user and close(agent.get("current_lat"), agent.get("current_lng")):
            found.add(user)
    seen_customers: set[str] = set()
    for order in orders:
        customer = str(order.get("customer_id") or "")
        if not customer or customer in seen_customers:
            continue
        seen_customers.add(customer)
        if close(order.get("delivery_lat"), order.get("delivery_lng")):
            found.add(customer)
    # (user id, lat, lng) from anywhere else
    for point in points:
        user, point_lat, point_lng = point
        if user and close(point_lat, point_lng):
            found.add(str(user))
    return found


_KNOWN_LOCATIONS_URL = "http://delivery-service:8000/delivery/internal/known-locations"


async def _get_json(client: httpx.AsyncClient, url: str, params: dict | None = None):
    try:
        response = await client.get(url, params=params or {})
        response.raise_for_status()
        return response.json()
    except Exception:
        logger.warning("Nearby people: could not read %s", url, exc_info=True)
        return None


def _own_points(db) -> list[tuple]:
    """(user id, lat, lng) from this service's own records."""
    from app.models import (  # local import: keeps users_near importable alone
        NewShopReport,
        RoadConditionReport,
        ShopReportConfirmation,
    )

    points: list[tuple] = []
    reports = db.query(
        NewShopReport.id, NewShopReport.reporter_id, NewShopReport.latitude, NewShopReport.longitude
    ).all()
    where = {}
    for report_id, reporter, lat, lng in reports:
        points.append((reporter, lat, lng))
        where[report_id] = (lat, lng)
    # Someone who answered a suggestion was near that suggested shop.
    for report_id, user in db.query(
        ShopReportConfirmation.report_id, ShopReportConfirmation.user_id
    ).all():
        if report_id in where:
            points.append((user, *where[report_id]))
    for reporter, lat, lng in db.query(
        RoadConditionReport.reporter_id, RoadConditionReport.latitude, RoadConditionReport.longitude
    ).all():
        points.append((reporter, lat, lng))
    return points


async def find_users_near(lat: float, lng: float, db=None, authorization: str | None = None) -> set[str]:
    """Everyone known to be within NOTIFY_RADIUS_KM of (lat, lng). Never raises.

    `authorization` is accepted for older callers and no longer needed.
    """
    try:
        async with httpx.AsyncClient(timeout=6.0) as client:
            known, shops = await asyncio.gather(
                _get_json(client, _KNOWN_LOCATIONS_URL),
                _get_json(client, _SHOPS_URL, {"limit": 200}),
            )
    except Exception:
        logger.warning("Nearby people: lookup failed", exc_info=True)
        known, shops = None, None

    points: list[tuple] = []
    if isinstance(known, dict):
        for group in ("customers", "agents"):
            for item in known.get(group) or []:
                points.append((item.get("user_id"), item.get("lat"), item.get("lng")))
    if db is not None:
        try:
            points.extend(_own_points(db))
        except Exception:
            logger.warning("Nearby people: could not read own records", exc_info=True)
    return users_near(
        lat,
        lng,
        shops=shops if isinstance(shops, list) else [],
        points=points,
    )
