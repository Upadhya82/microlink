"""One-off backfill: replay existing order feedback onto the shop pages.

Item 3 made shop-service listen for `feedback.submitted` and write each one
in as a review. Feedback submitted BEFORE that shipped was never heard, so
those reviews are missing from the shop pages they belong to.

This republishes one event per stored feedback row. shop-service's listener
does the actual writing, which means the backfill cannot drift from the
live path: it keys on (shop_id, user_id, source), so running this twice
updates the same rows rather than duplicating them, and feedback a customer
has since changed on the shop page is left alone.

Run it once, with the stack up (both services and Redis):

    docker compose exec -T crowdsource-service python -m app.scripts.replay_feedback
    # see what it would do, without publishing anything:
    docker compose exec -T crowdsource-service python -m app.scripts.replay_feedback --dry-run

Feedback with no shop_id is skipped and counted: those came from the
"request delivery" flow, which has no shop to review.
"""

import argparse
import asyncio
import sys

from app.database import SessionLocal
from app.event_bus import publish_event
from app.models import OrderFeedback

# Small pause between events so a few thousand rows cannot swamp the bus or
# shop-service's single listener.
PAUSE_SECONDS = 0.02


async def replay(dry_run: bool = False, limit: int | None = None) -> int:
    db = SessionLocal()
    try:
        query = db.query(OrderFeedback).order_by(OrderFeedback.created_at)
        if limit is not None:
            query = query.limit(limit)
        rows = query.all()
    finally:
        db.close()

    published = 0
    skipped = 0
    for row in rows:
        if not row.shop_id:
            skipped += 1
            continue
        if dry_run:
            print(f"  would replay feedback {row.id}: shop={row.shop_id} rating={row.rating}")
            published += 1
            continue
        await publish_event(
            "feedback.submitted",
            {
                "order_id": row.order_id,
                "user_id": row.user_id,
                "rating": row.rating,
                "shop_id": row.shop_id,
                "comment": row.comment,
            },
        )
        published += 1
        await asyncio.sleep(PAUSE_SECONDS)

    print(
        f"{'Would replay' if dry_run else 'Replayed'} {published} feedback row(s); "
        f"skipped {skipped} with no shop."
    )
    if not dry_run and published:
        # The listener writes asynchronously, so give it a moment before the
        # process exits and the connection closes.
        await asyncio.sleep(1.0)
    return published


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="List what would be replayed without publishing anything.",
    )
    parser.add_argument(
        "--limit", type=int, default=None, help="Only the oldest N rows (for a trial run)."
    )
    args = parser.parse_args()
    asyncio.run(replay(dry_run=args.dry_run, limit=args.limit))
    return 0


if __name__ == "__main__":
    sys.exit(main())
