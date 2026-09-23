"""Shared trust-score bookkeeping used by every report/feedback submission
and moderation endpoint. Keeping this in one place avoids duplicating the
get-or-create + adjust logic across the feedback, road-report, and
shop-report routers."""

from sqlalchemy.orm import Session

from app.models import UserTrustScore


def get_or_create_trust_score(db: Session, user_id: str) -> UserTrustScore:
    trust = db.query(UserTrustScore).filter(UserTrustScore.user_id == user_id).first()
    if trust is None:
        trust = UserTrustScore(user_id=user_id, score=50.0)
        db.add(trust)
        db.commit()
        db.refresh(trust)
    elif trust.score is None:
        trust.score = 50.0
        db.commit()
        db.refresh(trust)
    return trust


def record_report(db: Session, user_id: str) -> UserTrustScore:
    """Call whenever a user submits feedback, a road report, or a shop
    report. Increments total_reports while keeping the base trust score at 50
    until moderation changes it."""
    trust = get_or_create_trust_score(db, user_id)
    trust.total_reports += 1
    if trust.score is None:
        trust.score = 50.0
    db.commit()
    db.refresh(trust)
    return trust


def adjust_on_moderation(db: Session, user_id: str, approved: bool) -> UserTrustScore:
    """Call whenever an admin moderates a road report or shop report.
    On approval (verified/resolved/approved): +1 validated_reports, +2 score
    (capped at 100). On rejection: -1 score (floored at 0)."""
    trust = get_or_create_trust_score(db, user_id)
    if approved:
        trust.validated_reports += 1
        trust.score = min(100.0, trust.score + 2)
    else:
        trust.score = max(0.0, trust.score - 1)
    db.commit()
    db.refresh(trust)
    return trust
