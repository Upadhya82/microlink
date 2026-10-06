"""Product endpoints for one shop (SRS REQ-SHOP-4).

Anyone can read a shop's products. Only the shop's owner (or an admin) can
add, change or delete them.

Stock status rules (see app/logic.py -> resolve_stock_status):
  * the owner picks a status                  -> that status is used
  * the owner switches "available" off        -> out_of_stock
  * a quantity is sent                        -> derived: 0 = out_of_stock,
                                                 up to the low-stock limit = low_stock
  * nothing about stock is sent (smoke test)  -> in_stock
`is_available` is kept in step so older screens keep working.
"""

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.orm import Session

from app import logic
from app.auth import CurrentUser, get_current_user
from app.config import settings
from app.database import get_db
from app.models import Product, Shop
from app.schemas import ProductCreateRequest, ProductResponse, ProductUpdateRequest, StockStatusLiteral

router = APIRouter(prefix="/shops/{shop_id}/products", tags=["shop products"])


def _get_owned_shop(shop_id: str, current_user: CurrentUser, db: Session) -> Shop:
    shop = db.get(Shop, shop_id)
    if shop is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Shop not found")
    if current_user.role != "admin" and shop.owner_id != current_user.id:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN, detail="You do not own this shop"
        )
    return shop


def _get_product(db: Session, shop_id: str, product_id: str) -> Product:
    product = db.get(Product, product_id)
    if product is None or product.shop_id != shop_id:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Product not found")
    return product


@router.get("", response_model=list[ProductResponse])
async def list_products(
    shop_id: str,
    stock_status: StockStatusLiteral | None = Query(default=None, description="Only products with this stock status"),
    db: Session = Depends(get_db),
):
    if db.get(Shop, shop_id) is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Shop not found")
    query = db.query(Product).filter(Product.shop_id == shop_id)
    if stock_status is not None:
        query = query.filter(Product.stock_status == stock_status)
    return query.order_by(Product.name).all()


@router.post("", response_model=ProductResponse, status_code=status.HTTP_201_CREATED)
async def create_product(
    shop_id: str,
    payload: ProductCreateRequest,
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    _get_owned_shop(shop_id, current_user, db)

    stock_status = logic.resolve_stock_status(
        quantity=payload.stock_quantity,
        explicit_status=payload.stock_status,
        is_available=payload.is_available,
        threshold=settings.low_stock_threshold,
    )
    product = Product(
        shop_id=shop_id,
        name=payload.name,
        description=payload.description,
        price=payload.price,
        stock_quantity=payload.stock_quantity or 0,
        category=payload.category,
        stock_status=stock_status,
        is_available=logic.is_available_from_stock(stock_status),
    )
    db.add(product)
    db.commit()
    db.refresh(product)
    return product


@router.patch("/{product_id}", response_model=ProductResponse)
async def update_product(
    shop_id: str,
    product_id: str,
    payload: ProductUpdateRequest,
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    _get_owned_shop(shop_id, current_user, db)
    product = _get_product(db, shop_id, product_id)

    changes = payload.model_dump(exclude_unset=True)
    for field in ("name", "description", "price", "category"):
        if field in changes and changes[field] is not None:
            setattr(product, field, changes[field])

    stock_touched = any(key in changes for key in ("stock_quantity", "stock_status", "is_available"))
    if stock_touched:
        product.stock_status = logic.resolve_stock_status(
            quantity=changes.get("stock_quantity"),
            explicit_status=changes.get("stock_status"),
            is_available=changes.get("is_available"),
            current_status=product.stock_status,
            stored_quantity=product.stock_quantity,
            threshold=settings.low_stock_threshold,
        )
        if changes.get("stock_quantity") is not None:
            product.stock_quantity = changes["stock_quantity"]
        product.is_available = logic.is_available_from_stock(product.stock_status)

    db.commit()
    db.refresh(product)
    return product


@router.delete("/{product_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_product(
    shop_id: str,
    product_id: str,
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    _get_owned_shop(shop_id, current_user, db)
    product = _get_product(db, shop_id, product_id)
    db.delete(product)
    db.commit()
