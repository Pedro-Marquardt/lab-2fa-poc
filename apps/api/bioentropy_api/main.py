"""Bioentropy lab FastAPI application.

Privacy: never accept or store HR/BPM/SpO₂/raw biometrics (AGENTS.md).
"""

from __future__ import annotations

from fastapi import FastAPI
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import ValidationError

from bioentropy_api.routers import challenges, pairing
from bioentropy_api.store import LabStore, store as default_store

app = FastAPI(
    title="Bioentropy Lab API",
    version="0.1.0",
    description=(
        "Lab API for pairing tickets and app-open challenges. "
        "Stores only non-biometric metadata (IDs, nonces, MAC, labels, outcomes)."
    ),
)
app.state.store = default_store

app.include_router(pairing.router)
app.include_router(challenges.router)


@app.exception_handler(ValidationError)
async def pydantic_validation_handler(_request, exc: ValidationError) -> JSONResponse:
    return JSONResponse(
        status_code=422,
        content={"detail": exc.errors()},
    )


@app.exception_handler(RequestValidationError)
async def request_validation_handler(_request, exc: RequestValidationError) -> JSONResponse:
    return JSONResponse(status_code=422, content={"detail": exc.errors()})


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


def create_app(*, lab_store: LabStore | None = None) -> FastAPI:
    """Factory for tests — inject a fresh LabStore."""
    if lab_store is not None:
        app.state.store = lab_store
    return app
