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
  GpuPressureDetector({this.rasterMultiplierThreshold = 1.5})
      : super(
          type: DetectorType.gpuPressure,
          lifecycle: DetectorLifecycle.hybrid,
          name: 'GPU Pressure',
          description: 'Detects GPU bottlenecks (raster > UI × 1.5)',
        );

  /// Flag when raster time exceeds UI time by this factor.
  final double rasterMultiplierThreshold;
  final List<PerformanceIssue> _issues = [];
  final List<WidgetHighlight> _highlights = [];
  bool _isEnabled = true;

  int _lastRasterUs = 0;
  int _lastUiUs = 0;
  bool _vmConnected = false;
  final List<String> _expensiveNodes = [];

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

  /// Scan render tree for expensive GPU operations.
  @override
  void scanTree(BuildContext context) {
    if (!_isEnabled) return;
    _expensiveNodes.clear();
    _highlights.clear();

    void visitor(Element element) {
      final ro = element.renderObject;

      if (ro != null) {
        final typeName = ro.runtimeType.toString();
        // Detect truly expensive render objects.
        // Excludes RenderPhysicalModel/Shape (Card, Material) — these are
        // normal and hardware-accelerated in profile mode.
        if (typeName.contains('RenderOpacity') ||
            typeName.contains('RenderClipPath') ||
            typeName.contains('RenderBackdropFilter') ||
            typeName.contains('RenderShaderMask')) {
          // Check if it has a deep subtree (more than 5 descendants)
          int nodeCount = 0;
          void countNodes(Element child) {
            nodeCount++;
            if (nodeCount < 20) child.visitChildren(countNodes);
          }

          element.visitChildren(countNodes);
          if (nodeCount > 5) {
            _expensiveNodes.add('$typeName ($nodeCount descendants)');
            final rect = getGlobalRect(ro);
            if (rect != null) {
              _highlights.add(WidgetHighlight(
                rect: rect,
                widgetName: element.widget.runtimeType.toString(),
                severity: IssueSeverity.warning,
                detectorName: 'GPU',
                detail: '$typeName with $nodeCount descendants',
              ));
            }
          }
        }
      }

      element.visitChildren(visitor);
    }

    try {
      context.visitChildElements(visitor);
    } catch (_) {}

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

  @override
  void dispose() {
    _issues.clear();
    _highlights.clear();
    _expensiveNodes.clear();
  }
}
