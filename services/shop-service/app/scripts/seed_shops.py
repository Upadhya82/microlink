"""Seed the shop catalogue with a curated set of shops for one location.

Shops normally enter MicroLink through ``POST /shops``, which requires a
verified shop_owner's JWT. That is the right path for real owners, but it is
awkward for standing up a test dataset. This script writes straight to
``shop_db`` through the same SQLAlchemy models the service uses, so it needs
no running gateway and no auth -- run it inside the shop-service container:

    docker compose exec shop-service python -m app.scripts.seed_shops diyagama

The positional argument names a JSON file under ``app/scripts/seed_data/``
(so ``diyagama`` -> ``app/scripts/seed_data/diyagama.json``); a path ending
in ``.json`` is also accepted. Each entry becomes one Shop row, and its
optional ``products`` list becomes Product rows.

Alternatively, pull real points of interest from OpenStreetMap for an area
instead of a file (uses the same Overpass client as live shop search):

    docker compose exec shop-service python -m app.scripts.seed_shops \\
        --osm --lat 6.8402 --lng 80.0105 --radius-km 4

Re-running is safe: a shop is skipped when one with the same name already
exists within ~75 m of the same spot. Pass ``--reset`` to first delete every
shop owned by the seed owner (with its products, alerts, photos, ratings and
analytics rows) for a clean reload. Use ``--reset`` once after upgrading
shop-service, so the shops pick up the new fields (stock status, delivery,
ratings).

Optional keys a shop entry may carry (all have defaults):
  delivery_available (bool), status ("open" / "closed" / "temporarily_closed"),
  status_reason, photos (list of http links), ratings (list of 1-5 integers,
  each stored as a rating from a different made-up customer so the trust score
  has data). A product may carry stock_quantity and/or stock_status.

All seeded shops are owned by a sentinel id
(00000000-0000-0000-0000-000000000000) so they are easy to find and wipe.
They stay fully visible and searchable in the app, but no real account can
manage them -- pass ``--owner <user-id>`` with a real shop_owner's id if you
want them to appear in that owner's dashboard.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
from pathlib import Path

import uuid

from sqlalchemy import func

from app import logic
from app.config import settings
from app.database import Base, SessionLocal, engine, run_light_migrations
from app.models import Product, Shop, ShopAnalyticsEvent, ShopCategory, ShopPhoto, ShopRating
from app.overpass_client import search_nearby_places
from app.ratings import refresh_shop_rating

SEED_OWNER_ID = "00000000-0000-0000-0000-000000000000"
SEED_DATA_DIR = Path(__file__).parent / "seed_data"

# ~75 m in degrees. Two rows this close with the same name are the same shop
# being re-seeded, not two different shops.
_DEDUPE_DEGREES = 0.0007

_VALID_CATEGORIES = {c.value for c in ShopCategory}

# Categories worth asking OpenStreetMap about ("other" has no useful OSM tag).
_OSM_CATEGORIES = [
    "grocery",
    "restaurant",
    "pharmacy",
    "electronics",
    "clothing",
    "hardware",
    "stationery",
    "bakery",
]


def _clip(value: object, length: int) -> str | None:
    if value is None:
        return None
    return str(value)[:length]


def _resolve_path(name: str) -> Path:
    path = Path(name) if name.endswith(".json") else SEED_DATA_DIR / f"{name}.json"
    if not path.is_file():
        sys.exit(f"Seed file not found: {path}")
    return path


def _load_file(name: str) -> list[dict]:
    data = json.loads(_resolve_path(name).read_text(encoding="utf-8"))
    if not isinstance(data, list):
        sys.exit("Seed file must contain a JSON array of shop objects.")
    return data


def _from_osm(lat: float, lng: float, radius_km: float) -> list[dict]:
    async def _gather() -> list[dict]:
        rows: list[dict] = []
        for category in _OSM_CATEGORIES:
            for place in await search_nearby_places(category, lat, lng, radius_km):
                rows.append(
                    {
                        "name": place["name"],
                        "category": category,
                        "address": place.get("address") or "",
                        "latitude": place["latitude"],
                        "longitude": place["longitude"],
                        "phone": place.get("phone"),
                    }
                )
        return rows

    rows = asyncio.run(_gather())
    if not rows:
        print("OpenStreetMap returned no named places for that area.", file=sys.stderr)
    return rows


def _normalise_shop(entry: dict) -> dict:
    try:
        name = str(entry["name"]).strip()
        lat = float(entry["latitude"])
        lng = float(entry["longitude"])
    except (KeyError, TypeError, ValueError):
        sys.exit(f"Each shop needs name, latitude and longitude -- bad entry: {entry!r}")
    if not name:
        sys.exit(f"Shop name cannot be empty: {entry!r}")
    if not (-90 <= lat <= 90 and -180 <= lng <= 180):
        sys.exit(f"Coordinates out of range for {name!r}: {lat}, {lng}")

    category = str(entry.get("category", "other")).strip().lower()
    if category not in _VALID_CATEGORIES:
        sys.exit(
            f"Unknown category {category!r} for {name!r}. "
            f"Valid: {', '.join(sorted(_VALID_CATEGORIES))}"
        )

    status = str(entry.get("status", "open")).strip().lower()
    if status not in logic.SHOP_STATUSES:
        sys.exit(f"Unknown status {status!r} for {name!r}. Valid: {', '.join(logic.SHOP_STATUSES)}")
    ratings = [int(r) for r in (entry.get("ratings") or [])]
    if any(r < 1 or r > 5 for r in ratings):
        sys.exit(f"Ratings must be between 1 and 5 ({name!r}): {ratings}")

    return {
        "name": name[:150],
        "description": str(entry.get("description", "")),
        "category": ShopCategory(category),
        "address": _clip(entry.get("address", ""), 300) or "",
        "latitude": lat,
        "longitude": lng,
        "phone": _clip(entry.get("phone"), 30),
        "image_url": _clip(entry.get("image_url"), 500),
        "opening_time": _clip(entry.get("opening_time", "09:00"), 5) or "09:00",
        "closing_time": _clip(entry.get("closing_time", "18:00"), 5) or "18:00",
        "status": status,
        "is_open": logic.is_open_from_status(status),
        "status_reason": _clip(entry.get("status_reason"), 200),
        "delivery_available": bool(entry.get("delivery_available", False)),
        "photos": [str(u) for u in (entry.get("photos") or [])][: settings.max_shop_photos],
        "ratings": ratings,
        "products": entry.get("products") or [],
    }


def _normalise_product(entry: dict, shop_name: str) -> dict:
    try:
        name = str(entry["name"]).strip()
        price = float(entry["price"])
    except (KeyError, TypeError, ValueError):
        sys.exit(f"Each product needs name and price -- bad product on {shop_name!r}: {entry!r}")
    if not name:
        sys.exit(f"Product name cannot be empty on {shop_name!r}.")
    if price <= 0:
        sys.exit(f"Product price must be greater than 0 ({shop_name!r} / {name!r}).")

    quantity = entry.get("stock_quantity")
    quantity = None if quantity is None else max(0, int(quantity))
    stock_status = logic.resolve_stock_status(
        quantity=quantity,
        explicit_status=entry.get("stock_status"),
        is_available=entry.get("is_available"),
        threshold=settings.low_stock_threshold,
    )
    return {
        "name": name[:150],
        "description": str(entry.get("description", "")),
        "price": price,
        "stock_quantity": quantity or 0,
        "category": _clip(entry.get("category", ""), 60) or "",
        "stock_status": stock_status,
        "is_available": logic.is_available_from_stock(stock_status),
    }


def _existing_near(db, name: str, lat: float, lng: float) -> Shop | None:
    return (
        db.query(Shop)
        .filter(func.lower(Shop.name) == name.lower())
        .filter(Shop.latitude.between(lat - _DEDUPE_DEGREES, lat + _DEDUPE_DEGREES))
        .filter(Shop.longitude.between(lng - _DEDUPE_DEGREES, lng + _DEDUPE_DEGREES))
        .first()
    )


def _reset(db, owner_id: str) -> int:
    shops = db.query(Shop).filter(Shop.owner_id == owner_id).all()
    if not shops:
        return 0
    shop_ids = [shop.id for shop in shops]
    # Analytics events have a FK to shops but no ORM cascade -- clear them first.
    db.query(ShopAnalyticsEvent).filter(
        ShopAnalyticsEvent.shop_id.in_(shop_ids)
    ).delete(synchronize_session=False)
    for shop in shops:
        db.delete(shop)  # ORM cascade removes the shop's products and alerts
    db.commit()
    return len(shops)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Seed shop-service with one location's shops.",
    )
    parser.add_argument(
        "location",
        nargs="?",
        help="A file in seed_data/ (e.g. 'diyagama') or a path to a .json file.",
    )
    parser.add_argument(
        "--osm",
        action="store_true",
        help="Pull real places from OpenStreetMap instead of reading a file.",
    )
    parser.add_argument("--lat", type=float, help="Centre latitude for --osm.")
    parser.add_argument("--lng", type=float, help="Centre longitude for --osm.")
    parser.add_argument(
        "--radius-km", type=float, default=4.0, help="Search radius for --osm (default 4)."
    )
    parser.add_argument(
        "--owner",
        default=SEED_OWNER_ID,
        help="owner_id to assign (default: the sentinel seed id).",
    )
    parser.add_argument(
        "--reset",
        action="store_true",
        help="Delete this owner's existing shops before seeding.",
    )
    args = parser.parse_args()

    if args.osm:
        if args.lat is None or args.lng is None:
            parser.error("--osm requires --lat and --lng")
        raw = _from_osm(args.lat, args.lng, args.radius_km)
    elif args.location:
        raw = _load_file(args.location)
    else:
        parser.error("give a location file name, or --osm with --lat/--lng")

    specs = [_normalise_shop(entry) for entry in raw]
    if not specs and not args.reset:
        print("Nothing to seed.")
        return

    Base.metadata.create_all(bind=engine)
    run_light_migrations(engine)

    db = SessionLocal()
    try:
        if args.reset:
            print(f"Reset: removed {_reset(db, args.owner)} existing shop(s) for owner {args.owner}.")

        created = skipped = product_count = 0
        for spec in specs:
            products = spec.pop("products")
            photos = spec.pop("photos")
            ratings = spec.pop("ratings")
            if _existing_near(db, spec["name"], spec["latitude"], spec["longitude"]):
                skipped += 1
                continue
            shop = Shop(owner_id=args.owner, **spec)
            db.add(shop)
            db.flush()  # assigns shop.id
            for product in products:
                db.add(Product(shop_id=shop.id, **_normalise_product(product, spec["name"])))
                product_count += 1
            for position, url in enumerate(photos):
                db.add(ShopPhoto(shop_id=shop.id, url=url, position=position))
            if photos and not shop.image_url:
                shop.image_url = photos[0]
            for number, value in enumerate(ratings):
                # a stable made-up customer id per (shop, number), so re-seeding never duplicates
                customer = uuid.uuid5(uuid.NAMESPACE_URL, f"microlink-seed/{spec['name']}/{number}")
                db.add(ShopRating(shop_id=shop.id, user_id=str(customer), rating=value))
            db.flush()
            if ratings:
                refresh_shop_rating(db, shop)
            created += 1
        db.commit()

        total = db.query(Shop).filter(Shop.owner_id == args.owner).count()
        print(
            f"Done: {created} shop(s) created, {skipped} skipped (already present), "
            f"{product_count} product(s) added."
        )
        print(f"Owner {args.owner} now owns {total} shop(s) in shop_db.")
    finally:
        db.close()


if __name__ == "__main__":
    main()
