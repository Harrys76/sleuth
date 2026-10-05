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
  _ScrollableAccumulator(
    this.element, {
    Element? reportAs,
    this.isBarrier = false,
  }) : reportAs = reportAs ?? element;
  final Element element;

  /// Element whose name, chain, and rect the issue reports. A
  /// `TabBarView`'s internal `PageView` reports as the `TabBarView`.
  final Element reportAs;

  /// A non-page scrollable (ListView, GridView, CustomScrollView, ...).
  /// Keep-alives directly under it belong to it and are never counted;
  /// barriers never emit and take no index.
  final bool isBarrier;
  int count = 0;

  /// Total element count inside this scrollable (for avg subtree cost).
  int totalElements = 0;
}

/// Detects excessive AutomaticKeepAlive usage in PageView/TabBarView.
///
/// **Structural Detector** — >threshold keep-alive pages per scrollable wastes
/// memory. Only counts KeepAlive widgets inside PageView or TabBarView, where
/// entire pages/tabs are kept in memory. Each keep-alive counts toward the
/// innermost enclosing scrollable only, so a TabBarView (which builds a
/// PageView) reports once. ListView/GridView keep-alives are normal
/// framework behavior: those scrollables act as barriers and are not
/// flagged.
class KeepAliveDetector extends BaseDetector with DetectorMetadataProvider {
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
      RenderObject? renderObject,
      String typeName,
      String idSuffix,
    })
  >
  _scrollableData = [];
  final List<_ScrollableAccumulator> _scrollableStack = [];

  /// Same-type ordinal of each unkeyed reported scrollable, in post-order,
  /// and the next ordinal per type. Every page scrollable takes one,
  /// whether or not it keeps pages alive, so an id holds when another
  /// scrollable starts keeping pages alive.
  final Map<Element, int> _ordinals = {};
  final Map<String, int> _nextOrdinal = {};

  /// Longest key part of an id.
  static const int _maxKeyLength = 24;

  static final RegExp _unsafeIdChars = RegExp(r'[^A-Za-z0-9_-]');

  /// The part of `excessive_keep_alive:<TypeName>~<part>` after `~`: the
  /// scrollable's `ValueKey` value when it is a string or number (chars
  /// outside `[A-Za-z0-9_-]` become `_`, cut to 24), else the
  /// same-type ordinal.
  String _idPart(Element report, String typeName) {
    final key = report.widget.key;
    if (key is ValueKey) {
      final value = key.value;
      if (value is String || value is num) {
        var text = '$value'.replaceAll(_unsafeIdChars, '_');
        if (text.length > _maxKeyLength) {
          text = text.substring(0, _maxKeyLength);
        }
        if (text.isNotEmpty) return text;
      }
    }
    final ordinal = _ordinals[report] ??= (_nextOrdinal[typeName] =
        (_nextOrdinal[typeName] ?? 0) + 1);
    return '$ordinal';
  }

  /// Reported type name as an id part: generic arguments dropped, chars
  /// outside `[A-Za-z0-9_-]` removed.
  static String _idTypeName(String typeName) =>
      baseTypeName(typeName).replaceAll(_unsafeIdChars, '');

  @override
  void prepareScan(BuildContext context) {
    _issues.clear();
    _highlights.clear();
    _scrollableData.clear();
    _scrollableStack.clear();
    _ordinals.clear();
    _nextOrdinal.clear();
  }

  @override
  void checkElement(Element element) {
    final widget = element.widget;
    final name = typeNameCache.lookup(widget);

    // Count KeepAlive for the innermost scrollable BEFORE pushing, so the
    // scrollable's own element isn't counted for itself.
    if (_scrollableStack.isNotEmpty) {
      // Track total element count for subtree cost enrichment.
      for (final acc in _scrollableStack) {
        if (!acc.isBarrier) acc.totalElements++;
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
      //
      // Only the innermost scrollable owns the keep-alive. When that is a
      // barrier (ListView etc.), the keep-alive is a list item, not a page.
      final innermost = _scrollableStack.last;
      if (!innermost.isBarrier && _isActiveKeepAlive(element)) {
        innermost.count++;
      }
    }

    // TabBarView checked by string to avoid material.dart import.
    if (widget is PageView || name == 'TabBarView') {
      // A PageView directly inside a TabBarView accumulator is the
      // TabBarView's own PageView; report it under the TabBarView.
      final enclosing = _scrollableStack.isEmpty ? null : _scrollableStack.last;
      final reportAs =
          widget is PageView &&
              enclosing != null &&
              !enclosing.isBarrier &&
              typeNameCache.lookup(enclosing.element.widget) == 'TabBarView'
          ? enclosing.element
          : null;
      _scrollableStack.add(_ScrollableAccumulator(element, reportAs: reportAs));
    } else if (widget is ScrollView ||
        widget is NestedScrollView ||
        widget is SingleChildScrollView) {
      _scrollableStack.add(_ScrollableAccumulator(element, isBarrier: true));
    }
  }

  @override
  void afterElement(Element element) {
    if (_scrollableStack.isNotEmpty &&
        identical(_scrollableStack.last.element, element)) {
      final acc = _scrollableStack.removeLast();
      if (acc.isBarrier) return;
      final report = acc.reportAs;
      final typeName = _idTypeName(typeNameCache.lookup(report.widget));
      final idSuffix = '$typeName~${_idPart(report, typeName)}';
      if (acc.count > 0) {
        _scrollableData.add((
          chain: buildAncestorChain(report),
          count: acc.count,
          totalElements: acc.totalElements,
          rect: report.renderObject != null
              ? getGlobalRect(report.renderObject!)
              : null,
          renderObject: report.renderObject,
          typeName: typeNameCache.lookup(report.widget),
          idSuffix: idSuffix,
        ));
      }
    }
  }

  @override
  void finalizeScan() {
    _scrollableStack.clear();
    _ordinals.clear();
    _nextOrdinal.clear();
    for (final data in _scrollableData) {
      if (data.count > threshold) {
        final avgSubtreeSize = data.count > 0
            ? data.totalElements ~/ data.count
            : 0;

        if (data.rect != null) {
          _highlights.add(
            WidgetHighlight(
              rect: data.rect!,
              renderObject: data.renderObject,
              widgetName: data.typeName,
              severity: data.count > threshold * 2
                  ? IssueSeverity.critical
                  : IssueSeverity.warning,
              detectorName: 'KeepAlive',
              detail: '${data.count} items kept alive in memory',
            ),
          );
        }
        final (hint, effort) = FixHintBuilder.excessiveKeepAlive(
          count: data.count,
        );

        final subtreeCostLine = avgSubtreeSize > 0
            ? '\n~$avgSubtreeSize elements per page '
                  '(${data.totalElements} total in scrollable).'
            : '';

        _issues.add(
          PerformanceIssue(
            stableId: 'excessive_keep_alive:${data.idSuffix}',
            severity: data.count > threshold * 2
                ? IssueSeverity.critical
                : IssueSeverity.warning,
            category: IssueCategory.memory,
            confidence: IssueConfidence.possible,
            title: 'Excessive Keep-Alive: ${data.count} in ${data.typeName}',
            detail:
                '${data.count} widgets are using '
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
    _ordinals.clear();
    _nextOrdinal.clear();
  }

  @override
  DetectorMetadata get validationMetadata => const DetectorMetadata(
    tier: EvidenceTier.reproducerOnly,
    rationale:
        'Hermetic reproducer pins the parameterised '
        '`excessive_keep_alive:<TypeName>~<key>` family on a PageView '
        'with AutomaticKeepAliveClientMixin pages, above '
        '`threshold` (strict-greater). Pages are visited via '
        'PageController.jumpToPage so `_isActiveKeepAlive` reads '
        'parent-data `true` — the stale '
        '`element.widget.keepAlive` path stays false otherwise. '
        'ListView-suppression, wantKeepAlive=false silence, and '
        'at-threshold silence are pinned as negative controls. '
        'Family prefix convention pinned at the `:` separator. '
        'Keep-alives count toward the innermost page scrollable only; '
        'ListView/GridView/CustomScrollView/NestedScrollView/'
        'SingleChildScrollView are barriers, so a TabBarView emits once '
        'and list items inside a page are not counted. The id names the '
        'reported scrollable: its string or number `ValueKey` value '
        '(sanitised to `[A-Za-z0-9_-]`, 24 chars), else its ordinal '
        'among unkeyed page scrollables of the same type in tree order, '
        'so it holds when another scrollable starts keeping pages alive. '
        'Not yet runtime-verified on a profile-mode capture.',
    reproducerPath: 'test/validation/keep_alive_reproducer_test.dart',
    coveredStableIds: {'excessive_keep_alive'},
  );
}
