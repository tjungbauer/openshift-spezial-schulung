"""Unit tests for review – run with: make test (or pytest in this folder)."""

import pytest
from fastapi.testclient import TestClient

from review import main
from review.shopkit import Faults


@pytest.fixture
def client():
    main.app.state.faults = Faults()  # all faults off
    with TestClient(main.app) as test_client:
        yield test_client


# ── shared behaviour (shopkit) ──────────────────────────────────────────────


def test_health_endpoints(client):
    for probe in ("started", "ready", "live"):
        assert client.get(f"/health/{probe}").status_code == 200, probe


def test_not_ready_without_reviews(client, monkeypatch):
    monkeypatch.setattr(main, "_ratings", {})
    assert client.get("/health/ready").status_code == 503
    assert client.get("/health/live").status_code == 200


def test_info(client):
    body = client.get("/info").json()
    assert body["app"] == "review"
    assert set(body) == {"app", "version", "revision", "pod"}


def test_metrics(client):
    client.get("/reviews")
    assert 'shop_review_lookups_total{scope="all"}' in client.get("/metrics").text


def test_fault_error_rate(client):
    client.app.state.faults.error_rate = 1.0
    assert client.get("/reviews").status_code == 503
    assert client.get("/health/ready").status_code == 200


def test_admin_disabled_without_token(client, monkeypatch):
    monkeypatch.delenv("ADMIN_TOKEN", raising=False)
    assert client.post("/admin/fault", json={"fail_ready": True}).status_code == 404


# ── review ──────────────────────────────────────────────────────────────────


def test_every_catalog_product_has_ratings(client):
    reviews = client.get("/reviews").json()["reviews"]
    assert set(reviews) >= {"mug", "socks", "teddy"}
    for summary in reviews.values():
        assert 1 <= summary["stars"] <= 5 and summary["count"] > 0


def test_product_reviews(client):
    body = client.get("/reviews/mug").json()
    assert body["count"] == len(body["ratings"])
    assert body["stars"] == round(sum(body["ratings"]) / body["count"], 1)


def test_unknown_product(client):
    assert client.get("/reviews/nope").status_code == 404


def test_invalid_stars_are_ignored(tmp_path, monkeypatch):
    path = tmp_path / "reviews.json"
    path.write_text('{"mug": [5, 9, 0, 3]}')
    monkeypatch.setattr(main, "REVIEWS_FILE", path)
    main.load_reviews()
    assert main._ratings == {"mug": [5, 3]}
    monkeypatch.undo()
    main.load_reviews()  # restore the real data for other tests
