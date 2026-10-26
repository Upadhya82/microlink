import logging

from fastapi import APIRouter, Depends, File, HTTPException, Query, Request, Response, UploadFile, status
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from app import confirmations as conf
from app import nearby_people, people
from app import trust
from app.auth import CurrentUser, get_current_user, require_admin
from app.config import settings
from app.database import get_db
from app.event_bus import notify_users, publish_event
from app.geo import haversine_km
from app.images import ImageRejected, process_image
from app.models import (
    NewShopReport,
    ShopReportConfirmation,
    ShopReportStatus,
    SuggestionCommentReply,
    SuggestionGeneralComment,
)
from app.schemas import (
    ApprovedSuggestionResponse,
    NewShopReportCreateRequest,
    NewShopReportResponse,
    NewShopReportStatusUpdateRequest,
    ShopReportConfirmRequest,
)

router = APIRouter(prefix="/crowdsource", tags=["shop-reports"])

logger = logging.getLogger("crowdsource-service.shop-reports")


@router.post(
    "/shop-reports", response_model=NewShopReportResponse, status_code=status.HTTP_201_CREATED
)
async def create_shop_report(
    payload: NewShopReportCreateRequest,
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    report = NewShopReport(reporter_id=current_user.id, **payload.model_dump())
    db.add(report)
    db.commit()
    db.refresh(report)

    trust.record_report(db, current_user.id)

    await publish_event(
        "shop_report.created",
        {
            "report_id": report.id,
            "reporter_id": report.reporter_id,
            "shop_name": report.shop_name,
        },
    )

    # Who hears about it depends on the phone number:
    #   * it belongs to a MicroLink account -> straight to the admins
    #     ("fast track"); the neighbours are not asked to confirm it.
    #   * otherwise (or no number) -> people nearby are asked to confirm it.
    owner = await people.phone_owner(report.phone)
    if owner is not None:
        report.phone_user_id = str(owner["id"])
        db.commit()
        db.refresh(report)
        admins = await people.admin_ids()
        if admins:
            await notify_users(
                admins,
                f"Ready for review: {report.shop_name}",
                f"'{report.shop_name}' ({report.category}) was suggested with the phone "
                f"number of MicroLink user {owner.get('full_name') or 'on file'}. "
                "It skips the neighbour check -- you can approve it now.",
                kind="crowdsource",
                link={"route": "admin", "id": report.id},
            )
    else:
        await _ask_people_nearby(db, report, current_user.id)

    return _with_counts(db, report)


def _everyone_else(reporter_id: str) -> list[str]:
    """Every active non-admin user except the reporter.

    The fallback when nobody is known to be near a suggested shop (a fresh
    install, or a quiet area), so the suggestion still gets seen.
    """
    try:
        import psycopg2

        conn = psycopg2.connect("postgresql://microlink:microlink@postgres:5432/user_db")
        cur = conn.cursor()
        cur.execute("SELECT id, role FROM users WHERE is_active = true AND id != %s;", (str(reporter_id),))
        rows = cur.fetchall()
        conn.close()
        return [str(r[0]) for r in rows if r[1] != "admin"]
    except Exception as err:
        logger.warning("Error querying users for the shop suggestion notification: %s", err)
        return []


async def _ask_people_nearby(db: Session, report: NewShopReport, reporter_id: str) -> None:
    """Ask people within 5 km to confirm a suggested shop."""
    try:
        near = await nearby_people.find_users_near(report.latitude, report.longitude, db=db)
        recipients = sorted(near - {reporter_id, None, ""})
        if not recipients:
            recipients = _everyone_else(reporter_id)
        if not recipients:
            return
        await notify_users(
            recipients[: nearby_people.MAX_NOTIFIED],
            f"New Shop Nearby: '{report.shop_name}'",
            f"Someone suggested '{report.shop_name}' ({report.category}) at {report.address}. "
            "Tap to confirm if this shop is really there!",
            kind="crowdsource",
            link={"route": "confirm_shops", "id": report.id},
        )
    except Exception:
        logger.exception("Could not ask people near %s", report.id)





@router.get("/shop-reports", response_model=list[NewShopReportResponse])
async def list_shop_reports(
    status_filter: ShopReportStatus | None = Query(default=None, alias="status"),
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    query = db.query(NewShopReport)
    if current_user.role != "admin":
        query = query.filter(NewShopReport.reporter_id == current_user.id)
    elif status_filter is not None:
        query = query.filter(NewShopReport.status == status_filter)

    rows = query.order_by(NewShopReport.created_at.desc()).all()
    if current_user.role == "admin":
        # Fast-tracked suggestions (the phone belongs to a MicroLink user)
        # are ready now, so they come first while pending; newest first within.
        rows.sort(
            key=lambda r: not (r.phone_user_id and r.status == ShopReportStatus.pending)
        )
    # The reviewer needs the tally next to each report, not just the claim.
    return await _name_commenters([_with_counts(db, r) for r in rows])


@router.get("/shop-reports/approved", response_model=list[ApprovedSuggestionResponse])
async def approved_shop_suggestions(
    lat: float | None = Query(default=None, ge=-90, le=90),
    lng: float | None = Query(default=None, ge=-180, le=180),
    limit: int = Query(default=10, ge=1, le=50),
    _current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Shops users suggested that an admin approved -- the Home "User Suggestions" rail.

    Read-only: nothing about suggesting, confirming or approving changes.
    Nearest first when the app sends its location, otherwise the most
    recently approved first.
    """
    reports = (
        db.query(NewShopReport)
        .filter(NewShopReport.status == ShopReportStatus.approved)
        .order_by(NewShopReport.updated_at.desc())
        .all()
    )
    items = []
    for report in reports:
        item = ApprovedSuggestionResponse(
            id=report.id,
            shop_name=report.shop_name,
            category=report.category,
            address=report.address or "",
            latitude=report.latitude,
            longitude=report.longitude,
            description=report.description or "",
            phone=report.phone,
            opening_time=report.opening_time,
            closing_time=report.closing_time,
            has_photo=report.has_photo,
            approved_at=report.updated_at or report.created_at,
        )
        if lat is not None and lng is not None:
            item.distance_km = round(haversine_km(lat, lng, report.latitude, report.longitude), 2)
        items.append(item)
    if lat is not None and lng is not None:
        items.sort(key=lambda item: item.distance_km)
    return items[:limit]


@router.patch("/shop-reports/{report_id}/status", response_model=NewShopReportResponse)
async def update_shop_report_status(
    report_id: str,
    payload: NewShopReportStatusUpdateRequest,
    request: Request,
    _current_user: CurrentUser = Depends(require_admin),
    db: Session = Depends(get_db),
):
    report = db.get(NewShopReport, report_id)
    if report is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Shop report not found")

    # Only a real change of status may move the reporter's trust score.
    # Re-sending the same status (a double-tapped approve button, a retried
    # request) used to award another +2 and another validated_report every
    # time, and flipping approved -> rejected -> approved left the score
    # permanently inflated, because a rejection only takes 1 back.
    previous_status = report.status
    # The same reading answers "was it already approved?", which decides
    # whether the neighbourhood has been told about this shop before.
    was_approved = previous_status == ShopReportStatus.approved
    report.status = ShopReportStatus(payload.status)
    db.commit()
    db.refresh(report)

    if previous_status != report.status:
        trust.adjust_on_moderation(
            db, report.reporter_id, approved=payload.status == "approved"
        )

    await publish_event(
        "shop_report.status_changed", {"report_id": report.id, "status": report.status.value}
    )
    if report.reporter_id:
        approved = payload.status == "approved"
        title = f"Shop Suggestion '{report.shop_name}' Approved" if approved else f"Shop Suggestion '{report.shop_name}' Rejected"
        reason_text = f" Reason: {payload.reason}" if payload.reason else ""
        body = (
            f"Thank you! Your suggested shop '{report.shop_name}' has been verified and added to MicroLink."
            if approved
            else f"An administrator reviewed your suggestion for '{report.shop_name}' and rejected it.{reason_text}"
        )
        await notify_users([report.reporter_id], title, body, kind="report")

    # Tell people nearby that a new shop is on MicroLink -- once, the first
    # time it is approved. See app/nearby_people.py for who counts as nearby.
    if payload.status == "approved" and not was_approved:
        await _notify_people_nearby(db, report, request, _current_user.id)
    return report


async def _notify_people_nearby(
    db: Session, report: NewShopReport, request: Request, admin_id: str
) -> None:
    try:
        commenters = {
            row.user_id
            for row in db.query(ShopReportConfirmation)
            .filter(ShopReportConfirmation.report_id == report.id)
            .all()
        }
        near = await nearby_people.find_users_near(report.latitude, report.longitude, db=db)
        # The suggester already got their own message above.
        recipients = sorted((commenters | near) - {report.reporter_id, admin_id, None, ""})
        if not recipients:
            return
        await notify_users(
            recipients[: nearby_people.MAX_NOTIFIED],
            f"New shop near you: {report.shop_name}",
            f"{report.shop_name} ({report.category}) at {report.address or 'a spot near you'} "
            "was suggested by a MicroLink user and has just been approved. "
            "See it under User Suggestions on Home.",
            kind="crowdsource",
            link={"route": "home"},
        )
    except Exception:
        logger.exception("Could not notify people near %s", report.id)


@router.post("/shop-reports/{report_id}/photo", response_model=NewShopReportResponse)
async def upload_shop_report_photo(
    report_id: str,
    file: UploadFile = File(...),
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Attach a photo of the shop front to a reported shop.

    Sent after the report itself, so a failed upload on a poor connection
    never costs the reporter the report they already filled in.
    """
    report = db.get(NewShopReport, report_id)
    if report is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Shop report not found")
    if report.reporter_id != current_user.id and current_user.role != "admin":
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="You can only add a photo to your own report.",
        )

    raw = await file.read()
    try:
        processed = process_image(raw, file.content_type)
    except ImageRejected as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc))

    report.photo = processed
    report.has_photo = True
    db.commit()
    db.refresh(report)
    return report


@router.get("/shop-reports/{report_id}/photo")
async def get_shop_report_photo(report_id: str, db: Session = Depends(get_db)):
    """Shown to the administrator reviewing the report and to the nearby
    customers who are asked to confirm the shop exists."""
    report = db.get(NewShopReport, report_id)
    if report is None or not report.has_photo or report.photo is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="No photo for this report")
    return Response(
        content=report.photo,
        media_type="image/jpeg",
        headers={"Cache-Control": "public, max-age=86400"},
    )


def _with_counts(db: Session, report: NewShopReport) -> NewShopReportResponse:
    """Attach the confirmation tally the reviewer needs to judge a report."""
    rows = (
        db.query(ShopReportConfirmation)
        .filter(ShopReportConfirmation.report_id == report.id)
        .all()
    )
    total, positive, ratio = conf.tally(rows)
    response = NewShopReportResponse.model_validate(report)
    response.responses = total
    response.confirmations = positive
    response.confirmed_ratio = round(ratio, 3)
    response.is_confirmed = conf.is_confirmed(total, positive)
    response.comments = [c.comment for c in rows if c.comment and c.comment.strip()]
    reply_counts: dict[str, int] = {}
    for reply in (
        db.query(SuggestionCommentReply.comment_id)
        .filter(SuggestionCommentReply.report_id == report.id)
        .all()
    ):
        reply_counts[reply.comment_id] = reply_counts.get(reply.comment_id, 0) + 1
    response.comments_detail = [
        {
            "id": c.id,
            "user_id": c.user_id,
            "comment": c.comment,
            "confirms": c.confirms,
            "created_at": c.created_at.isoformat() if c.created_at else None,
            # Filled in by _name_commenters for the endpoints that show names.
            "author_name": None,
            "reply_count": reply_counts.get(c.id, 0),
        }
        for c in rows
        if c.comment and c.comment.strip()
    ]
    return response


async def _name_commenters(responses: list[NewShopReportResponse]) -> list[NewShopReportResponse]:
    """Put each commenter's full name next to their comment (one lookup for all)."""
    ids = {
        item.get("user_id")
        for response in responses
        for item in response.comments_detail
    }
    ids |= {response.phone_user_id for response in responses if response.phone_user_id}
    names = await people.user_names(i for i in ids if i)
    for response in responses:
        for item in response.comments_detail:
            item["author_name"] = people.name_for(names, item.get("user_id"))
        if response.phone_user_id:
            response.phone_user_name = people.name_for(names, response.phone_user_id)
    return responses


@router.get("/shop-reports/nearby", response_model=list[NewShopReportResponse])
async def nearby_shop_reports(
    lat: float = Query(..., ge=-90, le=90),
    lng: float = Query(..., ge=-180, le=180),
    radius_km: float = Query(default=15.0, gt=0, le=100),
    _current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Pending reports close enough to the caller to be worth asking about.

    The customer's device knows where it is; the server does not store that,
    so the app sends its position and gets back the reports it can sensibly
    be asked to confirm.
    """
    reports = (
        db.query(NewShopReport)
        .filter(NewShopReport.status == ShopReportStatus.pending)
        .all()
    )
    already = {
        c.report_id
        for c in db.query(ShopReportConfirmation)
        .filter(ShopReportConfirmation.user_id == _current_user.id)
        .all()
    }
    available = [
        r for r in reports
        if r.reporter_id != _current_user.id
        and r.id not in already
        # Fast-tracked ones go straight to the admins; neighbours are not asked.
        and not r.phone_user_id
    ]
    near = [
        r for r in available
        if haversine_km(lat, lng, r.latitude, r.longitude) <= radius_km
    ]
    # If no report within radius_km, fallback to all available pending reports so testing works smoothly
    if not near:
        near = available
    near.sort(key=lambda r: haversine_km(lat, lng, r.latitude, r.longitude))
    return await _name_commenters([_with_counts(db, r) for r in near])


@router.post("/shop-reports/{report_id}/confirm", response_model=NewShopReportResponse)
async def confirm_shop_report(
    report_id: str,
    payload: ShopReportConfirmRequest,
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Answer "is this shop really there?" for a reported shop.

    Item 7: only a verified account with enough standing may answer. Before
    this, any signed-in account could vouch for a shop -- including one
    whose own reports admins had just rejected, and a shop owner or driver
    whose application had not been approved.
    """
    if not trust.can_confirm_reports(
        is_verified=current_user.is_verified,
        score=None,
        minimum=settings.min_confirm_trust,
    ):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Your account must be verified before you can confirm shops.",
        )
    score = trust.get_or_create_trust_score(db, current_user.id).score
    if not trust.can_confirm_reports(
        is_verified=current_user.is_verified,
        score=score,
        minimum=settings.min_confirm_trust,
    ):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Your account cannot confirm shops yet.",
        )

    report = db.get(NewShopReport, report_id)
    if report is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Shop report not found")
    if report.reporter_id == current_user.id:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="You cannot confirm a shop you reported yourself.",
        )
    if report.status != ShopReportStatus.pending:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="This report has already been reviewed.",
        )

    before = (
        db.query(ShopReportConfirmation)
        .filter(ShopReportConfirmation.report_id == report_id)
        .all()
    )
    was_confirming = conf.is_confirmed(*conf.tally(before)[:2])

    existing = next((c for c in before if c.user_id == current_user.id), None)
    if existing is not None:
        existing.confirms = payload.confirms
        if payload.comment is not None:
            existing.comment = payload.comment
    else:
        db.add(
            ShopReportConfirmation(
                report_id=report_id,
                user_id=current_user.id,
                confirms=payload.confirms,
                comment=payload.comment,
            )
        )
    db.commit()

    after = (
        db.query(ShopReportConfirmation)
        .filter(ShopReportConfirmation.report_id == report_id)
        .all()
    )
    total, positive, _ = conf.tally(after)

    if conf.just_crossed(total, positive, was_confirming):
        await publish_event(
            "shop_report.confirmed",
            {
                "report_id": report.id,
                "shop_name": report.shop_name,
                "responses": total,
                "confirmations": positive,
            },
        )
        await notify_users(
            [report.reporter_id],
            "Your reported shop was confirmed",
            f"{positive} of {total} people nearby confirmed {report.shop_name}. "
            "An administrator will review it next.",
            kind="crowdsource",
        )

    db.refresh(report)
    return (await _name_commenters([_with_counts(db, report)]))[0]


@router.post("/shop-reports/{report_id}/request-phone")
async def request_shop_phone_from_nearby(
    report_id: str,
    _current_user: CurrentUser = Depends(require_admin),
    db: Session = Depends(get_db),
):
    """Admin requests nearby users to comment the shop owner's phone number."""
    report = db.get(NewShopReport, report_id)
    if report is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Shop report not found")

    rows = (
        db.query(ShopReportConfirmation)
        .filter(ShopReportConfirmation.report_id == report.id)
        .all()
    )
    total, positive, ratio = conf.tally(rows)
    pct = round(ratio * 100, 1) if total > 0 else 0.0

    msg = (
        f"Help complete shop details: '{report.shop_name}' at {report.address} "
        f"was verified by {pct}% of neighbours! "
        "If you know the owner's phone number, please comment it on MicroLink."
    )

    await publish_event(
        "shop_report.request_phone",
        {
            "report_id": report.id,
            "shop_name": report.shop_name,
            "address": report.address,
            "latitude": report.latitude,
            "longitude": report.longitude,
            "message": msg,
        },
    )

    return {
        "status": "ok",
        "message": f"Broadcast notification sent to nearby users for '{report.shop_name}'",
        "detail": msg,
    }


# ---------------------------------------------------------------------------
# Comment threads: who said what about a suggestion, and replies to it
# ---------------------------------------------------------------------------
# Two kinds of top-level comment are shown together, oldest first:
#   "answer"  -- a neighbour's "is it there?" answer that came with a comment
#                (ShopReportConfirmation); replies in SuggestionCommentReply
#   "comment" -- open discussion anyone signed in can start
#                (SuggestionGeneralComment); replies are rows with parent_id
class CommentReplyRequest(BaseModel):
    text: str = Field(min_length=1, max_length=500)


def _iso(moment) -> str | None:
    return moment.isoformat() if moment else None


def _open_report(db: Session, report_id: str) -> NewShopReport:
    report = db.get(NewShopReport, report_id)
    if report is None or report.status == ShopReportStatus.rejected:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Suggestion not found")
    return report


def _clean_text(text: str) -> str:
    cleaned = " ".join(text.split())
    if not cleaned:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY, detail="Write something first."
        )
    return cleaned


@router.get("/shop-reports/{report_id}/comments")
async def suggestion_comments(
    report_id: str,
    _current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Every comment on a suggestion, with full names and replies, oldest first.

    Open to any signed-in user, for pending and approved suggestions.
    """
    _open_report(db, report_id)

    answers = [
        row
        for row in db.query(ShopReportConfirmation)
        .filter(ShopReportConfirmation.report_id == report_id)
        .all()
        if row.comment and row.comment.strip()
    ]
    answer_replies = (
        db.query(SuggestionCommentReply)
        .filter(SuggestionCommentReply.report_id == report_id)
        .order_by(SuggestionCommentReply.created_at.asc())
        .all()
    )
    general = (
        db.query(SuggestionGeneralComment)
        .filter(SuggestionGeneralComment.report_id == report_id)
        .order_by(SuggestionGeneralComment.created_at.asc())
        .all()
    )
    names = await people.user_names(
        [a.user_id for a in answers]
        + [r.user_id for r in answer_replies]
        + [g.user_id for g in general]
    )

    def reply_dict(row, text: str) -> dict:
        return {
            "id": row.id,
            "user_id": row.user_id,
            "author_name": people.name_for(names, row.user_id),
            "text": text,
            "created_at": _iso(row.created_at),
        }

    replies_by_parent: dict[str, list[dict]] = {}
    for reply in answer_replies:
        replies_by_parent.setdefault(reply.comment_id, []).append(reply_dict(reply, reply.text))
    for row in general:
        if row.parent_id:
            replies_by_parent.setdefault(row.parent_id, []).append(reply_dict(row, row.text))

    items = [
        {
            "id": a.id,
            "kind": "answer",
            "user_id": a.user_id,
            "author_name": people.name_for(names, a.user_id),
            "confirms": a.confirms,
            "comment": a.comment,
            "created_at": _iso(a.created_at),
            "replies": replies_by_parent.get(a.id, []),
        }
        for a in answers
    ] + [
        {
            "id": g.id,
            "kind": "comment",
            "user_id": g.user_id,
            "author_name": people.name_for(names, g.user_id),
            "confirms": None,
            "comment": g.text,
            "created_at": _iso(g.created_at),
            "replies": replies_by_parent.get(g.id, []),
        }
        for g in general
        if not g.parent_id
    ]
    items.sort(key=lambda item: item["created_at"] or "")
    return items


@router.post("/shop-reports/{report_id}/comments", status_code=status.HTTP_201_CREATED)
async def add_comment(
    report_id: str,
    payload: CommentReplyRequest,
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Start a comment on a suggestion. Any signed-in user may."""
    _open_report(db, report_id)
    row = SuggestionGeneralComment(
        report_id=report_id, user_id=current_user.id, text=_clean_text(payload.text)
    )
    db.add(row)
    db.commit()
    db.refresh(row)
    names = await people.user_names([current_user.id])
    return {
        "id": row.id,
        "kind": "comment",
        "user_id": row.user_id,
        "author_name": people.name_for(names, row.user_id),
        "confirms": None,
        "comment": row.text,
        "created_at": _iso(row.created_at),
        "replies": [],
    }


@router.post(
    "/shop-reports/{report_id}/comments/{comment_id}/replies",
    status_code=status.HTTP_201_CREATED,
)
async def reply_to_comment(
    report_id: str,
    comment_id: str,
    payload: CommentReplyRequest,
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Reply to any top-level comment. Any signed-in user may join in."""
    _open_report(db, report_id)
    text = _clean_text(payload.text)

    answer = db.get(ShopReportConfirmation, comment_id)
    if answer is not None and answer.report_id == report_id and (answer.comment or "").strip():
        row = SuggestionCommentReply(
            report_id=report_id, comment_id=comment_id, user_id=current_user.id, text=text
        )
    else:
        parent = db.get(SuggestionGeneralComment, comment_id)
        if parent is None or parent.report_id != report_id or parent.parent_id:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Comment not found")
        row = SuggestionGeneralComment(
            report_id=report_id, parent_id=comment_id, user_id=current_user.id, text=text
        )
    db.add(row)
    db.commit()
    db.refresh(row)
    names = await people.user_names([current_user.id])
    return {
        "id": row.id,
        "user_id": row.user_id,
        "author_name": people.name_for(names, row.user_id),
        "text": row.text,
        "created_at": _iso(row.created_at),
    }
