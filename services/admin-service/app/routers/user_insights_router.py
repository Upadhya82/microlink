"""GET /admin/user-insights -- the admin "User Insights" tab.

How many customers, shop owners and delivery agents MicroLink has, and
roughly where they are (district and province), so the app can draw a bar
chart for the whole island, a province or a district, and search by name.

admin-service owns none of this data, so it asks the services that do,
inside the compose network, passing the admin's own token along -- every
call it makes is one the admin is already allowed to make. Read-only: no
other service changes. The rules live in app/user_insights.py.
"""

import asyncio
import logging

import httpx
from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials

from app.auth import CurrentUser, bearer_scheme, require_admin
from app.user_insights import ROLE_QUERY_NAMES, build_insights, user_points

router = APIRouter(prefix="/admin", tags=["user insights"])

logger = logging.getLogger("admin-service.user-insights")

_USERS_URL = "http://user-service:8000/users"
_SHOPS_URL = "http://shop-service:8000/shops"
_AGENTS_URL = "http://delivery-service:8000/delivery/agents"
_ORDERS_URL = "http://delivery-service:8000/delivery/orders"

_TIMEOUT_SECONDS = 8.0


async def _get_list(client: httpx.AsyncClient, url: str, params: dict, headers: dict) -> list:
    """A list from another service, or [] when it cannot be had.

    Locations are extra detail: if shop-service or delivery-service is down,
    the counts still load and those users show as "Location not known".
    """
    try:
        response = await client.get(url, params=params, headers=headers)
        response.raise_for_status()
        data = response.json()
        return data if isinstance(data, list) else []
    except Exception:
        logger.warning("User insights: could not read %s", url, exc_info=True)
        return []


@router.get("/user-insights")
async def get_user_insights(
    _admin: CurrentUser = Depends(require_admin),
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer_scheme),
):
    headers = {"Authorization": f"Bearer {credentials.credentials}"} if credentials else {}

    async with httpx.AsyncClient(timeout=_TIMEOUT_SECONDS) as client:
        # One call per role, so each can return its own full page of 500.
        user_calls = [
            client.get(_USERS_URL, params={"role": role, "limit": 500}, headers=headers)
            # user-service's own names for the roles, not this tab's.
            for role in ROLE_QUERY_NAMES.values()
        ]
        try:
            user_responses = await asyncio.gather(*user_calls)
            for response in user_responses:
                response.raise_for_status()
        except Exception:
            logger.exception("User insights: user-service did not answer")
            raise HTTPException(
                status_code=status.HTTP_502_BAD_GATEWAY,
                detail="Could not load users just now. Please try again.",
            )
        users = [user for response in user_responses for user in response.json()]

        shops, agents, orders = await asyncio.gather(
            _get_list(client, _SHOPS_URL, {"limit": 200}, headers),
            _get_list(client, _AGENTS_URL, {}, headers),
            _get_list(client, _ORDERS_URL, {"limit": 500}, headers),
        )

    return build_insights(users, user_points(shops, agents, orders))
