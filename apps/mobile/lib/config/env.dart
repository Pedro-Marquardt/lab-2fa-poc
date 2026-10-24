import 'package:flutter_dotenv/flutter_dotenv.dart';

class AppEnv {
  AppEnv._();

  static String get authKey {
    final v = dotenv.env['MIBAND_AUTH_KEY']?.trim() ?? '';
    if (!RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(v)) {
      throw StateError(
        'MIBAND_AUTH_KEY inválida no .env (precisa 32 hex). '
        'Copie .env.example → .env e preencha.',
      );
    }
    return v.toLowerCase();
  }

  /// Pode estar vazio — aí o scan usa o nome da pulseira.
  static String? get mac {
    final v = dotenv.env['MIBAND_MAC']?.trim() ?? '';
    if (v.isEmpty) return null;
    return v.toUpperCase();
  }

  static String get authKeyMasked {
    final k = authKey;
    return '${k.substring(0, 4)}…${k.substring(28)}';
  }
}
