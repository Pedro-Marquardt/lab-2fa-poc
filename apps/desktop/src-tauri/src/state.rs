use std::collections::HashMap;
use std::sync::Arc;

use tokio::sync::{mpsc, oneshot, Mutex};

use crate::models::{
    AppConfig, ChallengeOutcome, LabStatus, PairingRecord, QrPayload, DESKTOP_NAME, WS_PORT,
};
use crate::persist;
use crate::supervisor::LeaseMap;

pub type SharedState = Arc<Mutex<LabState>>;

pub struct PendingChallenge {
    pub resp_tx: oneshot::Sender<ChallengeOutcome>,
}

pub struct LabState {
    pub pairing_nonce: String,
    pub pairing: Option<PairingRecord>,
    /// True only after successful `pair.register` on the current WS session.
    pub mobile_online: bool,
    /// True when mobile reports band ready via pair.register / presence.update.
    pub band_ready: bool,
    /// ML-KEM-512 public key hex from the current mobile pair session.
    pub kem_public_key: Option<String>,
    /// SHA3-256(ML-KEM pk) from pair — demo/audit only.
    pub kem_pub_fp: Option<String>,
    pub lan_ip: Option<String>,
    pub config: AppConfig,
    /// Set when `BIOENTROPY_API_URL` yielded a lab pairing ticket.
    pub api_ticket_id: Option<String>,
    pub api_base_url: Option<String>,
    /// Outbound JSON frames to the connected mobile client.
    pub mobile_tx: Option<mpsc::UnboundedSender<String>>,
    pub pending_challenges: HashMap<String, PendingChallenge>,
    /// Active OS-gate leases (appId → root PID we spawned after challenge).
    pub leases: LeaseMap,
}

impl LabState {
    pub fn new() -> Self {
        Self {
            pairing_nonce: new_nonce(),
            pairing: persist::load_pairing(),
            mobile_online: false,
            band_ready: false,
            kem_public_key: None,
            kem_pub_fp: None,
            lan_ip: detect_lan_ip(),
            config: persist::load_config(),
            api_ticket_id: None,
            api_base_url: None,
            mobile_tx: None,
            pending_challenges: HashMap::new(),
            leases: HashMap::new(),
        }
    }

    /// Live sync — never true from persisted pairing alone.
    pub fn is_synced(&self) -> bool {
        self.pairing.is_some() && self.mobile_online && self.band_ready
    }

    pub fn ws_url(&self) -> String {
        let host = self
            .lan_ip
            .clone()
            .unwrap_or_else(|| "127.0.0.1".to_string());
        format!("ws://{host}:{WS_PORT}")
    }

    pub fn qr_payload(&self) -> QrPayload {
        QrPayload {
            v: 1,
            ws_url: self.ws_url(),
            pairing_nonce: self.pairing_nonce.clone(),
            desktop_name: DESKTOP_NAME.to_string(),
            api_ticket_id: self.api_ticket_id.clone(),
            api_base_url: self.api_base_url.clone(),
        }
    }

    pub fn qr_payload_json(&self) -> Result<String, String> {
        serde_json::to_string(&self.qr_payload()).map_err(|e| e.to_string())
    }

    pub fn qr_svg(&self) -> Result<String, String> {
        let json = self.qr_payload_json()?;
        let code = qrcode::QrCode::new(json.as_bytes()).map_err(|e| e.to_string())?;
        let svg = code
            .render::<qrcode::render::svg::Color>()
            .min_dimensions(220, 220)
            .build();
        // Drop XML prologue so the SVG embeds cleanly via innerHTML.
        Ok(svg
            .trim_start_matches("<?xml version=\"1.0\" standalone=\"yes\"?>")
            .to_string())
    }

    pub fn status(&self) -> Result<LabStatus, String> {
        Ok(LabStatus {
            pairing: self.pairing.clone(),
            mobile_online: self.mobile_online,
            band_ready: self.band_ready,
            synced: self.is_synced(),
            ws_port: WS_PORT,
            lan_ip: self.lan_ip.clone(),
            ws_url: self.ws_url(),
            pairing_nonce: self.pairing_nonce.clone(),
            desktop_name: DESKTOP_NAME.to_string(),
            qr_payload_json: self.qr_payload_json()?,
            qr_svg: self.qr_svg()?,
        })
    }

    pub fn refresh_lan_ip(&mut self) {
        self.lan_ip = detect_lan_ip();
    }
}

pub fn new_nonce() -> String {
    let bytes: [u8; 16] = rand::random();
    hex::encode(bytes)
}

fn detect_lan_ip() -> Option<String> {
    local_ip_address::local_ip()
        .ok()
        .map(|ip| ip.to_string())
}
