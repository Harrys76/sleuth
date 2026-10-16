import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show FramePhase, FrameTiming, TimingsCallback;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:sleuth/sleuth.dart';
// The detector is not exported; the leg reads its brackets from the
// detector's own metadata so the bands cannot drift from the audit.
// ignore: implementation_imports
import 'package:sleuth/src/detectors/startup_detector.dart';

import 'capture_driver.dart';

/// Capture flow for the `runtimeVerified` brackets on
/// `StartupDetector.slow_startup_ttff`: the warning at 1500 ms from
/// `Sleuth.init` to the first frame's timing report, and the critical at
/// 3000 ms.
///
/// A leg cannot run on a screen, because the measurement starts at
/// `Sleuth.init`. Each leg is a cold launch. The host copies a request
/// file naming the leg into the app container, then relaunches the app
/// ([StartupLeg.launchCommand]). iOS 17.5 does not pass `devicectl`'s
/// environment variables to the app, so the file carries the leg.
///
/// `main()` reads the leg before `Sleuth.init`, takes its own wall-clock
/// reading, blocks for the leg's delay before `runApp`, and hands the leg
/// to [StartupLegRunner]. The runner opens the scenario in the first
/// post-frame callback, waits for the VM link and for the detector to
/// judge the first frame, exports the capture and writes it, with a
/// verdict record, under [startupLegResultsDirectory]. The host copies
/// both with `xcrun devicectl device copy from`.
///
/// The observed value is the first frame's `rasterFinishWallTime` minus
/// the app's reading before `Sleuth.init`. That end point is the
/// engine's raster finish, not the timing report that ends the detector's
/// measurement, so the audit compares two separate readings.

/// Environment variable, or dart-define, naming the leg's scenario.
const kStartupLegVariable = 'SLEUTH_TTFF_LEG';

/// File under the app's temp directory that names the leg's scenario.
/// `main()` reads and deletes it, so a crash cannot run the leg again.
const kStartupLegRequestFile = 'sleuth_startup_leg_request.txt';

/// The request file in this app's temp directory.
File get startupLegRequestFile =>
    File('${Directory.systemTemp.path}/$kStartupLegRequestFile');

/// Environment variable, or dart-define, with a plain delay in ms before
/// `runApp`, with no capture. The Galaxy normal-build check uses it.
const kStartupDelayVariable = 'SLEUTH_STARTUP_DELAY_MS';

/// Longest delay a launch blocks for. The delay blocks the main thread,
/// which also runs the platform's launch on iOS and Android.
const kMaxStartupDelayMs = 4500;

/// Time to first frame past the delay on the iPhone 12 capture build. Six
/// devicectl launches measured the delay plus 71 to 75 ms. The leg
/// judges its own measurement against the band, so an off offset refuses
/// the leg instead of passing it.
const kStartupBaseMs = 74;

/// One slow_startup_ttff capture leg.
enum StartupLeg {
  below(tier: 'warning', role: 'below', targetMs: 1000),
  at(tier: 'warning', role: 'at', targetMs: 1650),
  above(tier: 'warning', role: 'above', targetMs: 2400),
  criticalBelow(tier: 'critical', role: 'below', targetMs: 2400),
  criticalAt(tier: 'critical', role: 'at', targetMs: 3300),
  criticalAbove(tier: 'critical', role: 'above', targetMs: 4500);

  const StartupLeg({
    required this.tier,
    required this.role,
    required this.targetMs,
  });

  /// The bracket the leg records for, `warning` or `critical`.
  final String tier;

  /// `below`, `at` or `above`.
  final String role;

  /// Time to first frame the leg aims for.
  final int targetMs;

  /// The blocking delay between `Sleuth.init` and `runApp`.
  int get delayMs => math.min(targetMs - kStartupBaseMs, kMaxStartupDelayMs);

  /// Scenario name, which is also the capture's file basename.
  String get scenario => tier == 'critical'
      ? 'slow_startup_ttff_critical_$role'
      : 'slow_startup_ttff_$role';

  /// The leg as the log names it.
  String get label => tier == 'critical' ? 'critical/$role' : role;

  /// The leg's title on the screen.
  String get title {
    final roleText = '${role[0].toUpperCase()}${role.substring(1)}';
    return tier == 'critical' ? 'Critical $role' : roleText;
  }

  /// The host commands that launch this leg on [device]: copy the request
  /// file into the app container, then relaunch the app.
  String launchCommand({String device = '<device>'}) =>
      'printf $scenario > /tmp/$kStartupLegRequestFile && '
      'xcrun devicectl device copy to --device $device '
      '--domain-type appDataContainer '
      '--domain-identifier com.example.example '
      '--source /tmp/$kStartupLegRequestFile '
      '--destination tmp/$kStartupLegRequestFile && '
      'xcrun devicectl device process launch --device $device '
      '--terminate-existing com.example.example';

  /// The leg named [scenario], or null.
  static StartupLeg? fromScenario(String scenario) {
    for (final leg in values) {
      if (leg.scenario == scenario) return leg;
    }
    return null;
  }
}

/// The bracket the capture audit judges [leg] against, read from
/// [metadata] (the detector's `validationMetadata`).
CaptureBracket? startupLegBracket(DetectorMetadata metadata, StartupLeg leg) =>
    CaptureBracket.fromMetadata(
      metadata,
      stableId: 'slow_startup_ttff',
      severityLabel: leg.tier,
    );

/// The `expectedMagnitude` band a [role] leg exports against [bracket]:
/// below `[1, threshold - 1]`, at `[threshold, atUpper]`, above
/// `[atUpper, aboveCeiling]`. The schema rejects a bound at or below 0.
({double min, double max}) startupLegBand(
  CaptureBracket bracket,
  String role,
) => switch (role) {
  'below' => (min: 1, max: bracket.threshold - 1),
  'at' => (min: bracket.threshold, max: bracket.atUpper),
  _ => (min: bracket.atUpper, max: bracket.aboveCeiling),
};

/// What the host asked this launch to do, read from the environment, the
/// dart-defines and the request file.
@immutable
class StartupLegRequest {
  const StartupLegRequest({this.leg, this.plainDelayMs = 0, this.problem});

  /// The capture leg, or null.
  final StartupLeg? leg;

  /// A delay with no capture, used when [leg] is null.
  final int plainDelayMs;

  /// Why a value was ignored, or null.
  final String? problem;

  /// The delay this launch blocks for.
  int get delayMs => leg?.delayMs ?? plainDelayMs;

  /// Whether this launch is an ordinary launch.
  bool get isEmpty => leg == null && plainDelayMs == 0;

  /// Reads the request: the environment first, then the dart-defines,
  /// then [requestFile] for the leg. [environment] defaults to
  /// [Platform.environment] and [requestFile] to [startupLegRequestFile].
  /// It deletes the request file whenever one exists, so the file names
  /// one launch's leg at most.
  static StartupLegRequest read({
    Map<String, String>? environment,
    String definedLeg = const String.fromEnvironment(kStartupLegVariable),
    String definedDelay = const String.fromEnvironment(kStartupDelayVariable),
    File? requestFile,
  }) {
    final env =
        environment ??
        (kIsWeb ? const <String, String>{} : Platform.environment);
    String pick(String name, String defined) {
      final fromEnvironment = env[name];
      return fromEnvironment != null && fromEnvironment.isNotEmpty
          ? fromEnvironment
          : defined;
    }

    final problems = <String>[];
    var legName = pick(kStartupLegVariable, definedLeg);
    final fileLeg = kIsWeb
        ? null
        : _takeRequestFile(requestFile ?? startupLegRequestFile, problems);
    if (legName.isEmpty && fileLeg != null) legName = fileLeg;
    final delayText = pick(kStartupDelayVariable, definedDelay);
    StartupLeg? leg;
    if (legName.isNotEmpty) {
      leg = StartupLeg.fromScenario(legName);
      if (leg == null) problems.add('unknown startup leg "$legName"');
    }
    var plainDelayMs = 0;
    if (delayText.isNotEmpty) {
      final parsed = int.tryParse(delayText);
      if (parsed == null || parsed < 0) {
        problems.add('startup delay "$delayText" is not a whole ms count');
      } else {
        plainDelayMs = math.min(parsed, kMaxStartupDelayMs);
      }
    }
    return StartupLegRequest(
      leg: leg,
      plainDelayMs: plainDelayMs,
      problem: problems.isEmpty ? null : problems.join('; '),
    );
  }
}

/// The scenario [file] names, deleting the file; null when there is no
/// file. A file that cannot be read or deleted adds to [problems].
String? _takeRequestFile(File file, List<String> problems) {
  try {
    if (!file.existsSync()) return null;
    final name = file.readAsStringSync().trim();
    file.deleteSync();
    return name;
  } on Object catch (e) {
    problems.add('startup leg request file: $e');
    try {
      if (file.existsSync()) file.deleteSync();
    } on Object {
      // Nothing more to do; the problem is reported.
    }
    return null;
  }
}

/// Why [leg] cannot run in this build, or null when it can. `main()`
/// checks it before the delay, so a refused leg does not block the
/// launch.
String? startupLegRefusal(
  StartupLeg leg, {
  required bool captureMode,
  CaptureProvenanceCheck Function() check = currentCaptureProvenance,
}) {
  if (!captureMode) {
    return 'capture mode is off. Build with '
        '--dart-define=SLEUTH_CAPTURE_MODE=true';
  }
  final problem = check().problem;
  return problem == null ? null : 'capture provenance: $problem';
}

/// The first `FrameTiming` the engine reports, kept whole.
class FirstFrameRecorder {
  FrameTiming? _first;
  final Completer<FrameTiming> _done = Completer<FrameTiming>();

  /// The first frame's timing once it arrives.
  Future<FrameTiming> get first => _done.future;

  /// The first frame's timing, or null before it arrives.
  FrameTiming? get timing => _first;

  /// Registers a one-shot timings callback. Call after the binding
  /// exists.
  void start() {
    late final TimingsCallback callback;
    callback = (timings) {
      SchedulerBinding.instance.removeTimingsCallback(callback);
      if (timings.isEmpty || _done.isCompleted) return;
      _first = timings.first;
      _done.complete(timings.first);
    };
    SchedulerBinding.instance.addTimingsCallback(callback);
  }

  /// Hands [timing] over as the first frame. Tests use it.
  @visibleForTesting
  void recordForTest(FrameTiming timing) {
    if (_done.isCompleted) return;
    _first = timing;
    _done.complete(timing);
  }
}

/// Time to first frame in ms from [markerWallUs] to [timing]'s raster
/// finish in wall time, or null when the reading is not plausible: no
/// timing, a wall time at or before the marker, or one more than 60 s
/// after it.
double? observedTtffMs(FrameTiming? timing, int markerWallUs) {
  if (timing == null) return null;
  final rasterWallUs = timing.timestampInMicroseconds(
    FramePhase.rasterFinishWallTime,
  );
  final elapsedUs = rasterWallUs - markerWallUs;
  if (elapsedUs <= 0 || elapsedUs > 60 * Duration.microsecondsPerSecond) {
    return null;
  }
  return elapsedUs / 1000;
}

/// Where a leg writes its capture and verdict. The host copies
/// `tmp/sleuth_startup_legs/<file>` from the app container.
Directory get startupLegResultsDirectory =>
    Directory('${Directory.systemTemp.path}/sleuth_startup_legs');

/// File name of the latest leg's verdict record.
const kStartupLegRecordFile = 'last_leg.json';

/// The verdict of one leg, as the screen and the host read it.
@immutable
class StartupLegRecord {
  const StartupLegRecord({
    required this.launchId,
    required this.scenario,
    required this.state,
    this.verdict,
    this.reason,
    this.observedMs,
    this.detectorMs,
    this.delayMs,
    this.chars,
    this.updatedAt,
  });

  /// Identifies the launch that wrote the record.
  final String launchId;

  /// The leg's scenario name.
  final String scenario;

  /// `running`, `stashed`, `refused` or `failed`.
  final String state;

  /// `ABORT`, `UNMEASURED`, `OUT-OF-BAND` or `FAILED` for a leg that did
  /// not stash, else null.
  final String? verdict;

  /// Why the leg did not stash, or null.
  final String? reason;

  /// The leg's own time to first frame.
  final double? observedMs;

  /// The detector's `ttffMs`.
  final double? detectorMs;

  /// The blocking delay the launch used.
  final int? delayMs;

  /// Length of the stashed capture JSON.
  final int? chars;

  /// When the leg wrote the record.
  final DateTime? updatedAt;

  /// The leg this record belongs to, or null for an unknown scenario.
  StartupLeg? get leg => StartupLeg.fromScenario(scenario);

  /// Whether the leg ended with a capture file.
  bool get isStashed => state == 'stashed';

  /// One log line for the record, without the leg label.
  String get line => switch (state) {
    'running' => 'running (launch $launchId)',
    'stashed' =>
      'capture stashed ($chars chars): time to first frame '
          '${observedMs?.toStringAsFixed(1)} ms, detector '
          '${detectorMs?.toStringAsFixed(1)} ms',
    _ => '${verdict ?? 'FAILED'}: ${reason ?? 'no reason recorded'}',
  };

  StartupLegRecord copyWith({
    String? state,
    String? verdict,
    String? reason,
    double? observedMs,
    double? detectorMs,
    int? chars,
    DateTime? updatedAt,
  }) => StartupLegRecord(
    launchId: launchId,
    scenario: scenario,
    state: state ?? this.state,
    verdict: verdict ?? this.verdict,
    reason: reason ?? this.reason,
    observedMs: observedMs ?? this.observedMs,
    detectorMs: detectorMs ?? this.detectorMs,
    delayMs: delayMs,
    chars: chars ?? this.chars,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, Object?> toJson() => {
    'launchId': launchId,
    'scenario': scenario,
    'state': state,
    'verdict': verdict,
    'reason': reason,
    'observedMs': observedMs,
    'detectorMs': detectorMs,
    'delayMs': delayMs,
    'chars': chars,
    'updatedAt': updatedAt?.toIso8601String(),
  };

  /// Parses a record, or throws [FormatException].
  static StartupLegRecord fromJson(Object? json) {
    if (json is! Map) throw const FormatException('not a JSON object');
    T? field<T>(String key) {
      final value = json[key];
      if (value == null || value is T) return value as T?;
      throw FormatException('field "$key" has the wrong type');
    }

    final launchId = field<String>('launchId');
    final scenario = field<String>('scenario');
    final state = field<String>('state');
    if (launchId == null || scenario == null || state == null) {
      throw const FormatException('launchId, scenario or state missing');
    }
    final updatedAt = field<String>('updatedAt');
    return StartupLegRecord(
      launchId: launchId,
      scenario: scenario,
      state: state,
      verdict: field<String>('verdict'),
      reason: field<String>('reason'),
      observedMs: field<num>('observedMs')?.toDouble(),
      detectorMs: field<num>('detectorMs')?.toDouble(),
      delayMs: field<num>('delayMs')?.toInt(),
      chars: field<num>('chars')?.toInt(),
      updatedAt: updatedAt == null ? null : DateTime.tryParse(updatedAt),
    );
  }
}

/// Reads and writes a leg's files in [directory].
class StartupLegResults {
  StartupLegResults([Directory? directory])
    : directory = directory ?? startupLegResultsDirectory;

  final Directory directory;

  File get _recordFile => File('${directory.path}/$kStartupLegRecordFile');

  /// The capture file of [scenario].
  File captureFile(String scenario) => File('${directory.path}/$scenario.json');

  /// The latest record, or null when no leg has run. Throws
  /// [FormatException] or a [FileSystemException] for a file it cannot
  /// read.
  StartupLegRecord? readRecord() {
    final file = _recordFile;
    if (!file.existsSync()) return null;
    return StartupLegRecord.fromJson(jsonDecode(file.readAsStringSync()));
  }

  /// Writes [record] through a temp file, so a reader never sees half a
  /// record.
  void writeRecord(StartupLegRecord record) {
    _writeAtomically(_recordFile, jsonEncode(record.toJson()));
  }

  /// Writes the composed capture of [scenario].
  void writeCapture(String scenario, String json) {
    _writeAtomically(captureFile(scenario), json);
  }

  /// Deletes an earlier capture of [scenario], so a refused leg cannot
  /// leave an older leg's capture under the same name.
  void deleteCapture(String scenario) {
    final file = captureFile(scenario);
    if (file.existsSync()) file.deleteSync();
  }

  /// Turns a `running` record that another launch left into a failure.
  /// Returns the repaired record, or null when there was none.
  StartupLegRecord? repairStale({required String currentLaunchId}) {
    final StartupLegRecord? record;
    try {
      record = readRecord();
    } on Object {
      return null;
    }
    if (record == null ||
        record.state != 'running' ||
        record.launchId == currentLaunchId) {
      return null;
    }
    final repaired = record.copyWith(
      state: 'failed',
      verdict: 'FAILED',
      reason: 'the app ended during the leg (killed, crashed or relaunched)',
    );
    writeRecord(repaired);
    return repaired;
  }

  void _writeAtomically(File target, String contents) {
    directory.createSync(recursive: true);
    final temp = File('${target.path}.tmp');
    temp.writeAsStringSync(contents, flush: true);
    temp.renameSync(target.path);
  }
}

/// The Sleuth calls a leg makes. Tests pass a recording subclass.
class StartupLegCalls {
  const StartupLegCalls();

  void markScenarioBegin(String scenario) => Sleuth.markScenarioBegin(scenario);

  void markScenarioEnd(String scenario) => Sleuth.markScenarioEnd(scenario);

  Future<void> flushTimeline() =>
      Sleuth.flushTimelineNow(timeout: const Duration(seconds: 2));

  Future<void> suspendStreams() => Sleuth.suspendNonEssentialTimelineStreams();

  Future<void> resumeStreams() => Sleuth.resumeAllTimelineStreams();

  bool vmConnected() => Sleuth.diagnoseCaptureState().vmConnected;

  /// Whether the detector has judged the first frame; null without a
  /// startup detector.
  bool? detectorEvaluated() => Sleuth.startupDetector?.evaluated;

  /// The detector's measurement.
  double? detectorTtffMs() => Sleuth.startupMetrics?.ttffMs;

  Future<String?> exportCapture({
    required StartupLeg leg,
    required ({double min, double max}) band,
    required double observed,
    required CaptureProvenance provenance,
    required String captureNotes,
  }) => Sleuth.exportCaptureJson(
    scenario: leg.scenario,
    role: leg.role,
    magnitudeMin: band.min,
    magnitudeObserved: observed,
    magnitudeMax: band.max,
    unit: 'ms',
    device: provenance.device,
    deviceOsVersion: provenance.deviceOsVersion,
    flutterVersion: provenance.flutterVersion,
    captureCommand: '${provenance.captureCommand}, then ${leg.launchCommand()}',
    captureNotes: captureNotes,
    bracketStableId: 'slow_startup_ttff',
    bracketSeverityLabel: leg.tier,
    // The time comes from FrameTiming, not from a timeline event.
    magnitudeSourceEventName: '',
  );

  String? lastExportFailure() => Sleuth.lastCaptureExportFailure;
}

/// A leg that stopped before it stashed its capture.
class _LegStop implements Exception {
  const _LegStop(this.verdict, this.reason);

  final String verdict;
  final String reason;
}

/// Runs one startup capture leg in the launch that `main()` delayed.
class StartupLegRunner {
  StartupLegRunner({
    required this.leg,
    required this.markerWallUs,
    required this.firstFrame,
    required this.launchId,
    StartupLegResults? results,
    this.calls = const StartupLegCalls(),
    this.provenanceCheck = currentCaptureProvenance,
    this.connectLimit = const Duration(seconds: 15),
    this.evaluateLimit = const Duration(seconds: 10),
    this.overallLimit = const Duration(seconds: 25),
    this.pollInterval = const Duration(milliseconds: 100),
  }) : results = results ?? StartupLegResults();

  final StartupLeg leg;

  /// The app's wall-clock reading before `Sleuth.init`, in µs.
  final int markerWallUs;

  final FirstFrameRecorder firstFrame;
  final String launchId;
  final StartupLegResults results;
  final StartupLegCalls calls;
  final CaptureProvenanceCheck Function() provenanceCheck;
  final Duration connectLimit;
  final Duration evaluateLimit;
  final Duration overallLimit;
  final Duration pollInterval;

  bool _scenarioOpen = false;
  bool _streamsSuspended = false;
  String? _leftForeground;
  Object? _beginError;
  AppLifecycleListener? _lifecycle;

  // Set when the overall limit passes. The timed-out leg keeps running
  // until its next check, so every check and the capture write read it.
  bool _stopped = false;

  /// Writes the `running` record and opens the scenario in the first
  /// post-frame callback. The returned future completes with the final
  /// record.
  Future<StartupLegRecord> start() {
    final running = StartupLegRecord(
      launchId: launchId,
      scenario: leg.scenario,
      state: 'running',
      delayMs: leg.delayMs,
      updatedAt: DateTime.now(),
    );
    // A file error must not stop the launch; the leg still runs and logs.
    try {
      results.repairStale(currentLaunchId: launchId);
      results.deleteCapture(leg.scenario);
      results.writeRecord(running);
    } on Object catch (e) {
      debugPrint('Startup leg ${leg.label}: could not write its record: $e');
    }
    final done = Completer<StartupLegRecord>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        calls.markScenarioBegin(leg.scenario);
        _scenarioOpen = true;
      } catch (e) {
        _beginError = e;
      }
      done.complete(_finish(running));
    });
    return done.future;
  }

  Future<StartupLegRecord> _finish(StartupLegRecord running) async {
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        if (state == AppLifecycleState.hidden ||
            state == AppLifecycleState.paused ||
            state == AppLifecycleState.detached) {
          _leftForeground ??= state.name;
        }
      },
    );
    StartupLegRecord record;
    try {
      record = await _run(running).timeout(
        overallLimit,
        onTimeout: () {
          _stopped = true;
          throw _LegStop(
            'FAILED',
            'the leg did not finish within ${overallLimit.inSeconds} s of '
                'the first frame',
          );
        },
      );
    } on _LegStop catch (stop) {
      record = running.copyWith(
        state: stop.verdict == 'FAILED' ? 'failed' : 'refused',
        verdict: stop.verdict,
        reason: stop.reason,
        observedMs: observedTtffMs(firstFrame.timing, markerWallUs),
        detectorMs: calls.detectorTtffMs(),
      );
    } on CaptureProvenanceUnavailable catch (e) {
      record = running.copyWith(
        state: 'refused',
        verdict: 'ABORT',
        reason: 'capture provenance: ${e.problem}',
      );
    } catch (e) {
      record = running.copyWith(
        state: 'failed',
        verdict: 'FAILED',
        reason: '$e',
      );
    } finally {
      _endScenario();
      await _resumeStreams();
      _lifecycle?.dispose();
      _lifecycle = null;
    }
    record = record.copyWith(updatedAt: DateTime.now());
    try {
      results.writeRecord(record);
    } on Object catch (e) {
      debugPrint('Startup leg ${leg.label}: could not write its record: $e');
    }
    debugPrint('Startup leg ${leg.label}: ${record.line}');
    return record;
  }

  Future<StartupLegRecord> _run(StartupLegRecord running) async {
    final beginError = _beginError;
    if (beginError != null) {
      throw _LegStop('FAILED', 'markScenarioBegin: $beginError');
    }
    final bracket = startupLegBracket(
      StartupDetector().validationMetadata,
      leg,
    );
    if (bracket == null) {
      throw _LegStop(
        'ABORT',
        'StartupDetector declares no slow_startup_ttff ${leg.tier} bracket',
      );
    }
    final provenance = requireCaptureProvenance(check: provenanceCheck);

    await _waitFor(
      calls.vmConnected,
      connectLimit,
      () => const _LegStop('FAILED', 'VM service did not connect'),
      what: 'connect',
    );
    // The leg keeps only the Dart timeline stream while it waits and
    // exports, so the Embedder and GC streams cannot roll the ring past
    // the scenario's begin marker. It sets the flag before the call,
    // because a suspension that times out may still land later.
    _streamsSuspended = true;
    await withCallTimeout(
      calls.suspendStreams(),
      'suspendNonEssentialTimelineStreams',
    );
    await _waitFor(
      () => calls.detectorEvaluated() ?? false,
      evaluateLimit,
      () => const _LegStop(
        'FAILED',
        'the startup detector did not judge the first frame',
      ),
      what: 'evaluate',
    );

    final observed = observedTtffMs(firstFrame.timing, markerWallUs);
    final detectorMs = calls.detectorTtffMs();
    final measured = measurementRefusal(
      observed,
      role: leg.role,
      bracket: bracket,
      what: 'time to first frame',
      unit: 'ms',
    );
    if (measured != null) {
      throw _LegStop(measured.verdict, measured.reason);
    }

    await withCallTimeout(calls.flushTimeline(), 'flushTimelineNow');
    _endScenario();
    // The end marker must reach the VM buffer before the export reads it.
    await Future<void>.delayed(const Duration(milliseconds: 800));
    await _resumeStreams();
    _checkForeground();

    final timing = firstFrame.timing!;
    final rasterWallUs = timing.timestampInMicroseconds(
      FramePhase.rasterFinishWallTime,
    );
    final notes =
        'Cold launch through devicectl after a request file named '
        '${leg.scenario}; ${leg.delayMs} ms blocking delay between '
        'Sleuth.init and runApp. observed = first FrameTiming '
        'rasterFinishWallTime $rasterWallUs us - app wall-clock reading '
        'before Sleuth.init $markerWallUs us = '
        '${observed!.toStringAsFixed(1)} ms; detector ttffMs '
        '${detectorMs?.toStringAsFixed(1)} ms.';
    final json = await withCallTimeout(
      calls.exportCapture(
        leg: leg,
        band: startupLegBand(bracket, leg.role),
        observed: observed,
        provenance: provenance,
        captureNotes: notes,
      ),
      'exportCaptureJson',
    );
    if (json == null) {
      throw _LegStop(
        'FAILED',
        'capture failed to compose: '
            '${calls.lastExportFailure() ?? 'exportCaptureJson gave no reason'}',
      );
    }
    final check = checkCaptureJson(
      json,
      bracket: bracket,
      role: leg.role,
      observed: observed,
      unit: 'ms',
    );
    final refusal = recordRefusal(check, role: leg.role, bracket: bracket);
    if (refusal != null) throw _LegStop(refusal.verdict, refusal.reason);
    _checkForeground();
    results.writeCapture(leg.scenario, json);
    return running.copyWith(
      state: 'stashed',
      observedMs: observed,
      detectorMs: detectorMs,
      chars: json.length,
    );
  }

  Future<void> _waitFor(
    bool Function() condition,
    Duration limit,
    _LegStop Function() onTimeout, {
    required String what,
  }) async {
    // Waited time counts poll intervals, so a test's fake clock drives it
    // too; on the device each interval runs a little long.
    var waited = Duration.zero;
    while (!condition()) {
      _checkForeground();
      if (waited >= limit) {
        final stop = onTimeout();
        throw _LegStop(
          stop.verdict,
          '${stop.reason} within ${limit.inSeconds} s',
        );
      }
      await Future<void>.delayed(pollInterval);
      waited += pollInterval;
    }
    _checkForeground();
  }

  void _checkForeground() {
    if (_stopped) {
      throw const _LegStop('FAILED', 'the leg passed its overall limit');
    }
    final state = _leftForeground;
    if (state != null) {
      throw _LegStop(
        'UNMEASURED',
        'the app left the foreground ($state) during the leg',
      );
    }
  }

  void _endScenario() {
    if (!_scenarioOpen) return;
    _scenarioOpen = false;
    try {
      calls.markScenarioEnd(leg.scenario);
    } catch (e) {
      debugPrint('Startup leg ${leg.label}: markScenarioEnd: $e');
    }
  }

  Future<void> _resumeStreams() async {
    if (!_streamsSuspended) return;
    _streamsSuspended = false;
    try {
      await withCallTimeout(calls.resumeStreams(), 'resumeAllTimelineStreams');
    } catch (e) {
      debugPrint('Startup leg ${leg.label}: resumeAllTimelineStreams: $e');
    }
  }
}

/// What one launch does for slow_startup_ttff: run a capture leg, block
/// for a plain delay, or nothing. `main()` calls [read] just before
/// `Sleuth.init`, [afterInit] after it, [delay] before `runApp` and
/// [afterRunApp] after it.
class StartupLaunch {
  StartupLaunch._(
    this.leg,
    this.refusal,
    this.delayMs,
    this.markerWallUs, {
    required void Function(Duration) sleeper,
    required StartupLegResults Function() results,
  }) : _sleep = sleeper,
       _results = results;

  /// Reads the launch's request and takes the wall-clock reading the leg
  /// measures from. A refused leg gets no delay, so it costs the launch
  /// nothing.
  factory StartupLaunch.read({
    required bool captureMode,
    StartupLegRequest? request,
    CaptureProvenanceCheck Function() check = currentCaptureProvenance,
    void Function(Duration) sleeper = sleep,
    StartupLegResults Function()? results,
  }) {
    final req = request ?? StartupLegRequest.read();
    final problem = req.problem;
    if (problem != null) debugPrint('Startup leg: $problem; ignored.');
    final leg = req.leg;
    final refusal = leg == null
        ? null
        : startupLegRefusal(leg, captureMode: captureMode, check: check);
    final delayMs = leg == null
        ? req.plainDelayMs
        : (refusal == null ? leg.delayMs : 0);
    return StartupLaunch._(
      leg,
      refusal,
      delayMs,
      req.isEmpty ? 0 : DateTime.now().microsecondsSinceEpoch,
      sleeper: sleeper,
      results: results ?? StartupLegResults.new,
    );
  }

  /// The requested leg, or null.
  final StartupLeg? leg;

  /// Why [leg] cannot run in this build, or null.
  final String? refusal;

  /// The blocking delay before `runApp`.
  final int delayMs;

  /// The app's wall-clock reading before `Sleuth.init`, in µs; 0 for an
  /// ordinary launch.
  final int markerWallUs;

  final void Function(Duration) _sleep;
  final StartupLegResults Function() _results;
  FirstFrameRecorder? _firstFrame;

  /// Whether this launch runs a capture leg.
  bool get runsLeg => leg != null && refusal == null;

  /// Identifies this launch in the leg's records.
  String get launchId => '$pid-$markerWallUs';

  /// Starts keeping the first frame's timing for a leg.
  void afterInit() {
    if (runsLeg) _firstFrame = FirstFrameRecorder()..start();
  }

  /// Blocks the main isolate for the leg's or the plain delay.
  void delay() {
    if (delayMs > 0) _sleep(Duration(milliseconds: delayMs));
  }

  /// Starts the leg, or records the refusal. Returns the leg's
  /// final record, or null when no leg runs.
  Future<StartupLegRecord>? afterRunApp() {
    final leg = this.leg;
    if (leg == null) return null;
    final refusal = this.refusal;
    if (refusal != null) {
      debugPrint('Startup leg ${leg.label}: ABORT: $refusal');
      try {
        _results().writeRecord(
          StartupLegRecord(
            launchId: launchId,
            scenario: leg.scenario,
            state: 'refused',
            verdict: 'ABORT',
            reason: refusal,
            updatedAt: DateTime.now(),
          ),
        );
      } on Object catch (e) {
        debugPrint('Startup leg ${leg.label}: could not write its record: $e');
      }
      return null;
    }
    return StartupLegRunner(
      leg: leg,
      markerWallUs: markerWallUs,
      firstFrame: _firstFrame!,
      launchId: launchId,
      results: _results(),
    ).start();
  }
}
