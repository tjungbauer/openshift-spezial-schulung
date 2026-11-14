"""Unit tests for cart – run with: make test (or pytest in this folder)."""

import pytest
from fastapi.testclient import TestClient

from cart import main
from cart.shopkit import Faults

SESSION = {"X-Session-ID": "test-session"}


@pytest.fixture
def client():
    main.app.state.faults = Faults()  # all faults off
    main._carts.clear()
    with TestClient(main.app) as test_client:
        yield test_client


# ── shared behaviour (shopkit) ──────────────────────────────────────────────


def test_health_endpoints(client):
    for probe in ("started", "ready", "live"):
        assert client.get(f"/health/{probe}").status_code == 200, probe


def test_info(client):
    body = client.get("/info").json()
    assert body["app"] == "cart"
    assert set(body) == {"app", "version", "revision", "pod"}


def test_metrics(client):
    client.put("/cart/items/mug", json={"quantity": 2}, headers=SESSION)
    text = client.get("/metrics").text
    assert "shop_cart_items_added_total 2.0" in text
    assert 'endpoint="/cart/items/{product_id}"' in text


def test_fault_error_rate_and_ready(client):
    client.app.state.faults.error_rate = 1.0
    assert client.get("/cart", headers=SESSION).status_code == 503
    client.app.state.faults.fail_ready = True
    assert client.get("/health/ready").status_code == 503
    assert client.get("/health/live").status_code == 200


def test_admin_toggles_faults(client, monkeypatch):
    monkeypatch.setenv("ADMIN_TOKEN", "s3cret")
    response = client.post(
        "/admin/fault", json={"error_rate": 1.0}, headers={"Authorization": "Bearer s3cret"}
    )
    assert response.json()["error_rate"] == 1.0
    assert client.get("/cart", headers=SESSION).status_code == 503


# ── cart ────────────────────────────────────────────────────────────────────


def test_session_header_required(client):
    assert client.get("/cart").status_code == 400


def test_add_change_remove(client):
    assert client.get("/cart", headers=SESSION).json() == {"items": [], "count": 0}
    client.put("/cart/items/mug", json={"quantity": 1}, headers=SESSION)
    body = client.put("/cart/items/socks", json={"quantity": 3}, headers=SESSION).json()
    assert body["count"] == 4
    body = client.put("/cart/items/socks", json={"quantity": 0}, headers=SESSION).json()
    assert body["items"] == [{"product_id": "mug", "quantity": 1}]
    assert client.delete("/cart/items/mug", headers=SESSION).json()["count"] == 0


def test_sessions_are_separate(client):
    client.put("/cart/items/mug", json={"quantity": 1}, headers=SESSION)
    assert client.get("/cart", headers={"X-Session-ID": "other"}).json()["count"] == 0


def test_clear(client):
    client.put("/cart/items/mug", json={"quantity": 5}, headers=SESSION)
    client.delete("/cart", headers=SESSION)
    assert client.get("/cart", headers=SESSION).json()["count"] == 0
