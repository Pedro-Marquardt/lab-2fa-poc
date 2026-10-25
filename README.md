# Lab 2FA — Wearable presence + on-device PQC demo

Public portfolio POC: **Mi Band** + phone (Flutter) + desktop (Tauri).

Two ideas in one demo — keep them straight:

| Piece | What it actually does |
|--------|------------------------|
| **Wearable 2FA** | Live heart rate proves presence. Unlock sends a **presence proof** the desktop **verifies** (not a naked `ok: true`). Bound to this challenge + paired session. |
| **On-device PQC** | Same unlock (and the **Generate PQC hash** button) derives a local seed from band signals → matrix → SHA3-256 + ML-KEM-512. **Demo / portfolio** of post-quantum material on-device — it is **not** what makes the 2FA stronger than a normal MAC over the pair session. |

Biometrics (BPM, steps, SpO₂, raw seed) **never leave the phone**.

Not production auth. Not medical.

## Why not “just heart rate”?

| Approach | Desktop sees | Gap |
|----------|--------------|-----|
| HR → `ok: true` | A boolean | Any client on the WS can lie |
| HR → **presence proof** | `SHA3(presenceKey ‖ challengeId ‖ bandMac ‖ seedDigest)` | Desktop recomputes; needs the pair session + this challenge |

The useful jump for 2FA is **verifiable proof**, not ML-KEM by itself.

## Flow

```
Pair (QR / LAN WS)
  phone: ML-KEM session → presenceKey (+ kemPubFp audit)
  desktop: stores presenceKey + band MAC

Unlock gated app
  desktop → challenge.request (challengeId)
  phone  → live HR (+ steps) → bio seed (wipe after)
         → seedDigest + PQC audit (SHA3 / ML-KEM fp)
         → presenceProof
  desktop → verify proof → launch (or deny)
```

**Generate PQC hash** on the phone is the visual explainer (matrix + hashes). Unlock runs that pipeline again with a **fresh** seed each time — nothing durable is stored as “the” seed.

## Layout

```
apps/
  mobile/     # Flutter — Mi Band BLE, QR/WS, seed + PQC demo, presence proof
  desktop/    # Tauri — QR, WS :8787, proof verify, gated launcher
  api/        # FastAPI — optional tickets / non-biometric audit
packages/
  protocol/   # Frozen host↔mobile JSON shapes
docs/
  research/   # Mi Band / Huami notes
```

## Quick start

**Desktop**

```bash
cd apps/desktop
npm install
npm run dev
```

**Mobile**

```bash
cd apps/mobile
cp .env.example .env   # MIBAND_AUTH_KEY + optional MIBAND_MAC
flutter pub get
flutter run
```

Phone and PC on the same Wi‑Fi. Force-stop Mi Fitness before connecting the band.

Optional API: `apps/api` or `docker compose up --build`.

## Demo script

1. Connect Mi Band → HR (+ steps) on the phone  
2. Optional: **Generate PQC hash** → matrix + SHA3 + ML-KEM fingerprint  
3. Scan desktop QR → pair (session `presenceKey`)  
4. Toggle **2FA** on an app → open it → phone proves presence + proof → desktop verifies → app launches  

Re-pair after restarting the desktop/phone session so `presenceKey` matches.

## Privacy

- No BPM / SpO₂ / steps / seed on the wire — digests + proof only  
- Contract: [`packages/protocol/lab-host-mobile.md`](packages/protocol/lab-host-mobile.md)  
- Do not commit `.env` or Huami auth keys  

## Status

Lab / portfolio quality. Honest scope: wearable presence + verifiable challenge proof; PQC as an on-device demo layered on the same seed path.
