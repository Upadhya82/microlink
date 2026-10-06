"""Customer ratings and owner replies (SRS REQ-SEARCH-4 trust score, REQ-SHOP-6).

POST /shops/{id}/rating   a logged-in customer rates a shop 1-5 (one rating per
                          customer per shop; sending again updates it)
GET  /shops/{id}/reviews  public list of ratings with comments and owner replies
POST /shops/{id}/reviews/{review_id}/reply   the owner replies, once per review

Why this lives here: until now nothing in the system ever wrote a shop's
rating_avg, so the trust score was always 0. crowdsource-service's
`feedback.submitted` event only carries an order id, not a shop id, so it
cannot update a shop. This endpoint gives the app a working way to rate a shop.
"""

from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.orm import Session

from app.auth import CurrentUser, get_current_user
from app.database import get_db
from app.event_bus import publish_event
from app.models import Shop, ShopRating
from app.ratings import refresh_shop_rating
from app.schemas import RatingCreateRequest, ReviewReplyRequest, ReviewResponse

router = APIRouter(prefix="/shops/{shop_id}", tags=["shop reviews"])


def _get_shop(db: Session, shop_id: str) -> Shop:
    shop = db.get(Shop, shop_id)
    if shop is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Shop not found")
    return shop


@router.get("/reviews", response_model=list[ReviewResponse])
async def list_reviews(
    shop_id: str,
    limit: int = Query(default=30, ge=1, le=100),
    db: Session = Depends(get_db),
):
    _get_shop(db, shop_id)
    return (
        db.query(ShopRating)
        .filter(ShopRating.shop_id == shop_id)
        .order_by(ShopRating.updated_at.desc())
        .limit(limit)
        .all()
    )


@router.post("/rating", response_model=ReviewResponse, status_code=status.HTTP_201_CREATED)
async def rate_shop(
    shop_id: str,
    payload: RatingCreateRequest,
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    shop = _get_shop(db, shop_id)
    if shop.owner_id == current_user.id:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN, detail="You cannot rate your own shop"
        )

    review = (
        db.query(ShopRating)
        .filter(ShopRating.shop_id == shop_id, ShopRating.user_id == current_user.id)
        .first()
    )
    if review is None:
        review = ShopRating(shop_id=shop_id, user_id=current_user.id)
        db.add(review)
    review.rating = payload.rating
    review.comment = payload.comment.strip()
    review.updated_at = datetime.now(timezone.utc)
    db.flush()

    refresh_shop_rating(db, shop)
    db.commit()
    db.refresh(review)

    await publish_event(
        "shop.rated",
        {"shop_id": shop_id, "rating": review.rating, "rating_avg": shop.rating_avg},
    )
    return review


@router.post("/reviews/{review_id}/reply", response_model=ReviewResponse)
async def reply_to_review(
    shop_id: str,
    review_id: str,
    payload: ReviewReplyRequest,
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    shop = _get_shop(db, shop_id)
    if current_user.role != "admin" and shop.owner_id != current_user.id:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN, detail="You do not own this shop"
        )
    review = db.get(ShopRating, review_id)
    if review is None or review.shop_id != shop_id:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Review not found")
    if review.owner_reply:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT, detail="This review already has a reply"
        )

    review.owner_reply = payload.reply.strip()
    review.replied_at = datetime.now(timezone.utc)
    db.commit()
    db.refresh(review)
    return review
