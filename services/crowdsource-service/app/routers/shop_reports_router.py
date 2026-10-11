from fastapi import APIRouter, Depends, File, HTTPException, Query, Response, UploadFile, status
from sqlalchemy.orm import Session

from app import confirmations as conf
from app import trust
from app.auth import CurrentUser, get_current_user, require_admin
from app.database import get_db
from app.event_bus import notify_users, publish_event
from app.geo import haversine_km
from app.images import ImageRejected, process_image
from app.models import NewShopReport, ShopReportConfirmation, ShopReportStatus
from app.schemas import (
    NewShopReportCreateRequest,
    NewShopReportResponse,
    NewShopReportStatusUpdateRequest,
    ShopReportConfirmRequest,
)

router = APIRouter(prefix="/crowdsource", tags=["shop-reports"])


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
    return report


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
    # The reviewer needs the tally next to each report, not just the claim.
    return [_with_counts(db, r) for r in rows]


@router.patch("/shop-reports/{report_id}/status", response_model=NewShopReportResponse)
async def update_shop_report_status(
    report_id: str,
    payload: NewShopReportStatusUpdateRequest,
    _current_user: CurrentUser = Depends(require_admin),
    db: Session = Depends(get_db),
):
    report = db.get(NewShopReport, report_id)
    if report is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Shop report not found")

    report.status = ShopReportStatus(payload.status)
    db.commit()
    db.refresh(report)

    trust.adjust_on_moderation(db, report.reporter_id, approved=payload.status == "approved")

    await publish_event(
        "shop_report.status_changed", {"report_id": report.id, "status": report.status.value}
    )
    return report


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
    return response


@router.get("/shop-reports/nearby", response_model=list[NewShopReportResponse])
async def nearby_shop_reports(
    lat: float = Query(..., ge=-90, le=90),
    lng: float = Query(..., ge=-180, le=180),
    radius_km: float = Query(default=3.0, gt=0, le=50),
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
    near = [
        r for r in reports
        if haversine_km(lat, lng, r.latitude, r.longitude) <= radius_km
    ]
    # Someone cannot usefully confirm their own report, and should not be
    # asked twice about the same one.
    already = {
        c.report_id
        for c in db.query(ShopReportConfirmation)
        .filter(ShopReportConfirmation.user_id == _current_user.id)
        .all()
    }
    near = [
        r for r in near
        if r.reporter_id != _current_user.id and r.id not in already
    ]
    near.sort(key=lambda r: haversine_km(lat, lng, r.latitude, r.longitude))
    return [_with_counts(db, r) for r in near]


@router.post("/shop-reports/{report_id}/confirm", response_model=NewShopReportResponse)
async def confirm_shop_report(
    report_id: str,
    payload: ShopReportConfirmRequest,
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Answer "is this shop really there?" for a reported shop.

    Once enough of the answers are positive the administrator is notified
    once, so the review queue holds reports the neighbourhood has already
    vouched for rather than every claim anyone made.
    """
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
    else:
        db.add(
            ShopReportConfirmation(
                report_id=report_id,
                user_id=current_user.id,
                confirms=payload.confirms,
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
    return _with_counts(db, report)
