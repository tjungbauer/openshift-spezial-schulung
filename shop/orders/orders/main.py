"""orders – place an order and list the orders of a session.

Placing an order asks catalog to check and reduce the stock (all or nothing),
then stores the order. The session id comes from the X-Session-ID header
(web creates it, see the cart service).

Ready means: the database is reachable and the table exists. catalog is NOT
part of the readiness check – if catalog is down, orders still answers (with
503 for new orders) instead of disappearing from the Service as well.
"""

import os
import uuid
from datetime import datetime, timezone

import httpx
from fastapi import Header, HTTPException
from prometheus_client import Counter
from pydantic import BaseModel, Field

from . import db
from .shopkit import POD, create_app, downstream_headers, log

CATALOG_URL = os.getenv("CATALOG_URL", "http://catalog:8080")

ORDERS = Counter("shop_orders_total", "Orders by result", ["result"])

_schema_ready = False


def ready() -> bool:
    """Database reachable and table in place (migrates on first success)."""
    global _schema_ready
    if not _schema_ready:
        try:
            db.migrate()
            _schema_ready = True
        except Exception as error:
            log.warning("database not ready", extra={"fields": {"error": str(error)}})
            return False
    return db.ping()


app = create_app("orders", ready_check=ready, on_startup=ready)


class Item(BaseModel):
    product_id: str
    quantity: int = Field(gt=0, le=100)


class NewOrder(BaseModel):
    items: list[Item] = Field(min_length=1)


def reserve_stock(items: list[Item]) -> dict:
    """POST /stock/reserve on catalog – passes on the request id (and trace context)."""
    response = httpx.post(
        f"{CATALOG_URL}/stock/reserve",
        json={"items": [item.model_dump() for item in items]},
        headers=downstream_headers(),
        timeout=5.0,
    )
    if response.status_code in (404, 409):
        raise HTTPException(409, response.json().get("detail", "not available"))
    response.raise_for_status()
    return response.json()


@app.post("/orders", status_code=201)
def place_order(order: NewOrder, x_session_id: str | None = Header(None)):
    if not x_session_id:
        raise HTTPException(400, "missing X-Session-ID header")
    if not ready():  # check before touching the stock – no lost reservations
        ORDERS.labels("failed").inc()
        raise HTTPException(503, "order database unavailable – please try again")
    try:
        reservation = reserve_stock(order.items)
    except HTTPException:
        ORDERS.labels("rejected").inc()
        raise
    except httpx.HTTPError as error:
        ORDERS.labels("failed").inc()
        log.error("catalog unavailable", extra={"fields": {"error": str(error)}})
        raise HTTPException(503, "catalog unavailable – please try again") from error

    placed = {
        "id": uuid.uuid4().hex[:8].upper(),
        "session_id": x_session_id,
        "created": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "total_pence": reservation["total_pence"],
        "items": reservation["items"],
        "pod": POD,
    }
    db.save(placed)
    ORDERS.labels("placed").inc()
    log.info("order placed", extra={"fields": {"order_id": placed["id"], "total_pence": placed["total_pence"]}})
    placed.pop("session_id")
    return placed


@app.get("/orders")
def list_orders(x_session_id: str | None = Header(None)):
    if not x_session_id:
        raise HTTPException(400, "missing X-Session-ID header")
    return {
        "orders": db.list_for_session(x_session_id),
        "storage": db.kind(),
        "persistent": db.persistent(),
    }
