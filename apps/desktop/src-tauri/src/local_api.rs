//! Loopback HTTP control plane for `bioentropy-gate` (Tauri off → connection refused → passthrough).

use axum::extract::State;
use axum::http::StatusCode;
use axum::routing::post;
use axum::{Json, Router};
use serde::Deserialize;
use tokio::net::TcpListener;

use crate::launcher;
use crate::models::{OpenAppResult, LOCAL_API_PORT};
use crate::state::SharedState;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct OpenBody {
    app_id: String,
}

pub fn spawn_local_api(state: SharedState) {
    tauri::async_runtime::spawn(async move {
        let app = Router::new()
            .route("/v1/open", post(open_handler))
            .route("/health", axum::routing::get(|| async { "ok" }))
            .with_state(state);

        let addr = format!("127.0.0.1:{LOCAL_API_PORT}");
        let listener = match TcpListener::bind(&addr).await {
            Ok(l) => l,
            Err(e) => {
                eprintln!("[lab-gate] local API bind failed on {addr}: {e}");
                return;
            }
        };
        eprintln!("[lab-gate] local API listening on http://{addr}");
        if let Err(e) = axum::serve(listener, app).await {
            eprintln!("[lab-gate] local API exited: {e}");
        }
    });
}

async fn open_handler(
    State(state): State<SharedState>,
    Json(body): Json<OpenBody>,
) -> Result<Json<OpenAppResult>, (StatusCode, Json<OpenAppResult>)> {
    eprintln!("[lab-gate] POST /v1/open appId={}", body.app_id);
    match launcher::open_app(state, body.app_id).await {
        Ok(result) => {
            if result.launched {
                Ok(Json(result))
            } else {
                Err((StatusCode::FORBIDDEN, Json(result)))
            }
        }
        Err(e) => Err((
            StatusCode::BAD_REQUEST,
            Json(OpenAppResult {
                launched: false,
                message: e,
            }),
        )),
    }
}
