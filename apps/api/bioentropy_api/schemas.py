"""Pydantic schemas — metadata only; no physiological fields."""

from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field


class StrictModel(BaseModel):
    """Forbid undeclared fields so physio extras cannot sneak in via known models."""

    model_config = ConfigDict(extra="forbid")


# --- Pairing ---


class PairingTicketCreateResponse(StrictModel):
    ticketId: str
    pairingNonce: str
    expiresAt: datetime


class PairingTicketStatusResponse(StrictModel):
    ticketId: str
    pairingNonce: str
    expiresAt: datetime
    status: Literal["pending", "completed", "expired"]
    bandMac: str | None = None
    deviceLabel: str | None = None


class PairingCompleteRequest(StrictModel):
    bandMac: str = Field(..., min_length=11, max_length=17, examples=["AA:BB:CC:DD:EE:FF"])
    deviceLabel: str = Field(..., min_length=1, max_length=64, examples=["phone"])


class PairingCompleteResponse(StrictModel):
    ticketId: str
    status: Literal["completed"]
    bandMac: str
    deviceLabel: str


# --- Challenges ---


class ChallengeCreateRequest(StrictModel):
    purpose: str = Field(..., min_length=1, max_length=64, examples=["open_app"])
    appId: str = Field(..., min_length=1, max_length=64, examples=["firefox"])
    ttlSeconds: int = Field(default=120, ge=30, le=600)


class ChallengeCreateResponse(StrictModel):
    challengeId: str
    purpose: str
    appId: str
    expiresAt: datetime


class ChallengeCompleteRequest(StrictModel):
    ok: bool
    bandMac: str = Field(..., min_length=11, max_length=17, examples=["AA:BB:CC:DD:EE:FF"])
    reason: str | None = Field(default=None, max_length=256)


class ChallengeCompleteResponse(StrictModel):
    ok: bool
    bandMac: str
    challengeId: str
