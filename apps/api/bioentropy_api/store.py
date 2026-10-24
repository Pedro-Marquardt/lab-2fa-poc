"""In-memory lab store for pairing tickets and challenges.

Lab-only: process-local, not durable. Reset between tests via LabStore.clear().
"""

from __future__ import annotations

import secrets
import threading
import uuid
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from typing import Literal


def _utcnow() -> datetime:
    return datetime.now(UTC)


def _new_id() -> str:
    return str(uuid.uuid4())


def _new_nonce() -> str:
    return secrets.token_urlsafe(24)


@dataclass
class PairingTicket:
    ticket_id: str
    pairing_nonce: str
    expires_at: datetime
    status: Literal["pending", "completed", "expired"] = "pending"
    band_mac: str | None = None
    device_label: str | None = None

    def refresh_status(self) -> None:
        if self.status == "pending" and _utcnow() >= self.expires_at:
            self.status = "expired"


@dataclass
class Challenge:
    challenge_id: str
    purpose: str
    app_id: str
    expires_at: datetime
    status: Literal["open", "completed", "expired"] = "open"
    ok: bool | None = None
    band_mac: str | None = None
    reason: str | None = None

    def refresh_status(self) -> None:
        if self.status == "open" and _utcnow() >= self.expires_at:
            self.status = "expired"


@dataclass
class LabStore:
    """Thread-safe in-memory store for the lab API."""

    _lock: threading.Lock = field(default_factory=threading.Lock)
    tickets: dict[str, PairingTicket] = field(default_factory=dict)
    challenges: dict[str, Challenge] = field(default_factory=dict)
    ticket_ttl: timedelta = field(default_factory=lambda: timedelta(minutes=10))

    def clear(self) -> None:
        with self._lock:
            self.tickets.clear()
            self.challenges.clear()

    def create_ticket(self) -> PairingTicket:
        ticket = PairingTicket(
            ticket_id=_new_id(),
            pairing_nonce=_new_nonce(),
            expires_at=_utcnow() + self.ticket_ttl,
        )
        with self._lock:
            self.tickets[ticket.ticket_id] = ticket
        return ticket

    def get_ticket(self, ticket_id: str) -> PairingTicket | None:
        with self._lock:
            ticket = self.tickets.get(ticket_id)
            if ticket is None:
                return None
            ticket.refresh_status()
            return ticket

    def complete_ticket(
        self, ticket_id: str, *, band_mac: str, device_label: str
    ) -> PairingTicket | None:
        with self._lock:
            ticket = self.tickets.get(ticket_id)
            if ticket is None:
                return None
            ticket.refresh_status()
            if ticket.status != "pending":
                return ticket
            ticket.status = "completed"
            ticket.band_mac = band_mac
            ticket.device_label = device_label
            return ticket

    def create_challenge(
        self, *, purpose: str, app_id: str, ttl_seconds: int
    ) -> Challenge:
        challenge = Challenge(
            challenge_id=_new_id(),
            purpose=purpose,
            app_id=app_id,
            expires_at=_utcnow() + timedelta(seconds=ttl_seconds),
        )
        with self._lock:
            self.challenges[challenge.challenge_id] = challenge
        return challenge

    def get_challenge(self, challenge_id: str) -> Challenge | None:
        with self._lock:
            challenge = self.challenges.get(challenge_id)
            if challenge is None:
                return None
            challenge.refresh_status()
            return challenge

    def complete_challenge(
        self,
        challenge_id: str,
        *,
        ok: bool,
        band_mac: str,
        reason: str | None,
    ) -> Challenge | None:
        with self._lock:
            challenge = self.challenges.get(challenge_id)
            if challenge is None:
                return None
            challenge.refresh_status()
            if challenge.status != "open":
                return challenge
            challenge.status = "completed"
            challenge.ok = ok
            challenge.band_mac = band_mac
            challenge.reason = reason
            return challenge


# Process-wide lab store (tests replace via dependency override / clear).
store = LabStore()
