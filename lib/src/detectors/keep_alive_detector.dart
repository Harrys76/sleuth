import 'package:flutter/rendering.dart' show KeepAliveParentDataMixin;
import 'package:flutter/widgets.dart';

import '../models/base_detector.dart';
import '../validation/detector_metadata.dart';
import '../validation/evidence_tier.dart';
import '../models/performance_issue.dart';
import '../models/widget_highlight.dart';
import '../utils/fix_hint_builder.dart';
import '../utils/type_name_cache.dart';
import '../utils/widget_location.dart';

/// Returns true if [element] is an active `KeepAlive` wrapper.
///
/// Flutter's `AutomaticKeepAlive.build()` unconditionally returns
/// `KeepAlive(keepAlive: _keepingAlive, child: _child)`, but when a
/// descendant dispatches a `KeepAliveNotification` it updates the wrapped
/// child's render-object parent data **out of turn** via
/// `ParentDataElement.applyWidgetOutOfTurn()`. That call mutates the
/// child render object's parent data but does NOT update `element.widget`
/// on the `KeepAlive` element — so `widget.keepAlive` remains the stale
/// `false` value from the very first build. The authoritative signal is
/// the child render object's `KeepAliveParentDataMixin.keepAlive` flag.
bool _isActiveKeepAlive(Element element) {
  if (element.widget is! KeepAlive) return false;
  final renderObject = element.renderObject;
  final parentData = renderObject?.parentData;
  return parentData is KeepAliveParentDataMixin && parentData.keepAlive;
}

class _ScrollableAccumulator {
  _ScrollableAccumulator(this.element);
  final Element element;
  int count = 0;

  /// Total element count inside this scrollable (for avg subtree cost).
  int totalElements = 0;
}

/// Detects excessive AutomaticKeepAlive usage in PageView/TabBarView.
///
/// **Structural Detector** — >threshold keep-alive pages per scrollable wastes
/// memory. Only counts KeepAlive widgets inside PageView or TabBarView, where
/// entire pages/tabs are kept in memory. ListView/GridView keep-alives
/// are normal framework behavior and are not flagged.
class KeepAliveDetector extends BaseDetector
    with DetectorMetadataProvider {
  KeepAliveDetector({this.threshold = 5})
      : super(
          type: DetectorType.keepAlive,
          lifecycle: DetectorLifecycle.structural,
          name: 'Keep Alive',
          description: 'Detects excessive keep-alive pages (>5)',
        );

  final int threshold;
  final List<PerformanceIssue> _issues = [];
  final List<WidgetHighlight> _highlights = [];
  bool _isEnabled = true;

  @override
  List<PerformanceIssue> get issues => List.unmodifiable(_issues);

  @override
  List<WidgetHighlight> get highlights => List.unmodifiable(_highlights);

  @override
  bool get isEnabled => _isEnabled;

  @override
  set isEnabled(bool value) => _isEnabled = value;

  final List<
      ({
        String chain,
        int count,
        int totalElements,
        Rect? rect,
        String typeName,
      })> _scrollableData = [];
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
    final name = typeNameCache.lookup(widget);

    // Count KeepAlive for all active scrollables BEFORE pushing, so the
    // scrollable's own element isn't counted for itself.
    if (_scrollableStack.isNotEmpty) {
      // Track total element count for subtree cost enrichment.
      for (final acc in _scrollableStack) {
        acc.totalElements++;
      }

      // Only count KeepAlive widgets that are ACTIVELY keeping the subtree
      // alive. Flutter's AutomaticKeepAlive always wraps its child in a
      // `KeepAlive(keepAlive: _keepingAlive, ...)` (see
      // widgets/automatic_keep_alive.dart:281), so every materialized
      // TabBarView/PageView page has a KeepAlive node in its ancestry
      // regardless of whether the page opts in via
      // AutomaticKeepAliveClientMixin. Matching on type name alone would
      // count inactive wrappers as live keep-alives — a false positive
      // that flags any TabBarView with enough tabs, even ones with zero
      // wantKeepAlive opt-ins.
      //
      // We can't trust `element.widget.keepAlive` either: when
      // AutomaticKeepAlive activates, it calls
      // `ParentDataElement.applyWidgetOutOfTurn` which updates the child
      // render object's parent data but does NOT update `element.widget`
      // on the KeepAlive element. See `_isActiveKeepAlive` for details.
      if (_isActiveKeepAlive(element)) {
        for (final acc in _scrollableStack) {
          acc.count++;
        }
      }
    }

    // TabBarView checked by string to avoid material.dart import.
    if (widget is PageView || name == 'TabBarView') {
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
          totalElements: acc.totalElements,
          rect: element.renderObject != null
              ? getGlobalRect(element.renderObject!)
              : null,
          typeName: typeNameCache.lookup(element.widget),
        ));
      }
    }
  }

  @override
  void finalizeScan() {
    _scrollableStack.clear();
    for (final (i, data) in _scrollableData.indexed) {
      if (data.count > threshold) {
        final avgSubtreeSize =
            data.count > 0 ? data.totalElements ~/ data.count : 0;

        if (data.rect != null) {
          _highlights.add(WidgetHighlight(
            rect: data.rect!,
            widgetName: data.typeName,
            severity: data.count > threshold * 2
                ? IssueSeverity.critical
                : IssueSeverity.warning,
            detectorName: 'KeepAlive',
            detail: '${data.count} items kept alive in memory',
          ));
        }
        final (hint, effort) =
            FixHintBuilder.excessiveKeepAlive(count: data.count);

        final subtreeCostLine = avgSubtreeSize > 0
            ? '\n~$avgSubtreeSize elements per page '
                '(${data.totalElements} total in scrollable).'
            : '';

        _issues.add(
          PerformanceIssue(
            stableId: 'excessive_keep_alive:$i',
            severity: data.count > threshold * 2
                ? IssueSeverity.critical
                : IssueSeverity.warning,
            category: IssueCategory.memory,
            confidence: IssueConfidence.possible,
            title: 'Excessive Keep-Alive: ${data.count} in ${data.typeName}',
            detail: '${data.count} widgets are using '
                'AutomaticKeepAliveClientMixin, keeping them all in '
                'memory.$subtreeCostLine\n\n  • ${data.chain}',
            fixHint: hint,
            fixEffort: effort,
            widgetName: data.typeName,
            observationSource: ObservationSource.structural,
            confidenceReason:
                'Structural scan only — AutomaticKeepAliveClientMixin count',
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

  @override
  DetectorMetadata get validationMetadata => const DetectorMetadata(
        tier: EvidenceTier.unvalidated,
        rationale:
            'AutomaticKeepAlive-misuse structural heuristic. Not '
            'runtime-verified or externally cited.',
      );
}
