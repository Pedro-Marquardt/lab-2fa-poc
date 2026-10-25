//! Unlock presence proof verification (Option A — ML-KEM shared secret).
//!
//! `SHA3-256(ss ‖ challengeId ‖ 0x00 ‖ bandMac ‖ 0x00 ‖ seedDigest)`

use sha3::{Digest, Sha3_256};

pub fn compute_presence_proof(
    shared_secret: &[u8],
    challenge_id: &str,
    band_mac: &str,
    seed_digest_hex: &str,
) -> Result<String, String> {
    if shared_secret.len() != 32 {
        return Err(format!(
            "shared secret must be 32 bytes, got {}",
            shared_secret.len()
        ));
    }
    let seed_digest = hex::decode(seed_digest_hex.trim())
        .map_err(|e| format!("seedDigest hex: {e}"))?;
    if seed_digest.len() != 32 {
        return Err(format!(
            "seedDigest must be 32 bytes, got {}",
            seed_digest.len()
        ));
    }

    let mac = band_mac.trim().to_ascii_uppercase();
    let mut hasher = Sha3_256::new();
    hasher.update(shared_secret);
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
    fn stable_vector() {
        let ss = vec![0u8; 32];
        let digest = "e2929f80ffdaaa51c427cbf42df6679013fddb1630bc28f234ca48692b353992";
        let a = compute_presence_proof(&ss, "chal-1", "aa:bb:cc:dd:ee:ff", digest).unwrap();
        let b = compute_presence_proof(&ss, "chal-1", "AA:BB:CC:DD:EE:FF", digest).unwrap();
        assert_eq!(a, b);
        let c = compute_presence_proof(&ss, "chal-2", "AA:BB:CC:DD:EE:FF", digest).unwrap();
        assert_ne!(a, c);
    }
}
