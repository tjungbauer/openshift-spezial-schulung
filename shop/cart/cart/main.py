"""cart – one shopping cart per session, kept in memory.

The session id arrives in the X-Session-ID header: web creates it, stores
it in the cookie "shop_session" and passes it on with every /api/cart call.

The carts live in this pod's memory: they are gone after a restart, and a
second replica does not know the carts of the first one. That is on purpose
– it makes a good lab discussion about state.
"""

import threading

from fastapi import Header, HTTPException
from prometheus_client import Counter, Gauge
from pydantic import BaseModel, Field

from .shopkit import create_app

ITEMS_ADDED = Counter("shop_cart_items_added_total", "Items put into carts")
CARTS = Gauge("shop_carts", "Carts held in memory")

_lock = threading.Lock()
_carts: dict[str, dict[str, int]] = {}  # session id -> {product id: quantity}

app = create_app("cart")


def _session(x_session_id: str | None) -> str:
    if not x_session_id:
        raise HTTPException(400, "missing X-Session-ID header (set by web from the shop_session cookie)")
    return x_session_id


def _view(cart: dict[str, int]) -> dict:
    items = [{"product_id": pid, "quantity": qty} for pid, qty in cart.items()]
    return {"items": items, "count": sum(cart.values())}


@app.get("/cart")
def get_cart(x_session_id: str | None = Header(None)):
    with _lock:
        return _view(_carts.get(_session(x_session_id), {}))


class Quantity(BaseModel):
    quantity: int = Field(ge=0, le=100)


@app.put("/cart/items/{product_id}")
def set_item(product_id: str, body: Quantity, x_session_id: str | None = Header(None)):
    """Set the quantity of one product; 0 removes it."""
    session = _session(x_session_id)
    with _lock:
        cart = _carts.setdefault(session, {})
        added = body.quantity - cart.get(product_id, 0)
        if body.quantity:
            cart[product_id] = body.quantity
        else:
            cart.pop(product_id, None)
        CARTS.set(len(_carts))
        view = _view(cart)
    if added > 0:
        ITEMS_ADDED.inc(added)
    return view


@app.delete("/cart/items/{product_id}")
def remove_item(product_id: str, x_session_id: str | None = Header(None)):
    with _lock:
        cart = _carts.get(_session(x_session_id), {})
        cart.pop(product_id, None)
        return _view(cart)


@app.delete("/cart")
def clear_cart(x_session_id: str | None = Header(None)):
    with _lock:
        _carts.pop(_session(x_session_id), None)
        CARTS.set(len(_carts))
    return {"items": [], "count": 0}
