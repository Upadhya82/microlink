from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.orm import Session

from app.auth import CurrentUser, get_current_user, require_admin
from app.database import get_db
from app.event_bus import notify_users, publish_event
from app.models import Complaint, ComplaintStatus
from app.schemas import ComplaintCreateRequest, ComplaintResponse, ComplaintUpdateRequest

router = APIRouter(prefix="/admin", tags=["complaints"])


@router.post("/complaints", response_model=ComplaintResponse, status_code=status.HTTP_201_CREATED)
async def create_complaint(
    payload: ComplaintCreateRequest,
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    complaint = Complaint(
        complainant_id=current_user.id,
        subject=payload.subject,
        description=payload.description,
        category=payload.category,
        status=ComplaintStatus.open,
    )
    db.add(complaint)
    db.commit()
    db.refresh(complaint)
    return complaint


@router.get("/complaints", response_model=list[ComplaintResponse])
async def list_complaints(
    status_filter: str | None = Query(default=None, alias="status"),
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    query = db.query(Complaint)
    if current_user.role != "admin":
        query = query.filter(Complaint.complainant_id == current_user.id)
    if status_filter is not None:
        query = query.filter(Complaint.status == status_filter)
    return query.order_by(Complaint.created_at.desc()).all()


@router.get("/complaints/{complaint_id}", response_model=ComplaintResponse)
async def get_complaint(
    complaint_id: str,
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    complaint = db.get(Complaint, complaint_id)
    if complaint is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Complaint not found")
    if current_user.role != "admin" and complaint.complainant_id != current_user.id:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN, detail="You do not have access to this complaint"
        )
    return complaint


@router.patch("/complaints/{complaint_id}", response_model=ComplaintResponse)
async def update_complaint(
    complaint_id: str,
    payload: ComplaintUpdateRequest,
    current_user: CurrentUser = Depends(require_admin),
    db: Session = Depends(get_db),
):
    complaint = db.get(Complaint, complaint_id)
    if complaint is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Complaint not found")

    complaint.status = payload.status
    if payload.admin_response is not None:
        complaint.admin_response = payload.admin_response
    db.commit()
    db.refresh(complaint)

    await publish_event(
        "complaint.updated", {"complaint_id": complaint.id, "status": complaint.status.value}
    )
    if complaint.complainant_id and payload.status in (ComplaintStatus.resolved, ComplaintStatus.dismissed):
        is_resolved = payload.status == ComplaintStatus.resolved
        title = f"Complaint {complaint.subject}: Resolved" if is_resolved else f"Complaint {complaint.subject}: Dismissed"
        resp_text = f" Admin response: {complaint.admin_response}" if complaint.admin_response else ""
        body = (
            f"Your complaint '{complaint.subject}' was marked as resolved.{resp_text}"
            if is_resolved
            else f"Your complaint '{complaint.subject}' was dismissed by administrator.{resp_text}"
        )
        await notify_users([complaint.complainant_id], title, body, kind="support")
    return complaint
