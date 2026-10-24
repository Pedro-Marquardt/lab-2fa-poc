"""Pairing ticket endpoints — nonces and device metadata only."""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter, HTTPException, Request, status

from bioentropy_api.deps import StoreDep
from bioentropy_api.privacy import assert_no_physio_fields
from bioentropy_api.schemas import (
    PairingCompleteRequest,
    PairingCompleteResponse,
    PairingTicketCreateResponse,
    PairingTicketStatusResponse,
)

router = APIRouter(prefix="/v1/pairing", tags=["pairing"])


@router.post(
    "/tickets",
    response_model=PairingTicketCreateResponse,
    status_code=status.HTTP_201_CREATED,
)
async def create_pairing_ticket(store: StoreDep) -> PairingTicketCreateResponse:
    ticket = store.create_ticket()
    return PairingTicketCreateResponse(
        ticketId=ticket.ticket_id,
        pairingNonce=ticket.pairing_nonce,
        expiresAt=ticket.expires_at,
    )


@router.get("/tickets/{ticket_id}", response_model=PairingTicketStatusResponse)
async def get_pairing_ticket(ticket_id: str, store: StoreDep) -> PairingTicketStatusResponse:
    ticket = store.get_ticket(ticket_id)
    if ticket is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="ticket_not_found")
    return PairingTicketStatusResponse(
        ticketId=ticket.ticket_id,
        pairingNonce=ticket.pairing_nonce,
        expiresAt=ticket.expires_at,
        status=ticket.status,
        bandMac=ticket.band_mac,
        deviceLabel=ticket.device_label,
    )


@router.post("/tickets/{ticket_id}/complete", response_model=PairingCompleteResponse)
async def complete_pairing_ticket(
    ticket_id: str,
    store: StoreDep,
    request: Request,
) -> PairingCompleteResponse:
    raw: Any = await request.json()
    if not isinstance(raw, dict):
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="body_must_be_object",
        )
    assert_no_physio_fields(raw)
    body = PairingCompleteRequest.model_validate(raw)

    existing = store.get_ticket(ticket_id)
    if existing is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="ticket_not_found")
    if existing.status == "expired":
        raise HTTPException(status_code=status.HTTP_410_GONE, detail="ticket_expired")
    if existing.status == "completed":
        if (
            existing.band_mac == body.bandMac
            and existing.device_label == body.deviceLabel
        ):
            return PairingCompleteResponse(
                ticketId=existing.ticket_id,
                status="completed",
                bandMac=existing.band_mac or body.bandMac,
                deviceLabel=existing.device_label or body.deviceLabel,
            )
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="ticket_already_completed",
        )

    ticket = store.complete_ticket(
        ticket_id, band_mac=body.bandMac, device_label=body.deviceLabel
    )
    if ticket is None or ticket.band_mac is None or ticket.device_label is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="ticket_not_found")

    return PairingCompleteResponse(
        ticketId=ticket.ticket_id,
        status="completed",
        bandMac=ticket.band_mac,
        deviceLabel=ticket.device_label,
    )
