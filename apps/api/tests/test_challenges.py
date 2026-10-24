"""Challenge create / complete and physio rejection."""

from __future__ import annotations


def test_create_challenge(client):
    res = client.post(
        "/v1/challenges",
        json={"purpose": "open_app", "appId": "firefox"},
    )
    assert res.status_code == 201
    data = res.json()
    assert "challengeId" in data
    assert data["purpose"] == "open_app"
    assert data["appId"] == "firefox"
    assert "expiresAt" in data


def test_complete_challenge_audit_only(client):
    created = client.post(
        "/v1/challenges",
        json={"purpose": "open_app", "appId": "firefox"},
    ).json()
    res = client.post(
        f"/v1/challenges/{created['challengeId']}/complete",
        json={"ok": True, "bandMac": "AA:BB:CC:DD:EE:FF", "reason": None},
    )
    assert res.status_code == 200
    data = res.json()
    assert data["ok"] is True
    assert data["bandMac"] == "AA:BB:CC:DD:EE:FF"
    assert data["challengeId"] == created["challengeId"]
    assert "bpm" not in data
    assert "hr" not in data
    assert "spo2" not in data


def test_complete_challenge_rejects_physio(client):
    created = client.post(
        "/v1/challenges",
        json={"purpose": "open_app", "appId": "firefox"},
    ).json()
    res = client.post(
        f"/v1/challenges/{created['challengeId']}/complete",
        json={
            "ok": True,
            "bandMac": "AA:BB:CC:DD:EE:FF",
            "heartRate": 68,
        },
    )
    assert res.status_code == 422
    detail = res.json()["detail"]
    assert detail["error"] == "physiological_fields_rejected"
    assert "heartRate" in detail["fields"]


def test_health(client):
    res = client.get("/health")
    assert res.status_code == 200
    assert res.json() == {"status": "ok"}
