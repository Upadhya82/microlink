"""Shop catalogue endpoints.

Public (no login):  GET /shops, /shops/landmark, /shops/external, /shops/{id},
                    /shops/{id}/photos
Shop owner:         POST /shops, GET /shops/owner/me, PATCH /shops/{id},
                    PATCH /shops/{id}/status, photos, DELETE /shops/{id}

Static paths (/owner/me, /external, /landmark) are declared BEFORE /{shop_id}
so FastAPI does not mistake the word "landmark" for a shop id.
"""

import logging
from dataclasses import dataclass
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import exists, func, or_
from sqlalchemy.orm import Session

from app import geo, logic
from app.auth import CurrentUser, get_current_user, require_roles, require_verified
from app.config import settings
from app.database import get_db
from app.event_bus import publish_event
from app.models import (
    AnalyticsEventType,
    Product,
    Shop,
    ShopAnalyticsEvent,
    ShopCategory,
    ShopPhoto,
)
from app.overpass_client import geocode_landmark, search_nearby_places
from app.schemas import (
    LandmarkInfo,
    LandmarkSearchResponse,
    ShopCreateRequest,
    ShopPhotoCreateRequest,
    ShopPhotoResponse,
    ShopResponse,
    ShopStatusUpdateRequest,
    ShopUpdateRequest,
)

logger = logging.getLogger(settings.service_name)

router = APIRouter(prefix="/shops", tags=["shops"])

require_shop_owner = require_roles("shop_owner")

SortLiteral = Literal["smart", "distance", "rating", "newest"]
_NOT_NULL_SHOP_FIELDS = {
    "name",
    "description",
    "category",
    "address",
    "latitude",
    "longitude",
    "delivery_available",
    "opening_time",
    "closing_time",
}
MAX_CANDIDATES = 1000  # rows read from the database before distance filtering
MAX_IMPRESSIONS_PER_SEARCH = 20


# ---------------------------------------------------------------- helpers
def _ensure_owner_or_admin(shop: Shop, current_user: CurrentUser) -> None:
    if current_user.role != "admin" and shop.owner_id != current_user.id:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN, detail="You do not own this shop"
        )


def _get_shop_or_404(db: Session, shop_id: str) -> Shop:
    shop = db.get(Shop, shop_id)
    if shop is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Shop not found")
    return shop


@dataclass
class _Row:
    """A shop plus its distance from the search point (used for sorting)."""

    shop: Shop
    distance_km: float | None = None

    @property
    def rating_avg(self) -> float:
        return self.shop.rating_avg or 0.0

    @property
    def created_at(self):
        return self.shop.created_at


def _like(text: str) -> str:
    return f"%{logic.escape_like(text.strip())}%"


def _apply_filters(
    query,
    *,
    q: str | None,
    category: ShopCategory | None,
    is_open: bool | None,
    min_rating: float | None,
    delivery_available: bool | None,
    owner_id: str | None,
):
    """SRS REQ-SEARCH-1 and REQ-SEARCH-2."""
    if q and q.strip():
        pattern = _like(q)
        conditions = [
            Shop.name.ilike(pattern, escape="\\"),
            Shop.address.ilike(pattern, escape="\\"),
            # a product with this name (REQ-SEARCH-1: "...and product names")
            exists().where(Product.shop_id == Shop.id, Product.name.ilike(pattern, escape="\\")),
        ]
        categories = logic.matching_categories(q, [c.value for c in ShopCategory])
        if categories:
            conditions.append(Shop.category.in_([ShopCategory(c) for c in categories]))
        query = query.filter(or_(*conditions))
    if category is not None:
        query = query.filter(Shop.category == category)
    if is_open is True:
        query = query.filter(Shop.status == "open")
    elif is_open is False:
        query = query.filter(Shop.status != "open")
    if min_rating is not None:
        query = query.filter(Shop.rating_avg >= min_rating)
    if delivery_available is not None:
        query = query.filter(Shop.delivery_available == delivery_available)
    if owner_id is not None:
        query = query.filter(Shop.owner_id == owner_id)
    return query


def _product_counts(db: Session, shop_ids: list[str]) -> dict[str, dict[str, int]]:
    if not shop_ids:
        return {}
    rows = (
        db.query(Product.shop_id, Product.stock_status, func.count(Product.id))
        .filter(Product.shop_id.in_(shop_ids))
        .group_by(Product.shop_id, Product.stock_status)
        .all()
    )
    result: dict[str, dict[str, int]] = {}
    for shop_id, stock_status, count in rows:
        result.setdefault(shop_id, {})[stock_status or "in_stock"] = count
    return result


def _photos_by_shop(db: Session, shop_ids: list[str]) -> dict[str, list[str]]:
    if not shop_ids:
        return {}
    rows = (
        db.query(ShopPhoto.shop_id, ShopPhoto.url)
        .filter(ShopPhoto.shop_id.in_(shop_ids))
        .order_by(ShopPhoto.position, ShopPhoto.created_at)
        .all()
    )
    result: dict[str, list[str]] = {}
    for shop_id, url in rows:
        result.setdefault(shop_id, []).append(url)
    return result


def _matched_products(db: Session, shop_ids: list[str], q: str | None) -> dict[str, str]:
    """For each shop, the first product whose name matches the search text."""
    if not shop_ids or not q or not q.strip():
        return {}
    rows = (
        db.query(Product.shop_id, Product.name)
        .filter(Product.shop_id.in_(shop_ids), Product.name.ilike(_like(q), escape="\\"))
        .order_by(Product.name)
        .all()
    )
    result: dict[str, str] = {}
    for shop_id, name in rows:
        result.setdefault(shop_id, name)
    return result


def _to_response(
    shop: Shop,
    *,
    distance_km: float | None = None,
    counts: dict[str, int] | None = None,
    photos: list[str] | None = None,
    matched_product: str | None = None,
) -> ShopResponse:
    counts = counts or {}
    in_stock = counts.get("in_stock", 0)
    low_stock = counts.get("low_stock", 0)
    out_of_stock = counts.get("out_of_stock", 0)

    response = ShopResponse.model_validate(shop)
    response.distance_km = distance_km
    response.status = shop.status or logic.status_from_is_open(shop.is_open)
    response.trust_score = shop.rating_avg or 0.0
    response.photos = photos if photos else ([shop.image_url] if shop.image_url else [])
    response.in_stock_count = in_stock
    response.low_stock_count = low_stock
    response.out_of_stock_count = out_of_stock
    response.product_count = in_stock + low_stock + out_of_stock
    response.availability = logic.availability_level(in_stock, low_stock, out_of_stock)
    response.matched_product = matched_product
    return response


def _build_responses(db: Session, rows: list[_Row], q: str | None) -> list[ShopResponse]:
    ids = [row.shop.id for row in rows]
    counts = _product_counts(db, ids)
    photos = _photos_by_shop(db, ids)
    matched = _matched_products(db, ids, q)
    return [
        _to_response(
            row.shop,
            distance_km=row.distance_km,
            counts=counts.get(row.shop.id),
            photos=photos.get(row.shop.id),
            matched_product=matched.get(row.shop.id),
        )
        for row in rows
    ]


def _record_impressions(db: Session, rows: list[_Row]) -> None:
    """Count one 'search impression' per shop shown for a text search.

    Best effort only: a failure here must never break the search itself.
    """
    try:
        db.add_all(
            [
                ShopAnalyticsEvent(shop_id=row.shop.id, event_type=AnalyticsEventType.search_impression)
                for row in rows[:MAX_IMPRESSIONS_PER_SEARCH]
            ]
        )
        db.commit()
    except Exception:
        db.rollback()
        logger.warning("Could not record search impressions", exc_info=True)


def _search_shops(
    db: Session,
    *,
    q: str | None,
    category: ShopCategory | None,
    is_open: bool | None,
    min_rating: float | None,
    delivery_available: bool | None,
    owner_id: str | None,
    lat: float | None,
    lng: float | None,
    radius_km: float,
    sort: str,
    limit: int,
) -> list[ShopResponse]:
    query = _apply_filters(
        db.query(Shop),
        q=q,
        category=category,
        is_open=is_open,
        min_rating=min_rating,
        delivery_available=delivery_available,
        owner_id=owner_id,
    )

    has_location = lat is not None and lng is not None
    if has_location:
        box = geo.bounding_box(lat, lng, radius_km)
        if box is not None:  # cheap pre-filter; the exact distance check follows
            query = query.filter(
                Shop.latitude.between(box.min_lat, box.max_lat),
                Shop.longitude.between(box.min_lng, box.max_lng),
            )

    shops = query.order_by(Shop.created_at.desc()).limit(MAX_CANDIDATES).all()

    rows: list[_Row] = []
    for shop in shops:
        if has_location:
            distance = geo.haversine_km(lat, lng, shop.latitude, shop.longitude)
            if distance > radius_km:
                continue
            rows.append(_Row(shop, round(distance, 2)))
        else:
            rows.append(_Row(shop))

    rows = logic.sort_shops(rows, sort, has_location)[:limit]
    if q and q.strip():
        _record_impressions(db, rows)
    return _build_responses(db, rows, q)


def _clean_photo_urls(urls: list[str]) -> list[str]:
    cleaned: list[str] = []
    for url in urls:
        url = url.strip()
        if not url.lower().startswith(("http://", "https://")):
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail="Photo links must start with http:// or https://",
            )
        if url not in cleaned:
            cleaned.append(url)
    return cleaned


# --------------------------------------------------------------- endpoints
@router.post("", response_model=ShopResponse, status_code=status.HTTP_201_CREATED)
async def create_shop(
    payload: ShopCreateRequest,
    current_user: CurrentUser = Depends(require_shop_owner),
    _verified: CurrentUser = Depends(require_verified),
    db: Session = Depends(get_db),
):
    photos = _clean_photo_urls(payload.photos)[: settings.max_shop_photos]
    shop = Shop(
        owner_id=current_user.id,
        status="open",
        is_open=True,
        **payload.model_dump(exclude={"photos"}),
    )
    db.add(shop)
    db.flush()  # gives the shop its id so the photo rows can point at it
    for position, url in enumerate(photos):
        db.add(ShopPhoto(shop_id=shop.id, url=url, position=position))
    if photos and not shop.image_url:
        shop.image_url = photos[0]
    db.commit()
    db.refresh(shop)

    await publish_event(
        "shop.created", {"shop_id": shop.id, "owner_id": shop.owner_id, "name": shop.name}
    )
    return _to_response(shop, photos=photos or None)


@router.get("", response_model=list[ShopResponse])
async def list_shops(
    q: str | None = Query(
        default=None, max_length=100, description="Search shop names, addresses, categories and product names"
    ),
    category: ShopCategory | None = Query(default=None),
    is_open: bool | None = Query(default=None, description="true = only shops that are open now"),
    min_rating: float | None = Query(default=None, ge=0, le=5, description="Minimum trust score (1-5)"),
    delivery_available: bool | None = Query(default=None),
    owner_id: str | None = Query(default=None),
    lat: float | None = Query(default=None, ge=-90, le=90),
    lng: float | None = Query(default=None, ge=-180, le=180),
    radius_km: float = Query(default=10, gt=0, le=200),
    sort: SortLiteral = Query(default="smart"),
    limit: int = Query(default=50, ge=1, le=200),
    db: Session = Depends(get_db),
):
    return _search_shops(
        db,
        q=q,
        category=category,
        is_open=is_open,
        min_rating=min_rating,
        delivery_available=delivery_available,
        owner_id=owner_id,
        lat=lat,
        lng=lng,
        radius_km=radius_km,
        sort=sort,
        limit=limit,
    )


@router.get("/owner/me", response_model=list[ShopResponse])
async def list_my_shops(
    current_user: CurrentUser = Depends(require_shop_owner),
    db: Session = Depends(get_db),
):
    shops = (
        db.query(Shop)
        .filter(Shop.owner_id == current_user.id)
        .order_by(Shop.created_at.desc())
        .all()
    )
    return _build_responses(db, [_Row(shop) for shop in shops], None)


@router.get("/landmark", response_model=LandmarkSearchResponse)
async def search_by_landmark(
    landmark: str = Query(..., min_length=2, max_length=150, description='For example "Central Bus Stand"'),
    radius_km: float = Query(default=settings.default_landmark_radius_km, gt=0, le=50),
    q: str | None = Query(default=None, max_length=100),
    category: ShopCategory | None = Query(default=None),
    is_open: bool | None = Query(default=None),
    min_rating: float | None = Query(default=None, ge=0, le=5),
    delivery_available: bool | None = Query(default=None),
    sort: SortLiteral = Query(default="smart"),
    limit: int = Query(default=50, ge=1, le=200),
    db: Session = Depends(get_db),
):
    """SRS REQ-SEARCH-3: turn a landmark name into a point, then return the
    shops inside the radius (default 2 km) of that point."""
    place = await geocode_landmark(landmark)
    if place is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="We could not find that landmark. Try a nearby town or a more specific name.",
        )
    shops = _search_shops(
        db,
        q=q,
        category=category,
        is_open=is_open,
        min_rating=min_rating,
        delivery_available=delivery_available,
        owner_id=None,
        lat=place["latitude"],
        lng=place["longitude"],
        radius_km=radius_km,
        sort=sort,
        limit=limit,
    )
    return LandmarkSearchResponse(
        landmark=LandmarkInfo(
            query=landmark,
            name=place["name"],
            latitude=place["latitude"],
            longitude=place["longitude"],
            source=place["source"],
        ),
        radius_km=radius_km,
        shops=shops,
    )


@router.get("/external")
async def search_external_places(
    category: ShopCategory = Query(...),
    lat: float = Query(..., ge=-90, le=90),
    lng: float = Query(..., ge=-180, le=180),
    radius_km: float = Query(default=5, gt=0, le=20),
):
    """Real places from OpenStreetMap (Overpass) near a point.

    These are display-only: every result carries source="openstreetmap" and an
    id that does not exist in MicroLink, so the app must never treat one as a
    registered shop.
    """
    return await search_nearby_places(category.value, lat, lng, radius_km)


@router.get("/{shop_id}", response_model=ShopResponse)
async def get_shop(shop_id: str, db: Session = Depends(get_db)):
    shop = _get_shop_or_404(db, shop_id)
    try:
        db.add(ShopAnalyticsEvent(shop_id=shop.id, event_type=AnalyticsEventType.view))
        db.commit()
    except Exception:  # a failed analytics write must not break the page
        db.rollback()
        logger.warning("Could not record shop view", exc_info=True)
    row = _Row(shop)
    return _build_responses(db, [row], None)[0]


@router.patch("/{shop_id}", response_model=ShopResponse)
async def update_shop(
    shop_id: str,
    payload: ShopUpdateRequest,
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    shop = _get_shop_or_404(db, shop_id)
    _ensure_owner_or_admin(shop, current_user)

    for field, value in payload.model_dump(exclude_unset=True).items():
        if value is None and field in _NOT_NULL_SHOP_FIELDS:
            continue  # these columns cannot be empty, so a null from the client is ignored
        setattr(shop, field, value)
    db.commit()
    db.refresh(shop)
    return _build_responses(db, [_Row(shop)], None)[0]


@router.patch("/{shop_id}/status", response_model=ShopResponse)
async def update_shop_status(
    shop_id: str,
    payload: ShopStatusUpdateRequest,
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """SRS REQ-SHOP-2. Accepts the old {"is_open": bool} or a full status with
    an optional reason and expected re-open time."""
    shop = _get_shop_or_404(db, shop_id)
    _ensure_owner_or_admin(shop, current_user)

    new_status = payload.status or logic.status_from_is_open(bool(payload.is_open))
    shop.status = new_status
    shop.is_open = logic.is_open_from_status(new_status)
    if new_status == "open":
        shop.status_reason = None
        shop.reopen_at = None
    else:
        shop.status_reason = payload.reason
        shop.reopen_at = payload.reopen_at if new_status == "temporarily_closed" else None
    db.commit()
    db.refresh(shop)

    await publish_event(
        "shop.status_changed",
        {
            "shop_id": shop.id,
            "is_open": shop.is_open,
            "status": shop.status,
            "reason": shop.status_reason,
        },
    )
    return _build_responses(db, [_Row(shop)], None)[0]


@router.get("/{shop_id}/photos", response_model=list[ShopPhotoResponse])
async def list_photos(shop_id: str, db: Session = Depends(get_db)):
    _get_shop_or_404(db, shop_id)
    return (
        db.query(ShopPhoto)
        .filter(ShopPhoto.shop_id == shop_id)
        .order_by(ShopPhoto.position, ShopPhoto.created_at)
        .all()
    )


@router.post("/{shop_id}/photos", response_model=ShopPhotoResponse, status_code=status.HTTP_201_CREATED)
async def add_photo(
    shop_id: str,
    payload: ShopPhotoCreateRequest,
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """REQ-SHOP-1: up to 10 photos per shop (added as links - there is no file storage)."""
    shop = _get_shop_or_404(db, shop_id)
    _ensure_owner_or_admin(shop, current_user)
    [url] = _clean_photo_urls([payload.url])

    existing = db.query(ShopPhoto).filter(ShopPhoto.shop_id == shop_id).order_by(ShopPhoto.position).all()
    if len(existing) >= settings.max_shop_photos:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f"A shop can have at most {settings.max_shop_photos} photos.",
        )
    if any(photo.url == url for photo in existing):
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="That photo is already added.")

    photo = ShopPhoto(shop_id=shop_id, url=url, position=(existing[-1].position + 1) if existing else 0)
    db.add(photo)
    if not shop.image_url:
        shop.image_url = url
    db.commit()
    db.refresh(photo)
    return photo


@router.delete("/{shop_id}/photos/{photo_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_photo(
    shop_id: str,
    photo_id: str,
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    shop = _get_shop_or_404(db, shop_id)
    _ensure_owner_or_admin(shop, current_user)
    photo = db.get(ShopPhoto, photo_id)
    if photo is None or photo.shop_id != shop_id:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Photo not found")

    removed_url = photo.url
    db.delete(photo)
    db.flush()
    if shop.image_url == removed_url:  # the cover photo was removed - fall back to the next one
        next_photo = (
            db.query(ShopPhoto).filter(ShopPhoto.shop_id == shop_id).order_by(ShopPhoto.position).first()
        )
        shop.image_url = next_photo.url if next_photo else None
    db.commit()


@router.delete("/{shop_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_shop(
    shop_id: str,
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    shop = _get_shop_or_404(db, shop_id)
    _ensure_owner_or_admin(shop, current_user)

    # Analytics rows point at the shop but have no cascade, so delete them
    # first. Without this, deleting a shop that anyone had viewed failed with
    # a foreign-key error.
    db.query(ShopAnalyticsEvent).filter(ShopAnalyticsEvent.shop_id == shop_id).delete(
        synchronize_session=False
    )
    db.delete(shop)  # products, alerts, photos and ratings are removed by the ORM cascade
    db.commit()
    await publish_event("shop.deleted", {"shop_id": shop_id})
