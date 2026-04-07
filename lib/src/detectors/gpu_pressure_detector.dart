import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../models/base_detector.dart';
import '../models/performance_issue.dart';
import '../models/widget_highlight.dart';
import '../utils/fix_hint_builder.dart';
import '../utils/widget_location.dart';
import '../vm/timeline_parser.dart';

/// Detects GPU pressure from expensive rendering operations.
///
/// **Hybrid Detector** — VM raster thread duration + render tree
/// to identify Opacity, ClipPath, BackdropFilter on deep subtrees.
class GpuPressureDetector extends BaseDetector {
  GpuPressureDetector({this.rasterMultiplierThreshold = 2.0})
      : super(
          type: DetectorType.gpuPressure,
          lifecycle: DetectorLifecycle.hybrid,
          name: 'GPU Pressure',
          description: 'Detects GPU bottlenecks (raster > UI × 2.0)',
        );

  /// Flag when raster time exceeds UI time by this factor.
  final double rasterMultiplierThreshold;
  final List<PerformanceIssue> _issues = [];
  final List<WidgetHighlight> _highlights = [];
  bool _isEnabled = true;

  /// BackdropFilter with blur sigma at or below this threshold is suppressed
  /// — the GPU cost is negligible for very small blurs.
  static const _lowSigmaThreshold = 2.0;

  /// BackdropFilter with blur sigma above this threshold gets critical severity.
  static const _highSigmaThreshold = 10.0;

  int _lastRasterUs = 0;
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
      _lastUiUs = 0;
      // Remove VM-backed raster dominance issue entirely.
      _issues.removeWhere((i) => i.stableId == 'raster_dominance');
      // Downgrade remaining structural issues to possible confidence.
      for (int i = 0; i < _issues.length; i++) {
        if (_issues[i].confidence != IssueConfidence.possible) {
          _issues[i] =
              _issues[i].copyWith(confidence: IssueConfidence.possible);
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
    final ratio = hasRasterTiming ? _lastRasterUs / _lastUiUs : 0.0;
    final hasRasterDominance =
        hasRasterTiming && ratio > rasterMultiplierThreshold;

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
          detail:
              'Raster thread (${(_lastRasterUs / 1000).toStringAsFixed(1)}ms) '
              'is ${ratio.toStringAsFixed(1)}× slower than UI thread '
              '(${(_lastUiUs / 1000).toStringAsFixed(1)}ms).',
          fixHint: hint,
          fixEffort: effort,
          observationSource: ObservationSource.vmTimeline,
          detectedAt: DateTime.now(),
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
}
