from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.orm import Session

from app import trust
from app.auth import CurrentUser, get_current_user, require_admin
from app.database import get_db
from app.event_bus import publish_event
from app.models import NewShopReport, ShopReportStatus
from app.schemas import (
    NewShopReportCreateRequest,
    NewShopReportResponse,
    NewShopReportStatusUpdateRequest,
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

    return query.order_by(NewShopReport.created_at.desc()).all()


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
