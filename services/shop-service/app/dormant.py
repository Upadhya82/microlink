"""Follow up on shops that have been closed for a long time.

A shop that closed a fortnight ago and never reopened is either gone or its
owner forgot to flip the switch back. Either way customers keep seeing it in
search and keep being disappointed, so:

1. after two weeks closed, ask the owner whether the shop is still trading;
2. if nothing changes a few days later, tell the people who saved the shop,
   so they stop planning trips to it.

Reopening the shop clears all of this -- that is the owner "reacting".

The two rules are pure functions over rows and a clock, so the thresholds
can be tested without a database.
"""

import asyncio
import logging
from datetime import datetime, timedelta, timezone

import httpx
from sqlalchemy.orm import Session

from app.config import settings
from app.event_bus import notify_users
from app.models import Shop

logger = logging.getLogger("shop-service.dormant")

# How long a shop may stay closed before its owner is asked about it.
CLOSED_DAYS_BEFORE_PROMPT = 14

# How long the owner then has to react before the followers are told.
DAYS_BEFORE_BROADCAST = 3

# How often to look. Hourly is plenty for a rule measured in weeks.
SWEEP_SECONDS = 3600


def _as_utc(value: datetime) -> datetime:
    """Treat a naive timestamp as UTC, so Postgres and SQLite compare alike."""
    return value if value.tzinfo is not None else value.replace(tzinfo=timezone.utc)


def needs_owner_prompt(shops, now: datetime, days: int = CLOSED_DAYS_BEFORE_PROMPT):
    """Shops closed long enough that the owner should be asked about them."""
    cutoff = now - timedelta(days=days)
    return [
        s for s in shops
        if not s.is_open
        and s.closed_since is not None
        and _as_utc(s.closed_since) <= cutoff
        and s.inactivity_prompt_at is None
    ]


def needs_follower_broadcast(shops, now: datetime, days: int = DAYS_BEFORE_BROADCAST):
    """Shops whose owner was asked and still has not reopened."""
    cutoff = now - timedelta(days=days)
    return [
        s for s in shops
        if not s.is_open
        and s.inactivity_prompt_at is not None
        and _as_utc(s.inactivity_prompt_at) <= cutoff
        and s.inactivity_broadcast_at is None
    ]


def mark_closed(shop: Shop, now: datetime | None = None) -> None:
    """Start the clock when a shop stops being open.

    Only on the transition: calling it again on an already-closed shop would
    keep pushing the fortnight back and the follow-up would never fire.
    """
    if shop.closed_since is None:
        shop.closed_since = now or datetime.now(timezone.utc)


def mark_open(shop: Shop) -> None:
    """Reopening is the owner reacting, so forget the whole sequence."""
    shop.closed_since = None
    shop.inactivity_prompt_at = None
    shop.inactivity_broadcast_at = None


async def _followers(shop_id: str) -> list[str]:
    """Who saved this shop. Empty on any failure -- a missed notification is
    better than a failed sweep."""
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            response = await client.get(
                f"{settings.recommendation_service_url}/recommendations/shops/{shop_id}/followers"
            )
            if response.status_code != 200:
                return []
            return [str(u) for u in response.json()]
    except Exception:
        logger.warning("Could not read followers for shop %s", shop_id, exc_info=True)
        return []


async def run_sweep(db: Session, now: datetime | None = None) -> dict[str, int]:
    """One pass of both stages. Returns how many shops each stage touched."""
    now = now or datetime.now(timezone.utc)
    closed = db.query(Shop).filter(Shop.is_open.is_(False)).all()

    prompted = needs_owner_prompt(closed, now)
    for shop in prompted:
        shop.inactivity_prompt_at = now
    if prompted:
        db.commit()
        for shop in prompted:
            await notify_users(
                [shop.owner_id],
                "Is your shop still open?",
                f"{shop.name} has been closed for {CLOSED_DAYS_BEFORE_PROMPT} days. "
                "Reopen it so customers can find it again, or let us know it has "
                "closed for good.",
                kind="shop",
                link={"route": "shop", "id": shop.id},
            )

    broadcast = needs_follower_broadcast(closed, now)
    for shop in broadcast:
        shop.inactivity_broadcast_at = now
    if broadcast:
        db.commit()
        for shop in broadcast:
            followers = await _followers(shop.id)
            if not followers:
                continue
            await notify_users(
                followers,
                "A shop you saved looks closed",
                f"{shop.name} has been closed for some time and its owner has not "
                "confirmed it is still trading.",
                kind="shop",
                link={"route": "shop", "id": shop.id},
            )

    if prompted or broadcast:
        logger.info(
            "Dormant sweep: prompted %d owner(s), told followers about %d shop(s)",
            len(prompted),
            len(broadcast),
        )
    return {"prompted": len(prompted), "broadcast": len(broadcast)}


async def run_dormant_loop(session_factory) -> None:
    """Sweep for dormant shops until the service shuts down."""
    while True:
        try:
            await asyncio.sleep(SWEEP_SECONDS)
            db = session_factory()
            try:
                await run_sweep(db)
            finally:
                db.close()
        except asyncio.CancelledError:
            raise
        except Exception:
            logger.exception("Dormant-shop sweep failed; will retry")
