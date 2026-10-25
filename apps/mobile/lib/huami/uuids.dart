import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// UUIDs Huami / Mi Band (Gadgetbridge + miband-6-heart-rate-monitor).
abstract final class HuamiUuids {
  static final Guid miband1 = Guid('0000fee0-0000-1000-8000-00805f9b34fb');
  static final Guid miband2 = Guid('0000fee1-0000-1000-8000-00805f9b34fb');
  static final Guid heartrate = Guid('0000180d-0000-1000-8000-00805f9b34fb');

  static final Guid auth = Guid('00000009-0000-3512-2118-0009af100700');
  /// Realtime steps / distance / calories (Huami).
  static final Guid realtimeSteps =
      Guid('00000007-0000-3512-2118-0009af100700');
  static final Guid chunkedWrite =
      Guid('00000016-0000-3512-2118-0009af100700');
  static final Guid chunkedRead =
      Guid('00000017-0000-3512-2118-0009af100700');
  static final Guid hrMeasure = Guid('00002a37-0000-1000-8000-00805f9b34fb');
  static final Guid hrControl = Guid('00002a39-0000-1000-8000-00805f9b34fb');
  static final Guid batteryLevel =
      Guid('00002a19-0000-1000-8000-00805f9b34fb');
}
