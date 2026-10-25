use tauri::State;

use crate::api_ticket::{api_base_url_from_env, create_pairing_ticket};
use crate::installed_apps::{self, InstalledApp};
use crate::launcher;
use crate::models::{AppConfig, LabStatus, OpenAppResult};
use crate::persist;
use crate::state::{new_nonce, SharedState};
use crate::ws::emit_status;

/// Build next pairing material, validate QR render, then commit atomically.
/// Avoids rotating `pairing_nonce` while the UI still shows the previous QR.
pub async fn refresh_pairing_material(state: &SharedState) {
    let api_base = api_base_url_from_env();
    let (pairing_nonce, api_ticket_id, api_base_url) = match api_base {
        Some(base) => {
            // Desktop may call API on loopback; phone needs a LAN-reachable base in the QR.
            let qr_base = {
                let mut guard = state.lock().await;
                guard.refresh_lan_ip();
                rewrite_loopback_for_phone(&base, guard.lan_ip.as_deref())
            };
            match create_pairing_ticket(&base).await {
                Ok((ticket_id, pairing_nonce)) => {
                    eprintln!(
                        "[lab-api] pairing ticket ready (apiBaseUrl for phone={qr_base})"
                    );
                    (pairing_nonce, Some(ticket_id), Some(qr_base))
                }
                Err(e) => {
                    eprintln!("[lab-api] ticket create failed ({e}); using local nonce");
                    (new_nonce(), None, None)
                }
            }
        }
        None => (new_nonce(), None, None),
    };

    let mut guard = state.lock().await;
    guard.refresh_lan_ip();
    let prev_nonce = guard.pairing_nonce.clone();
    guard.pairing_nonce = pairing_nonce;
    guard.api_ticket_id = api_ticket_id;
    guard.api_base_url = api_base_url;

    // Roll back if the new payload cannot be rendered as a QR (keeps UI/nonce aligned).
    if let Err(e) = guard.qr_svg() {
        eprintln!("[lab-api] QR render failed ({e}); keeping previous nonce");
        guard.pairing_nonce = prev_nonce;
        guard.api_ticket_id = None;
        guard.api_base_url = None;
    }
}

/// If env points at localhost, embed LAN IP so the phone can reach the same API host.
fn rewrite_loopback_for_phone(api_base: &str, lan_ip: Option<&str>) -> String {
    let Some(ip) = lan_ip else {
        return api_base.to_string();
    };
    api_base
        .replacen("127.0.0.1", ip, 1)
        .replacen("localhost", ip, 1)
}

#[tauri::command]
pub async fn get_status(state: State<'_, SharedState>) -> Result<LabStatus, String> {
    let mut guard = state.lock().await;
    guard.refresh_lan_ip();
    guard.status()
}

#[tauri::command]
pub async fn refresh_qr(
    state: State<'_, SharedState>,
    app: tauri::AppHandle,
) -> Result<LabStatus, String> {
    {
        let mut guard = state.lock().await;
        guard.refresh_lan_ip();
    }
    refresh_pairing_material(&state).await;
    let guard = state.lock().await;
    emit_status(&app, &guard)?;
    guard.status()
}

#[tauri::command]
pub async fn get_config(state: State<'_, SharedState>) -> Result<AppConfig, String> {
    let guard = state.lock().await;
    Ok(guard.config.clone())
}

#[tauri::command]
pub async fn save_config(
    state: State<'_, SharedState>,
    mut config: AppConfig,
) -> Result<AppConfig, String> {
    config
        .apps
        .retain(|a| a.id != "custom" && a.id != "editor");
    persist::save_config(&config)?;
    let mut guard = state.lock().await;
    guard.config = config.clone();
    Ok(config)
}

#[tauri::command]
pub async fn list_installed_apps() -> Result<Vec<InstalledApp>, String> {
    installed_apps::list_installed_apps()
}

#[tauri::command]
pub async fn unpair(state: State<'_, SharedState>, app: tauri::AppHandle) -> Result<LabStatus, String> {
    persist::clear_pairing()?;
    {
        let mut guard = state.lock().await;
        guard.pairing = None;
    }
    refresh_pairing_material(&state).await;
    let guard = state.lock().await;
    emit_status(&app, &guard)?;
    guard.status()
}

#[tauri::command]
pub async fn open_gated_app(
    state: State<'_, SharedState>,
    app_id: String,
) -> Result<OpenAppResult, String> {
    launcher::open_app(state.inner().clone(), app_id).await
}
