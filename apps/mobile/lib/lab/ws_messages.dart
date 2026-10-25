/// Mensagens WebSocket do lab 2FA (contrato congelado).
class PairRegisterMessage {
  const PairRegisterMessage({
    required this.pairingNonce,
    required this.bandMac,
    this.deviceLabel = 'phone',
    this.presenceKey,
    this.kemPubFp,
  });

  final String pairingNonce;
  final String bandMac;
  final String deviceLabel;

  /// Hex SHA3-derived session key for unlock proofs (local pair only).
  final String? presenceKey;

  /// Hex SHA3-256(ML-KEM-512 pk) — audit / demo display.
  final String? kemPubFp;

  Map<String, dynamic> toJson() => {
        'v': 1,
        'type': 'pair.register',
        'pairingNonce': pairingNonce,
        'bandMac': bandMac,
        'deviceLabel': deviceLabel,
        if (presenceKey != null) 'presenceKey': presenceKey,
        if (kemPubFp != null) 'kemPubFp': kemPubFp,
      };
}

class ChallengeRequest {
  const ChallengeRequest({
    required this.challengeId,
    required this.purpose,
    required this.appId,
    required this.expiresAt,
  });

  final String challengeId;
  final String purpose;
  final String appId;
  final String expiresAt;

  factory ChallengeRequest.fromJson(Map<String, dynamic> json) {
    String req(String key) {
      final v = json[key];
      if (v is! String || v.isEmpty) {
        throw FormatException('challenge.request sem $key');
      }
      return v;
    }

    return ChallengeRequest(
      challengeId: req('challengeId'),
      purpose: req('purpose'),
      appId: req('appId'),
      expiresAt: req('expiresAt'),
    );
  }
}

class ChallengeResultMessage {
  const ChallengeResultMessage({
    required this.challengeId,
    required this.ok,
    required this.bandMac,
    this.reason,
    this.presenceProof,
    this.seedDigest,
    this.pqcSha3,
    this.pqcKemFp,
  });

  final String challengeId;
  final bool ok;
  final String bandMac;
  final String? reason;

  /// SHA3 presence proof (verifiable by desktop with pair presenceKey).
  final String? presenceProof;

  /// SHA3(bio seed) — not the seed; binds proof to this unlock's on-device seed.
  final String? seedDigest;

  /// SHA3-256(seed) from the same PQC demo pipeline (audit / UI).
  final String? pqcSha3;

  /// ML-KEM-512 pubkey fingerprint from the demo pipeline (audit / UI).
  final String? pqcKemFp;

  Map<String, dynamic> toJson() => {
        'v': 1,
        'type': 'challenge.result',
        'challengeId': challengeId,
        'ok': ok,
        'bandMac': bandMac,
        'reason': reason,
        if (presenceProof != null) 'presenceProof': presenceProof,
        if (seedDigest != null) 'seedDigest': seedDigest,
        if (pqcSha3 != null) 'pqcSha3': pqcSha3,
        if (pqcKemFp != null) 'pqcKemFp': pqcKemFp,
      };
}

/// Live band readiness — no BPM values.
class PresenceUpdateMessage {
  const PresenceUpdateMessage({
    required this.bandMac,
    required this.bandReady,
  });

  final String bandMac;
  final bool bandReady;

  Map<String, dynamic> toJson() => {
        'v': 1,
        'type': 'presence.update',
        'bandMac': bandMac,
        'bandReady': bandReady,
      };
}
