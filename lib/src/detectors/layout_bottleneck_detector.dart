import 'package:flutter/widgets.dart';

import '../models/base_detector.dart';
import '../models/performance_issue.dart';
import '../models/widget_highlight.dart';
import '../utils/fix_hint_builder.dart';
import '../utils/widget_location.dart';

/// Detects intrinsic dimension render objects that cause layout bottlenecks.
///
/// **Structural Detector** — scans render tree for RenderIntrinsicHeight/Width.
/// Nested intrinsics are escalated to critical severity (exponential layout).
class LayoutBottleneckDetector extends BaseDetector {
  LayoutBottleneckDetector()
      : super(
          type: DetectorType.layoutBottleneck,
          lifecycle: DetectorLifecycle.structural,
          name: 'Layout Bottleneck',
          description: 'Detects RenderIntrinsicHeight/Width nodes',
        );

  final List<PerformanceIssue> _issues = [];
  final List<WidgetHighlight> _highlights = [];
  final List<({String name, bool nested})> _found = [];
  final List<({int childCount, String location})> _wrapFindings = [];
  int _intrinsicDepth = 0;
  bool _isEnabled = true;

  /// Threshold for Wrap child count — above this, non-virtualized layout
  /// becomes costly (all children measured every frame).
  static const _wrapChildThreshold = 30;

  @override
  List<PerformanceIssue> get issues => List.unmodifiable(_issues);

  @override
  List<WidgetHighlight> get highlights => List.unmodifiable(_highlights);

  @override
  bool get isEnabled => _isEnabled;

  @override
  set isEnabled(bool value) => _isEnabled = value;

  @override
  void prepareScan(BuildContext context) {
    _issues.clear();
    _highlights.clear();
    _found.clear();
    _wrapFindings.clear();
    _intrinsicDepth = 0;
  }

  /// Framework widgets that use IntrinsicHeight/IntrinsicWidth internally.
  /// Developers cannot control this usage, so flagging it is noise.
  static const _frameworkIntrinsicParents = {
    'DropdownButton',
    'DropdownButtonFormField',
    'PopupMenuButton',
    'AlertDialog',
    'SimpleDialog',
    'ExpansionTile',
  };

  /// Walk up the element tree (max [_maxAncestorLookup] levels) to check
  /// if a framework widget is an ancestor of this intrinsic node.
  static const _maxAncestorLookup = 10;

  bool _isInsideFrameworkWidget(Element element) {
    int depth = 0;
    bool found = false;
    element.visitAncestorElements((ancestor) {
      if (depth >= _maxAncestorLookup) return false;
      depth++;
      final name = ancestor.widget.runtimeType.toString();
      // Handle generic types like DropdownButton<String>
      final baseName =
          name.contains('<') ? name.substring(0, name.indexOf('<')) : name;
      if (_frameworkIntrinsicParents.contains(baseName)) {
        found = true;
        return false;
      }
      return true;
    });
    return found;
  }

  @override
  void checkElement(Element element) {
    final widget = element.widget;

    // Detect Wrap with excessive children — non-virtualized layout means all
    // children are measured every frame regardless of visibility.
    if (widget is Wrap) {
      int childCount = 0;
      element.visitChildren((_) => childCount++);
      if (childCount > _wrapChildThreshold) {
        _wrapFindings.add(
            (childCount: childCount, location: buildAncestorChain(element)));
        final ro = element.renderObject;
        if (ro != null) {
          final rect = getGlobalRect(ro);
          if (rect != null) {
            _highlights.add(WidgetHighlight(
              rect: rect,
              widgetName: 'Wrap',
              severity: childCount > _wrapChildThreshold * 2
                  ? IssueSeverity.critical
                  : IssueSeverity.warning,
              detectorName: 'Layout',
              detail: 'Wrap with $childCount children — non-virtualized layout',
            ));
          }
        }
      }
    }

    if (widget is IntrinsicHeight || widget is IntrinsicWidth) {
      final isNested = _intrinsicDepth > 0;
      _intrinsicDepth++; // Always increment — afterElement always decrements.

      // Suppress intrinsics that are internal to framework widgets.
      if (_isInsideFrameworkWidget(element)) return;

      final widgetName =
          widget is IntrinsicHeight ? 'IntrinsicHeight' : 'IntrinsicWidth';
      _found.add((name: widgetName, nested: isNested));
      final ro = element.renderObject;
      if (ro != null) {
        final rect = getGlobalRect(ro);
        if (rect != null) {
          _highlights.add(WidgetHighlight(
            rect: rect,
            widgetName: widgetName,
            severity: isNested ? IssueSeverity.critical : IssueSeverity.warning,
            detectorName: 'Layout',
            detail: isNested
                ? 'Nested intrinsic — O(N²+) layout'
                : 'Causes O(N^2) layout passes',
          ));
        }
      }
    }
  }

  @override
  void afterElement(Element element) {
    final widget = element.widget;
    if (widget is IntrinsicHeight || widget is IntrinsicWidth) {
      _intrinsicDepth--;
    }
  }

  @override
  void finalizeScan() {
    if (_found.isNotEmpty) {
      final hasNested = _found.any((f) => f.nested);
      final locations = _found.take(5).map((f) {
        final prefix = f.nested ? '⚠ ' : '';
        return '  • $prefix${f.name}${f.nested ? ' (nested)' : ''}';
      }).join('\n');
      final (hint, effort) = FixHintBuilder.layoutBottleneck();

      _issues.add(PerformanceIssue(
        stableId: 'layout_bottleneck',
        severity: hasNested ? IssueSeverity.critical : IssueSeverity.warning,
        category: IssueCategory.layout,
        // confirmed: IntrinsicHeight/Width always triggers two-pass layout
        // (framework guarantee — not a heuristic)
        confidence: IssueConfidence.confirmed,
        title: hasNested
            ? 'Nested Layout Bottleneck: ${_found.length} intrinsic nodes'
            : 'Layout Bottleneck: ${_found.length} intrinsic nodes',
        detail: hasNested
            ? 'Found ${_found.length} IntrinsicHeight/IntrinsicWidth widgets '
                'including nested intrinsics. Nesting multiplies layout '
                'passes exponentially.\n\n$locations'
            : 'Found ${_found.length} IntrinsicHeight/IntrinsicWidth '
                'widgets. These cause O(N²) layout passes.\n\n$locations',
        fixHint: hint,
        fixEffort: effort,
        observationSource: ObservationSource.structural,
        detectedAt: DateTime.now(),
      ));
    }

    // Emit Wrap bottleneck issues
    for (final wrap in _wrapFindings) {
      final (hint, effort) = FixHintBuilder.wrapBottleneck(
        childCount: wrap.childCount,
        ancestorChain: wrap.location,
      );
      _issues.add(PerformanceIssue(
        stableId: 'wrap_layout_bottleneck',
        severity: wrap.childCount > _wrapChildThreshold * 2
            ? IssueSeverity.critical
            : IssueSeverity.warning,
        category: IssueCategory.layout,
        confidence: IssueConfidence.possible,
        title: 'Wrap Layout Bottleneck: ${wrap.childCount} children',
        detail: 'Wrap with ${wrap.childCount} children is non-virtualized '
            '— all children are laid out every frame regardless of '
            'visibility.\n\n  • ${wrap.location}',
        fixHint: hint,
        fixEffort: effort,
        observationSource: ObservationSource.structural,
        detectedAt: DateTime.now(),
      ));
    }
  }

  @override
  void dispose() {
    _issues.clear();
    _highlights.clear();
    _found.clear();
    _wrapFindings.clear();
    _intrinsicDepth = 0;
  }
}
