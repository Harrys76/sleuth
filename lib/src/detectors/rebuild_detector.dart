import 'dart:developer' show Timeline;

import 'package:flutter/widgets.dart';

import '../../sleuth.dart' show Sleuth;
import '../debug/debug_snapshot.dart';
import '../models/base_detector.dart';
import '../validation/detector_metadata.dart';
import '../validation/evidence_tier.dart';
import '../models/phase_event.dart';
import '../models/performance_issue.dart';
import '../models/widget_highlight.dart';
import '../utils/fix_hint_builder.dart';
import '../utils/monotonic_clock.dart';
import '../utils/type_name_cache.dart';
import '../utils/widget_location.dart';
import '../vm/timeline_parser.dart';

/// Detects expensive widget rebuilding using VM BUILD scopes + element tree.
///
/// **Hybrid Detector** — the VM timeline measures the share of UI-thread
/// wall time spent inside BUILD scopes over each ~1 s window
/// (`rebuild_activity`); the element tree walk provides screen context
/// only. Debug callbacks provide per-widget-type rebuild counts
/// (`rebuild_debug_<type>`) when enabled.
///
/// Data sources accumulate into staging fields; the single [_evaluate]
/// method is the ONLY writer of [_issues]. Called from [scanTree] (scan
/// tick) and [evaluateNow] (timeline tick).
///
/// Each emission stamps `extraTraceArgs.lifecyclePhase: 'startup' |
/// 'steady'` based on whether the issue EMITTED within
/// [startupPhaseWindowSeconds] of [Sleuth.dartEntryMonotonicUs]. The
/// classification reads `Timeline.now` at emission time — it is
/// **emission-time semantics**, not event-time. `rebuild_activity`'s
/// ~1-second window means a window straddling the startup boundary tags
/// as `'steady'` once `Timeline.now` exceeds the threshold even when
/// most contributing build events happened during startup. Per-widget
/// `rebuild_debug_<typeName>` emissions in a single scan tick share
/// one classification (read once per evaluation pass).
///
/// This differs from `ShaderJankDetector.shaderWarmupContext`, which
/// classifies against per-event shader timestamp. The two tags are
/// related but NOT aligned at the boundary.
///
/// Hot restart resets `Sleuth.dartEntryMonotonicUs` (Dart re-initializes
/// statics; `Sleuth.init()` re-runs and writes a fresh anchor). Emissions
/// for the configured window after each hot restart tag as `'startup'`
/// even when the prior session was already past the window.
///
/// The tag is observable in capture-mode trace records and audit-gate
/// replay; it is not serialized into saved JSON snapshots.
class RebuildDetector extends BaseDetector with DetectorMetadataProvider {
  RebuildDetector({
    this.rebuildsPerSecThreshold = 10,
    this.buildTimePercentThreshold = 10,
    this.statefulDensityThreshold = 10,
    this.startupPhaseWindowSeconds = 5,
    DateTime Function()? clock,
    int? Function()? appStartMonotonicUsForTest,
  }) : assert(
         buildTimePercentThreshold > 0 && buildTimePercentThreshold <= 100,
         'buildTimePercentThreshold must be in the range (0, 100].',
       ),
       _clock = clock ?? monotonicClock(),
       _appStartForTest = appStartMonotonicUsForTest,
       super(
         type: DetectorType.rebuild,
         lifecycle: DetectorLifecycle.hybrid,
         name: 'Rebuild',
         description:
             'Detects rebuild work above 10% of UI-thread time '
             '(VM) or widgets rebuilding over 10 times/sec (debug)',
       ) {
    _windowStart = _clock();
  }

  /// Per-widget rebuilds per second (debug instrumentation) above which
  /// `rebuild_debug_<type>` fires. Builder widgets use 3× this value.
  /// Does not gate the VM time-share axis.
  final int rebuildsPerSecThreshold;

  /// Share of UI-thread wall time, in percent, spent inside BUILD scopes
  /// over a ~1 s window above which `rebuild_activity` fires. Critical
  /// above 3× this value. Default mirrors
  /// `DetectorThresholds.buildTimePercentThreshold`.
  final double buildTimePercentThreshold;

  /// Minimum number of public StatefulWidget instances on screen for the
  /// structural-only `stateful_density` fallback to emit. Independent of
  /// [rebuildsPerSecThreshold].
  final int statefulDensityThreshold;

  /// Window in seconds after Dart entry within which emissions stamp
  /// `extraTraceArgs.lifecyclePhase: 'startup'`; outside the window
  /// emissions stamp `'steady'`. Default mirrors
  /// [DetectorThresholds.startupPhaseWindowSeconds] — the canonical
  /// source for users wiring via `SleuthConfig`.
  final int startupPhaseWindowSeconds;

  final DateTime Function() _clock;
  final int? Function()? _appStartForTest;

  /// Returns `'startup'` when emission `Timeline.now` falls within the
  /// startup window after [Sleuth.dartEntryMonotonicUs], `'steady'`
  /// otherwise, or `null` when no app-start anchor is available
  /// (e.g. `Sleuth.init()` not yet called). A null return omits the
  /// `lifecyclePhase` key from `extraTraceArgs` rather than fabricating
  /// a phase value.
  String? _classifyLifecyclePhase() {
    final appStart = _appStartForTest?.call() ?? Sleuth.dartEntryMonotonicUs;
    if (appStart == null) return null;
    final delta = Timeline.now - appStart;
    // Defensive: a future-timestamped `_appStartForTest` value would
    // otherwise produce a negative delta. Production `Timeline.now` is
    // monotonic-from-boot and cannot land before the captured app-start.
    if (delta < 0) return null;
    final windowUs = startupPhaseWindowSeconds * 1000000;
    return delta < windowUs ? 'startup' : 'steady';
  }

  final List<PerformanceIssue> _issues = [];

  /// Per-type issues from the latest debug-callback snapshot, kept until
  /// the next snapshot. Snapshots arrive with each scan (every 2-5 s) and
  /// VM windows every ~1 s, so each source's issues are kept between its
  /// own updates and [_issues] is rebuilt from both on every evaluation;
  /// replacing everything from whichever source just ticked made cards
  /// appear and vanish between ticks.
  final List<PerformanceIssue> _debugIssues = [];

  /// Issues from the latest closed VM window, kept until the next one.
  final List<PerformanceIssue> _vmIssues = [];

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

  /// Builder widget types alert at this many times
  /// [rebuildsPerSecThreshold].
  static const int builderThresholdMultiplier = 3;

  /// A per-widget rebuild rate above this many times its alert rate is
  /// critical.
  static const int debugCriticalMultiplier = 3;

  int _buildEventCount = 0;

  /// BUILD scope time accumulated in the open window, in microseconds.
  int _buildTimeUs = 0;
  bool _vmConnected = false;
  late DateTime _windowStart;

  /// BUILD events accumulated in the open VM window. Informational; the
  /// `rebuild_activity` gate reads build time, not this count.
  int get buildEventCount => _buildEventCount;

  // -- Staging fields (nullable = no fresh data) --

  /// Build-time share (percent of window wall time) of the most recently
  /// closed VM window.
  /// null = no VM window completed since last evaluate.
  /// 0 = a window completed with no build time (should clear issues).
  /// >0 = a window completed with build time (may produce issues).
  double? _pendingVmWindowPercent;

  /// null = no new snapshot delivered since last evaluate.
  /// A snapshot with 0 counts means activity stopped (should clear issues).
  DebugSnapshot? _pendingDebugSnapshot;

  /// Staged debug snapshot not yet consumed by a scan (for testing).
  @visibleForTesting
  DebugSnapshot? get pendingDebugSnapshotForTest => _pendingDebugSnapshot;

  /// Dirty widget names from enriched timeline args, accumulating across
  /// timeline ticks until the next 1s window completes.
  final List<String> _pendingEnrichedNames = [];

  /// Enriched names staged atomically with [_pendingVmWindowPercent].
  /// Consumed by [_evaluateVmData] and cleared unconditionally in [_evaluate].
  List<String>? _stagedEnrichedNames;

  /// Build-time share of the most recently closed VM window, updated on
  /// every window close (including idle 0 % windows) before the
  /// threshold gate, so sub-threshold capture legs still expose the
  /// detector's measurement.
  double _lastObservedBuildPercent = 0;

  /// Share of UI-thread wall time, in percent, spent inside BUILD scopes
  /// in the most recently closed ~1 s VM window. A
  /// `Sleuth.flushTimelineNow()` barrier drives the VM poll →
  /// [processTimelineData] → window-close chain that updates it.
  double get lastObservedBuildPercent => _lastObservedBuildPercent;

  // Highest window share since the last resetCaptureState. Updated on the
  // same evaluation path that stamps `observedBuildPercent` on emissions,
  // so a capture's `max` reduction over emission args can match it.
  double _peakObservedBuildPercent = 0;

  /// Highest build-time share observed across VM windows since the last
  /// [resetCaptureState] (auto-invoked by `Sleuth.markScenarioBegin`).
  /// Capture-mode operators report this as `expectedMagnitude.observed`
  /// when the bracket uses `observedAxisReduction: 'max'`; every value it
  /// takes is also the `observedBuildPercent` of an emission whenever it
  /// crosses [buildTimePercentThreshold].
  double get peakObservedBuildPercent => _peakObservedBuildPercent;

  /// Capture-mode session-boundary reset hook called from
  /// `SleuthController.resetCaptureState()` (auto-invoked by
  /// `Sleuth.markScenarioBegin`). Clears the VM-path window state so
  /// leg N+1's measured share reflects only leg-N+1 activity: the
  /// last/peak observables, the open window's build time and event
  /// count, any staged-but-unconsumed window, the parallel dirty-widget
  /// staging, and the window clock (re-anchored so the next window
  /// closes 1 s after the reset and measures elapsed time from it).
  ///
  /// `_pendingDebugSnapshot` and `_widgetRebuildCounts` are not
  /// touched — those drive the structural-fallback path, managed by
  /// the existing `prepareScan` lifecycle.
  void resetCaptureState() {
    _lastObservedBuildPercent = 0;
    _peakObservedBuildPercent = 0;
    _buildEventCount = 0;
    _buildTimeUs = 0;
    _pendingVmWindowPercent = null;
    _pendingEnrichedNames.clear();
    _stagedEnrichedNames = null;
    _vmIssues.clear();
    _windowStart = _clock();
  }

  /// Current VM connectivity — set by the controller.
  /// Clears VM staging on disconnect; issues are repopulated on next _evaluate.
  bool get vmConnected => _vmConnected;
  @override
  set vmConnected(bool value) {
    final wasConnected = _vmConnected;
    _vmConnected = value;
    if (!value) {
      _buildEventCount = 0;
      _buildTimeUs = 0;
      _pendingVmWindowPercent = null;
      _vmIssues.clear();
      _pendingEnrichedNames.clear();
      _stagedEnrichedNames = null;
      // A leg straddling a VM disconnect must not export a peak from
      // before the drop; post-reconnect windows accumulate a fresh one.
      _lastObservedBuildPercent = 0;
      _peakObservedBuildPercent = 0;
    } else if (!wasConnected) {
      // Reconnect: stage a fresh-zero so the next _evaluate() flushes
      // stale structural/debug issues that are incompatible with VM mode.
      // The window restarts so its elapsed time excludes the disconnect.
      _pendingVmWindowPercent = 0;
      _windowStart = _clock();
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

  /// Process VM timeline data for BUILD scope time.
  ///
  /// Accumulates BUILD scope durations, event counts, and enriched dirty
  /// names into pending buffers. When at least 1 s has elapsed on the
  /// detector clock, the window closes: its build time divided by the
  /// measured elapsed time (windows close at poll arrival and can run
  /// 1.0–1.5 s) is staged with the enrichment atomically for [_evaluate].
  @override
  void processTimelineData(ParsedTimelineData data) {
    if (!_isEnabled) return;
    _buildEventCount += data.buildEventCount;
    _buildTimeUs += data.totalBuildScopeUs;

    // Accumulate enriched dirty names from this batch
    for (final event in data.phaseEvents) {
      if (event.phase == TimelinePhase.build && event.dirtyList != null) {
        _pendingEnrichedNames.addAll(event.dirtyList!);
      }
    }

    final now = _clock();
    final elapsedUs = now.difference(_windowStart).inMicroseconds;
    if (elapsedUs >= Duration.microsecondsPerSecond) {
      // Clamped: a mis-paired or nested scope could otherwise credit more
      // phase time than the window holds.
      final percent = (_buildTimeUs / elapsedUs * 100).clamp(0.0, 100.0);
      _pendingVmWindowPercent = percent;
      _lastObservedBuildPercent = percent;
      // Stage enrichment atomically with the window share
      _stagedEnrichedNames = _pendingEnrichedNames.isNotEmpty
          ? _pendingEnrichedNames.toList()
          : null;
      _pendingEnrichedNames.clear();
      _buildEventCount = 0;
      _buildTimeUs = 0;
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

    // Track StatefulWidget rebuild indicators — skip framework widgets so
    // the structural-only fallback (stateful_density) reflects user-created
    // widget density. Private-named widgets (starting with '_') are
    // overwhelmingly framework internals (_ModalScope, _MediaQueryFromView,
    // etc.) and named framework widgets (Scaffold, Navigator) are filtered
    // by the set. This prevents stateful_density from firing on every
    // Material page where 50+ framework StatefulWidgets are always present.
    if (element is StatefulElement &&
        !name.startsWith('_') &&
        !_frameworkWidgetNames.contains(name)) {
      _widgetRebuildCounts[name] = (_widgetRebuildCounts[name] ?? 0) + 1;
    }

    // Collect highlights for hot types. Severity uses the SAME effective
    // threshold as the issue path (`_evaluateDebugData`): builder widgets
    // escalate to critical at `> effectiveThreshold * 3` (= 90/sec for
    // builders), not at `rebuildsPerSecThreshold * 3` (= 30/sec). A plain
    // `* 3` would over-escalate builders by 60 units relative to issues.
    final rate = _hotTypes[name];
    if (rate != null) {
      final count = _hotCounts[name] ?? 0;
      if (count < _maxHighlightsPerType) {
        final ro = element.renderObject;
        if (ro != null) {
          final rect = getGlobalRect(ro);
          if (rect != null) {
            final effectiveThreshold =
                _builderWidgetTypes.contains(baseTypeName(name))
                ? rebuildsPerSecThreshold * builderThresholdMultiplier
                : rebuildsPerSecThreshold;
            _highlights.add(
              WidgetHighlight(
                rect: rect,
                renderObject: ro,
                widgetName: name,
                severity: rate > effectiveThreshold * debugCriticalMultiplier
                    ? IssueSeverity.critical
                    : IssueSeverity.warning,
                detectorName: 'Rebuild',
                detail: '${rate.round()} rebuilds/sec',
              ),
            );
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

    // Priority 1: Debug snapshot (per-widget type attribution).
    // Source-mode `flutterTimeline` includes initial widget inflations
    // (KDD-5) — `_evaluate` suppresses per-type issues for that source.
    // Highlights MUST share the same gate or the overlay paints hot-widget
    // boxes without a corresponding issue card.
    final snapshot = _pendingDebugSnapshot;
    if (snapshot != null) {
      if (snapshot.source == RebuildCountSource.flutterTimeline) {
        return hotTypes;
      }
      for (final entry in snapshot.rebuildCounts.entries) {
        final rate = snapshot.rebuildsPerSecond(entry.key);
        final threshold = _builderWidgetTypes.contains(baseTypeName(entry.key))
            ? rebuildsPerSecThreshold * builderThresholdMultiplier
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
        final threshold = _builderWidgetTypes.contains(baseTypeName(entry.key))
            ? rebuildsPerSecThreshold * builderThresholdMultiplier
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
  /// with 0 → clear stale issues). A fresh debug snapshot replaces
  /// [_debugIssues], a fresh VM window replaces [_vmIssues], and
  /// [_issues] is rebuilt from both, so a tick of one source keeps the
  /// other source's issues. Staging is consumed so a window or snapshot
  /// is evaluated once.
  void _evaluate() {
    final debugSnapshot = _pendingDebugSnapshot;
    final vmWindowPercent = _pendingVmWindowPercent;
    final enrichedNames = _stagedEnrichedNames;
    final hasStructuralData = !_vmConnected && _widgetRebuildCounts.isNotEmpty;

    final hasFreshDebug = debugSnapshot != null;
    final hasFreshVm = _vmConnected && vmWindowPercent != null;

    // No fresh data from any source — keep existing issues.
    if (!hasFreshDebug && !hasFreshVm && !hasStructuralData) return;

    // Unconditional clear — prevents enrichment leaking across branches.
    _stagedEnrichedNames = null;

    if (hasFreshDebug) {
      _issues.clear();
      // `_evaluateDebugData` must NOT run on profile-mode
      // (`flutterTimeline`) snapshots. Those counts include initial widget
      // inflations per KDD-5 — feeding them to the per-type "Excessive
      // Rebuilds" path produced critical false positives on route entry
      // (e.g. `ProductCard × 50` list-entry inflations interpreted as
      // rebuilds). Profile mode surfaces a single session-level rollup
      // instead; debug mode keeps the per-type attribution unchanged
      // because `debugOnRebuildDirtyWidget` only fires on actual
      // `setState`-driven rebuilds. The gate is "not flutterTimeline"
      // rather than "equals debugCallback" so existing tests that
      // construct `DebugSnapshot` with the default `source:
      // RebuildCountSource.none` (no explicit source tag) keep exercising
      // the per-type path — backwards compatibility for pre-v15 fixtures.
      if (debugSnapshot.source != RebuildCountSource.flutterTimeline &&
          debugSnapshot.totalRebuilds > 0) {
        _evaluateDebugData(debugSnapshot);
      }
      _debugIssues
        ..clear()
        ..addAll(_issues);
      _pendingDebugSnapshot = null;
    }

    if (hasFreshVm) {
      _issues.clear();
      // Per-type debug attribution wins; the VM share is evaluated (and
      // emitted) only when no type crossed its threshold, which also
      // surfaces a storm spread across many sub-threshold types as
      // `rebuild_activity`.
      if (_debugIssues.isEmpty && vmWindowPercent > 0) {
        _evaluateVmData(vmWindowPercent, enrichedNames);
      }
      _vmIssues
        ..clear()
        ..addAll(_issues);
      _pendingVmWindowPercent = null;
    }

    _issues.clear();
    if (_debugIssues.isNotEmpty) {
      _issues.addAll(_debugIssues);
    } else if (_vmConnected) {
      _issues.addAll(_vmIssues);
    } else if (!hasFreshDebug && hasStructuralData) {
      _evaluateStructuralOnly();
    }
  }

  /// Debug callback path — per-widget-type rebuild attribution.
  void _evaluateDebugData(DebugSnapshot snapshot) {
    // Read once per evaluation pass — multiple per-widget emissions in
    // the same scan tick share the same lifecycle phase.
    final lifecyclePhase = _classifyLifecyclePhase();
    for (final entry in snapshot.rebuildCounts.entries) {
      final typeName = entry.key;
      final count = entry.value;
      final rate = snapshot.rebuildsPerSecond(typeName);

      // Builder widgets are designed to rebuild on data/tick changes —
      // apply a higher threshold to avoid false positives. Canonicalize
      // the generic suffix because production runtime types arrive as
      // `StreamBuilder<int>` etc.
      final isBuilder = _builderWidgetTypes.contains(baseTypeName(typeName));
      final effectiveThreshold = isBuilder
          ? rebuildsPerSecThreshold * builderThresholdMultiplier
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

      _issues.add(
        PerformanceIssue(
          stableId: 'rebuild_debug_$typeName',
          severity: rate > effectiveThreshold * debugCriticalMultiplier
              ? IssueSeverity.critical
              : IssueSeverity.warning,
          category: IssueCategory.build,
          confidence: IssueConfidence.confirmed,
          title: 'Excessive Rebuilds: $typeName (${rate.round()}/sec)',
          detail:
              '$typeName: $count rebuilds in '
              '${elapsedSec.toStringAsFixed(1)}s '
              '(${rate.round()}/sec).$builderNote',
          fixHint: hint,
          fixEffort: effort,
          widgetName: typeName,
          ancestorChain: snapshot.ancestorChains[typeName],
          observationSource: ObservationSource.debugCallback,
          detectedAt: DateTime.now(),
          extraTraceArgs: {'lifecyclePhase': ?lifecyclePhase},
          confidenceReason:
              'Measured directly from debug callback rebuild counter',
        ),
      );
    }
  }

  /// VM timeline path — share of UI-thread time inside BUILD scopes, with
  /// attribution context.
  ///
  /// When [enrichedNames] are available (from timeline enrichment args),
  /// uses them for dirty-widget attribution. Otherwise falls back to
  /// structural tree scan context.
  void _evaluateVmData(double percent, [List<String>? enrichedNames]) {
    // The peak moves on the evaluation path that stamps
    // `observedBuildPercent`, so every peak above the threshold is also
    // the arg of an emission (the audit's `max` reduction matches it).
    if (percent > _peakObservedBuildPercent) {
      _peakObservedBuildPercent = percent;
    }
    if (percent <= buildTimePercentThreshold) return;

    String detailSuffix;

    if (enrichedNames != null && enrichedNames.isNotEmpty) {
      // Enriched path: count occurrences of each dirty widget type
      final counts = <String, int>{};
      for (final name in enrichedNames) {
        counts[name] = (counts[name] ?? 0) + 1;
      }
      final sorted = counts.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      detailSuffix =
          '\nTop dirty widgets (timeline enrichment): '
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

    final formatted = percent.toStringAsFixed(1);
    final (hint, effort) = FixHintBuilder.rebuildActivity(
      buildPercent: percent,
    );

    final detectedAt = DateTime.now();
    final lifecyclePhase = _classifyLifecyclePhase();
    _issues.add(
      PerformanceIssue(
        stableId: 'rebuild_activity',
        severity: percent > buildTimePercentThreshold * 3
            ? IssueSeverity.critical
            : IssueSeverity.warning,
        category: IssueCategory.build,
        confidence: IssueConfidence.confirmed,
        title: 'Rebuild Activity: build phase $formatted% of UI time',
        detail:
            'Widget rebuilding (BUILD scopes on the UI thread) took '
            '$formatted% of wall time in the last ~1 s window '
            '(threshold ${_formatPercent(buildTimePercentThreshold)}%).'
            '$detailSuffix',
        fixHint: hint,
        fixEffort: effort,
        observationSource: ObservationSource.vmTimeline,
        detectedAt: detectedAt,
        dedupIdentityMicros: detectedAt.microsecondsSinceEpoch,
        extraTraceArgs: {
          'observedBuildPercent': formatted,
          'lifecyclePhase': ?lifecyclePhase,
        },
        confidenceReason: 'Measured directly from VM timeline BUILD durations',
      ),
    );
  }

  static String _formatPercent(double value) => value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);

  /// Structural-only fallback when VM data is unavailable.
  /// Reports high StatefulWidget density as context, not proven rebuild rate.
  void _evaluateStructuralOnly() {
    final totalStateful = _widgetRebuildCounts.values.fold(0, (s, v) => s + v);
    if (totalStateful < statefulDensityThreshold) return;

    final topRebuilders = _widgetRebuildCounts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final topWidget = topRebuilders.isNotEmpty
        ? topRebuilders.first.key
        : 'Unknown';

    final (hint, effort) = FixHintBuilder.statefulDensity(
      topWidget: topRebuilders.isNotEmpty ? topWidget : null,
    );

    final lifecyclePhase = _classifyLifecyclePhase();
    _issues.add(
      PerformanceIssue(
        stableId: 'stateful_density',
        severity: IssueSeverity.warning,
        category: IssueCategory.build,
        confidence: IssueConfidence.possible,
        title: 'High StatefulWidget Density: $totalStateful instances',
        detail:
            '$totalStateful StatefulWidget instances on screen '
            '(VM unavailable — rebuild rate unknown).'
            '${topRebuilders.isNotEmpty ? '\nMost common: $topWidget '
                      '(${topRebuilders.first.value} instances).' : ''}',
        fixHint: hint,
        fixEffort: effort,
        observationSource: ObservationSource.structural,
        detectedAt: DateTime.now(),
        extraTraceArgs: {'lifecyclePhase': ?lifecyclePhase},
        confidenceReason:
            'Structural scan only — connect VM for higher confidence',
      ),
    );
  }

  /// Framework StatefulWidget types that inflate the structural density count
  /// without indicating a user performance issue. These are always present on
  /// Material/Cupertino pages and would cause stateful_density to fire on
  /// every page when the VM is unavailable.
  static const _frameworkWidgetNames = {
    // Material / Cupertino framework widgets
    'Scaffold',
    'ScaffoldMessenger',
    'AppBar',
    'Material',
    'AnimatedTheme',
    'Navigator',
    'Overlay',
    'Scrollable',
    'ScrollConfiguration',
    'ScrollNotificationObserver',
    'FocusScope',
    'FocusTraversalGroup',
    'Actions',
    'Shortcuts',
    'GlowingOverscrollIndicator',
    'StretchingOverscrollIndicator',
    'RawGestureDetector',
    'RawScrollbar',
    'EditableText',
    'ModalBarrier',
    'CupertinoPageScaffold',
    'CupertinoTabScaffold',
    'MaterialApp',
    'WidgetsApp',
    'CupertinoApp',
    'HeroControllerScope',
    'PrimaryScrollController',
    'DefaultTextEditingShortcuts',
    'DefaultSelectionStyle',
    'DefaultTabController',
    'TabBarView',
    'TabBar',
    'PageView',
    // Sleuth overlay widgets — internal diagnostics, not user-created
    'SleuthOverlay',
    'FloatingIssuesCard',
    'TriggerButton',
    'IssueCard',
    'IssueEncyclopediaPage',
    'AiChatPage',
    'GuidePage',
    'StartupMetricsPage',
    'RebuildStatsPage',
  };

  @override
  void dispose() {
    _issues.clear();
    _debugIssues.clear();
    _vmIssues.clear();
    _highlights.clear();
    _widgetRebuildCounts.clear();
    _pendingEnrichedNames.clear();
    _stagedEnrichedNames = null;
  }

  @override
  DetectorMetadata get validationMetadata => const DetectorMetadata(
    tier: EvidenceTier.reproducerOnly,
    perStableIdTier: {'rebuild_activity': EvidenceTier.runtimeVerified},
    additionalBrackets: [
      BracketSpec(
        stableId: 'rebuild_activity',
        severityLabel: 'critical',
        threshold: 30,
        unit: 'percent',
        coveredThresholds: {'rebuild_activity.critical'},
        profileCapturePaths: [
          'test/validation/captures/rebuild_detector/critical_below.json',
          'test/validation/captures/rebuild_detector/critical_at.json',
          'test/validation/captures/rebuild_detector/critical_above.json',
        ],
        atTolerance: 0.5,
        aboveCeilingMultiplier: 2.7,
        requireUniqueDetectedAtMicros: true,
        requireDetectorTraceRecord: true,
        observedAxisArgKey: 'observedBuildPercent',
        observedAxisTolerance: 0.25,
        observedAxisReduction: 'max',
        // Each leg's capture must contain >=2 in-band detector samples in
        // its role band so a single in-band window surrounded by sub-band
        // windows cannot certify the bracket. Build time drifts with
        // device temperature across a 6 s leg; requiring redundancy keeps
        // the gate robust against a dropped window.
        minInBandSamples: 2,
      ),
    ],
    rationale:
        'Hybrid detector. Three families: `stateful_density` '
        '(public-named StatefulWidget density at or above '
        '`statefulDensityThreshold` instances, default 10, independent '
        'of rebuild cost; framework/private filtered), '
        '`rebuild_activity` (share of UI-thread wall time spent inside '
        'VM-timeline BUILD scopes over each ~1 s window, normalised by '
        'the measured window length — warning at '
        '`> buildTimePercentThreshold` default 10 %, critical at `> 3×` '
        '= 30 %; reproducer pins 9.5 → silent, 10.5 → warning, 31 → '
        'critical), and parametric `rebuild_debug_<typeName>` (per-widget '
        'rebuilds/sec from debug instrumentation against '
        '`rebuildsPerSecThreshold`; declared via `parametricFamilies` — '
        'concrete `rebuild_debug_MyWidget` credits via `_` separator '
        'matcher). `rebuild_activity` warning and critical are '
        'runtimeVerified via on-device capture triads on iPhone 12 + '
        'iOS 17.5 + Flutter 3.47.x. The capture workload varies BUILD '
        'cost per frame (rows of non-const leaf widgets rebuilt by a '
        'per-frame Ticker) at a fixed frame rate, with a calibration '
        'pre-pass that scales the row count to the leg target and an '
        'idle window between pre-pass and scenario so pre-pass build '
        'time cannot reach an in-span emission. The `max` reduction '
        'over in-span `observedBuildPercent` args matches '
        '`peakObservedBuildPercent`, which moves only on the emission '
        'path; atTolerance 0.5 and observedAxisTolerance 0.25 absorb '
        'thermal drift in build duration across a leg. VM → '
        'TimelineParser → detector boundary exercised via '
        'cross-harness reproducer (raw `List<TimelineEvent>` '
        'through `parseAndAssertShape` + real `pumpWidget` for '
        'the structural-fallback leg). Builder-widget 3× per-widget '
        'threshold multiplier proven with paired non-builder/builder '
        'fixture at identical rate=25. Source-mode '
        '`RebuildCountSource.flutterTimeline` per-type suppression '
        'pinned. Detector stamps `observedBuildPercent` and '
        '`dedupIdentityMicros` on every `rebuild_activity` emission; '
        '`lastObservedBuildPercent` tracks every closed window.',
    reproducerPath: 'test/validation/rebuild_reproducer_test.dart',
    coveredStableIds: {'stateful_density', 'rebuild_activity'},
    coveredThresholds: {
      'rebuild_activity.warning',
      'rebuild_activity.critical',
    },
    parametricFamilies: {'rebuild_debug'},
    bracketStableId: 'rebuild_activity',
    bracketSeverityLabel: 'warning',
    bracketThreshold: 10,
    bracketUnit: 'percent',
    bracketAtTolerance: 0.5,
    aboveCeilingMultiplier: 2.7,
    observedAxisArgKey: 'observedBuildPercent',
    observedAxisTolerance: 0.25,
    observedAxisReduction: 'max',
    bracketRequireUniqueDetectedAtMicros: true,
    profileCapturePaths: [
      'test/validation/captures/rebuild_detector/below.json',
      'test/validation/captures/rebuild_detector/at.json',
      'test/validation/captures/rebuild_detector/above.json',
    ],
  );
}
