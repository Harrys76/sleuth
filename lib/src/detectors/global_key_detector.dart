import 'package:flutter/widgets.dart';

import '../models/base_detector.dart';
import '../models/performance_issue.dart';
import '../models/widget_highlight.dart';
import '../utils/fix_hint_builder.dart';
import '../utils/widget_location.dart';

/// Detects excessive GlobalKey usage inside scrollable widgets.
///
/// **Structural Detector** — counts user-assigned GlobalKey instances on
/// children of ListView, GridView, PageView (>10 prevents element recycling).
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

  int _globalKeyCount = 0;
  final List<String> _scrollableLocations = [];
  Rect? _parentRect;

  @override
  void prepareScan(BuildContext context) {
    _issues.clear();
    _highlights.clear();
    _globalKeyCount = 0;
    _scrollableLocations.clear();
    _parentRect = null;
  }

  @override
  void checkElement(Element element) {
    final widget = element.widget;

    if (widget is ListView || widget is GridView || widget is PageView) {
      final before = _globalKeyCount;
      _countUserGlobalKeys(element, (n) => _globalKeyCount += n);
      if (_globalKeyCount > before) {
        _scrollableLocations.add(buildAncestorChain(element));
        final ro = element.renderObject;
        if (ro != null) _parentRect = getGlobalRect(ro);
      }
    }
  }

  @override
  void finalizeScan() {
    if (_globalKeyCount > threshold) {
      if (_parentRect != null) {
        _highlights.add(WidgetHighlight(
          rect: _parentRect!,
          widgetName: 'Container',
          severity: _globalKeyCount > threshold * 3
              ? IssueSeverity.critical
              : IssueSeverity.warning,
          detectorName: 'GlobalKey',
          detail: '$_globalKeyCount GlobalKeys (threshold: $threshold)',
        ));
      }
      final locations =
          _scrollableLocations.take(5).map((chain) => '  • $chain').join('\n');
      final (hint, effort) =
          FixHintBuilder.excessiveGlobalKeys(count: _globalKeyCount);

      _issues.add(
        PerformanceIssue(
          stableId: 'excessive_global_keys',
          severity: _globalKeyCount > threshold * 3
              ? IssueSeverity.critical
              : IssueSeverity.warning,
          category: IssueCategory.build,
          confidence: IssueConfidence.possible,
          title: 'Excessive GlobalKeys: $_globalKeyCount in scrollable',
          detail: '$_globalKeyCount GlobalKey instances found on children of '
              'scrollable widgets. GlobalKeys prevent element '
              'recycling.\n\n$locations',
          fixHint: hint,
          fixEffort: effort,
          widgetName: 'Container',
          observationSource: ObservationSource.structural,
          detectedAt: DateTime.now(),
        ),
      );
    }
  }

  /// Walk the scrollable's full subtree and count GlobalKeys on
  /// user-level widgets (skip private types and known framework types).
  void _countUserGlobalKeys(Element scrollElement, void Function(int) add) {
    void check(Element element) {
      if (element.widget.key is GlobalKey) {
        final name = element.widget.runtimeType.toString();
        if (!name.startsWith('_') && !frameworkWidgets.contains(name)) {
          add(1);
        }
      }
      element.visitChildren(check);
    }

    scrollElement.visitChildren(check);
  }

  @override
  void dispose() {
    _issues.clear();
    _highlights.clear();
  }
}
