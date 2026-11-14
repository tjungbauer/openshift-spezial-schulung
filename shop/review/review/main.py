"""review – star ratings (1–5) per product.

The ratings come from a JSON file baked into the image (one list of stars
per product id). Mount a ConfigMap and point REVIEWS_FILE at it to change
them without a new image.

review is optional for the shop: when it is down, the UI simply shows no
stars – browsing, the cart and placing orders keep working. Scale it to 0
to show that.
"""

import json
import os
from pathlib import Path

from fastapi import HTTPException
from prometheus_client import Counter

from .shopkit import create_app, log

REVIEWS_FILE = Path(os.getenv("REVIEWS_FILE", Path(__file__).with_name("reviews.json")))

SERVED = Counter("shop_review_lookups_total", "Rating lookups", ["scope"])

_ratings: dict[str, list[int]] = {}


def load_reviews() -> None:
    try:
        ratings = json.loads(REVIEWS_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        log.exception("cannot load reviews", extra={"fields": {"file": str(REVIEWS_FILE)}})
        return
    _ratings.clear()
    _ratings.update({pid: [s for s in stars if 1 <= s <= 5] for pid, stars in ratings.items()})
    log.info("reviews loaded", extra={"fields": {"products": len(_ratings), "file": str(REVIEWS_FILE)}})


def _summary(stars: list[int]) -> dict:
    return {"stars": round(sum(stars) / len(stars), 1), "count": len(stars)}


app = create_app("review", ready_check=lambda: bool(_ratings), on_startup=load_reviews)


@app.get("/reviews")
def all_reviews():
    """Average stars and number of ratings for every product that has ratings."""
    SERVED.labels("all").inc()
    return {"reviews": {pid: _summary(stars) for pid, stars in _ratings.items() if stars}}


@app.get("/reviews/{product_id}")
def product_reviews(product_id: str):
    stars = _ratings.get(product_id)
    if not stars:
        raise HTTPException(404, f"no reviews for {product_id}")
    SERVED.labels("product").inc()
    return {"product_id": product_id, **_summary(stars), "ratings": stars}
