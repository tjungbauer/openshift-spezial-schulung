"""catalog – the ACME product catalogue: list, details and stock.

Products come from a JSON file baked into the image. Mount a ConfigMap and
point PRODUCTS_FILE at it to change them without a new image.

Stock lives in memory, per pod: it starts from the JSON file again after a
restart, and two replicas count independently.

APP_VERSION 2.x is the "new look" for canary demos: products marked "new"
get a badge and the UI switches to a different accent colour.
"""

import json
import os
import threading
from pathlib import Path

from fastapi import HTTPException
from prometheus_client import Counter
from pydantic import BaseModel, Field

from .shopkit import VERSION, create_app, log

PRODUCTS_FILE = Path(os.getenv("PRODUCTS_FILE", Path(__file__).with_name("products.json")))
NEW_LOOK = VERSION.startswith("2.")

RESERVATIONS = Counter("shop_stock_reservations_total", "Stock reservations", ["result"])

_lock = threading.Lock()
_products: dict[str, dict] = {}


def load_products() -> None:
    try:
        products = json.loads(PRODUCTS_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        log.exception("cannot load products", extra={"fields": {"file": str(PRODUCTS_FILE)}})
        return
    with _lock:
        _products.clear()
        _products.update({p["id"]: p for p in products})
    log.info("products loaded", extra={"fields": {"count": len(products), "file": str(PRODUCTS_FILE)}})


def _public(product: dict) -> dict:
    result = {key: product[key] for key in ("id", "name", "description", "emoji", "price_pence", "stock")}
    if NEW_LOOK and product.get("new"):
        result["badge"] = "new"
    return result


app = create_app("catalog", ready_check=lambda: bool(_products), on_startup=load_products)


@app.get("/products")
def list_products():
    with _lock:
        products = [_public(p) for p in _products.values()]
    return {"theme": "v2" if NEW_LOOK else "v1", "products": products}


@app.get("/products/{product_id}")
def get_product(product_id: str):
    with _lock:
        product = _products.get(product_id)
        if not product:
            raise HTTPException(404, f"unknown product {product_id}")
        return _public(product)


class Item(BaseModel):
    product_id: str
    quantity: int = Field(gt=0, le=100)


class Reservation(BaseModel):
    items: list[Item] = Field(min_length=1)


@app.post("/stock/reserve")
def reserve_stock(reservation: Reservation):
    """All or nothing: either every item is in stock and gets reduced, or nothing changes."""
    with _lock:
        for item in reservation.items:
            product = _products.get(item.product_id)
            if not product:
                RESERVATIONS.labels("unknown_product").inc()
                raise HTTPException(404, f"unknown product {item.product_id}")
            if product["stock"] < item.quantity:
                RESERVATIONS.labels("out_of_stock").inc()
                raise HTTPException(409, f"only {product['stock']} × {product['name']} left")
        lines = []
        for item in reservation.items:
            product = _products[item.product_id]
            product["stock"] -= item.quantity
            lines.append(
                {
                    "product_id": item.product_id,
                    "name": product["name"],
                    "quantity": item.quantity,
                    "price_pence": product["price_pence"],
                }
            )
    RESERVATIONS.labels("ok").inc()
    total = sum(line["price_pence"] * line["quantity"] for line in lines)
    return {"items": lines, "total_pence": total}
