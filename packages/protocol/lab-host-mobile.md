# Lab host ↔ mobile message examples (frozen)

Frozen JSON shapes for Bioentropy lab 2FA (host / mobile / API metadata).  
**Never** include physiological fields (`bpm`, `hr`, `spo2`, ADC, waveforms) or raw seeds.

Version field `v` is `1` for this lab slice.

Architecture: local QR/WS primary; optional API pairing tickets.

## QR payload (desktop → phone scan)

Primary pairing channel. `apiTicketId` / `apiBaseUrl` are set only when the desktop minted a lab API ticket (`BIOENTROPY_API_URL`).

Without API (local nonce):

```json
{
  "v": 1,
  "wsUrl": "ws://192.168.1.10:8787",
  "pairingNonce": "...",
  "desktopName": "lab-pc",
  "apiTicketId": null
}
```

With optional API ticket:

```json
{
  "v": 1,
  "wsUrl": "ws://192.168.1.10:8787",
  "pairingNonce": "<from POST /v1/pairing/tickets>",
  "desktopName": "lab-pc",
  "apiTicketId": "<ticketId>",
  "apiBaseUrl": "http://127.0.0.1:8000"
}
```

## Pair register

Host/mobile completes pairing over WebSocket. When `apiTicketId` was present, mobile may also `POST …/complete` (best-effort; must not break local pair).

Desktop marks **sincronizado** only after this message on the **current** WS session (persisted MAC alone is not enough) plus live band presence.

At pair the phone also runs **ML-KEM-512 keygen**, derives a local `presenceKey` (SHA3 of secret material), and sends it over the paired LAN channel so the desktop can **verify** unlock proofs. `kemPubFp` is audit/display only.

```json
{
  "v": 1,
  "type": "pair.register",
  "pairingNonce": "...",
  "bandMac": "AA:BB:CC:DD:EE:FF",
  "deviceLabel": "phone",
  "presenceKey": "<64 hex chars = 32 bytes>",
  "kemPubFp": "<64 hex chars SHA3-256(ML-KEM pk)>"
}
```

## Presence update

Mobile → desktop whenever band readiness changes. No BPM values. Desktop clears sync when `bandReady` is false or WS drops.

```json
{
  "v": 1,
  "type": "presence.update",
  "bandMac": "AA:BB:CC:DD:EE:FF",
  "bandReady": true
}
```

## Challenge request

Issued by the lab desktop when opening a gated app (unlock).

```json
{
  "v": 1,
  "type": "challenge.request",
  "challengeId": "<uuid>",
  "purpose": "open_app",
  "appId": "firefox",
  "expiresAt": "<iso8601>"
}
```

## Challenge result

On success the phone must have live band presence, derive an on-device bio seed (HR + steps + …), run the PQC demo pipeline, and return a **verifiable** presence proof:

`presenceProof = SHA3-256(presenceKey ‖ challengeId ‖ 0x00 ‖ bandMac ‖ 0x00 ‖ seedDigest)`

`seedDigest = SHA3-256(bioSeed)` — digest only, never the seed.  
`pqcSha3` / `pqcKemFp` are audit fields from the same on-device pipeline (SHA3-256(seed) and ML-KEM pubkey fingerprint).

```json
{
  "v": 1,
  "type": "challenge.result",
  "challengeId": "<uuid>",
  "ok": true,
  "bandMac": "AA:BB:CC:DD:EE:FF",
  "reason": null,
  "presenceProof": "<64 hex>",
  "seedDigest": "<64 hex>",
  "pqcSha3": "<64 hex>",
  "pqcKemFp": "<64 hex>"
}
```

Desktop rejects unlock if `ok` is true but proof/digest/PQC fields are missing or `presenceProof` does not match the recomputed value.

## API mapping (lab)

| Message | Lab HTTP |
|---------|----------|
| ticket create (nonce) | `POST /v1/pairing/tickets` → `{ ticketId, pairingNonce, expiresAt }` |
| `pair.register` (optional audit) | `POST /v1/pairing/tickets/{ticketId}/complete` body `{ bandMac, deviceLabel }` |
| `challenge.request` | `POST /v1/challenges` → `{ challengeId, purpose, appId, expiresAt }` |
| `challenge.result` | `POST /v1/challenges/{id}/complete` body `{ ok, bandMac, reason? }` |
