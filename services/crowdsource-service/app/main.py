import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.database import Base, engine, run_light_migrations
from app.routers import (
    corrections_router,
    feedback_router,
    road_reports_router,
    shop_reports_router,
    trust_router,
)

logging.basicConfig(level=logging.INFO)


@asynccontextmanager
async def lifespan(app: FastAPI):
    Base.metadata.create_all(bind=engine)
    run_light_migrations(engine)
    yield


app = FastAPI(title="MicroLink Crowdsource Service", version="1.0.0", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(feedback_router.router)
app.include_router(road_reports_router.router)
app.include_router(shop_reports_router.router)
app.include_router(trust_router.router)
app.include_router(corrections_router.router)


@app.get("/health")
async def health():
    return {"status": "ok", "service": "crowdsource-service"}
