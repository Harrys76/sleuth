// Shared state and leg sequence for the time-share capture screens
// (`RebuildActivityCaptureScreen`, `RepaintCaptureScreen`).
//
// The screens register a leg runner with [CaptureDriver.instance] while
// mounted and publish each leg's progress, observed magnitude and wrapped
// capture JSON through it, so the `ext.sleuthDemo.captureLeg` /
// `captureResult` service extensions in `main.dart` drive and read legs
// without reaching into `State` objects.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sleuth/sleuth.dart';

/// Lifecycle of the most recent capture leg.
enum CaptureLegState { idle, running, done, failed }

/// Starts one leg of a registered capture screen. [tier] is `warning` or
/// `critical`, [role] is `below`, `at` or `above`.
typedef CaptureLegRunner = Future<void> Function(String tier, String role);

/// Process-wide capture-leg state shared by the capture screens and the
/// demo service extensions. Notifies listeners on every state or log
/// change.
class CaptureDriver extends ChangeNotifier {
  CaptureDriver._();

  /// The single driver instance.
  static final CaptureDriver instance = CaptureDriver._();

  final Map<String, CaptureLegRunner> _runners = {};

  CaptureLegState _state = CaptureLegState.idle;
  String? _leg;
  double? _observed;
  String? _json;
  int _attempts = 0;
  final List<String> _log = [];

  /// Current leg state.
  CaptureLegState get state => _state;

  /// True while a leg is running; a second leg is refused.
  bool get isBusy => _state == CaptureLegState.running;

  /// `<detector>/<tier>/<role>` of the current or last leg.
  String? get leg => _leg;

  /// Detector-measured magnitude of the last finished leg.
  double? get observed => _observed;

  /// Wrapped capture JSON of the last successful leg.
  String? get json => _json;

  /// Measured scenario spans the current or last leg has run (0 before
  /// the first, one more per rescaled retry).
  int get attempts => _attempts;

  /// Log lines of the current or last leg, oldest first.
  List<String> get log => List.unmodifiable(_log);

  /// Registers the leg runner of the mounted screen for [detector]
  /// (`rebuild` or `repaint`).
  void register(String detector, CaptureLegRunner runner) {
    _runners[detector] = runner;
  }

  /// Removes [runner] for [detector] if it is still the registered one.
  void unregister(String detector, CaptureLegRunner runner) {
    if (_runners[detector] == runner) _runners.remove(detector);
  }

  /// The runner registered for [detector], if its screen is mounted.
  CaptureLegRunner? runnerFor(String detector) => _runners[detector];

  /// Marks a leg as started. Returns false (and changes nothing) while
  /// another leg is running. Clears the previous result and log.
  bool begin(String leg) {
    if (isBusy) return false;
    _state = CaptureLegState.running;
    _leg = leg;
    _observed = null;
    _json = null;
    _attempts = 0;
    _log.clear();
    notifyListeners();
    return true;
  }

  /// Counts one measured scenario span of the running leg.
  void recordAttempt() {
    _attempts++;
    notifyListeners();
  }

  /// Appends a log line to the current leg.
  void addLog(String line) {
    _log.add(line);
    debugPrint('[sleuth.capture] $line');
    notifyListeners();
  }

  /// Finishes the running leg successfully.
  void complete({required double observed, required String json}) {
    _observed = observed;
    _json = json;
    _state = CaptureLegState.done;
    notifyListeners();
  }

  /// Finishes the running leg with a failure [reason].
  void fail(String reason, {double? observed}) {
    _observed = observed;
    _json = null;
    _state = CaptureLegState.failed;
    addLog('FAILED: $reason');
  }

  /// Result payload for `ext.sleuthDemo.captureResult`. With [consume] a
  /// finished leg (done or failed) is cleared back to idle after the read
  /// so its stash (up to a few MB of JSON) is released.
  Map<String, Object?> result({bool consume = false}) {
    final payload = <String, Object?>{
      'state': _state.name,
      'leg': _leg,
      'observed': _observed,
      'attempts': _attempts,
      if (_json != null) 'json': _json,
      'log': List<String>.of(_log),
    };
    if (consume &&
        (_state == CaptureLegState.done || _state == CaptureLegState.failed)) {
      _state = CaptureLegState.idle;
      _leg = null;
      _observed = null;
      _json = null;
      _attempts = 0;
      _log.clear();
      notifyListeners();
    }
    return payload;
  }

  /// Restores the initial state. Tests only.
  @visibleForTesting
  void resetForTest() {
    _runners.clear();
    _state = CaptureLegState.idle;
    _leg = null;
    _observed = null;
    _json = null;
    _attempts = 0;
    _log.clear();
  }
}

/// `expectedMagnitude` band for a time-share capture leg against the
/// tier threshold [threshold] (the warning threshold for the warning
/// tier, 3× it for the critical tier):
///
/// - warning below `[0.5, t)`, critical below `[0.65 t, t)`
/// - at `[t, 1.5 t]`
/// - above `(1.5 t, 2.7 t]`
///
/// The schema rejects a band or an observed value at or below zero, so
/// every lower bound is positive. Exclusive bounds are enforced by the
/// audit's role-band check, not by these numbers.
({double min, double max}) timeShareBand({
  required String tier,
  required String role,
  required double threshold,
}) {
  assert(threshold > 0, 'threshold must be > 0');
  switch (role) {
    case 'below':
      final min = tier == 'critical' ? 0.65 * threshold : 0.5;
      return (min: min < threshold ? min : threshold / 2, max: threshold);
    case 'at':
      return (min: threshold, max: 1.5 * threshold);
    case 'above':
      return (min: 1.5 * threshold, max: 2.7 * threshold);
  }
  throw ArgumentError.value(role, 'role', 'expected below, at or above');
}

/// Fixed inputs of one time-share capture leg.
class TimeShareLeg {
  const TimeShareLeg({
    required this.detector,
    required this.stableId,
    required this.tier,
    required this.role,
    required this.scenario,
    required this.tierThreshold,
    required this.targetPercent,
    required this.knobName,
    required this.calibrationKnob,
    required this.minKnob,
    required this.maxKnob,
    required this.workloadDuration,
  });

  /// `rebuild` or `repaint`.
  final String detector;

  /// Bracketed stable id (`rebuild_activity`, `excessive_repaint`).
  final String stableId;

  /// `warning` or `critical`.
  final String tier;

  /// `below`, `at` or `above`.
  final String role;

  /// Scenario name; must equal the capture file's basename-derived name.
  final String scenario;

  /// Threshold of [tier] in percent.
  final double tierThreshold;

  /// Share of UI-thread time the leg aims for, in percent.
  final double targetPercent;

  /// Name of the workload knob in log lines (`work`, `ops`).
  final String knobName;

  /// Knob value the calibration pre-pass runs at.
  final int calibrationKnob;

  /// Smallest knob value the workload supports.
  final int minKnob;

  /// Largest knob value the workload supports.
  final int maxKnob;

  /// Length of the measured workload.
  final Duration workloadDuration;
}

/// Calibration pre-pass length.
const Duration kCalibrationPrePass = Duration(seconds: 3);

/// Idle dwell between the pre-pass and `markScenarioBegin`, long enough
/// for the 1 s idle timeline heartbeat to close an empty window.
const Duration kBoundaryDwell = Duration(milliseconds: 1500);

/// Attempts a leg may take (the first run plus rescaled retries).
const int kMaxLegAttempts = 5;

/// Dwell after `markScenarioEnd` before the trace is exported.
const Duration kPostScenarioEndDwell = Duration(milliseconds: 800);

/// Reference device and toolchain the time-share captures are recorded on.
const String kCaptureDevice = 'iPhone 12';
const String kCaptureDeviceOs = 'iOS 17.5';
const String kCaptureFlutterVersion = '3.47.6';
const String kCaptureCommand =
    'fvm flutter run --profile --no-dds -d "iPhone 12" '
    '--dart-define=SLEUTH_CAPTURE_MODE=true';

/// Scales [calibrationKnob] so a workload that measured [measured] percent
/// at that knob lands on [target] percent. Returns null when the
/// measurement is unusable (≤ 0) or the result falls outside
/// `[minKnob, maxKnob]` (the clamp would bind and the leg would miss its
/// target).
int? scaleKnob({
  required int calibrationKnob,
  required double measured,
  required double target,
  required int minKnob,
  required int maxKnob,
}) {
  if (measured <= 0 || !measured.isFinite) return null;
  final knob = (calibrationKnob * target / measured).round();
  if (knob < minKnob || knob > maxKnob) return null;
  return knob;
}

/// Knob for a rescaled retry of a leg whose peak [observed] missed its
/// band at [knob]: [knob] scaled by [target] / [observed], rounded and
/// clamped to `[minKnob, maxKnob]`. Returns null when [observed] is not a
/// usable measurement (≤ 0).
int? retryKnob({
  required int knob,
  required double observed,
  required double target,
  required int minKnob,
  required int maxKnob,
}) {
  if (observed <= 0 || !observed.isFinite) return null;
  return (knob * target / observed).round().clamp(minKnob, maxKnob);
}

/// Runs one time-share capture leg end to end and publishes the result
/// through [CaptureDriver.instance]. The caller has already called
/// [CaptureDriver.begin].
///
/// Sequence: calibration pre-pass → `flushTimelineNow` → read the last
/// window → scale the knob → measured span (stop → `flushTimelineNow` →
/// reset the detector → idle dwell → `markScenarioBegin` → workload →
/// `flushTimelineNow` → read the peak → `markScenarioEnd` → dwell) →
/// `exportCaptureJson`. The stop/flush/reset/dwell boundary keeps
/// pre-pass work out of every in-span window. A peak outside the band
/// gets further measured spans at knobs rescaled by [retryKnob]; the
/// export reads the latest span of the scenario.
Future<void> runTimeShareLeg({
  required TimeShareLeg leg,
  required void Function(int knob) startWorkload,
  required void Function() stopWorkload,
  required double Function() readPeak,
  required void Function() resetDetector,
  required bool Function() isActive,
}) async {
  final driver = CaptureDriver.instance;
  final label = '${leg.tier}/${leg.role}';
  final knob = leg.knobName;
  var streamsSuspended = false;
  var scenarioOpen = false;
  try {
    await Sleuth.suspendNonEssentialTimelineStreams();
    streamsSuspended = true;

    // Calibration pre-pass.
    resetDetector();
    startWorkload(leg.calibrationKnob);
    driver.addLog(
      '[$label] calibration pre-pass at $knob ${leg.calibrationKnob} '
      '(${kCalibrationPrePass.inSeconds} s)',
    );
    await Future<void>.delayed(kCalibrationPrePass);
    if (!isActive()) return driver.fail('screen closed during pre-pass');
    await Sleuth.flushTimelineNow(timeout: const Duration(seconds: 2));
    // The peak over the pre-pass is the best full window of steady
    // workload; the last closed window can be one that mostly covered
    // the ramp or a poll stall.
    final measured = readPeak();
    final scaled = scaleKnob(
      calibrationKnob: leg.calibrationKnob,
      measured: measured,
      target: leg.targetPercent,
      minKnob: leg.minKnob,
      maxKnob: leg.maxKnob,
    );
    stopWorkload();
    if (scaled == null) {
      return driver.fail(
        measured <= 0
            ? 'pre-pass measured 0 % (is the VM connected and the '
                  'detector enabled?)'
            : '$knob for ${leg.targetPercent.toStringAsFixed(1)} % falls '
                  'outside [${leg.minKnob}, ${leg.maxKnob}] '
                  '(pre-pass ${measured.toStringAsFixed(2)} % at '
                  '${leg.calibrationKnob})',
      );
    }
    driver.addLog(
      '[$label] pre-pass ${measured.toStringAsFixed(2)} % → $knob $scaled '
      'for target ${leg.targetPercent.toStringAsFixed(1)} %',
    );

    final band = timeShareBand(
      tier: leg.tier,
      role: leg.role,
      threshold: leg.tierThreshold,
    );
    final bandText =
        '${band.min.toStringAsFixed(1)}–${band.max.toStringAsFixed(1)}';
    // Edges follow the audit: below stops short of the threshold, at is
    // closed on both ends, above starts past the at-band upper edge.
    bool inBand(double v) => switch (leg.role) {
      'below' => v >= band.min && v < band.max,
      'above' => v > band.min && v <= band.max,
      _ => v >= band.min && v <= band.max,
    };

    // One measured span at knob [value]. Returns the detector peak rounded to
    // one decimal (the precision the emission arg carries), or null when
    // the screen closed before the scenario.
    Future<double?> measure(int value) async {
      // Clean boundary between earlier work and the measured span.
      stopWorkload();
      await Sleuth.flushTimelineNow(timeout: const Duration(seconds: 2));
      resetDetector();
      await Future<void>.delayed(kBoundaryDwell);
      if (!isActive()) return null;

      Sleuth.markScenarioBegin(leg.scenario);
      scenarioOpen = true;
      driver.recordAttempt();
      startWorkload(value);
      await Future<void>.delayed(leg.workloadDuration);
      stopWorkload();
      await Sleuth.flushTimelineNow(timeout: const Duration(seconds: 2));
      final peak = double.parse(readPeak().toStringAsFixed(1));
      Sleuth.markScenarioEnd(leg.scenario);
      scenarioOpen = false;
      await Future<void>.delayed(kPostScenarioEndDwell);
      driver.addLog(
        '[$label] attempt ${driver.attempts} at $knob $value: observed peak '
        '$peak % (band $bandText)',
      );
      return peak;
    }

    var current = scaled;
    var observed = await measure(current);
    if (observed == null) return driver.fail('screen closed before scenario');
    // The share does not scale linearly with the knob once builds or
    // paints approach the frame budget, so rescale by target / observed
    // up to kMaxLegAttempts times; the share is concave in the knob, so each
    // step closes only part of the gap.
    while (!inBand(observed!) && driver.attempts < kMaxLegAttempts) {
      final retry = retryKnob(
        knob: current,
        observed: observed,
        target: leg.targetPercent,
        minKnob: leg.minKnob,
        maxKnob: leg.maxKnob,
      );
      if (retry == null) {
        return driver.fail(
          'observed peak is 0 % at $knob $current',
          observed: observed,
        );
      }
      if (retry == current) {
        return driver.fail(
          'observed $observed % outside the $label band and the $knob '
          'clamp binds at $current',
          observed: observed,
        );
      }
      driver.addLog('[$label] outside the band, retrying at $knob $retry');
      current = retry;
      observed = await measure(current);
      if (observed == null) {
        return driver.fail('screen closed before the retry scenario');
      }
    }
    await Sleuth.resumeAllTimelineStreams();
    streamsSuspended = false;

    if (observed <= 0) {
      return driver.fail('observed peak is 0 %', observed: observed);
    }
    if (!inBand(observed)) {
      return driver.fail(
        'observed $observed % outside the $label band after '
        '${driver.attempts} attempts',
        observed: observed,
      );
    }
    final json = await Sleuth.exportCaptureJson(
      scenario: leg.scenario,
      role: leg.role,
      magnitudeMin: band.min,
      magnitudeObserved: observed,
      magnitudeMax: band.max,
      unit: 'percent',
      device: kCaptureDevice,
      deviceOsVersion: kCaptureDeviceOs,
      flutterVersion: kCaptureFlutterVersion,
      captureCommand: kCaptureCommand,
      // Detector-measured magnitude; no timeline event to derive it from.
      magnitudeSourceEventName: '',
      bracketStableId: leg.stableId,
      bracketSeverityLabel: leg.tier,
    );
    if (json == null) {
      return driver.fail(
        'export refused: ${Sleuth.lastCaptureExportFailure ?? 'no reason'}',
        observed: observed,
      );
    }
    driver.addLog('[$label] export OK (${json.length} chars)');
    driver.complete(observed: observed, json: json);
  } catch (e) {
    driver.fail('$e');
  } finally {
    stopWorkload();
    if (scenarioOpen) endScenarioInCleanup(leg.scenario, label);
    if (streamsSuspended) unawaited(Sleuth.resumeAllTimelineStreams());
  }
}

/// Closes [scenario] from a leg's cleanup path. A throw is logged under
/// [label] and swallowed, so it cannot replace the leg's own outcome or
/// skip the rest of the cleanup.
@visibleForTesting
void endScenarioInCleanup(
  String scenario,
  String label, {
  void Function(String scenario) markEnd = Sleuth.markScenarioEnd,
}) {
  try {
    markEnd(scenario);
  } catch (e) {
    CaptureDriver.instance.addLog('[$label] markScenarioEnd on cleanup: $e');
  }
}

/// Banner shown on a capture screen while capture mode is off or the VM
/// service is not connected; legs started in that state fail.
class CapturePreflightBanner extends StatelessWidget {
  const CapturePreflightBanner({
    super.key,
    required this.captureMode,
    required this.vmConnected,
  });

  final bool captureMode;
  final bool vmConnected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      color: scheme.errorContainer,
      child: Text(
        !captureMode
            ? 'Capture mode is off. Relaunch with '
                  '--dart-define=SLEUTH_CAPTURE_MODE=true.'
            : 'VM service not connected. Run a profile build with '
                  '--no-dds so Sleuth can attach.',
        style: TextStyle(color: scheme.onErrorContainer, fontSize: 12),
      ),
    );
  }
}

/// Leg buttons, copy button, state line and log shared by the
/// time-share capture screens. Rebuilds from [CaptureDriver.instance].
class CaptureLegPanel extends StatelessWidget {
  const CaptureLegPanel({
    super.key,
    required this.tier,
    required this.tiers,
    required this.onTierChanged,
    required this.onRunLeg,
  });

  /// Selected tier.
  final String tier;

  /// Tiers the screen offers.
  final List<String> tiers;

  final ValueChanged<String> onTierChanged;
  final ValueChanged<String> onRunLeg;

  Future<void> _copyJson() async {
    final json = CaptureDriver.instance.json;
    if (json == null) return;
    await Clipboard.setData(ClipboardData(text: json));
    CaptureDriver.instance.addLog('copied ${json.length} chars to clipboard');
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: CaptureDriver.instance,
      builder: (context, _) {
        final driver = CaptureDriver.instance;
        final busy = driver.isBusy;
        final lines = driver.log;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (tiers.length > 1)
              SegmentedButton<String>(
                segments: [
                  for (final t in tiers)
                    ButtonSegment(value: t, label: Text(t)),
                ],
                selected: {tier},
                onSelectionChanged: busy
                    ? null
                    : (selection) => onTierChanged(selection.first),
              ),
            for (final role in const ['below', 'at', 'above'])
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: ElevatedButton(
                  onPressed: busy ? null : () => onRunLeg(role),
                  child: Text('Run $tier/$role'),
                ),
              ),
            ElevatedButton.icon(
              icon: const Icon(Icons.content_copy),
              label: const Text('Copy last capture'),
              onPressed: busy || driver.json == null ? null : _copyJson,
            ),
            const SizedBox(height: 4),
            Text(
              'State: ${driver.state.name}'
              '${driver.leg == null ? '' : ' (${driver.leg})'}'
              '${driver.observed == null ? '' : ' — ${driver.observed} %'}',
              style: const TextStyle(fontFamily: 'monospace'),
            ),
            const Divider(),
            SizedBox(
              height: 160,
              child: ListView.builder(
                itemCount: lines.length,
                itemBuilder: (_, i) => Text(
                  lines[lines.length - 1 - i],
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
