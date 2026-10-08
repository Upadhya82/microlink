"""Shop alerts (SRS REQ-SHOP-3): closure, relocation and special-offer notices.

An alert shows on the shop page while it is switched on and inside its dates.
Creating one also publishes a `shop.alert_created` event with the alert type
and the new address (for relocations), so a notification service can push it
to the customers who favourited the shop.
"""

from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import or_
from sqlalchemy.orm import Session

from app.auth import CurrentUser, get_current_user
from app.database import get_db
from app.event_bus import publish_event
from app.models import Shop, ShopAlert
from app.schemas import ShopAlertCreateRequest, ShopAlertResponse

router = APIRouter(prefix="/shops/{shop_id}/alerts", tags=["shop alerts"])


def _get_owned_shop(shop_id: str, current_user: CurrentUser, db: Session) -> Shop:
    shop = db.get(Shop, shop_id)
    if shop is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Shop not found")
    if current_user.role != "admin" and shop.owner_id != current_user.id:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN, detail="You do not own this shop"
        )
    return shop


@router.get("", response_model=list[ShopAlertResponse])
async def list_active_alerts(shop_id: str, db: Session = Depends(get_db)):
    if db.get(Shop, shop_id) is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Shop not found")
    now = datetime.now(timezone.utc)
    return (
        db.query(ShopAlert)
        .filter(
            ShopAlert.shop_id == shop_id,
            ShopAlert.is_active == True,  # noqa: E712
            or_(ShopAlert.starts_at.is_(None), ShopAlert.starts_at <= now),
            or_(ShopAlert.ends_at.is_(None), ShopAlert.ends_at >= now),
        )
        .order_by(ShopAlert.created_at.desc())
        .all()
    )


@router.post("", response_model=ShopAlertResponse, status_code=status.HTTP_201_CREATED)
async def create_alert(
    shop_id: str,
    payload: ShopAlertCreateRequest,
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    _get_owned_shop(shop_id, current_user, db)
    alert = ShopAlert(shop_id=shop_id, **payload.model_dump())
    db.add(alert)
    db.commit()
    db.refresh(alert)

    await publish_event(
        "shop.alert_created",
        {
            "shop_id": shop_id,
            "alert_id": alert.id,
            "alert_type": alert.alert_type,
            "message": alert.message,
            "new_address": alert.new_address,
        },
    )
    return alert


@router.delete("/{alert_id}", status_code=status.HTTP_204_NO_CONTENT)
async def deactivate_alert(
    shop_id: str,
    alert_id: str,
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    _get_owned_shop(shop_id, current_user, db)
    alert = db.get(ShopAlert, alert_id)
    if alert is None or alert.shop_id != shop_id:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Alert not found")
    alert.is_active = False
    db.commit()
