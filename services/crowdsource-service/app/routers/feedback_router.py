from fastapi import APIRouter, Depends, status
from sqlalchemy.orm import Session

from app import trust
from app.auth import CurrentUser, get_current_user
from app.database import get_db
from app.event_bus import publish_event
from app.models import OrderFeedback
from app.schemas import OrderFeedbackCreateRequest, OrderFeedbackResponse

router = APIRouter(prefix="/crowdsource", tags=["feedback"])


@router.post("/feedback", response_model=OrderFeedbackResponse, status_code=status.HTTP_201_CREATED)
async def create_feedback(
    payload: OrderFeedbackCreateRequest,
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    feedback = OrderFeedback(user_id=current_user.id, **payload.model_dump())
    db.add(feedback)
    db.commit()
    db.refresh(feedback)

    trust.record_report(db, current_user.id)

    await publish_event(
        "feedback.submitted",
        {"order_id": feedback.order_id, "user_id": feedback.user_id, "rating": feedback.rating},
    )
    return feedback


@router.get("/feedback/order/{order_id}", response_model=list[OrderFeedbackResponse])
async def list_feedback_for_order(order_id: str, db: Session = Depends(get_db)):
    return (
        db.query(OrderFeedback)
        .filter(OrderFeedback.order_id == order_id)
        .order_by(OrderFeedback.created_at.desc())
        .all()
    )
