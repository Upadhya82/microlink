from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from app.auth import CurrentUser, get_current_user
from app.database import get_db
from app.schemas import TrustScoreResponse
from app.trust import get_or_create_trust_score

router = APIRouter(prefix="/crowdsource", tags=["trust-score"])


@router.get("/trust-score/me", response_model=TrustScoreResponse)
async def get_my_trust_score(
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    return get_or_create_trust_score(db, current_user.id)


@router.get("/trust-score/{user_id}", response_model=TrustScoreResponse)
async def get_trust_score(user_id: str, db: Session = Depends(get_db)):
    return get_or_create_trust_score(db, user_id)
