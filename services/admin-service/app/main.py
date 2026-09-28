import asyncio
import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.activity import handle_event
from app.database import Base, engine
from app.event_bus import subscribe_events
from app.routers import (
    activity_router,
    ads_router,
    analytics_router,
    complaints_router,
    subscriptions_router,
)

logging.basicConfig(level=logging.INFO)


@asynccontextmanager
async def lifespan(app: FastAPI):
    Base.metadata.create_all(bind=engine)
    task = asyncio.create_task(subscribe_events(handle_event))
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


@app.get("/health")
async def health():
    return {"status": "ok", "service": "admin-service"}
