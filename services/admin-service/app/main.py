import asyncio
import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.activity import handle_event
from app.database import Base, engine, run_light_migrations
from app.event_bus import subscribe_events
from app.routers import (
    activity_router,
    ads_router,
    analytics_router,
    complaints_router,
    monitor_router,
    notifications_router,
    subscriptions_router,
    user_insights_router,
)

logging.basicConfig(level=logging.INFO)

logger = logging.getLogger("admin-service")

# How long to wait before re-subscribing after the event bus drops us.
EVENT_BUS_RETRY_SECONDS = 5


async def _run_subscriber() -> None:
    """Keep the activity-log / notification subscriber alive for the life of
    the process.

    Compose starts every container at once, so Redis is often not accepting
    connections yet when this service's lifespan runs. A bare create_task()
    would raise once, die silently, and leave the activity log and the whole
    notification centre permanently empty with nothing in the logs to explain
    it. Retrying forever is the right behaviour here: without the subscriber
    this service has no job to do.
    """
    while True:
        try:
            await subscribe_events(handle_event)
            # A clean return means the pubsub connection closed; reconnect.
            logger.warning("Event bus subscription ended; reconnecting.")
        except asyncio.CancelledError:
            # Shutdown -- let the cancellation propagate.
            raise
        except Exception:
            logger.exception("Event bus subscription failed; retrying.")
        await asyncio.sleep(EVENT_BUS_RETRY_SECONDS)


@asynccontextmanager
async def lifespan(app: FastAPI):
    Base.metadata.create_all(bind=engine)
    run_light_migrations(engine)
    task = asyncio.create_task(_run_subscriber())
    yield
    task.cancel()


app = FastAPI(title="MicroLink Admin Service", version="1.0.0", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(activity_router.router)
app.include_router(complaints_router.router)
app.include_router(subscriptions_router.router)
app.include_router(analytics_router.router)
app.include_router(ads_router.router)
app.include_router(notifications_router.router)
app.include_router(monitor_router.router)
app.include_router(user_insights_router.router)


@app.get("/health")
async def health():
    return {"status": "ok", "service": "admin-service"}
