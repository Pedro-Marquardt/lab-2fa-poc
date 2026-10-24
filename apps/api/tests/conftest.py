"""Shared fixtures — fresh in-memory store per test."""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from bioentropy_api.main import app
from bioentropy_api.store import LabStore


@pytest.fixture()
def lab_store() -> LabStore:
    return LabStore()


@pytest.fixture()
def client(lab_store: LabStore):
    app.state.store = lab_store
    with TestClient(app) as test_client:
        yield test_client
    app.state.store = LabStore()
