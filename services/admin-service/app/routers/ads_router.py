from datetime import datetime, timezone

from fastapi import APIRouter, Depends, File, HTTPException, Query, Response, UploadFile, status
from sqlalchemy import or_
from sqlalchemy.orm import Session

from app.auth import CurrentUser, get_current_user, require_admin
from app.database import get_db
from app.event_bus import notify_users, publish_event
from app.images import ImageRejected, process_image
from app.models import AdStatus, Advertisement
from app.schemas import AdCreateRequest, AdResponse, AdReviewUpdateRequest, AdStatusUpdateRequest

router = APIRouter(prefix="/ads", tags=["ads"])


@router.post("", response_model=AdResponse, status_code=status.HTTP_201_CREATED)
async def submit_ad(
    payload: AdCreateRequest,
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """A shop owner (or anyone) submits an ad for a shop or an outside
    company to run on the customer Home screen. Always starts pending --
    only an admin can approve it (see `update_ad_status` below)."""
    ad = Advertisement(
        submitted_by_user_id=current_user.id,
        status=AdStatus.pending,
        **payload.model_dump(),
    )
    db.add(ad)
    db.commit()
    db.refresh(ad)

    await publish_event(
        "ad.submitted",
        {"ad_id": ad.id, "submitted_by_user_id": ad.submitted_by_user_id, "advertiser_name": ad.advertiser_name},
    )
    return ad


@router.get("", response_model=list[AdResponse])
async def list_ads(
    status_filter: str | None = Query(default=None, alias="status"),
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Admin sees every submission (for the moderation queue); anyone else
    only sees their own submissions and their review status."""
    query = db.query(Advertisement)
    if current_user.role != "admin":
        query = query.filter(Advertisement.submitted_by_user_id == current_user.id)
    if status_filter is not None:
        query = query.filter(Advertisement.status == status_filter)
    return query.order_by(Advertisement.created_at.desc()).all()


@router.get("/active", response_model=list[AdResponse])
async def list_active_ads(
    _current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """What the customer Home screen banner actually renders: approved ads
    whose date window (if any) covers right now."""
    now = datetime.now(timezone.utc)
    query = db.query(Advertisement).filter(Advertisement.status == AdStatus.approved)
    query = query.filter(
        or_(Advertisement.start_date.is_(None), Advertisement.start_date <= now)
    )
    query = query.filter(or_(Advertisement.end_date.is_(None), Advertisement.end_date >= now))
    return query.order_by(Advertisement.created_at.desc()).all()


@router.patch("/{ad_id}", response_model=AdResponse)
async def update_ad(
    ad_id: str,
    payload: AdReviewUpdateRequest,
    current_user: CurrentUser = Depends(require_admin),
    db: Session = Depends(get_db),
):
    """Admin edits an ad's content (copy, image, date window) to match the
    advertiser's brand before -- or instead of -- approving it as-submitted."""
    ad = db.get(Advertisement, ad_id)
    if ad is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Ad not found")

    for field, value in payload.model_dump(exclude_unset=True).items():
        setattr(ad, field, value)
    db.commit()
    db.refresh(ad)
    return ad


@router.patch("/{ad_id}/status", response_model=AdResponse)
async def update_ad_status(
    ad_id: str,
    payload: AdStatusUpdateRequest,
    current_user: CurrentUser = Depends(require_admin),
    db: Session = Depends(get_db),
):
    ad = db.get(Advertisement, ad_id)
    if ad is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Ad not found")

    ad.status = AdStatus(payload.status)
    ad.reviewed_by = current_user.id
    db.commit()
    db.refresh(ad)

    await publish_event("ad.status_changed", {"ad_id": ad.id, "status": ad.status.value})
    if ad.submitted_by_user_id:
        approved = ad.status == AdStatus.approved
        title = f"Advertisement '{ad.title}' Approved" if approved else f"Advertisement '{ad.title}' Rejected"
        reason_text = f" Reason: {payload.reason}" if payload.reason else ""
        body = (
            f"Your advertisement banner '{ad.title}' has been approved and is now live."
            if approved
            else f"Your advertisement banner '{ad.title}' was rejected by administrator.{reason_text}"
        )
        await notify_users([ad.submitted_by_user_id], title, body, kind="ad")
    return ad


@router.delete("/{ad_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_ad(
    ad_id: str,
    _current_user: CurrentUser = Depends(require_admin),
    db: Session = Depends(get_db),
):
    ad = db.get(Advertisement, ad_id)
    if ad is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Ad not found")
    db.delete(ad)
    db.commit()


@router.post("/{ad_id}/image", response_model=AdResponse)
async def upload_ad_image(
    ad_id: str,
    file: UploadFile = File(...),
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Upload the banner for an advertisement.

    A separate call from the submission, so a slow upload cannot lose the ad
    copy that was already typed in.
    """
    ad = db.get(Advertisement, ad_id)
    if ad is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Ad not found")
    if ad.submitted_by_user_id != current_user.id and current_user.role != "admin":
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="You can only change the image of an ad you submitted.",
        )

    raw = await file.read()
    try:
        processed = process_image(raw, file.content_type)
    except ImageRejected as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc))

    ad.image = processed
    ad.has_image = True
    db.commit()
    db.refresh(ad)
    return ad


@router.get("/{ad_id}/image")
async def get_ad_image(ad_id: str, db: Session = Depends(get_db)):
    """Public: approved banners are shown on every customer Home screen."""
    ad = db.get(Advertisement, ad_id)
    if ad is None or not ad.has_image or ad.image is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="No image for this ad")
    return Response(
        content=ad.image,
        media_type="image/jpeg",
        headers={"Cache-Control": "public, max-age=86400"},
    )
