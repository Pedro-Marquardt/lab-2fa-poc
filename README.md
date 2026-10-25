# Lab 2FA — Wearable presence + post-quantum unlock

Public portfolio POC: **Mi Band** + phone (Flutter) + desktop (Tauri).

A local demo of **human presence** (live wearable) bound to a **verifiable unlock** (ML-KEM-512), without sending biometrics off the phone.

Not production auth. Not medical.

## What this POC proves

| Claim | How the lab shows it |
|--------|----------------------|
| **A bot / remote script is not enough** | Unlock needs a **live** Mi Band HR session on the paired phone — not a stored flag. |
| **“ok: true” over the wire is not verification** | Desktop only launches after recomputing `presenceProof` with its own ML-KEM shared secret. |
| **Biometrics can stay on-device** | BPM, steps, SpO₂ cache, and the raw bio seed never leave the phone; the wire carries digests + a KEM proof. |
| **Session crypto can be post-quantum ready** | Pair uses **ML-KEM-512** (NIST FIPS 203 family). Classical RSA/ECDH session keys are the ones a future cryptographically relevant quantum computer threatens; lattice KEMs are the migration path this lab exercises. |
| **Two secrets, two jobs** | Pairing keypair ≠ bio seed. Confusing them breaks the story — see below. |

It does **not** prove production MFA, medical HR accuracy, or that wearables are unforgeable. It proves an architecture: **presence + PQC session + local seed binding**.

## Two secrets (do not confuse them)

| | **ML-KEM session key** | **Bio seed (band)** |
|--|------------------------|---------------------|
| **When created** | Once at **pair** (QR) | **Every unlock** (and optional Generate button) |
| **Where kept** | `sk` in phone RAM; `pk` in desktop RAM | Phone only; wiped after use |
| **Changes with BPM?** | No | Yes — by design |
| **Role in unlock** | Desktop validates with KEM shared secret `ss` | Bound into the proof as `seedDigest` only |

Unlock does **not** ask “is this the same seed as last time?”.  
It asks “does this paired phone hold the session `sk`, prove this challenge, and attest a fresh on-device seed digest?”

```
presenceProof = SHA3(ss ‖ challengeId ‖ bandMac ‖ seedDigest)
```

- `ss` — from ML-KEM encaps/decaps (session) → **what makes verification possible**
- `seedDigest` — `SHA3(bioSeed)` for *this* unlock → binding / audit, discarded with the seed

## Why post-quantum here?

Large-scale quantum computers (Shor) break the public-key schemes we still lean on for key exchange (RSA, finite-field / elliptic Diffie–Hellman). Symmetric crypto and SHA3-class hashes are far less exposed; the urgent migration is **key establishment**.

This POC uses **ML-KEM** so the unlock channel is already on the NIST post-quantum track: the desktop encapsulate / phone decapsulate step is the piece that would need to survive that transition — while the wearable gate answers a different question: *is a real device/person in the loop right now?*

## Step-by-step flow

### A. Pair (create the ML-KEM session)

1. Phone and PC on the **same Wi‑Fi**; force-stop Mi Fitness; connect the Mi Band in the Flutter app (HR streaming).
2. Desktop: **Refresh QR** (commits a fresh `pairingNonce`; optional API ticket if `BIOENTROPY_API_URL` is set).
3. Phone: **Pair with desktop** → scan the QR (`wsUrl` + nonce).
4. Phone generates ML-KEM-512 `(pk, sk)`, sends `pair.register` with `kemPublicKey` + nonce + `bandMac`.
5. Desktop checks nonce + pk length → persists pairing → replies **`pair.ok`** (or **`pair.error`** with a reason).
6. Phone shows **Sync** only after `pair.ok`. `presence.update` keeps `bandReady` while HR is live.

**Synced** = paired ∧ mobile online ∧ band ready — live session only, never from disk alone. Restart desktop/phone → re-pair so `sk`/`pk` match again.

### B. Unlock a gated app

1. Desktop **Apps** → add an installed app → enable **2FA** → **Open** (blocked until synced).
2. Desktop: `encapsulate(pk)` → `(kemCiphertext, ss)` → `challenge.request` over WS.
3. Phone: wait for a **valid live BPM** → derive a **fresh** bio seed (HR + steps + cached SpO₂, etc.) → wipe seed after use.
4. Phone: `ss' = decapsulate(sk, ct)` → build `presenceProof` + audit digests (`seedDigest`, `pqcSha3`, …) → `challenge.result` (**no** BPM/seed/`sk` on the wire).
5. Desktop: recompute the proof with its `ss`; check `bandMac` + PQC audit fields → **spawn app + lease**, or deny / timeout.

### C. Optional on-device demo button

**Generate PQC hash** runs the same local seed → 16×16 matrix → SHA3 / ML-KEM fingerprint path for UI — it does not replace the desktop challenge.

## Architecture sketch

```
┌─────────────┐   BLE HR/steps    ┌──────────────┐
│   Mi Band   │ ───────────────► │ Flutter phone │
└─────────────┘                  │  sk, bio seed │
                                 └───────┬───────┘
                    QR + WS :8787        │
              pair.register / challenge.*│
                                 ┌───────▼───────┐
                                 │ Tauri desktop │
                                 │  pk, encaps   │
                                 │  gate + lease │
                                 └───────────────┘
```

## Layout

```
apps/mobile/         Flutter — BLE, QR/WS, seed demo, ML-KEM decaps
apps/desktop/        Tauri — QR, WS :8787, ML-KEM encaps, gated launcher
apps/api/            optional FastAPI pairing tickets
packages/protocol/   frozen JSON shapes
```

Wire contract: [`packages/protocol/lab-host-mobile.md`](packages/protocol/lab-host-mobile.md)

## Quick start

```bash
cd apps/desktop && npm install && npm run dev
```

```bash
cd apps/mobile
cp .env.example .env   # MIBAND_AUTH_KEY + optional MIBAND_MAC
flutter pub get && flutter run
```

Same LAN; allow TCP **8787**. Optional: `BIOENTROPY_API_URL=http://127.0.0.1:8000` on the desktop.

## Privacy

- No BPM / raw bio seed / ML-KEM secret key on the wire
- Do not commit `.env` / Huami auth keys

## Status

Lab / portfolio quality. ML-KEM-512 interop verified (Dart `pqcrypto` ↔ Rust `ml-kem`). Pairing ACK’d (`pair.ok` / `pair.error`); unlock is encaps/decaps + presence proof.
