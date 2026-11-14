"""Unit tests for orders – run with: make test (or pytest in this folder).

catalog is replaced by a fake reserve_stock(); SQLite writes to a temp folder.
"""

import httpx
import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient

from orders import db, main, migrate
from orders.shopkit import Faults, request_id_var

SESSION = {"X-Session-ID": "test-session"}
ORDER = {"items": [{"product_id": "mug", "quantity": 2}]}


def fake_reservation(items):
    return {
        "items": [{"product_id": "mug", "name": "Rocket Mug", "quantity": 2, "price_pence": 1250}],
        "total_pence": 2500,
    }


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setattr(db, "DATA_DIR", tmp_path)
    monkeypatch.setattr(main, "_schema_ready", False)
    monkeypatch.setattr(main, "reserve_stock", fake_reservation)
    main.app.state.faults = Faults()  # all faults off
    with TestClient(main.app) as test_client:
        yield test_client


# ── shared behaviour (shopkit) ──────────────────────────────────────────────


def test_health_endpoints(client):
    for probe in ("started", "ready", "live"):
        assert client.get(f"/health/{probe}").status_code == 200, probe


def test_not_ready_without_database(client, monkeypatch, tmp_path):
    monkeypatch.setattr(db, "DATA_DIR", tmp_path / "missing")  # SQLite cannot create the file
    monkeypatch.setattr(main, "_schema_ready", False)
    assert client.get("/health/ready").status_code == 503
    assert client.get("/health/live").status_code == 200  # live never checks dependencies


def test_info(client):
    body = client.get("/info").json()
    assert body["app"] == "orders"
    assert set(body) == {"app", "version", "revision", "pod"}


def test_metrics_business_counter(client):
    client.post("/orders", json=ORDER, headers=SESSION)
    assert 'shop_orders_total{result="placed"}' in client.get("/metrics").text


def test_fault_error_rate(client):
    client.app.state.faults.error_rate = 1.0
    assert client.post("/orders", json=ORDER, headers=SESSION).status_code == 503


def test_admin_disabled_without_token(client, monkeypatch):
    monkeypatch.delenv("ADMIN_TOKEN", raising=False)
    assert client.post("/admin/fault", json={"delay_ms": 10}).status_code == 404


# ── orders ──────────────────────────────────────────────────────────────────


def test_place_and_list(client):
    response = client.post("/orders", json=ORDER, headers=SESSION)
    assert response.status_code == 201
    placed = response.json()
    assert placed["total_pence"] == 2500 and len(placed["id"]) == 8

    body = client.get("/orders", headers=SESSION).json()
    assert [o["id"] for o in body["orders"]] == [placed["id"]]
    assert body["storage"] == "sqlite" and body["persistent"] is False
    assert client.get("/orders", headers={"X-Session-ID": "other"}).json()["orders"] == []


def test_out_of_stock_is_rejected(client, monkeypatch):
    def no_stock(items):
        raise HTTPException(409, "only 1 × Rocket Mug left")

    monkeypatch.setattr(main, "reserve_stock", no_stock)
    response = client.post("/orders", json=ORDER, headers=SESSION)
    assert response.status_code == 409
    assert client.get("/orders", headers=SESSION).json()["orders"] == []


def test_catalog_down_gives_503(client, monkeypatch):
    def catalog_down(items):
        raise httpx.ConnectError("connection refused")

    monkeypatch.setattr(main, "reserve_stock", catalog_down)
    assert client.post("/orders", json=ORDER, headers=SESSION).status_code == 503


def test_database_down_does_not_reserve_stock(client, monkeypatch, tmp_path):
    called = []
    monkeypatch.setattr(main, "reserve_stock", lambda items: called.append(items))
    monkeypatch.setattr(db, "DATA_DIR", tmp_path / "missing")
    monkeypatch.setattr(main, "_schema_ready", False)
    assert client.post("/orders", json=ORDER, headers=SESSION).status_code == 503
    assert called == []  # catalog was never asked


def test_session_and_items_required(client):
    assert client.post("/orders", json=ORDER).status_code == 400
    assert client.post("/orders", json={"items": []}, headers=SESSION).status_code == 422


def test_reserve_stock_passes_request_id(monkeypatch):
    seen = {}

    def fake_catalog(request):
        seen["request_id"] = request.headers.get("X-Request-ID")
        return httpx.Response(200, json=fake_reservation(None))

    fake_client = httpx.Client(transport=httpx.MockTransport(fake_catalog))
    monkeypatch.setattr(main.httpx, "post", fake_client.post)
    request_id_var.set("req-42")
    main.reserve_stock([main.Item(product_id="mug", quantity=2)])
    assert seen["request_id"] == "req-42"


def test_migrate_command(tmp_path, monkeypatch):
    monkeypatch.setattr(db, "DATA_DIR", tmp_path)
    assert migrate.main() == 0
    assert (tmp_path / "orders.db").exists()
