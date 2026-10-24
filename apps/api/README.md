# apps/api

API Python (FastAPI) para o lab Bioentropy 2FA.

Escopo permitido: pairing tickets, challenges, sessão, auditoria de eventos **não biométricos**.

Fora de escopo: receber/armazenar SpO₂, FC, pressão, morfologia, ADC ou seeds.  
Payloads com campos como `bpm`, `hr`, `spo2`, `heartRate`, etc. são rejeitados com **422**.

**E2E lab:** optional side-channel. Desktop/mobile pair over LAN QR+WS; when desktop has `BIOENTROPY_API_URL=http://127.0.0.1:8000`, it mints tickets here and mobile completes them best-effort. See [`packages/protocol/lab-host-mobile.md`](../../packages/protocol/lab-host-mobile.md) and lab 2FA notes. Mobile: [`apps/mobile`](../mobile/). Desktop: [`apps/desktop`](../desktop/).

## Setup

```bash
cd apps/api
python3 -m venv .venv
source .venv/bin/activate
pip install -e ".[dev]"
# or: pip install -r requirements.txt && pip install -e .
```

## Run

```bash
cd apps/api
source .venv/bin/activate
uvicorn bioentropy_api.main:app --reload --host 127.0.0.1 --port 8000
# phone must reach API: use --host 0.0.0.0 (desktop rewrites loopback → LAN IP in QR)
```

### Docker (repo root)

```bash
docker compose up --build
# → http://127.0.0.1:8000  (binds 0.0.0.0 inside the container)
```

Compose mounts `bioentropy_api/` with `--reload` for lab iteration. Desktop/Tauri and mobile stay on the host — only this API is containerized.

Health: [http://127.0.0.1:8000/health](http://127.0.0.1:8000/health)  
OpenAPI: [http://127.0.0.1:8000/docs](http://127.0.0.1:8000/docs)

## Endpoints (lab)

| Method | Path | Notes |
|--------|------|--------|
| `GET` | `/health` | liveness |
| `POST` | `/v1/pairing/tickets` | `{ ticketId, pairingNonce, expiresAt }` |
| `GET` | `/v1/pairing/tickets/{ticketId}` | status + nonce |
| `POST` | `/v1/pairing/tickets/{ticketId}/complete` | `{ bandMac, deviceLabel }` only |
| `POST` | `/v1/challenges` | `{ purpose, appId, ttlSeconds? }` → challenge metadata |
| `POST` | `/v1/challenges/{id}/complete` | `{ ok, bandMac, reason? }` audit only |

Store: **in-memory** (process-local lab). Data is lost on restart.

Protocol message examples: [`packages/protocol/lab-host-mobile.md`](../../packages/protocol/lab-host-mobile.md).

## Tests

```bash
cd apps/api
source .venv/bin/activate
pytest -q
```
