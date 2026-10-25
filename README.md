# Lab 2FA — Wearable presence + ML-KEM unlock

Public portfolio POC: **Mi Band** + phone (Flutter) + desktop (Tauri).

| Piece | What it does |
|--------|----------------|
| **Wearable gate** | Live heart rate (+ steps) required on the phone before an unlock succeeds. |
| **ML-KEM unlock (Option A)** | At pair the phone sends an ML-KEM-512 **public key**. On app open the desktop **encapsulates**; the phone **decapsulates** and returns `presenceProof = SHA3(ss ‖ challengeId ‖ bandMac ‖ seedDigest)`. Desktop verifies with its `ss`. |
| **On-device PQC demo** | **Generate PQC hash** (and unlock) derive a local bio seed → 16×16 matrix → SHA3 + ML-KEM fingerprints. Visual / audit only — biometrics never leave the phone. |

Not production auth. Not medical.

## Why this beats “HR → ok: true”

| Approach | Desktop verifies |
|----------|------------------|
| HR → `ok: true` | Nothing cryptographic |
| **ML-KEM encaps + presenceProof** | Shared secret from KEM + challenge binding |

## Flow

```
Pair (QR)
  phone → ML-KEM keygen → kemPublicKey (sk stays on phone)

Unlock gated app
  desktop → encapsulate(pk) → (ct, ss) → challenge.request + kemCiphertext
  phone   → live HR → bio seed → decapsulate(ct) → presenceProof
  desktop → recompute proof with ss → launch or deny
```

Each unlock uses a **fresh** bio seed (wiped after). Re-pair after restarting a session.

## Layout

```
apps/mobile/    Flutter — BLE, QR/WS, seed demo, ML-KEM decaps
apps/desktop/   Tauri — QR, WS :8787, ML-KEM encaps, gated launcher
apps/api/       optional FastAPI tickets
packages/protocol/  frozen JSON shapes
```

## Quick start

```bash
cd apps/desktop && npm install && npm run dev
```

```bash
cd apps/mobile
cp .env.example .env   # MIBAND_AUTH_KEY + optional MIBAND_MAC
flutter pub get && flutter run
```

Same Wi‑Fi. Force-stop Mi Fitness before connecting the band.

## Demo script

1. Connect Mi Band  
2. Optional: **Generate PQC hash** (matrix + digests)  
3. Pair via QR  
4. **Add apps** → enable 2FA → Open → phone proves ML-KEM + presence → app launches  

## Privacy

- No BPM / seed / ML-KEM secret key on the wire  
- Contract: [`packages/protocol/lab-host-mobile.md`](packages/protocol/lab-host-mobile.md)  
- Do not commit `.env` / Huami auth keys  

## Status

Lab / portfolio quality. ML-KEM-512 interop verified between Dart `pqcrypto` and Rust `ml-kem`.
