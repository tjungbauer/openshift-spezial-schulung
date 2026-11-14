"""Unit tests for catalog – run with: make test (or pytest in this folder)."""

import time

import pytest
from fastapi.testclient import TestClient

from catalog import main
from catalog.shopkit import Faults


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setattr(main, "NEW_LOOK", False)
    app = main.app
    app.state.faults = Faults()  # all faults off
    with TestClient(app) as test_client:
        main.load_products()  # fresh stock for every test
        yield test_client


# ── shared behaviour (shopkit) ──────────────────────────────────────────────


def test_health_endpoints(client):
    for probe in ("started", "ready", "live"):
        response = client.get(f"/health/{probe}")
        assert response.status_code == 200, probe


def test_info(client, monkeypatch):
    body = client.get("/info").json()
    assert body["app"] == "catalog"
    assert set(body) == {"app", "version", "revision", "pod"}


def test_response_headers_and_request_id(client):
    response = client.get("/products", headers={"X-Request-ID": "abc123"})
    assert response.headers["X-Request-ID"] == "abc123"
    assert response.headers["X-Shop-App"] == "catalog"
    assert "X-Shop-Pod" in response.headers


def test_metrics(client):
    client.get("/products")
    text = client.get("/metrics").text
    assert 'shop_http_requests_total{endpoint="/products",method="GET",status="200"}' in text
    assert "shop_stock_reservations_total" in text


def test_fault_error_rate(client):
    client.app.state.faults.error_rate = 1.0
    assert client.get("/products").status_code == 503
    assert client.get("/health/ready").status_code == 200  # health is never failed


def test_fault_delay(client):
    client.app.state.faults.delay_ms = 200
    start = time.monotonic()
    client.get("/products")
    assert time.monotonic() - start >= 0.2


def test_fault_fail_ready(client):
    client.app.state.faults.fail_ready = True
    assert client.get("/health/ready").status_code == 503
    assert client.get("/health/live").status_code == 200


def test_fault_startup_delay(client):
    client.app.state.faults.startup_delay_s = 3600
    assert client.get("/health/started").status_code == 503
    assert client.get("/health/ready").status_code == 503


def test_faults_from_env(monkeypatch):
    monkeypatch.setenv("FAULT_DELAY_MS", "150")
    monkeypatch.setenv("FAULT_ERROR_RATE", "0.25")
    monkeypatch.setenv("FAULT_FAIL_READY", "true")
    faults = Faults.from_env()
    assert (faults.delay_ms, faults.error_rate, faults.fail_ready) == (150, 0.25, True)


def test_admin_disabled_without_token(client, monkeypatch):
    monkeypatch.delenv("ADMIN_TOKEN", raising=False)
    assert client.post("/admin/fault", json={"error_rate": 1}).status_code == 404


def test_admin_toggles_faults(client, monkeypatch):
    monkeypatch.setenv("ADMIN_TOKEN", "s3cret")
    assert client.post("/admin/fault", json={"error_rate": 1}).status_code == 401
    response = client.post(
        "/admin/fault", json={"fail_ready": True}, headers={"Authorization": "Bearer s3cret"}
    )
    assert response.status_code == 200 and response.json()["fail_ready"] is True
    assert client.get("/health/ready").status_code == 503


# ── catalog ─────────────────────────────────────────────────────────────────


def test_list_products(client):
    body = client.get("/products").json()
    assert body["theme"] == "v1"
    assert 8 <= len(body["products"]) <= 12
    assert all("badge" not in p for p in body["products"])


def test_version_2_new_look(client, monkeypatch):
    monkeypatch.setattr(main, "NEW_LOOK", True)
    body = client.get("/products").json()
    assert body["theme"] == "v2"
    assert any(p.get("badge") == "new" for p in body["products"])


def test_product_details_and_404(client):
    assert client.get("/products/mug").json()["name"] == "Rocket Mug"
    assert client.get("/products/nope").status_code == 404


def test_reserve_reduces_stock(client):
    before = client.get("/products/mug").json()["stock"]
    response = client.post("/stock/reserve", json={"items": [{"product_id": "mug", "quantity": 2}]})
    assert response.status_code == 200
    assert response.json()["total_pence"] == 2 * 1250
    assert client.get("/products/mug").json()["stock"] == before - 2


def test_reserve_is_all_or_nothing(client):
    before = client.get("/products/mug").json()["stock"]
    items = [{"product_id": "mug", "quantity": 1}, {"product_id": "headphones", "quantity": 99}]
    assert client.post("/stock/reserve", json={"items": items}).status_code == 409
    assert client.get("/products/mug").json()["stock"] == before


def test_reserve_unknown_product(client):
    response = client.post("/stock/reserve", json={"items": [{"product_id": "nope", "quantity": 1}]})
    assert response.status_code == 404
