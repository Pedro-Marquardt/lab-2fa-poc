import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:permission_handler/permission_handler.dart';

import 'config/env.dart';
import 'huami/miband.dart';
import 'lab/bio_seed.dart';
import 'lab/bpm_gate.dart';
import 'lab/lab_ws_client.dart';
import 'lab/pqc_demo.dart';
import 'lab/presence_proof.dart';
import 'lab/qr_payload.dart';
import 'lab/ws_messages.dart';
import 'permissions/ble_permissions.dart';
import 'screens/qr_scan_screen.dart';
import 'widgets/seed_matrix.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: '.env');
  runApp(const BioentropyApp());
}

class BioentropyApp extends StatelessWidget {
  const BioentropyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Wearable 2FA · PQC',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0B6E4F),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final MiBandClient _client;
  late final LabWsClient _ws;
  MiBandState _bandState = MiBandState.idle;
  LabWsStatus _labStatus = LabWsStatus.disconnected;
  int? _bpm;
  int? _steps;
  int? _spo2;
  String? _error;
  String? _desktopName;
  ChallengeResultMessage? _lastChallengeResult;
  bool _challengeBusy = false;
  bool _hashBusy = false;
  List<List<int>>? _matrix;
  String? _sha3Hex;
  String? _mlKemFpHex;
  String? _seedMeta;

  final _bpmBuffer = <int>[];
  static const _bpmBufferMax = 16;

  final _subs = <StreamSubscription<dynamic>>[];

  @override
  void initState() {
    super.initState();
    _client = MiBandClient(authKeyHex: AppEnv.authKey);
    _ws = LabWsClient();

    _subs.add(_client.state$.listen((s) {
      if (mounted) setState(() => _bandState = s);
      _pushPresence();
    }));
    _subs.add(_client.heartRate$.listen((bpm) {
      if (!mounted) return;
      setState(() => _bpm = bpm);
      if (bpm != null && bpm >= 40 && bpm <= 200) {
        _bpmBuffer.add(bpm);
        while (_bpmBuffer.length > _bpmBufferMax) {
          _bpmBuffer.removeAt(0);
        }
      }
    }));
    _subs.add(_client.steps$.listen((steps) {
      if (mounted) setState(() => _steps = steps);
    }));
    _subs.add(_client.log$.listen(debugPrint));
    _subs.add(_ws.status$.listen((s) {
      if (mounted) setState(() => _labStatus = s);
    }));
    _subs.add(_ws.log$.listen(debugPrint));
    _subs.add(_ws.challenge$.listen(_onChallenge));
    _subs.add(_ws.result$.listen((r) {
      if (mounted) setState(() => _lastChallengeResult = r);
    }));
  }

  @override
  void dispose() {
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    unawaited(_ws.dispose());
    unawaited(_client.dispose());
    super.dispose();
  }

  String get _bandMac => _client.bandMac ?? AppEnv.mac ?? '';

  bool get _bandConnected =>
      _bandState != MiBandState.idle && _bandState != MiBandState.error;

  bool get _bandBusy =>
      _bandState == MiBandState.scanning ||
      _bandState == MiBandState.connecting ||
      _bandState == MiBandState.authenticating;

  bool get _paired =>
      _labStatus == LabWsStatus.paired ||
      _labStatus == LabWsStatus.challengeInProgress ||
      _labStatus == LabWsStatus.result;

  String get _labStateLabel {
    final bandLive = _client.isStreamingHr;
    return switch (_labStatus) {
      LabWsStatus.disconnected => 'Offline',
      LabWsStatus.connecting => 'A emparelhar…',
      LabWsStatus.paired => bandLive ? 'Sync' : 'Sem band',
      LabWsStatus.challengeInProgress => 'Challenge…',
      LabWsStatus.result => _lastChallengeResult?.ok == true
          ? (bandLive ? 'OK' : 'OK · sem band')
          : 'Falhou',
      LabWsStatus.error => 'Erro WS',
    };
  }

  String get _bandStateLabel => switch (_bandState) {
        MiBandState.idle => 'Parado',
        MiBandState.scanning => 'A procurar…',
        MiBandState.connecting => 'A conectar…',
        MiBandState.authenticating => 'A autenticar…',
        MiBandState.authenticated => 'OK',
        MiBandState.streamingHr => 'HR',
        MiBandState.error => 'Erro',
      };

  void _pushPresence() {
    if (!_ws.isSessionLive) return;
    final mac = _bandMac;
    if (mac.isEmpty) return;
    _ws.sendPresenceUpdate(
      bandMac: mac,
      bandReady: _client.isStreamingHr,
    );
  }

  void _showPermSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        action: SnackBarAction(
          label: 'Abrir definições',
          onPressed: openAppSettings,
        ),
      ),
    );
  }

  Future<void> _connectBand() async {
    setState(() {
      _error = null;
      _bpm = null;
      _steps = null;
      _bpmBuffer.clear();
    });
    try {
      final permError = await BlePermissions.ensure(
        onLog: debugPrint,
      );
      if (permError != null) {
        _showPermSnackBar(permError);
        setState(() => _error = permError);
        return;
      }

      await _client.connect(preferredMac: AppEnv.mac);
      if (mounted) {
        setState(() {
          _steps = _client.lastSteps;
          _spo2 = _client.lastSpo2 ?? _spo2;
        });
      }
    } on PlatformException catch (e) {
      final msg = 'PlatformException [${e.code}]: ${e.message}';
      debugPrint('$msg\n${e.details ?? ""}');
      if (mounted) setState(() => _error = msg);
    } catch (e) {
      debugPrint(e.toString());
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _toggleBand() async {
    if (_bandConnected) {
      await _client.disconnect();
      if (mounted) {
        setState(() {
          _bpm = null;
          _steps = null;
          // Keep last SpO₂ in UI/session cache for the PQC seed.
          _bpmBuffer.clear();
        });
      }
      return;
    }
    await _connectBand();
  }

  Future<void> _generateHash() async {
    if (_hashBusy) return;
    final mac = _bandMac;
    if (mac.isEmpty) {
      setState(() => _error = 'Sem MAC da band');
      return;
    }
    final samples = List<int>.from(_bpmBuffer);
    if (samples.isEmpty && _bpm != null) samples.add(_bpm!);
    if (samples.isEmpty) {
      setState(() => _error = 'Precisa de BPM ao vivo');
      return;
    }

    setState(() {
      _hashBusy = true;
      _error = null;
      _sha3Hex = null;
      _mlKemFpHex = null;
      _seedMeta = null;
    });

    try {
      // Instant seed from live/cached band values — no on-demand SpO₂.
      final spo2 = _client.lastSpo2 ?? _spo2;
      final steps = _client.lastSteps ?? _steps;
      final bio = deriveBioSeed(
        BioSeedInput(
          bpmSamples: samples,
          bandMac: mac,
          capturedAtMs: DateTime.now().millisecondsSinceEpoch,
          spo2: spo2,
          steps: steps,
          distanceM: _client.lastDistanceM,
          calories: _client.lastCalories,
        ),
      );
      final pqc = runPqcDemo(bio.seed32);

      if (!mounted) {
        bio.wipe();
        return;
      }
      setState(() {
        _matrix = bio.matrix.map((r) => List<int>.from(r)).toList();
        _sha3Hex = pqc.sha3Hex;
        _mlKemFpHex = pqc.mlKemPubFpHex;
        _spo2 = bio.usedSpo2;
        _steps = bio.usedSteps;
        _seedMeta =
            'Seed: HR×${bio.usedBpm.length} · steps ${bio.usedSteps ?? "—"}'
            '${bio.usedSpo2 != null ? " · SpO₂ ${bio.usedSpo2}" : ""}'
            ' · on-device';
      });
      bio.wipe();
    } on Object catch (e) {
      debugPrint('generateHash: $e');
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _hashBusy = false);
    }
  }

  Future<void> _ensureBandReady() async {
    if (_client.isStreamingHr) return;
    await _connectBand();
    if (!_client.isStreamingHr) {
      throw StateError('Mi Band não está a transmitir HR');
    }
  }

  Future<void> _scanAndPair() async {
    setState(() {
      _error = null;
      _lastChallengeResult = null;
    });

    final qr = await Navigator.of(context).push<PairingQr>(
      MaterialPageRoute(builder: (_) => const QrScanScreen()),
    );
    if (qr == null || !mounted) return;

    setState(() => _desktopName = qr.desktopName);

    try {
      await _ensureBandReady();
      final mac = _bandMac;
      if (mac.isEmpty) {
        throw StateError(
          'Sem bandMac — conecta a Mi Band ou define MIBAND_MAC no .env',
        );
      }
      await _ws.connectAndRegister(qr: qr, bandMac: mac);
      _pushPresence();
    } on Object catch (e) {
      debugPrint(e.toString());
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _onChallenge(ChallengeRequest req) async {
    if (_challengeBusy) {
      debugPrint('challenge: BUSY — denying ${req.challengeId}');
      _ws.sendChallengeResult(
        ChallengeResultMessage(
          challengeId: req.challengeId,
          ok: false,
          bandMac:
              _bandMac.isEmpty ? (AppEnv.mac ?? '00:00:00:00:00:00') : _bandMac,
          reason: 'busy',
        ),
      );
      return;
    }
    _challengeBusy = true;
    final mac = _bandMac;
    try {
      String? reason;
      var ok = false;
      String? presenceProof;
      String? seedDigest;
      String? pqcSha3;
      String? pqcKemFp;

      try {
        await _ensureBandReady();
        final session = _ws.session;
        if (mac.isEmpty) {
          reason = 'no_band_mac';
        } else if (session == null) {
          reason = 'no_pairing_session';
          debugPrint('challenge: FAIL no_pairing_session');
        } else if (!_client.isStreamingHr) {
          reason = 'hr_not_streaming';
          debugPrint('challenge: FAIL hr_not_streaming');
        } else {
          debugPrint(
            'challenge: waiting presence '
            '(fresh=${_client.hasFreshHr()} last=${_client.lastHeartRate ?? "-"})…',
          );
          // Lab gate: one live in-range BPM is enough (fast presence).
          final valid = await waitValidBpm(
            heartRate$: _client.heartRate$,
            minSamples: 1,
            minDistinct: 1,
            minSpan: Duration.zero,
            minSampleGap: Duration.zero,
            timeout: const Duration(seconds: 8),
            onEvent: debugPrint,
          );
          if (valid && _client.hasFreshHr()) {
            final samples = List<int>.from(_bpmBuffer);
            if (samples.isEmpty && _bpm != null) samples.add(_bpm!);
            if (samples.isEmpty) {
              reason = 'no_bpm_samples';
            } else {
              final bio = deriveBioSeed(
                BioSeedInput(
                  bpmSamples: samples,
                  bandMac: mac,
                  capturedAtMs: DateTime.now().millisecondsSinceEpoch,
                  spo2: _client.lastSpo2 ?? _spo2,
                  steps: _client.lastSteps ?? _steps,
                  distanceM: _client.lastDistanceM,
                  calories: _client.lastCalories,
                ),
              );
              final pqc = runPqcDemo(bio.seed32);
              seedDigest = seedDigestHex(bio.seed32);
              presenceProof = computePresenceProof(
                presenceKeyHex: session.presenceKeyHex,
                challengeId: req.challengeId,
                bandMac: mac,
                seedDigestHex: seedDigest,
              );
              pqcSha3 = pqc.sha3Hex;
              pqcKemFp = pqc.mlKemPubFpHex;
              if (mounted) {
                setState(() {
                  _matrix =
                      bio.matrix.map((r) => List<int>.from(r)).toList();
                  _sha3Hex = pqc.sha3Hex;
                  _mlKemFpHex = pqc.mlKemPubFpHex;
                  _steps = bio.usedSteps;
                  _spo2 = bio.usedSpo2;
                  _seedMeta =
                      'Unlock seed: HR×${bio.usedBpm.length} · steps ${bio.usedSteps ?? "—"}'
                      ' · presence proof';
                });
              }
              bio.wipe();
              ok = true;
              debugPrint('challenge: presence + PQC proof OK');
            }
          } else if (valid && !_client.hasFreshHr()) {
            reason = 'hr_stale';
            debugPrint('challenge: presence FAIL (hr_stale after samples)');
          } else {
            reason = 'no_valid_bpm';
            debugPrint('challenge: presence FAIL (no_valid_bpm)');
          }
        }
      } on Object catch (e) {
        reason = 'band_error';
        debugPrint('challenge band: $e');
      }

      final result = ChallengeResultMessage(
        challengeId: req.challengeId,
        ok: ok,
        bandMac: mac.isEmpty ? (AppEnv.mac ?? '00:00:00:00:00:00') : mac,
        reason: ok ? null : reason,
        presenceProof: ok ? presenceProof : null,
        seedDigest: ok ? seedDigest : null,
        pqcSha3: ok ? pqcSha3 : null,
        pqcKemFp: ok ? pqcKemFp : null,
      );
      debugPrint(
        'challenge.result ok=$ok reason=${reason ?? "-"} '
        'proof=${presenceProof != null} (BPM/seed not sent)',
      );
      _ws.sendChallengeResult(result);
    } finally {
      _challengeBusy = false;
    }
  }

  Future<void> _unpair() async {
    await _ws.disconnect();
    setState(() {
      _desktopName = null;
      _lastChallengeResult = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Wearable 2FA'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: Text(
                'PQC demo',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: scheme.primary,
                    ),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Mi Band → local seed → SHA3 + ML-KEM',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 20),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        color: scheme.surfaceContainerHighest,
                      ),
                      child: Column(
                        children: [
                          Text(
                            _bpm?.toString() ?? '—',
                            style: Theme.of(context).textTheme.displayMedium,
                          ),
                          Text(
                            'Heart rate',
                            style: Theme.of(context)
                                .textTheme
                                .labelLarge
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Steps ${_steps?.toString() ?? "—"}'
                            '${_spo2 != null ? " · SpO₂ $_spo2" : ""}',
                            style: Theme.of(context)
                                .textTheme
                                .labelMedium
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    children: [
                      SeedMatrix(matrix: _matrix),
                      const SizedBox(height: 6),
                      Text(
                        'Seed matrix',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _StatusChip(
                    label: 'Band · $_bandStateLabel',
                    tone: _bandState == MiBandState.streamingHr
                        ? _ChipTone.ok
                        : _ChipTone.neutral,
                  ),
                  _StatusChip(
                    label: _desktopName != null
                        ? 'Desktop · $_labStateLabel · $_desktopName'
                        : 'Desktop · $_labStateLabel',
                    tone: switch (_labStatus) {
                      LabWsStatus.paired =>
                        _client.isStreamingHr ? _ChipTone.ok : _ChipTone.warn,
                      LabWsStatus.challengeInProgress => _ChipTone.warn,
                      LabWsStatus.result => _lastChallengeResult?.ok != true
                          ? _ChipTone.err
                          : (_client.isStreamingHr
                              ? _ChipTone.ok
                              : _ChipTone.warn),
                      LabWsStatus.error => _ChipTone.err,
                      _ => _ChipTone.neutral,
                    },
                  ),
                ],
              ),
              if (_seedMeta != null) ...[
                const SizedBox(height: 12),
                Text(
                  _seedMeta!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ],
              if (_sha3Hex != null) ...[
                const SizedBox(height: 8),
                SelectableText(
                  'SHA3-256  ${_sha3Hex!.substring(0, 20)}…',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                SelectableText(
                  'ML-KEM-512  ${_mlKemFpHex!.substring(0, 20)}…',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              const Spacer(),
              if (_error != null) ...[
                Text(
                  _error!,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: scheme.error),
                ),
                const SizedBox(height: 12),
              ],
              FilledButton(
                onPressed: (_hashBusy ||
                        !_client.isStreamingHr ||
                        _bpmBuffer.isEmpty && _bpm == null)
                    ? null
                    : _generateHash,
                child: Text(
                  _hashBusy ? 'Generating…' : 'Generate PQC hash',
                ),
              ),
              const SizedBox(height: 8),
              FilledButton.tonal(
                onPressed: _bandBusy ? null : _toggleBand,
                child: Text(
                  _bandConnected ? 'Disconnect band' : 'Connect Mi Band',
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed:
                    _labStatus == LabWsStatus.connecting ? null : _scanAndPair,
                child: Text(
                  _paired ? 'Re-pair desktop' : 'Pair with desktop',
                ),
              ),
              if (_paired) ...[
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _unpair,
                  child: const Text('Unpair'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

enum _ChipTone { neutral, ok, warn, err }

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label, required this.tone});

  final String label;
  final _ChipTone tone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = switch (tone) {
      _ChipTone.ok => scheme.primaryContainer,
      _ChipTone.warn => scheme.tertiaryContainer,
      _ChipTone.err => scheme.errorContainer,
      _ChipTone.neutral => scheme.surfaceContainerHighest,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(label, style: Theme.of(context).textTheme.labelLarge),
    );
  }
}
