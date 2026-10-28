"""Who someone is: full names from user-service, for showing commenters.

crowdsource-service stores only user ids. To show "Kamal Perera" next to a
comment it asks user-service's internal /users/internal/names, inside the
compose network (api-gateway blocks that path for apps). Best effort: if
user-service does not answer, comments still show, as "MicroLink user".
"""

import logging
from typing import Iterable

import httpx

logger = logging.getLogger("crowdsource-service.people")

_NAMES_URL = "http://user-service:8000/users/internal/names"
UNKNOWN_NAME = "MicroLink user"


async def user_names(ids: Iterable[str]) -> dict[str, str]:
    """user id -> full name, for the ids user-service knows."""
    wanted = sorted({str(i) for i in ids if i})
    if not wanted:
        return {}
    try:
        async with httpx.AsyncClient(timeout=4.0) as client:
            response = await client.get(_NAMES_URL, params={"ids": ",".join(wanted[:200])})
            response.raise_for_status()
            names = response.json().get("names", {})
            return {str(k): str(v) for k, v in names.items() if v}
    except Exception:
        logger.warning("Could not look up commenter names", exc_info=True)
        return {}


def name_for(names: dict[str, str], user_id: str | None) -> str:
    return names.get(str(user_id or ""), UNKNOWN_NAME)


_PHONE_URL = "http://user-service:8000/users/internal/by-phone"
_ADMIN_IDS_URL = "http://user-service:8000/users/internal/admin-ids"


async def phone_owner(phone: str | None) -> dict | None:
    """The MicroLink account a phone number belongs to ({id, full_name, role}), or None."""
    if not phone or not phone.strip():
        return None
    try:
        async with httpx.AsyncClient(timeout=4.0) as client:
            response = await client.get(_PHONE_URL, params={"phone": phone.strip()})
            response.raise_for_status()
            user = response.json().get("user")
            return user if isinstance(user, dict) and user.get("id") else None
    except Exception:
        logger.warning("Could not check the suggested phone number", exc_info=True)
        return None


_ACTIVE_IDS_URL = "http://user-service:8000/users/internal/active-ids"


async def active_non_admin_ids() -> list[str]:
    """Every active non-admin account (the "nobody known nearby" fallback)."""
    try:
        async with httpx.AsyncClient(timeout=4.0) as client:
            response = await client.get(_ACTIVE_IDS_URL)
            response.raise_for_status()
            return [str(i) for i in response.json().get("user_ids", [])]
    except Exception:
        logger.warning("Could not look up active users", exc_info=True)
        return []


async def admin_ids() -> list[str]:
    try:
        async with httpx.AsyncClient(timeout=4.0) as client:
            response = await client.get(_ADMIN_IDS_URL)
            response.raise_for_status()
            return [str(i) for i in response.json().get("admin_ids", [])]
    except Exception:
        logger.warning("Could not look up the admins", exc_info=True)
        return []
