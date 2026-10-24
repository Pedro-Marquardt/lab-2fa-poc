"""Challenge endpoints — session metadata and audit outcome only."""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter, HTTPException, Request, status

from bioentropy_api.deps import StoreDep
from bioentropy_api.privacy import assert_no_physio_fields
from bioentropy_api.schemas import (
    ChallengeCompleteRequest,
    ChallengeCompleteResponse,
    ChallengeCreateRequest,
    ChallengeCreateResponse,
)

router = APIRouter(prefix="/v1/challenges", tags=["challenges"])


@router.post("", response_model=ChallengeCreateResponse, status_code=status.HTTP_201_CREATED)
async def create_challenge(
    store: StoreDep,
    request: Request,
) -> ChallengeCreateResponse:
    raw: Any = await request.json()
    if not isinstance(raw, dict):
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="body_must_be_object",
        )
    assert_no_physio_fields(raw)
    body = ChallengeCreateRequest.model_validate(raw)

    challenge = store.create_challenge(
        purpose=body.purpose,
        app_id=body.appId,
        ttl_seconds=body.ttlSeconds,
    )
    return ChallengeCreateResponse(
        challengeId=challenge.challenge_id,
        purpose=challenge.purpose,
        appId=challenge.app_id,
        expiresAt=challenge.expires_at,
    )


@router.post("/{challenge_id}/complete", response_model=ChallengeCompleteResponse)
async def complete_challenge(
    challenge_id: str,
    store: StoreDep,
    request: Request,
) -> ChallengeCompleteResponse:
    raw: Any = await request.json()
    if not isinstance(raw, dict):
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="body_must_be_object",
        )
    assert_no_physio_fields(raw)
    body = ChallengeCompleteRequest.model_validate(raw)

    existing = store.get_challenge(challenge_id)
    if existing is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="challenge_not_found")
    if existing.status == "expired":
        raise HTTPException(status_code=status.HTTP_410_GONE, detail="challenge_expired")
    if existing.status == "completed":
        if existing.ok == body.ok and existing.band_mac == body.bandMac:
            return ChallengeCompleteResponse(
                ok=existing.ok if existing.ok is not None else body.ok,
                bandMac=existing.band_mac or body.bandMac,
                challengeId=existing.challenge_id,
            )
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="challenge_already_completed",
        )

    challenge = store.complete_challenge(
        challenge_id,
        ok=body.ok,
        band_mac=body.bandMac,
        reason=body.reason,
    )
    if challenge is None or challenge.band_mac is None or challenge.ok is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="challenge_not_found")

    return ChallengeCompleteResponse(
        ok=challenge.ok,
        bandMac=challenge.band_mac,
        challengeId=challenge.challenge_id,
    )
