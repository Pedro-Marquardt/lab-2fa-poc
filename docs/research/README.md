# Research notes (lab)

This POC uses **Xiaomi / Huami Mi Band** over BLE as a lab heart-rate source.

Useful public references:

- [Gadgetbridge](https://codeberg.org/Freeyourgadget/Gadgetbridge) — reverse-engineered Huami protocols
- Huami “New Auth” (ECDH + AES) with a per-device auth key extracted from Mi Fitness / companion tooling

Auth keys and `.env` must never be committed. BPM is validated on the phone only and is not sent to desktop/API.
