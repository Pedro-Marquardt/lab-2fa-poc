/// Mensagens WebSocket do lab 2FA (contrato congelado).
class PairRegisterMessage {
  const PairRegisterMessage({
    required this.pairingNonce,
    required this.bandMac,
    this.deviceLabel = 'phone',
  });

  final String pairingNonce;
  final String bandMac;
  final String deviceLabel;

  Map<String, dynamic> toJson() => {
        'v': 1,
        'type': 'pair.register',
        'pairingNonce': pairingNonce,
        'bandMac': bandMac,
        'deviceLabel': deviceLabel,
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
  });

  final String challengeId;
  final bool ok;
  final String bandMac;
  final String? reason;

  Map<String, dynamic> toJson() => {
        'v': 1,
        'type': 'challenge.result',
        'challengeId': challengeId,
        'ok': ok,
        'bandMac': bandMac,
        'reason': reason,
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
