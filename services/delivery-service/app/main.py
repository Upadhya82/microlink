import asyncio
import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.backfill import run_backfill
from app.database import Base, SessionLocal, engine
from app.expiry import run_expiry_loop
from app.timeliness import run_timeliness_loop
from app.migrations import run_startup_migrations
from app.routers import agents_router, internal_router, orders_router, shop_sales_router

logging.basicConfig(level=logging.INFO)


@asynccontextmanager
async def lifespan(app: FastAPI):
    # create_all makes any missing TABLE; run_startup_migrations then adds any
    # missing COLUMN to tables that an older version of this service created.
    Base.metadata.create_all(bind=engine)
    run_startup_migrations(engine)
    # Orders placed before shop_name existed have none; fill them in from
    # shop-service. A background task, not an await: it talks over the
    # network, and nothing about serving requests depends on it finishing.
    backfill = asyncio.create_task(run_backfill(SessionLocal))
    sweeper = asyncio.create_task(run_expiry_loop(SessionLocal))
    # Item 4: work out which shops keep drivers waiting, on a schedule,
    # so the search path never has to ask.
    timeliness = asyncio.create_task(run_timeliness_loop(SessionLocal))
    try:
        yield
    finally:
        for task in (backfill, sweeper, timeliness):
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass


app = FastAPI(title="MicroLink Delivery Service", version="1.1.0", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(agents_router.router)
app.include_router(orders_router.router)
app.include_router(shop_sales_router.router)
app.include_router(internal_router.router)


@app.get("/health")
async def health():
    return {"status": "ok", "service": "delivery-service"}
