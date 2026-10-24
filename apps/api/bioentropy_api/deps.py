"""FastAPI dependencies."""

from __future__ import annotations

from typing import Annotated

from fastapi import Depends, Request

from bioentropy_api.store import LabStore, store as default_store


def get_store(request: Request) -> LabStore:
    """Prefer app.state.store when set (tests); otherwise module singleton."""
    return getattr(request.app.state, "store", default_store)


StoreDep = Annotated[LabStore, Depends(get_store)]
