//! ML-KEM-512 encapsulate against the phone's pairing public key (Option A).

use ml_kem::kem::Encapsulate;
use ml_kem::ml_kem_512::EncapsulationKey;
use ml_kem::TryKeyInit;

pub struct KemEncapsulation {
    pub ciphertext_hex: String,
    pub shared_secret: Vec<u8>,
}

/// Parse phone `kemPublicKey` (hex) and encapsulate a fresh shared secret.
pub fn encapsulate_to_phone_pk(kem_public_key_hex: &str) -> Result<KemEncapsulation, String> {
    let pk = hex::decode(kem_public_key_hex.trim())
        .map_err(|e| format!("kemPublicKey hex: {e}"))?;
    if pk.len() != 800 {
        return Err(format!(
            "kemPublicKey must be 800 bytes (ML-KEM-512), got {}",
            pk.len()
        ));
    }
    let ek = EncapsulationKey::new_from_slice(&pk)
        .map_err(|_| "invalid ML-KEM-512 public key".to_string())?;
    let (ct, ss) = Encapsulate::encapsulate(&ek);
    let ct_bytes: &[u8] = ct.as_slice();
    let ss_bytes: &[u8] = ss.as_slice();
    Ok(KemEncapsulation {
        ciphertext_hex: hex::encode(ct_bytes),
        shared_secret: ss_bytes.to_vec(),
    })
}
