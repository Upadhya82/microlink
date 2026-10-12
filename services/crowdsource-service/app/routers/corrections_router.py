"""Shop correction suggestions (REQ-CROWD-5).

Any logged-in user can suggest a fix to a shop's details. Corrections go
into a moderation queue; on approval a `shop_correction.approved` event is
published and shop-service applies the whitelisted fields.

Corrections live here rather than in shop-service because moderation is
this service's job -- the same queue, reviewer and trust rules as new-shop
and road reports.
"""

import json
import uuid

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.orm import Session

from app.auth import CurrentUser, get_current_user, require_admin
from app.database import get_db
from app.event_bus import notify_users, publish_event
from app.models import ShopCorrectionReport, ShopReportStatus
from app.schemas import (
    ShopCorrectionCreateRequest,
    ShopCorrectionResponse,
    ShopCorrectionStatusRequest,
)

router = APIRouter(prefix="/crowdsource", tags=["shop corrections"])


def _to_response(report: ShopCorrectionReport) -> ShopCorrectionResponse:
    try:
        changes = json.loads(report.changes or "{}")
    except (TypeError, ValueError):
        changes = {}
    return ShopCorrectionResponse(
        id=report.id,
        reporter_id=report.reporter_id,
        shop_id=report.shop_id,
        shop_name=report.shop_name,
        changes=changes if isinstance(changes, dict) else {},
        note=report.note,
        status=report.status,
        created_at=report.created_at,
        updated_at=report.updated_at,
    )


@router.post(
    "/shop-corrections",
    response_model=ShopCorrectionResponse,
    status_code=status.HTTP_201_CREATED,
)
async def create_correction(
    payload: ShopCorrectionCreateRequest,
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    changes = payload.non_empty_changes()
    if not changes:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Suggest at least one change (name, address, phone or opening hours).",
        )

    report = ShopCorrectionReport(
        reporter_id=current_user.id,
        shop_id=payload.shop_id,
        shop_name=payload.shop_name or "",
        changes=json.dumps(changes),
        note=payload.note,
        status=ShopReportStatus.pending,
    )
    db.add(report)
    db.commit()
    db.refresh(report)

    await publish_event(
        "shop_correction.submitted",
        {"report_id": report.id, "shop_id": report.shop_id, "reporter_id": report.reporter_id},
    )
    return _to_response(report)


@router.get("/shop-corrections", response_model=list[ShopCorrectionResponse])
async def list_corrections(
    status_filter: str | None = Query(default=None, alias="status"),
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    query = db.query(ShopCorrectionReport)
    # Admins moderate everything; everyone else only sees what they sent in.
    if current_user.role != "admin":
        query = query.filter(ShopCorrectionReport.reporter_id == current_user.id)
    if status_filter:
        query = query.filter(ShopCorrectionReport.status == status_filter)
    rows = query.order_by(ShopCorrectionReport.created_at.desc()).all()
    return [_to_response(row) for row in rows]


@router.patch("/shop-corrections/{report_id}/status", response_model=ShopCorrectionResponse)
async def update_correction_status(
    report_id: str,
    payload: ShopCorrectionStatusRequest,
    _admin: CurrentUser = Depends(require_admin),
    db: Session = Depends(get_db),
):
    try:
        uuid.UUID(report_id)
    except ValueError:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Correction not found")

    report = db.get(ShopCorrectionReport, report_id)
    if report is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Correction not found")

    report.status = ShopReportStatus(payload.status)
    db.commit()
    db.refresh(report)

    try:
        changes = json.loads(report.changes or "{}")
    except (TypeError, ValueError):
        changes = {}

    if report.status == ShopReportStatus.approved:
        await publish_event(
            "shop_correction.approved",
            {
                "report_id": report.id,
                "shop_id": report.shop_id,
                "changes": changes if isinstance(changes, dict) else {},
            },
        )

    approved = report.status == ShopReportStatus.approved
    await notify_users(
        [report.reporter_id],
        "Your suggested correction was applied" if approved else "Your suggested correction was reviewed",
        (
            f"Thanks -- the details you sent for {report.shop_name or 'a shop'} are now live."
            if approved
            else f"An admin reviewed your suggestion for {report.shop_name or 'a shop'} and did not apply it."
        ),
        kind="report",
        link={"route": "shop", "id": report.shop_id},
    )
    return _to_response(report)
