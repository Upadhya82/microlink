from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.orm import Session

from app import trust
from app.auth import CurrentUser, get_current_user, require_admin
from app.database import get_db
from app.event_bus import publish_event
from app.geo import haversine_km
from app.models import RoadConditionReport, RoadConditionType, RoadReportStatus
from app.schemas import (
    RoadConditionReportCreateRequest,
    RoadConditionReportResponse,
    RoadConditionReportStatusUpdateRequest,
)

router = APIRouter(prefix="/crowdsource", tags=["road-reports"])


@router.post(
    "/road-reports",
    response_model=RoadConditionReportResponse,
    status_code=status.HTTP_201_CREATED,
)
async def create_road_report(
    payload: RoadConditionReportCreateRequest,
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    report = RoadConditionReport(reporter_id=current_user.id, **payload.model_dump())
    db.add(report)
    db.commit()
    db.refresh(report)

    trust.record_report(db, current_user.id)

    await publish_event(
        "road_report.created",
        {
            "report_id": report.id,
            "reporter_id": report.reporter_id,
            "condition_type": report.condition_type.value,
            "latitude": report.latitude,
            "longitude": report.longitude,
        },
    )
    return report


@router.get("/road-reports", response_model=list[RoadConditionReportResponse])
async def list_road_reports(
    status_filter: RoadReportStatus | None = Query(default=None, alias="status"),
    condition_type: RoadConditionType | None = Query(default=None),
    lat: float | None = Query(default=None, ge=-90, le=90),
    lng: float | None = Query(default=None, ge=-180, le=180),
    radius_km: float = Query(default=10, gt=0, le=200),
    db: Session = Depends(get_db),
):
    query = db.query(RoadConditionReport)
    if status_filter is not None:
        query = query.filter(RoadConditionReport.status == status_filter)
    if condition_type is not None:
        query = query.filter(RoadConditionReport.condition_type == condition_type)

    reports = query.order_by(RoadConditionReport.created_at.desc()).limit(500).all()

    results: list[RoadConditionReportResponse] = []
    for report in reports:
        response = RoadConditionReportResponse.model_validate(report)
        if lat is not None and lng is not None:
            distance = haversine_km(lat, lng, report.latitude, report.longitude)
            if distance > radius_km:
                continue
            response.distance_km = round(distance, 2)
        results.append(response)

    if lat is not None and lng is not None:
        results.sort(key=lambda r: r.distance_km if r.distance_km is not None else 0)

    return results


@router.patch("/road-reports/{report_id}/status", response_model=RoadConditionReportResponse)
async def update_road_report_status(
    report_id: str,
    payload: RoadConditionReportStatusUpdateRequest,
    _current_user: CurrentUser = Depends(require_admin),
    db: Session = Depends(get_db),
):
    report = db.get(RoadConditionReport, report_id)
    if report is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Road report not found")

    report.status = RoadReportStatus(payload.status)
    db.commit()
    db.refresh(report)

    trust.adjust_on_moderation(
        db, report.reporter_id, approved=payload.status in ("verified", "resolved")
    )

    await publish_event(
        "road_report.status_changed", {"report_id": report.id, "status": report.status.value}
    )
    return report
