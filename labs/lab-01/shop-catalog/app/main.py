"""shop-catalog – a tiny catalogue API.

    GET /items   the catalogue
    GET /info    version, git revision and pod – the same strings as in the image tag and labels
    GET /health  for probes
"""

import os
import socket

from fastapi import FastAPI

VERSION = os.getenv("APP_VERSION", "dev")
REVISION = os.getenv("APP_REVISION", "unknown")

ITEMS = [
    {"id": 1, "name": "Red fedora", "price": 29.90},
    {"id": 2, "name": "OpenShift mug", "price": 12.50},
    {"id": 3, "name": "Sticker pack", "price": 1.00},
]

app = FastAPI(title="shop-catalog", version=VERSION)


@app.get("/items")
def items():
    return ITEMS


@app.get("/info")
def info():
    return {"app": "shop-catalog", "version": VERSION, "revision": REVISION, "pod": socket.gethostname()}


@app.get("/health")
def health():
    return {"status": "UP"}
