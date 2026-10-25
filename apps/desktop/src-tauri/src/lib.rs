mod api_ticket;
mod commands;
mod installed_apps;
mod launcher;
mod local_api;
mod models;
mod persist;
mod presence_proof;
mod state;
mod supervisor;
mod ws;

use std::sync::Arc;

use tokio::sync::Mutex;

use commands::{
    get_config, get_status, list_installed_apps, open_gated_app, refresh_pairing_material,
    refresh_qr, save_config, unpair,
};
use state::LabState;
use ws::spawn_ws_server;

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let lab_state = Arc::new(Mutex::new(LabState::new()));

    tauri::Builder::default()
        .manage(lab_state.clone())
        .setup(move |app| {
            let handle = app.handle().clone();
            let state_for_ticket = lab_state.clone();
            tauri::async_runtime::spawn(async move {
                refresh_pairing_material(&state_for_ticket).await;
                let guard = state_for_ticket.lock().await;
                let _ = ws::emit_status(&handle, &guard);
            });
            spawn_ws_server(app.handle().clone(), lab_state.clone());
            supervisor::spawn_supervisor(lab_state.clone());
            local_api::spawn_local_api(lab_state);
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            get_status,
            refresh_qr,
            get_config,
            save_config,
            list_installed_apps,
            unpair,
            open_gated_app
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
