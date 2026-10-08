"""Keeps a shop's trust score (rating_avg / rating_count) up to date.

SRS REQ-CROWD-3: the trust score is the average of all customer ratings from
the last 90 days. Ratings live in `shop_ratings`; this function recomputes the
two numbers stored on the shop row. Used by the rating endpoint and the seed
script.
"""

from datetime import datetime, timezone

from sqlalchemy.orm import Session

from app import logic
from app.config import settings
from app.models import Shop, ShopRating


def refresh_shop_rating(db: Session, shop: Shop) -> None:
    """Recompute rating_avg / rating_count on `shop`. The caller commits."""
    rows = db.query(ShopRating.rating, ShopRating.updated_at).filter(
        ShopRating.shop_id == shop.id
    )
    average, count = logic.rating_summary(
        [(rating, when) for rating, when in rows],
        now=datetime.now(timezone.utc),
        window_days=settings.rating_window_days,
    )
    shop.rating_avg = average
    shop.rating_count = count
