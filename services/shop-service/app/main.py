import asyncio
import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.database import Base, SessionLocal, engine, run_light_migrations
from app.dormant import run_dormant_loop
from app.event_bus import subscribe_events
from app.feedback_reviews import handle_event as handle_feedback_event
from app.routers import (
    alerts_router,
    analytics_router,
    products_router,
    reviews_router,
    shops_router,
    stock_router,
)

logging.basicConfig(level=logging.INFO)


@asynccontextmanager
async def lifespan(app: FastAPI):
    # 1. create any missing tables (shop_photos and shop_ratings are new)
    Base.metadata.create_all(bind=engine)
    # 2. add the new columns to tables that already exist in an older shop_db
    run_light_migrations(engine)
    # 3. follow up on shops that have been closed for a fortnight
    sweeper = asyncio.create_task(run_dormant_loop(SessionLocal))
    # 4. item 3: a customer's post-delivery feedback becomes a review here
    feedback_listener = asyncio.create_task(
        subscribe_events(lambda envelope: handle_feedback_event(envelope, SessionLocal))
    )
    try:
        yield
    finally:
        for task in (sweeper, feedback_listener):
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass


app = FastAPI(title="MicroLink Shop Service", version="2.0.0", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# shops_router first: it declares /shops/owner/me, /shops/external and
# /shops/landmark, which must be matched before /shops/{shop_id}.
app.include_router(shops_router.router)
app.include_router(alerts_router.router)
app.include_router(products_router.router)
app.include_router(analytics_router.router)
app.include_router(reviews_router.router)
# Internal, called by delivery-service only; the gateway blocks these paths.
app.include_router(stock_router.router)


@app.get("/health")
async def health():
    return {"status": "ok", "service": "shop-service"}
