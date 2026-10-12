import asyncio
import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.database import Base, SessionLocal, engine
from app.expiry import run_expiry_loop
from app.migrations import run_startup_migrations
from app.routers import agents_router, orders_router

logging.basicConfig(level=logging.INFO)


@asynccontextmanager
async def lifespan(app: FastAPI):
    # create_all makes any missing TABLE; run_startup_migrations then adds any
    # missing COLUMN to tables that an older version of this service created.
    Base.metadata.create_all(bind=engine)
    run_startup_migrations(engine)
    sweeper = asyncio.create_task(run_expiry_loop(SessionLocal))
    try:
        yield
    finally:
        sweeper.cancel()
        try:
            await sweeper
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


@app.get("/health")
async def health():
    return {"status": "ok", "service": "delivery-service"}
