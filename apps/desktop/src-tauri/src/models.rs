use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

pub const WS_PORT: u16 = 8787;
/// Loopback control plane for OS-level gate wrapper (`bioentropy-gate`).
pub const LOCAL_API_PORT: u16 = 8788;
pub const DESKTOP_NAME: &str = "lab-pc";
pub const CHALLENGE_TIMEOUT_SECS: u64 = 45;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PairingRecord {
    pub band_mac: String,
    pub paired_at: DateTime<Utc>,
    #[serde(default)]
    pub device_label: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QrPayload {
    pub v: u8,
    pub ws_url: String,
    pub pairing_nonce: String,
    pub desktop_name: String,
    pub api_ticket_id: Option<String>,
    /// Present when `apiTicketId` is set (phone POSTs ticket complete here).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub api_base_url: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GatedApp {
    pub id: String,
    pub label: String,
    /// Executable + args. For curated apps these are resolved at boot.
    pub command: Vec<String>,
    /// Always wire as `require2fa` (avoid serde `require2Fa` from `require_2fa`).
    #[serde(rename = "require2fa", alias = "require2Fa", alias = "require_2fa")]
    pub require_2fa: bool,
    pub curated: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct AppConfig {
    pub apps: Vec<GatedApp>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LabStatus {
    pub pairing: Option<PairingRecord>,
    /// Phone has an open WS *and* completed `pair.register` this session.
    pub mobile_online: bool,
    /// Phone reports Mi Band ready (HR streaming). False until presence says so.
    pub band_ready: bool,
    /// Live sync: registered MAC + phone session + band ready. Never true from disk alone.
    pub synced: bool,
    pub ws_port: u16,
    pub lan_ip: Option<String>,
    pub ws_url: String,
    pub pairing_nonce: String,
    pub desktop_name: String,
    pub qr_payload_json: String,
    pub qr_svg: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MobileMessage {
    pub v: u8,
    #[serde(rename = "type")]
    pub msg_type: String,
    #[serde(default)]
    pub pairing_nonce: Option<String>,
    #[serde(default)]
    pub band_mac: Option<String>,
    #[serde(default)]
    pub device_label: Option<String>,
    #[serde(default)]
    pub challenge_id: Option<String>,
    #[serde(default)]
    pub ok: Option<bool>,
    #[serde(default)]
    pub reason: Option<String>,
    /// `presence.update` — band HR streaming / ready (no BPM values).
    #[serde(default)]
    pub band_ready: Option<bool>,
    /// `pair.register` — hex session key for unlock proof verification.
    #[serde(default)]
    pub presence_key: Option<String>,
    /// `pair.register` — SHA3-256(ML-KEM pk) audit fingerprint.
    #[serde(default)]
    pub kem_pub_fp: Option<String>,
    /// `challenge.result` — SHA3 presence proof.
    #[serde(default)]
    pub presence_proof: Option<String>,
    /// `challenge.result` — SHA3(bio seed), not the seed.
    #[serde(default)]
    pub seed_digest: Option<String>,
    /// `challenge.result` — SHA3-256(seed) audit.
    #[serde(default)]
    pub pqc_sha3: Option<String>,
    /// `challenge.result` — ML-KEM pubkey fingerprint audit.
    #[serde(default)]
    pub pqc_kem_fp: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChallengeRequest {
    pub v: u8,
    #[serde(rename = "type")]
    pub msg_type: &'static str,
    pub challenge_id: String,
    pub purpose: &'static str,
    pub app_id: String,
    pub expires_at: String,
}

#[derive(Debug, Clone)]
pub struct ChallengeOutcome {
    pub ok: bool,
    pub band_mac: Option<String>,
    pub reason: Option<String>,
    pub presence_proof: Option<String>,
    pub seed_digest: Option<String>,
    pub pqc_sha3: Option<String>,
    pub pqc_kem_fp: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenAppResult {
    pub launched: bool,
    pub message: String,
}
