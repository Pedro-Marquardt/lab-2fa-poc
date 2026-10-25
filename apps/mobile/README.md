# Wearable 2FA · Mobile (Flutter)

Portfolio client: **Mi Band** BLE + desktop 2FA (QR/WebSocket) + **on-device PQC** demo.

1. Connect band → live HR + steps  
2. **Generate PQC hash** → local seed (HR + steps + last SpO₂ if cached) → matrix → SHA3-256 + ML-KEM-512  
3. Pair desktop → presence challenge (`ok` + `bandMac` only; biometrics never leave the phone)

Contract: [`packages/protocol/lab-host-mobile.md`](../../packages/protocol/lab-host-mobile.md). Desktop: [`apps/desktop`](../desktop/).

## Setup

```bash
cd apps/mobile
cp .env.example .env
# edita .env com MIBAND_AUTH_KEY e MIBAND_MAC
flutter pub get
flutter run
```

### `.env` (gitignored)

```env
MIBAND_AUTH_KEY=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
MIBAND_MAC=AA:BB:CC:DD:EE:FF
```

- Key: 32 hex, **sem** `0x`
- MAC: opcional mas recomendado (fallback para `pair.register` se o remoteId BLE falhar)
- **Nunca** faças commit do `.env`

Antes de `git push`, confirma:

```bash
git status   # .env não deve aparecer
git check-ignore -v apps/mobile/.env
```

## Uso — Mi Band

1. Força-stop / desliga Bluetooth do **Mi Fitness** (senão disputa a ligação)
2. Corre o app → **Conectar Mi Band**
3. Vê BPM no ecrã (local only)

## Uso — lab 2FA (desktop)

Pré-requisito: desktop a servir QR + WebSocket em `ws://<LAN-IP>:8787` (mesmo Wi‑Fi que o telemóvel).

1. Conecta a Mi Band (HR a transmitir)
2. **Scan QR desktop** — payload esperado:

```json
{"v":1,"wsUrl":"ws://192.168.x.x:8787","pairingNonce":"...","desktopName":"lab-pc","apiTicketId":null}
```

Com API ticket (desktop com `BIOENTROPY_API_URL`):

```json
{"v":1,"wsUrl":"ws://192.168.x.x:8787","pairingNonce":"...","desktopName":"lab-pc","apiTicketId":"<id>","apiBaseUrl":"http://127.0.0.1:8000"}
```

3. O app liga ao `wsUrl` e envia:

```json
{"v":1,"type":"pair.register","pairingNonce":"...","bandMac":"AA:BB:CC:DD:EE:FF","deviceLabel":"phone"}
```

4. Quando o desktop envia `challenge.request`, o app exige presença ao vivo: ≥1 BPM válido (40–200) no stream + HR fresco (máx. 3s). Sem cache. Off-wrist → `ok=false`. Logs de BPM só no telemóvel. Responde:

```json
{"v":1,"type":"challenge.result","challengeId":"...","ok":true,"bandMac":"...","reason":null}
```

Estados UI: **Unpaired** → **Paired** → **Challenge em curso** → **Result: OK/FAIL**.

Privacidade: BPM só no ecrã/memória; WS e logs de desafio não incluem valores de HR.

## Structure

- `lib/huami/` — Huami BLE / Mi Band client (HR + realtime steps)
- `lib/lab/` — QR/WS 2FA, BPM gate, `bio_seed` + `pqc_demo`
- `lib/widgets/seed_matrix.dart` — 16×16 seed visualization
- `lib/screens/qr_scan_screen.dart` — camera QR
- `lib/config/env.dart` — `.env`

See `docs/research/miband-flutter-ble.md`.
