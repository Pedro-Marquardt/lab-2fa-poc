"""Pairing ticket create / complete and physio rejection."""

from __future__ import annotations


def test_create_pairing_ticket(client):
    res = client.post("/v1/pairing/tickets")
    assert res.status_code == 201
    data = res.json()
    assert "ticketId" in data
    assert "pairingNonce" in data
    assert "expiresAt" in data
    assert len(data["pairingNonce"]) >= 16


def test_get_pairing_ticket(client):
    created = client.post("/v1/pairing/tickets").json()
    res = client.get(f"/v1/pairing/tickets/{created['ticketId']}")
    assert res.status_code == 200
    data = res.json()
    assert data["ticketId"] == created["ticketId"]
    assert data["pairingNonce"] == created["pairingNonce"]
    assert data["status"] == "pending"


def test_complete_pairing_ticket(client):
    created = client.post("/v1/pairing/tickets").json()
    ticket_id = created["ticketId"]
    res = client.post(
        f"/v1/pairing/tickets/{ticket_id}/complete",
        json={"bandMac": "AA:BB:CC:DD:EE:FF", "deviceLabel": "phone"},
    )
    assert res.status_code == 200
    data = res.json()
    assert data["status"] == "completed"
    assert data["bandMac"] == "AA:BB:CC:DD:EE:FF"
    assert data["deviceLabel"] == "phone"

    status = client.get(f"/v1/pairing/tickets/{ticket_id}").json()
    assert status["status"] == "completed"
    assert status["bandMac"] == "AA:BB:CC:DD:EE:FF"


def test_complete_pairing_rejects_bpm(client):
    created = client.post("/v1/pairing/tickets").json()
    res = client.post(
        f"/v1/pairing/tickets/{created['ticketId']}/complete",
        json={
            "bandMac": "AA:BB:CC:DD:EE:FF",
            "deviceLabel": "phone",
            "bpm": 72,
        },
    )
    assert res.status_code == 422
    detail = res.json()["detail"]
    assert detail["error"] == "physiological_fields_rejected"
    assert "bpm" in detail["fields"]


def test_complete_pairing_rejects_hr_and_spo2(client):
    created = client.post("/v1/pairing/tickets").json()
    res = client.post(
        f"/v1/pairing/tickets/{created['ticketId']}/complete",
        json={
            "bandMac": "AA:BB:CC:DD:EE:FF",
            "deviceLabel": "phone",
            "hr": 70,
            "spo2": 98,
        },
    )
    assert res.status_code == 422
    detail = res.json()["detail"]
    assert detail["error"] == "physiological_fields_rejected"
    assert set(detail["fields"]) >= {"hr", "spo2"}


def test_complete_unknown_ticket_404(client):
    res = client.post(
        "/v1/pairing/tickets/00000000-0000-0000-0000-000000000000/complete",
        json={"bandMac": "AA:BB:CC:DD:EE:FF", "deviceLabel": "phone"},
    )
    assert res.status_code == 404
