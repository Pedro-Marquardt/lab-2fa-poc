import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

/// Permissões BLE no Xiaomi/Android 14.
///
/// No Android 12+ o diálogo chama-se **"Dispositivos próximos"** (não
/// "Bluetooth"). A permissão antiga `Permission.bluetooth` **não existe**
/// nessa versão — se a pedires, fica "em falta" sem popup.
class BlePermissions {
  BlePermissions._();

  static Future<int> _sdk() async {
    if (!Platform.isAndroid) return 0;
    return (await DeviceInfoPlugin().androidInfo).version.sdkInt;
  }

  /// Resultado: erro (bloqueante) ou null se pode continuar.
  /// [onLog] recebe o estado de cada permissão (para o ecrã de debug).
  static Future<String?> ensure({void Function(String msg)? onLog}) async {
    final log = onLog ?? (_) {};
    final sdk = await _sdk();

    if (!Platform.isAndroid) {
      final s = await Permission.bluetooth.request();
      log('iOS/desktop bluetooth: $s');
      return s.isGranted ? null : 'Bluetooth negado';
    }

    // Android 12+ (teu Android 14 = API 34)
    if (sdk >= 31) {
      final scan = await _ask(Permission.bluetoothScan, log);
      final connect = await _ask(Permission.bluetoothConnect, log);

      // Localização: no Xiaomi ajuda o scan, mas NÃO bloqueia se BT já está OK
      final loc = await _ask(Permission.locationWhenInUse, log);
      log('GPS/localização service: ${await Permission.locationWhenInUse.serviceStatus}');

      if (scan.isGranted && connect.isGranted) {
        if (!loc.isGranted) {
          log('Aviso: localização não concedida — no Xiaomi liga o GPS mesmo assim.');
        }
        return null;
      }

      if (scan.isPermanentlyDenied || connect.isPermanentlyDenied) {
        await openAppSettings();
        return 'Bluetooth bloqueado nas definições.\n'
            'Definições → Apps → Bioentropy → Permissões → '
            'Dispositivos próximos → Permitir.';
      }

      return 'Falta permissão de Dispositivos próximos '
          '(scan=$scan, connect=$connect).\n'
          'Se não apareceu popup: Definições → Apps → Bioentropy → '
          'Permissões → Dispositivos próximos.';
    }

    // Android ≤11
    final loc = await _ask(Permission.locationWhenInUse, log);
    final bt = await _ask(Permission.bluetooth, log);
    if (loc.isGranted && bt.isGranted) return null;
    return 'Permissões em falta (Android antigo): location=$loc bluetooth=$bt';
  }

  static Future<PermissionStatus> _ask(
    Permission p,
    void Function(String) log,
  ) async {
    var status = await p.status;
    log('$p → status inicial: $status');
    if (status.isGranted || status.isLimited) return status;

    status = await p.request();
    log('$p → depois do request: $status');
    return status;
  }
}
