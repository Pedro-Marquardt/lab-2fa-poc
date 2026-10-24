import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Completes an optional lab API pairing ticket after local WS pair.register.
/// Failures are logged only — never breaks local pairing.
/// Body is bandMac + deviceLabel only (no BPM / physio).
Future<void> completePairingTicketBestEffort({
  required String apiBaseUrl,
  required String ticketId,
  required String bandMac,
  String deviceLabel = 'phone',
}) async {
  final base = apiBaseUrl.trim().replaceAll(RegExp(r'/+$'), '');
  if (base.isEmpty || ticketId.isEmpty) {
    debugPrint('[LabApi] skip ticket complete (missing base/ticket)');
    return;
  }

  final uri = Uri.parse('$base/v1/pairing/tickets/$ticketId/complete');
  try {
    final res = await http
        .post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'bandMac': bandMac,
            'deviceLabel': deviceLabel,
          }),
        )
        .timeout(const Duration(seconds: 8));
    if (res.statusCode >= 200 && res.statusCode < 300) {
      debugPrint('[LabApi] ticket $ticketId completed');
    } else {
      debugPrint(
        '[LabApi] ticket complete HTTP ${res.statusCode}: ${res.body}',
      );
    }
  } on Object catch (e) {
    debugPrint('[LabApi] ticket complete failed (ignored): $e');
  }
}
