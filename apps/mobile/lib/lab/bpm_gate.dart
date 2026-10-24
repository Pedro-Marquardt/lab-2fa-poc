import 'dart:async';

bool isValidBpm(int bpm, {int minBpm = 40, int maxBpm = 200}) =>
    bpm >= minBpm && bpm <= maxBpm;

/// Espera presença com BPM ao vivo (sem cache).
///
/// Regras lab (anti off-wrist / valor colado):
/// - [minSamples] amostras válidas no stream durante a espera
/// - espaçamento mínimo [minSampleGap] entre aceites
/// - janela mínima [minSpan] entre a 1ª e a última amostra
/// - pelo menos [minDistinct] valores de BPM diferentes
/// - se o gap entre eventos exceder [maxIdleGap], a contagem reinicia
/// - `null` reinicia (off-wrist / HR stale no cliente)
///
/// [onEvent] = log local no telemóvel apenas.
Future<bool> waitValidBpm({
  required Stream<int?> heartRate$,
  int minSamples = 3,
  int minDistinct = 2,
  Duration timeout = const Duration(seconds: 20),
  Duration minSampleGap = const Duration(milliseconds: 700),
  Duration minSpan = const Duration(seconds: 2),
  Duration maxIdleGap = const Duration(seconds: 3),
  int minBpm = 40,
  int maxBpm = 200,
  void Function(String message)? onEvent,
}) async {
  if (minSamples < 1) {
    throw ArgumentError.value(minSamples, 'minSamples', 'must be >= 1');
  }
  if (minDistinct < 1) {
    throw ArgumentError.value(minDistinct, 'minDistinct', 'must be >= 1');
  }

  final completer = Completer<bool>();
  StreamSubscription<int?>? sub;
  Timer? timer;
  Timer? idleWatch;
  var count = 0;
  DateTime? firstAcceptedAt;
  DateTime? lastAcceptedAt;
  DateTime? lastEventAt;
  final distinct = <int>{};

  void reset(String why) {
    if (count > 0 || distinct.isNotEmpty) {
      onEvent?.call('bpm_gate reset ($why) was $count/$minSamples distinct=${distinct.length}');
    }
    count = 0;
    firstAcceptedAt = null;
    lastAcceptedAt = null;
    distinct.clear();
  }

  void finish(bool ok) {
    if (completer.isCompleted) return;
    timer?.cancel();
    idleWatch?.cancel();
    unawaited(sub?.cancel());
    onEvent?.call(
      ok
          ? 'bpm_gate OK samples=$count distinct=${distinct.length} '
              'spanMs=${firstAcceptedAt == null ? 0 : DateTime.now().difference(firstAcceptedAt!).inMilliseconds}'
          : 'bpm_gate FAIL samples=$count/$minSamples distinct=${distinct.length}/$minDistinct',
    );
    completer.complete(ok);
  }

  bool tryComplete() {
    if (count < minSamples) return false;
    if (distinct.length < minDistinct) {
      onEvent?.call(
        'bpm_gate need distinct BPM (have ${distinct.length}/$minDistinct) — '
        'valor colado/off-wrist?',
      );
      return false;
    }
    final span = firstAcceptedAt == null
        ? Duration.zero
        : DateTime.now().difference(firstAcceptedAt!);
    if (span < minSpan) {
      onEvent?.call(
        'bpm_gate need span ${minSpan.inMilliseconds}ms '
        '(have ${span.inMilliseconds}ms)',
      );
      return false;
    }
    finish(true);
    return true;
  }

  timer = Timer(timeout, () => finish(false));
  idleWatch = Timer.periodic(const Duration(milliseconds: 500), (_) {
    final last = lastEventAt;
    if (last == null) return;
    if (DateTime.now().difference(last) > maxIdleGap && count > 0) {
      reset('idle > ${maxIdleGap.inMilliseconds}ms');
    }
  });

  sub = heartRate$.listen((bpm) {
    lastEventAt = DateTime.now();
    if (bpm == null) {
      reset('null/off-wrist');
      return;
    }
    if (!isValidBpm(bpm, minBpm: minBpm, maxBpm: maxBpm)) {
      onEvent?.call('bpm_gate ignore out-of-range bpm=$bpm');
      return;
    }
    final now = DateTime.now();
    if (lastAcceptedAt != null &&
        now.difference(lastAcceptedAt!) < minSampleGap) {
      onEvent?.call('bpm_gate skip bpm=$bpm (gap < ${minSampleGap.inMilliseconds}ms)');
      return;
    }
    firstAcceptedAt ??= now;
    lastAcceptedAt = now;
    count += 1;
    distinct.add(bpm);
    onEvent?.call(
      'bpm_gate sample $count/$minSamples bpm=$bpm distinct=${distinct.length}',
    );
    tryComplete();
  });

  return completer.future;
}
