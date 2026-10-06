import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.database import Base, engine, run_light_migrations
from app.routers import (
    alerts_router,
    analytics_router,
    products_router,
    reviews_router,
    shops_router,
)

logging.basicConfig(level=logging.INFO)


@asynccontextmanager
async def lifespan(app: FastAPI):
    # 1. create any missing tables (shop_photos and shop_ratings are new)
    Base.metadata.create_all(bind=engine)
    # 2. add the new columns to tables that already exist in an older shop_db
    run_light_migrations(engine)
    yield


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


@app.get("/health")
async def health():
    return {"status": "ok", "service": "shop-service"}
