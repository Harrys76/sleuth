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
///
/// Each emission stamps `extraTraceArgs.lifecyclePhase: 'startup' |
/// 'steady'` based on whether the issue EMITTED within
/// [startupPhaseWindowSeconds] of [Sleuth.dartEntryMonotonicUs]. The
/// classification reads `Timeline.now` at emission time — it is
/// **emission-time semantics**, not event-time. `rebuild_activity`'s
/// 1-second window means a window straddling the startup boundary tags
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
    this.startupPhaseWindowSeconds = 5,
    DateTime Function()? clock,
    int? Function()? appStartMonotonicUsForTest,
  })  : _clock = clock ?? DateTime.now,
        _windowStart = (clock ?? DateTime.now)(),
        _appStartForTest = appStartMonotonicUsForTest,
        super(
          type: DetectorType.rebuild,
          lifecycle: DetectorLifecycle.hybrid,
          name: 'Rebuild',
          description: 'Detects excessive widget rebuilds (>10/sec)',
        );

  final int rebuildsPerSecThreshold;

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

  /// Last observed rebuilds-per-second count from the VM-backed
  /// `_evaluateVmData` path. Updated unconditionally on every call —
  /// sub-threshold buffers (no warning fire) still expose detector-
  /// measured evidence so capture-mode operators export the same axis
  /// the audit gate classifies on.
  // _evaluateVmData rewrites this on every call and resetCaptureState
  // clears it on session boundaries; cannot be final.
  // ignore: prefer_final_fields
  int _lastObservedRebuildRate = 0;

  /// Detector-measured rebuilds-per-second from the most recent
  /// VM-backed evaluation, with [baselineRebuildRate] subtracted when
  /// non-zero. Capture-mode operators read this for sub-threshold legs
  /// where no warning event fires. A separate `Sleuth.flushTimelineNow()`
  /// barrier drives the VM-poll → `processTimelineData` →
  /// `_evaluateVmData` chain that updates this getter; no detector-side
  /// flush API needed.
  int get lastObservedRebuildRate => _lastObservedRebuildRate;

  // Highest adjusted window count seen since the last
  // resetCaptureState call. Capture-mode operators read this for
  // bracket-band evidence when the audit gate uses
  // `observedAxisReduction: 'max'`. Last-window-only would let a
  // tail-off window understate the worst signal in the scenario.
  // ignore: prefer_final_fields
  int _peakObservedRebuildRate = 0;

  /// Highest adjusted rebuilds-per-second observed across all staged
  /// windows since the last [resetCaptureState] (which is auto-invoked
  /// by `Sleuth.markScenarioBegin`). Capture-mode operators report
  /// this as `expectedMagnitude.observed` when the audit-gate bracket
  /// uses `observedAxisReduction: 'max'` so the capture's send-side
  /// number agrees with the schema's max-of-trace-events reduction.
  int get peakObservedRebuildRate => _peakObservedRebuildRate;

  /// Ambient framework-driven rebuild rate (BUILDs per second observed
  /// when no user signal is present). Subtracted from raw window counts
  /// before the threshold gate fires and before
  /// [_lastObservedRebuildRate] is exposed. Defaults to `0` —
  /// live-monitoring behavior is unchanged because zero subtraction is
  /// a no-op. Capture-mode operators set this via [setBaseline] after a
  /// dedicated idle-measurement run, so that on-device evidence
  /// reflects user-driven rebuild activity rather than Material
  /// framework noise (Scaffold animations, theme inheritance, navigator
  /// transitions). Without this, iOS profile-mode emits ~10–15 BUILD
  /// events per second purely from framework state, which exceeds the
  /// default 10/sec threshold and breaks below-leg honesty for the
  /// runtimeVerified bracket.
  int _baselineRebuildRate = 0;

  /// Currently configured ambient floor for capture-mode evidence. See
  /// [setBaseline].
  int get baselineRebuildRate => _baselineRebuildRate;

  /// Configures the ambient rebuild floor that [_evaluateVmData]
  /// subtracts from raw window counts. Pass `0` to disable subtraction
  /// (the default; preserves live-monitoring semantics). Typical
  /// usage: capture-mode operator runs an idle scenario, reads
  /// [lastObservedRebuildRate], then calls [setBaseline] with that
  /// value before driving the actual workload. Negative inputs are
  /// clamped to `0`.
  void setBaseline(int rate) {
    _baselineRebuildRate = rate < 0 ? 0 : rate;
  }

  /// Capture-mode session-boundary reset hook called from
  /// `SleuthController.resetCaptureState()` (auto-invoked by
  /// `Sleuth.markScenarioBegin`). Clears the VM-path window state so
  /// leg N+1's measured rate reflects ONLY leg-N+1 activity:
  ///   - `_lastObservedRebuildRate`: prior leg's peak read.
  ///   - `_buildEventCount`: accumulator that would otherwise carry
  ///     pre-scenario BUILD events into the first window stage.
  ///   - `_pendingVmWindowCount`: staged-but-unconsumed window count
  ///     from a window that closed before scenario start.
  ///   - `_pendingEnrichedNames` / `_stagedEnrichedNames`: parallel
  ///     dirty-widget staging for the same window.
  ///   - `_windowStart`: re-anchored to scenario-begin time so the
  ///     next window stage fires exactly 1 s after leg start, not
  ///     1 s from app-construction time.
  ///
  /// `_pendingDebugSnapshot` and `_widgetRebuildCounts` are NOT
  /// touched — those drive the structural-fallback path, managed by
  /// the existing `prepareScan` lifecycle. Clearing them would
  /// change behavior for non-capture detector paths.
  void resetCaptureState() {
    _lastObservedRebuildRate = 0;
    _peakObservedRebuildRate = 0;
    _buildEventCount = 0;
    _pendingVmWindowCount = null;
    _pendingEnrichedNames.clear();
    _stagedEnrichedNames = null;
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
      _pendingVmWindowCount = null;
      _pendingEnrichedNames.clear();
      _stagedEnrichedNames = null;
      // Capture-mode operators set a non-zero baseline before each
      // leg via `setBaseline(int)`. The baseline is intentionally
      // retained across `resetCaptureState` so multiple legs in one
      // session share the ambient measurement. VM disconnect is the
      // implicit end of a capture session: a `setBaseline`-bearing
      // session that loses VM connectivity (DevTools detach, app
      // backgrounded, debugger reattach) and reconnects must NOT
      // carry the stale floor into post-reconnect live monitoring,
      // otherwise the threshold gate silently suppresses real
      // rebuild storms in `(threshold, threshold + baseline]`.
      _baselineRebuildRate = 0;
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
                    ? rebuildsPerSecThreshold * _builderThresholdMultiplier
                    : rebuildsPerSecThreshold;
            _highlights.add(WidgetHighlight(
              rect: rect,
              widgetName: name,
              severity: rate > effectiveThreshold * 3
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
        final threshold = _builderWidgetTypes.contains(baseTypeName(entry.key))
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
        // Same-tick VM fallback. `_evaluateDebugData` only fires when an
        // individual type crosses its per-type threshold; a window where
        // total rebuilds are spread across many sub-threshold types
        // would otherwise drop the VM aggregate signal entirely. Surface
        // it as `rebuild_activity` instead of silently discarding the
        // storm.
        if (_issues.isEmpty && hasFreshVm && vmWindowCount > 0) {
          _evaluateVmData(vmWindowCount, enrichedNames);
        }
      } else if (debugSnapshot.totalRebuilds == 0 && hasFreshVm) {
        // Debug callbacks active but returned zero counts — fall back to VM.
        if (vmWindowCount > 0) {
          _evaluateVmData(vmWindowCount, enrichedNames);
        }
      }
      // Debug snapshot is the priority signal whenever fresh; consume the
      // VM window in the same scan. Otherwise the `flutterTimeline +
      // totalRebuilds > 0 + hasFreshVm` branch falls through both inner
      // cases and leaves `_pendingVmWindowCount` staged. The next scan
      // would replay it as `rebuild_activity` after the snapshot's
      // enrichment + tree context has already been discarded — a stale
      // ghost issue, often surfacing after navigation.
      _pendingDebugSnapshot = null;
      _pendingVmWindowCount = null;
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
        extraTraceArgs: {
          if (lifecyclePhase != null) 'lifecyclePhase': lifecyclePhase,
        },
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
    // Subtract the configured ambient floor before the threshold gate.
    // When [_baselineRebuildRate] is 0 (the default for live monitoring)
    // the adjusted count is identical to the raw count, so existing
    // detection semantics are unchanged. Capture mode opts in by calling
    // [setBaseline] with a measured idle rate, which lets the
    // user-driven signal cross the threshold without ambient framework
    // BUILDs (Material animations, theme inheritance, navigator
    // transitions on iOS profile mode) inflating the magnitude.
    final adjusted = (buildCount - _baselineRebuildRate).clamp(0, buildCount);

    // Update detector-measured rate BEFORE the threshold gate so
    // sub-threshold buffers still expose the value to capture-mode
    // operators. The threshold gate below skips emission only —
    // the field is the source of truth for the bracket axis.
    _lastObservedRebuildRate = adjusted;
    if (adjusted > _peakObservedRebuildRate) {
      _peakObservedRebuildRate = adjusted;
    }
    if (adjusted <= rebuildsPerSecThreshold) return;

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

    // FixHintBuilder receives the RAW count (not adjusted) so the
    // user-facing prose reflects total observed rebuild activity, not
    // baseline-subtracted activity. A user reading the hint cares
    // about reducing the actual rebuild rate happening in their app —
    // baseline-correction is an internal capture-mode mechanism that
    // shouldn't surface in advice text.
    final (hint, effort) = FixHintBuilder.rebuildActivity(
      buildCount: buildCount,
    );

    final detectedAt = DateTime.now();
    final lifecyclePhase = _classifyLifecyclePhase();
    _issues.add(PerformanceIssue(
      stableId: 'rebuild_activity',
      severity: adjusted > rebuildsPerSecThreshold * 3
          ? IssueSeverity.critical
          : IssueSeverity.warning,
      category: IssueCategory.build,
      confidence: IssueConfidence.confirmed,
      title: 'High Rebuild Activity: $adjusted builds/sec',
      detail: '$adjusted widget rebuilds in the last second.$detailSuffix',
      fixHint: hint,
      fixEffort: effort,
      observationSource: ObservationSource.vmTimeline,
      detectedAt: detectedAt,
      dedupIdentityMicros: detectedAt.microsecondsSinceEpoch,
      extraTraceArgs: {
        'observedRebuildRate': adjusted.toString(),
        if (lifecyclePhase != null) 'lifecyclePhase': lifecyclePhase,
      },
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

    final lifecyclePhase = _classifyLifecyclePhase();
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
      extraTraceArgs: {
        if (lifecyclePhase != null) 'lifecyclePhase': lifecyclePhase,
      },
      confidenceReason:
          'Structural scan only — connect VM for higher confidence',
    ));
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
    _highlights.clear();
    _widgetRebuildCounts.clear();
    _pendingEnrichedNames.clear();
    _stagedEnrichedNames = null;
  }

  @override
  DetectorMetadata get validationMetadata => const DetectorMetadata(
        tier: EvidenceTier.reproducerOnly,
        perStableIdTier: {
          'rebuild_activity': EvidenceTier.runtimeVerified,
        },
        additionalBrackets: [
          BracketSpec(
            stableId: 'rebuild_activity',
            severityLabel: 'critical',
            threshold: 31,
            unit: 'rebuilds',
            coveredThresholds: {'rebuild_activity.critical'},
            profileCapturePaths: [
              'test/validation/captures/rebuild_detector/critical_below.json',
              'test/validation/captures/rebuild_detector/critical_at.json',
              'test/validation/captures/rebuild_detector/critical_above.json',
            ],
            atTolerance: 0.65,
            aboveCeilingMultiplier: 2.7,
            requireUniqueDetectedAtMicros: true,
            requireDetectorTraceRecord: true,
            observedAxisArgKey: 'observedRebuildRate',
            observedAxisReduction: 'max',
            // Each leg's capture must contain >=2 in-band detector
            // samples in its role band so a single in-band peak
            // surrounded by sub-band emissions cannot certify the
            // bracket. iPhone thermal throttling on a 6 s sustained
            // leg routinely produces a mix of in-band + sub-band
            // emissions; requiring redundancy makes the audit gate
            // robust against a future event drop (VM-poll dedup
            // tightening, ring-buffer roll, reduction-strategy
            // change) that would otherwise leave the leg with only
            // sub-band evidence.
            minInBandSamples: 2,
          ),
        ],
        rationale: 'Hybrid detector. Three families: `stateful_density` '
            '(public-named StatefulWidget density; framework/private '
            'filtered), `rebuild_activity` (VM-timeline rebuild-rate — '
            'warning at `> rebuildsPerSecThreshold` default 10/sec, '
            'critical at `> 3×` = 30/sec; reproducer pins 11 → warning, '
            '31 → critical), and parametric `rebuild_debug_<typeName>` '
            '(declared via `parametricFamilies` — concrete '
            '`rebuild_debug_MyWidget` credits via `_` separator '
            'matcher). `rebuild_activity.warning` runtimeVerified via '
            'three on-device captures bracketing 11 BUILDs/sec '
            '(below 8 / at 18 / above 26) on iPhone 12 + iOS 17.5 + '
            'Flutter 3.41.x. Capture-mode operator measures ambient '
            'baseline inline before each leg and calls '
            '`setBaseline(int)` so framework-driven BUILDs (Material '
            'animations, theme inheritance, navigator transitions) are '
            'subtracted from the threshold gate. Without subtraction '
            'iOS profile-mode emits ~10–15 BUILDs/sec from ambient '
            'state alone, which exceeds the default threshold and '
            'breaks below-leg honesty. Live monitoring is unaffected '
            '(default baseline=0 → no-op subtraction). VM → '
            'TimelineParser → detector boundary exercised via '
            'cross-harness reproducer (raw `List<TimelineEvent>` '
            'through `parseAndAssertShape` + real `pumpWidget` for '
            'the structural-fallback leg). Builder-widget 3× threshold '
            'multiplier proven with paired non-builder/builder fixture '
            'at identical rate=25. Source-mode '
            '`RebuildCountSource.flutterTimeline` per-type suppression '
            'pinned. Detector exports `observedRebuildRate` to '
            '`extraTraceArgs` and stamps `dedupIdentityMicros` on '
            'every emission; `peakObservedRebuildRate` and '
            '`lastObservedRebuildRate` getters expose adjusted rates '
            'unconditionally (sub-threshold buffers update both '
            'before the emission gate). `RebuildActivityCaptureScreen` '
            'drives Stopwatch-throttled `_Pulse` setState (1 BUILD '
            'per tick via const-child diff short-circuit) at '
            'refresh-rate-independent rates.',
        reproducerPath: 'test/validation/rebuild_reproducer_test.dart',
        coveredStableIds: {'stateful_density', 'rebuild_activity'},
        coveredThresholds: {
          'rebuild_activity.warning',
          'rebuild_activity.critical',
        },
        parametricFamilies: {'rebuild_debug'},
        bracketStableId: 'rebuild_activity',
        bracketSeverityLabel: 'warning',
        bracketThreshold: 11,
        bracketUnit: 'rebuilds',
        bracketAtTolerance: 0.65,
        aboveCeilingMultiplier: 2.7,
        observedAxisArgKey: 'observedRebuildRate',
        observedAxisReduction: 'max',
        bracketRequireUniqueDetectedAtMicros: true,
        profileCapturePaths: [
          'test/validation/captures/rebuild_detector/below.json',
          'test/validation/captures/rebuild_detector/at.json',
          'test/validation/captures/rebuild_detector/above.json',
        ],
      );
}
