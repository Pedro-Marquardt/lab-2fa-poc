use std::process::{Child, Command};
use std::time::Duration;

use chrono::{Duration as ChronoDuration, Utc};
use tokio::sync::oneshot;
use uuid::Uuid;

use crate::models::{
    ChallengeOutcome, ChallengeRequest, GatedApp, OpenAppResult, CHALLENGE_TIMEOUT_SECS,
};
use crate::state::SharedState;
use crate::supervisor;

pub async fn open_app(state: SharedState, app_id: String) -> Result<OpenAppResult, String> {
    let (app_cfg, require_2fa, paired_mac, mobile_tx, synced) = {
        let guard = state.lock().await;
        let app = guard
            .config
            .apps
            .iter()
            .find(|a| a.id == app_id)
            .cloned()
            .ok_or_else(|| format!("unknown appId={app_id}"))?;

        let tx = guard.mobile_tx.clone();
        let mac = guard.pairing.as_ref().map(|p| p.band_mac.clone());
        let require_2fa = app.require_2fa;
        let synced = guard.is_synced();
        eprintln!(
            "[lab-open] appId={app_id} require2fa={require_2fa} synced={synced} paired={} mobile={} band={} cmd={:?}",
            mac.is_some(),
            guard.mobile_online,
            guard.band_ready,
            app.command
        );
        (app, require_2fa, mac, tx, synced)
    };

    validate_command(&app_cfg)?;

    if !require_2fa {
        eprintln!("[lab-open] bypass — require2fa=false, spawning (no mobile challenge)");
        // Drop any old lease entry; supervisor ignores apps with require2fa=false.
        {
            let mut guard = state.lock().await;
            guard.leases.remove(&app_cfg.id);
        }
        let mut child = spawn_process(&app_cfg)?;
        let pid = child.id();
        std::thread::spawn(move || {
            let _ = child.wait();
        });
        eprintln!("[lab-open] spawned without 2FA pid={pid}");
        return Ok(OpenAppResult {
            launched: true,
            message: format!("launched without 2FA (pid={pid})"),
        });
    }

    if !synced {
        eprintln!("[lab-open] BLOCK not synced — not spawning");
        return Ok(OpenAppResult {
            launched: false,
            message: "not synced (phone + band must be live) — not launching".into(),
        });
    }

    let Some(paired_mac) = paired_mac else {
        eprintln!("[lab-open] BLOCK not paired — not spawning");
        return Ok(OpenAppResult {
            launched: false,
            message: "not synced — not launching".into(),
        });
    };

    let Some(mobile_tx) = mobile_tx else {
        eprintln!("[lab-open] BLOCK mobile offline — not spawning");
        return Ok(OpenAppResult {
            launched: false,
            message: "mobile offline — not launching".into(),
        });
    };

    let challenge_id = Uuid::new_v4().to_string();
    let expires_at = (Utc::now() + ChronoDuration::seconds(CHALLENGE_TIMEOUT_SECS as i64))
        .to_rfc3339_opts(chrono::SecondsFormat::Millis, true);

    let request = ChallengeRequest {
        v: 1,
        msg_type: "challenge.request",
        challenge_id: challenge_id.clone(),
        purpose: "open_app",
        app_id: app_cfg.id.clone(),
        expires_at,
    };
    let payload = serde_json::to_string(&request).map_err(|e| e.to_string())?;

    let (resp_tx, resp_rx) = oneshot::channel::<ChallengeOutcome>();
    {
        let mut guard = state.lock().await;
        guard.pending_challenges.insert(challenge_id.clone(), resp_tx);
    }

    eprintln!(
        "[lab-open] challenge.request id={challenge_id} appId={}",
        app_cfg.id
    );
    mobile_tx
        .send(payload)
        .map_err(|_| "failed to send challenge to mobile".to_string())?;

    let outcome = match tokio::time::timeout(
        Duration::from_secs(CHALLENGE_TIMEOUT_SECS),
        resp_rx,
    )
    .await
    {
        Ok(Ok(o)) => o,
        Ok(Err(_)) => {
            clear_pending(&state, &challenge_id).await;
            supervisor::revoke_lease(&state, &app_cfg.id, "challenge channel closed").await;
            return Ok(OpenAppResult {
                launched: false,
                message: "challenge channel closed".into(),
            });
        }
        Err(_) => {
            clear_pending(&state, &challenge_id).await;
            supervisor::revoke_lease(&state, &app_cfg.id, "challenge timeout").await;
            return Ok(OpenAppResult {
                launched: false,
                message: "challenge timeout — not launching".into(),
            });
        }
    };

    eprintln!(
        "[lab-open] challenge.result id={challenge_id} ok={} reason={:?} bandMac={:?}",
        outcome.ok, outcome.reason, outcome.band_mac
    );

    if !outcome.ok {
        let reason = outcome.reason.clone().unwrap_or_else(|| "ok=false".into());
        eprintln!("[lab-open] BLOCK challenge denied reason={reason}");
        supervisor::revoke_lease(&state, &app_cfg.id, &format!("denied:{reason}")).await;
        return Ok(OpenAppResult {
            launched: false,
            message: format!("challenge denied: {reason}"),
        });
    }

    let result_mac = outcome
        .band_mac
        .ok_or_else(|| "challenge missing bandMac".to_string())?;
    if !mac_eq(&result_mac, &paired_mac) {
        eprintln!("[lab-open] BLOCK bandMac mismatch got={result_mac} expected={paired_mac}");
        supervisor::revoke_lease(&state, &app_cfg.id, "bandMac mismatch").await;
        return Ok(OpenAppResult {
            launched: false,
            message: format!("bandMac mismatch (got {result_mac}, expected {paired_mac})"),
        });
    }

    eprintln!("[lab-open] OK challenge passed — spawning {:?}", app_cfg.command);
    let mut child = spawn_process(&app_cfg)?;
    let pid = child.id();
    std::thread::spawn(move || {
        let _ = child.wait();
    });
    supervisor::grant_lease(&state, app_cfg.id.clone(), pid).await;
    Ok(OpenAppResult {
        launched: true,
        message: format!("challenge ok — launched (pid={pid})"),
    })
}

async fn clear_pending(state: &SharedState, challenge_id: &str) {
    let mut guard = state.lock().await;
    guard.pending_challenges.remove(challenge_id);
}

fn validate_command(app: &GatedApp) -> Result<(), String> {
    let prog = app
        .command
        .first()
        .map(|s| s.trim())
        .filter(|s| !s.is_empty())
        .ok_or_else(|| "empty command path".to_string())?;
    if prog.contains('\0') {
        return Err("invalid command".into());
    }
    Ok(())
}

fn spawn_process(app: &GatedApp) -> Result<Child, String> {
    let mut iter = app.command.iter();
    let prog = iter
        .next()
        .ok_or_else(|| "empty command".to_string())?
        .trim();
    if prog.is_empty() {
        return Err("empty command path".into());
    }
    let args: Vec<&str> = iter.map(|s| s.as_str()).collect();
    Command::new(prog)
        .args(&args)
        .spawn()
        .map_err(|e| format!("spawn {prog}: {e}"))
}

fn mac_eq(a: &str, b: &str) -> bool {
    normalize_mac(a) == normalize_mac(b)
}

fn normalize_mac(mac: &str) -> String {
    mac.chars()
        .filter(|c| c.is_ascii_hexdigit())
        .flat_map(|c| c.to_lowercase())
        .collect()
}
