# Bioentropy Mobile (Flutter)

Cliente de lab para **Mi Band**  + **lab 2FA** com desktop via QR + WebSocket.

Fluxo: scan BLE → New Auth Protocol (Huami) → HR ao vivo → scan QR desktop → `pair.register` → (se QR tiver `apiTicketId` + `apiBaseUrl`, completa ticket na API best-effort) → `challenge.result` (só `ok` + `bandMac`, **nunca** BPM na rede).

Contrato: [`packages/protocol/lab-host-mobile.md`](../../packages/protocol/lab-host-mobile.md). Desktop: [`apps/desktop`](../desktop/). API opcional: [`apps/api`](../api/).

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

4. Quando o desktop envia `challenge.request`, o app exige presença ao vivo: ≥3 amostras de BPM (40–200), ≥2 valores distintos, span ≥2s, HR fresco (máx. 3s). Sem cache. Off-wrist / BPM colado → `ok=false`. Logs de BPM só no telemóvel. Responde:

```json
{"v":1,"type":"challenge.result","challengeId":"...","ok":true,"bandMac":"...","reason":null}
```

Estados UI: **Unpaired** → **Paired** → **Challenge em curso** → **Result: OK/FAIL**.

Privacidade: BPM só no ecrã/memória; WS e logs de desafio não incluem valores de HR.

## Estrutura

- `lib/huami/` — UUIDs, ECDH, chunked framing, cliente Mi Band
- `lib/lab/` — QR payload, WS client, BPM gate (booleano)
- `lib/screens/qr_scan_screen.dart` — câmara (`mobile_scanner`)
- `lib/config/env.dart` — leitura do `.env`

Ver `docs/research/miband-flutter-ble.md`.
