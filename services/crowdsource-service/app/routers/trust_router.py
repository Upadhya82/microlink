from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from app.auth import CurrentUser, get_current_user
from app.config import settings
from app.database import get_db
from app.schemas import TrustScoreResponse
from app.trust import can_confirm_reports, get_or_create_trust_score

router = APIRouter(prefix="/crowdsource", tags=["trust-score"])


@router.get("/trust-score/me", response_model=TrustScoreResponse)
async def get_my_trust_score(
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """This account's standing, plus whether it may confirm shop reports.

    The app asks this to decide whether to offer "Confirm shops near you"
    (items 6 and 7). The verdict is computed here so the rule lives in one
    place: a screen that offered the button to everyone would just collect
    403s.
    """
    trust = get_or_create_trust_score(db, current_user.id)
    response = TrustScoreResponse.model_validate(trust)
    response.min_confirm_trust = settings.min_confirm_trust
    response.can_confirm_shops = can_confirm_reports(
        is_verified=current_user.is_verified,
        score=trust.score,
        minimum=settings.min_confirm_trust,
    )
    return response


@router.get("/trust-score/{user_id}", response_model=TrustScoreResponse)
async def get_trust_score(user_id: str, db: Session = Depends(get_db)):
    return get_or_create_trust_score(db, user_id)
