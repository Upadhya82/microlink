from contextlib import asynccontextmanager
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.database import Base, engine, run_light_migrations
from app.routers import auth_router, documents_router, users_router


@asynccontextmanager
async def lifespan(app: FastAPI):
    Base.metadata.create_all(bind=engine)
    run_light_migrations(engine)
    yield


app = FastAPI(
    title="MicroLink User Service",
    version="1.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(auth_router.router)
# Before users_router: its /users/documents/... and /users/me/documents paths
# must be matched before /users/{user_id} swallows the literal segment.
app.include_router(documents_router.router)
app.include_router(users_router.router)


@app.get("/health")
def health():
    return {"status": "ok", "service": "user-service"}
