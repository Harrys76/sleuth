import 'dart:developer' show Timeline;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../sleuth.dart' show Sleuth;
import '../models/base_detector.dart';
import '../models/frame_stats.dart';
import '../validation/detector_metadata.dart';
import '../validation/evidence_tier.dart';
import '../models/performance_issue.dart';
import '../models/widget_highlight.dart';
import '../utils/blur_sigma.dart';
import '../utils/fix_hint_builder.dart';
import '../utils/framework_painters.dart';
import '../utils/framework_types.dart' show cupertinoBlurOwner;
import '../utils/widget_location.dart';
import '../vm/timeline_parser.dart';

/// Detects GPU pressure from expensive rendering operations.
///
/// **Hybrid Detector** with three evidence sources:
///
/// * **Frame leg (every tier).** [processFrame] receives each presented
///   frame's `FrameTiming` UI (build + layout + paint) and raster durations.
///   A frame is raster-dominant when its UI time is positive, its raster
///   time exceeds the frame's own budget (so the frame missed its deadline
///   on the raster thread) and [maxFrameRasterFloorUs], and raster exceeds
///   [rasterMultiplierThreshold] × UI. `raster_dominance` warns when at
///   least [minRasterDominantFrames] dominant frames fall inside a
///   one-second span, and is critical at [criticalRasterDominantFrames].
///   Dominant frames from the last second before the newest frame carry
///   across a scan, so a burst split by a scan counts once. Frames that
///   arrive within [startupPhaseWindowSeconds] of Dart entry are ignored
///   (cold-start pipeline compilation belongs to `shader_compilation`).
///   The issue stamps `observedDominantFrames`, the dominant frames in the
///   one-second span it judged, and `dominantFrameCount`, the dominant
///   frames since the previous scan. The two differ when a span reaches
///   back across a scan.
/// * **VM leg.** Raster and UI timeline events from the VM, ignored inside
///   the same startup window, read once per scan. When the frame leg fires
///   and a VM raster frame since the last scan also exceeds the budget and
///   [rasterMultiplierThreshold] times the UI time of an average frame in
///   its batch, the issue is `confirmed`. When no frames arrived since the
///   last scan (`FrameTimingDetector` disabled), the VM leg emits on its own
///   once one poll holds [minRasterDominantFrames] such frames, critical at
///   [criticalRasterDominantFrames].
/// * **Structural leg.** Opacity, ClipPath, BackdropFilter, ShaderMask and
///   ColorFiltered over deep subtrees (`expensive_gpu_nodes`).
class GpuPressureDetector extends BaseDetector with DetectorMetadataProvider {
  GpuPressureDetector({
    this.rasterMultiplierThreshold = 2.0,
    this.maxFrameRasterFloorUs = 8000,
    this.minRasterDominantFrames = 3,
    this.criticalRasterDominantFrames = 10,
    this.startupPhaseWindowSeconds = 5,
    String? Function()? sourceRouteProvider,
    int? Function()? appStartMonotonicUsForTest,
  }) : assert(
         minRasterDominantFrames >= 1,
         'minRasterDominantFrames must be at least 1.',
       ),
       assert(
         criticalRasterDominantFrames >= minRasterDominantFrames,
         'criticalRasterDominantFrames must be at least '
         'minRasterDominantFrames.',
       ),
       _sourceRouteProvider = sourceRouteProvider ?? (() => null),
       _appStartForTest = appStartMonotonicUsForTest,
       super(
         type: DetectorType.gpuPressure,
         lifecycle: DetectorLifecycle.hybrid,
         name: 'GPU Pressure',
         description:
             'Detects GPU bottlenecks (frames that miss their budget on the '
             'raster thread, raster above 2.0 times UI)',
       );

  /// Flag when raster time exceeds UI time by this factor.
  final double rasterMultiplierThreshold;

  /// Raster time (microseconds) a frame must exceed to count, on top of
  /// its frame budget. The default 8000 is below the budget of every
  /// display up to 120 Hz, so it takes effect only when raised.
  final int maxFrameRasterFloorUs;

  /// Raster-dominant frames inside one second at which `raster_dominance`
  /// warns. Default 3.
  final int minRasterDominantFrames;

  /// Raster-dominant frames inside one second at which `raster_dominance`
  /// is critical. Default 10. On a Galaxy A07 the GPU Pressure, Cupertino
  /// blur and IntrinsicHeight demos dropped 26 to 54 such frames a second;
  /// other screens there and on an iPhone 12 dropped 5 or fewer.
  final int criticalRasterDominantFrames;

  /// Frames arriving within this many seconds of
  /// [Sleuth.dartEntryMonotonicUs] do not count toward the frame leg. Same
  /// clock and window as `FrameTimingDetector`'s `lifecyclePhase`; the
  /// controller wires it from
  /// `DetectorThresholds.startupPhaseWindowSeconds`.
  final int startupPhaseWindowSeconds;

  /// Route active when a frame-leg issue is emitted, stamped on it as
  /// [PerformanceIssue.sourceRoute]. Wired by the controller.
  final String? Function() _sourceRouteProvider;

  /// Test-only override for the app-start monotonic anchor, mirroring
  /// `FrameTimingDetector`. Tests pass `() => Timeline.now - ageUs`.
  final int? Function()? _appStartForTest;

  static const int _defaultFrameBudgetUs = 16667;
  int _frameBudgetUs = _defaultFrameBudgetUs;

  /// Raster time the VM leg's worst frame must exceed: the resolved frame
  /// budget, or [maxFrameRasterFloorUs] when that is larger. The frame leg
  /// uses each frame's own budget.
  int get effectiveMaxFrameRasterFloorUs =>
      _frameBudgetUs > maxFrameRasterFloorUs
      ? _frameBudgetUs
      : maxFrameRasterFloorUs;

  /// Sets the frame budget the VM leg judges against. Called by
  /// `SleuthController` whenever the resolved frame budget changes.
  void updateFrameBudget(int budgetUs) {
    if (budgetUs <= 0) return;
    _frameBudgetUs = budgetUs;
  }

  /// Restores the 60 Hz budget (16667 us).
  void resetFrameBudget() {
    _frameBudgetUs = _defaultFrameBudgetUs;
  }

  final List<PerformanceIssue> _issues = [];
  final List<WidgetHighlight> _highlights = [];
  bool _isEnabled = true;

  /// BackdropFilter with blur sigma at or below this threshold is suppressed
  /// — the GPU cost is negligible for very small blurs.
  static const _lowSigmaThreshold = 2.0;

  /// BackdropFilter with blur sigma above this threshold gets critical severity.
  static const _highSigmaThreshold = 10.0;

  // VM raster frames since the last scan that missed the budget with raster
  // above the ratio times their batch's UI time per frame: the most in any
  // one batch, and the slowest of them with its batch's UI time per frame.
  // Read and cleared once per scan, so idle polls cannot judge old values
  // again.
  int _vmMissedInBatch = 0;
  int _vmWorstRasterUs = 0;
  int _vmWorstBatchUiUs = 0;
  bool _vmConnected = false;
  final List<String> _expensiveNodes = [];

  // Cupertino widgets whose own blur produced an expensive node this scan,
  // and how many of the expensive nodes were such blurs.
  final Set<String> _blurChromeOwners = {};
  int _chromeNodeCount = 0;
  final List<int> _subtreeSizeStack = [];

  static const String _structuralOnlyReason =
      'Structural pattern only. Sleuth saw no raster-dominant frames';

  static const String _frameLegReason =
      'Per-frame FrameTiming raster and UI durations';

  // -- Frame leg --
  //
  // Dominant frames go into a fixed 64-entry ring (parallel lists, no
  // per-frame allocation) that drops the oldest entry when full. After a
  // scan the ring keeps the dominant frames from the last second before
  // the newest frame, so a burst split by a scan still counts once; the
  // per-scan counters reset. A span counts only when it holds a frame that
  // arrived since the previous scan, so a burst is reported once.
  static const int _ringCapacity = 64;
  static const int _spanUs = 1000000;
  final List<int> _ringRasterUs = List<int>.filled(_ringCapacity, 0);
  final List<int> _ringUiUs = List<int>.filled(_ringCapacity, 0);
  final List<int> _ringAtUs = List<int>.filled(_ringCapacity, 0);
  final List<bool> _ringHasAt = List<bool>.filled(_ringCapacity, false);
  final List<int> _ringIdentityUs = List<int>.filled(_ringCapacity, 0);
  final List<bool> _ringHasIdentity = List<bool>.filled(_ringCapacity, false);
  final List<bool> _ringFresh = List<bool>.filled(_ringCapacity, false);
  int _ringCount = 0;
  int _ringWrite = 0;
  int _windowFrameCount = 0;
  int _dominantCount = 0;
  int _worstFrameRasterUs = 0;
  int? _newestFrameAtUs;

  /// Current VM connectivity — set by the controller.
  ///
  /// On disconnect, clears the VM timings, removes a VM-sourced
  /// `raster_dominance`, returns a VM-confirmed frame-leg issue to
  /// `likely`, and downgrades other non-frame issues to `possible`.
  /// `expensive_gpu_nodes` stays `likely` while a frame-sourced
  /// `raster_dominance` remains.
  bool get vmConnected => _vmConnected;
  @override
  set vmConnected(bool value) {
    _vmConnected = value;
    if (!value) {
      _clearVmLeg();
      _issues.removeWhere(
        (i) =>
            i.stableId == 'raster_dominance' &&
            i.observationSource == ObservationSource.vmTimeline,
      );
      for (int i = 0; i < _issues.length; i++) {
        final issue = _issues[i];
        if (issue.stableId == 'raster_dominance' &&
            issue.confidence == IssueConfidence.confirmed) {
          _issues[i] = issue.copyWith(
            confidence: IssueConfidence.likely,
            confidenceReason: _frameLegReason,
          );
        }
      }
      final frameLegRemains = _issues.any(
        (i) =>
            i.stableId == 'raster_dominance' &&
            i.observationSource == ObservationSource.frameTiming,
      );
      for (int i = 0; i < _issues.length; i++) {
        final issue = _issues[i];
        if (issue.observationSource == ObservationSource.frameTiming) continue;
        if (issue.confidence == IssueConfidence.possible) continue;
        if (frameLegRemains && issue.stableId == 'expensive_gpu_nodes') {
          continue;
        }
        _issues[i] = issue.copyWith(
          confidence: IssueConfidence.possible,
          confidenceReason: _structuralOnlyReason,
        );
      }
    }
  }

  @override
  List<PerformanceIssue> get issues => List.unmodifiable(_issues);

  @override
  List<WidgetHighlight> get highlights => List.unmodifiable(_highlights);

  @override
  bool get isEnabled => _isEnabled;

  @override
  set isEnabled(bool value) => _isEnabled = value;

  @override
  void processTimelineData(ParsedTimelineData data) {
    if (!_isEnabled) return;
    // Cold-start polls carry pipeline-compilation raster frames against
    // almost no UI work; the frame leg ignores them and so does this leg.
    if (_insideStartupWindow()) return;
    if (data.rasterDurations.isEmpty) return;
    final totalUi =
        data.totalBuildScopeUs +
        data.totalFlushLayoutUs +
        data.totalFlushPaintUs;
    // A batch without UI work has no ratio to judge.
    if (totalUi <= 0) return;
    // A poll carries about half a second of frames, and the timeline does
    // not pair a frame's raster with its UI work. Each raster frame is set
    // against the UI time of an average frame in the batch, not the batch's
    // total, which grows with the frame count.
    final perFrame = totalUi ~/ data.rasterDurations.length;
    final uiPerFrameUs = perFrame > 0 ? perFrame : 1;
    final budgetUs = effectiveMaxFrameRasterFloorUs;
    var missed = 0;
    for (final rasterUs in data.rasterDurations) {
      if (rasterUs <= budgetUs) continue;
      if (rasterUs <= rasterMultiplierThreshold * uiPerFrameUs) continue;
      missed++;
      if (rasterUs > _vmWorstRasterUs) {
        _vmWorstRasterUs = rasterUs;
        _vmWorstBatchUiUs = uiPerFrameUs;
      }
    }
    if (missed > _vmMissedInBatch) _vmMissedInBatch = missed;
  }

  @override
  void processFrame(FrameStats frame) {
    if (!_isEnabled) return;
    if (_insideStartupWindow()) return;
    _windowFrameCount++;
    final atUs = frame.vsyncStartUs ?? frame.rasterFinishUs;
    final newest = _newestFrameAtUs;
    if (atUs != null && (newest == null || atUs > newest)) {
      _newestFrameAtUs = atUs;
    }
    final uiUs = frame.uiDuration.inMicroseconds;
    final rasterUs = frame.rasterDuration.inMicroseconds;
    if (uiUs <= 0 || rasterUs <= 0) return;
    // The frame missed its deadline on the raster thread, and raster, not
    // the UI thread, was the larger cost.
    if (rasterUs <= frame.frameBudgetUs) return;
    if (rasterUs <= maxFrameRasterFloorUs) return;
    if (rasterUs <= rasterMultiplierThreshold * uiUs) return;

    _dominantCount++;
    if (rasterUs > _worstFrameRasterUs) _worstFrameRasterUs = rasterUs;
    final i = _ringWrite;
    _ringRasterUs[i] = rasterUs;
    _ringUiUs[i] = uiUs;
    _ringHasAt[i] = atUs != null;
    _ringAtUs[i] = atUs ?? 0;
    final identityUs = frame.rasterFinishUs ?? frame.vsyncStartUs;
    _ringHasIdentity[i] = identityUs != null;
    _ringIdentityUs[i] = identityUs ?? 0;
    _ringFresh[i] = true;
    _ringWrite = (i + 1) % _ringCapacity;
    if (_ringCount < _ringCapacity) _ringCount++;
  }

  /// True while the frame arrives within [startupPhaseWindowSeconds] of
  /// Dart entry, measured like `FrameTimingDetector`'s lifecycle phase
  /// (`Timeline.now` against [Sleuth.dartEntryMonotonicUs]). Without an
  /// anchor (no `Sleuth.init`) frames count.
  bool _insideStartupWindow() {
    final appStart = _appStartForTest?.call() ?? Sleuth.dartEntryMonotonicUs;
    if (appStart == null) return false;
    final delta = Timeline.now - appStart;
    if (delta < 0) return false;
    return delta < startupPhaseWindowSeconds * 1000000;
  }

  /// Starts a new frame window at a route change: raster-dominant frames
  /// and VM raster timing seen on the previous route no longer count.
  void markRouteEpoch() {
    _resetFrameLeg();
    _clearVmLeg();
  }

  /// Clears the frame leg, the VM leg and any `raster_dominance` issue at
  /// the start of a capture scenario, so dominant frames from before the
  /// scenario cannot join its first record. `expensive_gpu_nodes` stays
  /// until the next scan. Called by `SleuthController.resetCaptureState`,
  /// which runs only in capture mode.
  void resetCaptureState() {
    _resetFrameLeg();
    _clearVmLeg();
    _issues.removeWhere((i) => i.stableId == 'raster_dominance');
  }

  void _clearVmLeg() {
    _vmMissedInBatch = 0;
    _vmWorstRasterUs = 0;
    _vmWorstBatchUiUs = 0;
  }

  void _resetFrameLeg() {
    _ringCount = 0;
    _ringWrite = 0;
    _newestFrameAtUs = null;
    _resetScanCounters();
  }

  void _resetScanCounters() {
    _windowFrameCount = 0;
    _dominantCount = 0;
    _worstFrameRasterUs = 0;
  }

  /// Drops dominant frames more than a second older than the newest frame,
  /// and frames without a timestamp, and marks the frames it keeps as seen
  /// by a scan. Kept frames move up to stay contiguous in arrival order.
  void _pruneFrameLeg() {
    final newest = _newestFrameAtUs;
    final oldest = (_ringWrite - _ringCount + _ringCapacity) % _ringCapacity;
    var kept = 0;
    for (var k = 0; k < _ringCount; k++) {
      final from = (oldest + k) % _ringCapacity;
      final keep =
          newest != null &&
          _ringHasAt[from] &&
          _ringAtUs[from] > newest - _spanUs;
      if (!keep) continue;
      final to = (oldest + kept) % _ringCapacity;
      if (to != from) {
        _ringRasterUs[to] = _ringRasterUs[from];
        _ringUiUs[to] = _ringUiUs[from];
        _ringAtUs[to] = _ringAtUs[from];
        _ringHasAt[to] = true;
        _ringIdentityUs[to] = _ringIdentityUs[from];
        _ringHasIdentity[to] = _ringHasIdentity[from];
      }
      _ringFresh[to] = false;
      kept++;
    }
    _ringCount = kept;
    _ringWrite = (oldest + kept) % _ringCapacity;
  }

  /// Finds the one-second span holding the most dominant frames (the most
  /// recent on ties) among the spans that hold a frame that arrived since
  /// the previous scan. Frames without timestamps form one span of their
  /// own. Returns null when no span reaches [minRasterDominantFrames].
  _FrameLegResult? _evaluateFrameLeg() {
    // Fast path: no dominant frame arrived since the previous scan.
    if (_dominantCount == 0) return null;
    if (_ringCount < minRasterDominantFrames) return null;
    final oldest = (_ringWrite - _ringCount + _ringCapacity) % _ringCapacity;
    final timed = <int>[];
    final untimed = <int>[];
    for (var k = 0; k < _ringCount; k++) {
      final idx = (oldest + k) % _ringCapacity;
      (_ringHasAt[idx] ? timed : untimed).add(idx);
    }
    // Ring position relative to the oldest entry is arrival order; it
    // breaks timestamp ties so equal keys keep their arrival order.
    int arrival(int idx) => (idx - oldest + _ringCapacity) % _ringCapacity;
    timed.sort((a, b) {
      final byAt = _ringAtUs[a].compareTo(_ringAtUs[b]);
      return byAt != 0 ? byAt : arrival(a).compareTo(arrival(b));
    });

    var bestCount = 0;
    var bestLeft = 0;
    var left = 0;
    var freshInSpan = 0;
    for (var right = 0; right < timed.length; right++) {
      if (_ringFresh[timed[right]]) freshInSpan++;
      while (_ringAtUs[timed[right]] - _ringAtUs[timed[left]] >= _spanUs) {
        if (_ringFresh[timed[left]]) freshInSpan--;
        left++;
      }
      if (freshInSpan == 0) continue;
      final count = right - left + 1;
      if (count >= bestCount) {
        bestCount = count;
        bestLeft = left;
      }
    }
    var bestSpan = timed.sublist(bestLeft, bestLeft + bestCount);
    // Untimed frames never outlive a scan, so they all arrived since the
    // previous one.
    if (untimed.length > bestCount) {
      bestCount = untimed.length;
      bestSpan = untimed;
    }
    if (bestCount < minRasterDominantFrames) return null;

    final ratios = <double>[
      for (final idx in bestSpan) _ringRasterUs[idx] / _ringUiUs[idx],
    ];
    ratios.sort();
    final mid = ratios.length ~/ 2;
    final median = ratios.length.isOdd
        ? ratios[mid]
        : (ratios[mid - 1] + ratios[mid]) / 2;
    final last = bestSpan.last;
    return _FrameLegResult(
      qualifyingCount: bestCount,
      medianRatio: median,
      critical: bestCount >= criticalRasterDominantFrames,
      identityUs: _ringHasIdentity[last] ? _ringIdentityUs[last] : null,
    );
  }

  @override
  void prepareScan(BuildContext context) {
    _expensiveNodes.clear();
    _blurChromeOwners.clear();
    _chromeNodeCount = 0;
    _highlights.clear();
    _subtreeSizeStack.clear();
  }

  @override
  void checkElement(Element element) {
    _subtreeSizeStack.add(0);
  }

  @override
  void afterElement(Element element) {
    final subtreeSize = _subtreeSizeStack.removeLast();
    if (_subtreeSizeStack.isNotEmpty) {
      _subtreeSizeStack.last += subtreeSize + 1;
    }

    // Only the element that owns a render object judges it. Wrapper
    // elements (a Material, a Builder) resolve `renderObject` to the same
    // descendant render object and would report it once more each, with
    // a subtree one larger per hop.
    if (element is! RenderObjectElement) return;
    final ro = element.renderObject;

    // Direct type checks — no runtimeType.toString() allocation.
    // Excludes RenderPhysicalModel/Shape (Card, Material) — these are
    // normal and hardware-accelerated in profile mode.
    // Note: `is RenderOpacity` correctly excludes RenderAnimatedOpacity
    // (which extends RenderProxyBox, not RenderOpacity) — the previous
    // contains('RenderOpacity') matched it as a false positive.
    String? typeName;
    double? backdropSigma;
    String? chromeOwner;
    if (ro is RenderOpacity) {
      final val = ro.opacity;
      if (val >= 1.0 || val <= 0.0) return; // no-op or short-circuit
      typeName = 'RenderOpacity';
    } else if (ro is RenderClipPath) {
      // The clip a transparency Material builds for its own shape is
      // framework-owned (buttons, chips); only user ClipPaths count.
      if (isMaterialOwnClip(element)) return;
      typeName = 'RenderClipPath';
    } else if (ro is RenderBackdropFilter) {
      // A disabled filter draws nothing (an opaque Cupertino bar keeps its
      // BackdropFilter with `enabled: false`).
      if (!ro.enabled) return;
      final widget = element.widget;
      if (widget is BackdropFilter) {
        backdropSigma = maxBlurSigma(widget);
        if (backdropSigma != null && backdropSigma <= _lowSigmaThreshold) {
          return;
        }
        chromeOwner = cupertinoBlurOwner(element);
      }
      typeName = 'RenderBackdropFilter';
    } else if (ro is RenderShaderMask) {
      typeName = 'RenderShaderMask';
    } else if (element.widget is ColorFiltered) {
      // ColorFiltered uses a private _ColorFilterRenderObject — can't use
      // `is` check on the render object. Check the widget type instead.
      typeName = 'RenderColorFiltered';
    }

    if (typeName == null) return;

    if (subtreeSize > 5) {
      // Sigma-aware detail for BackdropFilter.
      String nodeDetail = '$typeName ($subtreeSize descendants)';
      String highlightDetail = '$typeName with $subtreeSize descendants';
      IssueSeverity highlightSeverity = IssueSeverity.warning;

      if (backdropSigma != null) {
        final sigmaStr = backdropSigma.toStringAsFixed(1);
        nodeDetail = '$typeName ($subtreeSize descendants, σ=$sigmaStr)';
        highlightDetail =
            '$typeName with $subtreeSize descendants (σ=$sigmaStr)';
        if (backdropSigma > _highSigmaThreshold) {
          highlightSeverity = IssueSeverity.critical;
        }
      }

      if (chromeOwner != null) {
        nodeDetail = '$nodeDetail, drawn by $chromeOwner';
        highlightDetail = '$highlightDetail, drawn by $chromeOwner';
        _blurChromeOwners.add(chromeOwner);
        _chromeNodeCount++;
      }

      _expensiveNodes.add(nodeDetail);
      final rect = getGlobalRect(ro);
      if (rect != null) {
        _highlights.add(
          WidgetHighlight(
            rect: rect,
            renderObject: ro,
            widgetName: typeName, // known from type check — no toString()
            severity: highlightSeverity,
            detectorName: 'GPU',
            detail: highlightDetail,
          ),
        );
      }
    }
  }

  @override
  void finalizeScan() {
    _subtreeSizeStack.clear();
    _evaluate();
  }

  void _evaluate() {
    _issues.clear();

    final windowFrameCount = _windowFrameCount;
    final dominantCount = _dominantCount;
    final worstFrameRasterUs = _worstFrameRasterUs;
    // Without a new frame since the last scan the frame leg has nothing to
    // judge. Its held frames stay for the next scan, which prunes them by
    // time, so a scan that lands between two frame-timing batches does not
    // split a burst.
    final frameLeg = windowFrameCount == 0 ? null : _evaluateFrameLeg();
    _pruneFrameLeg();
    _resetScanCounters();

    // The VM raster frames since the last scan that missed the budget with
    // raster above the ratio times their batch's UI time per frame, read
    // once.
    final vmMissedInBatch = vmConnected ? _vmMissedInBatch : 0;
    final vmWorstUs = _vmWorstRasterUs;
    final vmUiUs = _vmWorstBatchUiUs;
    _clearVmLeg();
    final vmRatio = vmUiUs > 0 ? vmWorstUs / vmUiUs : 0.0;
    final vmMissed = vmMissedInBatch > 0;
    // The VM leg emits alone only when no frames arrived, which happens
    // when FrameTimingDetector is disabled, and then needs as many missed
    // frames inside one poll as the frame leg needs inside one second.
    final vmAlone =
        windowFrameCount == 0 && vmMissedInBatch >= minRasterDominantFrames;
    final hasRasterDominance = frameLeg != null || vmAlone;

    if (frameLeg != null) {
      final (hint, effort) = FixHintBuilder.rasterDominance();
      final median = frameLeg.medianRatio.toStringAsFixed(1);
      _issues.add(
        PerformanceIssue(
          stableId: 'raster_dominance',
          severity: frameLeg.critical
              ? IssueSeverity.critical
              : IssueSeverity.warning,
          category: IssueCategory.raster,
          confidence: vmMissed
              ? IssueConfidence.confirmed
              : IssueConfidence.likely,
          title: 'Raster Dominance: $median× UI time',
          detail:
              '${frameLeg.qualifyingCount} frames within one second missed '
              'their budget on the raster thread, with raster above '
              '${rasterMultiplierThreshold.toStringAsFixed(1)} times the UI '
              'time (median raster-to-UI ratio $median). $dominantCount of '
              '$windowFrameCount frames since the last scan did so, the '
              'worst taking '
              '${(worstFrameRasterUs / 1000).toStringAsFixed(1)}ms.',
          fixHint: hint,
          fixEffort: effort,
          observationSource: ObservationSource.frameTiming,
          detectedAt: DateTime.now(),
          sourceRoute: _sourceRouteProvider(),
          dedupIdentityMicros: frameLeg.identityUs,
          extraTraceArgs: {
            'source': 'frame_timing',
            'observedDominantFrames': frameLeg.qualifyingCount.toString(),
            'dominantFrameCount': dominantCount.toString(),
            'windowFrameCount': windowFrameCount.toString(),
            'worstFrameRasterUs': worstFrameRasterUs.toString(),
            'medianRatio': frameLeg.medianRatio.toStringAsFixed(2),
            if (vmMissed) 'vmWorstRasterUs': vmWorstUs.toString(),
            'lifecyclePhase': 'steady',
          },
          confidenceReason: vmMissed
              ? '$_frameLegReason, confirmed by the VM timeline raster timing'
              : _frameLegReason,
        ),
      );
    } else if (vmAlone) {
      // No extra trace args: this path counts frames in one poll, not in a
      // one-second span, so it carries no `observedDominantFrames`.
      final (hint, effort) = FixHintBuilder.rasterDominance();
      _issues.add(
        PerformanceIssue(
          stableId: 'raster_dominance',
          severity: vmMissedInBatch >= criticalRasterDominantFrames
              ? IssueSeverity.critical
              : IssueSeverity.warning,
          category: IssueCategory.raster,
          confidence: IssueConfidence.confirmed,
          title: 'Raster Dominance: ${vmRatio.toStringAsFixed(1)}× UI time',
          detail:
              '$vmMissedInBatch frames in one VM poll (about half a second) '
              'took longer than the '
              '${(effectiveMaxFrameRasterFloorUs / 1000).toStringAsFixed(1)}'
              'ms frame budget to rasterize, with raster above '
              '${rasterMultiplierThreshold.toStringAsFixed(1)} times the UI '
              'time of an average frame in that poll. The worst took '
              '${(vmWorstUs / 1000).toStringAsFixed(1)}ms against '
              '${(vmUiUs / 1000).toStringAsFixed(1)}ms of UI time. No frame '
              'timings arrived, so this comes from the VM timeline alone.',
          fixHint: hint,
          fixEffort: effort,
          observationSource: ObservationSource.vmTimeline,
          detectedAt: DateTime.now(),
          confidenceReason: 'Measured directly from VM timeline raster timing',
        ),
      );
    }

    if (_expensiveNodes.isNotEmpty) {
      final (hint, effort) = FixHintBuilder.expensiveGpuNodes(
        blurChromeOwners: _blurChromeOwners,
        onlyChrome: _chromeNodeCount == _expensiveNodes.length,
      );
      final noRasterTiming = !vmConnected && windowFrameCount == 0;
      _issues.add(
        PerformanceIssue(
          stableId: 'expensive_gpu_nodes',
          severity: IssueSeverity.warning,
          category: IssueCategory.raster,
          confidence: hasRasterDominance
              ? IssueConfidence.likely
              : IssueConfidence.possible,
          title: hasRasterDominance
              ? 'Expensive Render Nodes May Contribute: ${_expensiveNodes.length} found'
              : 'Expensive Render Nodes: ${_expensiveNodes.length} found',
          detail:
              '${hasRasterDominance ? 'Raster-dominant frames coincided with ' : 'Sleuth found '}'
              'expensive render objects with deep subtrees:\n'
              '${_expensiveNodes.join("\n")}'
              '${noRasterTiming ? '\nSleuth has not observed raster timing yet.' : ''}',
          fixHint: hint,
          fixEffort: effort,
          observationSource: ObservationSource.structural,
          detectedAt: DateTime.now(),
          confidenceReason: hasRasterDominance
              ? 'Raster-dominant frames and a structural render node scan'
              : _structuralOnlyReason,
        ),
      );
    }
  }

  @override
  void dispose() {
    _issues.clear();
    _highlights.clear();
    _expensiveNodes.clear();
    _blurChromeOwners.clear();
    _chromeNodeCount = 0;
    _subtreeSizeStack.clear();
    _resetFrameLeg();
    _vmWorstRasterUs = 0;
    _vmWorstBatchUiUs = 0;
  }

  @override
  DetectorMetadata get validationMetadata => const DetectorMetadata(
    tier: EvidenceTier.reproducerOnly,
    rationale:
        'Hybrid detector with a frame leg, a VM leg and a structural leg. '
        'On the frame leg (every tier), `processFrame` reads the per-frame '
        '`FrameTiming` UI (build, layout and paint) and raster durations. A '
        'frame is raster-dominant when UI is above 0, raster is above the '
        'frame\'s own budget (the frame missed its deadline on the raster '
        'thread) and above `maxFrameRasterFloorUs` (default 8000us, below '
        'every budget up to 120 Hz), and raster is above 2.0 times UI. '
        '`raster_dominance` warns (`likely`, source `frameTiming`) at 3 '
        'dominant frames inside a 1 s span and is critical at 10, over a '
        '64-entry ring that keeps the last second before the newest frame '
        'across scans and counts only spans that hold a frame that arrived '
        'since the last scan, so a burst is reported once. Recorded frames '
        'from a Galaxy A07 (90 Hz) and an iPhone 12 pin the split: the GPU '
        'Pressure, Cupertino blur and IntrinsicHeight demos on the Galaxy '
        'dropped 26 to 54 such frames a second, other screens 5 or fewer. '
        'Two Galaxy recordings made while Sleuth requested the timeline '
        'every 500 ms read warning from 3 frames 500 ms apart, which the '
        'request held on the raster thread. The same screens recorded with '
        'the timeline stream read none. '
        'Frames inside the startup window (`startupPhaseWindowSeconds` after '
        'Dart entry) do not count on either leg. On the VM leg, each scan '
        'reads the batch with the slowest raster frame since the last scan '
        'and clears it, so idle polls never judge old values; a route change '
        'clears it too. Each raster frame in a batch is set against the UI '
        'time of an average frame in that batch (UI total over raster '
        'frames), because the timeline does not pair them. When the frame '
        'leg fires and at least one VM frame since the last scan is over '
        'the budget with the ratio above 2.0, the issue is `confirmed`; '
        'otherwise it is `likely`, because Impeller raster durations can '
        'include present back-pressure. When no frames arrived since the '
        'last scan (`FrameTimingDetector` disabled), the VM leg emits on its '
        'own once one poll holds 3 such frames, critical at 10. '
        '`expensive_gpu_nodes` (structural) '
        'gates on a subtree size strictly above 5 over 4 RenderObject '
        'checks. These are `RenderOpacity` (an opacity-value short-circuit '
        'at 0.0 and 1.0, pinned by a 4-axis matrix), `RenderClipPath` '
        '(except the clip a transparency `Material` builds for its own '
        'shape), `RenderBackdropFilter` (3 sigma bands: at most 2.0 is '
        'suppressed, above 2.0 up to 10.0 is a warning highlight, above '
        '10.0 is a critical highlight; a disabled filter is skipped; the '
        'sigma is read from the filter fields, because profile builds drop '
        'the `toString` it was once parsed from; a blur composed with a '
        'matrix has no known sigma and counts; a blur drawn by a Cupertino '
        'bar or dialog names that widget) and `RenderShaderMask`. One more '
        'check runs at widget level (`element.widget is ColorFiltered`), '
        'because ColorFiltered has no public RenderObject type. The '
        '`expensive_gpu_nodes` issue severity is always `warning`. An '
        'Opacity-wrapping-Opacity test verifies the nested-expense '
        'subtree-stack arithmetic. For confidence, `expensive_gpu_nodes` is '
        '`likely` when either raster leg qualified and `possible` '
        'otherwise. The VM-disconnect setter removes a VM-sourced '
        '`raster_dominance`, returns a VM-confirmed frame-leg issue to '
        '`likely`, and downgrades `expensive_gpu_nodes` only when no '
        'frame-sourced `raster_dominance` remains. The detector has no '
        'runtime '
        'verification against Impeller or Skia budgets and no external '
        'citation.',
    reproducerPath: 'test/validation/gpu_pressure_reproducer_test.dart',
    coveredStableIds: {'raster_dominance', 'expensive_gpu_nodes'},
  );
}

/// Outcome of one frame-leg evaluation.
class _FrameLegResult {
  const _FrameLegResult({
    required this.qualifyingCount,
    required this.medianRatio,
    required this.critical,
    required this.identityUs,
  });

  /// Dominant frames in the qualifying one-second span.
  final int qualifyingCount;

  /// Median raster/UI ratio of the qualifying frames.
  final double medianRatio;

  /// At least [GpuPressureDetector.criticalRasterDominantFrames] frames
  /// fell in the qualifying span.
  final bool critical;

  /// `rasterFinishUs ?? vsyncStartUs` of the last qualifying frame.
  final int? identityUs;
}
