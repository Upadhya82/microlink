import logging
from sqlalchemy import create_engine
from sqlalchemy.orm import DeclarativeBase, sessionmaker

from app.config import settings

engine = create_engine(settings.database_url, pool_pre_ping=True)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)


class Base(DeclarativeBase):
    pass


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


# No migration tool in this project: create_all() adds missing TABLES but
# never a column to a table that already exists. These statements bring an
# older crowdsource_db up to the current model and are safe to re-run.
_COLUMN_MIGRATIONS: list[str] = [
    # REQ-CROWD-4: optional photo on a road report
    "ALTER TABLE road_condition_reports ADD COLUMN IF NOT EXISTS photo BYTEA",
    "ALTER TABLE road_condition_reports ADD COLUMN IF NOT EXISTS has_photo BOOLEAN NOT NULL DEFAULT FALSE",
    # shop trust scoring needs to know which shop the feedback was about
    "ALTER TABLE order_feedback ADD COLUMN IF NOT EXISTS shop_id VARCHAR(36)",
    # idempotency when a shop_report.approved event is redelivered
    "ALTER TABLE new_shop_reports ADD COLUMN IF NOT EXISTS created_shop_id VARCHAR(36)",
    # photo of the reported shop front
    "ALTER TABLE new_shop_reports ADD COLUMN IF NOT EXISTS photo BYTEA",
    "ALTER TABLE new_shop_reports ADD COLUMN IF NOT EXISTS has_photo BOOLEAN NOT NULL DEFAULT FALSE",
    # fast track: the suggested phone number belongs to a MicroLink account
    "ALTER TABLE new_shop_reports ADD COLUMN IF NOT EXISTS phone_user_id VARCHAR(36)",
]


def run_light_migrations(target=None) -> None:
    """Safe to call on every start."""
    from sqlalchemy import text

    bind = target or engine
    if bind.dialect.name != "postgresql":
        return  # ADD COLUMN IF NOT EXISTS is PostgreSQL syntax.
    for statement in _COLUMN_MIGRATIONS:
        try:
            with bind.begin() as connection:
                connection.execute(text(statement))
        except Exception:
            logging.getLogger("crowdsource-service").exception(
                "Migration step failed (continuing): %s", statement
            )
