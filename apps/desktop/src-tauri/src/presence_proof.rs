//! Unlock presence proof verification (matches mobile `presence_proof.dart`).
//!
//! `SHA3-256(presenceKey ‖ challengeId ‖ 0x00 ‖ bandMac ‖ 0x00 ‖ seedDigest)`

use sha3::{Digest, Sha3_256};

pub fn compute_presence_proof(
    presence_key_hex: &str,
    challenge_id: &str,
    band_mac: &str,
    seed_digest_hex: &str,
) -> Result<String, String> {
    let key = hex::decode(presence_key_hex.trim())
        .map_err(|e| format!("presenceKey hex: {e}"))?;
    let seed_digest = hex::decode(seed_digest_hex.trim())
        .map_err(|e| format!("seedDigest hex: {e}"))?;
    if key.len() != 32 {
        return Err(format!("presenceKey must be 32 bytes, got {}", key.len()));
    }
    if seed_digest.len() != 32 {
        return Err(format!(
            "seedDigest must be 32 bytes, got {}",
            seed_digest.len()
        ));
    }

    let mac = band_mac.trim().to_ascii_uppercase();
    let mut hasher = Sha3_256::new();
    hasher.update(&key);
    hasher.update(challenge_id.as_bytes());
    hasher.update([0x00]);
    hasher.update(mac.as_bytes());
    hasher.update([0x00]);
    hasher.update(&seed_digest);
    Ok(hex::encode(hasher.finalize()))
}

pub fn proofs_equal(a: &str, b: &str) -> bool {
    a.trim().eq_ignore_ascii_case(b.trim())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_mobile_vector() {
        // seedDigest = SHA3(0x11 * 32) from mobile presence_proof_test / tool/proof_vec.dart
        let key = "00".repeat(32);
        let digest = "e2929f80ffdaaa51c427cbf42df6679013fddb1630bc28f234ca48692b353992";
        let a = compute_presence_proof(&key, "chal-1", "aa:bb:cc:dd:ee:ff", digest).unwrap();
        let b = compute_presence_proof(&key, "chal-1", "AA:BB:CC:DD:EE:FF", digest).unwrap();
        assert_eq!(a, b);
        assert_eq!(
            a,
            "46173a1817b65581068d3f7c9561c96f4edbdaaa7e45a0502e8de0d533484145"
        );
        let c = compute_presence_proof(&key, "chal-2", "AA:BB:CC:DD:EE:FF", digest).unwrap();
        assert_ne!(a, c);
    }
}
