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
| **Bioentropy feeds the seed** | Live band metrics act as physical entropy → local 32-byte seed (wiped); only `seedDigest` is bound into the proof. |
| **Session crypto can be post-quantum ready** | Pair uses **ML-KEM-512** (NIST FIPS 203). Quantum threatens classical key exchange; lattice KEMs are the migration this lab exercises. |
| **Two secrets, two jobs** | Pairing keypair ≠ bio seed. Confusing them breaks the story — see below. |

It does **not** prove production MFA, medical HR accuracy, TRNG-grade entropy, or that wearables are unforgeable. It proves an architecture: **bioentropy seed + PQC session + verifiable presence**.

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

## Why bioentropy → seed (and how that meets quantum)

**Bioentropy** here means treating the wearable snapshot (live HR, steps, cached SpO₂, …) as a **physical entropy source**: noisy, time-bound, hard to replay exactly, and inseparable from a body/device in the loop. That material is folded (SHAKE-256 in this lab) into a **32-byte bio seed**, visualized as the 16×16 matrix, then wiped. Only `seedDigest` ever leaves the phone.

That is a different job from “password = BPM”:

| Layer | Question it answers |
|-------|---------------------|
| **Bioentropy seed** | Was this unlock fed by a **fresh physical snapshot**, not a canned file or bot? |
| **ML-KEM session** | Can the desktop **cryptographically verify** the paired phone without trusting a bare `ok: true`? |

Post-quantum algorithms still need **unpredictable seeds** for key material. A cryptographically relevant quantum computer (Shor) breaks RSA/ECDH *algorithms*; it does not invent free entropy for you. The Bioentropy product thesis (MCU + Secure Element) is: derive **ephemeral PQC keys from bioentropy + physiological fingerprint on-device**, wipe immediately, never upload raw biometrics. This lab approximates that story with a Mi Band + phone: **body-sourced entropy → local seed → digests**, while **ML-KEM** carries the NIST (FIPS 203) key-establishment path that survives the quantum migration.

So the pair is intentional:

1. **Quantum-safe channel** — ML-KEM encaps/decaps (session `ss`)  
2. **Human/physical binding** — bioentropy seed digest inside `presenceProof`  

Without (1), verification is classical and aging. Without (2), PQC alone does not prove a human was present.

## Why ML-KEM on the wire?

Large-scale quantum computers threaten the public-key schemes we still use for key exchange (RSA, finite-field / elliptic Diffie–Hellman). Symmetric crypto and SHA3-class hashes are far less exposed; the urgent migration is **key establishment**. This POC uses **ML-KEM-512** so unlock verification already sits on that track — while bioentropy answers *presence*, not *algorithm*.

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
