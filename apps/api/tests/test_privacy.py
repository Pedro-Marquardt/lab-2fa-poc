"""Unit tests for physio field detection."""

from __future__ import annotations

import pytest
from fastapi import HTTPException

from bioentropy_api.privacy import assert_no_physio_fields


def test_allows_metadata_only():
    assert_no_physio_fields(
        {"bandMac": "AA:BB:CC:DD:EE:FF", "deviceLabel": "phone", "ok": True}
    )


def test_rejects_nested_spo2():
    with pytest.raises(HTTPException) as exc:
        assert_no_physio_fields({"meta": {"spo2": 99}})
    assert exc.value.status_code == 422
    assert "spo2" in exc.value.detail["fields"]
