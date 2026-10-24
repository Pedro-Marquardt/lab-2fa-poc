# apps/desktop — Bioentropy Lab 2FA

**Thin client:** UI + LAN pairing + challenge-gated app launch. No biometric storage; BPM never leaves the phone.

E2E with phone: [`apps/mobile`](../mobile/). Optional audit API: [`apps/api`](../api/). Wire shapes: [`packages/protocol/lab-host-mobile.md`](../../packages/protocol/lab-host-mobile.md).

## What this lab app does

1. Runs a **WebSocket server on `:8787`** (Rust, `0.0.0.0`)
2. Runs a **loopback gate API on `127.0.0.1:8788`** (`POST /v1/open`) for dock/CLI wrappers
3. On boot + while running: **process supervisor** kills apps with Require 2FA unless they have a post-challenge **lease** (~10 min max TTL, or until the app is closed — **not** a refresh token). Failed challenge **revokes** the lease and kills the app. Reset leases: close the gated app, fail a challenge, or restart Lab 2FA (boot clears all leases).
4. Shows a **QR** with the frozen pairing payload (`apiTicketId: null` unless API URL is set)
5. Accepts `pair.register` from mobile → persists `{ bandMac, pairedAt }` locally
6. **Apps** tab: curated launchers (browser, terminal, file manager, editor) + custom path + require-2FA toggle
7. With 2FA ON → Open disabled until mobile paired+online → `challenge.request` → wait for `challenge.result` → verify `bandMac` → spawn + lease; on fail/timeout/unpaired do **not** launch

### Optional API tickets

If `BIOENTROPY_API_URL` is set (e.g. `http://127.0.0.1:8000`), on boot / Refresh QR / Unpair the desktop `POST`s `/v1/pairing/tickets` and embeds `apiTicketId`, `apiBaseUrl`, and the API `pairingNonce` in the QR. Loopback hosts in the env URL are rewritten to the desktop LAN IP in the QR so the phone can reach the API. Bind the API with `--host 0.0.0.0` (or the LAN IP) when using a real device. If unset, behavior stays local (`apiTicketId: null`).

```bash
BIOENTROPY_API_URL=http://127.0.0.1:8000 npm run dev
```

## Frozen wire contract

QR (phone scans):

```json
{
  "v": 1,
  "wsUrl": "ws://<lan-ip>:8787",
  "pairingNonce": "...",
  "desktopName": "lab-pc",
  "apiTicketId": null
}
```

With API:

```json
{
  "v": 1,
  "wsUrl": "ws://<lan-ip>:8787",
  "pairingNonce": "<from API>",
  "desktopName": "lab-pc",
  "apiTicketId": "<ticketId>",
  "apiBaseUrl": "http://127.0.0.1:8000"
}
```

Mobile → desktop:

```json
{ "v": 1, "type": "pair.register", "pairingNonce": "...", "bandMac": "...", "deviceLabel": "phone" }
```

Desktop → mobile (when Open + 2FA):

```json
{
  "v": 1,
  "type": "challenge.request",
  "challengeId": "uuid",
  "purpose": "open_app",
  "appId": "...",
  "expiresAt": "iso"
}
```

Mobile → desktop:

```json
{
  "v": 1,
  "type": "challenge.result",
  "challengeId": "...",
  "ok": true,
  "bandMac": "...",
  "reason": null
}
```

Local data (no biometrics): `~/.local/share/bioentropy-lab2fa/{pairing,config}.json`

## Prerequisites (Linux)

- Rust (`rustup`) + Node/npm
- Tauri Linux **dev** packages (runtime libs alone are not enough):

```bash
sudo apt install libwebkit2gtk-4.1-dev build-essential curl wget file \
  libxdo-dev libssl-dev libayatana-appindicator3-dev librsvg2-dev \
  libdbus-1-dev libgtk-3-dev
```

Without those `-dev` packages, `cargo check` / `npm run dev` fail at build-script (`webkit2gtk`, `dbus`, `gtk`, …).

Phone and PC must share a LAN; firewall must allow TCP **8787** (WS). Gate API is loopback-only (`:8788`).

## Run

```bash
cd apps/desktop
npm install
BIOENTROPY_API_URL=http://127.0.0.1:8000 npm run dev
# equivalent: npx tauri dev
```

Build release:

```bash
npm run build
```

### OS gate (Firefox from dock/menu)

While Lab 2FA is running, gated binaries are killed unless opened via challenge (UI Open or wrapper). Install a **user-level** Firefox override:

```bash
./scripts/install-firefox-gate.sh
```

Wrapper behaviour (`scripts/bioentropy-gate`):

- Lab up → `POST http://127.0.0.1:8788/v1/open` `{ "appId": "browser" }` (challenge, then desktop spawns)
- Lab down → `exec` real Firefox (no block)

## Layout

| Path | Role |
|------|------|
| `src/` | Vanilla HTML/CSS/JS UI (pairing + apps) |
| `src-tauri/src/` | Tauri v2 + WS + supervisor + local gate API + spawn |
| `scripts/bioentropy-gate` | Dock/CLI wrapper (passthrough if lab down) |
| `scripts/install-firefox-gate.sh` | `~/.local/share/applications/firefox.desktop` override |

## Explicit non-goals

- Heavy host crypto engine (out of scope for this POC)
- ADC / biometric signals on the wire or disk
- OS login / session unlock (GDM) — still out of scope
- Blocking apps when Lab 2FA is **not** running (by design)
- Production-grade ticket store (lab API is in-memory)
