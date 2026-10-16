import 'dart:async';
import 'dart:io' show pid;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
// The detector is not exported; the screen reads its brackets from the
// detector's own metadata so the thresholds cannot drift from the audit.
// ignore: implementation_imports
import 'package:sleuth/src/detectors/startup_detector.dart';

import 'capture_driver.dart';
import 'startup_leg.dart';

/// Result view and launch commands for the slow_startup_ttff capture
/// legs. A leg runs at launch (see `startup_leg.dart`), so this screen
/// runs nothing itself. It shows the latest leg's verdict and values,
/// copies each leg's devicectl command, and exports a stashed capture.
///
/// **Procedure per leg:**
///
///   1. `cd example && fvm flutter run --profile --no-dds -d "iPhone 12" \
///         --dart-define=SLEUTH_CAPTURE_MODE=true \
///         --dart-define=SLEUTH_CAPTURE_DEVICE="iPhone 12"` once to
///      install the build; that first launch does not count.
///   2. Run the leg's command from this screen (Copy launch command) on
///      the host, with the device id in place of `<device>`.
///   3. Wait about 20 s, then copy `tmp/sleuth_startup_legs/<scenario>.json`
///      from the app container with `xcrun devicectl device copy from`,
///      or open this screen and tap **Export last leg**.
class SlowStartupCaptureScreen extends StatefulWidget {
  const SlowStartupCaptureScreen({
    super.key,
    this.captureModeOverride,
    this.provenanceCheck = currentCaptureProvenance,
    this.results,
    this.currentPid,
  });

  /// Capture mode for tests. Null reads the build's
  /// `SLEUTH_CAPTURE_MODE` dart-define.
  @visibleForTesting
  final bool? captureModeOverride;

  /// Where the screen reads the provenance a leg stamps.
  @visibleForTesting
  final CaptureProvenanceCheck Function() provenanceCheck;

  /// Where the legs write their files; null reads
  /// [startupLegResultsDirectory].
  @visibleForTesting
  final StartupLegResults? results;

  /// This process's id; null reads `dart:io`'s [pid]. A `running` record
  /// from another process means that launch ended during its leg.
  @visibleForTesting
  final int? currentPid;

  @override
  State<SlowStartupCaptureScreen> createState() =>
      _SlowStartupCaptureScreenState();
}

/// The latest leg as the screen shows it.
typedef _Shown = ({
  StartupLegRecord? record,
  String? problem,
  bool runningHere,
});

class _SlowStartupCaptureScreenState extends State<SlowStartupCaptureScreen> {
  late final StartupLegResults _results;
  late final CaptureProvenanceCheck _provenance;
  late final String _warningMs;
  late final String _criticalMs;
  final List<String> _log = [];
  _Shown _shown = (record: null, problem: null, runningHere: false);
  Timer? _refresh;
  bool _copying = false;

  bool get _captureModeOn =>
      widget.captureModeOverride ??
      const bool.fromEnvironment('SLEUTH_CAPTURE_MODE');

  @override
  void initState() {
    super.initState();
    _results = widget.results ?? StartupLegResults();
    _provenance = widget.provenanceCheck();
    final metadata = StartupDetector().validationMetadata;
    String ms(StartupLeg leg) {
      final bracket = startupLegBracket(metadata, leg);
      return bracket == null ? '?' : bracket.threshold.toStringAsFixed(0);
    }

    _warningMs = ms(StartupLeg.at);
    _criticalMs = ms(StartupLeg.criticalAt);
    _read();
    // A leg of this launch may still be running; follow it to its end.
    if (_shown.runningHere) {
      _refresh = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(_read);
        if (!_shown.runningHere) _refresh?.cancel();
      });
    }
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  void _read() {
    StartupLegRecord? record;
    String? problem;
    try {
      record = _results.readRecord();
    } on Object catch (e) {
      problem = 'The last result could not be read ($e).';
    }
    final here = '${widget.currentPid ?? pid}-';
    var runningHere = false;
    if (record != null && record.state == 'running') {
      if (record.launchId.startsWith(here)) {
        runningHere = true;
      } else {
        record = record.copyWith(
          state: 'failed',
          verdict: 'FAILED',
          reason:
              'the app ended during the leg (killed, crashed or '
              'relaunched)',
        );
      }
    }
    _shown = (record: record, problem: problem, runningHere: runningHere);
  }

  void _say(String line) {
    if (!mounted) return;
    setState(() => _log.add(line));
  }

  Future<void> _copyCommand(StartupLeg leg) async {
    try {
      await Clipboard.setData(ClipboardData(text: leg.launchCommand()));
      _say(
        '[${leg.label}] launch command copied. Replace <device> with the '
        'device id and run it on the host.',
      );
    } catch (e) {
      _say('[${leg.label}] clipboard copy FAILED: $e');
    }
  }

  Future<void> _exportLastLeg() async {
    final record = _shown.record;
    if (record == null || !record.isStashed) {
      _say(
        'Export: no stashed leg. Run a leg until its result reads '
        '"capture stashed".',
      );
      return;
    }
    final label = record.leg?.label ?? record.scenario;
    setState(() => _copying = true);
    try {
      final file = _results.captureFile(record.scenario);
      if (!file.existsSync()) {
        _say('[$label] FAILED: the stashed capture file is missing.');
        return;
      }
      final json = file.readAsStringSync();
      await Clipboard.setData(ClipboardData(text: json));
      _say(
        '[$label] copied ${json.length} chars. Save as '
        '${record.scenario}.json under test/validation/captures/startup/.',
      );
    } catch (e) {
      _say('[$label] clipboard copy FAILED: $e');
    } finally {
      if (mounted) setState(() => _copying = false);
    }
  }

  String _statusLine() {
    final problem = _shown.problem;
    if (problem != null) return problem;
    final record = _shown.record;
    if (record == null) {
      return 'No startup leg has run on this install. Launch one with a '
          'command below.';
    }
    final label = record.leg?.label ?? record.scenario;
    return 'Last leg ($label): ${record.line}';
  }

  @override
  Widget build(BuildContext context) {
    final stamp = _provenance.provenance;
    const evidenceStyle = TextStyle(
      fontFamily: 'monospace',
      fontSize: 12,
      fontFeatures: [FontFeature.tabularFigures()],
    );
    final record = _shown.record;
    final leg = record?.leg;
    final bracket = leg == null
        ? null
        : startupLegBracket(StartupDetector().validationMetadata, leg);
    String ms(double? value) =>
        value == null ? 'not measured' : '${value.toStringAsFixed(1)} ms';
    return Scaffold(
      appBar: AppBar(title: const Text('slow_startup_ttff capture')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          // Export and the status stay in view below the controls on a
          // tall body.
          child: CaptureBodyLayout(
            controlsShare: 0.45,
            controls: [
              // A leg launch connects to the VM service by itself, so
              // this screen's own VM link does not block anything.
              CapturePreflightBanner(
                captureMode: _captureModeOn,
                vmConnected: true,
                provenanceProblem: _provenance.problem,
              ),
              if (stamp != null)
                Text(
                  'Provenance: ${stamp.device} / '
                  '${stamp.deviceOsVersion} / '
                  'Flutter ${stamp.flutterVersion}',
                  style: const TextStyle(fontSize: 12),
                ),
              const SizedBox(height: 8),
              // The latest leg's evidence comes first: the screen opens
              // after a cold launch with the leg already finished.
              if (record == null)
                const Text('No leg recorded yet.', style: evidenceStyle)
              else ...[
                Text(
                  'Leg: ${leg?.title ?? record.scenario} '
                  '(${record.scenario})',
                  style: evidenceStyle,
                ),
                Text(
                  'Time to first frame: ${ms(record.observedMs)}',
                  style: evidenceStyle,
                ),
                Text(
                  'Detector ttffMs: ${ms(record.detectorMs)}',
                  style: evidenceStyle,
                ),
                if (bracket != null && leg != null)
                  Text(
                    'Band: ${bracket.bandText(leg.role)} ms',
                    style: evidenceStyle,
                  ),
                Text(
                  'Delay ${record.delayMs ?? '?'} ms, launch '
                  '${record.launchId}, '
                  '${record.updatedAt?.toLocal().toString().split('.').first ?? 'time unknown'}',
                  style: evidenceStyle,
                ),
              ],
              const SizedBox(height: 8),
              Text(
                'Each leg is a cold launch that blocks between Sleuth.init '
                'and runApp, and records slow_startup_ttff: a warning at '
                '$_warningMs ms to first frame, critical at $_criticalMs ms. '
                'The host starts it with the command below; the result '
                'shows here on the next open.',
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              for (final leg in StartupLeg.values) ...[
                if (leg == StartupLeg.criticalBelow) const SizedBox(height: 8),
                _LegRow(leg: leg, onCopy: () => _copyCommand(leg)),
              ],
            ],
            pinned: [
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: _copying ? null : _exportLastLeg,
                icon: const Icon(Icons.save_alt),
                label: const Text('Export last leg'),
              ),
              const SizedBox(height: 8),
              // Three lines at most so a large text scale cannot push the
              // log off the screen; the log keeps the full line.
              Semantics(
                liveRegion: true,
                child: Text(
                  _statusLine(),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const Divider(height: 24),
            ],
            log: ListView.builder(
              reverse: true,
              itemCount: _log.length,
              itemBuilder: (context, i) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  _log[_log.length - 1 - i],
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One leg: its title, target and delay, and a button that copies its
/// launch command.
class _LegRow extends StatelessWidget {
  const _LegRow({required this.leg, required this.onCopy});

  final StartupLeg leg;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    // The button sits under the text, not beside it, so neither has to
    // give way at a large text scale on a narrow phone.
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${leg.title}: about ${leg.targetMs} ms to first frame '
            '(delay ${leg.delayMs} ms)',
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 4),
          OutlinedButton.icon(
            onPressed: onCopy,
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            icon: const Icon(Icons.copy),
            label: Text('Copy launch command (${leg.label})'),
          ),
        ],
      ),
    );
  }
}
