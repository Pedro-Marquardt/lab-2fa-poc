# Lab 2FA (Mi Band POC)

Public proof-of-concept: **Mi Band** + phone (Flutter) + desktop (Tauri) two-factor gate for launching apps.

1. Phone connects to Mi Band over BLE and streams heart rate **locally**
2. Desktop shows a QR → phone pairs over LAN WebSocket and registers the band MAC
3. Apps marked with the **2FA** toggle only open after a live challenge (phone proves BPM is capturable; **BPM never leaves the phone**)

Optional lab API issues pairing tickets / non-biometric audit metadata.

## Layout

```
apps/
  mobile/     # Flutter — Mi Band BLE + QR/WS challenge
  desktop/    # Tauri — QR pairing, WS :8787, gated app launcher
  api/        # FastAPI — pairing tickets + challenge audit (no physio)
packages/
  protocol/   # Frozen host↔mobile JSON shapes
docs/
  research/   # Mi Band / Huami lab notes
```

## Quick start

**API (optional)**

```bash
cd apps/api && python3 -m venv .venv && source .venv/bin/activate
pip install -e ".[dev]"
uvicorn bioentropy_api.main:app --reload --host 0.0.0.0 --port 8000
# or from repo root: docker compose up --build
```

**Desktop**

```bash
cd apps/desktop
npm install
# optional tickets:
# BIOENTROPY_API_URL=http://127.0.0.1:8000 npm run dev
npm run dev
```

Linux needs Tauri `-dev` packages (see `apps/desktop/README.md`).

**Mobile**

```bash
cd apps/mobile
cp .env.example .env   # MIBAND_AUTH_KEY + optional MIBAND_MAC
flutter pub get
flutter run
```

Phone and PC must share Wi‑Fi. Force-stop Mi Fitness before connecting the band.

## Privacy (lab)

- Heart rate / SpO₂ stay on the phone for the BPM gate
- Wire protocol carries `ok` + `bandMac` only — see [`packages/protocol/lab-host-mobile.md`](packages/protocol/lab-host-mobile.md)
- Do not commit `.env` or Huami auth keys

## Status

Lab / demo quality. Not a medical product. Not production auth.
