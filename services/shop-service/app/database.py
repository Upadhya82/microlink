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
    # dormant-shop follow-up (REQ-SHOP: a shop closed for a fortnight)
    "ALTER TABLE shops ADD COLUMN IF NOT EXISTS closed_since TIMESTAMPTZ",
    "ALTER TABLE shops ADD COLUMN IF NOT EXISTS inactivity_prompt_at TIMESTAMPTZ",
    "ALTER TABLE shops ADD COLUMN IF NOT EXISTS inactivity_broadcast_at TIMESTAMPTZ",
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
    # shop_photos: real uploaded bytes, not just links (REQ-SHOP-1)
    "ALTER TABLE shop_photos ADD COLUMN IF NOT EXISTS data BYTEA",
    "ALTER TABLE shop_photos ADD COLUMN IF NOT EXISTS content_type VARCHAR(100)",
    "ALTER TABLE shop_photos ADD COLUMN IF NOT EXISTS size_bytes INTEGER",
    # shops: admin verification queue (REQ-ADMIN-1)
    "ALTER TABLE shops ADD COLUMN IF NOT EXISTS is_verified BOOLEAN NOT NULL DEFAULT FALSE",
    "ALTER TABLE shops ADD COLUMN IF NOT EXISTS verified_at TIMESTAMPTZ",
    "ALTER TABLE shops ADD COLUMN IF NOT EXISTS verified_by VARCHAR(36)",
    # shops: item 4 -- the "often delayed" marker, computed by
    # delivery-service and stored here. FALSE until it reports otherwise.
    "ALTER TABLE shops ADD COLUMN IF NOT EXISTS delay_prone BOOLEAN NOT NULL DEFAULT FALSE",
    "ALTER TABLE shops ADD COLUMN IF NOT EXISTS median_pickup_wait_min DOUBLE PRECISION",
    "ALTER TABLE shops ADD COLUMN IF NOT EXISTS timeliness_updated_at TIMESTAMPTZ",
    # shop_ratings: item 3 -- post-delivery feedback becomes a review, so a
    # row records where it came from and which order. Existing rows were all
    # typed on the shop page, which is what the default says.
    "ALTER TABLE shop_ratings ADD COLUMN IF NOT EXISTS source VARCHAR(20) NOT NULL DEFAULT 'shop'",
    "ALTER TABLE shop_ratings ADD COLUMN IF NOT EXISTS order_id VARCHAR(36)",
    # ... and one person may now leave both kinds, so the unique key grows a
    # column. Guarded so re-running neither adds nor drops anything twice.
    "ALTER TABLE shop_ratings DROP CONSTRAINT IF EXISTS uq_shop_ratings_shop_user",
    (
        "DO $$ BEGIN "
        "IF NOT EXISTS (SELECT 1 FROM pg_constraint "
        "WHERE conname = 'uq_shop_ratings_shop_user_source') THEN "
        "ALTER TABLE shop_ratings ADD CONSTRAINT uq_shop_ratings_shop_user_source "
        "UNIQUE (shop_id, user_id, source); "
        "END IF; END $$;"
    ),
    # shops: item 10 -- remembers the one "you are below 5 listed products"
    # warning, so a verified shop's owner is told once, not on every sale.
    "ALTER TABLE shops ADD COLUMN IF NOT EXISTS low_product_warning_at TIMESTAMPTZ",
    # shops: how a shop came to be verified -- "admin" or "community".
    # Older rows were all approved by an admin, which is what the backfill
    # says; NULL would make the admin queue unable to tell them apart.
    "ALTER TABLE shops ADD COLUMN IF NOT EXISTS verified_via VARCHAR(20)",
    "UPDATE shops SET verified_via = 'admin' WHERE is_verified AND verified_via IS NULL",
    # products: discounts and photos (shop-owner storefront)
    "ALTER TABLE products ADD COLUMN IF NOT EXISTS discount_percent INTEGER NOT NULL DEFAULT 0",
    "ALTER TABLE products ADD COLUMN IF NOT EXISTS image BYTEA",
    "ALTER TABLE products ADD COLUMN IF NOT EXISTS has_image BOOLEAN NOT NULL DEFAULT FALSE",
    # products: hidden after the last item sells, until the owner unhides it
    "ALTER TABLE products ADD COLUMN IF NOT EXISTS is_hidden BOOLEAN NOT NULL DEFAULT FALSE",
    "ALTER TABLE products ADD COLUMN IF NOT EXISTS hidden_reason VARCHAR(20)",
    # products: the one "running low" warning has been sent for this drop,
    # so a product that started at 5 or fewer is still warned about once.
    "ALTER TABLE products ADD COLUMN IF NOT EXISTS low_stock_notified BOOLEAN NOT NULL DEFAULT FALSE",
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
