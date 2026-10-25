# Lab host ↔ mobile message examples (frozen)

Frozen JSON shapes for Bioentropy lab 2FA (host / mobile / API metadata).  
**Never** include physiological fields (`bpm`, `hr`, `spo2`, ADC, waveforms) or raw seeds / ML-KEM secret keys.

Version field `v` is `1` for this lab slice.

Architecture: local QR/WS primary; optional API pairing tickets.

## QR payload (desktop → phone scan)

```json
{
  "v": 1,
  "wsUrl": "ws://192.168.1.10:8787",
  "pairingNonce": "...",
  "desktopName": "lab-pc",
  "apiTicketId": null
}
```

## Pair register

Phone generates an **ML-KEM-512** keypair for the session, keeps `sk` in memory, and sends `kemPublicKey` (800 bytes hex) so the desktop can encapsulate on unlock.

```json
{
  "v": 1,
  "type": "pair.register",
  "pairingNonce": "...",
  "bandMac": "AA:BB:CC:DD:EE:FF",
  "deviceLabel": "phone",
  "kemPublicKey": "<1600 hex chars = 800 bytes>",
  "kemPubFp": "<64 hex chars SHA3-256(pk)>"
}
```

## Presence update

```json
{
  "v": 1,
  "type": "presence.update",
  "bandMac": "AA:BB:CC:DD:EE:FF",
  "bandReady": true
}
```

## Challenge request (unlock)

Desktop encapsulate(`kemPublicKey`) → `(ct, ss)`. Sends `ct`; keeps `ss` to verify the result.

```json
{
  "v": 1,
  "type": "challenge.request",
  "challengeId": "<uuid>",
  "purpose": "open_app",
  "appId": "firefox",
  "expiresAt": "<iso8601>",
  "kemCiphertext": "<1536 hex chars = 768 bytes>"
}
```

## Challenge result

Phone: live HR → bio seed → PQC audit digests; `ss' = decapsulate(sk, ct)`;

`presenceProof = SHA3-256(ss' ‖ challengeId ‖ 0x00 ‖ bandMac ‖ 0x00 ‖ seedDigest)`

Desktop accepts only if `presenceProof` equals the same formula with its `ss`.

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

`seedDigest` / `pqcSha3` / `pqcKemFp` are digests only (audit / UI). Never the bio seed.
