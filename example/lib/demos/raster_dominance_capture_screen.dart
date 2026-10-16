import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:sleuth/sleuth.dart';
// The detector is not exported; the screen reads its bracket, ratio, floor
// and startup window from the detector's own defaults so they cannot drift
// from the audit.
// ignore: implementation_imports
import 'package:sleuth/src/detectors/gpu_pressure_detector.dart'
    show GpuPressureDetector;

import 'capture_driver.dart';

/// Capture helper for the `runtimeVerified` brackets on
/// `GpuPressureDetector.raster_dominance`: a warning at 3 raster-dominant
/// frames inside one second, critical at 10. A frame is raster-dominant
/// when its UI time is above 0 and its raster time is above the 16.7 ms
/// frame budget, above 8 ms and above 2 times its UI time.
///
/// Each leg draws a prerecorded picture of [rasterLegPaths] stroked cubic
/// paths on a run of consecutive frames. The raster thread tessellates the
/// picture again on every frame it is shown, so each such frame costs the
/// raster thread far more than the UI thread. The frame after the run
/// hides the picture. It, or the next frame drawn within
/// [rasterRunTailUs] of it, can still be dominant, because its raster time
/// includes waiting for the GPU to finish the heavy frames, so those
/// frames belong to the run ([inRasterRun]).
///
/// The screen judges every frame of the span itself from its own
/// `FrameTiming` listener with the detector's rule ([isRasterDominant]) and
/// counts the dominant frames in the busiest one-second span
/// ([busiestSpanCount]). A leg is exported only when no dominant frame
/// falls outside the run, the count lands in the leg's band, and the most
/// the detector stamped as `observedDominantFrames` equals the count.
///
/// **Procedure per leg:**
///
///   1. `cd example && fvm flutter run --profile --no-dds -d "iPhone 12" \
///         --dart-define=SLEUTH_CAPTURE_MODE=true \
///         --dart-define=SLEUTH_CAPTURE_DEVICE="iPhone 12"`. The VM
///      service must be connected (VM+), because the export reads the
///      detector's records from the VM timeline.
///   2. Open Capture Helpers, then GpuPressure (raster_dominance), in
///      portrait at the default text size. Check that the refresh-rate
///      line shows 60 Hz and the provenance line names the device, OS and
///      Flutter version. A red banner lists a missing capture mode, VM
///      link or provenance; any other reason a leg cannot start shows in
///      the status line under the box when you tap it.
///   3. Wait 3 s after the screen opens, tap a leg and wait for its result
///      line. A refused attempt says why; tap the leg again.
///   4. Tap **Export last leg** and save the clipboard text as
///      `<scenario>.json` under `test/validation/captures/gpu_pressure/`.
class RasterDominanceCaptureScreen extends StatefulWidget {
  const RasterDominanceCaptureScreen({
    super.key,
    this.captureModeOverride,
    this.provenanceCheck = currentCaptureProvenance,
    this.calls = const RasterLegCalls(),
    this.frameNumber = _engineFrameNumber,
    this.clock,
    this.timing = const RasterLegTiming(),
  });

  /// Capture mode for tests. Null reads the build's
  /// `SLEUTH_CAPTURE_MODE` dart-define.
  @visibleForTesting
  final bool? captureModeOverride;

  /// Where the screen reads the provenance its exports stamp.
  @visibleForTesting
  final CaptureProvenanceCheck Function() provenanceCheck;

  /// The Sleuth calls a leg makes.
  @visibleForTesting
  final RasterLegCalls calls;

  /// The engine's number for the frame being drawn, read in a post-frame
  /// callback.
  @visibleForTesting
  final int Function() frameNumber;

  /// The clock behind the quiet-start check and the result's age.
  @visibleForTesting
  final DateTime Function()? clock;

  /// The waits a leg makes.
  @visibleForTesting
  final RasterLegTiming timing;

  @override
  State<RasterDominanceCaptureScreen> createState() =>
      _RasterDominanceCaptureScreenState();
}

int _engineFrameNumber() =>
    ui.PlatformDispatcher.instance.frameData.frameNumber;

/// Frame budget the legs judge against. The pre-flight requires a 60 Hz
/// display, and capture mode keeps the detector's budget fixed at the same
/// 16,667 µs.
const int rasterCaptureBudgetUs = 16667;

/// Stroked cubic paths in the leg picture. On an iPhone 12 with Impeller
/// on Metal, 700 such paths in the workload box cost the raster thread 28
/// to 80 ms a frame against under 6 ms of UI.
const int rasterLegPaths = 700;

/// How long after the hide frame's vsync a dominant frame still belongs to
/// the run. On an iPhone 12 the frame drawn after the hide frame waited 50
/// to 83 ms for the GPU (22 to 58 ms of raster against under 1 ms of UI).
const int rasterRunTailUs = 250000;

/// Cubic segments per path.
const int rasterPathSegments = 60;

/// Size of the workload box, in logical pixels. A centered box this wide
/// stays clear of the Sleuth trigger on a 390 pt wide phone.
const Size rasterBoxSize = Size(224, 112);

/// Time the screen's route must have been current and still before a leg
/// or a burst starts. The first scan after a route change clears the
/// detector's held frames, and the scan interval is at most 2 s.
const Duration rasterRouteSettle = Duration(seconds: 3);

// Attempts per leg before the screen asks for a restart.
const _maxAttemptsPerLeg = 5;

// The brackets are calibrated on a 60 Hz display.
const _expected60HzMin = 59.0;
const _expected60HzMax = 61.0;

/// The waits a leg makes. Tests shorten them.
@immutable
class RasterLegTiming {
  const RasterLegTiming({
    this.settle = const Duration(milliseconds: 500),
    this.runTimeout = const Duration(seconds: 5),
    this.hideTimingTimeout = const Duration(seconds: 2),
    this.dwell = const Duration(milliseconds: 3500),
    this.endBarrier = const Duration(milliseconds: 800),
    this.restoreRetry = const Duration(milliseconds: 500),
    this.attemptLimit = const Duration(seconds: 30),
    this.burstTail = const Duration(milliseconds: 300),
    this.frontCheck = const Duration(milliseconds: 100),
    this.routeSettle = rasterRouteSettle,
    this.suspendWait = const Duration(seconds: 5),
  });

  /// Idle time after `markScenarioBegin` before the run starts.
  final Duration settle;

  /// Longest the run may take to draw.
  final Duration runTimeout;

  /// Longest the screen waits for the hide frame's timing. Profile builds
  /// report timings in batches about every 100 ms.
  final Duration hideTimingTimeout;

  /// Wait after the hide frame's timing, so a scan (at most 2 s apart)
  /// writes the record that holds the whole run.
  final Duration dwell;

  /// Wait after `markScenarioEnd`, so the end marker reaches the VM buffer
  /// before the export reads it.
  final Duration endBarrier;

  /// Pause between stream restore attempts.
  final Duration restoreRetry;

  /// Longest one attempt may run.
  final Duration attemptLimit;

  /// Wait after the hide frame's timing in a burst outside a leg, for the
  /// frames that follow it.
  final Duration burstTail;

  /// How often a running leg checks that the screen is in front.
  final Duration frontCheck;

  /// See [rasterRouteSettle].
  final Duration routeSettle;

  /// Longest a restore waits for a suspension the VM has not answered.
  final Duration suspendWait;
}

/// The Sleuth calls a leg makes, behind one seam for tests.
class RasterLegCalls {
  const RasterLegCalls();

  /// Whether the VM accepted the narrowed stream list.
  Future<bool> suspendStreams() => Sleuth.suspendNonEssentialTimelineStreams();

  /// Whether the VM accepted the restored stream list.
  Future<bool> resumeStreams() => Sleuth.resumeAllTimelineStreams();

  Future<void> flushTimeline() =>
      Sleuth.flushTimelineNow(timeout: const Duration(seconds: 2));

  void markScenarioBegin(String scenario) => Sleuth.markScenarioBegin(scenario);

  void markScenarioEnd(String scenario) => Sleuth.markScenarioEnd(scenario);

  bool vmConnected() => Sleuth.diagnoseCaptureState().vmConnected;

  /// Whether Sleuth's dashboard card is open over the app.
  bool dashboardOpen() => Sleuth.overlayUiState?.dashboardOpen ?? false;

  /// `Timeline.now` at Dart entry, or null without `Sleuth.init`.
  int? dartEntryMonotonicUs() => Sleuth.dartEntryMonotonicUs;

  int timelineNowUs() => developer.Timeline.now;

  String? lastExportFailure() => Sleuth.lastCaptureExportFailure;

  Future<String?> exportCapture({
    required RasterLeg leg,
    required ({double min, double max}) band,
    required int observed,
    required CaptureProvenance provenance,
    required String captureNotes,
  }) => Sleuth.exportCaptureJson(
    scenario: leg.scenario,
    role: leg.role,
    magnitudeMin: band.min,
    magnitudeObserved: observed,
    magnitudeMax: band.max,
    unit: 'frames',
    device: provenance.device,
    deviceOsVersion: provenance.deviceOsVersion,
    flutterVersion: provenance.flutterVersion,
    captureCommand: provenance.captureCommand,
    captureNotes: captureNotes,
    bracketStableId: 'raster_dominance',
    bracketSeverityLabel: leg.tier,
    // The count comes from FrameTiming, not a VM timeline event.
    magnitudeSourceEventName: '',
  );
}

/// One frame as the screen judges it.
typedef RasterFrame = ({int number, int vsyncUs, int uiUs, int rasterUs});

/// [timing] as the screen judges it: UI is the build duration and raster
/// the raster duration, as `FrameStats` carries them.
RasterFrame rasterFrameOf(FrameTiming timing) => (
  number: timing.frameNumber,
  vsyncUs: timing.timestampInMicroseconds(ui.FramePhase.vsyncStart),
  uiUs: timing.buildDuration.inMicroseconds,
  rasterUs: timing.rasterDuration.inMicroseconds,
);

/// Whether a frame with [uiUs] of UI time and [rasterUs] of raster time is
/// raster-dominant by the detector's rule: both above 0, raster above
/// [budgetUs], above [floorUs] and above [ratio] times UI, each strictly.
bool isRasterDominant({
  required int uiUs,
  required int rasterUs,
  int budgetUs = rasterCaptureBudgetUs,
  int? floorUs,
  double? ratio,
}) {
  final floor = floorUs ?? _detectorDefaults.maxFrameRasterFloorUs;
  final r = ratio ?? _detectorDefaults.rasterMultiplierThreshold;
  if (uiUs <= 0 || rasterUs <= 0) return false;
  if (rasterUs <= budgetUs) return false;
  if (rasterUs <= floor) return false;
  return rasterUs > r * uiUs;
}

final GpuPressureDetector _detectorDefaults = GpuPressureDetector();

/// The busiest half-open one-second span of [dominant] by vsync start, as
/// the detector counts it: frames sorted by vsync (arrival order on ties),
/// and a frame leaves the span once a later one starts a full second or
/// more after it. Returns the count and the span's first and last vsync.
({int count, int? firstUs, int? lastUs}) busiestSpanCount(
  List<RasterFrame> dominant,
) {
  if (dominant.isEmpty) return (count: 0, firstUs: null, lastUs: null);
  final order = [for (var i = 0; i < dominant.length; i++) i]
    ..sort((a, b) {
      final byVsync = dominant[a].vsyncUs.compareTo(dominant[b].vsyncUs);
      return byVsync != 0 ? byVsync : a.compareTo(b);
    });
  var best = 0;
  var bestLeft = 0;
  var bestRight = 0;
  var left = 0;
  for (var right = 0; right < order.length; right++) {
    final rightUs = dominant[order[right]].vsyncUs;
    while (rightUs - dominant[order[left]].vsyncUs >= 1000000) {
      left++;
    }
    final count = right - left + 1;
    if (count >= best) {
      best = count;
      bestLeft = left;
      bestRight = right;
    }
  }
  return (
    count: best,
    firstUs: dominant[order[bestLeft]].vsyncUs,
    lastUs: dominant[order[bestRight]].vsyncUs,
  );
}

/// `1 heavy frame`, `3 dominant frames` and so on.
String rasterFrameCount(int n, String kind) =>
    '$n $kind frame${n == 1 ? '' : 's'}';

/// One capture leg: its bracket tier, role and the heavy frames it draws.
///
/// A run of H heavy frames usually gives H or H + 1 dominant frames (the
/// hide frame or the next one waits for the GPU), and each leg's H keeps
/// both inside its band.
enum RasterLeg {
  below(tier: 'warning', role: 'below', heavyFrames: 1),
  at(tier: 'warning', role: 'at', heavyFrames: 3),
  above(tier: 'warning', role: 'above', heavyFrames: 6),
  criticalBelow(tier: 'critical', role: 'below', heavyFrames: 6),
  criticalAt(tier: 'critical', role: 'at', heavyFrames: 11),
  criticalAbove(tier: 'critical', role: 'above', heavyFrames: 20);

  const RasterLeg({
    required this.tier,
    required this.role,
    required this.heavyFrames,
  });

  /// `warning` or `critical`: the bracket the leg records.
  final String tier;

  /// `below`, `at` or `above`.
  final String role;

  /// Consecutive frames that show the picture.
  final int heavyFrames;

  /// Scenario name, which is also the capture's file basename.
  String get scenario => tier == 'warning'
      ? 'raster_dominance_$role'
      : 'raster_dominance_critical_$role';

  /// `at`, `critical at` and so on.
  String get label => tier == 'warning' ? role : 'critical $role';

  /// `At`, `Critical at` and so on.
  String get title => '${label[0].toUpperCase()}${label.substring(1)}';

  /// The leg button's text, unique per leg so a harness tap matches one.
  String get buttonLabel => '$title: ${rasterFrameCount(heavyFrames, 'heavy')}';
}

/// The bracket [tier] is judged against, read from [metadata] (the
/// detector's `validationMetadata`).
CaptureBracket? rasterBracket(DetectorMetadata metadata, String tier) =>
    CaptureBracket.fromMetadata(
      metadata,
      stableId: 'raster_dominance',
      severityLabel: tier,
    );

/// `expectedMagnitude` band for [role] under [bracket]: below (1, t − 1),
/// at [t, atUpper], above (atUpper, aboveCeiling].
({double min, double max}) rasterLegBand(CaptureBracket bracket, String role) =>
    switch (role) {
      'below' => (min: 1, max: bracket.threshold - 1),
      'at' => (min: bracket.threshold, max: bracket.atUpper),
      _ => (min: bracket.atUpper, max: bracket.aboveCeiling),
    };

/// The number of the first frame reported after the hide frame
/// [hideFrame] (drawn at [hideVsyncUs]) when it starts within
/// [rasterRunTailUs] of it, else null. That frame can wait for the GPU to
/// finish the heavy frames; a later one cannot belong to the run.
int? rasterContinuationFrame(
  List<RasterFrame> frames, {
  required int hideFrame,
  required int hideVsyncUs,
}) {
  RasterFrame? next;
  for (final f in frames) {
    if (f.number <= hideFrame) continue;
    if (next == null || f.number < next.number) next = f;
  }
  if (next == null) return null;
  final after = next.vsyncUs - hideVsyncUs;
  return after > 0 && after <= rasterRunTailUs ? next.number : null;
}

/// Whether [frame] belongs to the run that began with frame number
/// [firstHeavy] and ended with the hide frame [hideFrame]: numbered from
/// [firstHeavy] through [hideFrame], or the [continuationFrame] (see
/// [rasterContinuationFrame]).
bool inRasterRun(
  RasterFrame frame, {
  required int firstHeavy,
  required int hideFrame,
  required int? continuationFrame,
}) =>
    (frame.number >= firstHeavy && frame.number <= hideFrame) ||
    frame.number == continuationFrame;

/// Why a leg cannot be exported given what the screen saw, with the
/// screen's count when it got that far. [heavyFrames] are the engine frame
/// numbers of the frames that showed the picture, [hideFrame] the number
/// of the frame that hid it, and [frames] every frame the screen judged in
/// the span, in arrival order.
({LegRefusal? refusal, int? count}) rasterFrameRefusal(
  RasterLeg leg, {
  required List<int> heavyFrames,
  required int? hideFrame,
  required List<RasterFrame> frames,
  required CaptureBracket bracket,
  int budgetUs = rasterCaptureBudgetUs,
}) {
  if (heavyFrames.length != leg.heavyFrames || hideFrame == null) {
    return (
      refusal: (
        verdict: 'UNMEASURED',
        reason:
            '${heavyFrames.length} of '
            '${rasterFrameCount(leg.heavyFrames, 'heavy')} '
            'drew${hideFrame == null ? ' and the hide frame did not' : ''}',
      ),
      count: null,
    );
  }
  if (heavyFrames.any((n) => n < 0) || hideFrame < 0) {
    return (
      refusal: (
        verdict: 'UNMEASURED',
        reason: 'the engine gave no frame numbers, so frames cannot be mapped',
      ),
      count: null,
    );
  }
  final first = heavyFrames.first;
  final hideVsync = frames
      .where((f) => f.number == hideFrame)
      .map((f) => f.vsyncUs)
      .firstOrNull;
  if (hideVsync == null) {
    return (
      refusal: (
        verdict: 'UNMEASURED',
        reason: 'the hide frame #$hideFrame reported no timing',
      ),
      count: null,
    );
  }
  bool dominantFrame(RasterFrame f) =>
      isRasterDominant(uiUs: f.uiUs, rasterUs: f.rasterUs, budgetUs: budgetUs);
  // Every heavy frame must be dominant, so the run, not a frame around it,
  // sets the count: H heavy frames, plus at most the hide frame and the
  // frame after it.
  for (final n in heavyFrames) {
    final f = frames.where((f) => f.number == n).firstOrNull;
    if (f == null) {
      return (
        refusal: (
          verdict: 'UNMEASURED',
          reason: 'heavy frame #$n reported no timing',
        ),
        count: null,
      );
    }
    if (!dominantFrame(f)) {
      return (
        refusal: (
          verdict: 'UNMEASURED',
          reason:
              'heavy frame #$n was not raster-dominant (raster '
              '${(f.rasterUs / 1000).toStringAsFixed(1)} ms, UI '
              '${(f.uiUs / 1000).toStringAsFixed(1)} ms)',
        ),
        count: null,
      );
    }
  }
  final continuation = rasterContinuationFrame(
    frames,
    hideFrame: hideFrame,
    hideVsyncUs: hideVsync,
  );
  final dominant = [
    for (final f in frames)
      if (dominantFrame(f)) f,
  ];
  final ambient = [
    for (final f in dominant)
      if (!inRasterRun(
        f,
        firstHeavy: first,
        hideFrame: hideFrame,
        continuationFrame: continuation,
      ))
        f.number,
  ];
  if (ambient.isNotEmpty) {
    return (
      refusal: (
        verdict: 'OUT-OF-BAND',
        reason:
            '${rasterFrameCount(ambient.length, 'dominant')} outside the '
            'run (#$first to #$hideFrame and the next frame within '
            '${rasterRunTailUs ~/ 1000} ms): '
            '${ambient.map((n) => '#$n').join(', ')}',
      ),
      count: null,
    );
  }
  final count = busiestSpanCount(dominant).count;
  final measured = measurementRefusal(
    count,
    role: leg.role,
    bracket: bracket,
    what: 'dominant frames in one second',
    unit: 'frames',
  );
  return (refusal: measured, count: count);
}

/// Runs a burst outside a leg; `ext.sleuthDemo.rasterBurst` calls it on
/// the foreground screen.
abstract interface class RasterBurstRunner {
  /// Draws [frames] heavy frames of a [paths]-path picture and returns
  /// every frame's timing, the dominant flag at [budgetUs] and the
  /// busiest-span count, or `{error: ...}` when the screen refuses.
  Future<Map<String, Object?>> runBurst({
    required int frames,
    required int paths,
    required int budgetUs,
  });

  /// Whether a leg or burst runs, the last attempt's result and the
  /// stashed leg, for `ext.sleuthDemo.rasterState`.
  Map<String, Object?> harnessState();
}

/// Records [paths] stroked cubic paths across [size] in [color], from a
/// fixed seed, so every leg draws the same picture.
ui.Picture recordStrokePicture({
  required int paths,
  required Size size,
  required Color color,
}) {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Offset.zero & size);
  final paint = Paint()
    ..color = color.withAlpha(0xFF)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.5;
  final random = math.Random(7);
  double x() => random.nextDouble() * size.width;
  double y() => random.nextDouble() * size.height;
  for (var p = 0; p < paths; p++) {
    final path = Path()..moveTo(x(), y());
    for (var s = 0; s < rasterPathSegments; s++) {
      path.cubicTo(x(), y(), x(), y(), x(), y());
    }
    canvas.drawPath(path, paint);
  }
  return recorder.endRecording();
}

/// Fixed-width text for the counts and the frame log. iOS has no
/// 'monospace' family, so it falls back to Menlo or Courier; tabular
/// figures keep the padded columns lined up.
const TextStyle _monoStyle = TextStyle(
  fontFamily: 'monospace',
  fontFamilyFallback: ['Menlo', 'Courier'],
  fontFeatures: [FontFeature.tabularFigures()],
);

/// What a running attempt was stopped by.
typedef _Stop = ({String verdict, String reason});

class _RasterDominanceCaptureScreenState
    extends State<RasterDominanceCaptureScreen>
    with SingleTickerProviderStateMixin
    implements RasterBurstRunner {
  // One ticker for the State, started and stopped per run, because the
  // mixin allows only one `createTicker` call.
  late final Ticker _ticker;
  late final AppLifecycleListener _lifecycle;
  late final CaptureProvenanceCheck _provenance;
  final GlobalKey _boxKey = GlobalKey();

  bool _busy = false;
  double? _refreshRate;

  RasterLeg? _attemptLeg;
  int _attempts = 0;
  String _status = 'Idle. Tap a leg.';

  // The last attempt's evidence, shown first.
  ({
    RasterLeg leg,
    String line,
    int? screenCount,
    num? detectorMax,
    int? spanMs,
    DateTime at,
  })?
  _result;

  // The last stashed capture. Only a newer stashed leg replaces it.
  ({RasterLeg leg, String json, DateTime at})? _stash;

  final List<String> _log = [];

  // The picture and the run state.
  ui.Picture? _picture;
  int _picturePaths = 0;
  Color? _pictureColor;
  bool _showPicture = false;
  final ValueNotifier<int> _paintTick = ValueNotifier<int>(0);
  int _runTarget = 0;
  int _ticksRun = 0;
  final List<int> _heavyNumbers = [];
  int? _hideNumber;
  Completer<void>? _runDone;

  // Frames judged since the timings callback was registered.
  final List<RasterFrame> _frames = [];
  bool _timingsRegistered = false;

  // Quiet-start bookkeeping for the screen's route.
  ModalRoute<Object?>? _route;
  DateTime? _quietSince;

  // The scenario and stream state an attempt owns. They are fields, not
  // locals, so dispose can end the scenario and restore the streams while
  // the attempt still awaits.
  String? _openScenario;
  bool _streamsSuspended = false;
  // Whether this attempt's scenario has ended, after which an inactive
  // app (Control Center) no longer stops the export.
  bool _spanClosed = false;
  _Stop? _stop;
  Completer<void>? _stopSignal;
  Timer? _frontTimer;
  Timer? _limitTimer;

  bool get _captureModeOn =>
      widget.captureModeOverride ??
      const bool.fromEnvironment('SLEUTH_CAPTURE_MODE');

  DateTime _now() => (widget.clock ?? DateTime.now)();

  bool get _refreshRateOk {
    final rate = _refreshRate;
    return rate != null && rate >= _expected60HzMin && rate <= _expected60HzMax;
  }

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _provenance = widget.provenanceCheck();
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        if (state == AppLifecycleState.resumed) return;
        // Once the span has closed, a pulled-down Control Center
        // (inactive) no longer touches the measurement; only leaving the
        // app stops the export.
        if (state == AppLifecycleState.inactive && _spanClosed) return;
        _stopAttempt('UNMEASURED', 'the app left the foreground ($state)');
      },
    );
    // The display may not be known in initState on iOS.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final rate = View.maybeOf(context)?.display.refreshRate;
      setState(() {
        _refreshRate = rate;
        _log.add(
          rate == null
              ? 'Pre-flight: no view, so the refresh rate is unknown. '
                    'Re-open the screen.'
              : 'Pre-flight: ${rate.toStringAsFixed(1)} Hz, '
                    '${_refreshRateOk ? 'OK' : 'REJECTED: set the display to 60 Hz before a leg'}',
        );
      });
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (!identical(route, _route)) {
      _route?.animation?.removeStatusListener(_onRouteAnimation);
      _route?.secondaryAnimation?.removeStatusListener(_onRouteAnimation);
      _route = route;
      route?.animation?.addStatusListener(_onRouteAnimation);
      route?.secondaryAnimation?.addStatusListener(_onRouteAnimation);
      _onRouteAnimation(AnimationStatus.completed);
    }
    final color = Theme.of(context).colorScheme.surfaceContainer;
    if (color != _pictureColor) _recordPicture(_picturePaths, color);
  }

  /// Restarts the quiet period whenever the route or a route above it
  /// moves; the period runs while the route is fully in and nothing covers
  /// it.
  void _onRouteAnimation(AnimationStatus _) {
    final route = _route;
    final inFully =
        route == null ||
        (route.animation?.status ?? AnimationStatus.completed) ==
            AnimationStatus.completed;
    final uncovered =
        route == null ||
        (route.secondaryAnimation?.status ?? AnimationStatus.dismissed) ==
            AnimationStatus.dismissed;
    _quietSince = inFully && uncovered ? _now() : null;
  }

  void _recordPicture(int paths, Color? color) {
    final old = _picture;
    final c = color ?? _pictureColor;
    if (c == null) return;
    _pictureColor = c;
    _picturePaths = paths == 0 ? rasterLegPaths : paths;
    _picture = recordStrokePicture(
      paths: _picturePaths,
      size: rasterBoxSize,
      color: c,
    );
    // The frame in flight may still hold the old picture.
    if (old != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
  }

  @override
  void dispose() {
    // An attempt may be awaiting the run, a delay or the flush. End its
    // scenario and restore the streams now, so neither lands inside
    // another capture's span, and release its waits.
    _stopAttempt('UNMEASURED', 'the screen closed during the leg');
    _endScenario(log: false);
    unawaited(_restoreStreams(log: false));
    _frontTimer?.cancel();
    _limitTimer?.cancel();
    final run = _runDone;
    if (run != null && !run.isCompleted) run.complete();
    _route?.animation?.removeStatusListener(_onRouteAnimation);
    _route?.secondaryAnimation?.removeStatusListener(_onRouteAnimation);
    _lifecycle.dispose();
    _ticker.dispose();
    _stopTimings();
    _paintTick.dispose();
    _picture?.dispose();
    super.dispose();
  }

  void _stopAttempt(String verdict, String reason) {
    if (!_busy) return;
    _stop ??= (verdict: verdict, reason: reason);
    final signal = _stopSignal;
    if (signal != null && !signal.isCompleted) signal.complete();
  }

  /// Ends the attempt's open scenario once. A throw is logged, not
  /// rethrown, so it cannot replace the attempt's outcome.
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

  /// Restores the timeline streams, up to three tries, until the VM
  /// accepts the list. Returns whether it did; the obligation stays until
  /// then. A call made while one runs (dispose during the attempt's own
  /// restore) waits for that one instead of starting another.
  Future<bool> _restoreStreams({String label = '', bool log = true}) {
    if (!_streamsSuspended) return Future.value(true);
    return _restoring ??= _restoreOnce(
      label: label,
      log: log,
    ).whenComplete(() => _restoring = null);
  }

  Future<bool>? _restoring;

  // A suspension the VM has not answered yet. A restore waits for it, so
  // the suspension cannot land after the restore.
  Future<bool>? _pendingSuspend;

  void _clearPendingSuspend(Future<bool> suspend) {
    if (identical(_pendingSuspend, suspend)) _pendingSuspend = null;
  }

  Future<bool> _restoreOnce({required String label, required bool log}) async {
    final pending = _pendingSuspend;
    if (pending != null) {
      try {
        await pending.timeout(widget.timing.suspendWait);
      } catch (_) {
        // Still unanswered: restore once more when it lands, then go on.
        pending
            .then((_) => widget.calls.resumeStreams(), onError: (_) => false)
            .ignore();
      }
    }
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        final accepted = await withCallTimeout(
          widget.calls.resumeStreams(),
          'resumeAllTimelineStreams',
        );
        if (accepted) {
          _streamsSuspended = false;
          return true;
        }
        if (log) {
          _say('[$label] the VM did not restore the streams ($attempt/3)');
        }
      } catch (e) {
        if (log) _say('[$label] resumeAllTimelineStreams: $e ($attempt/3)');
      }
      if (attempt < 3) await _waitAny(const [], widget.timing.restoreRetry);
    }
    return false;
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      _frames.add(rasterFrameOf(timing));
    }
  }

  void _startTimings() {
    _frames.clear();
    if (_timingsRegistered) return;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _timingsRegistered = true;
  }

  // Removing an unregistered callback fails an assert in debug builds.
  void _stopTimings() {
    if (!_timingsRegistered) return;
    _timingsRegistered = false;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
  }

  void _onTick(Duration _) {
    final done = _runDone;
    if (done == null || done.isCompleted) return;
    if (_ticksRun < _runTarget) {
      _ticksRun++;
      _showPicture = true;
      _paintTick.value++;
      // The engine updates the frame number after the begin-frame
      // callbacks, so read it once the frame has drawn.
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _heavyNumbers.add(widget.frameNumber());
      });
      return;
    }
    _showPicture = false;
    _paintTick.value++;
    _ticker.stop();
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _hideNumber = widget.frameNumber();
      if (!done.isCompleted) done.complete();
    });
  }

  /// Completes when any of [futures] completes or [limit] passes, and
  /// cancels its timer either way, so no timer outlives the wait.
  Future<void> _waitAny(List<Future<void>> futures, Duration limit) {
    final done = Completer<void>();
    void finish([Object? _]) {
      if (!done.isCompleted) done.complete();
    }

    final timer = Timer(limit, finish);
    for (final f in futures) {
      f.then(finish, onError: finish);
    }
    return done.future.whenComplete(timer.cancel);
  }

  /// Waits for [d] or until the attempt is stopped.
  Future<void> _wait(Duration d) => _waitAny([?_stopSignal?.future], d);

  /// Waits until [test] holds, polling every 20 ms, for at most [limit].
  Future<bool> _waitUntil(bool Function() test, Duration limit) async {
    final sw = Stopwatch()..start();
    while (!test()) {
      if (_stop != null || sw.elapsed >= limit) return test();
      await _wait(const Duration(milliseconds: 20));
    }
    return true;
  }

  /// Draws [heavyFrames] frames with the picture and one without it.
  /// Returns false when the run did not finish within its limit.
  Future<bool> _drawRun(int heavyFrames) async {
    _heavyNumbers.clear();
    _hideNumber = null;
    _runTarget = heavyFrames;
    _ticksRun = 0;
    final done = _runDone = Completer<void>();
    _ticker.start();
    await _waitAny([
      done.future,
      ?_stopSignal?.future,
    ], widget.timing.runTimeout);
    if (_ticker.isActive) _ticker.stop();
    if (_showPicture) {
      _showPicture = false;
      _paintTick.value++;
    }
    return done.isCompleted && _hideNumber != null;
  }

  /// Why a leg or a burst cannot start now, or null.
  String? _quietStartProblem() {
    final route = _route;
    if (route != null && !route.isCurrent) {
      return 'another screen is on top of this one';
    }
    final since = _quietSince;
    if (since == null) return 'the screen is still moving in or covered';
    final quiet = _now().difference(since);
    if (quiet < widget.timing.routeSettle) {
      return 'the screen opened ${quiet.inMilliseconds} ms ago; wait '
          '${widget.timing.routeSettle.inSeconds} s so the route-change scan '
          'has run';
    }
    final state = WidgetsBinding.instance.lifecycleState;
    if (state != null && state != AppLifecycleState.resumed) {
      return 'the app is not in the foreground ($state)';
    }
    if (widget.calls.dashboardOpen()) {
      return 'the Sleuth dashboard is open over the screen; close it';
    }
    final entry = widget.calls.dartEntryMonotonicUs();
    final windowUs =
        (_detectorDefaults.startupPhaseWindowSeconds + 1) * 1000000;
    if (entry != null && widget.calls.timelineNowUs() - entry < windowUs) {
      return 'the app started under '
          '${_detectorDefaults.startupPhaseWindowSeconds + 1} s ago, inside '
          'the window where the detector ignores frames';
    }
    final box = _boxKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize || box.size != rasterBoxSize) {
      return 'the workload box is not laid out at '
          '${rasterBoxSize.width.toInt()} x ${rasterBoxSize.height.toInt()}';
    }
    final rect = box.localToGlobal(Offset.zero) & box.size;
    final screen = Offset.zero & MediaQuery.sizeOf(context);
    if (!screen.contains(rect.topLeft) || !screen.contains(rect.bottomRight)) {
      return 'the workload box is not fully on screen; hold the phone in '
          'portrait at the default text size';
    }
    return null;
  }

  /// Ends the attempt when the screen leaves the front: another route on
  /// top or moving, or the dashboard open.
  void _checkFront() {
    final route = _route;
    if (route != null &&
        (!route.isCurrent ||
            (route.secondaryAnimation?.status ?? AnimationStatus.dismissed) !=
                AnimationStatus.dismissed)) {
      _stopAttempt('UNMEASURED', 'another screen covered this one');
    } else if (widget.calls.dashboardOpen()) {
      _stopAttempt('UNMEASURED', 'the Sleuth dashboard opened');
    }
  }

  void _say(String line) {
    if (!mounted) return;
    setState(() => _log.add(line));
  }

  /// A tap refused before any attempt starts: the line goes to the log,
  /// the status line (which a screen reader announces) and
  /// `ext.sleuthDemo.rasterState`.
  void _refuse(String line) {
    if (!mounted) return;
    setState(() {
      _log.add(line);
      _status = line;
      _lastRefusal = line;
    });
  }

  // The last tap refused before an attempt started; cleared when one starts.
  String? _lastRefusal;

  /// Shows [message] in a SnackBar as well as the log, because the log can
  /// sit out of view and a screen reader does not announce it.
  void _confirm(String message) {
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 6)),
      );
  }

  /// The retry step for a refused or failed attempt, with the attempts
  /// left on this leg.
  String _retryHint() {
    final left = _maxAttemptsPerLeg - _attempts;
    return left > 0
        ? 'Tap the leg again ($left of $_maxAttemptsPerLeg attempts left).'
        : 'No attempts left on this leg; reopen the screen.';
  }

  void _finish(
    RasterLeg leg,
    String line, {
    int? count,
    num? detector,
    int? spanMs,
  }) {
    if (!mounted) return;
    setState(() {
      _status = 'Last leg (${leg.label}): $line';
      _result = (
        leg: leg,
        line: line,
        screenCount: count,
        detectorMax: detector,
        spanMs: spanMs,
        at: _now(),
      );
      _log.add('[${leg.label}] $line');
    });
  }

  Future<void> _runLeg(RasterLeg leg) async {
    if (_busy) return;
    final label = leg.label;
    if (!_captureModeOn) {
      _refuse(
        '[$label] ABORT: capture mode is off. Relaunch with '
        '--dart-define=SLEUTH_CAPTURE_MODE=true.',
      );
      return;
    }
    if (!widget.calls.vmConnected()) {
      _refuse(
        '[$label] ABORT: VM service not connected. Run a profile build '
        'with --no-dds so Sleuth can attach.',
      );
      return;
    }
    final refusal = provenanceRefusal(label, check: widget.provenanceCheck);
    if (refusal != null) {
      _refuse(refusal);
      return;
    }
    // Read again at every tap, so a display switched to 60 Hz in Settings
    // is picked up without reopening the screen.
    _refreshRate = View.maybeOf(context)?.display.refreshRate ?? _refreshRate;
    if (!_refreshRateOk) {
      _refuse(
        '[$label] ABORT: refresh rate is '
        '${_refreshRate?.toStringAsFixed(1) ?? 'unknown'} Hz, not 60 Hz. '
        'Set the display to 60 Hz, then tap the leg again.',
      );
      return;
    }
    final quiet = _quietStartProblem();
    if (quiet != null) {
      _refuse('[$label] ABORT: $quiet.');
      return;
    }
    final bracket = rasterBracket(
      GpuPressureDetector().validationMetadata,
      leg.tier,
    );
    if (bracket == null) {
      _refuse(
        '[$label] ABORT: GpuPressureDetector declares no raster_dominance '
        '${leg.tier} bracket.',
      );
      return;
    }
    if (_attemptLeg != leg) _attempts = 0;
    if (_attempts >= _maxAttemptsPerLeg) {
      _refuse(
        '[$label] $_maxAttemptsPerLeg attempts used. Let the phone idle, '
        'then reopen this screen or run another leg.',
      );
      return;
    }
    _attempts++;
    _attemptLeg = leg;
    if (_picturePaths != rasterLegPaths) {
      _recordPicture(rasterLegPaths, null);
    }
    _stop = null;
    _spanClosed = false;
    _stopSignal = Completer<void>();
    setState(() {
      _lastRefusal = null;
      _busy = true;
      _status =
          'Running ${leg.label}, attempt $_attempts of $_maxAttemptsPerLeg';
      _log.add(
        '[$label] attempt $_attempts/$_maxAttemptsPerLeg: '
        '${rasterFrameCount(leg.heavyFrames, 'heavy')} of $rasterLegPaths '
        'paths, band '
        '${bracket.bandText(leg.role)} frames',
      );
    });
    // Leaves the SnackBar out of the span instead of animating it out.
    ScaffoldMessenger.maybeOf(context)?.removeCurrentSnackBar();
    _limitTimer = Timer(widget.timing.attemptLimit, () {
      _stopAttempt(
        'FAILED',
        'the attempt ran past ${widget.timing.attemptLimit.inSeconds} s',
      );
    });

    var step = 'suspending the timeline streams';
    try {
      // The flag is set before the call, because a suspension that times
      // out may still land later.
      _streamsSuspended = true;
      final suspend = widget.calls.suspendStreams();
      _pendingSuspend = suspend;
      suspend.then(
        (_) => _clearPendingSuspend(suspend),
        onError: (Object _) => _clearPendingSuspend(suspend),
      );
      final narrowed = await withCallTimeout(
        suspend,
        'suspendNonEssentialTimelineStreams',
      );
      // An app that went inactive (Control Center) while the suspension was
      // pending has already stopped the attempt; it ends here, before its
      // scenario begins.
      if (!mounted || _stop != null) return;
      if (!narrowed) {
        _say('[$label] the VM kept every timeline stream on; continuing');
      }
      // Registered in the same synchronous block as markScenarioBegin, so
      // the screen and the detector judge the same timing batches.
      _startTimings();
      widget.calls.markScenarioBegin(leg.scenario);
      _openScenario = leg.scenario;
      _frontTimer = Timer.periodic(widget.timing.frontCheck, (_) {
        _checkFront();
      });

      step = 'settling';
      await _wait(widget.timing.settle);
      if (!mounted || _stop != null) return;

      step = 'drawing the run';
      final drew = await _drawRun(leg.heavyFrames);
      if (!mounted || _stop != null) return;
      if (!drew) {
        _stop = (
          verdict: 'FAILED',
          reason:
              'the run did not finish within '
              '${widget.timing.runTimeout.inSeconds} s',
        );
        return;
      }

      step = 'waiting for the hide frame\'s timing';
      final hide = _hideNumber;
      final reported = await _waitUntil(
        () => _frames.any((f) => f.number == hide),
        widget.timing.hideTimingTimeout,
      );
      if (!mounted || _stop != null) return;
      if (!reported) {
        _stop = (
          verdict: 'FAILED',
          reason:
              'no timing for the hide frame #$hide within '
              '${widget.timing.hideTimingTimeout.inSeconds} s',
        );
        return;
      }

      step = 'waiting for a scan';
      await _wait(widget.timing.dwell);
      if (!mounted || _stop != null) return;
      step = 'flushing the timeline';
      await widget.calls.flushTimeline();
      if (!mounted || _stop != null) return;
      _frontTimer?.cancel();
      _endScenario(label: label);
      _spanClosed = true;
      _stopTimings();

      final frames = List.of(_frames);
      final judged = rasterFrameRefusal(
        leg,
        heavyFrames: List.of(_heavyNumbers),
        hideFrame: _hideNumber,
        frames: frames,
        bracket: bracket,
      );
      _logFrames(label, frames);
      final count = judged.count;
      final dominant = [
        for (final f in frames)
          if (isRasterDominant(uiUs: f.uiUs, rasterUs: f.rasterUs)) f,
      ];
      final span = busiestSpanCount(dominant);
      final spanMs = span.firstUs == null
          ? null
          : (span.lastUs! - span.firstUs!) ~/ 1000;
      final frameRefusal = judged.refusal;
      if (frameRefusal != null) {
        _finish(
          leg,
          '${frameRefusal.verdict}: ${frameRefusal.reason}. ${_retryHint()}',
          count: count,
          spanMs: spanMs,
        );
        return;
      }

      step = 'restoring the timeline streams';
      await _wait(widget.timing.endBarrier);
      if (!mounted) return;
      if (!await _restoreStreams(label: label)) {
        _finish(
          leg,
          'FAILED: the VM did not restore the timeline streams after 3 '
          'tries. ${_retryHint()}',
          count: count,
          spanMs: spanMs,
        );
        return;
      }
      if (!mounted) return;

      step = 'exporting';
      final provenance = requireCaptureProvenance(
        check: widget.provenanceCheck,
      );
      final heavyRaster = [
        for (final f in frames)
          if (_heavyNumbers.contains(f.number)) f.rasterUs,
      ]..sort();
      // Which run frames were dominant, so the capture shows where its
      // count came from.
      final inRun = _runTest(frames);
      bool dominantAt(int? n) => frames.any(
        (f) =>
            f.number == n &&
            isRasterDominant(uiUs: f.uiUs, rasterUs: f.rasterUs),
      );
      final tail = [
        for (final f in frames)
          if (inRun(f) && hide != null && f.number > hide) f.number,
      ];
      final notes =
          'paths $rasterLegPaths, heavy frames ${leg.heavyFrames} (all '
          'dominant), hide frame dominant ${dominantAt(hide)}, next frame '
          'in the run ${tail.isEmpty ? 'none' : (dominantAt(tail.first) ? 'dominant' : 'light')}, '
          'dominant span '
          '${spanMs ?? 0} ms, heavy raster median '
          '${heavyRaster.isEmpty ? 0 : heavyRaster[heavyRaster.length ~/ 2]} '
          'us';
      String? json;
      String? composeFailure;
      try {
        json = await withCallTimeout(
          widget.calls.exportCapture(
            leg: leg,
            band: rasterLegBand(bracket, leg.role),
            observed: count!,
            provenance: provenance,
            captureNotes: notes,
          ),
          'exportCaptureJson',
        );
        if (json == null) {
          composeFailure =
              widget.calls.lastExportFailure() ??
              'exportCaptureJson gave no reason';
        }
      } catch (e) {
        composeFailure = '$e';
      }
      // A stop that landed during the export wins over its result.
      if (!mounted || _stop != null) return;
      if (json == null) {
        _finish(leg, 'FAILED to compose: $composeFailure', count: count);
        return;
      }
      num? detectorMax;
      try {
        detectorMax = countCaptureRecords(
          json,
          bracket: bracket,
          role: leg.role,
        ).reduced;
      } on FormatException {
        detectorMax = null;
      }
      final check = checkCaptureJson(
        json,
        bracket: bracket,
        role: leg.role,
        observed: count,
        unit: 'frames',
      );
      final exportRefusal = recordRefusal(
        check,
        role: leg.role,
        bracket: bracket,
      );
      if (exportRefusal != null) {
        _finish(
          leg,
          '${exportRefusal.verdict}: ${exportRefusal.reason}. ${_retryHint()}',
          count: count,
          detector: detectorMax,
          spanMs: spanMs,
        );
        return;
      }
      final stashed = json;
      _stash = (leg: leg, json: stashed, at: _now());
      _attemptLeg = null;
      _finish(
        leg,
        'capture stashed: ${rasterFrameCount(count!, 'dominant')} in '
        '${spanMs ?? 0} ms${detectorMax == null ? '' : ', detector count $detectorMax'}. '
        'Tap "Export last leg" to copy it.',
        count: count,
        detector: detectorMax,
        spanMs: spanMs,
      );
    } on CaptureProvenanceUnavailable catch (e) {
      _finish(leg, 'ABORT: capture provenance: ${e.problem}.');
    } catch (e) {
      // A flush past its 2 s limit, a VM call past its limit, or any other
      // failure still ends the attempt with an outcome line.
      _finish(leg, 'FAILED while $step: $e. ${_retryHint()}');
    } finally {
      final stop = _stop;
      if (stop != null && mounted) {
        _finish(leg, '${stop.verdict}: ${stop.reason}. ${_retryHint()}');
      }
      _frontTimer?.cancel();
      _limitTimer?.cancel();
      if (_ticker.isActive) _ticker.stop();
      if (_showPicture) {
        _showPicture = false;
        _paintTick.value++;
      }
      _stopTimings();
      // Both are no-ops when the attempt or dispose already did them.
      _endScenario(label: label);
      await _restoreStreams(label: label);
      _stopSignal = null;
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Logs the run's frames and any dominant frame outside it, with fixed
  /// widths so the log reads as columns.
  void _logFrames(String label, List<RasterFrame> frames) {
    final inRun = _runTest(frames);
    final hide = _hideNumber;
    for (final f in frames) {
      final dominant = isRasterDominant(uiUs: f.uiUs, rasterUs: f.rasterUs);
      if (!inRun(f) && !dominant) continue;
      _say(
        '[$label] #${f.number.toString().padLeft(6)} '
        'ui ${(f.uiUs / 1000).toStringAsFixed(1).padLeft(5)} ms '
        'raster ${(f.rasterUs / 1000).toStringAsFixed(1).padLeft(5)} ms '
        '${dominant ? 'dominant yes' : 'dominant no '}'
        '${inRun(f) ? (f.number == hide ? ' (hide)' : '') : ' OUTSIDE THE RUN'}',
      );
    }
  }

  /// [inRasterRun] for the run just drawn, judged over [frames].
  bool Function(RasterFrame) _runTest(List<RasterFrame> frames) {
    final first = _heavyNumbers.isEmpty ? null : _heavyNumbers.first;
    final hide = _hideNumber;
    if (first == null || hide == null) return (_) => false;
    final hideVsync = frames
        .where((f) => f.number == hide)
        .map((f) => f.vsyncUs)
        .firstOrNull;
    final continuation = hideVsync == null
        ? null
        : rasterContinuationFrame(
            frames,
            hideFrame: hide,
            hideVsyncUs: hideVsync,
          );
    return (f) => inRasterRun(
      f,
      firstHeavy: first,
      hideFrame: hide,
      continuationFrame: continuation,
    );
  }

  @override
  Future<Map<String, Object?>> runBurst({
    required int frames,
    required int paths,
    required int budgetUs,
  }) async {
    if (_busy) return {'error': 'busy: a leg or a burst is running'};
    if (frames < 1 || frames > 60) {
      return {'error': 'frames must be between 1 and 60'};
    }
    if (paths < 1 || paths > 5000) {
      return {'error': 'paths must be between 1 and 5000'};
    }
    final quiet = _quietStartProblem();
    if (quiet != null) return {'error': quiet};
    if (paths != _picturePaths) _recordPicture(paths, null);
    _stop = null;
    _stopSignal = Completer<void>();
    setState(() => _busy = true);
    try {
      _startTimings();
      final drew = await _drawRun(frames);
      final hide = _hideNumber;
      if (!drew || !mounted) return {'error': 'the run did not finish'};
      await _waitUntil(
        () => _frames.any((f) => f.number == hide),
        widget.timing.hideTimingTimeout,
      );
      await _wait(widget.timing.burstTail);
      final judged = List.of(_frames);
      final heavy = Set.of(_heavyNumbers);
      final inRun = _runTest(judged);
      final dominant = [
        for (final f in judged)
          if (isRasterDominant(
            uiUs: f.uiUs,
            rasterUs: f.rasterUs,
            budgetUs: budgetUs,
          ))
            f,
      ];
      final span = busiestSpanCount(dominant);
      return {
        'paths': paths,
        'budgetUs': budgetUs,
        'heavyFrames': _heavyNumbers,
        'hideFrame': hide,
        'dominantCount': dominant.length,
        'busiestSpanCount': span.count,
        'busiestSpanMs': span.firstUs == null
            ? null
            : (span.lastUs! - span.firstUs!) ~/ 1000,
        'frames': [
          for (final f in judged)
            {
              'number': f.number,
              'vsyncUs': f.vsyncUs,
              'uiUs': f.uiUs,
              'rasterUs': f.rasterUs,
              'heavy': heavy.contains(f.number),
              'hide': f.number == hide,
              'inRun': inRun(f),
              'dominant': dominant.contains(f),
            },
        ],
      };
    } finally {
      _stopTimings();
      _stopSignal = null;
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Map<String, Object?> harnessState() {
    final result = _result;
    final stash = _stash;
    return {
      'busy': _busy,
      'attempts': _attempts,
      'lastRefusal': _lastRefusal,
      'result': result == null
          ? null
          : {
              'leg': result.leg.name,
              'scenario': result.leg.scenario,
              'line': result.line,
              'screenCount': result.screenCount,
              'detectorMax': result.detectorMax,
              'spanMs': result.spanMs,
              'at': result.at.toIso8601String(),
            },
      'stash': stash == null
          ? null
          : {
              'leg': stash.leg.name,
              'scenario': stash.leg.scenario,
              'at': stash.at.toIso8601String(),
            },
    };
  }

  Future<void> _exportLastLeg() async {
    final stash = _stash;
    if (stash == null) {
      _say(
        'Export: no stashed leg yet. Run a leg until its result reads '
        '"capture stashed".',
      );
      _confirm('No stashed leg yet');
      return;
    }
    final label = stash.leg.label;
    try {
      await Clipboard.setData(ClipboardData(text: stash.json));
      _say(
        '[$label] capture copied to the clipboard (${stash.json.length} '
        'chars). Send it to the Mac and save it as '
        '${stash.leg.scenario}.json under '
        'test/validation/captures/gpu_pressure/.',
      );
      if (mounted) {
        _confirm('Capture copied. Save as ${stash.leg.scenario}.json.');
      }
    } catch (e) {
      _say('[$label] clipboard copy FAILED: $e');
      if (mounted) _confirm('Copy failed: $e');
    }
  }

  /// How long ago [at] was, with its clock time.
  String _age(DateTime at) {
    final local = at.toLocal();
    final clockTime =
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
    final ago = _now().difference(at);
    final String text;
    if (ago.inMinutes < 1) {
      text = 'just now';
    } else if (ago.inHours < 1) {
      text = '${ago.inMinutes} min ago';
    } else {
      text = '${ago.inHours} h ago';
    }
    return 'Recorded $text ($clockTime)';
  }

  @override
  Widget build(BuildContext context) {
    final capture = Sleuth.diagnoseCaptureState();
    final scheme = Theme.of(context).colorScheme;
    final evidenceStyle = _monoStyle.copyWith(fontSize: 12);
    // The refresh rate is read again at each tap, so it does not disable
    // the legs.
    final ready = _captureModeOn && _provenance.provenance != null && !_busy;
    final rate = _refreshRate;
    final stamp = _provenance.provenance;
    final result = _result;
    final stash = _stash;
    final resultBracket = result == null
        ? null
        : rasterBracket(_detectorDefaults.validationMetadata, result.leg.tier);
    return Scaffold(
      appBar: AppBar(title: const Text('raster_dominance capture')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: CaptureBodyLayout(
            controlsShare: 0.40,
            controls: [
              CapturePreflightBanner(
                captureMode: _captureModeOn,
                vmConnected: capture.vmConnected,
                provenanceProblem: _provenance.problem,
              ),
              Text(
                'Refresh rate: '
                '${rate == null ? 'detecting' : '${rate.toStringAsFixed(1)} Hz'}'
                '${rate == null || _refreshRateOk ? '' : ' (needs 60 Hz)'}',
                style: const TextStyle(fontSize: 12),
              ),
              if (stamp != null)
                Text(
                  'Provenance: ${stamp.device} / '
                  '${stamp.deviceOsVersion} / '
                  'Flutter ${stamp.flutterVersion}',
                  style: const TextStyle(fontSize: 12),
                ),
              const SizedBox(height: 16),
              // The last attempt's evidence comes first. The verdict line
              // has no line cap, so a long reason stays whole.
              if (result == null)
                Text(
                  'No leg run yet.',
                  style: Theme.of(context).textTheme.titleSmall,
                )
              else ...[
                Text(
                  'Result: ${result.line}',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                Text(
                  'Leg: ${result.leg.title} (${result.leg.scenario})',
                  style: evidenceStyle,
                ),
                Text(
                  'Screen count:   ${result.screenCount ?? '-'}',
                  style: evidenceStyle,
                ),
                Text(
                  'Detector count: ${result.detectorMax ?? '-'}',
                  style: evidenceStyle,
                ),
                if (resultBracket != null)
                  Text(
                    'Band: ${resultBracket.bandText(result.leg.role)} frames',
                    style: evidenceStyle,
                  ),
                if (result.spanMs != null)
                  Text(
                    'Dominant span: ${result.spanMs} ms',
                    style: evidenceStyle,
                  ),
                Text(_age(result.at), style: evidenceStyle),
              ],
              if (stash != null) ...[
                const SizedBox(height: 8),
                Text(
                  'Stashed: ${stash.leg.title}, '
                  '${_age(stash.at).replaceFirst('Recorded ', 'recorded ')}',
                  style: evidenceStyle,
                ),
              ],
              const SizedBox(height: 16),
              Text(
                'Draws a run of frames in the framed box under Export, in a '
                'color close to the background, whose raster time is far '
                'above their UI time, and records raster_dominance: a '
                'warning at 3 dominant frames inside one second, critical '
                'at 10. A run of N heavy frames gives N or N + 1 dominant '
                'frames. Wait ${rasterRouteSettle.inSeconds} s after the '
                'screen opens before a leg.',
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 12),
              for (final leg in RasterLeg.values) ...[
                if (leg == RasterLeg.criticalBelow) const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: FilledButton.tonal(
                    onPressed: ready ? () => _runLeg(leg) : null,
                    child: Text(leg.buttonLabel),
                  ),
                ),
              ],
            ],
            pinned: [
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: _busy ? null : _exportLastLeg,
                icon: const Icon(Icons.save_alt),
                label: const Text('Export last leg'),
              ),
              const SizedBox(height: 12),
              // The workload box. Its size is fixed and nothing above it
              // changes height during a leg, so the picture never moves.
              Center(
                child: SizedBox(
                  key: _boxKey,
                  width: rasterBoxSize.width,
                  height: rasterBoxSize.height,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(color: scheme.outlineVariant),
                    ),
                    child: RepaintBoundary(
                      child: CustomPaint(
                        painter: _RunPainter(
                          repaint: _paintTick,
                          picture: () => _showPicture ? _picture : null,
                        ),
                        size: rasterBoxSize,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // Three lines at most so a large text scale cannot push the
              // log off the screen; the verdict line above and the log keep
              // the full text.
              Semantics(
                liveRegion: true,
                child: Text(
                  _status,
                  style: _monoStyle.copyWith(fontSize: 12),
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
                  style: _monoStyle.copyWith(fontSize: 11),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Draws the leg picture while [picture] returns one. Repaints on every
/// [repaint] tick and on nothing else, so a run frame's UI work is the
/// repaint of this boundary only.
class _RunPainter extends CustomPainter {
  _RunPainter({required Listenable repaint, required this.picture})
    : super(repaint: repaint);

  final ui.Picture? Function() picture;

  @override
  void paint(Canvas canvas, Size size) {
    final p = picture();
    if (p == null) return;
    canvas.clipRect(Offset.zero & size);
    canvas.drawPicture(p);
  }

  @override
  bool shouldRepaint(_RunPainter oldDelegate) => false;
}
