import 'package:flutter/widgets.dart';

import '../debug/debug_snapshot.dart';
import '../models/base_detector.dart';
import '../models/phase_event.dart';
import '../models/performance_issue.dart';
import '../models/widget_highlight.dart';
import '../utils/fix_hint_builder.dart';
import '../utils/type_name_cache.dart';
import '../utils/widget_location.dart';
import '../vm/timeline_parser.dart';

/// Detects excessive widget rebuilds using VM Build events + element tree.
///
/// **Hybrid Detector** — VM Timeline provides exact build counts,
/// element tree walk provides screen context only. Debug callbacks provide
/// per-widget-type rebuild attribution when enabled.
///
/// Data sources accumulate into staging fields; the single [_evaluate]
/// method is the ONLY writer of [_issues]. Called from [scanTree] (scan
/// tick) and [evaluateNow] (timeline tick).
class RebuildDetector extends BaseDetector {
  RebuildDetector({
    this.rebuildsPerSecThreshold = 10,
    DateTime Function()? clock,
  })  : _clock = clock ?? DateTime.now,
        _windowStart = (clock ?? DateTime.now)(),
        super(
          type: DetectorType.rebuild,
          lifecycle: DetectorLifecycle.hybrid,
          name: 'Rebuild',
          description: 'Detects excessive widget rebuilds (>10/sec)',
        );

  final int rebuildsPerSecThreshold;
  final DateTime Function() _clock;
  final List<PerformanceIssue> _issues = [];
  final List<WidgetHighlight> _highlights = [];
  static const int _maxHighlightsPerType = 3;
  bool _isEnabled = true;

  /// Widget types designed to rebuild on every data/tick event.
  /// These use a 3x threshold multiplier to avoid false positives
  /// from expected high-frequency rebuilds.
  static const _builderWidgetTypes = {
    'StreamBuilder',
    'FutureBuilder',
    'ValueListenableBuilder',
    'AnimatedBuilder',
    'ListenableBuilder',
    'TweenAnimationBuilder',
    'StreamBuilderBase',
  };

  /// Threshold multiplier for builder widget types.
  static const int _builderThresholdMultiplier = 3;

  int _buildEventCount = 0;
  bool _vmConnected = false;
  DateTime _windowStart;

  // -- Staging fields (nullable = no fresh data) --

  /// null = no VM window completed since last evaluate.
  /// 0 = a window completed with zero events (should clear issues).
  /// >0 = a window completed with events (should produce issues).
  int? _pendingVmWindowCount;

  /// null = no new snapshot delivered since last evaluate.
  /// A snapshot with 0 counts means activity stopped (should clear issues).
  DebugSnapshot? _pendingDebugSnapshot;

  /// Dirty widget names from enriched timeline args, accumulating across
  /// timeline ticks until the next 1s window completes.
  final List<String> _pendingEnrichedNames = [];

  /// Enriched names staged atomically with [_pendingVmWindowCount].
  /// Consumed by [_evaluateVmData] and cleared unconditionally in [_evaluate].
  List<String>? _stagedEnrichedNames;

  /// Current VM connectivity — set by the controller.
  /// Clears VM staging on disconnect; issues are repopulated on next _evaluate.
  bool get vmConnected => _vmConnected;
  @override
  set vmConnected(bool value) {
    final wasConnected = _vmConnected;
    _vmConnected = value;
    if (!value) {
      _buildEventCount = 0;
      _pendingVmWindowCount = null;
      _pendingEnrichedNames.clear();
      _stagedEnrichedNames = null;
    } else if (!wasConnected) {
      // Reconnect: stage a fresh-zero so the next _evaluate() flushes
      // stale structural/debug issues that are incompatible with VM mode.
      _pendingVmWindowCount = 0;
    }
  }

  final Map<String, int> _widgetRebuildCounts = {};

  @override
  List<PerformanceIssue> get issues => List.unmodifiable(_issues);

  @override
  List<WidgetHighlight> get highlights => List.unmodifiable(_highlights);

  @override
  bool get isEnabled => _isEnabled;

  @override
  set isEnabled(bool value) => _isEnabled = value;

  /// Process VM timeline data for build event counts.
  ///
  /// Accumulates counts and enriched dirty names into pending buffers.
  /// On 1s window completion, stages count + enrichment atomically
  /// for [_evaluate].
  @override
  void processTimelineData(ParsedTimelineData data) {
    if (!_isEnabled) return;
    _buildEventCount += data.buildEventCount;

    // Accumulate enriched dirty names from this batch
    for (final event in data.phaseEvents) {
      if (event.phase == TimelinePhase.build && event.dirtyList != null) {
        _pendingEnrichedNames.addAll(event.dirtyList!);
      }
    }

    final now = _clock();
    if (now.difference(_windowStart).inMilliseconds >= 1000) {
      _pendingVmWindowCount = _buildEventCount;
      // Stage enrichment atomically with the window count
      _stagedEnrichedNames = _pendingEnrichedNames.isNotEmpty
          ? _pendingEnrichedNames.toList()
          : null;
      _pendingEnrichedNames.clear();
      _buildEventCount = 0;
      _windowStart = now;
    }
  }

  Map<String, double> _hotTypes = const {};
  Map<String, int> _hotCounts = {};

  @override
  void prepareScan(BuildContext context) {
    _widgetRebuildCounts.clear();
    _highlights.clear();
    _hotCounts = {};

    // Compute hot types and their rates from available staging data.
    // Staging is still available here — _evaluate() clears it AFTER the walk.
    _hotTypes = _hotRebuildTypes();
  }

  @override
  void checkElement(Element element) {
    final widget = element.widget;
    final name = typeNameCache.lookup(widget);

    // Track StatefulWidget rebuild indicators
    if (element is StatefulElement) {
      _widgetRebuildCounts[name] = (_widgetRebuildCounts[name] ?? 0) + 1;
    }

    // Collect highlights for hot types
    final rate = _hotTypes[name];
    if (rate != null) {
      final count = _hotCounts[name] ?? 0;
      if (count < _maxHighlightsPerType) {
        final ro = element.renderObject;
        if (ro != null) {
          final rect = getGlobalRect(ro);
          if (rect != null) {
            _highlights.add(WidgetHighlight(
              rect: rect,
              widgetName: name,
              severity: rate > rebuildsPerSecThreshold * 3
                  ? IssueSeverity.critical
                  : IssueSeverity.warning,
              detectorName: 'Rebuild',
              detail: '${rate.round()} rebuilds/sec',
            ));
            _hotCounts[name] = count + 1;
          }
        }
      }
    }
  }

  @override
  void finalizeScan() {
    _evaluate();
  }

  /// Compute types with excessive rebuild rates from available staging data.
  ///
  /// Returns a map of typeName → rate. Priority: debug snapshot > enriched
  /// VM names. Returns empty when only structural data is available (density
  /// is not proven rebuild rate).
  Map<String, double> _hotRebuildTypes() {
    final hotTypes = <String, double>{};

    // Priority 1: Debug snapshot (per-widget type attribution)
    final snapshot = _pendingDebugSnapshot;
    if (snapshot != null) {
      for (final entry in snapshot.rebuildCounts.entries) {
        final rate = snapshot.rebuildsPerSecond(entry.key);
        final threshold = _builderWidgetTypes.contains(entry.key)
            ? rebuildsPerSecThreshold * _builderThresholdMultiplier
            : rebuildsPerSecThreshold;
        if (rate >= threshold) {
          hotTypes[entry.key] = rate;
        }
      }
      return hotTypes;
    }

    // Priority 2: Enriched VM names (dirty widget names from timeline)
    final enriched = _stagedEnrichedNames;
    if (enriched != null && enriched.isNotEmpty) {
      final counts = <String, int>{};
      for (final name in enriched) {
        counts[name] = (counts[name] ?? 0) + 1;
      }
      for (final entry in counts.entries) {
        final threshold = _builderWidgetTypes.contains(entry.key)
            ? rebuildsPerSecThreshold * _builderThresholdMultiplier
            : rebuildsPerSecThreshold;
        if (entry.value >= threshold) {
          hotTypes[entry.key] = entry.value.toDouble();
        }
      }
    }

    return hotTypes;
  }

  @override
  void updateDebugSnapshot(DebugSnapshot snapshot) {
    _pendingDebugSnapshot = snapshot;
  }

  @override
  void evaluateNow() => _evaluate();

  /// The ONLY method that writes [_issues].
  ///
  /// Priority: debug callback > VM timeline > structural scan.
  /// Nullable staging fields distinguish "no new data" (null → keep
  /// existing issues) from "fresh window with zero events" (non-null
  /// with 0 → clear stale issues).
  void _evaluate() {
    final debugSnapshot = _pendingDebugSnapshot;
    final vmWindowCount = _pendingVmWindowCount;
    final enrichedNames = _stagedEnrichedNames;
    final hasStructuralData = !_vmConnected && _widgetRebuildCounts.isNotEmpty;

    final hasFreshDebug = debugSnapshot != null;
    final hasFreshVm = _vmConnected && vmWindowCount != null;

    // No fresh data from any source — keep existing issues.
    if (!hasFreshDebug && !hasFreshVm && !hasStructuralData) return;

    // Fresh data exists — clear and re-evaluate.
    _issues.clear();
    // Unconditional clear — prevents enrichment leaking across branches.
    _stagedEnrichedNames = null;

    if (hasFreshDebug) {
      if (debugSnapshot.totalRebuilds > 0) {
        _evaluateDebugData(debugSnapshot);
      } else if (hasFreshVm) {
        // Debug callbacks active but returned zero counts — fall back to VM.
        if (vmWindowCount > 0) {
          _evaluateVmData(vmWindowCount, enrichedNames);
        }
        _pendingVmWindowCount = null;
      }
      _pendingDebugSnapshot = null;
    } else if (hasFreshVm) {
      if (vmWindowCount > 0) {
        _evaluateVmData(vmWindowCount, enrichedNames);
      }
      _pendingVmWindowCount = null;
    } else if (hasStructuralData) {
      _evaluateStructuralOnly();
    }
  }

  /// Debug callback path — per-widget-type rebuild attribution.
  void _evaluateDebugData(DebugSnapshot snapshot) {
    for (final entry in snapshot.rebuildCounts.entries) {
      final typeName = entry.key;
      final count = entry.value;
      final rate = snapshot.rebuildsPerSecond(typeName);

      // Builder widgets are designed to rebuild on data/tick changes —
      // apply a higher threshold to avoid false positives.
      final isBuilder = _builderWidgetTypes.contains(typeName);
      final effectiveThreshold = isBuilder
          ? rebuildsPerSecThreshold * _builderThresholdMultiplier
          : rebuildsPerSecThreshold;

      if (rate < effectiveThreshold) continue;

      final elapsedSec =
          snapshot.elapsed.inMicroseconds / Duration.microsecondsPerSecond;

      final (hint, effort) = FixHintBuilder.rebuildDebug(
        typeName: typeName,
        rate: rate.round(),
        ancestorChain: snapshot.ancestorChains[typeName],
      );

      final builderNote = isBuilder ? ' (builder widget)' : '';

      _issues.add(PerformanceIssue(
        stableId: 'rebuild_debug_$typeName',
        severity: rate > effectiveThreshold * 3
            ? IssueSeverity.critical
            : IssueSeverity.warning,
        category: IssueCategory.build,
        confidence: IssueConfidence.confirmed,
        title: 'Excessive Rebuilds: $typeName (${rate.round()}/sec)',
        detail: '$typeName: $count rebuilds in '
            '${elapsedSec.toStringAsFixed(1)}s '
            '(${rate.round()}/sec).$builderNote',
        fixHint: hint,
        fixEffort: effort,
        widgetName: typeName,
        ancestorChain: snapshot.ancestorChains[typeName],
        observationSource: ObservationSource.debugCallback,
        detectedAt: DateTime.now(),
        confidenceReason:
            'Measured directly from debug callback rebuild counter',
      ));
    }
  }

  /// VM timeline path — aggregate build event count with attribution context.
  ///
  /// When [enrichedNames] are available (from timeline enrichment args),
  /// uses them for dirty-widget attribution. Otherwise falls back to
  /// structural tree scan context.
  void _evaluateVmData(int buildCount, [List<String>? enrichedNames]) {
    if (buildCount <= rebuildsPerSecThreshold) return;

    String detailSuffix;

    if (enrichedNames != null && enrichedNames.isNotEmpty) {
      // Enriched path: count occurrences of each dirty widget type
      final counts = <String, int>{};
      for (final name in enrichedNames) {
        counts[name] = (counts[name] ?? 0) + 1;
      }
      final sorted = counts.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      detailSuffix = '\nTop dirty widgets (timeline enrichment): '
          '${sorted.take(3).map((e) => '${e.key} (${e.value}x)').join(', ')}';
    } else {
      // Structural fallback
      final topRebuilders = _widgetRebuildCounts.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      detailSuffix = topRebuilders.isNotEmpty
          ? '\nMost common StatefulWidget on screen: ${topRebuilders.first.key} '
              '(${topRebuilders.first.value} instances — screen context, '
              'not proven rebuild source).'
          : '';
    }

    final (hint, effort) = FixHintBuilder.rebuildActivity(
      buildCount: buildCount,
    );

    _issues.add(PerformanceIssue(
      stableId: 'rebuild_activity',
      severity: buildCount > rebuildsPerSecThreshold * 3
          ? IssueSeverity.critical
          : IssueSeverity.warning,
      category: IssueCategory.build,
      confidence: IssueConfidence.confirmed,
      title: 'High Rebuild Activity: $buildCount builds/sec',
      detail: '$buildCount widget rebuilds in the last second.$detailSuffix',
      fixHint: hint,
      fixEffort: effort,
      observationSource: ObservationSource.vmTimeline,
      detectedAt: DateTime.now(),
      confidenceReason: 'Measured directly from VM timeline build count',
    ));
  }

  /// Structural-only fallback when VM data is unavailable.
  /// Reports high StatefulWidget density as context, not proven rebuild rate.
  void _evaluateStructuralOnly() {
    final totalStateful = _widgetRebuildCounts.values.fold(0, (s, v) => s + v);
    if (totalStateful < rebuildsPerSecThreshold) return;

    final topRebuilders = _widgetRebuildCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final topWidget =
        topRebuilders.isNotEmpty ? topRebuilders.first.key : 'Unknown';

    final (hint, effort) = FixHintBuilder.statefulDensity(
      topWidget: topRebuilders.isNotEmpty ? topWidget : null,
    );

    _issues.add(PerformanceIssue(
      stableId: 'stateful_density',
      severity: IssueSeverity.warning,
      category: IssueCategory.build,
      confidence: IssueConfidence.possible,
      title: 'High StatefulWidget Density: $totalStateful instances',
      detail: '$totalStateful StatefulWidget instances on screen '
          '(VM unavailable — rebuild rate unknown).'
          '${topRebuilders.isNotEmpty ? '\nMost common: $topWidget '
              '(${topRebuilders.first.value} instances).' : ''}',
      fixHint: hint,
      fixEffort: effort,
      observationSource: ObservationSource.structural,
      detectedAt: DateTime.now(),
      confidenceReason:
          'Structural scan only — connect VM for higher confidence',
    ));
  }

  @override
  void dispose() {
    _issues.clear();
    _highlights.clear();
    _widgetRebuildCounts.clear();
    _pendingEnrichedNames.clear();
    _stagedEnrichedNames = null;
  }
}
