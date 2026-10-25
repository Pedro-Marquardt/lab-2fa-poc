use std::fs::OpenOptions;
use std::io::Write;
use std::sync::atomic::{AtomicU64, Ordering};

use futures_util::{SinkExt, StreamExt};
use tauri::{AppHandle, Emitter};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message;

use crate::models::{MobileMessage, PairingRecord, WS_PORT};
use crate::persist;
use crate::state::SharedState;

static CONN_SEQ: AtomicU64 = AtomicU64::new(1);

fn ws_log(msg: &str) {
    eprintln!("{msg}");
    if let Ok(mut f) = OpenOptions::new()
        .create(true)
        .append(true)
        .open("/tmp/lab-ws.log")
    {
        let _ = writeln!(f, "{msg}");
    }
}

pub fn spawn_ws_server(app: AppHandle, state: SharedState) {
    tauri::async_runtime::spawn(async move {
        if let Err(e) = run_server(app, state).await {
            ws_log(&format!("[lab-ws] server error: {e}"));
        }
    });
}

async fn run_server(app: AppHandle, state: SharedState) -> Result<(), String> {
    let addr = format!("0.0.0.0:{WS_PORT}");
    let listener = TcpListener::bind(&addr)
        .await
        .map_err(|e| format!("bind {addr}: {e}"))?;
    ws_log(&format!("[lab-ws] listening on {addr}"));

    loop {
        let (stream, peer) = listener.accept().await.map_err(|e| e.to_string())?;
        ws_log(&format!("[lab-ws] accept from {peer}"));
        let app = app.clone();
        let state = state.clone();
        tauri::async_runtime::spawn(async move {
            if let Err(e) = handle_connection(app, state, stream).await {
                ws_log(&format!("[lab-ws] connection error: {e}"));
            }
        });
    }
}

async fn handle_connection(
    app: AppHandle,
    state: SharedState,
    stream: TcpStream,
) -> Result<(), String> {
    let conn_id = CONN_SEQ.fetch_add(1, Ordering::Relaxed);
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
        guard.mobile_conn_id = Some(conn_id);
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
                Message::Binary(b) => match String::from_utf8(b.to_vec()) {
                    Ok(s) => s,
                    Err(_) => {
                        ws_log("[lab-ws] ignoring non-utf8 binary frame");
                        continue;
                    }
                },
                Message::Ping(_) | Message::Pong(_) => continue,
                Message::Close(_) => break,
                Message::Frame(_) => continue,
            };
            if let Err(e) = on_mobile_message(&app, &state, &text, conn_id).await {
                ws_log(&format!("[lab-ws] message error: {e}"));
            }
        }
    };

    tokio::select! {
        _ = writer => {},
        _ = reader => {},
    }

    {
        let mut guard = state.lock().await;
        // Only clear session if this connection is still the active one.
        if guard.mobile_conn_id != Some(conn_id) {
            ws_log(&format!(
                "[lab-ws] conn {conn_id} closed (stale; active={:?})",
                guard.mobile_conn_id
            ));
            return Ok(());
        }
        guard.mobile_online = false;
        guard.band_ready = false;
        guard.kem_public_key = None;
        guard.kem_pub_fp = None;
        guard.mobile_tx = None;
        guard.mobile_conn_id = None;
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
        ws_log(&format!("[lab-ws] conn {conn_id} closed (active)"));
    }

    Ok(())
}

fn send_to_mobile(state: &crate::state::LabState, json: &str) {
    if let Some(tx) = state.mobile_tx.as_ref() {
        let _ = tx.send(json.to_string());
    }
}

fn pair_ack(ok: bool, reason: Option<&str>) -> String {
    let mut m = serde_json::json!({
        "v": 1,
        "type": if ok { "pair.ok" } else { "pair.error" },
    });
    if let Some(r) = reason {
        m["reason"] = serde_json::Value::String(r.to_string());
    }
    m.to_string()
}

async fn on_mobile_message(
    app: &AppHandle,
    state: &SharedState,
    text: &str,
    conn_id: u64,
) -> Result<(), String> {
    ws_log(&format!(
        "[lab-ws] conn {conn_id} frame len={} head={:?}",
        text.len(),
        text.chars().take(120).collect::<String>()
    ));

    let msg: MobileMessage = serde_json::from_str(text).map_err(|e| {
        format!(
            "json parse: {e} (len={} head={:?})",
            text.len(),
            text.chars().take(80).collect::<String>()
        )
    })?;
    if msg.v != 1 {
        return Err(format!("unsupported v={}", msg.v));
    }

    match msg.msg_type.as_str() {
        "pair.register" => {
            let nonce = msg
                .pairing_nonce
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .ok_or_else(|| "missing pairingNonce".to_string())?;
            let band_mac = msg
                .band_mac
                .ok_or_else(|| "missing bandMac".to_string())?;

            let mut guard = state.lock().await;
            if guard.mobile_conn_id != Some(conn_id) {
                return Err(format!("stale conn {conn_id} pair.register ignored"));
            }

            if nonce != guard.pairing_nonce {
                let expected = guard.pairing_nonce.clone();
                let err = format!(
                    "pairingNonce mismatch (got len={} prefix={:?}, expected len={} prefix={:?})",
                    nonce.len(),
                    nonce.chars().take(8).collect::<String>(),
                    expected.len(),
                    expected.chars().take(8).collect::<String>(),
                );
                send_to_mobile(&guard, &pair_ack(false, Some("pairingNonce mismatch")));
                return Err(err);
            }

            let Some(kem_public_key) = msg.kem_public_key.filter(|s| !s.is_empty()) else {
                send_to_mobile(&guard, &pair_ack(false, Some("missing kemPublicKey")));
                return Err("missing kemPublicKey".into());
            };
            let kem_bytes = match hex::decode(kem_public_key.trim()) {
                Ok(b) => b,
                Err(e) => {
                    send_to_mobile(&guard, &pair_ack(false, Some("kemPublicKey hex invalid")));
                    return Err(format!("kemPublicKey hex: {e}"));
                }
            };
            if kem_bytes.len() != 800 {
                let err = format!(
                    "kemPublicKey must be 800 bytes (ML-KEM-512), got {}",
                    kem_bytes.len()
                );
                send_to_mobile(&guard, &pair_ack(false, Some(&err)));
                return Err(err);
            }

            let record = PairingRecord {
                band_mac,
                paired_at: chrono::Utc::now(),
                device_label: msg.device_label,
            };
            if let Err(e) = persist::save_pairing(&record) {
                send_to_mobile(&guard, &pair_ack(false, Some("persist failed")));
                return Err(format!("save_pairing: {e}"));
            }
            guard.pairing = Some(record);
            guard.kem_public_key = Some(kem_public_key.trim().to_string());
            guard.kem_pub_fp = msg.kem_pub_fp.filter(|s| !s.is_empty());
            guard.mobile_online = true;
            // Pair only happens after mobile ensured HR streaming — mark ready.
            guard.band_ready = true;
            if let Some(fp) = guard.kem_pub_fp.as_ref() {
                ws_log(&format!(
                    "[lab-ws] pair.register ok conn={conn_id} kemPubFp={}…",
                    fp.chars().take(16).collect::<String>()
                ));
            } else {
                ws_log(&format!("[lab-ws] pair.register ok conn={conn_id}"));
            }
            send_to_mobile(&guard, &pair_ack(true, None));
            emit_status(app, &guard)?;
            Ok(())
        }
        "presence.update" => {
            let band_ready = msg.band_ready.unwrap_or(false);
            let mut guard = state.lock().await;
            if guard.mobile_conn_id != Some(conn_id) {
                return Ok(());
            }
            if !guard.mobile_online {
                // Ignore presence before a successful pair.register this session.
                ws_log("[lab-ws] presence.update ignored (not paired this session)");
                return Ok(());
            }
            if let (Some(expected), Some(got)) =
                (guard.pairing.as_ref().map(|p| p.band_mac.clone()), msg.band_mac)
            {
                if !mac_eq(&got, &expected) {
                    ws_log("[lab-ws] presence bandMac mismatch; marking band not ready");
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
            ws_log(&format!("[lab-ws] ignored type={other}"));
            Ok(())
        }
    }
}

fn mac_eq(a: &str, b: &str) -> bool {
    a.eq_ignore_ascii_case(b)
}

pub fn emit_status(app: &AppHandle, state: &crate::state::LabState) -> Result<(), String> {
    let status = state.status()?;
    if let Ok(mut f) = OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .open("/tmp/lab-nonce.txt")
    {
        let _ = writeln!(
            f,
            "nonce={}\nsynced={}\nmobile={}\nband={}\npairing={}",
            status.pairing_nonce,
            status.synced,
            status.mobile_online,
            status.band_ready,
            status.pairing.is_some()
        );
    }
    app.emit("lab-status", status)
        .map_err(|e| e.to_string())
}
