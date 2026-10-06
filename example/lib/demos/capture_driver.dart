// Shared state and leg sequence for the time-share capture screens
// (`RebuildActivityCaptureScreen`, `RepaintCaptureScreen`), and the
// provenance every capture screen stamps on its exports.
//
// The screens register with [CaptureDriver.instance] while mounted and
// publish each leg's progress, observed magnitude and wrapped capture
// JSON through it, so the `ext.sleuthDemo.captureLeg` / `captureResult`
// service extensions in `main.dart` drive and read legs without reaching
// into `State` objects.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sleuth/sleuth.dart';

/// Lifecycle of the most recent capture leg.
enum CaptureLegState { idle, running, done, failed }

/// Starts one leg of a registered capture screen. [tier] is `warning` or
/// `critical`, [role] is `below`, `at` or `above`.
typedef CaptureLegRunner = Future<void> Function(String tier, String role);

/// A mounted capture screen as the driver sees it.
class CaptureScreenHandle {
  CaptureScreenHandle({
    required this.runner,
    required this.route,
    required this.inFront,
  });

  /// Runs one leg on the screen.
  final CaptureLegRunner runner;

  /// The route the screen sits on, if any.
  final ModalRoute<Object?>? Function() route;

  /// Whether the screen is mounted, on the current route and has its
  /// tickers enabled, so a workload it starts actually runs.
  final bool Function() inFront;
}

/// Process-wide capture-leg state shared by the capture screens and the
/// demo service extensions. Notifies listeners on every state or log
/// change.
class CaptureDriver extends ChangeNotifier {
  CaptureDriver._();

  /// The single driver instance.
  static final CaptureDriver instance = CaptureDriver._();

  final Map<String, CaptureScreenHandle> _screens = {};

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
  /// the first, one more per retry).
  int get attempts => _attempts;

  /// Log lines of the current or last leg, oldest first.
  List<String> get log => List.unmodifiable(_log);

  /// Registers the mounted capture [screen] for [detector] (`rebuild` or
  /// `repaint`). The latest registration wins.
  void register(String detector, CaptureScreenHandle screen) {
    _screens[detector] = screen;
  }

  /// Removes [screen] for [detector] if it is still the registered one.
  void unregister(String detector, CaptureScreenHandle screen) {
    if (identical(_screens[detector], screen)) _screens.remove(detector);
  }

  /// The capture screen registered for [detector], if one is mounted. It
  /// may be covered by another route; check [CaptureScreenHandle.inFront].
  CaptureScreenHandle? screenFor(String detector) => _screens[detector];

  /// The leg runner of the screen registered for [detector].
  CaptureLegRunner? runnerFor(String detector) => _screens[detector]?.runner;

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

  /// Runs [runner] for a leg [begin] has started. A throw from the
  /// runner, including one before its own error handling, and a runner
  /// that returns without a result both end the leg as failed, so the
  /// driver never stays busy.
  Future<void> runLeg(CaptureLegRunner runner, String tier, String role) async {
    try {
      await runner(tier, role);
    } catch (e) {
      if (isBusy) fail('$e');
      return;
    }
    if (isBusy) fail('leg ended without a result');
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
    _screens.clear();
    _state = CaptureLegState.idle;
    _leg = null;
    _observed = null;
    _json = null;
    _attempts = 0;
    _log.clear();
  }
}

/// Whether a capture screen on [route] runs a workload it starts: its
/// tickers are enabled and its route (if it has one) is the current one.
/// A route covered by another keeps its `State` while the overlay mutes
/// its tickers, so a workload started there would not run.
bool isCaptureScreenInFront({
  required Route<Object?>? route,
  required bool tickersEnabled,
}) => tickersEnabled && (route?.isCurrent ?? true);

/// Registers a time-share capture screen with [CaptureDriver.instance]
/// while it is mounted, and reports whether it is in front.
mixin CaptureScreenStateMixin<T extends StatefulWidget> on State<T> {
  /// Driver key of the screen (`rebuild`, `repaint`).
  String get captureDetector;

  /// Runs one leg on this screen.
  Future<void> runCaptureLeg(String tier, String role);

  ModalRoute<Object?>? _captureRoute;

  late final CaptureScreenHandle _captureHandle = CaptureScreenHandle(
    runner: runCaptureLeg,
    route: () => mounted ? _captureRoute : null,
    inFront: () => captureInFront,
  );

  /// True while the screen is mounted, on the current route and has its
  /// tickers enabled.
  bool get captureInFront =>
      mounted &&
      isCaptureScreenInFront(
        route: _captureRoute,
        tickersEnabled: TickerMode.getValuesNotifier(context).value.enabled,
      );

  @override
  void initState() {
    super.initState();
    CaptureDriver.instance.register(captureDetector, _captureHandle);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _captureRoute = ModalRoute.of(context);
  }

  @override
  void dispose() {
    CaptureDriver.instance.unregister(captureDetector, _captureHandle);
    super.dispose();
  }
}

/// Brings the capture screen registered for [detector] to the front of
/// [navigator] for `ext.sleuthDemo.captureLeg`. A screen already in
/// front is returned at once. A covered one has the routes above it
/// popped; with none registered (or one outside [navigator])
/// [pushScreen] pushes a fresh screen. Waits up to [timeout] for the
/// screen to be in front. Returns the screen, or an error: `no_navigator`,
/// `screen_not_ready` (nothing registered in time) or `not_in_front` (a
/// screen is registered but its route is not current or its tickers stay
/// muted).
Future<({CaptureScreenHandle? screen, String? error})>
bringCaptureScreenToFront({
  required String detector,
  required NavigatorState? navigator,
  required VoidCallback? pushScreen,
  Duration timeout = const Duration(seconds: 3),
  Duration pollInterval = const Duration(milliseconds: 50),
}) async {
  final driver = CaptureDriver.instance;
  final existing = driver.screenFor(detector);
  if (existing != null && existing.inFront()) {
    return (screen: existing, error: null);
  }
  if (navigator == null || pushScreen == null) {
    return (screen: null, error: 'no_navigator');
  }
  final route = existing?.route();
  if (route != null && route.isActive && route.navigator == navigator) {
    navigator.popUntil((r) => r == route);
  } else {
    pushScreen();
  }
  for (var waited = Duration.zero; ; waited += pollInterval) {
    final screen = driver.screenFor(detector);
    if (screen != null && screen.inFront()) {
      return (screen: screen, error: null);
    }
    if (waited >= timeout) {
      return (
        screen: null,
        error: screen == null ? 'screen_not_ready' : 'not_in_front',
      );
    }
    await Future<void>.delayed(pollInterval);
  }
}

// ── Provenance ──

/// `--dart-define` naming the device model a capture is recorded on. The
/// example has no device-info plugin, so the operator supplies it.
const String kCaptureDeviceDefine = 'SLEUTH_CAPTURE_DEVICE';

const String _definedCaptureDevice = String.fromEnvironment(
  kCaptureDeviceDefine,
);

/// Where a capture was recorded, stamped into its `sleuthMetadata`.
@immutable
class CaptureProvenance {
  const CaptureProvenance({
    required this.device,
    required this.deviceOsVersion,
    required this.flutterVersion,
  });

  /// Device model, e.g. `iPhone 12`.
  final String device;

  /// OS in the schema's form, e.g. `iOS 17.5`.
  final String deviceOsVersion;

  /// Flutter version the app was built with, e.g. `3.47.6`.
  final String flutterVersion;

  /// The launch command recorded as `captureCommand`.
  String get captureCommand =>
      'fvm flutter run --profile --no-dds -d "$device" '
      '--dart-define=SLEUTH_CAPTURE_MODE=true '
      '--dart-define=$kCaptureDeviceDefine="$device"';
}

/// This build's capture provenance, or why it cannot stamp one.
typedef CaptureProvenanceCheck = ({
  CaptureProvenance? provenance,
  String? problem,
});

/// `deviceOsVersion` in the schema's form from `dart:io`'s
/// [operatingSystem] and [operatingSystemVersion]. iOS reports
/// `Version 17.5 (Build 21F79)`, which becomes `iOS 17.5`. Returns null on
/// another platform or when the string carries no version.
String? captureOsVersion({
  required String operatingSystem,
  required String operatingSystemVersion,
}) {
  if (operatingSystem != 'ios') return null;
  final version = RegExp(r'\d+(?:\.\d+)+').firstMatch(operatingSystemVersion);
  return version == null ? null : 'iOS ${version[0]}';
}

/// `<major>.<minor>.<patch>` with an optional pre-release or build
/// suffix, as the capture schema reads `flutterVersion`.
final RegExp _flutterVersionPattern = RegExp(
  r'^(\d+\.\d+)\.\d+(?:[-+][0-9A-Za-z.\-]+)?$',
);

/// Checks [device], the OS and [flutterVersion] against what
/// [ProfileCaptureSchema] approves (`approvedDevicePairs`,
/// `approvedFlutterMajorMinors`). Returns the provenance when every value
/// is known and approved, else every problem found.
CaptureProvenanceCheck checkCaptureProvenance({
  required String? device,
  required String operatingSystem,
  required String operatingSystemVersion,
  required String? flutterVersion,
}) {
  String list(Iterable<String> values) => (values.toList()..sort()).join(', ');
  final pairs = ProfileCaptureSchema.approvedDevicePairs;
  final problems = <String>[];

  final model = device?.trim() ?? '';
  Set<String>? approvedOs;
  if (model.isEmpty) {
    problems.add(
      'device model unknown: relaunch with '
      '--dart-define=$kCaptureDeviceDefine=<model> '
      '(approved: ${list(pairs.keys)})',
    );
  } else {
    approvedOs = pairs[model];
    if (approvedOs == null) {
      problems.add(
        'device "$model" is not an approved reference device '
        '(approved: ${list(pairs.keys)})',
      );
    }
  }

  final os = captureOsVersion(
    operatingSystem: operatingSystem,
    operatingSystemVersion: operatingSystemVersion,
  );
  if (os == null) {
    problems.add(
      'OS version unknown: none readable from $operatingSystem '
      '"$operatingSystemVersion"',
    );
  } else if (approvedOs != null && !approvedOs.contains(os)) {
    problems.add(
      '$os is not approved for "$model" (approved: ${list(approvedOs)})',
    );
  }

  final sdk = flutterVersion?.trim() ?? '';
  final majorMinor = _flutterVersionPattern.firstMatch(sdk)?[1];
  final approvedSdks = ProfileCaptureSchema.approvedFlutterMajorMinors.map(
    (v) => '$v.x',
  );
  if (sdk.isEmpty) {
    problems.add(
      'Flutter version unknown (FlutterVersion.version is not set; build '
      'with the flutter tool)',
    );
  } else if (majorMinor == null ||
      !ProfileCaptureSchema.approvedFlutterMajorMinors.contains(majorMinor)) {
    problems.add(
      'Flutter $sdk is not an approved capture SDK '
      '(approved: ${list(approvedSdks)})',
    );
  }

  if (problems.isNotEmpty) {
    return (provenance: null, problem: problems.join('; '));
  }
  return (
    provenance: CaptureProvenance(
      device: model,
      deviceOsVersion: os!,
      flutterVersion: sdk,
    ),
    problem: null,
  );
}

/// Provenance of this build on this device: the model from
/// `--dart-define=SLEUTH_CAPTURE_DEVICE`, the OS from
/// `Platform.operatingSystemVersion` and the SDK from
/// [FlutterVersion.version].
CaptureProvenanceCheck currentCaptureProvenance() => checkCaptureProvenance(
  device: _definedCaptureDevice,
  operatingSystem: kIsWeb ? 'web' : Platform.operatingSystem,
  operatingSystemVersion: kIsWeb ? '' : Platform.operatingSystemVersion,
  flutterVersion: FlutterVersion.version,
);

// ── Bracket and bands ──

/// The bracket a capture leg records evidence for, read from the
/// detector's [DetectorMetadata] with the capture audit's defaults filled
/// in.
@immutable
class CaptureBracket {
  const CaptureBracket({
    required this.stableId,
    required this.severityLabel,
    required this.threshold,
    required this.atTolerance,
    required this.aboveCeilingMultiplier,
    required this.argKey,
    this.reduction = 'max',
    this.observedAxisTolerance = 0.25,
    this.minInBandSamples,
  });

  /// The bracket on [metadata] for [stableId] at [severityLabel]: the
  /// canonical bracket or an `additionalBrackets` entry with an observed
  /// axis. Null when the detector declares none.
  static CaptureBracket? fromMetadata(
    DetectorMetadata metadata, {
    required String stableId,
    required String severityLabel,
  }) {
    final threshold = metadata.bracketThreshold;
    final argKey = metadata.observedAxisArgKey;
    if (metadata.bracketStableId == stableId &&
        metadata.bracketSeverityLabel == severityLabel &&
        threshold != null &&
        argKey != null) {
      return CaptureBracket(
        stableId: stableId,
        severityLabel: severityLabel,
        threshold: threshold.toDouble(),
        atTolerance:
            metadata.bracketAtTolerance ??
            ProfileCaptureSchema.defaultAtTolerance,
        aboveCeilingMultiplier:
            metadata.aboveCeilingMultiplier ??
            ProfileCaptureSchema.defaultAboveCeilingMultiplier,
        argKey: argKey,
        reduction: metadata.observedAxisReduction,
        observedAxisTolerance: metadata.observedAxisTolerance,
      );
    }
    for (final spec in metadata.additionalBrackets ?? const <BracketSpec>[]) {
      final specArgKey = spec.observedAxisArgKey;
      if (spec.stableId != stableId ||
          spec.severityLabel != severityLabel ||
          specArgKey == null) {
        continue;
      }
      return CaptureBracket(
        stableId: stableId,
        severityLabel: severityLabel,
        threshold: spec.threshold.toDouble(),
        atTolerance:
            spec.atTolerance ?? ProfileCaptureSchema.defaultAtTolerance,
        aboveCeilingMultiplier:
            spec.aboveCeilingMultiplier ??
            ProfileCaptureSchema.defaultAboveCeilingMultiplier,
        argKey: specArgKey,
        reduction: spec.observedAxisReduction,
        observedAxisTolerance: spec.observedAxisTolerance,
        minInBandSamples: spec.minInBandSamples,
      );
    }
    return null;
  }

  /// Bracketed stable id.
  final String stableId;

  /// `warning` or `critical`.
  final String severityLabel;

  /// Bracket threshold.
  final double threshold;

  /// At band upper edge as a fraction above [threshold].
  final double atTolerance;

  /// Above band ceiling as a multiple of [threshold].
  final double aboveCeilingMultiplier;

  /// Trace arg carrying the detector's observed value.
  final String argKey;

  /// `max` or `last`: how the audit reduces several in-span records.
  final String reduction;

  /// Largest relative gap the audit allows between a capture's observed
  /// magnitude and the reduced detector value.
  final double observedAxisTolerance;

  /// In-band records each at and above leg must carry, when set.
  final int? minInBandSamples;

  /// `sleuth.issue.<stableId>.<severityLabel>`.
  String get eventName => 'sleuth.issue.$stableId.$severityLabel';

  /// At band upper edge, `threshold × (1 + atTolerance)`.
  double get atUpper => threshold * (1 + atTolerance);

  /// Above band ceiling, `threshold × aboveCeilingMultiplier`.
  double get aboveCeiling => threshold * aboveCeilingMultiplier;

  /// In-band records an at or above leg needs: [minInBandSamples], and
  /// at least one.
  int get requiredInBand => math.max(1, minInBandSamples ?? 1);

  /// Whether a detector [value] lies in [role]'s band as the capture
  /// audit draws it: at `[threshold, atUpper]`, above
  /// `(atUpper, aboveCeiling]`. Below has no detector band.
  bool inRoleBand(num value, String role) => switch (role) {
    'at' => value >= threshold && value <= atUpper,
    'above' => value > atUpper && value <= aboveCeiling,
    _ => false,
  };
}

/// `expectedMagnitude` band for a time-share capture leg against the
/// tier threshold [threshold] (the warning threshold for the warning
/// tier, 3× it for the critical tier):
///
/// - warning below `[0.5, t)`, critical below `[0.65 t, t)`
/// - at `[t, t × (1 + atTolerance)]`
/// - above `(t × (1 + atTolerance), t × aboveCeilingMultiplier]`
///
/// The defaults (0.5, 2.7) are the time-share brackets' values. The
/// schema rejects a band or an observed value at or below zero, so every
/// lower bound is positive. Exclusive bounds are enforced by [inLegBand]
/// and the audit's role-band check, not by these numbers.
({double min, double max}) timeShareBand({
  required String tier,
  required String role,
  required double threshold,
  double atTolerance = 0.5,
  double aboveCeilingMultiplier = 2.7,
}) {
  assert(threshold > 0, 'threshold must be > 0');
  final atUpper = threshold * (1 + atTolerance);
  switch (role) {
    case 'below':
      final min = tier == 'critical' ? 0.65 * threshold : 0.5;
      return (min: min < threshold ? min : threshold / 2, max: threshold);
    case 'at':
      return (min: threshold, max: atUpper);
    case 'above':
      return (min: atUpper, max: threshold * aboveCeilingMultiplier);
  }
  throw ArgumentError.value(role, 'role', 'expected below, at or above');
}

/// Whether [value] lies in [role]'s [band] with the audit's edges: below
/// stops short of the threshold, at is closed on both ends, above starts
/// past the at band's upper edge.
bool inLegBand(double value, String role, ({double min, double max}) band) =>
    switch (role) {
      'below' => value >= band.min && value < band.max,
      'above' => value > band.min && value <= band.max,
      _ => value >= band.min && value <= band.max,
    };

/// [percent] rounded to one decimal, the precision the detectors' trace
/// args carry.
double roundPercent(double percent) => double.parse(percent.toStringAsFixed(1));

/// In-span detector records of an exported capture, read the way the
/// capture audit reads them.
@immutable
class CaptureRecordCount {
  const CaptureRecordCount({
    required this.inSpan,
    required this.stamped,
    required this.inBand,
    required this.reduced,
  });

  /// Records of the bracketed event inside the scenario span.
  final int inSpan;

  /// In-span records carrying a parseable observed value.
  final int stamped;

  /// Stamped records inside the leg's role band.
  final int inBand;

  /// The bracket's reduction (`max` or `last`) over the stamped records.
  final num? reduced;
}

/// Counts the in-span [CaptureBracket.eventName] records of the wrapped
/// capture [json] for a [role] leg. The span comes from
/// [ProfileCaptureSchema.findScenarioSpan]; values are read from the
/// record's args (or its `Dart Arguments`) under
/// [CaptureBracket.argKey]. Throws [FormatException] when the JSON or its
/// scenario markers are malformed.
CaptureRecordCount countCaptureRecords(
  String json, {
  required CaptureBracket bracket,
  required String role,
}) {
  final root = jsonDecode(json);
  final events = root is Map ? root['traceEvents'] : null;
  if (events is! List) {
    throw const FormatException('capture has no traceEvents array');
  }
  final (begin, end) = ProfileCaptureSchema.findScenarioSpan(
    events,
    'exported capture',
  );
  var inSpan = 0;
  var stamped = 0;
  var inBand = 0;
  num? reduced;
  num? reducedTs;
  for (final event in events) {
    if (event is! Map || event['name'] != bracket.eventName) continue;
    final ts = event['ts'];
    if (ts is! num || ts < begin || ts > end) continue;
    inSpan++;
    final args = event['args'];
    if (args is! Map) continue;
    var raw = args[bracket.argKey];
    final dartArgs = args['Dart Arguments'];
    if (raw == null && dartArgs is Map) raw = dartArgs[bracket.argKey];
    final value = switch (raw) {
      final num n => n,
      final String s => num.tryParse(s.trim()),
      _ => null,
    };
    if (value == null) continue;
    stamped++;
    if (bracket.inRoleBand(value, role)) inBand++;
    final take = bracket.reduction == 'last'
        // Latest record; a tie goes to the later one in file order.
        ? reducedTs == null || ts >= reducedTs
        : reduced == null || value > reduced;
    if (take) {
      reduced = value;
      reducedTs = ts;
    }
  }
  return CaptureRecordCount(
    inSpan: inSpan,
    stamped: stamped,
    inBand: inBand,
    reduced: reduced,
  );
}

// ── Leg sequence ──

/// Fixed inputs of one time-share capture leg.
class TimeShareLeg {
  const TimeShareLeg({
    required this.detector,
    required this.bracket,
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

  /// Bracket the leg records evidence for.
  final CaptureBracket bracket;

  /// `warning` or `critical`.
  final String tier;

  /// `below`, `at` or `above`.
  final String role;

  /// Scenario name; must equal the capture file's basename-derived name.
  final String scenario;

  /// Live threshold of [tier] in percent; must equal the bracket's.
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

  /// `<tier>/<role>`, the prefix of the leg's log lines.
  String get label => '$tier/$role';
}

/// Calibration pre-pass length.
const Duration kCalibrationPrePass = Duration(seconds: 3);

/// Idle dwell between the pre-pass and `markScenarioBegin`, long enough
/// for the 1 s idle timeline heartbeat to close an empty window.
const Duration kBoundaryDwell = Duration(milliseconds: 1500);

/// Measured spans a leg may run (the first plus retries).
const int kMaxLegAttempts = 5;

/// Dwell after `markScenarioEnd` before the trace is exported.
const Duration kPostScenarioEndDwell = Duration(milliseconds: 800);

/// How often a leg checks that its screen is still in front while it
/// waits.
const Duration kFrontCheckInterval = Duration(milliseconds: 100);

/// Longest wait for a Sleuth call that talks to the VM service
/// (stream flags, the capture export) before the leg fails.
const Duration kVmCallTimeout = Duration(seconds: 10);

/// A Sleuth call of a capture leg that did not finish in time.
class CaptureCallTimeout implements Exception {
  const CaptureCallTimeout(this.call, this.timeout);

  /// Name of the call.
  final String call;

  /// The limit it ran past.
  final Duration timeout;

  @override
  String toString() =>
      '$call timed out after ${timeout.inMilliseconds / 1000} s';
}

/// [future] limited to [timeout]; past it, throws [CaptureCallTimeout]
/// naming [call].
Future<T> withCallTimeout<T>(
  Future<T> future,
  String call, {
  Duration timeout = kVmCallTimeout,
}) => future.timeout(
  timeout,
  onTimeout: () => throw CaptureCallTimeout(call, timeout),
);

/// The capture screen was not in front while a leg needed its workload.
class CaptureScreenLeftFront implements Exception {
  const CaptureScreenLeftFront(this.when);

  /// Phase of the leg, e.g. `during the scenario`.
  final String when;

  @override
  String toString() =>
      'capture screen not in front $when; a covered screen does not run '
      'its workload';
}

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

/// What a leg does after a measured span or its export.
sealed class LegDecision {
  const LegDecision();
}

/// The peak is in its band: export the span.
final class LegExport extends LegDecision {
  const LegExport();
}

/// The export satisfies the bracket: the leg is done.
final class LegComplete extends LegDecision {
  const LegComplete();
}

/// Run another measured span at [knob].
final class LegRetry extends LegDecision {
  const LegRetry(this.knob, this.reason);

  final int knob;

  /// What the last span missed.
  final String reason;
}

/// The leg fails with [reason].
final class LegFail extends LegDecision {
  const LegFail(this.reason);

  final String reason;
}

/// Decision after a measured span of [leg] at [knob] whose detector peak,
/// rounded to one decimal, is [observed]; [attempts] spans have run.
/// In band → export. Out of band → a retry at the knob rescaled by
/// target / observed while attempts remain, else a failure.
LegDecision decideAfterPeak({
  required TimeShareLeg leg,
  required ({double min, double max}) band,
  required int knob,
  required double observed,
  required int attempts,
}) {
  if (inLegBand(observed, leg.role, band)) return const LegExport();
  if (attempts >= kMaxLegAttempts) {
    return LegFail(
      observed <= 0
          ? 'observed peak is 0 %'
          : 'observed $observed % outside the ${leg.label} band after '
                '$attempts attempts',
    );
  }
  final retry = retryKnob(
    knob: knob,
    observed: observed,
    target: leg.targetPercent,
    minKnob: leg.minKnob,
    maxKnob: leg.maxKnob,
  );
  if (retry == null) {
    return LegFail('observed peak is 0 % at ${leg.knobName} $knob');
  }
  if (retry == knob) {
    return LegFail(
      'observed $observed % outside the ${leg.label} band and the '
      '${leg.knobName} clamp binds at $knob',
    );
  }
  return LegRetry(retry, 'outside the band');
}

/// Decision after the export of an in-band span of [leg] at [knob]
/// (peak [observed], [attempts] spans run). A below leg is done: the
/// export already refuses one with an in-span record. An at or above leg
/// is done when its in-span [records] pass what the capture audit checks:
/// every record stamped, the reduced value in the role band and within
/// the observed-axis tolerance of [observed], and at least
/// [CaptureBracket.requiredInBand] records in the band. Otherwise it
/// retries while attempts remain (at the knob rescaled toward the target
/// when the peak fell short of it, else at the same knob), or fails.
LegDecision decideAfterExport({
  required TimeShareLeg leg,
  required int knob,
  required double observed,
  required int attempts,
  required CaptureRecordCount? records,
}) {
  if (leg.role == 'below') return const LegComplete();
  final bracket = leg.bracket;
  final event = bracket.eventName;
  if (records == null || records.inSpan == 0) {
    return _retryOrFail(leg, knob, observed, attempts, 'no in-span $event');
  }
  if (records.stamped < records.inSpan) {
    return LegFail(
      '${records.inSpan - records.stamped} of ${records.inSpan} in-span '
      '$event records carry no ${bracket.argKey}',
    );
  }
  final reduced = records.reduced!;
  final String? shortfall;
  if (!bracket.inRoleBand(reduced, leg.role)) {
    shortfall =
        'in-span ${bracket.reduction} ${bracket.argKey} $reduced lies '
        'outside the ${leg.role} band';
  } else if (reduced < observed * (1 - bracket.observedAxisTolerance) ||
      reduced > observed * (1 + bracket.observedAxisTolerance)) {
    shortfall =
        'in-span ${bracket.reduction} ${bracket.argKey} $reduced is more '
        'than ±${(bracket.observedAxisTolerance * 100).round()} % from the '
        'observed $observed %';
  } else if (records.inBand < bracket.requiredInBand) {
    shortfall =
        '${records.inBand} in-band $event record(s); the bracket requires '
        '${bracket.requiredInBand}';
  } else {
    shortfall = null;
  }
  if (shortfall == null) return const LegComplete();
  return _retryOrFail(leg, knob, observed, attempts, shortfall);
}

LegDecision _retryOrFail(
  TimeShareLeg leg,
  int knob,
  double observed,
  int attempts,
  String shortfall,
) {
  if (attempts >= kMaxLegAttempts) {
    return LegFail('$shortfall after $attempts attempts');
  }
  final next = observed < leg.targetPercent
      ? retryKnob(
              knob: knob,
              observed: observed,
              target: leg.targetPercent,
              minKnob: leg.minKnob,
              maxKnob: leg.maxKnob,
            ) ??
            knob
      : knob;
  return LegRetry(next, shortfall);
}

/// The Sleuth calls and waits a time-share leg makes. Tests pass a
/// subclass that scripts them.
class CaptureLegCalls {
  const CaptureLegCalls();

  Future<void> suspendStreams() => Sleuth.suspendNonEssentialTimelineStreams();

  Future<void> resumeStreams() => Sleuth.resumeAllTimelineStreams();

  Future<void> flushTimeline() =>
      Sleuth.flushTimelineNow(timeout: const Duration(seconds: 2));

  void markScenarioBegin(String scenario) => Sleuth.markScenarioBegin(scenario);

  void markScenarioEnd(String scenario) => Sleuth.markScenarioEnd(scenario);

  /// Exports the latest span of [leg]'s scenario with the observed peak
  /// [observed], its [band] and [provenance].
  Future<String?> exportCapture({
    required TimeShareLeg leg,
    required ({double min, double max}) band,
    required double observed,
    required CaptureProvenance provenance,
  }) => Sleuth.exportCaptureJson(
    scenario: leg.scenario,
    role: leg.role,
    magnitudeMin: band.min,
    magnitudeObserved: observed,
    magnitudeMax: band.max,
    unit: 'percent',
    device: provenance.device,
    deviceOsVersion: provenance.deviceOsVersion,
    flutterVersion: provenance.flutterVersion,
    captureCommand: provenance.captureCommand,
    // Detector-measured magnitude; no timeline event to derive it from.
    magnitudeSourceEventName: '',
    bracketStableId: leg.bracket.stableId,
    bracketSeverityLabel: leg.bracket.severityLabel,
  );

  /// Why the last export returned null.
  String? get lastExportFailure => Sleuth.lastCaptureExportFailure;

  Future<void> wait(Duration duration) => Future<void>.delayed(duration);
}

/// Waits [duration] through [calls] in steps of at most
/// [kFrontCheckInterval]. Returns false as soon as [isActive] reports
/// false.
Future<bool> holdInFront(
  Duration duration,
  bool Function() isActive, {
  CaptureLegCalls calls = const CaptureLegCalls(),
}) async {
  var left = duration;
  while (left > Duration.zero) {
    final step = left < kFrontCheckInterval ? left : kFrontCheckInterval;
    await calls.wait(step);
    left -= step;
    if (!isActive()) return false;
  }
  return isActive();
}

/// Runs one time-share capture leg end to end and publishes the result
/// through [CaptureDriver.instance]. The caller has already called
/// [CaptureDriver.begin].
///
/// Refuses to start when [provenance] reports a problem, when the live
/// tier threshold differs from the bracket's, or when the screen is not
/// in front ([isActive]).
///
/// Sequence: calibration pre-pass → `flushTimelineNow` → read the peak →
/// scale the knob → measured span (stop → `flushTimelineNow` → reset the
/// detector → idle dwell → `markScenarioBegin` → workload →
/// `flushTimelineNow` → read the peak → `markScenarioEnd` → dwell). The
/// stop/flush/reset/dwell boundary keeps pre-pass work out of every
/// in-span window. A peak outside the band gets another span at the knob
/// rescaled by [retryKnob] ([decideAfterPeak]); an in-band span is
/// exported (the export reads the latest span of the scenario) and its
/// in-span records checked against the bracket ([decideAfterExport]),
/// which can also ask for another span. At most [kMaxLegAttempts] spans
/// run. The screen must stay in front through the pre-pass, the dwell
/// and the workload; if it leaves, the leg fails and exports nothing.
///
/// Stream suspension, resumption and the export each fail the leg when
/// they take longer than [callTimeout].
Future<void> runTimeShareLeg({
  required TimeShareLeg leg,
  required void Function(int knob) startWorkload,
  required void Function() stopWorkload,
  required double Function() readPeak,
  required void Function() resetDetector,
  required bool Function() isActive,
  CaptureProvenanceCheck Function() provenance = currentCaptureProvenance,
  CaptureLegCalls calls = const CaptureLegCalls(),
  Duration callTimeout = kVmCallTimeout,
}) async {
  final driver = CaptureDriver.instance;
  final label = leg.label;
  final knob = leg.knobName;
  final source = provenance();
  final stamp = source.provenance;
  if (stamp == null) {
    return driver.fail('capture provenance: ${source.problem}');
  }
  if (leg.tierThreshold != leg.bracket.threshold) {
    return driver.fail(
      'live ${leg.tier} threshold ${leg.tierThreshold} % differs from the '
      '${leg.bracket.eventName} bracket threshold '
      '${leg.bracket.threshold} %',
    );
  }
  if (!isActive()) {
    return driver.fail(const CaptureScreenLeftFront('at the start').toString());
  }
  var streamsSuspended = false;
  var scenarioOpen = false;
  try {
    // Marked first: a suspend that times out may still land later.
    streamsSuspended = true;
    await withCallTimeout(
      calls.suspendStreams(),
      'suspendNonEssentialTimelineStreams',
      timeout: callTimeout,
    );

    // Calibration pre-pass.
    resetDetector();
    startWorkload(leg.calibrationKnob);
    driver.addLog(
      '[$label] calibration pre-pass at $knob ${leg.calibrationKnob} '
      '(${kCalibrationPrePass.inSeconds} s)',
    );
    if (!await holdInFront(kCalibrationPrePass, isActive, calls: calls)) {
      throw const CaptureScreenLeftFront('during the pre-pass');
    }
    await calls.flushTimeline();
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
      atTolerance: leg.bracket.atTolerance,
      aboveCeilingMultiplier: leg.bracket.aboveCeilingMultiplier,
    );
    final bandText =
        '${band.min.toStringAsFixed(1)}–${band.max.toStringAsFixed(1)}';

    // One measured span at knob [value]. Returns the detector peak
    // rounded to one decimal (the precision the emission arg carries).
    Future<double> measure(int value) async {
      // Clean boundary between earlier work and the measured span.
      stopWorkload();
      await calls.flushTimeline();
      resetDetector();
      if (!await holdInFront(kBoundaryDwell, isActive, calls: calls)) {
        throw const CaptureScreenLeftFront('before the scenario');
      }

      calls.markScenarioBegin(leg.scenario);
      scenarioOpen = true;
      driver.recordAttempt();
      startWorkload(value);
      final ranInFront = await holdInFront(
        leg.workloadDuration,
        isActive,
        calls: calls,
      );
      stopWorkload();
      // The open scenario is closed by the cleanup; nothing is exported.
      if (!ranInFront) {
        throw const CaptureScreenLeftFront('during the scenario');
      }
      await calls.flushTimeline();
      final peak = roundPercent(readPeak());
      calls.markScenarioEnd(leg.scenario);
      scenarioOpen = false;
      await calls.wait(kPostScenarioEndDwell);
      driver.addLog(
        '[$label] attempt ${driver.attempts} at $knob $value: observed peak '
        '$peak % (band $bandText)',
      );
      return peak;
    }

    // The share does not scale linearly with the knob once builds or
    // paints approach the frame budget, so a miss rescales by target /
    // observed; the share is concave in the knob, so each step closes
    // only part of the gap.
    var current = scaled;
    while (true) {
      final observed = await measure(current);
      final afterPeak = decideAfterPeak(
        leg: leg,
        band: band,
        knob: current,
        observed: observed,
        attempts: driver.attempts,
      );
      if (afterPeak is LegFail) {
        return driver.fail(afterPeak.reason, observed: observed);
      }
      if (afterPeak is LegRetry) {
        driver.addLog(
          '[$label] ${afterPeak.reason}, retrying at $knob ${afterPeak.knob}',
        );
        current = afterPeak.knob;
        continue;
      }

      final json = await withCallTimeout(
        calls.exportCapture(
          leg: leg,
          band: band,
          observed: observed,
          provenance: stamp,
        ),
        'exportCaptureJson',
        timeout: callTimeout,
      );
      if (json == null) {
        return driver.fail(
          'export refused: ${calls.lastExportFailure ?? 'no reason'}',
          observed: observed,
        );
      }
      final records = leg.role == 'below'
          ? null
          : countCaptureRecords(json, bracket: leg.bracket, role: leg.role);
      final afterExport = decideAfterExport(
        leg: leg,
        knob: current,
        observed: observed,
        attempts: driver.attempts,
        records: records,
      );
      if (afterExport is LegFail) {
        return driver.fail(afterExport.reason, observed: observed);
      }
      if (afterExport is LegRetry) {
        driver.addLog(
          '[$label] ${afterExport.reason}, retrying at $knob '
          '${afterExport.knob}',
        );
        current = afterExport.knob;
        continue;
      }

      await withCallTimeout(
        calls.resumeStreams(),
        'resumeAllTimelineStreams',
        timeout: callTimeout,
      );
      streamsSuspended = false;
      driver.addLog(
        '[$label] export OK (${json.length} chars'
        '${records == null ? '' : ', ${records.inBand} in-band records'})',
      );
      driver.complete(observed: observed, json: json);
      return;
    }
  } catch (e) {
    driver.fail('$e');
  } finally {
    stopWorkload();
    if (scenarioOpen) {
      endScenarioInCleanup(leg.scenario, label, markEnd: calls.markScenarioEnd);
    }
    if (streamsSuspended) {
      unawaited(calls.resumeStreams().catchError((Object _) {}));
    }
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

// ── Widgets ──

/// Banner shown on a capture screen while capture mode is off, the VM
/// service is not connected or the build cannot stamp an approved
/// provenance; legs started in that state fail. Renders nothing when
/// every check passes.
class CapturePreflightBanner extends StatelessWidget {
  const CapturePreflightBanner({
    super.key,
    required this.captureMode,
    required this.vmConnected,
    this.provenanceProblem,
  });

  final bool captureMode;
  final bool vmConnected;

  /// Why the build cannot stamp an approved provenance, if it cannot.
  final String? provenanceProblem;

  @override
  Widget build(BuildContext context) {
    final lines = [
      if (!captureMode)
        'Capture mode is off. Relaunch with '
            '--dart-define=SLEUTH_CAPTURE_MODE=true.'
      else if (!vmConnected)
        'VM service not connected. Run a profile build with '
            '--no-dds so Sleuth can attach.',
      if (provenanceProblem != null) 'Capture provenance: $provenanceProblem.',
    ];
    if (lines.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      color: scheme.errorContainer,
      child: Text(
        lines.join('\n'),
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
