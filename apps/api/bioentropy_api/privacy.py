"""Reject physiological / biometric fields on API payloads.

Hosts and API never accept ADC, HR, SpO₂, or related signals (AGENTS.md).
"""

from __future__ import annotations

from typing import Any

from fastapi import HTTPException, status

# Names commonly used for physio / raw biometrics — never accepted on this API.
PHYSIO_FIELD_NAMES: frozenset[str] = frozenset(
    {
        "bpm",
        "hr",
        "heartrate",
        "heart_rate",
        "heartRate",
        "spo2",
        "spo_2",
        "SpO2",
        "spo₂",
        "oxygen",
        "oxygen_saturation",
        "pulse",
        "ppg",
        "ecg",
        "adc",
        "waveform",
        "morphology",
        "raw",
        "rawSignal",
        "raw_signal",
        "biometric",
        "biometrics",
        "physio",
        "physiology",
        "blood_pressure",
        "bloodPressure",
        "bp",
        "seed",
        "privateKey",
        "private_key",
    }
)


def assert_no_physio_fields(payload: dict[str, Any] | None) -> None:
    """Raise 422 if any known physio / secret field is present (any nesting depth)."""
    if not payload:
        return
    found = _find_physio_keys(payload)
    if found:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail={
                "error": "physiological_fields_rejected",
                "message": "API must not receive biometric or physiological fields",
                "fields": sorted(found),
            },
        )


def _find_physio_keys(obj: Any, found: set[str] | None = None) -> set[str]:
    if found is None:
        found = set()
    if isinstance(obj, dict):
        for key, value in obj.items():
            if key in PHYSIO_FIELD_NAMES or key.lower() in {
                n.lower() for n in PHYSIO_FIELD_NAMES
            }:
                found.add(key)
            _find_physio_keys(value, found)
    elif isinstance(obj, list):
        for item in obj:
            _find_physio_keys(item, found)
    return found
