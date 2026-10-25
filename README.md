# Lab 2FA — Wearable presence + ML-KEM unlock

Public portfolio POC: **Mi Band** + phone (Flutter) + desktop (Tauri).

| Piece | What it does |
|--------|----------------|
| **Wearable gate** | Live heart rate (+ steps) required on the phone before an unlock succeeds. |
| **ML-KEM unlock** | At pair the phone sends an ML-KEM-512 **public key**. On app open the desktop **encapsulates**; the phone **decapsulates** and returns a proof the desktop verifies with its shared secret. |
| **On-device seed demo** | **Generate PQC hash** (and unlock) derive a local bio seed → 16×16 matrix → SHA3 + digests. Visual / audit — biometrics never leave the phone. |

Not production auth. Not medical.

## Two secrets (do not confuse them)

| | **ML-KEM session key** | **Bio seed (band)** |
|--|------------------------|---------------------|
| **When created** | Once at **pair** (QR) | **Every unlock** (and optional Generate button) |
| **Where kept** | `sk` in phone RAM; `pk` in desktop RAM | Phone only; wiped after use |
| **Changes with BPM?** | No | Yes — by design |
| **Role in unlock** | Desktop validates with KEM shared secret `ss` | Bound into the proof as `seedDigest` only (not re-checked against an old seed) |

Unlock does **not** ask “is this the same seed as last time?”.  
It asks “does this paired phone hold the session `sk`, prove this challenge, and attest a fresh on-device seed digest?”

```
presenceProof = SHA3(ss ‖ challengeId ‖ bandMac ‖ seedDigest)
```

- `ss` — from ML-KEM encaps/decaps (session) → **what makes verification possible**  
- `seedDigest` — `SHA3(bioSeed)` for *this* unlock → binding / audit, discarded with the seed  

## Why this beats “HR → ok: true”

| Approach | Desktop verifies |
|----------|------------------|
| HR → `ok: true` | Nothing cryptographic |
| **ML-KEM encaps + presenceProof** | Shared secret from the paired session + challenge binding |

## Flow

```
Pair (QR)
  phone   → ML-KEM keygen → pair.register (kemPublicKey + nonce)
  desktop → validate nonce + pk → pair.ok (or pair.error)
  phone   → Sync only after pair.ok  (presence.update keeps band ready)

Unlock gated app (requires synced = paired ∧ mobile online ∧ band ready)
  desktop → encapsulate(pk) → (ct, ss)
          → challenge.request + kemCiphertext
  phone   → live HR → fresh bio seed → wipe seed after
          → ss' = decapsulate(sk, ct)
          → presenceProof = SHA3(ss' ‖ challengeId ‖ bandMac ‖ seedDigest)
  desktop → recompute proof with its ss → launch + lease, or deny
```

**Synced** is live session state — never true from disk alone. Re-pair after restarting desktop/phone so the session keypair matches again. If Sync fails, the phone shows `pair.error` (e.g. `pairingNonce mismatch` after a stale QR).

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

1. Connect Mi Band (force-stop Mi Fitness first)  
2. Optional: **Generate PQC hash** (matrix = seed visualization only)  
3. Desktop: **Refresh QR** → phone: scan → wait for **Sync** (`pair.ok`)  
4. **Add apps** → enable 2FA → Open → phone proves KEM + presence → app launches  

## Privacy

- No BPM / raw bio seed / ML-KEM secret key on the wire  
- Contract: [`packages/protocol/lab-host-mobile.md`](packages/protocol/lab-host-mobile.md)  
- Do not commit `.env` / Huami auth keys  

## Status

Lab / portfolio quality. ML-KEM-512 interop verified (Dart `pqcrypto` ↔ Rust `ml-kem`). Pairing is ACK’d (`pair.ok` / `pair.error`); unlock is Option A encaps/decaps + presence proof.
