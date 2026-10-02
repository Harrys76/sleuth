import 'package:flutter/widgets.dart';

import '../models/base_detector.dart';
import '../validation/detector_metadata.dart';
import '../validation/evidence_tier.dart';
import '../models/performance_issue.dart';
import '../models/widget_highlight.dart';
import '../utils/fix_hint_builder.dart';
import '../utils/type_name_cache.dart';
import '../utils/widget_location.dart';

/// Detects intrinsic dimension render objects that cause layout bottlenecks.
///
/// **Structural Detector** — scans the tree for IntrinsicHeight/Width.
/// A single intrinsic is warning/possible; nested intrinsics are
/// critical/likely. Intrinsics built by framework widgets are skipped.
class LayoutBottleneckDetector extends BaseDetector
    with DetectorMetadataProvider {
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
    _intrinsicCounted.clear();
  }

  /// Framework widgets that build an IntrinsicWidth/IntrinsicHeight
  /// internally, mapped to the maximum number of ancestor hops between the
  /// intrinsic and the owner. Developers cannot remove these intrinsics, so
  /// flagging them is noise. The hop budget keeps a user intrinsic placed
  /// deep inside the owner's content from being suppressed.
  ///
  /// Budgets sit just above the hop counts measured on Flutter 3.32 and
  /// 3.47: ToggleButtons 1, BottomNavigationBar linear landscape label 24,
  /// MenuBar cross-axis IntrinsicHeight 4 and per-item IntrinsicWidth 42,
  /// popup menu 14, AlertDialog/SimpleDialog 18 (user `content` intrinsics
  /// sit at 24 and stay reported), CupertinoContextMenu sheet 2-3.
  static const _frameworkIntrinsicOwners = <String, int>{
    'ToggleButtons': 2,
    '_BottomNavigationTile': 26,
    '_MenuPanel': 44,
    '_PopupMenu': 16,
    'AlertDialog': 20,
    'SimpleDialog': 20,
    '_ContextMenuSheet': 3,
  };

  static final int _maxOwnerHops = _frameworkIntrinsicOwners.values.reduce(
    (a, b) => a > b ? a : b,
  );

  /// Scaffold places `persistentFooterButtons` under an IntrinsicHeight
  /// inside the `LayoutId` for this slot.
  static const _persistentFooterSlotId = '_ScaffoldSlot.persistentFooter';
  static const _persistentFooterMaxHops = 8;

  /// The bottom-navigation label intrinsic is always the direct child of a
  /// `Flexible` (`Flexible(child: IntrinsicWidth(child: label))`). A user
  /// intrinsic placed inside the item's icon shares the same tile ancestor
  /// but not that parent, so the owner match requires it.
  static const _flexibleParentOwner = '_BottomNavigationTile';

  bool _isFrameworkIntrinsic(Element element) {
    int hops = 0;
    bool found = false;
    bool parentIsFlexible = false;
    element.visitAncestorElements((ancestor) {
      hops++;
      if (hops > _maxOwnerHops) return false;
      final ancestorWidget = ancestor.widget;
      if (hops == 1) parentIsFlexible = ancestorWidget is Flexible;
      if (hops <= _persistentFooterMaxHops &&
          ancestorWidget is LayoutId &&
          ancestorWidget.id.toString() == _persistentFooterSlotId) {
        found = true;
        return false;
      }
      final ownerName = baseTypeName(typeNameCache.lookup(ancestorWidget));
      final budget = _frameworkIntrinsicOwners[ownerName];
      if (budget != null && hops <= budget) {
        if (ownerName == _flexibleParentOwner && !parentIsFlexible) {
          return true;
        }
        found = true;
        return false;
      }
      return true;
    });
    return found;
  }

  /// Parallel to the walk: whether each entered intrinsic counted toward
  /// [_intrinsicDepth], so [afterElement] decrements symmetrically.
  final List<bool> _intrinsicCounted = [];

  @override
  void checkElement(Element element) {
    final widget = element.widget;

    // Detect Wrap with excessive children — non-virtualized layout means all
    // children are measured every frame regardless of visibility.
    if (widget is Wrap) {
      int childCount = 0;
      element.visitChildren((_) => childCount++);
      if (childCount > _wrapChildThreshold) {
        _wrapFindings.add((
          childCount: childCount,
          location: buildAncestorChain(element),
        ));
        final ro = element.renderObject;
        if (ro != null) {
          final rect = getGlobalRect(ro);
          if (rect != null) {
            _highlights.add(
              WidgetHighlight(
                rect: rect,
                widgetName: 'Wrap',
                severity: childCount > _wrapChildThreshold * 2
                    ? IssueSeverity.critical
                    : IssueSeverity.warning,
                detectorName: 'Layout',
                detail:
                    'Wrap with $childCount children — non-virtualized layout',
              ),
            );
          }
        }
      }
    }

    if (widget is IntrinsicHeight || widget is IntrinsicWidth) {
      // Framework-owned intrinsics are neither reported nor counted toward
      // nesting.
      if (_isFrameworkIntrinsic(element)) {
        _intrinsicCounted.add(false);
        return;
      }
      final isNested = _intrinsicDepth > 0;
      _intrinsicDepth++;
      _intrinsicCounted.add(true);

      final widgetName = widget is IntrinsicHeight
          ? 'IntrinsicHeight'
          : 'IntrinsicWidth';
      _found.add((name: widgetName, nested: isNested));
      final ro = element.renderObject;
      if (ro != null) {
        final rect = getGlobalRect(ro);
        if (rect != null) {
          _highlights.add(
            WidgetHighlight(
              rect: rect,
              widgetName: widgetName,
              severity: isNested
                  ? IssueSeverity.critical
                  : IssueSeverity.warning,
              detectorName: 'Layout',
              detail: isNested
                  ? 'Nested intrinsic — each level re-measures the levels below'
                  : 'Adds an extra intrinsic measuring pass',
            ),
          );
        }
      }
    }
  }

  @override
  void afterElement(Element element) {
    final widget = element.widget;
    if ((widget is IntrinsicHeight || widget is IntrinsicWidth) &&
        _intrinsicCounted.isNotEmpty &&
        _intrinsicCounted.removeLast()) {
      _intrinsicDepth--;
    }
  }

  @override
  void finalizeScan() {
    if (_found.isNotEmpty) {
      final hasNested = _found.any((f) => f.nested);
      final locations = _found
          .take(5)
          .map((f) {
            final prefix = f.nested ? '⚠ ' : '';
            return '  • $prefix${f.name}${f.nested ? ' (nested)' : ''}';
          })
          .join('\n');
      final (hint, effort) = FixHintBuilder.layoutBottleneck();

      _issues.add(
        PerformanceIssue(
          stableId: 'layout_bottleneck',
          severity: hasNested ? IssueSeverity.critical : IssueSeverity.warning,
          category: IssueCategory.layout,
          // A single intrinsic's cost scales with its subtree, which a
          // structural scan cannot size. Nesting compounds the measuring
          // passes, so it is likely costly regardless of subtree.
          confidence: hasNested
              ? IssueConfidence.likely
              : IssueConfidence.possible,
          title: hasNested
              ? 'Nested Layout Bottleneck: ${_found.length} intrinsic nodes'
              : 'Layout Bottleneck: ${_found.length} intrinsic nodes',
          detail: hasNested
              ? 'Found ${_found.length} IntrinsicHeight/IntrinsicWidth widgets '
                    'including nested intrinsics. Each nested level '
                    're-measures the levels below it.\n\n$locations'
              : 'Found ${_found.length} IntrinsicHeight/IntrinsicWidth '
                    'widgets. Each adds an extra intrinsic measuring '
                    'pass.\n\n$locations',
          fixHint: hint,
          fixEffort: effort,
          observationSource: ObservationSource.structural,
          confidenceReason: hasNested
              ? 'Structural: nested IntrinsicWidth/IntrinsicHeight multiply '
                    'measurement passes for every level below'
              : 'Structural: an IntrinsicWidth/IntrinsicHeight forces a '
                    'second measurement pass; cost depends on subtree size',
          detectedAt: DateTime.now(),
        ),
      );
    }

    // Emit Wrap bottleneck issues
    for (final wrap in _wrapFindings) {
      final (hint, effort) = FixHintBuilder.wrapBottleneck(
        childCount: wrap.childCount,
        ancestorChain: wrap.location,
      );
      _issues.add(
        PerformanceIssue(
          stableId: 'wrap_layout_bottleneck',
          severity: wrap.childCount > _wrapChildThreshold * 2
              ? IssueSeverity.critical
              : IssueSeverity.warning,
          category: IssueCategory.layout,
          confidence: IssueConfidence.possible,
          title: 'Wrap Layout Bottleneck: ${wrap.childCount} children',
          detail:
              'Wrap with ${wrap.childCount} children is non-virtualized '
              '— all children are laid out every frame regardless of '
              'visibility.\n\n  • ${wrap.location}',
          fixHint: hint,
          fixEffort: effort,
          observationSource: ObservationSource.structural,
          confidenceReason:
              'Structural scan only — Wrap child count exceeds threshold',
          detectedAt: DateTime.now(),
        ),
      );
    }
  }

  @override
  void dispose() {
    _issues.clear();
    _highlights.clear();
    _found.clear();
    _wrapFindings.clear();
    _intrinsicDepth = 0;
    _intrinsicCounted.clear();
  }

  @override
  DetectorMetadata get validationMetadata => const DetectorMetadata(
    tier: EvidenceTier.reproducerOnly,
    rationale:
        'Hermetic reproducer pins `layout_bottleneck` '
        '(IntrinsicHeight/IntrinsicWidth structural trigger; single = '
        'warning/possible, nested = critical/likely; framework-owned '
        'intrinsics matched by owner type within a measured hop budget are '
        'suppressed) and '
        '`wrap_layout_bottleneck` (Wrap with > `wrapChildThreshold` '
        'children, strict-greater). Detector is a pure structural scan '
        'over widget shape — no layout-phase timing dependency — so the '
        'reproducer covers the full runtime trigger path. Not yet '
        'runtime-verified on a profile-mode capture.',
    reproducerPath: 'test/validation/layout_bottleneck_reproducer_test.dart',
    coveredStableIds: {'layout_bottleneck', 'wrap_layout_bottleneck'},
  );
}
