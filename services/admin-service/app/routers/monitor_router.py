"""Real-time system activity monitor (REQ-ADMIN-4).

Shows what the platform is doing right now: who is active, how busy it is,
how the host is holding up, what has recently gone wrong, and which of the
other six services are actually answering.
"""

import asyncio
from datetime import datetime, timedelta, timezone

import httpx
from fastapi import APIRouter, Depends
from sqlalchemy import func
from sqlalchemy.orm import Session

from app.auth import CurrentUser, require_admin
from app.config import settings
from app.database import get_db
from app.metrics import (
    ACTIVE_WINDOW_MINUTES,
    active_users,
    count_orders_since,
    is_error_event,
    read_cpu_and_memory,
)
from app.models import ActivityLog
from app.schemas import MonitorResponse, ServiceHealth

router = APIRouter(prefix="/admin", tags=["monitor"])

# Checked in parallel. Short timeout on purpose: this is a liveness probe for
# a dashboard, and a hung service should read as "down" quickly rather than
# making the admin wait.
_SERVICES: dict[str, str] = {
    "user-service": "http://user-service:8000/health",
    "shop-service": "http://shop-service:8000/health",
    "recommendation-service": "http://recommendation-service:8000/health",
    "navigation-service": "http://navigation-service:8000/health",
    "delivery-service": "http://delivery-service:8000/health",
    "crowdsource-service": "http://crowdsource-service:8000/health",
}

_PROBE_TIMEOUT_SECONDS = 2.0


async def _probe(client: httpx.AsyncClient, name: str, url: str) -> ServiceHealth:
    started = asyncio.get_event_loop().time()
    try:
        response = await client.get(url)
        latency_ms = round((asyncio.get_event_loop().time() - started) * 1000)
        return ServiceHealth(
            name=name,
            healthy=response.status_code == 200,
            status_code=response.status_code,
            latency_ms=latency_ms,
        )
    except Exception:
        # Unreachable, refused, timed out -- all the same to the dashboard.
        return ServiceHealth(name=name, healthy=False, status_code=None, latency_ms=None)


@router.get("/monitor", response_model=MonitorResponse)
async def get_monitor(
    _admin: CurrentUser = Depends(require_admin),
    db: Session = Depends(get_db),
):
    now = datetime.now(timezone.utc)
    hour_ago = now - timedelta(hours=1)
    window_start = now - timedelta(minutes=ACTIVE_WINDOW_MINUTES)

    recent = (
        db.query(ActivityLog)
        .filter(ActivityLog.created_at >= window_start)
        .order_by(ActivityLog.created_at.desc())
        .limit(2000)
        .all()
    )

    orders_last_hour = count_orders_since(
        db.query(ActivityLog)
        .filter(ActivityLog.event_type == "order.created", ActivityLog.created_at >= hour_ago)
        .all(),
        hour_ago,
    )

    events_last_hour = (
        db.query(func.count(ActivityLog.id))
        .filter(ActivityLog.created_at >= hour_ago)
        .scalar()
        or 0
    )

    error_rows = (
        db.query(ActivityLog)
        .order_by(ActivityLog.created_at.desc())
        .limit(200)
        .all()
    )
    recent_errors = [
        {
            "event_type": row.event_type,
            "source_service": row.source_service,
            "created_at": row.created_at.isoformat() if row.created_at else None,
        }
        for row in error_rows
        if is_error_event(row.event_type)
    ][:20]

    async with httpx.AsyncClient(timeout=_PROBE_TIMEOUT_SECONDS) as client:
        services = await asyncio.gather(
            *(_probe(client, name, url) for name, url in _SERVICES.items())
        )

    host = read_cpu_and_memory()

    return MonitorResponse(
        generated_at=now,
        active_users=active_users(recent, now=now),
        active_window_minutes=ACTIVE_WINDOW_MINUTES,
        # Per minute rather than per hour: "0.4 orders/min" is the shape an
        # operator watches, and it stays readable at low volume.
        orders_per_minute=round(orders_last_hour / 60, 2),
        orders_last_hour=orders_last_hour,
        events_last_hour=events_last_hour,
        load_average_1m=host["load_average_1m"],
        cpu_count=host["cpu_count"],
        memory_used_percent=host["memory_used_percent"],
        recent_errors=recent_errors,
        services=list(services),
        service_name=settings.service_name,
    )
