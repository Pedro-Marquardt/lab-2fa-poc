# Lab host ↔ mobile message examples (frozen)

Frozen JSON shapes for Bioentropy lab 2FA (host / mobile / API metadata).  
**Never** include physiological fields (`bpm`, `hr`, `spo2`, ADC, waveforms, seeds).

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

```json
{
  "v": 1,
  "type": "pair.register",
  "pairingNonce": "...",
  "bandMac": "AA:BB:CC:DD:EE:FF",
  "deviceLabel": "phone"
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

Issued by the lab desktop (or relayed from API metadata) when opening a gated app.

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

Audit outcome only — success flag + band MAC. No physio. BPM is validated **on the phone** before this is sent.

```json
{
  "v": 1,
  "type": "challenge.result",
  "challengeId": "<uuid>",
  "ok": true,
  "bandMac": "AA:BB:CC:DD:EE:FF",
  "reason": null
}
```

## API mapping (lab)

| Message | Lab HTTP |
|---------|----------|
| ticket create (nonce) | `POST /v1/pairing/tickets` → `{ ticketId, pairingNonce, expiresAt }` |
| `pair.register` (optional audit) | `POST /v1/pairing/tickets/{ticketId}/complete` body `{ bandMac, deviceLabel }` |
| `challenge.request` | `POST /v1/challenges` → `{ challengeId, purpose, appId, expiresAt }` |
| `challenge.result` | `POST /v1/challenges/{id}/complete` body `{ ok, bandMac, reason? }` |
