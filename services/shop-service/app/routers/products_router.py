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

Listing rule (settings.min_listable_stock, default 5): a product needs at
least that many units to be created, and customers only see products that
still have them. Owners and admins always see every product, so stock can
be refilled.
"""

from fastapi import APIRouter, Depends, File, HTTPException, Query, Response, UploadFile, status
from sqlalchemy.orm import Session

from app import listings, logic
from app.auth import CurrentUser, get_current_user, get_current_user_optional
from app.config import settings
from app.images import ImageRejected, process_image
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


def _sees_hidden_products(shop: Shop, current_user: CurrentUser | None) -> bool:
    """Owners and admins see products that are below the listing threshold."""
    if current_user is None:
        return False
    return current_user.role == "admin" or shop.owner_id == current_user.id


def _get_product(db: Session, shop_id: str, product_id: str) -> Product:
    product = db.get(Product, product_id)
    if product is None or product.shop_id != shop_id:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Product not found")
    return product


@router.get("", response_model=list[ProductResponse])
async def list_products(
    shop_id: str,
    stock_status: StockStatusLiteral | None = Query(default=None, description="Only products with this stock status"),
    current_user: CurrentUser | None = Depends(get_current_user_optional),
    db: Session = Depends(get_db),
):
    """Public, but a token is read when one is sent: the owner of the shop and
    admins get the full list, everyone else only the listable products."""
    shop = db.get(Shop, shop_id)
    if shop is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Shop not found")
    query = db.query(Product).filter(Product.shop_id == shop_id)
    if stock_status is not None:
        query = query.filter(Product.stock_status == stock_status)
    if not _sees_hidden_products(shop, current_user):
        query = query.filter(Product.stock_quantity >= settings.min_listable_stock)
    return query.order_by(Product.name).all()


@router.post("", response_model=ProductResponse, status_code=status.HTTP_201_CREATED)
async def create_product(
    shop_id: str,
    payload: ProductCreateRequest,
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    _get_owned_shop(shop_id, current_user, db)

    if not logic.is_listable(payload.stock_quantity, settings.min_listable_stock):
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=(
                f"A product needs at least {settings.min_listable_stock} in stock "
                "to be listed."
            ),
        )

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
        discount_percent=payload.discount_percent,
        stock_status=stock_status,
        is_available=logic.is_available_from_stock(stock_status),
    )
    db.add(product)
    db.commit()
    db.refresh(product)
    # Adding products is how a new shop reaches the listable threshold, so
    # this is the call that verifies a shop its neighbours have already
    # confirmed. Updating and deleting a product already did this; creating
    # one did not, which left that shop waiting for an edit it had no reason
    # to make.
    await listings.review_product_count(db, db.get(Shop, shop_id))
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
    for field in ("name", "description", "price", "category", "discount_percent"):
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
    # Item 10: this edit may have taken the shop below the number of
    # products customers can see.
    if stock_touched:
        await listings.review_product_count(db, db.get(Shop, shop_id))
    return product


@router.delete("/{product_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_product(
    shop_id: str,
    product_id: str,
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    shop = _get_owned_shop(shop_id, current_user, db)
    product = _get_product(db, shop_id, product_id)
    db.delete(product)
    db.commit()
    # Item 10: deleting a product lowers the count the same way.
    await listings.review_product_count(db, shop)


@router.post("/{product_id}/image", response_model=ProductResponse)
async def upload_product_image(
    shop_id: str,
    product_id: str,
    file: UploadFile = File(...),
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    """Attach a photo to a product (shop-owner storefront).

    One image per product rather than a gallery: on a phone listing, the
    thumbnail is what sells the item, and asking a micro-business owner to
    curate several shots per product is friction they will not accept.
    """
    _get_owned_shop(shop_id, current_user, db)
    product = _get_product(db, shop_id, product_id)

    raw = await file.read()
    try:
        processed = process_image(raw, file.content_type)
    except ImageRejected as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc))

    product.image = processed
    product.has_image = True
    db.commit()
    db.refresh(product)
    return product


@router.get("/{product_id}/image")
async def get_product_image(shop_id: str, product_id: str, db: Session = Depends(get_db)):
    """Public: product photos are shop-front content, and requiring a token
    would stop a plain <img> in the app from loading them."""
    product = _get_product(db, shop_id, product_id)
    if not product.has_image or product.image is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="No image for this product")
    return Response(
        content=product.image,
        media_type="image/jpeg",
        headers={"Cache-Control": "public, max-age=86400"},
    )


@router.delete("/{product_id}/image", response_model=ProductResponse)
async def delete_product_image(
    shop_id: str,
    product_id: str,
    current_user: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    _get_owned_shop(shop_id, current_user, db)
    product = _get_product(db, shop_id, product_id)
    product.image = None
    product.has_image = False
    db.commit()
    db.refresh(product)
    return product
