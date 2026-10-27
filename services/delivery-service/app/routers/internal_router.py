"""Internal-only lookups for other MicroLink services (never reachable from apps).

api-gateway blocks /delivery/internal/*, so only services inside the compose
network can call these -- the same arrangement as user-service's
/users/internal/*.
"""

from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from app.database import get_db
from app.models import DeliveryAgentProfile, Order

router = APIRouter(prefix="/delivery/internal", tags=["internal"])

_RECENT_ORDERS = 2000


@router.get("/known-locations")
async def known_locations(db: Session = Depends(get_db)):
    """Where users were last seen, for "tell people nearby" notifications.

    customers .. the address of each customer's newest delivery
    agents ..... each delivery agent's last shared live location

    crowdsource-service turns these into "who is within 5 km of this shop".
    Only coordinates and user ids -- no names, orders or addresses.
    """
    customers: list[dict] = []
    seen: set[str] = set()
    orders = (
        db.query(Order.customer_id, Order.delivery_lat, Order.delivery_lng)
        .order_by(Order.created_at.desc())
        .limit(_RECENT_ORDERS)
        .all()
    )
    for customer_id, lat, lng in orders:
        key = str(customer_id or "")
        if not key or key in seen:
            continue
        seen.add(key)
        if lat is not None and lng is not None:
            customers.append({"user_id": key, "lat": lat, "lng": lng})

    agents = [
        {"user_id": str(row.user_id), "lat": row.current_lat, "lng": row.current_lng}
        for row in db.query(
            DeliveryAgentProfile.user_id,
            DeliveryAgentProfile.current_lat,
            DeliveryAgentProfile.current_lng,
        ).all()
        if row.current_lat is not None and row.current_lng is not None
    ]
    return {"customers": customers, "agents": agents}
