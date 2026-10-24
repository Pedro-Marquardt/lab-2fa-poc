//! Optional lab API pairing ticket (thin client — metadata only, no biometrics).

use serde::Deserialize;

/// `BIOENTROPY_API_URL` e.g. `http://127.0.0.1:8000`. Trailing slash stripped.
pub fn api_base_url_from_env() -> Option<String> {
    std::env::var("BIOENTROPY_API_URL")
        .ok()
        .map(|s| s.trim().trim_end_matches('/').to_string())
        .filter(|s| !s.is_empty())
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct TicketCreateResponse {
    ticket_id: String,
    pairing_nonce: String,
}

/// POST `/v1/pairing/tickets` → `(ticketId, pairingNonce)`.
pub async fn create_pairing_ticket(api_base: &str) -> Result<(String, String), String> {
    let url = format!("{api_base}/v1/pairing/tickets");
    let client = reqwest::Client::new();
    let res = client
        .post(&url)
        .send()
        .await
        .map_err(|e| format!("pairing ticket request: {e}"))?;
    if !res.status().is_success() {
        return Err(format!(
            "pairing ticket HTTP {}: {}",
            res.status(),
            res.text().await.unwrap_or_default()
        ));
    }
    let body: TicketCreateResponse = res
        .json()
        .await
        .map_err(|e| format!("pairing ticket JSON: {e}"))?;
    Ok((body.ticket_id, body.pairing_nonce))
}
