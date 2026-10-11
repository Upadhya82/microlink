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


# create_all() adds missing TABLES but never a column to an existing one,
# and this project has no migration tool. Safe to re-run on every start.
_COLUMN_MIGRATIONS: list[str] = [
    "ALTER TABLE users ADD COLUMN IF NOT EXISTS rejection_reason VARCHAR(300)",
    "ALTER TABLE users ADD COLUMN IF NOT EXISTS business_name VARCHAR(120)",
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
            logging.getLogger("user-service").exception(
                "Migration step failed (continuing): %s", statement
            )
