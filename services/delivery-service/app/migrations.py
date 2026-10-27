"""Tiny, repeatable startup migrations.

This project has no Alembic. `Base.metadata.create_all()` creates MISSING
TABLES but never adds new COLUMNS to a table that already exists. So if a
teammate already ran the stack with the old delivery_db, the new columns below
would be missing and the service would crash. These `IF NOT EXISTS` statements
add them safely, and do nothing on a fresh database.
"""

import logging

from sqlalchemy import text
from sqlalchemy.engine import Engine

logger = logging.getLogger("delivery-service.migrations")

_TS = "TIMESTAMP WITH TIME ZONE"

_STATEMENTS = [
    # delivery_agent_profiles
    "ALTER TABLE delivery_agent_profiles ADD COLUMN IF NOT EXISTS phone VARCHAR(20)",
    "ALTER TABLE delivery_agent_profiles ADD COLUMN IF NOT EXISTS id_document_url VARCHAR(500)",
    "ALTER TABLE delivery_agent_profiles ADD COLUMN IF NOT EXISTS license_photo_url VARCHAR(500)",
    "ALTER TABLE delivery_agent_profiles ADD COLUMN IF NOT EXISTS police_report_url VARCHAR(500)",
    "ALTER TABLE delivery_agent_profiles ADD COLUMN IF NOT EXISTS on_time_deliveries INTEGER NOT NULL DEFAULT 0",
    "ALTER TABLE delivery_agent_profiles ADD COLUMN IF NOT EXISTS application_status VARCHAR(20) NOT NULL DEFAULT 'pending'",
    "ALTER TABLE delivery_agent_profiles ADD COLUMN IF NOT EXISTS review_note VARCHAR(300)",
    f"ALTER TABLE delivery_agent_profiles ADD COLUMN IF NOT EXISTS reviewed_at {_TS}",
    # item 13: when the driver last shared their position. NULL on older
    # rows, which the app reads as "never shared".
    f"ALTER TABLE delivery_agent_profiles ADD COLUMN IF NOT EXISTS location_updated_at {_TS}",
    # orders
    # Handover codes: the shop owner reads one to the agent at pickup, the
    # customer reads the other at the door.
    "ALTER TABLE orders ADD COLUMN IF NOT EXISTS pickup_code VARCHAR(8)",
    "ALTER TABLE orders ADD COLUMN IF NOT EXISTS delivery_code VARCHAR(8)",
    "ALTER TABLE orders ADD COLUMN IF NOT EXISTS pickup_address VARCHAR(300)",
    "ALTER TABLE orders ADD COLUMN IF NOT EXISTS pickup_lat DOUBLE PRECISION",
    "ALTER TABLE orders ADD COLUMN IF NOT EXISTS pickup_lng DOUBLE PRECISION",
    "ALTER TABLE orders ADD COLUMN IF NOT EXISTS item_description VARCHAR(200)",
    f"ALTER TABLE orders ADD COLUMN IF NOT EXISTS accepted_at {_TS}",
    # An agent handed the order back to the pool. NULL on orders that
    # were never released, which is also what the wait-time rule reads
    # as "still waiting since it was created".
    # The shop's name, copied onto the order when it is placed, so the
    # customer's own order list can say where they ordered from.
    "ALTER TABLE orders ADD COLUMN IF NOT EXISTS shop_name VARCHAR(150)",
    f"ALTER TABLE orders ADD COLUMN IF NOT EXISTS reopened_at {_TS}",
    # When the customer was told their order was still waiting for an agent.
    f"ALTER TABLE orders ADD COLUMN IF NOT EXISTS unclaimed_notice_at {_TS}",
    f"ALTER TABLE orders ADD COLUMN IF NOT EXISTS picked_up_at {_TS}",
    f"ALTER TABLE orders ADD COLUMN IF NOT EXISTS delivered_at {_TS}",
    f"ALTER TABLE orders ADD COLUMN IF NOT EXISTS promised_by {_TS}",
    "ALTER TABLE orders ADD COLUMN IF NOT EXISTS agent_eta_minutes INTEGER",
    f"ALTER TABLE orders ADD COLUMN IF NOT EXISTS agent_notified_at {_TS}",
    "ALTER TABLE orders ADD COLUMN IF NOT EXISTS rating INTEGER",
    "ALTER TABLE orders ADD COLUMN IF NOT EXISTS rating_comment VARCHAR(300)",
    f"ALTER TABLE orders ADD COLUMN IF NOT EXISTS rated_at {_TS}",
    # item 8: who cancelled an order and why. Old cancelled rows stay NULL
    # (unknown), so they count towards neither cancellation limit.
    "ALTER TABLE orders ADD COLUMN IF NOT EXISTS cancelled_by VARCHAR(20)",
    "ALTER TABLE orders ADD COLUMN IF NOT EXISTS cancel_reason VARCHAR(200)",
    f"ALTER TABLE orders ADD COLUMN IF NOT EXISTS cancelled_at {_TS}",
    # item 12: when shop-service took this order's stock, and when it gave it
    # back. Old rows stay NULL: they never reserved anything, so there is
    # nothing to return for them.
    f"ALTER TABLE orders ADD COLUMN IF NOT EXISTS stock_reserved_at {_TS}",
    f"ALTER TABLE orders ADD COLUMN IF NOT EXISTS stock_released_at {_TS}",
    # order_events
    "ALTER TABLE order_events ADD COLUMN IF NOT EXISTS agent_lat DOUBLE PRECISION",
    "ALTER TABLE order_events ADD COLUMN IF NOT EXISTS agent_lng DOUBLE PRECISION",
    # SRS REQ-AGENT-3: an agent can hold only ONE active order at a time. A
    # partial unique index makes the database itself enforce it, even if two
    # accept requests arrive in the same instant.
    (
        "CREATE UNIQUE INDEX IF NOT EXISTS uq_orders_one_active_per_agent "
        "ON orders (agent_id) WHERE status IN ('accepted', 'picked_up', 'in_transit')"
    ),
]


def run_startup_migrations(engine: Engine) -> None:
    if engine.dialect.name != "postgresql":
        return
    for statement in _STATEMENTS:
        try:
            with engine.begin() as connection:
                connection.execute(text(statement))
        except Exception:
            logger.exception("Startup migration failed (service keeps running): %s", statement)
