import logging

import httpx

from app.config import settings

logger = logging.getLogger(settings.service_name)


async def fetch_preferred_categories(authorization: str | None) -> list[str]:
    """Best-effort read of the caller's explicitly-chosen shop categories from
    user-service (`GET /users/me/preferences`). The field is stored there as a
    single comma-separated string. Returns [] on any problem so recommendations
    still work if user-service is unreachable or the user set no preferences."""
    if not authorization:
        return []
    url = f"{settings.user_service_url}/users/me/preferences"
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            response = await client.get(url, headers={"Authorization": authorization})
            response.raise_for_status()
            raw = response.json().get("preferred_categories", "") or ""
    except Exception:
        logger.warning("Failed to fetch user preferences", exc_info=True)
        return []
    return [part.strip() for part in raw.split(",") if part.strip()]
