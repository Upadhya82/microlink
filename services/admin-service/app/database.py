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


# create_all() creates missing tables but never adds a column to a table
# that already exists, so each new column needs a statement here. Written to
# be safe to run on every start.
_COLUMN_MIGRATIONS: list[str] = [
    # advertisers upload a banner instead of pasting a link
    "ALTER TABLE advertisements ADD COLUMN IF NOT EXISTS image BYTEA",
    "ALTER TABLE advertisements ADD COLUMN IF NOT EXISTS has_image BOOLEAN NOT NULL DEFAULT FALSE",
    "ALTER TABLE advertisements ALTER COLUMN image_url DROP NOT NULL",
    "ALTER TABLE advertisements ALTER COLUMN image_url SET DEFAULT ''",
]


def run_light_migrations(target=None) -> None:
    from sqlalchemy import text

    bind = target or engine
    if bind.dialect.name != "postgresql":
        return  # ADD COLUMN IF NOT EXISTS is PostgreSQL syntax.
    for statement in _COLUMN_MIGRATIONS:
        try:
            with bind.begin() as connection:
                connection.execute(text(statement))
        except Exception:
            logging.getLogger("admin-service").exception(
                "Migration step failed (continuing): %s", statement
            )
