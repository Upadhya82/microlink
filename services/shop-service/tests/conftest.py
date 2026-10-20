import os

# Settings requires JWT_SECRET (no default); give tests a throwaway one.
os.environ.setdefault("JWT_SECRET", "test-only-signing-key-" + "x" * 16)

# Tests that need a database run on in-memory SQLite. `postgresql.UUID` has no
# SQLite spelling, and a column declared "UUID" gets NUMERIC affinity there, so
# SQLite quietly stores '44444444-4444-...' as the float 4.44e31. Spell the
# type as VARCHAR on SQLite only; PostgreSQL is untouched.
from sqlalchemy.dialects.postgresql import UUID  # noqa: E402
from sqlalchemy.ext.compiler import compiles  # noqa: E402


@compiles(UUID, "sqlite")
def _uuid_as_varchar(type_, compiler, **kw):  # pragma: no cover - DDL helper
    return "VARCHAR(36)"
