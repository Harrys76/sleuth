import 'package:flutter/widgets.dart';

import '../debug/debug_snapshot.dart';
import '../models/base_detector.dart';
import '../validation/detector_metadata.dart';
import '../validation/evidence_tier.dart';
import '../models/performance_issue.dart';
import '../utils/fix_hint_builder.dart';
import '../utils/type_name_cache.dart';
import '../utils/widget_location.dart';
import '../vm/timeline_parser.dart';

/// Detects StatefulWidgets at shallow tree depth during high build activity.
///
/// **Hybrid Detector** — VM build count + element tree depth.
/// Finds StatefulWidgets near the root that would cause wide rebuilds
/// if they depend on inherited widgets (e.g. MediaQuery, Theme).
///
/// Note: This detector does not observe actual dependency usage — it
/// identifies structural risk, not proven rebuild causes.
class ShallowRebuildRiskDetector extends BaseDetector
    with DetectorMetadataProvider {
  ShallowRebuildRiskDetector({this.depthThreshold = 3})
      : super(
          type: DetectorType.shallowRebuildRisk,
          lifecycle: DetectorLifecycle.hybrid,
          name: 'Shallow Rebuild Risk',
          description:
              'Detects StatefulWidgets high in tree during heavy build activity',
        );

  /// StatefulWidgets above this tree depth trigger a warning.
  final int depthThreshold;
  final List<PerformanceIssue> _issues = [];
  bool _isEnabled = true;

  int _lastBuildCount = 0;
  bool _vmConnected = false;
  final List<_ShallowWidgetUsage> _usages = [];
  DebugSnapshot? _lastDebugSnapshot;

  /// Depth counter for unified tree walk.
  int _depth = 0;

  /// Current VM connectivity — set by the controller.
  /// Clears stale VM-backed state immediately on disconnect.
  bool get vmConnected => _vmConnected;
  @override
  set vmConnected(bool value) {
    _vmConnected = value;
    if (!value) {
      _lastBuildCount = 0;
      _issues.clear();
    }
  }

  @override
  List<PerformanceIssue> get issues => List.unmodifiable(_issues);

  @override
  bool get isEnabled => _isEnabled;

  @override
  set isEnabled(bool value) => _isEnabled = value;

  @override
  void updateDebugSnapshot(DebugSnapshot snapshot) {
    _lastDebugSnapshot = snapshot;
  }

  @override
  void processTimelineData(ParsedTimelineData data) {
    if (!_isEnabled) return;
    _lastBuildCount = data.buildEventCount;
  }

  @override
  void prepareScan(BuildContext context) {
    _depth = 0;
    _usages.clear();
  }

  @override
  void checkElement(Element element) {
    _depth++;

    final widget = element.widget;

    // Count StatefulElements at shallow depth — these are the ones
    // that would rebuild widely if they depend on inherited widgets.
    // Skip framework widgets that are expected at shallow depth.
    if (element is StatefulElement && _depth <= depthThreshold) {
      final name = typeNameCache.lookup(widget);
      const frameworkWidgets = {
        'Scaffold',
        'CupertinoPageScaffold',
        'ScaffoldMessenger',
        'AppBar',
        'Material',
        'AnimatedTheme',
        'ScrollConfiguration',
        'ScrollNotificationObserver',
        '_ModalScope',
        'Navigator',
        'Overlay',
        'FocusScope',
        'FocusTraversalGroup',
      };
      // Canonicalize the generic suffix before set membership — production
      // `_ModalScope<dynamic>` etc. would otherwise bypass the framework
      // filter and surface as user-shallow rebuild risk.
      if (!frameworkWidgets.contains(baseTypeName(name))) {
        _usages.add(_ShallowWidgetUsage(
          widgetName: name,
          depth: _depth,
          location: buildAncestorChain(element),
        ));
      }
    }
  }

  @override
  void afterElement(Element element) {
    _depth--;
  }

  @override
  void finalizeScan() {
    _evaluate();
  }

  void _evaluate() {
    _issues.clear();

    if (_usages.isEmpty) return;

    final topUsage = _usages.first;
    final usageList =
        _usages.take(5).map((u) => '  • ${u.location}').join('\n');

    if (vmConnected && _lastBuildCount > 20) {
      // VM-backed path.
      IssueConfidence confidence = IssueConfidence.possible;
      ObservationSource source = ObservationSource.vmTimeline;
      String? debugDetail;
      String confidenceReason =
          'Structural scan only — connect VM for higher confidence';

      final ds = _lastDebugSnapshot;
      if (ds != null) {
        final rate = ds.rebuildsPerSecond(topUsage.widgetName);
        if (rate > 0) {
          confidence = IssueConfidence.likely;
          source = ObservationSource.debugCallbackAndStructural;
          debugDetail =
              '${topUsage.widgetName} rebuilding at ${rate.round()}/sec.';
          confidenceReason =
              'Debug callback rebuild rate + shallow tree position';
        }
      }

      // VM-backed: elevated build activity confirmed.
      final (hint, effort) = FixHintBuilder.shallowRebuildRisk(
        widgetName: topUsage.widgetName,
        hasVmData: true,
      );
      _issues.add(
        PerformanceIssue(
          stableId: 'shallow_rebuild_risk',
          severity: IssueSeverity.warning,
          category: IssueCategory.build,
          confidence: confidence,
          title:
              'Shallow Rebuild Risk: ${topUsage.widgetName} at depth ${topUsage.depth}',
          detail: '${_usages.length} StatefulWidget(s) found high in '
              'the tree (depth ≤ $depthThreshold) during elevated build '
              'activity. These widgets risk causing wide rebuilds if they '
              'depend on frequently-changing inherited widgets.'
              '${debugDetail != null ? '\n\n$debugDetail' : ''}'
              '\n\n$usageList',
          fixHint: hint,
          fixEffort: effort,
          widgetName: topUsage.widgetName,
          ancestorChain: topUsage.location,
          observationSource: source,
          detectedAt: DateTime.now(),
          confidenceReason: confidenceReason,
        ),
      );
    } else if (!vmConnected) {
      // Structural-only fallback path.
      IssueConfidence confidence = IssueConfidence.possible;
      ObservationSource source = ObservationSource.structural;
      String? debugDetail;
      String confidenceReason =
          'Structural scan only — connect VM for higher confidence';

      final ds = _lastDebugSnapshot;
      if (ds != null) {
        final rate = ds.rebuildsPerSecond(topUsage.widgetName);
        if (rate > 0) {
          confidence = IssueConfidence.likely;
          source = ObservationSource.debugCallbackAndStructural;
          debugDetail =
              '${topUsage.widgetName} rebuilding at ${rate.round()}/sec.';
          confidenceReason =
              'Debug callback rebuild rate + shallow tree position';
        }
      }

      // Report shallow StatefulWidgets as risk without build-rate evidence.
      final (hint, effort) = FixHintBuilder.shallowRebuildRisk(
        widgetName: topUsage.widgetName,
        hasVmData: false,
      );
      _issues.add(
        PerformanceIssue(
          stableId: 'shallow_rebuild_risk',
          severity: IssueSeverity.warning,
          category: IssueCategory.build,
          confidence: confidence,
          title:
              'Shallow Rebuild Risk: ${topUsage.widgetName} at depth ${topUsage.depth}',
          detail: '${_usages.length} StatefulWidget(s) found high in '
              'the tree (depth ≤ $depthThreshold). VM unavailable — '
              'build activity unknown. These widgets risk causing wide '
              'rebuilds if they depend on frequently-changing inherited '
              'widgets.'
              '${debugDetail != null ? '\n\n$debugDetail' : ''}'
              '\n\n$usageList',
          fixHint: hint,
          fixEffort: effort,
          widgetName: topUsage.widgetName,
          ancestorChain: topUsage.location,
          observationSource: source,
          detectedAt: DateTime.now(),
          confidenceReason: confidenceReason,
        ),
      );
    }
    // else: VM connected but build count ≤ 20 — no issue, activity is low.
  }

  @override
  void dispose() {
    _issues.clear();
    _usages.clear();
    _lastDebugSnapshot = null;
  }

  @override
  DetectorMetadata get validationMetadata => const DetectorMetadata(
        tier: EvidenceTier.reproducerOnly,
        rationale: 'Hybrid detector. v0.17.5 tier-quality audit: VM leg '
            'feeds BUILD timeline events through `TimelineParser.parse()` '
            'into the detector — closes the parser-boundary gap. Three '
            'gate states pinned exhaustively in `_evaluate()`: '
            '(1) `vmConnected && _lastBuildCount > 20` strict + shallow '
            'Stateful → VM-backed warning; (2) `!vmConnected` → '
            'structural fallback warning ("VM unavailable" detail); '
            '(3) `vmConnected && _lastBuildCount ≤ 20` → silent no-fire '
            '(activity-low branch — a regression that flips the gate to '
            '`>=` or removes the activity check shows up only in the '
            'State-3 test). Structural depth threshold default 3 pinned '
            'at boundary (depth 3 fires inclusive, depth 4 does not). '
            'Framework-widget allowlist (13 names: Scaffold, '
            'CupertinoPageScaffold, ScaffoldMessenger, AppBar, Material, '
            'AnimatedTheme, ScrollConfiguration, ScrollNotificationObserver, '
            '_ModalScope, Navigator, Overlay, FocusScope, '
            'FocusTraversalGroup) verified by Navigator-only tree '
            'producing zero usages. DebugSnapshot confidence upgrade '
            'consumed in `finalizeScan` → `_evaluate()`, so '
            '`updateDebugSnapshot` MUST be called BEFORE the scan; '
            'reproducer pins this ordering. Rate=0 negative case '
            'verifies the upgrade is gated on `rebuildsPerSecond > 0`. '
            'VM-disconnect setter clears `_lastBuildCount` and `_issues` '
            'synchronously (immediate-effect contract). `_vmConnected` '
            'defaults to false; reproducer setUp explicitly sets true so '
            'VM-backed tests are not silently routed into the State-2 '
            'structural fallback. Not runtime-verified or externally '
            'cited.',
        reproducerPath:
            'test/validation/shallow_rebuild_risk_reproducer_test.dart',
        coveredStableIds: {'shallow_rebuild_risk'},
      );
}

class _ShallowWidgetUsage {
  const _ShallowWidgetUsage({
    required this.widgetName,
    required this.depth,
    required this.location,
  });
  final String widgetName;
  final int depth;
  final String location;
}
