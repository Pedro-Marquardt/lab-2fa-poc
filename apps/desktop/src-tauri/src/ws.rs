use futures_util::{SinkExt, StreamExt};
use tauri::{AppHandle, Emitter};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message;

use crate::models::{MobileMessage, PairingRecord, WS_PORT};
use crate::persist;
use crate::state::SharedState;

pub fn spawn_ws_server(app: AppHandle, state: SharedState) {
    tauri::async_runtime::spawn(async move {
        if let Err(e) = run_server(app, state).await {
            eprintln!("[lab-ws] server error: {e}");
        }
    });
}

async fn run_server(app: AppHandle, state: SharedState) -> Result<(), String> {
    let addr = format!("0.0.0.0:{WS_PORT}");
    let listener = TcpListener::bind(&addr)
        .await
        .map_err(|e| format!("bind {addr}: {e}"))?;
    eprintln!("[lab-ws] listening on {addr}");

    loop {
        let (stream, peer) = listener.accept().await.map_err(|e| e.to_string())?;
        eprintln!("[lab-ws] accept from {peer}");
        let app = app.clone();
        let state = state.clone();
        tauri::async_runtime::spawn(async move {
            if let Err(e) = handle_connection(app, state, stream).await {
                eprintln!("[lab-ws] connection error: {e}");
            }
        });
    }
}

async fn handle_connection(
    app: AppHandle,
    state: SharedState,
    stream: TcpStream,
) -> Result<(), String> {
    let ws = tokio_tungstenite::accept_async(stream)
        .await
        .map_err(|e| e.to_string())?;
    let (mut write, mut read) = ws.split();

    let (tx, mut rx) = mpsc::unbounded_channel::<String>();
    {
        let mut guard = state.lock().await;
        // Keep the socket for outbound challenges, but do NOT mark online/synced
        // until a successful pair.register (and band presence).
        guard.mobile_tx = Some(tx);
        guard.mobile_online = false;
        guard.band_ready = false;
        guard.kem_public_key = None;
        guard.kem_pub_fp = None;
        let _ = emit_status(&app, &guard);
    }

    let writer = async {
        while let Some(msg) = rx.recv().await {
            if write.send(Message::Text(msg.into())).await.is_err() {
                break;
            }
        }
    };

    let reader = async {
        while let Some(frame) = read.next().await {
            let frame = match frame {
                Ok(f) => f,
                Err(_) => break,
            };
            let text = match frame {
                Message::Text(t) => t.to_string(),
                Message::Ping(_) | Message::Pong(_) => continue,
                Message::Close(_) => break,
                Message::Binary(_) => continue,
                Message::Frame(_) => continue,
            };
            if let Err(e) = on_mobile_message(&app, &state, &text).await {
                eprintln!("[lab-ws] message error: {e}");
            }
        }
    };

    tokio::select! {
        _ = writer => {},
        _ = reader => {},
    }

    {
        let mut guard = state.lock().await;
        guard.mobile_online = false;
        guard.band_ready = false;
        guard.kem_public_key = None;
        guard.kem_pub_fp = None;
        guard.mobile_tx = None;
        // Fail any in-flight challenges on disconnect.
        let pending = std::mem::take(&mut guard.pending_challenges);
        for (_, pending) in pending {
            let _ = pending.resp_tx.send(crate::models::ChallengeOutcome {
                ok: false,
                band_mac: None,
                reason: Some("mobile_disconnected".into()),
                presence_proof: None,
                seed_digest: None,
                pqc_sha3: None,
                pqc_kem_fp: None,
            });
        }
        let _ = emit_status(&app, &guard);
    }

    Ok(())
}

async fn on_mobile_message(
    app: &AppHandle,
    state: &SharedState,
    text: &str,
) -> Result<(), String> {
    let msg: MobileMessage = serde_json::from_str(text).map_err(|e| e.to_string())?;
    if msg.v != 1 {
        return Err(format!("unsupported v={}", msg.v));
    }

    match msg.msg_type.as_str() {
        "pair.register" => {
            let nonce = msg
                .pairing_nonce
                .ok_or_else(|| "missing pairingNonce".to_string())?;
            let band_mac = msg
                .band_mac
                .ok_or_else(|| "missing bandMac".to_string())?;

            let mut guard = state.lock().await;
            if nonce != guard.pairing_nonce {
                return Err("pairingNonce mismatch".into());
            }

            let kem_public_key = msg
                .kem_public_key
                .filter(|s| !s.is_empty())
                .ok_or_else(|| "missing kemPublicKey".to_string())?;
            if hex::decode(&kem_public_key).map(|b| b.len()).unwrap_or(0) != 800 {
                return Err("kemPublicKey must be 800 bytes hex (ML-KEM-512)".into());
            }

            let record = PairingRecord {
                band_mac,
                paired_at: chrono::Utc::now(),
                device_label: msg.device_label,
            };
            persist::save_pairing(&record)?;
            guard.pairing = Some(record);
            guard.kem_public_key = Some(kem_public_key);
            guard.kem_pub_fp = msg.kem_pub_fp.filter(|s| !s.is_empty());
            guard.mobile_online = true;
            // Pair only happens after mobile ensured HR streaming — mark ready.
            guard.band_ready = true;
            if let Some(fp) = guard.kem_pub_fp.as_ref() {
                eprintln!(
                    "[lab-ws] pair.register ok kemPubFp={}…",
                    fp.chars().take(16).collect::<String>()
                );
            }
            emit_status(app, &guard)?;
            Ok(())
        }
        "presence.update" => {
            let band_ready = msg.band_ready.unwrap_or(false);
            let mut guard = state.lock().await;
            if !guard.mobile_online {
                // Ignore presence before a successful pair.register this session.
                return Ok(());
            }
            if let (Some(expected), Some(got)) =
                (guard.pairing.as_ref().map(|p| p.band_mac.clone()), msg.band_mac)
            {
                if !mac_eq(&got, &expected) {
                    eprintln!("[lab-ws] presence bandMac mismatch; marking band not ready");
                    guard.band_ready = false;
                    emit_status(app, &guard)?;
                    return Ok(());
                }
            }
            guard.band_ready = band_ready;
            emit_status(app, &guard)?;
            Ok(())
        }
        "challenge.result" => {
            let challenge_id = msg
                .challenge_id
                .ok_or_else(|| "missing challengeId".to_string())?;
            let mut guard = state.lock().await;
            if let Some(pending) = guard.pending_challenges.remove(&challenge_id) {
                let _ = pending.resp_tx.send(crate::models::ChallengeOutcome {
                    ok: msg.ok.unwrap_or(false),
                    band_mac: msg.band_mac,
                    reason: msg.reason,
                    presence_proof: msg.presence_proof,
                    seed_digest: msg.seed_digest,
                    pqc_sha3: msg.pqc_sha3,
                    pqc_kem_fp: msg.pqc_kem_fp,
                });
            }
            Ok(())
        }
        other => {
            eprintln!("[lab-ws] ignored type={other}");
            Ok(())
        }
    }
}

fn mac_eq(a: &str, b: &str) -> bool {
    a.eq_ignore_ascii_case(b)
}

pub fn emit_status(app: &AppHandle, state: &crate::state::LabState) -> Result<(), String> {
    let status = state.status()?;
    app.emit("lab-status", status)
        .map_err(|e| e.to_string())
}
