import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../models/base_detector.dart';
import '../validation/detector_metadata.dart';
import '../validation/evidence_tier.dart';
import '../models/performance_issue.dart';
import '../models/widget_highlight.dart';
import '../utils/fix_hint_builder.dart';
import '../utils/widget_location.dart';
import '../vm/timeline_parser.dart';

/// Detects GPU pressure from expensive rendering operations.
///
/// **Hybrid Detector** — VM raster thread duration + render tree
/// to identify Opacity, ClipPath, BackdropFilter on deep subtrees.
class GpuPressureDetector extends BaseDetector with DetectorMetadataProvider {
  GpuPressureDetector({
    this.rasterMultiplierThreshold = 2.0,
    this.maxFrameRasterFloorUs = 8000,
  }) : super(
          type: DetectorType.gpuPressure,
          lifecycle: DetectorLifecycle.hybrid,
          name: 'GPU Pressure',
          description: 'Detects GPU bottlenecks (raster > UI × 2.0)',
        );

  /// Flag when raster time exceeds UI time by this factor.
  final double rasterMultiplierThreshold;

  /// Suppress `raster_dominance` unless the worst single-frame raster
  /// scope in the batch exceeds this floor (microseconds). Aggregate
  /// raster sums across many vsync-driven idle frames + trivial UI
  /// work otherwise produce a misleading high ratio. Default 8000us
  /// (half of 60Hz frame budget) — single bad frame must exceed half
  /// budget for raster to qualify as the bottleneck.
  final int maxFrameRasterFloorUs;
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

  /// Current VM connectivity — set by the controller.
  /// Clears stale VM timings and VM-backed issues immediately on disconnect.
  bool get vmConnected => _vmConnected;
  @override
  set vmConnected(bool value) {
    _vmConnected = value;
    if (!value) {
      _lastRasterUs = 0;
      _lastMaxFrameRasterUs = 0;
      _lastUiUs = 0;
      // Remove VM-backed raster dominance issue entirely.
      _issues.removeWhere((i) => i.stableId == 'raster_dominance');
      // Downgrade remaining structural issues to possible confidence.
      for (int i = 0; i < _issues.length; i++) {
        if (_issues[i].confidence != IssueConfidence.possible) {
          _issues[i] = _issues[i].copyWith(
            confidence: IssueConfidence.possible,
            confidenceReason:
                'Structural pattern only — connect VM for higher confidence',
          );
        }
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
    if (data.rasterDurations.isNotEmpty) {
      _lastRasterUs = data.rasterDurations.fold(0, (s, d) => s + d);
      _lastMaxFrameRasterUs =
          data.rasterDurations.reduce((a, b) => a > b ? a : b);
    }
    final totalUi = data.totalBuildScopeUs +
        data.totalFlushLayoutUs +
        data.totalFlushPaintUs;
    if (totalUi > 0) _lastUiUs = totalUi;
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
        backdropSigma =
            _extractMaxBlurSigma((element.widget as BackdropFilter).filter);
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
        _highlights.add(WidgetHighlight(
          rect: rect,
          widgetName: typeName, // known from type check — no toString()
          severity: highlightSeverity,
          detectorName: 'GPU',
          detail: highlightDetail,
        ));
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

    final hasRasterTiming = vmConnected && _lastUiUs > 0 && _lastRasterUs > 0;
    // Numerator is the WORST single-frame raster scope, not aggregate
    // sum. Aggregate inflates whenever many idle vsync raster scopes
    // share a batch with little UI work — including the case of one
    // bad raster frame in an otherwise-idle batch. Tradeoff documented
    // in DetectorMetadata rationale.
    final ratio = hasRasterTiming ? _lastMaxFrameRasterUs / _lastUiUs : 0.0;
    final hasRasterDominance = hasRasterTiming &&
        _lastMaxFrameRasterUs > maxFrameRasterFloorUs &&
        ratio > rasterMultiplierThreshold;

    if (hasRasterDominance) {
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
          detail: 'Worst-frame raster '
              '(${(_lastMaxFrameRasterUs / 1000).toStringAsFixed(1)}ms) is '
              '${ratio.toStringAsFixed(1)}× the UI thread total '
              '(${(_lastUiUs / 1000).toStringAsFixed(1)}ms).',
          fixHint: hint,
          fixEffort: effort,
          observationSource: ObservationSource.vmTimeline,
          detectedAt: DateTime.now(),
          confidenceReason: 'Measured directly from VM timeline raster timing',
        ),
      );
    }

    if (_expensiveNodes.isNotEmpty) {
      final (hint, effort) = FixHintBuilder.expensiveGpuNodes();
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
              '${!vmConnected ? '\nVM unavailable — raster timing unknown.' : ''}',
          fixHint: hint,
          fixEffort: effort,
          observationSource: ObservationSource.structural,
          detectedAt: DateTime.now(),
          confidenceReason: hasRasterDominance
              ? 'Raster dominance timing + structural render node scan'
              : 'Structural pattern only — connect VM for higher confidence',
        ),
      );
    }
  }

  /// Extract the maximum blur sigma from a [ui.ImageFilter].
  ///
  /// `_GaussianBlurImageFilter` is private — `toString()` returns
  /// `'ImageFilter.blur(sigmaX, sigmaY, TileMode.clamp)'`.
  static final _blurSigmaRegExp =
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
  }

  @override
  DetectorMetadata get validationMetadata => const DetectorMetadata(
        tier: EvidenceTier.reproducerOnly,
        rationale: 'Hybrid detector. v0.17.5 tier-quality audit: VM leg '
            'feeds raster + UI timeline events through '
            '`TimelineParser.parse()` into the detector — closes the '
            'parser-boundary gap. Two families pinned. '
            '`raster_dominance` (VM): ratio = `_lastMaxFrameRasterUs / '
            '_lastUiUs` with strict `> 2.0` threshold; critical at `> 4.0`. '
            'Numerator is the WORST single-frame raster scope (not aggregate) '
            'so idle vsync raster scopes cannot inflate the ratio. Two '
            'preconditions: `hasRasterTiming` (`vmConnected && _lastUiUs > 0 '
            '&& _lastRasterUs > 0`) and `_lastMaxFrameRasterUs > '
            'maxFrameRasterFloorUs` (default 8000us = half 60Hz budget). '
            'Tradeoff: sustained moderate raster across an active multi-frame '
            'batch may under-classify (UI denominator is still aggregate); a '
            'per-frame UI proxy would close that gap. '
            '`expensive_gpu_nodes` (structural): subtree-size strict `> 5` '
            'gate over 4 RenderObject checks (`RenderOpacity` with '
            'opacity-value short-circuit at 0.0 / 1.0 pinned by 4-axis '
            'matrix; `RenderClipPath`; `RenderBackdropFilter` with sigma '
            '3-band — ≤ 2.0 suppressed, (2.0, 10.0] warning highlight, '
            '> 10.0 critical highlight; `RenderShaderMask`) plus 1 '
            'widget-level check (`element.widget is ColorFiltered`; '
            'no public RenderObject type for ColorFiltered). The '
            '`expensive_gpu_nodes` issue severity is always `warning` — '
            'the high-sigma "critical" only escalates the corresponding '
            '`WidgetHighlight` entry. Nested-expense '
            'subtree-stack arithmetic verified by Opacity-wrapping-'
            'Opacity test. Confidence correlation: `expensive_gpu_nodes` '
            'is `likely` only when `hasRasterDominance` true; `possible` '
            'in 3 sub-cases — vmConnected=false, vmConnected=true with no '
            'raster, and vmConnected=true with ratio ≤ 2.0. VM-disconnect '
            'setter removes `raster_dominance` and downgrades '
            '`expensive_gpu_nodes` confidence in-place. `_vmConnected` '
            'defaults to false; reproducer setUp explicitly sets true so '
            'VM-backed tests are not silently routed into structural '
            'fallback. Not runtime-verified against Impeller/Skia '
            'budgets or externally cited.',
        reproducerPath: 'test/validation/gpu_pressure_reproducer_test.dart',
        coveredStableIds: {'raster_dominance', 'expensive_gpu_nodes'},
      );
}
