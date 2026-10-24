/// Payload do QR gerado pelo desktop (contrato lab 2FA).
class PairingQr {
  const PairingQr({
    required this.v,
    required this.wsUrl,
    required this.pairingNonce,
    required this.desktopName,
    this.apiTicketId,
    this.apiBaseUrl,
  });

  final int v;
  final String wsUrl;
  final String pairingNonce;
  final String desktopName;
  final String? apiTicketId;

  /// Base URL for optional ticket complete (e.g. `http://127.0.0.1:8000`).
  final String? apiBaseUrl;

  factory PairingQr.fromJson(Map<String, dynamic> json) {
    final v = json['v'];
    final wsUrl = json['wsUrl'];
    final pairingNonce = json['pairingNonce'];
    final desktopName = json['desktopName'];
    if (v is! int || v != 1) {
      throw FormatException('QR v inválido (esperado 1)');
    }
    if (wsUrl is! String || wsUrl.isEmpty) {
      throw FormatException('QR sem wsUrl');
    }
    if (pairingNonce is! String || pairingNonce.isEmpty) {
      throw FormatException('QR sem pairingNonce');
    }
    if (desktopName is! String || desktopName.isEmpty) {
      throw FormatException('QR sem desktopName');
    }
    final ticket = json['apiTicketId'];
    if (ticket != null && ticket is! String) {
      throw FormatException('apiTicketId deve ser string ou null');
    }
    final base = json['apiBaseUrl'];
    if (base != null && base is! String) {
      throw FormatException('apiBaseUrl deve ser string ou null');
    }
    return PairingQr(
      v: v,
      wsUrl: wsUrl,
      pairingNonce: pairingNonce,
      desktopName: desktopName,
      apiTicketId: ticket as String?,
      apiBaseUrl: base as String?,
    );
  }
}
