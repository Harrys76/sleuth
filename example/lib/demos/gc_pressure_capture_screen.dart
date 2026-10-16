import 'dart:async';
import 'dart:developer' show Service;
import 'dart:isolate' show Isolate;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sleuth/sleuth.dart';
// The detector is not exported; the screen reads its bracket from the
// detector's own metadata so the bands cannot drift from the audit.
// ignore: implementation_imports
import 'package:sleuth/src/detectors/memory_pressure_detector.dart'
    show MemoryPressureDetector;
import 'package:vm_service/vm_service.dart' show Event, EventStreams, VmService;
import 'package:vm_service/vm_service_io.dart' show vmServiceConnectUri;

import 'capture_driver.dart';

/// Capture helper for the `runtimeVerified` bracket on
/// `MemoryPressureDetector.gc_pressure.warning`, which fires above 40
/// young-generation collections in its 10 s window (240 per minute).
///
/// The young-collection count follows the VM's new-space size, not a
/// number the operator can set, so the screen counts the collections
/// itself. It opens its own VM service connection, listens to the `GC`
/// stream, keeps this isolate's young collections ([isYoungGcType]) and
/// exports the largest count in any 10 s window of the scenario span as
/// the observed value. The capture audit compares that count with the
/// detector's records within 25 %.
///
/// Each leg measures the ambient young rate for 4 s, calibrates a garbage
/// allocator for 4 s, then runs a 13 s span inside
/// `markScenarioBegin`/`markScenarioEnd`. During the span a closed loop
/// adjusts the allocation once a second to hold the leg's target: 25
/// (below), 50 (at) or 80 (above) young collections per 10 s. The
/// allocator builds small maps and lists, which stay in new space, and
/// writes each batch's length to a field so the compiler keeps them.
///
/// **Procedure per leg:**
///
///   1. `cd example && fvm flutter run --profile --no-dds -d "iPhone 12" \
///         --dart-define=SLEUTH_CAPTURE_MODE=true \
///         --dart-define=SLEUTH_CAPTURE_DEVICE="iPhone 12"`. Set Auto-Lock
///      to Never, because a leg takes about 30 s and a lock ends it.
///   2. Open Capture Helpers, then MemoryPressure (gc_pressure). The
///      provenance line names the device, OS and Flutter version; a red
///      banner lists anything that blocks a leg.
///   3. Tap "Below: 25 young GCs in 10 s", "At: 50 young GCs in 10 s" or
///      "Above: 80 young GCs in 10 s" and wait for "capture stashed".
///   4. Tap **Export last leg** and save the clipboard text as
///      `gc_pressure_<role>.json` under
///      `test/validation/captures/gc_pressure/`.
class GcPressureCaptureScreen extends StatefulWidget {
  const GcPressureCaptureScreen({
    super.key,
    this.captureModeOverride,
    this.provenanceCheck = currentCaptureProvenance,
    this.vmConnected = _sleuthVmConnected,
    this.calls = const CaptureLegCalls(),
    this.gcEvents = _vmServiceGcEvents,
    this.allocator,
  });

  /// Capture mode for tests. Null reads the build's
  /// `SLEUTH_CAPTURE_MODE` dart-define.
  @visibleForTesting
  final bool? captureModeOverride;

  /// Where the screen reads the provenance its exports stamp.
  @visibleForTesting
  final CaptureProvenanceCheck Function() provenanceCheck;

  /// Whether Sleuth's VM service client is connected, which the export
  /// needs to read the detector's records.
  @visibleForTesting
  final bool Function() vmConnected;

  /// The stream, scenario and flush calls a leg makes.
  @visibleForTesting
  final CaptureLegCalls calls;

  /// Opens the screen's own GC event feed.
  @visibleForTesting
  final GcEventSource Function() gcEvents;

  /// The garbage allocator; null builds a [ChurnAllocator].
  @visibleForTesting
  final ChurnAllocator? allocator;

  @override
  State<GcPressureCaptureScreen> createState() =>
      _GcPressureCaptureScreenState();
}

bool _sleuthVmConnected() => Sleuth.diagnoseCaptureState().vmConnected;

GcEventSource _vmServiceGcEvents() => VmServiceGcEventSource();

/// Whether [gcType] is a young-generation collection, by the rule
/// `MemoryPressureDetector` applies: `MarkSweep` and `MarkCompact`
/// complete an old-generation cycle, `StartCMark` starts a concurrent
/// mark, and anything else (`Scavenge`, `Evacuate`, an unknown or missing
/// type) is young.
bool isYoungGcType(String? gcType) => switch (gcType) {
  'MarkSweep' || 'MarkCompact' || 'StartCMark' => false,
  _ => true,
};

/// The young collections a leg saw, by arrival time.
class YoungGcLog {
  final List<DateTime> _young = [];

  /// Records one GC event that arrived at [at].
  void add(DateTime at, String? gcType) {
    if (isYoungGcType(gcType)) _young.add(at);
  }

  /// Young collections that arrived at or after [since].
  int countSince(DateTime since) =>
      _young.where((t) => !t.isBefore(since)).length;

  /// The largest number of young collections in any [window] that ends
  /// at one of them, counting only arrivals in `[from, to]`. A window
  /// holds the arrivals no earlier than its end minus [window], as the
  /// detector's eviction keeps them.
  int peakIn(Duration window, {required DateTime from, required DateTime to}) {
    final span = [
      for (final t in _young)
        if (!t.isBefore(from) && !t.isAfter(to)) t,
    ]..sort();
    var peak = 0;
    var start = 0;
    for (var end = 0; end < span.length; end++) {
      final cutoff = span[end].subtract(window);
      while (span[start].isBefore(cutoff)) {
        start++;
      }
      final count = end - start + 1;
      if (count > peak) peak = count;
    }
    return peak;
  }

  /// Forgets every arrival.
  void clear() => _young.clear();
}

/// A feed of this isolate's GC events, each with its arrival time and
/// `gcType`.
abstract class GcEventSource {
  /// Starts the feed. Events arrive on [onEvent] until [stop].
  Future<void> start(void Function(DateTime at, String? gcType) onEvent);

  /// Stops the feed and releases its connection.
  Future<void> stop();
}

/// [GcEventSource] over the screen's own VM service connection. It keeps
/// the events of this isolate only, because the VM posts each collection
/// once for every isolate of the group.
class VmServiceGcEventSource implements GcEventSource {
  VmServiceGcEventSource({
    @visibleForTesting Future<Uri?> Function()? serviceUri,
    @visibleForTesting Future<VmService> Function(String uri)? connect,
  }) : _serviceUri = serviceUri ?? _vmServiceUri,
       _connect = connect ?? vmServiceConnectUri;

  final Future<Uri?> Function() _serviceUri;
  final Future<VmService> Function(String uri) _connect;
  VmService? _service;
  StreamSubscription<Object?>? _subscription;

  // Set by [stop]. A start still connecting when the leg ends checks it
  // after each await and closes what it opened, so no connection or
  // listener outlives the leg, and a late event never reaches a log a
  // later leg owns.
  bool _stopped = false;

  static Future<Uri?> _vmServiceUri() async =>
      (await Service.getInfo()).serverWebSocketUri;

  @override
  Future<void> start(void Function(DateTime at, String? gcType) onEvent) async {
    final uri = await _serviceUri();
    if (_stopped) return;
    if (uri == null) {
      throw StateError('the VM service is not available');
    }
    final service = await _connect(uri.toString());
    if (_stopped) {
      await service.dispose();
      return;
    }
    _service = service;
    final ownId = Service.getIsolateId(Isolate.current);
    _subscription = service.onGCEvent.listen((event) {
      if (_stopped) return;
      final read = readGcEvent(event, ownId);
      if (read.own) onEvent(DateTime.now(), read.gcType);
    });
    await service.streamListen(EventStreams.kGC);
  }

  /// Whether [event] belongs to the isolate [ownIsolateId], and its
  /// `gcType` from the raw payload (the field `Event` does not model).
  static ({bool own, String? gcType}) readGcEvent(
    Event event,
    String? ownIsolateId,
  ) => (
    own: ownIsolateId != null && event.isolate?.id == ownIsolateId,
    gcType: event.json?['gcType'] as String?,
  );

  @override
  Future<void> stop() async {
    _stopped = true;
    await _subscription?.cancel();
    _subscription = null;
    final service = _service;
    _service = null;
    await service?.dispose();
  }
}

/// Allocates short-lived garbage every 25 ms in batches of [batch] small
/// maps, each holding a 100-element list.
class ChurnAllocator {
  Timer? _timer;

  /// Maps per 25 ms tick.
  int batch = 0;

  /// Items allocated so far. Writing it keeps the allocation alive for
  /// the compiler, which may otherwise drop an object nothing reads.
  int allocated = 0;

  /// Whether the timer runs.
  bool get running => _timer != null;

  /// Starts the timer at [batch] maps per tick.
  void start(int batch) {
    this.batch = batch;
    _timer ??= Timer.periodic(const Duration(milliseconds: 25), (_) => tick());
  }

  /// Allocates one batch.
  @visibleForTesting
  void tick() {
    final garbage = List.generate(
      batch,
      (i) => <String, Object>{'i': i, 'data': List.filled(100, i)},
    );
    allocated += garbage.length;
  }

  /// Stops the timer.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}

/// Batch size that should move [measured] young collections per 10 s to
/// [target], stepping [batch] by at most 30 % either way. With no
/// measured collection the batch grows by 30 %, from at least
/// [minGrowFrom] maps.
int nextChurnBatch({
  required int batch,
  required double measured,
  required int target,
  int minGrowFrom = 50,
  int maxBatch = _maxBatch,
}) {
  if (measured <= 0) {
    return (math.max(batch, minGrowFrom) * 1.3).round().clamp(0, maxBatch);
  }
  final factor = (target / measured).clamp(0.7, 1.3);
  return (batch * factor).round().clamp(0, maxBatch);
}

/// Batch size for [target] young collections per 10 s from a
/// calibration that measured [ambient] with no allocation and
/// [atSeed] with [seedBatch] maps per tick. Zero when the ambient rate
/// alone reaches the target.
int calibratedChurnBatch({
  required double ambient,
  required double atSeed,
  required int seedBatch,
  required int target,
  int maxBatch = _maxBatch,
}) {
  final needed = target - ambient;
  if (needed <= 0) return 0;
  final perBatch = (atSeed - ambient) / seedBatch;
  if (perBatch <= 0) return maxBatch;
  return (needed / perBatch).round().clamp(0, maxBatch);
}

const _maxBatch = 20000;

/// One gc_pressure leg and its target young-collection count per 10 s.
enum GcPressureLeg {
  below(target: 25),
  at(target: 50),
  above(target: 80);

  const GcPressureLeg({required this.target});

  /// Young collections per 10 s the leg holds.
  final int target;

  /// `below`, `at` or `above`.
  String get label => name;

  /// Scenario name, which is also the capture's file basename.
  String get scenario => 'gc_pressure_$label';

  /// The leg's button label.
  String get buttonLabel =>
      '${label[0].toUpperCase()}${label.substring(1)}: $target young GCs '
      'in 10 s';
}

/// The bracket every leg is judged against, read from [metadata] (the
/// detector's `validationMetadata`).
CaptureBracket? gcPressureBracket(DetectorMetadata metadata) =>
    CaptureBracket.fromMetadata(
      metadata,
      stableId: 'gc_pressure',
      severityLabel: 'warning',
    );

/// The `expectedMagnitude` band a [role] leg exports against [bracket]:
/// below `[1, threshold - 1]`, at `[threshold, atUpper]`, above
/// `[atUpper, aboveCeiling]`. The schema rejects a bound at or below 0.
({double min, double max}) gcPressureBand(
  CaptureBracket bracket,
  String role,
) => switch (role) {
  'below' => (min: 1, max: bracket.threshold - 1),
  'at' => (min: bracket.threshold, max: bracket.atUpper),
  _ => (min: bracket.atUpper, max: bracket.aboveCeiling),
};

// Leg phases.
const _ambientWindow = Duration(seconds: 4);
const _calibrationWindow = Duration(seconds: 4);
const _settle = Duration(milliseconds: 1500);
const _span = Duration(seconds: 13);
const _gcWindow = Duration(seconds: 10);
// The closed loop reads the last 2 s of young collections, scaled to 10 s.
const _loopWindow = Duration(seconds: 2);
const _seedBatch = 1000;
const _maxAttemptsPerLeg = 5;

/// A leg stopped before its export, with the verdict to log.
class _LegStopped implements Exception {
  const _LegStopped(this.verdict, this.reason);

  final String verdict;
  final String reason;
}

class _GcPressureCaptureScreenState extends State<GcPressureCaptureScreen> {
  bool _busy = false;
  GcPressureLeg? _attemptLeg;
  int _attempts = 0;
  GcPressureLeg? _stashedLeg;
  String? _stashedJson;
  final List<String> _log = [];
  String _status = 'Idle.';

  // The last leg's final log line, announced once when the leg ends.
  String? _outcome;

  late final CaptureProvenanceCheck _provenance;
  late final ChurnAllocator _allocator;

  // The bracket threshold, read from the detector's metadata for the
  // description so its number cannot drift from the audit.
  late final int? _firesAt;
  late final AppLifecycleListener _lifecycle;
  final YoungGcLog _youngGcs = YoungGcLog();

  // The resources a leg owns. They are fields, not locals, so dispose can
  // end the scenario, restore the streams, stop the allocator and close
  // the GC feed while the leg still awaits.
  GcEventSource? _feed;
  String? _openScenario;
  bool _streamsSuspended = false;
  bool _readsHeld = false;
  String? _stopReason;

  bool get _captureModeOn =>
      widget.captureModeOverride ??
      const bool.fromEnvironment('SLEUTH_CAPTURE_MODE');

  @override
  void initState() {
    super.initState();
    _provenance = widget.provenanceCheck();
    _firesAt = gcPressureBracket(
      MemoryPressureDetector().validationMetadata,
    )?.threshold.round();
    _allocator = widget.allocator ?? ChurnAllocator();
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        if (_busy && state != AppLifecycleState.resumed) {
          _stopReason ??= 'the app left the foreground ($state)';
        }
      },
    );
  }

  @override
  void dispose() {
    // A running leg may be awaiting a phase, the flush or the export.
    // Release what it owns now, so nothing lands inside another capture's
    // span, and let the leg stop at its next check.
    _stopReason ??= 'the screen closed';
    _allocator.stop();
    _endScenario(log: false);
    unawaited(_resumeStreams(log: false));
    _releaseReads();
    unawaited(_stopFeed());
    _lifecycle.dispose();
    super.dispose();
  }

  void _say(String line) {
    if (!mounted) return;
    setState(() => _log.add(line));
  }

  void _setStatus(String status) {
    if (!mounted) return;
    setState(() => _status = status);
  }

  /// Ends the leg's open scenario once. A throw is logged, not rethrown,
  /// so it cannot replace the leg's outcome.
  void _endScenario({String label = '', bool log = true}) {
    final scenario = _openScenario;
    if (scenario == null) return;
    _openScenario = null;
    try {
      widget.calls.markScenarioEnd(scenario);
    } catch (e) {
      if (log) _say('[$label] markScenarioEnd: $e');
    }
  }

  /// Restores the timeline streams once, bounded so an unanswered VM call
  /// cannot keep the screen busy.
  Future<void> _resumeStreams({String label = '', bool log = true}) async {
    if (!_streamsSuspended) return;
    _streamsSuspended = false;
    try {
      await withCallTimeout(
        widget.calls.resumeStreams(),
        'resumeAllTimelineStreams',
      );
    } catch (e) {
      if (log) _say('[$label] resumeAllTimelineStreams: $e');
    }
  }

  void _releaseReads() {
    if (!_readsHeld) return;
    _readsHeld = false;
    Sleuth.releaseAllocationProfileReads();
  }

  Future<void> _stopFeed() async {
    final feed = _feed;
    _feed = null;
    try {
      await feed?.stop();
    } catch (_) {
      // The connection is going away either way.
    }
  }

  /// Waits [duration] in 1 s steps, calling [eachSecond] after each, and
  /// stops the leg when the screen closed or the app left the foreground.
  Future<void> _hold(Duration duration, void Function() eachSecond) async {
    var left = duration;
    while (left > Duration.zero) {
      final step = left < const Duration(seconds: 1)
          ? left
          : const Duration(seconds: 1);
      await Future<void>.delayed(step);
      left -= step;
      final reason = _stopReason;
      if (reason != null) throw _LegStopped('UNMEASURED', reason);
      eachSecond();
    }
  }

  /// Young collections per 10 s over the last [window], from the screen's
  /// own count.
  double _ratePer10s(Duration window) =>
      _youngGcs.countSince(DateTime.now().subtract(window)) *
      (_gcWindow.inMilliseconds / window.inMilliseconds);

  String _detectorYoung() {
    final young = Sleuth.memoryPressureDetector?.gcWindowStats.young;
    return young == null ? 'n/a' : '$young';
  }

  Future<void> _runLeg(GcPressureLeg leg) async {
    if (_busy) return;
    final label = leg.label;
    if (!_captureModeOn) {
      _say(
        '[$label] ABORT: capture mode is off. Relaunch with '
        '--dart-define=SLEUTH_CAPTURE_MODE=true.',
      );
      return;
    }
    if (!widget.vmConnected()) {
      _say(
        '[$label] ABORT: VM service not connected. Run a profile build '
        'with --no-dds so Sleuth can attach.',
      );
      return;
    }
    final refusal = provenanceRefusal(label, check: widget.provenanceCheck);
    if (refusal != null) {
      _say(refusal);
      return;
    }
    final bracket = gcPressureBracket(
      MemoryPressureDetector().validationMetadata,
    );
    if (bracket == null) {
      _say(
        '[$label] ABORT: MemoryPressureDetector declares no gc_pressure '
        'warning bracket.',
      );
      return;
    }
    if (_attemptLeg != leg) _attempts = 0;
    if (_attempts >= _maxAttemptsPerLeg) {
      _say(
        '[$label] $_maxAttemptsPerLeg attempts used. Switch leg or restart '
        'the app.',
      );
      return;
    }
    _attempts++;
    _attemptLeg = leg;
    _stopReason = null;
    _youngGcs.clear();
    setState(() {
      _busy = true;
      _stashedLeg = null;
      _stashedJson = null;
      _outcome = null;
      _status = 'Preparing streams, allocation reads and the GC feed';
      _log.add(
        '[$label] attempt $_attempts/$_maxAttemptsPerLeg: target '
        '${leg.target} young GCs in 10 s, band '
        '${bracket.bandText(label)}',
      );
    });

    try {
      // Only the Dart timeline stream during the leg, as the other capture
      // screens do. The flag is set before the call, because a suspension
      // that times out may still land later.
      _streamsSuspended = true;
      await withCallTimeout(
        widget.calls.suspendStreams(),
        'suspendNonEssentialTimelineStreams',
      );
      if (!mounted) return;
      // Sleuth's allocation-profile reads allocate on this isolate; held,
      // they cannot add collections to the count.
      _readsHeld = true;
      if (!await Sleuth.holdAllocationProfileReads()) {
        _say(
          '[$label] note: Sleuth\'s allocation-profile reads are held '
          'without a confirmed drain.',
        );
      }
      if (!mounted) return;

      final feed = _feed = widget.gcEvents();
      await withCallTimeout(
        // Only the current leg's feed writes to the log.
        feed.start((at, gcType) {
          if (identical(_feed, feed)) _youngGcs.add(at, gcType);
        }),
        'GC stream',
      );
      if (!mounted) return;

      _setStatus('Measuring ambient young GCs (4 s)');
      final ambientFrom = DateTime.now();
      await _hold(_ambientWindow, () {});
      final ambient =
          _youngGcs.countSince(ambientFrom) *
          (_gcWindow.inMilliseconds / _ambientWindow.inMilliseconds);

      _setStatus('Calibrating at $_seedBatch maps per tick (4 s)');
      final seedFrom = DateTime.now();
      _allocator.start(_seedBatch);
      await _hold(_calibrationWindow, () {});
      _allocator.stop();
      final atSeed =
          _youngGcs.countSince(seedFrom) *
          (_gcWindow.inMilliseconds / _calibrationWindow.inMilliseconds);
      var batch = calibratedChurnBatch(
        ambient: ambient,
        atSeed: atSeed,
        seedBatch: _seedBatch,
        target: leg.target,
      );
      _say(
        '[$label] ambient ${ambient.toStringAsFixed(1)}, '
        '${atSeed.toStringAsFixed(1)} at $_seedBatch maps per tick; '
        'starting at $batch',
      );
      await _hold(_settle, () {});

      final spanFrom = DateTime.now();
      widget.calls.markScenarioBegin(leg.scenario);
      _openScenario = leg.scenario;
      if (batch > 0) _allocator.start(batch);
      var elapsed = 0;
      await _hold(_span, () {
        elapsed++;
        batch = nextChurnBatch(
          batch: batch,
          measured: _ratePer10s(_loopWindow),
          target: leg.target,
        );
        if (batch > 0) {
          _allocator.start(batch);
        } else {
          _allocator.stop();
        }
        _setStatus(
          'Span $elapsed/${_span.inSeconds} s: screen counts '
          '${_youngGcs.countSince(DateTime.now().subtract(_gcWindow))}, '
          'detector ${_detectorYoung()} young GCs in 10 s; batch $batch',
        );
      });
      _allocator.stop();

      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (!mounted) return;
      await widget.calls.flushTimeline();
      if (!mounted) return;
      _endScenario(label: label);
      final spanTo = DateTime.now();
      await _stopFeed();
      final peak = _youngGcs.peakIn(_gcWindow, from: spanFrom, to: spanTo);
      _say('[$label] screen peak $peak young GCs in 10 s');

      final measured = measurementRefusal(
        peak,
        role: label,
        bracket: bracket,
        what: 'young GC peak',
        unit: 'young GCs in 10 s',
      );
      if (measured != null) {
        throw _LegStopped(measured.verdict, measured.reason);
      }

      // The end marker must reach the VM buffer before the export reads it.
      await Future<void>.delayed(const Duration(milliseconds: 800));
      if (!mounted) return;
      await _resumeStreams(label: label);
      if (!mounted) return;

      _setStatus('Composing the capture');
      final provenance = requireCaptureProvenance(
        check: widget.provenanceCheck,
      );
      final band = gcPressureBand(bracket, label);
      String? json;
      String? composeFailure;
      try {
        json = await withCallTimeout(
          Sleuth.exportCaptureJson(
            scenario: leg.scenario,
            role: label,
            magnitudeMin: band.min,
            magnitudeObserved: peak.toDouble(),
            magnitudeMax: band.max,
            unit: 'gcevents',
            device: provenance.device,
            deviceOsVersion: provenance.deviceOsVersion,
            flutterVersion: provenance.flutterVersion,
            captureCommand: provenance.captureCommand,
            bracketStableId: 'gc_pressure',
            bracketSeverityLabel: 'warning',
            // The count comes from the GC stream, not a timeline event.
            magnitudeSourceEventName: '',
          ),
          'exportCaptureJson',
        );
        if (json == null) {
          composeFailure =
              Sleuth.lastCaptureExportFailure ??
              'exportCaptureJson gave no reason';
        }
      } catch (e) {
        composeFailure = '$e';
      }
      if (!mounted) return;
      if (json == null) {
        _say('[$label] capture FAILED to compose: $composeFailure');
        return;
      }
      final check = checkCaptureJson(
        json,
        bracket: bracket,
        role: label,
        observed: peak,
        unit: 'gcevents',
      );
      final exportRefusal = recordRefusal(check, role: label, bracket: bracket);
      if (exportRefusal != null) {
        _say('[$label] ${exportRefusal.verdict}: ${exportRefusal.reason}');
        return;
      }
      final stashed = json;
      setState(() {
        _stashedLeg = leg;
        _stashedJson = stashed;
        _attemptLeg = null;
        _log.add(
          '[$label] capture stashed (${stashed.length} chars). Tap '
          '"Export last leg" to copy it.',
        );
      });
    } on _LegStopped catch (e) {
      _say('[$label] ${e.verdict}: ${e.reason}');
    } on CaptureProvenanceUnavailable catch (e) {
      _say('[$label] ABORT: capture provenance: ${e.problem}.');
    } catch (e) {
      // A flush past its 2 s limit, a VM call past its limit, or any other
      // failure still ends the leg with an outcome line.
      _say('[$label] FAILED: $e. Tap the leg again.');
    } finally {
      final verdictLines = _log.length;
      _allocator.stop();
      // All of these are no-ops when the leg or dispose already did them.
      _endScenario(label: label);
      await _stopFeed();
      await _resumeStreams(label: label);
      _releaseReads();
      if (mounted) {
        setState(() {
          _busy = false;
          _status = 'Idle.';
          _outcome = _lastLegLine(label, upTo: verdictLines);
        });
      }
    }
  }

  /// The leg's last line among the first [upTo] log lines, without its
  /// `[label]` prefix, for the announced outcome line. The leg passes the
  /// log length before its cleanup, so a cleanup error stays in the log
  /// and does not replace the verdict.
  String? _lastLegLine(String label, {required int upTo}) {
    final prefix = '[$label] ';
    for (final line in _log.take(upTo).toList().reversed) {
      if (line.startsWith(prefix)) {
        return 'Last leg ($label): ${line.substring(prefix.length)}';
      }
    }
    return null;
  }

  Future<void> _exportLastLeg() async {
    final leg = _stashedLeg;
    final json = _stashedJson;
    if (leg == null || json == null) {
      _say('Export: no stashed leg. Run a leg until "capture stashed".');
      return;
    }
    try {
      await Clipboard.setData(ClipboardData(text: json));
      _say(
        '[${leg.label}] copied ${json.length} chars. Save as '
        '${leg.scenario}.json under test/validation/captures/gc_pressure/.',
      );
    } catch (e) {
      _say('[${leg.label}] clipboard copy FAILED: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final capture = Sleuth.diagnoseCaptureState();
    final ready = _captureModeOn && _provenance.provenance != null && !_busy;
    final stamp = _provenance.provenance;
    return Scaffold(
      appBar: AppBar(title: const Text('gc_pressure capture')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          // Export, the status and the outcome stay in view below the
          // controls on a tall body.
          child: CaptureBodyLayout(
            controlsShare: 0.55,
            controls: [
              CapturePreflightBanner(
                captureMode: capture.captureMode,
                vmConnected: capture.vmConnected,
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
              Text(
                'Allocates short-lived garbage to hold a young-GC rate, '
                'counts the collections itself, and records the gc_pressure '
                'warning, which fires at ${_firesAt ?? '?'} young GCs in '
                '10 s.',
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              for (final leg in GcPressureLeg.values)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: FilledButton.tonal(
                    onPressed: ready ? () => _runLeg(leg) : null,
                    child: Text(leg.buttonLabel),
                  ),
                ),
            ],
            pinned: [
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: _busy ? null : _exportLastLeg,
                icon: const Icon(Icons.save_alt),
                label: const Text('Export last leg'),
              ),
              const SizedBox(height: 8),
              Text(
                _status,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              // Three lines at most so a large text scale cannot push the
              // log off the screen; the log keeps the full line.
              if (_outcome != null)
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _outcome!,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
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
