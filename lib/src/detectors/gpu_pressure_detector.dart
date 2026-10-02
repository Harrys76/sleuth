import 'dart:developer' show Timeline;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../sleuth.dart' show Sleuth;
import '../models/base_detector.dart';
import '../models/frame_stats.dart';
import '../validation/detector_metadata.dart';
import '../validation/evidence_tier.dart';
import '../models/performance_issue.dart';
import '../models/widget_highlight.dart';
import '../utils/fix_hint_builder.dart';
import '../utils/widget_location.dart';
import '../vm/timeline_parser.dart';

/// Detects GPU pressure from expensive rendering operations.
///
/// **Hybrid Detector** with three evidence sources:
///
/// * **Frame leg (every tier).** [processFrame] receives each presented
///   frame's `FrameTiming` UI (build + layout + paint) and raster durations.
///   A frame is raster-dominant when both durations are positive, raster
///   exceeds [effectiveMaxFrameRasterFloorUs], and raster exceeds
///   [rasterMultiplierThreshold] × UI. `raster_dominance` emits as `likely`
///   when at least [minRasterDominantFrames] dominant frames fall inside any
///   one-second span since the last scan. Frames that arrive within
///   [startupPhaseWindowSeconds] of Dart entry are ignored (cold-start
///   pipeline compilation belongs to `shader_compilation`).
/// * **VM leg.** Raster and UI timeline events from the VM, ignored inside
///   the same startup window. When it fires
///   it wins: `raster_dominance` is `confirmed` and carries the VM numbers.
/// * **Structural leg.** Opacity, ClipPath, BackdropFilter, ShaderMask and
///   ColorFiltered over deep subtrees (`expensive_gpu_nodes`).
///
/// The frame leg needs `FrameTimingDetector` enabled; without it no frames
/// arrive.
class GpuPressureDetector extends BaseDetector with DetectorMetadataProvider {
  GpuPressureDetector({
    this.rasterMultiplierThreshold = 2.0,
    this.maxFrameRasterFloorUs = 8000,
    this.minRasterDominantFrames = 3,
    this.startupPhaseWindowSeconds = 5,
    int? Function()? appStartMonotonicUsForTest,
  }) : assert(
         minRasterDominantFrames >= 1,
         'minRasterDominantFrames must be >= 1.',
       ),
       _appStartForTest = appStartMonotonicUsForTest,
       super(
         type: DetectorType.gpuPressure,
         lifecycle: DetectorLifecycle.hybrid,
         name: 'GPU Pressure',
         description: 'Detects GPU bottlenecks (raster > UI × 2.0 per frame)',
       );

  /// Flag when raster time exceeds UI time by this factor.
  final double rasterMultiplierThreshold;

  /// Suppress `raster_dominance` unless a single frame's raster time
  /// exceeds this floor (microseconds). On the VM leg the numerator is the
  /// worst single-frame raster scope in the batch; on the frame leg every
  /// dominant frame must clear it. Idle vsync frames with trivial UI work
  /// otherwise produce a misleading high ratio. Default 8000us (half of
  /// the 60Hz frame budget).
  final int maxFrameRasterFloorUs;

  /// Raster-dominant frames required inside one second for the frame leg
  /// to emit `raster_dominance`. Default 3. Severity is critical when that
  /// many frames in the qualifying span also had raster time above their
  /// own frame budget.
  final int minRasterDominantFrames;

  /// Frames arriving within this many seconds of
  /// [Sleuth.dartEntryMonotonicUs] do not count toward the frame leg. Same
  /// clock and window as `FrameTimingDetector`'s `lifecyclePhase`; the
  /// controller wires it from
  /// `DetectorThresholds.startupPhaseWindowSeconds`.
  final int startupPhaseWindowSeconds;

  /// Test-only override for the app-start monotonic anchor, mirroring
  /// `FrameTimingDetector`. Tests pass `() => Timeline.now - ageUs`.
  final int? Function()? _appStartForTest;

  int? _budgetFloorUs;

  /// Floor in effect: half the resolved frame budget once
  /// [updateFrameBudget] has been called, else [maxFrameRasterFloorUs].
  int get effectiveMaxFrameRasterFloorUs =>
      _budgetFloorUs ?? maxFrameRasterFloorUs;

  /// Sets the raster floor to half of [budgetUs]. Called by
  /// `SleuthController` when the resolved frame budget changes.
  void updateFrameBudget(int budgetUs) {
    if (budgetUs <= 0) return;
    _budgetFloorUs = budgetUs ~/ 2;
  }

  /// Restores the [maxFrameRasterFloorUs] floor.
  void resetFrameBudget() {
    _budgetFloorUs = null;
  }

  final List<PerformanceIssue> _issues = [];
  final List<WidgetHighlight> _highlights = [];
  bool _isEnabled = true;

  /// BackdropFilter with blur sigma at or below this threshold is suppressed
  /// — the GPU cost is negligible for very small blurs.
  static const _lowSigmaThreshold = 2.0;

  /// BackdropFilter with blur sigma above this threshold gets critical severity.
  static const _highSigmaThreshold = 10.0;

  int _lastRasterUs = 0;
  int _lastMaxFrameRasterUs = 0;
  int _lastUiUs = 0;
  bool _vmConnected = false;
  final List<String> _expensiveNodes = [];
  final List<int> _subtreeSizeStack = [];

  static const String _structuralOnlyReason =
      'Structural pattern only — no raster-dominant frames observed';

  // -- Frame leg --
  //
  // Frames since the last `_evaluate`. Dominant frames go into a fixed
  // 64-entry ring (parallel lists, no per-frame allocation) that drops the
  // oldest entry when full, so under sustained pressure the newest ~1 s of
  // frames at 60 Hz is always present. Everything resets after each scan.
  static const int _ringCapacity = 64;
  static const int _spanUs = 1000000;
  final List<int> _ringRasterUs = List<int>.filled(_ringCapacity, 0);
  final List<int> _ringUiUs = List<int>.filled(_ringCapacity, 0);
  final List<int> _ringAtUs = List<int>.filled(_ringCapacity, 0);
  final List<bool> _ringHasAt = List<bool>.filled(_ringCapacity, false);
  final List<int> _ringIdentityUs = List<int>.filled(_ringCapacity, 0);
  final List<bool> _ringHasIdentity = List<bool>.filled(_ringCapacity, false);
  final List<bool> _ringOverBudget = List<bool>.filled(_ringCapacity, false);
  int _ringCount = 0;
  int _ringWrite = 0;
  int _windowFrameCount = 0;
  int _dominantCount = 0;
  int _worstFrameRasterUs = 0;

  /// Frame-leg version of the last scan's `raster_dominance`, kept when the
  /// VM leg won that scan. A VM disconnect swaps it in so frame evidence
  /// already observed survives the loss of the VM.
  PerformanceIssue? _frameLegFallback;

  /// Current VM connectivity — set by the controller.
  ///
  /// On disconnect, clears stale VM timings, removes the VM-sourced
  /// `raster_dominance` (replaced by the frame-leg version when that leg
  /// also qualified), and downgrades other non-frame issues to `possible`.
  /// Frame-sourced issues are untouched, and `expensive_gpu_nodes` stays
  /// `likely` while a frame-sourced `raster_dominance` remains.
  bool get vmConnected => _vmConnected;
  @override
  set vmConnected(bool value) {
    _vmConnected = value;
    if (!value) {
      _lastRasterUs = 0;
      _lastMaxFrameRasterUs = 0;
      _lastUiUs = 0;
      final vmIndex = _issues.indexWhere(
        (i) =>
            i.stableId == 'raster_dominance' &&
            i.observationSource == ObservationSource.vmTimeline,
      );
      if (vmIndex != -1) {
        final fallback = _frameLegFallback;
        if (fallback != null) {
          _issues[vmIndex] = fallback;
        } else {
          _issues.removeAt(vmIndex);
        }
      }
      _frameLegFallback = null;
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
    if (data.rasterDurations.isNotEmpty) {
      _lastRasterUs = data.rasterDurations.fold(0, (s, d) => s + d);
      _lastMaxFrameRasterUs = data.rasterDurations.reduce(
        (a, b) => a > b ? a : b,
      );
    }
    final totalUi =
        data.totalBuildScopeUs +
        data.totalFlushLayoutUs +
        data.totalFlushPaintUs;
    if (totalUi > 0) _lastUiUs = totalUi;
  }

  @override
  void processFrame(FrameStats frame) {
    if (!_isEnabled) return;
    if (_insideStartupWindow()) return;
    _windowFrameCount++;
    final uiUs = frame.uiDuration.inMicroseconds;
    final rasterUs = frame.rasterDuration.inMicroseconds;
    if (uiUs <= 0 || rasterUs <= 0) return;
    if (rasterUs <= effectiveMaxFrameRasterFloorUs) return;
    if (rasterUs <= rasterMultiplierThreshold * uiUs) return;

    _dominantCount++;
    if (rasterUs > _worstFrameRasterUs) _worstFrameRasterUs = rasterUs;
    final i = _ringWrite;
    _ringRasterUs[i] = rasterUs;
    _ringUiUs[i] = uiUs;
    final atUs = frame.vsyncStartUs ?? frame.rasterFinishUs;
    _ringHasAt[i] = atUs != null;
    _ringAtUs[i] = atUs ?? 0;
    final identityUs = frame.rasterFinishUs ?? frame.vsyncStartUs;
    _ringHasIdentity[i] = identityUs != null;
    _ringIdentityUs[i] = identityUs ?? 0;
    _ringOverBudget[i] = rasterUs > frame.frameBudgetUs;
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

  void _resetFrameLeg() {
    _ringCount = 0;
    _ringWrite = 0;
    _windowFrameCount = 0;
    _dominantCount = 0;
    _worstFrameRasterUs = 0;
  }

  /// Finds the one-second span holding the most dominant frames (the most
  /// recent on ties). Frames without timestamps form one span of their own.
  /// Returns null when no span reaches [minRasterDominantFrames].
  _FrameLegResult? _evaluateFrameLeg() {
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
    for (var right = 0; right < timed.length; right++) {
      while (_ringAtUs[timed[right]] - _ringAtUs[timed[left]] >= _spanUs) {
        left++;
      }
      final count = right - left + 1;
      if (count >= bestCount) {
        bestCount = count;
        bestLeft = left;
      }
    }
    var bestSpan = timed.sublist(bestLeft, bestLeft + bestCount);
    if (untimed.length > bestCount) {
      bestCount = untimed.length;
      bestSpan = untimed;
    }
    if (bestCount < minRasterDominantFrames) return null;

    var overBudget = 0;
    final ratios = <double>[];
    for (final idx in bestSpan) {
      if (_ringOverBudget[idx]) overBudget++;
      ratios.add(_ringRasterUs[idx] / _ringUiUs[idx]);
    }
    ratios.sort();
    final mid = ratios.length ~/ 2;
    final median = ratios.length.isOdd
        ? ratios[mid]
        : (ratios[mid - 1] + ratios[mid]) / 2;
    final last = bestSpan.last;
    return _FrameLegResult(
      qualifyingCount: bestCount,
      medianRatio: median,
      critical: overBudget >= minRasterDominantFrames,
      identityUs: _ringHasIdentity[last] ? _ringIdentityUs[last] : null,
    );
  }

  @override
  void prepareScan(BuildContext context) {
    _expensiveNodes.clear();
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

    final ro = element.renderObject;
    if (ro == null) return;

    // Direct type checks — no runtimeType.toString() allocation.
    // Excludes RenderPhysicalModel/Shape (Card, Material) — these are
    // normal and hardware-accelerated in profile mode.
    // Note: `is RenderOpacity` correctly excludes RenderAnimatedOpacity
    // (which extends RenderProxyBox, not RenderOpacity) — the previous
    // contains('RenderOpacity') matched it as a false positive.
    String? typeName;
    double? backdropSigma;
    if (ro is RenderOpacity) {
      final val = ro.opacity;
      if (val >= 1.0 || val <= 0.0) return; // no-op or short-circuit
      typeName = 'RenderOpacity';
    } else if (ro is RenderClipPath) {
      typeName = 'RenderClipPath';
    } else if (ro is RenderBackdropFilter) {
      if (element.widget is BackdropFilter) {
        backdropSigma = _extractMaxBlurSigma(
          (element.widget as BackdropFilter).filter,
        );
        if (backdropSigma != null && backdropSigma <= _lowSigmaThreshold) {
          return;
        }
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
    _frameLegFallback = null;

    final frameLeg = _evaluateFrameLeg();
    final windowFrameCount = _windowFrameCount;
    final dominantCount = _dominantCount;
    final worstFrameRasterUs = _worstFrameRasterUs;
    _resetFrameLeg();

    final hasRasterTiming = vmConnected && _lastUiUs > 0 && _lastRasterUs > 0;
    // Numerator is the WORST single-frame raster scope, not aggregate
    // sum. Aggregate inflates whenever many idle vsync raster scopes
    // share a batch with little UI work — including the case of one
    // bad raster frame in an otherwise-idle batch. Tradeoff documented
    // in DetectorMetadata rationale.
    final ratio = hasRasterTiming ? _lastMaxFrameRasterUs / _lastUiUs : 0.0;
    final vmDominance =
        hasRasterTiming &&
        _lastMaxFrameRasterUs > effectiveMaxFrameRasterFloorUs &&
        ratio > rasterMultiplierThreshold;
    final hasRasterDominance = vmDominance || frameLeg != null;

    PerformanceIssue? frameIssue;
    if (frameLeg != null) {
      final (hint, effort) = FixHintBuilder.rasterDominance();
      final median = frameLeg.medianRatio.toStringAsFixed(1);
      frameIssue = PerformanceIssue(
        stableId: 'raster_dominance',
        severity: frameLeg.critical
            ? IssueSeverity.critical
            : IssueSeverity.warning,
        category: IssueCategory.raster,
        confidence: IssueConfidence.likely,
        title: 'Raster Dominance: $median× UI time',
        detail:
            '$dominantCount of $windowFrameCount frames since the last scan '
            'were raster-dominant, ${frameLeg.qualifyingCount} within one '
            'second (worst raster '
            '${(worstFrameRasterUs / 1000).toStringAsFixed(1)}ms, median '
            'ratio $median×).',
        fixHint: hint,
        fixEffort: effort,
        observationSource: ObservationSource.frameTiming,
        detectedAt: DateTime.now(),
        dedupIdentityMicros: frameLeg.identityUs,
        extraTraceArgs: {
          'source': 'frame_timing',
          'dominantFrameCount': dominantCount.toString(),
          'windowFrameCount': windowFrameCount.toString(),
          'worstFrameRasterUs': worstFrameRasterUs.toString(),
          'medianRatio': frameLeg.medianRatio.toStringAsFixed(2),
          'lifecyclePhase': 'steady',
        },
        confidenceReason: 'Per-frame FrameTiming raster vs UI durations',
      );
    }

    if (vmDominance) {
      final (hint, effort) = FixHintBuilder.rasterDominance();
      _issues.add(
        PerformanceIssue(
          stableId: 'raster_dominance',
          severity: ratio > rasterMultiplierThreshold * 2
              ? IssueSeverity.critical
              : IssueSeverity.warning,
          category: IssueCategory.raster,
          confidence: IssueConfidence.confirmed,
          title: 'Raster Dominance: ${ratio.toStringAsFixed(1)}× UI time',
          detail:
              'Worst-frame raster '
              '(${(_lastMaxFrameRasterUs / 1000).toStringAsFixed(1)}ms) is '
              '${ratio.toStringAsFixed(1)}× the UI thread total '
              '(${(_lastUiUs / 1000).toStringAsFixed(1)}ms).',
          fixHint: hint,
          fixEffort: effort,
          observationSource: ObservationSource.vmTimeline,
          detectedAt: DateTime.now(),
          confidenceReason: frameLeg != null
              ? 'Measured directly from VM timeline raster timing, '
                    'corroborated by $dominantCount raster-dominant frames'
              : 'Measured directly from VM timeline raster timing',
        ),
      );
      _frameLegFallback = frameIssue;
    } else if (frameIssue != null) {
      _issues.add(frameIssue);
    }

    if (_expensiveNodes.isNotEmpty) {
      final (hint, effort) = FixHintBuilder.expensiveGpuNodes();
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
              '${hasRasterDominance ? 'Raster-dominant frames coincided with ' : 'Found '}'
              'expensive render objects with deep subtrees:\n'
              '${_expensiveNodes.join("\n")}'
              '${noRasterTiming ? '\nNo raster timing observed yet.' : ''}',
          fixHint: hint,
          fixEffort: effort,
          observationSource: ObservationSource.structural,
          detectedAt: DateTime.now(),
          confidenceReason: hasRasterDominance
              ? 'Raster-dominant frames + structural render node scan'
              : _structuralOnlyReason,
        ),
      );
    }
  }

  /// Extract the maximum blur sigma from a [ui.ImageFilter].
  ///
  /// `_GaussianBlurImageFilter` is private — `toString()` returns
  /// `'ImageFilter.blur(sigmaX, sigmaY, TileMode.clamp)'`.
  // IDE analyzer false-positive: dart:core RegExp uses @Deprecated.implement
  // (fires only on subclassing). Remove when analyzer-server recognizes the
  // implement-only kind.
  static final _blurSigmaRegExp =
      // ignore: deprecated_member_use
      RegExp(r'ImageFilter\.blur\((\d+\.?\d*),\s*(\d+\.?\d*)');

  static double? _extractMaxBlurSigma(ui.ImageFilter? filter) {
    if (filter == null) return null;
    final match = _blurSigmaRegExp.firstMatch(filter.toString());
    if (match == null) return null;
    final sigmaX = double.tryParse(match.group(1)!);
    final sigmaY = double.tryParse(match.group(2)!);
    if (sigmaX == null || sigmaY == null) return null;
    return sigmaX > sigmaY ? sigmaX : sigmaY;
  }

  @override
  void dispose() {
    _issues.clear();
    _highlights.clear();
    _expensiveNodes.clear();
    _subtreeSizeStack.clear();
    _resetFrameLeg();
    _frameLegFallback = null;
  }

  @override
  DetectorMetadata get validationMetadata => const DetectorMetadata(
    tier: EvidenceTier.reproducerOnly,
    rationale:
        'Hybrid detector with a frame leg, a VM leg and a structural leg. '
        'Frame leg (every tier): `processFrame` reads per-frame '
        '`FrameTiming` UI (build + layout + paint) and raster durations. '
        'A frame is raster-dominant when UI > 0, raster > 0, raster > the '
        'per-frame floor (default 8000us; half the resolved frame budget '
        'once the controller supplies one) and raster > 2.0 × UI. '
        '`raster_dominance` emits `likely` (source `frameTiming`) when at '
        'least 3 dominant frames fall inside any 1 s span since the last '
        'scan, over a 64-entry ring that drops the oldest; critical when 3 '
        'frames in that span also exceeded their frame budget. Frames inside '
        'the startup window (`startupPhaseWindowSeconds` after Dart entry) '
        'do not count, on either leg. VM leg: ratio = worst single-frame raster scope / '
        'UI thread total (`TimelineParser.parse()` output), strict `> 2.0`, '
        'critical at `> 4.0`, same per-frame floor, requires '
        '`vmConnected && _lastUiUs > 0 && _lastRasterUs > 0`. When both legs '
        'qualify one `raster_dominance` is emitted from the VM leg '
        '(`confirmed`), its reason noting the frame corroboration. '
        'Tradeoff: the VM UI denominator is aggregate, so sustained '
        'moderate raster across an active batch may under-classify on that '
        'leg; the frame leg compares per frame. Impeller raster durations '
        'can include present back-pressure, so the frame leg stays '
        '`likely`. `expensive_gpu_nodes` (structural): subtree-size strict '
        '`> 5` gate over 4 RenderObject checks (`RenderOpacity` with '
        'opacity-value short-circuit at 0.0 / 1.0 pinned by 4-axis '
        'matrix; `RenderClipPath`; `RenderBackdropFilter` with sigma '
        '3-band — ≤ 2.0 suppressed, (2.0, 10.0] warning highlight, '
        '> 10.0 critical highlight; `RenderShaderMask`) plus 1 '
        'widget-level check (`element.widget is ColorFiltered`; '
        'no public RenderObject type for ColorFiltered). The '
        '`expensive_gpu_nodes` issue severity is always `warning`. '
        'Nested-expense subtree-stack arithmetic verified by '
        'Opacity-wrapping-Opacity test. Confidence correlation: '
        '`expensive_gpu_nodes` is `likely` when either raster leg '
        'qualified, `possible` otherwise. VM-disconnect setter removes '
        'only the VM-sourced `raster_dominance` (swapping in the frame-leg '
        'version when that leg also qualified), leaves frame-sourced issues '
        'untouched, and downgrades `expensive_gpu_nodes` only when no '
        'frame-sourced `raster_dominance` remains. Not runtime-verified '
        'against Impeller/Skia budgets or externally cited.',
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

  /// At least [GpuPressureDetector.minRasterDominantFrames] qualifying
  /// frames had raster time above their frame budget.
  final bool critical;

  /// `rasterFinishUs ?? vsyncStartUs` of the last qualifying frame.
  final int? identityUs;
}
