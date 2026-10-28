import math
from collections import defaultdict
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, Query, Request, status
from sqlalchemy import func
from sqlalchemy.orm import Session

from app.auth import CurrentUser, get_current_user
from app.database import get_db
from app.event_bus import publish_event
from app.models import Dismissal, Favorite, Interaction, InteractionType
from app.schemas import FavoriteResponse, InteractionCreateRequest, InteractionResponse
from app.shop_client import fetch_any_shops, fetch_open_shops, fetch_shop_catalog
from app.user_client import fetch_preferred_categories

router = APIRouter(prefix="/recommendations", tags=["recommendations"])

# How strongly each kind of logged interaction signals real intent.
_INTERACTION_WEIGHT = {
    InteractionType.order: 3.0,
    InteractionType.favorite: 3.0,
    InteractionType.click: 1.0,
    InteractionType.view: 0.4,
}
# A behaviour signal loses half its weight every 30 days, so what the user did
# recently counts far more than what they did months ago ("sequences").
_HALF_LIFE_DAYS = 30.0
# New shops decay faster -- a two-week-old shop is only "half new".
_FRESHNESS_HALF_LIFE_DAYS = 14.0

# Relative weight of each scoring signal in the final blend.
_W_CONTENT = 2.0      # matches categories this user gravitates to
_W_COLLABORATIVE = 1.5  # liked by users who like the same shops as this user
_W_POPULARITY = 1.0   # global favourites + orders + rating
_W_PROXIMITY = 0.8    # how close the shop is
_W_FRESHNESS = 0.3    # recently added to the platform


def _recency_weight(timestamp: datetime | None, now: datetime, half_life_days: float) -> float:
    """Exponential decay: 1.0 for something that just happened, 0.5 after one
    half-life, approaching 0 for old events."""
    if timestamp is None:
        return 1.0
    if timestamp.tzinfo is None:
        timestamp = timestamp.replace(tzinfo=timezone.utc)
    age_days = max((now - timestamp).total_seconds() / 86_400.0, 0.0)
    return 0.5 ** (age_days / half_life_days)


def _parse_timestamp(raw: object) -> datetime | None:
    if not raw:
        return None
    try:
        return datetime.fromisoformat(str(raw).replace("Z", "+00:00"))
    except ValueError:
        return None


def _normalise(raw: dict[str, float]) -> dict[str, float]:
    """Scale a {key: value} map into [0, 1] by its own maximum, so every signal
    contributes on the same scale regardless of its natural units."""
    top = max(raw.values(), default=0.0)
    if top <= 0:
        return {}
    return {key: value / top for key, value in raw.items()}


def _explain(contributions: dict[str, float]) -> str:
    """Turn the winning scoring signal into a short human-readable reason."""
    label, value = max(contributions.items(), key=lambda item: item[1])
    if value <= 0:
        return "Suggested for you"
    return f"Recommended because it's {label}"


def _diversify(scored: list[tuple[dict, float, str]], limit: int) -> list[dict]:
    """Greedy re-rank that keeps score order but pushes down shops whose
    category has already been picked, so the rail opens with variety instead of
    five shops of the same kind -- which is exactly what a plain distance sort
    (the "Nearby Shops" rail) produces."""
    pool = sorted(scored, key=lambda item: item[1], reverse=True)
    chosen: list[dict] = []
    seen_categories: dict[str, int] = defaultdict(int)
    while pool and len(chosen) < limit:
        best_index = 0
        best_adjusted: float | None = None
        for index, (shop, score, _reason) in enumerate(pool):
            adjusted = score - 0.5 * seen_categories[shop.get("category")]
            if best_adjusted is None or adjusted > best_adjusted:
                best_adjusted, best_index = adjusted, index
        shop, _score, reason = pool.pop(best_index)
        enriched = dict(shop)
        enriched["reason"] = reason
        chosen.append(enriched)
        seen_categories[shop.get("category")] += 1
    return chosen


@router.get("")
async def get_recommendations(
    request: Request,
    lat: float | None = Query(default=None, ge=-90, le=90),
    lng: float | None = Query(default=None, ge=-180, le=180),
    limit: int = Query(default=10, ge=1, le=100),
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
) -> list[dict]:
    """Rank nearby open shops for this user with a hybrid score blending:
    content affinity (their category taste), collaborative filtering (what
    like-minded users favourite), global popularity, proximity and freshness --
    then re-rank for category variety. Falls back gracefully to
    popularity + proximity for a brand-new user with no history."""
    candidates = await fetch_open_shops(lat, lng)
    if not candidates:
        # Nothing open right now (late at night, or a new install): rank
        # every shop instead, so a brand-new user still sees the carousel
        # on Home rather than an empty "browse a few shops" message.
        candidates = await fetch_any_shops(lat, lng)
    if not candidates:
        return []

    user_id = current_user.id
    now = datetime.now(timezone.utc)

    # ---- this user's own signals -------------------------------------------
    interactions = db.query(Interaction).filter(Interaction.user_id == user_id).all()
    my_favorites = {
        row.shop_id
        for row in db.query(Favorite.shop_id).filter(Favorite.user_id == user_id).all()
    }
    dismissed = {
        row.shop_id
        for row in db.query(Dismissal.shop_id).filter(Dismissal.user_id == user_id).all()
    }

    # id -> category for EVERY shop, so we can read the category of shops the
    # user touched in the past even if they aren't in today's candidate list.
    category_of = {shop["id"]: shop.get("category") for shop in await fetch_shop_catalog()}
    for shop in candidates:
        category_of.setdefault(shop["id"], shop.get("category"))

    # ---- signal 1: content affinity (their category taste) ----------------
    category_affinity: dict[str, float] = defaultdict(float)
    for interaction in interactions:
        category = category_of.get(interaction.shop_id)
        if not category:
            continue
        category_affinity[category] += _INTERACTION_WEIGHT.get(
            interaction.interaction_type, 0.0
        ) * _recency_weight(interaction.created_at, now, _HALF_LIFE_DAYS)

    for category in await fetch_preferred_categories(request.headers.get("authorization")):
        category_affinity[category] += 2.0  # explicit "I like this" from their profile

    category_affinity = _normalise(category_affinity)

    # ---- signal 2: collaborative filtering (like-minded users) ------------
    collaborative: dict[str, float] = {}
    if my_favorites:
        peer_user_ids = [
            row[0]
            for row in db.query(Favorite.user_id)
            .filter(Favorite.shop_id.in_(my_favorites), Favorite.user_id != user_id)
            .distinct()
            .all()
        ]
        if peer_user_ids:
            peer_favorites = (
                db.query(Favorite.shop_id, func.count(func.distinct(Favorite.user_id)))
                .filter(Favorite.user_id.in_(peer_user_ids))
                .filter(Favorite.shop_id.notin_(my_favorites))
                .group_by(Favorite.shop_id)
                .all()
            )
            collaborative = _normalise(
                {shop_id: float(count) for shop_id, count in peer_favorites}
            )

    # ---- signal 3: global popularity (all users) -------------------------
    favorite_counts = dict(
        db.query(Favorite.shop_id, func.count(Favorite.id)).group_by(Favorite.shop_id).all()
    )
    order_counts = dict(
        db.query(Interaction.shop_id, func.count(Interaction.id))
        .filter(Interaction.interaction_type == InteractionType.order)
        .group_by(Interaction.shop_id)
        .all()
    )
    popularity = _normalise(
        {
            shop["id"]: math.log1p(
                favorite_counts.get(shop["id"], 0) + 2 * order_counts.get(shop["id"], 0)
            )
            + (shop.get("rating_avg") or 0.0) / 5.0
            for shop in candidates
        }
    )

    # ---- score every candidate ------------------------------------------
    scored: list[tuple[dict, float, str]] = []
    for shop in candidates:
        shop_id = shop["id"]
        if shop_id in dismissed or shop_id in my_favorites:
            continue  # dismissed, or already saved -- not "discovery"

        category = shop.get("category")
        distance = shop.get("distance_km")

        s_content = category_affinity.get(category, 0.0)
        s_collab = collaborative.get(shop_id, 0.0)
        s_popular = popularity.get(shop_id, 0.0)
        s_proximity = 1.0 / (1.0 + distance) if distance is not None else 0.3
        s_fresh = _recency_weight(
            _parse_timestamp(shop.get("created_at")), now, _FRESHNESS_HALF_LIFE_DAYS
        )

        score = (
            _W_CONTENT * s_content
            + _W_COLLABORATIVE * s_collab
            + _W_POPULARITY * s_popular
            + _W_PROXIMITY * s_proximity
            + _W_FRESHNESS * s_fresh
        )
        reason = _explain(
            {
                f"a good match for your interest in {category}": _W_CONTENT * s_content,
                "liked by shoppers with similar taste": _W_COLLABORATIVE * s_collab,
                "popular with shoppers right now": _W_POPULARITY * s_popular,
                "close to you": _W_PROXIMITY * s_proximity,
                "new on MicroLink": _W_FRESHNESS * s_fresh,
            }
        )
        scored.append((shop, score, reason))

    return _diversify(scored, limit)


@router.post(
    "/interactions", response_model=InteractionResponse, status_code=status.HTTP_201_CREATED
)
async def create_interaction(
    payload: InteractionCreateRequest,
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    interaction = Interaction(
        user_id=current_user.id,
        shop_id=payload.shop_id,
        interaction_type=payload.interaction_type,
    )
    db.add(interaction)
    db.commit()
    db.refresh(interaction)

    await publish_event(
        "recommendation.interaction_logged",
        {
            "user_id": interaction.user_id,
            "shop_id": interaction.shop_id,
            "interaction_type": interaction.interaction_type.value,
        },
    )
    return interaction


@router.get("/interactions/me", response_model=list[InteractionResponse])
async def list_my_interactions(
    limit: int = Query(default=50, ge=1, le=200),
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    return (
        db.query(Interaction)
        .filter(Interaction.user_id == current_user.id)
        .order_by(Interaction.created_at.desc())
        .limit(limit)
        .all()
    )


@router.post("/{shop_id}/dismiss", status_code=status.HTTP_204_NO_CONTENT)
async def dismiss_shop(
    shop_id: str,
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    existing = (
        db.query(Dismissal)
        .filter(Dismissal.user_id == current_user.id, Dismissal.shop_id == shop_id)
        .first()
    )
    if existing is None:
        db.add(Dismissal(user_id=current_user.id, shop_id=shop_id))
        db.commit()


@router.delete("/{shop_id}/dismiss", status_code=status.HTTP_204_NO_CONTENT)
async def undismiss_shop(
    shop_id: str,
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    db.query(Dismissal).filter(
        Dismissal.user_id == current_user.id, Dismissal.shop_id == shop_id
    ).delete()
    db.commit()


@router.get("/favorites/me", response_model=list[FavoriteResponse])
async def list_my_favorites(
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    return (
        db.query(Favorite)
        .filter(Favorite.user_id == current_user.id)
        .order_by(Favorite.created_at.desc())
        .all()
    )


@router.post("/{shop_id}/favorite", status_code=status.HTTP_204_NO_CONTENT)
async def favorite_shop(
    shop_id: str,
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    existing = (
        db.query(Favorite)
        .filter(Favorite.user_id == current_user.id, Favorite.shop_id == shop_id)
        .first()
    )
    if existing is None:
        db.add(Favorite(user_id=current_user.id, shop_id=shop_id))
        db.commit()
        await publish_event(
            "recommendation.favorited", {"user_id": current_user.id, "shop_id": shop_id}
        )


@router.delete("/{shop_id}/favorite", status_code=status.HTTP_204_NO_CONTENT)
async def unfavorite_shop(
    shop_id: str,
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    db.query(Favorite).filter(
        Favorite.user_id == current_user.id, Favorite.shop_id == shop_id
    ).delete()
    db.commit()


@router.get("/shops/{shop_id}/followers", response_model=list[str])
async def shop_followers(shop_id: str, db: Session = Depends(get_db)):
    """The user ids that favourited this shop.

    Service-to-service only: shop-service uses it to work out who actually
    cares that a shop has gone quiet. "Customers near the shop" is not
    something this system can answer -- no customer location is stored --
    and the people who saved the shop are a better audience anyway.
    """
    rows = db.query(Favorite.user_id).filter(Favorite.shop_id == shop_id).all()
    return [row[0] for row in rows]
