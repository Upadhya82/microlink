"""What shop-service learns from the event bus (items 3 and 4).

A customer who rates a delivered order was writing into
crowdsource-service's `order_feedback` table, which nothing read back: the
shop page only ever showed rows from "Rate this shop", so the feedback was
saved and invisible, and it never counted towards the shop's score.

crowdsource-service publishes `feedback.submitted` with the shop id (the
docstring in reviews_router claiming otherwise is out of date), so this
listener writes it in as a review with source="order". The app labels those
"Verified order", because they can only come from a delivery that happened.

`review_from_event` is a plain function with no database in it, so the
awkward envelopes -- a missing shop, a rating out of range, a replayed
event -- can be tested directly (see tests/test_feedback_reviews.py).

Item 4 arrives the same way: delivery-service publishes `shop.timeliness`
with its verdict on how long a shop keeps drivers waiting, and this module
records it on the shop so the search path never has to ask another service.
"""

import logging
from datetime import datetime, timezone

from sqlalchemy.orm import Session

from app.config import settings
from app.models import Shop, ShopRating
from app.ratings import refresh_shop_rating

logger = logging.getLogger(settings.service_name)

# Ratings that arrive over the bus from a delivered order.
ORDER_SOURCE = "order"

FEEDBACK_EVENT = "feedback.submitted"


def review_from_event(envelope: dict) -> dict | None:
    """The review row an envelope should produce, or None to ignore it.

    Returns a dict rather than a model so the rule is testable without a
    session, and so a malformed event is rejected in one place.
    """
    if not isinstance(envelope, dict) or envelope.get("event") != FEEDBACK_EVENT:
        return None
    data = envelope.get("data")
    if not isinstance(data, dict):
        return None

    shop_id = data.get("shop_id")
    user_id = data.get("user_id")
    rating = data.get("rating")
    if not isinstance(shop_id, str) or not shop_id:
        # Feedback on a "request delivery" order carries no shop.
        return None
    if not isinstance(user_id, str) or not user_id:
        return None
    if isinstance(rating, bool) or not isinstance(rating, int):
        return None
    if not 1 <= rating <= 5:
        return None

    comment = data.get("comment")
    order_id = data.get("order_id")
    return {
        "shop_id": shop_id,
        "user_id": user_id,
        "rating": rating,
        "comment": comment.strip() if isinstance(comment, str) else "",
        "order_id": order_id if isinstance(order_id, str) else None,
        "source": ORDER_SOURCE,
    }


def save_order_review(db: Session, row: dict) -> ShopRating | None:
    """Write (or update) the order-feedback review and rescore the shop.

    Keyed on (shop_id, user_id, source), so a redelivered event updates the
    one row instead of stacking up duplicates, and a customer's own "Rate
    this shop" review is left alone.
    """
    shop = db.get(Shop, row["shop_id"])
    if shop is None:
        logger.info("Ignoring feedback for unknown shop %s", row["shop_id"])
        return None

    review = (
        db.query(ShopRating)
        .filter(
            ShopRating.shop_id == row["shop_id"],
            ShopRating.user_id == row["user_id"],
            ShopRating.source == ORDER_SOURCE,
        )
        .first()
    )
    if review is None:
        review = ShopRating(
            shop_id=row["shop_id"], user_id=row["user_id"], source=ORDER_SOURCE
        )
        db.add(review)

    review.rating = row["rating"]
    review.comment = row["comment"]
    review.order_id = row["order_id"]
    review.updated_at = datetime.now(timezone.utc)
    db.flush()

    refresh_shop_rating(db, shop)
    db.commit()
    db.refresh(review)
    return review


async def handle_event(envelope: dict, session_factory) -> None:
    """Event-bus entry point. Never raises: a bad event must not stop the
    subscriber, or every later event would be lost with it."""
    row = review_from_event(envelope)
    if row is not None:
        db = session_factory()
        try:
            saved = save_order_review(db, row)
            if saved is not None:
                logger.info(
                    "Order feedback from %s stored as a review for shop %s",
                    row["user_id"],
                    row["shop_id"],
                )
        except Exception:
            db.rollback()
            logger.exception("Could not store order feedback as a review: %r", envelope)
        finally:
            db.close()
        return

    # Item 4: delivery-service's timeliness verdict for a shop.
    timeliness = timeliness_from_event(envelope)
    if timeliness is None:
        return
    db = session_factory()
    try:
        save_timeliness(db, timeliness)
    except Exception:
        db.rollback()
        logger.exception("Could not store shop timeliness: %r", envelope)
    finally:
        db.close()


TIMELINESS_EVENT = "shop.timeliness"


def timeliness_from_event(envelope: dict) -> dict | None:
    """The timeliness fields an envelope should store, or None to ignore it.

    delivery-service owns the calculation (it has the order timestamps);
    this service only records the verdict, so the only job here is to refuse
    a malformed one rather than writing nonsense onto a shop.
    """
    if not isinstance(envelope, dict) or envelope.get("event") != TIMELINESS_EVENT:
        return None
    data = envelope.get("data")
    if not isinstance(data, dict):
        return None

    shop_id = data.get("shop_id")
    delay_prone = data.get("delay_prone")
    if not isinstance(shop_id, str) or not shop_id:
        return None
    if not isinstance(delay_prone, bool):
        return None

    wait = data.get("median_pickup_wait_min")
    if isinstance(wait, bool) or not isinstance(wait, (int, float)):
        wait = None
    elif wait < 0:
        wait = None

    return {
        "shop_id": shop_id,
        "delay_prone": delay_prone,
        "median_pickup_wait_min": float(wait) if wait is not None else None,
    }


def save_timeliness(db: Session, row: dict) -> Shop | None:
    """Record the verdict on the shop, if it still exists."""
    shop = db.get(Shop, row["shop_id"])
    if shop is None:
        logger.info("Ignoring timeliness for unknown shop %s", row["shop_id"])
        return None

    shop.delay_prone = row["delay_prone"]
    shop.median_pickup_wait_min = row["median_pickup_wait_min"]
    shop.timeliness_updated_at = datetime.now(timezone.utc)
    db.commit()
    db.refresh(shop)
    logger.info(
        "Shop %s delay_prone=%s (median pickup wait %s min)",
        shop.id,
        shop.delay_prone,
        shop.median_pickup_wait_min,
    )
    return shop
