import 'package:flutter/widgets.dart';

import '../models/base_detector.dart';
import '../models/performance_issue.dart';
import '../models/widget_highlight.dart';
import '../utils/fix_hint_builder.dart';
import '../utils/widget_location.dart';

class _ScrollableAccumulator {
  _ScrollableAccumulator(this.element);
  final Element element;
  int count = 0;
}

/// Detects excessive GlobalKey usage inside scrollable widgets.
///
/// **Structural Detector** — counts user-assigned GlobalKey instances on
/// children of ListView, GridView, PageView per-scrollable (>threshold
/// prevents element recycling).
class GlobalKeyDetector extends BaseDetector {
  GlobalKeyDetector({this.threshold = 20})
      : super(
          type: DetectorType.globalKey,
          lifecycle: DetectorLifecycle.structural,
          name: 'Global Key',
          description: 'Detects excessive GlobalKey usage (>20) in scrollables',
        );

  final int threshold;
  final List<PerformanceIssue> _issues = [];
  final List<WidgetHighlight> _highlights = [];
  bool _isEnabled = true;

  /// Framework widget types that use GlobalKeys for internal plumbing.
  /// Users never assign GlobalKeys to these types.
  static const frameworkWidgets = {
    'KeyedSubtree',
    'RawGestureDetector',
    'IgnorePointer',
    'Padding',
    'Semantics',
    'Actions',
    'Shortcuts',
    'Focus',
    'FocusScope',
    'FocusTrapArea',
    'Builder',
    'Listener',
    'MouseRegion',
    'MergeSemantics',
    'BlockSemantics',
    'ExcludeSemantics',
  };

  @override
  List<PerformanceIssue> get issues => List.unmodifiable(_issues);

  @override
  List<WidgetHighlight> get highlights => List.unmodifiable(_highlights);

  @override
  bool get isEnabled => _isEnabled;

  @override
  set isEnabled(bool value) => _isEnabled = value;

  final List<({String chain, int count, Rect? rect, String typeName})>
      _scrollableData = [];
  final List<_ScrollableAccumulator> _scrollableStack = [];

  @override
  void prepareScan(BuildContext context) {
    _issues.clear();
    _highlights.clear();
    _scrollableData.clear();
    _scrollableStack.clear();
  }

  @override
  void checkElement(Element element) {
    final widget = element.widget;

    // Count GlobalKey for all active scrollables BEFORE pushing, so the
    // scrollable's own key isn't counted for itself (matches current behavior
    // where _countUserGlobalKeys starts from scrollElement.visitChildren).
    if (_scrollableStack.isNotEmpty && widget.key is GlobalKey) {
      final name = widget.runtimeType.toString();
      if (!name.startsWith('_') && !frameworkWidgets.contains(name)) {
        for (final acc in _scrollableStack) {
          acc.count++;
        }
      }
    }

    // Push if this is a scrollable type.
    if (widget is ListView || widget is GridView || widget is PageView) {
      _scrollableStack.add(_ScrollableAccumulator(element));
    }
  }

  @override
  void afterElement(Element element) {
    if (_scrollableStack.isNotEmpty &&
        identical(_scrollableStack.last.element, element)) {
      final acc = _scrollableStack.removeLast();
      if (acc.count > 0) {
        _scrollableData.add((
          chain: buildAncestorChain(element),
          count: acc.count,
          rect: element.renderObject != null
              ? getGlobalRect(element.renderObject!)
              : null,
          typeName: element.widget.runtimeType.toString(),
        ));
      }
    }
  }

  @override
  void finalizeScan() {
    _scrollableStack.clear();
    for (final (i, data) in _scrollableData.indexed) {
      if (data.count > threshold) {
        if (data.rect != null) {
          _highlights.add(WidgetHighlight(
            rect: data.rect!,
            widgetName: data.typeName,
            severity: data.count > threshold * 3
                ? IssueSeverity.critical
                : IssueSeverity.warning,
            detectorName: 'GlobalKey',
            detail: '${data.count} GlobalKeys (threshold: $threshold)',
          ));
        }
        final (hint, effort) =
            FixHintBuilder.excessiveGlobalKeys(count: data.count);

        _issues.add(
          PerformanceIssue(
            stableId: 'excessive_global_keys:$i',
            severity: data.count > threshold * 3
                ? IssueSeverity.critical
                : IssueSeverity.warning,
            category: IssueCategory.build,
            confidence: IssueConfidence.possible,
            title: 'Excessive GlobalKeys: ${data.count} in ${data.typeName}',
            detail: '${data.count} GlobalKey instances in ${data.typeName}. '
                'GlobalKeys prevent element recycling.\n\n  • ${data.chain}',
            fixHint: hint,
            fixEffort: effort,
            widgetName: data.typeName,
            observationSource: ObservationSource.structural,
            detectedAt: DateTime.now(),
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _issues.clear();
    _highlights.clear();
    _scrollableData.clear();
    _scrollableStack.clear();
  }
}
