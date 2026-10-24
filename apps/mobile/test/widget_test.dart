import 'package:flutter_test/flutter_test.dart';

import 'package:bioentropy_mobile/lab/qr_payload.dart';

void main() {
  test('PairingQr smoke', () {
    final qr = PairingQr.fromJson({
      'v': 1,
      'wsUrl': 'ws://127.0.0.1:8787',
      'pairingNonce': 'n',
      'desktopName': 'lab-pc',
      'apiTicketId': null,
    });
    expect(qr.desktopName, 'lab-pc');
  });
}
