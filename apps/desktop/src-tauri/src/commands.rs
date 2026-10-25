use tauri::State;

use crate::api_ticket::{api_base_url_from_env, create_pairing_ticket};
use crate::installed_apps::{self, InstalledApp};
use crate::launcher;
use crate::models::{AppConfig, LabStatus, OpenAppResult};
use crate::persist;
use crate::state::{new_nonce, SharedState};
use crate::ws::emit_status;

/// Rotate local nonce; if `BIOENTROPY_API_URL` is set, mint an API ticket and use its nonce.
pub async fn refresh_pairing_material(state: &SharedState) {
    let api_base = api_base_url_from_env();
    match api_base {
        Some(base) => {
            // Desktop may call API on loopback; phone needs a LAN-reachable base in the QR.
            let qr_base = {
                let mut guard = state.lock().await;
                guard.refresh_lan_ip();
                rewrite_loopback_for_phone(&base, guard.lan_ip.as_deref())
            };
            match create_pairing_ticket(&base).await {
                Ok((ticket_id, pairing_nonce)) => {
                    let mut guard = state.lock().await;
                    guard.pairing_nonce = pairing_nonce;
                    guard.api_ticket_id = Some(ticket_id);
                    guard.api_base_url = Some(qr_base);
                    eprintln!("[lab-api] pairing ticket ready (apiBaseUrl for phone={})", guard.api_base_url.as_deref().unwrap_or("?"));
                }
                Err(e) => {
                    eprintln!("[lab-api] ticket create failed ({e}); using local nonce");
                    let mut guard = state.lock().await;
                    guard.pairing_nonce = new_nonce();
                    guard.api_ticket_id = None;
                    guard.api_base_url = None;
                }
            }
        }
        None => {
            let mut guard = state.lock().await;
            guard.pairing_nonce = new_nonce();
            guard.api_ticket_id = None;
            guard.api_base_url = None;
        }
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
