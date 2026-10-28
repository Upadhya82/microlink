import logging

import httpx

from app.config import settings

logger = logging.getLogger(settings.service_name)


async def fetch_open_shops(lat: float | None, lng: float | None) -> list[dict]:
    """Fetch candidate open shops from shop-service. Never raises -- if
    shop-service is briefly down, recommendations should degrade to an
    empty list rather than fail the request."""
    params: dict[str, str] = {"is_open": "true", "limit": "100"}
    if lat is not None:
        params["lat"] = str(lat)
    if lng is not None:
        params["lng"] = str(lng)

    url = f"{settings.shop_service_url}/shops"
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            response = await client.get(url, params=params)
            response.raise_for_status()
            return response.json()
    except Exception:
        logger.warning("Failed to fetch shops from shop-service", exc_info=True)
        return []


async def fetch_any_shops(lat: float | None, lng: float | None) -> list[dict]:
    """Every shop, open or closed, nearest first when a location is given.

    The fallback for the Home "Recommended for You" carousel when no shop is
    open right now (late at night, or a fresh install): a new user should
    still see shops moving there instead of an empty message. Never raises.
    """
    params: dict[str, str] = {"limit": "100"}
    if lat is not None:
        params["lat"] = str(lat)
    if lng is not None:
        params["lng"] = str(lng)
    url = f"{settings.shop_service_url}/shops"
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            response = await client.get(url, params=params)
            response.raise_for_status()
            return response.json()
    except Exception:
        logger.warning("Failed to fetch shops from shop-service", exc_info=True)
        return []


async def fetch_shop_catalog() -> list[dict]:
    """Fetch every shop (no open/distance filter) from shop-service. Used only
    to look up the category of shops a user interacted with in the past, which
    may not appear in today's nearby-and-open candidate list. Never raises."""
    url = f"{settings.shop_service_url}/shops"
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            response = await client.get(url, params={"limit": "200"})
            response.raise_for_status()
            return response.json()
    except Exception:
        logger.warning("Failed to fetch shop catalog from shop-service", exc_info=True)
        return []
