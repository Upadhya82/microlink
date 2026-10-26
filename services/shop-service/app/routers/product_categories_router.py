"""Product categories: the predefined list, and admin review of "Others".

  GET  /shops/product-categories                       anyone: the list owners pick from
  POST /shops/product-categories                       admin: add one (optionally from "Others")
  GET  /shops/product-categories/suggestions           admin: "Others" waiting for review
  POST /shops/product-categories/suggestions/dismiss   admin: keep one off the list

Included before shops_router, so "/shops/product-categories" is never read
as a shop id. The existing product endpoints are unchanged: a product's
category is still plain text. Rules live in app/product_categories.py.
"""

import logging

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app import product_categories as rules
from app.auth import CurrentUser, require_admin
from app.database import get_db
from app.models import DismissedProductCategory, Product, ProductCategory

router = APIRouter(prefix="/shops/product-categories", tags=["product categories"])

logger = logging.getLogger("shop-service.product-categories")


class CategoryResponse(BaseModel):
    slug: str
    label: str


class CategoryCreateRequest(BaseModel):
    label: str = Field(min_length=2, max_length=80)
    # The "Others" name this comes from; its products move to the new category.
    from_suggestion: str | None = Field(default=None, max_length=150)


class CategoryCreateResponse(CategoryResponse):
    products_moved: int = 0
    already_existed: bool = False


class SuggestionResponse(BaseModel):
    name: str
    key: str
    product_count: int
    shop_count: int
    example_products: list[str] = []


class DismissRequest(BaseModel):
    name: str = Field(min_length=1, max_length=150)


def seed_defaults(db: Session) -> None:
    """Fill an empty list with the defaults. Leaves an existing list alone,
    so whatever admins have added survives a restart."""
    if db.query(ProductCategory.id).first() is not None:
        return
    for slug, label in rules.DEFAULT_CATEGORIES:
        db.add(ProductCategory(slug=slug, label=label, is_default=True))
    try:
        db.commit()
    except IntegrityError:
        # Two requests seeded at once; the other one won.
        db.rollback()


def _known(db: Session) -> list[tuple[str, str]]:
    seed_defaults(db)
    return [(row.slug, row.label) for row in db.query(ProductCategory).all()]


@router.get("", response_model=list[CategoryResponse])
async def list_categories(db: Session = Depends(get_db)):
    """Public: the shop owner's product form reads it."""
    seed_defaults(db)
    rows = db.query(ProductCategory).all()
    rows.sort(key=lambda row: row.label.lower())
    return [CategoryResponse(slug=row.slug, label=row.label) for row in rows]


@router.get("/suggestions", response_model=list[SuggestionResponse])
async def list_suggestions(
    _admin: CurrentUser = Depends(require_admin),
    db: Session = Depends(get_db),
):
    products = db.query(Product.category, Product.shop_id, Product.name).all()
    dismissed = [row.name_key for row in db.query(DismissedProductCategory).all()]
    return rules.other_categories(products, _known(db), dismissed)


@router.post("", response_model=CategoryCreateResponse, status_code=status.HTTP_201_CREATED)
async def create_category(
    payload: CategoryCreateRequest,
    admin: CurrentUser = Depends(require_admin),
    db: Session = Depends(get_db),
):
    label = " ".join(payload.label.split())
    known = _known(db)

    # Already on the list under this name? Then accepting an "Others" name
    # just files its products under the existing category.
    existing_slug = rules.match_category(label, known)
    already_existed = existing_slug is not None
    if existing_slug is None:
        slug = rules.slugify(label)
        if not slug:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail="Use letters or numbers in the category name.",
            )
        if any(slug == known_slug for known_slug, _ in known):
            existing_slug = slug
            already_existed = True
        else:
            db.add(ProductCategory(slug=slug, label=label, created_by=admin.id))
            existing_slug = slug
    if already_existed and not payload.from_suggestion:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail=f'"{label}" is already a category.',
        )

    moved = 0
    if payload.from_suggestion:
        key = rules.name_key(payload.from_suggestion)
        for product in db.query(Product).all():
            if rules.name_key(product.category) == key and product.category != existing_slug:
                product.category = existing_slug
                moved += 1

    db.commit()
    final_label = next(
        (row.label for row in db.query(ProductCategory).filter(ProductCategory.slug == existing_slug)),
        label,
    )
    logger.info("Category %s added/used by admin %s; %d product(s) moved", existing_slug, admin.id, moved)
    return CategoryCreateResponse(
        slug=existing_slug,
        label=final_label,
        products_moved=moved,
        already_existed=already_existed,
    )


@router.post("/suggestions/dismiss", status_code=status.HTTP_204_NO_CONTENT)
async def dismiss_suggestion(
    payload: DismissRequest,
    admin: CurrentUser = Depends(require_admin),
    db: Session = Depends(get_db),
):
    key = rules.name_key(payload.name)
    if not key:
        raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_ENTITY, detail="Name is empty.")
    exists = (
        db.query(DismissedProductCategory.id)
        .filter(DismissedProductCategory.name_key == key)
        .first()
    )
    if exists is None:
        db.add(DismissedProductCategory(name_key=key, dismissed_by=admin.id))
        db.commit()
