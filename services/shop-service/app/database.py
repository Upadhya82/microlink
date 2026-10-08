import logging

from sqlalchemy import create_engine, text
from sqlalchemy.engine import Engine
from sqlalchemy.orm import DeclarativeBase, sessionmaker

from app.config import settings

logger = logging.getLogger(settings.service_name)

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


# The project has no migration tool: on start-up each service just calls
# `Base.metadata.create_all()`, which creates MISSING TABLES but never adds a
# column to a table that already exists. If you started the stack with an
# older shop-service, your shop_db volume already has `shops` / `products` /
# `shop_alerts` without the new columns, and every query would fail.
#
# These statements add the new columns when they are missing (and fill them
# from the old columns). Every statement is safe to run again and again.
_COLUMN_MIGRATIONS: list[str] = [
    # shops: status (REQ-SHOP-2), delivery flag (REQ-SEARCH-2)
    "ALTER TABLE shops ADD COLUMN IF NOT EXISTS status VARCHAR(20)",
    "ALTER TABLE shops ADD COLUMN IF NOT EXISTS status_reason VARCHAR(200)",
    "ALTER TABLE shops ADD COLUMN IF NOT EXISTS reopen_at TIMESTAMPTZ",
    "ALTER TABLE shops ADD COLUMN IF NOT EXISTS delivery_available BOOLEAN NOT NULL DEFAULT FALSE",
    "UPDATE shops SET status = CASE WHEN is_open THEN 'open' ELSE 'closed' END WHERE status IS NULL",
    # products: three-level stock status (REQ-SHOP-4)
    "ALTER TABLE products ADD COLUMN IF NOT EXISTS stock_status VARCHAR(20)",
    (
        "UPDATE products SET stock_status = CASE "
        "WHEN NOT is_available THEN 'out_of_stock' "
        "WHEN stock_quantity > 0 AND stock_quantity <= 5 THEN 'low_stock' "
        "ELSE 'in_stock' END WHERE stock_status IS NULL"
    ),
    # shop_alerts: alert types and relocation details (REQ-SHOP-3)
    "ALTER TABLE shop_alerts ADD COLUMN IF NOT EXISTS alert_type VARCHAR(20) NOT NULL DEFAULT 'general'",
    "ALTER TABLE shop_alerts ADD COLUMN IF NOT EXISTS new_address VARCHAR(300)",
    "ALTER TABLE shop_alerts ADD COLUMN IF NOT EXISTS starts_at TIMESTAMPTZ",
    "ALTER TABLE shop_alerts ADD COLUMN IF NOT EXISTS ends_at TIMESTAMPTZ",
]


def run_light_migrations(target: Engine | None = None) -> None:
    """Bring an older shop_db up to the current model. Safe to call on every start."""
    bind = target or engine
    if bind.dialect.name != "postgresql":
        return  # ADD COLUMN IF NOT EXISTS is PostgreSQL syntax; other engines build fresh tables.
    for statement in _COLUMN_MIGRATIONS:
        try:
            with bind.begin() as connection:
                connection.execute(text(statement))
        except Exception:
            logger.exception("Migration step failed (continuing): %s", statement)
