"""Seed approved Home-screen sponsor ads, so the Sponsored carousel has
several slides to rotate through.

Ads normally arrive through ``POST /ads`` and wait for an admin to approve
them. This writes approved rows straight to ``admin_db`` instead -- run it
inside the admin-service container:

    docker compose exec admin-service python -m app.scripts.seed_ads

Ads come from ``app/scripts/seed_data/ads.json`` (or pass another path as the
first argument). Re-running is safe: an ad is skipped when one with the same
advertiser and title already exists. Pass ``--reset`` to first delete every ad
owned by the seed user for a clean reload. Seeded ads belong to a sentinel
user id so they are easy to find and wipe, and carry no ``shop_id`` (the shop
catalogue lives in a different database), so tapping one does nothing.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from app.database import Base, SessionLocal, engine
from app.models import AdStatus, Advertisement

SEED_USER_ID = "00000000-0000-0000-0000-000000000000"
DEFAULT_FILE = Path(__file__).parent / "seed_data" / "ads.json"


def main() -> None:
    parser = argparse.ArgumentParser(description="Seed approved sponsor ads.")
    parser.add_argument("file", nargs="?", default=str(DEFAULT_FILE))
    parser.add_argument("--reset", action="store_true", help="delete previously seeded ads first")
    args = parser.parse_args()

    path = Path(args.file)
    if not path.exists():
        sys.exit(f"Seed file not found: {path}")
    entries = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(entries, list):
        sys.exit("Seed file must contain a JSON array of ad objects.")

    Base.metadata.create_all(bind=engine)
    db = SessionLocal()
    try:
        if args.reset:
            deleted = (
                db.query(Advertisement)
                .filter(Advertisement.submitted_by_user_id == SEED_USER_ID)
                .delete()
            )
            print(f"Removed {deleted} previously seeded ad(s).")

        added = skipped = 0
        for entry in entries:
            exists = (
                db.query(Advertisement)
                .filter(
                    Advertisement.advertiser_name == entry["advertiser_name"],
                    Advertisement.title == entry["title"],
                )
                .first()
            )
            if exists:
                skipped += 1
                continue
            db.add(
                Advertisement(
                    submitted_by_user_id=SEED_USER_ID,
                    status=AdStatus.approved,
                    advertiser_name=entry["advertiser_name"],
                    title=entry["title"],
                    subtitle=entry.get("subtitle", ""),
                    image_url=entry["image_url"],
                )
            )
            added += 1
        db.commit()
        print(f"Added {added} ad(s), skipped {skipped} already present.")
    finally:
        db.close()


if __name__ == "__main__":
    main()
