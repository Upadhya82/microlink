"""Community verification: nearby customers vouching a shop into verified.

A shop registered by its owner starts unverified. Until this module existed
the only way out of that state was an admin calling PATCH /shops/{id}/verify,
which is a bottleneck in exactly the places the project is for: an admin in
Colombo has no way to know whether a grocery that appeared in Homagama last
week is real. The people who walk past it every day do.

So a confirmation from a nearby customer is treated as the same kind of
evidence an admin gives, and enough of them verify the shop outright.

The two gates that make that safe to automate are kept apart on purpose:

  * WHO may confirm (`can_confirm_shop`) -- a verified account, with enough
    crowdsourcing standing, physically near the shop, and not its owner.
  * WHETHER the shop may go live (`try_auto_verify`) -- enough distinct
    confirmations AND enough listable products, because item 10's rule that
    a verified shop must have something to buy applies however it was
    verified. A shop the neighbourhood has vouched for but which lists
    nothing stays unverified and its owner is told why; it goes live by
    itself the moment the fifth product is stocked.

Both are pure-ish and live here rather than in the router so the endpoint,
the product-count hook and the tests cannot disagree about the rule.
"""

import logging
from datetime import datetime, timezone

import httpx
from sqlalchemy import func
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app import geo, listings
from app.config import settings
from app.event_bus import notify_users, publish_event
from app.models import Shop, ShopExistenceConfirmation

logger = logging.getLogger(settings.service_name)

# What a new crowdsourcing account starts with, and what an unreachable
# crowdsource-service is assumed to mean. Mirrors the same constant in
# crowdsource-service/app/trust.py.
DEFAULT_TRUST_SCORE = 50.0

VERIFIED_VIA_COMMUNITY = "community"
VERIFIED_VIA_ADMIN = "admin"


class ConfirmationRefused(Exception):
    """Why this account may not confirm this shop. The router turns the
    message into the 403/400 the app shows; raising rather than returning a
    bool keeps the reason from being invented twice."""

    def __init__(self, reason: str, *, status_code: int = 403) -> None:
        super().__init__(reason)
        self.reason = reason
        self.status_code = status_code


def confirmation_count(db: Session, shop_id: str) -> int:
    """How many distinct people have confirmed this shop exists."""
    return (
        db.query(func.count(ShopExistenceConfirmation.id))
        .filter(ShopExistenceConfirmation.shop_id == shop_id)
        .scalar()
    ) or 0


def confirmation_counts(db: Session, shop_ids: list[str]) -> dict[str, int]:
    """The same tally for many shops in one query, for the search results."""
    if not shop_ids:
        return {}
    rows = (
        db.query(ShopExistenceConfirmation.shop_id, func.count(ShopExistenceConfirmation.id))
        .filter(ShopExistenceConfirmation.shop_id.in_(shop_ids))
        .group_by(ShopExistenceConfirmation.shop_id)
        .all()
    )
    return {shop_id: count for shop_id, count in rows}


def meets_community_threshold(count: int) -> bool:
    return count >= settings.community_confirmations_to_verify


def record_confirmation(
    db: Session,
    *,
    shop_id: str,
    user_id: str,
    latitude: float,
    longitude: float,
    distance_km: float,
    trust_score: float | None,
) -> bool:
    """Store one confirmation. Returns whether this call stored a new one.

    Confirming twice is not an error -- the app may retry on a poor
    connection, and the second tap simply must not count -- so an existing
    row, whether found by the check or by the unique constraint losing a
    race with another request, is reported as "nothing new" rather than
    raised.
    """
    if has_confirmed(db, shop_id, user_id):
        return False
    db.add(
        ShopExistenceConfirmation(
            shop_id=shop_id,
            user_id=user_id,
            latitude=latitude,
            longitude=longitude,
            distance_km=distance_km,
            trust_score=trust_score,
        )
    )
    try:
        db.commit()
    except IntegrityError:
        # Two taps in flight at once; the other one stored it.
        db.rollback()
        return False
    return True


def clear_confirmations(db: Session, shop_id: str) -> int:
    """Throw away a shop's confirmations. Returns how many were removed.

    Called when an admin un-verifies a shop. Without this, an admin who
    un-verified a shop the neighbourhood had vouched for would see it verify
    itself again the next time its owner touched a product, because the
    confirmations that verified it were still standing. An admin's decision
    has to be the last word, so the evidence they overruled is discarded --
    the neighbours can always confirm it again if the admin was wrong.
    """
    removed = (
        db.query(ShopExistenceConfirmation)
        .filter(ShopExistenceConfirmation.shop_id == shop_id)
        .delete(synchronize_session=False)
    )
    db.commit()
    return removed or 0


def has_confirmed(db: Session, shop_id: str, user_id: str) -> bool:
    return (
        db.query(ShopExistenceConfirmation.id)
        .filter(
            ShopExistenceConfirmation.shop_id == shop_id,
            ShopExistenceConfirmation.user_id == user_id,
        )
        .first()
        is not None
    )


def can_confirm_shop(
    *,
    is_verified: bool,
    trust_score: float | None,
    distance_km: float | None,
    is_owner: bool,
) -> None:
    """Raise ConfirmationRefused unless this account may vouch for this shop.

    A missing trust score counts as the starting 50, which is what a new
    account has and what an unreachable crowdsource-service is taken to mean.
    A missing distance means the client sent no position, which cannot be
    accepted: proximity is the whole reason this confirmation is worth more
    than an admin's guess.
    """
    if is_owner:
        raise ConfirmationRefused(
            "You cannot confirm your own shop.", status_code=400
        )
    if not is_verified:
        raise ConfirmationRefused(
            "Your account must be verified before you can confirm a shop."
        )
    score = DEFAULT_TRUST_SCORE if trust_score is None else trust_score
    if score < settings.min_confirm_trust:
        raise ConfirmationRefused(
            "Your account cannot confirm shops yet. Contribute some accepted "
            "reports first."
        )
    if distance_km is None:
        raise ConfirmationRefused(
            "Your location is needed to confirm a shop.", status_code=400
        )
    if distance_km > settings.confirm_radius_km:
        raise ConfirmationRefused(
            f"You are {distance_km:.1f} km away. Only customers within "
            f"{settings.confirm_radius_km:g} km of a shop can confirm it.",
            status_code=400,
        )


def distance_to_shop(shop: Shop, latitude: float, longitude: float) -> float:
    return round(geo.haversine_km(latitude, longitude, shop.latitude, shop.longitude), 2)


async def fetch_trust_score(user_id: str, bearer_token: str | None) -> float | None:
    """This account's crowdsourcing trust score, or None if it cannot be read.

    The caller's own token is forwarded to /crowdsource/trust-score/me rather
    than asking for somebody else's score, so this service never needs
    privileges of its own. None (a timeout, a 500, crowdsource-service not
    running) is read by `can_confirm_shop` as the starting 50: an outage in a
    service that only *restricts* who may confirm must not block the
    confirmation, and the proximity and distinct-user rules still hold.
    """
    if not bearer_token:
        return None
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            response = await client.get(
                f"{settings.crowdsource_service_url}/crowdsource/trust-score/me",
                headers={"Authorization": f"Bearer {bearer_token}"},
            )
            if response.status_code != 200:
                return None
            score = response.json().get("score")
            return float(score) if score is not None else None
    except Exception:
        logger.warning(
            "Could not read the trust score for user %s; treating it as the "
            "starting %s",
            user_id,
            DEFAULT_TRUST_SCORE,
            exc_info=True,
        )
        return None


async def try_auto_verify(db: Session, shop: Shop, listable_count: int) -> bool:
    """Verify `shop` if the neighbourhood and its shelves both say it is real.

    Returns whether this call verified it. Safe to call whenever either
    number changes -- an already-verified shop is left alone, so the admin's
    `verified_via = "admin"` is never overwritten and the owner is never
    told twice.

    The two orders this can complete in are both handled: confirmations
    arriving last (the confirm endpoint calls this) and products arriving
    last (listings.review_product_count calls this).
    """
    if shop.is_verified:
        return False

    count = confirmation_count(db, shop.id)
    if not meets_community_threshold(count):
        return False

    if not listings.meets_verification_threshold(listable_count):
        # The neighbourhood has vouched for it, so the only thing left is a
        # stocked shelf. Tell the owner once -- the same "told once" flag
        # item 10 already uses -- and let the next restock finish the job.
        await _warn_owner_about_products(db, shop, count, listable_count)
        return False

    shop.is_verified = True
    shop.verified_at = datetime.now(timezone.utc)
    shop.verified_by = VERIFIED_VIA_COMMUNITY
    shop.verified_via = VERIFIED_VIA_COMMUNITY
    # _warn_owner_about_products borrows item 10's "already told them" flag.
    # Clearing it here means a verified shop that later drops below the
    # product threshold still gets that one warning, instead of being
    # silently skipped because this feature had used the flag up.
    shop.low_product_warning_at = None
    db.commit()
    db.refresh(shop)

    await publish_event(
        "shop.verified",
        {
            "shop_id": shop.id,
            "owner_id": shop.owner_id,
            "is_verified": True,
            "verified_via": VERIFIED_VIA_COMMUNITY,
            "confirmations": count,
        },
    )
    if shop.owner_id:
        await notify_users(
            [shop.owner_id],
            "Your shop has been verified by your neighbours",
            f"{count} customers near {shop.name} confirmed it is really there, "
            "so it is now verified and shown as such to everyone.",
            kind="account",
            link={"route": "shop", "id": shop.id},
        )
    return True


async def _warn_owner_about_products(
    db: Session, shop: Shop, confirmations: int, listable_count: int
) -> None:
    """Tell the owner once that only their product list is holding them back."""
    if shop.low_product_warning_at is not None or not shop.owner_id:
        return
    shop.low_product_warning_at = datetime.now(timezone.utc)
    db.commit()
    await notify_users(
        [shop.owner_id],
        "Your neighbours confirmed your shop -- one step left",
        f"{confirmations} customers near {shop.name} confirmed it exists. It "
        f"will be verified automatically once it lists "
        f"{settings.min_products_to_verify} products with at least "
        f"{settings.min_listable_stock} in stock (it has {listable_count}).",
        kind="shop_alert",
        link={"route": "shop", "id": shop.id},
    )
