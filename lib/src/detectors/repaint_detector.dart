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

/// Detects excessive repainting using VM Timeline Paint events or debug
/// callback aggregate paint counts.
///
/// **Hybrid Detector** — VM Timeline provides exact paint event data
/// (confirmed confidence). Debug callbacks provide aggregate paint count
/// fallback (likely confidence, no per-widget attribution).
///
/// Data sources accumulate into staging fields; the single [_evaluate]
/// method is the ONLY writer of [_issues]. Called from [scanTree] (scan
/// tick) and [evaluateNow] (timeline tick).
class RepaintDetector extends BaseDetector {
  RepaintDetector({
    this.paintFrequencyThreshold = 30,
    DateTime Function()? clock,
  })  : _clock = clock ?? DateTime.now,
        _windowStart = (clock ?? DateTime.now)(),
        super(
          type: DetectorType.repaint,
          lifecycle: DetectorLifecycle.hybrid,
          name: 'Repaint',
          description: 'Detects excessive repainting (>30 paints/sec)',
        );

  final int paintFrequencyThreshold;
  final DateTime Function() _clock;
  final List<PerformanceIssue> _issues = [];
  final List<WidgetHighlight> _highlights = [];
  static const int _maxHighlightsPerType = 3;
  bool _isEnabled = true;

  int _paintEventCount = 0;
  DateTime _windowStart;

  // -- Staging fields (nullable = no fresh data) --

  /// null = no VM window completed since last evaluate.
  int? _pendingVmWindowCount;

  /// null = no new snapshot delivered since last evaluate.
  DebugSnapshot? _pendingDebugSnapshot;

  /// Dirty RenderObject count from enriched timeline args, accumulating
  /// across timeline ticks until the next 1s window completes.
  int _pendingEnrichedDirtyTotal = 0;

  /// Enriched dirty count staged atomically with [_pendingVmWindowCount].
  /// Consumed by [_evaluateVmData] and cleared unconditionally in [_evaluate].
  int? _stagedEnrichedDirtyTotal;

  bool _vmConnected = false;

  /// Current VM connectivity — set by the controller.
  bool get vmConnected => _vmConnected;
  @override
  set vmConnected(bool value) {
    final wasConnected = _vmConnected;
    _vmConnected = value;
    if (!value) {
      _paintEventCount = 0;
      _pendingVmWindowCount = null;
      _pendingEnrichedDirtyTotal = 0;
      _stagedEnrichedDirtyTotal = null;
    } else if (!wasConnected) {
      // Reconnect: stage a fresh-zero so the next _evaluate() flushes
      // stale debug issues that are incompatible with VM mode.
      _pendingVmWindowCount = 0;
    }
  }

  @override
  List<PerformanceIssue> get issues => List.unmodifiable(_issues);

  @override
  List<WidgetHighlight> get highlights => List.unmodifiable(_highlights);

  @override
  bool get isEnabled => _isEnabled;

  @override
  set isEnabled(bool value) => _isEnabled = value;

  /// Process VM timeline data for paint event counts.
  ///
  /// Accumulates counts and enriched dirty totals into pending buffers.
  /// On 1s window completion, stages count + enrichment atomically
  /// for [_evaluate].
  @override
  void processTimelineData(ParsedTimelineData data) {
    if (!_isEnabled) return;

    _paintEventCount += data.flushPaintDurations.length;

    // Accumulate enriched dirty counts from this batch
    for (final event in data.phaseEvents) {
      if (event.phase == TimelinePhase.paint && event.dirtyCount != null) {
        _pendingEnrichedDirtyTotal += event.dirtyCount!;
      }
    }

    final now = _clock();
    if (now.difference(_windowStart).inMilliseconds >= 1000) {
      _pendingVmWindowCount = _paintEventCount;
      // Stage enrichment atomically with the window count
      _stagedEnrichedDirtyTotal =
          _pendingEnrichedDirtyTotal > 0 ? _pendingEnrichedDirtyTotal : null;
      _pendingEnrichedDirtyTotal = 0;
      _paintEventCount = 0;
      _windowStart = now;
    }
  }

  Map<String, double> _hotTypes = const {};
  final Map<String, int> _hotCounts = {};

  @override
  void prepareScan(BuildContext context) {
    _highlights.clear();
    _hotCounts.clear();

    // Compute hot types from per-widget debug paint data
    _hotTypes = const {};
    final snapshot = _pendingDebugSnapshot;
    if (snapshot != null && snapshot.paintCounts.isNotEmpty) {
      final types = <String, double>{};
      for (final entry in snapshot.paintCounts.entries) {
        final rate = snapshot.paintsPerSecondForType(entry.key);
        if (rate >= paintFrequencyThreshold) {
          types[entry.key] = rate;
        }
      }
      if (types.isNotEmpty) _hotTypes = types;
    }
  }

  @override
  void checkElement(Element element) {
    if (_hotTypes.isEmpty) return;

    final name = typeNameCache.lookup(element.widget);
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
              severity: rate > paintFrequencyThreshold * 2
                  ? IssueSeverity.critical
                  : IssueSeverity.warning,
              detectorName: 'Repaint',
              detail: '${rate.round()} repaints/sec',
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

  @override
  void updateDebugSnapshot(DebugSnapshot snapshot) {
    _pendingDebugSnapshot = snapshot;
  }

  @override
  void evaluateNow() => _evaluate();

  /// The ONLY method that writes [_issues].
  ///
  /// Priority: debug per-widget > VM aggregate > debug aggregate.
  /// Per-widget paint attribution is more actionable than aggregate counts.
  /// All staging is cleared up front to prevent stale data from a
  /// lower-priority source from overwriting on the next scan tick.
  void _evaluate() {
    final vmWindowCount = _pendingVmWindowCount;
    final debugSnapshot = _pendingDebugSnapshot;
    final enrichedDirtyTotal = _stagedEnrichedDirtyTotal;

    final hasFreshVm = _vmConnected && vmWindowCount != null;
    final hasFreshDebug = debugSnapshot != null;

    if (!hasFreshVm && !hasFreshDebug) return;

    _issues.clear();

    // Clear ALL staging regardless of which branch wins.
    _pendingVmWindowCount = null;
    _pendingDebugSnapshot = null;
    // Unconditional clear — prevents enrichment leaking across branches.
    _stagedEnrichedDirtyTotal = null;

    if (hasFreshDebug && debugSnapshot.paintCounts.isNotEmpty) {
      // Per-widget debug path — best attribution.
      // If no individual type crosses the threshold, fall through.
      _evaluateDebugDataPerWidget(debugSnapshot);
      if (_issues.isEmpty && hasFreshVm && vmWindowCount > 0) {
        _evaluateVmData(vmWindowCount, enrichedDirtyTotal);
      } else if (_issues.isEmpty && debugSnapshot.totalPaintCount > 0) {
        _evaluateDebugData(debugSnapshot);
      }
    } else if (hasFreshVm) {
      if (vmWindowCount > 0) {
        _evaluateVmData(vmWindowCount, enrichedDirtyTotal);
      }
    } else if (hasFreshDebug) {
      if (debugSnapshot.totalPaintCount > 0) {
        _evaluateDebugData(debugSnapshot);
      }
    }
  }

  /// VM timeline path — exact paint event data.
  ///
  /// When [enrichedDirtyTotal] is available (from timeline enrichment args),
  /// appends dirty RenderObject count to the issue detail.
  void _evaluateVmData(int paintCount, [int? enrichedDirtyTotal]) {
    if (paintCount <= paintFrequencyThreshold) return;

    final detailSuffix = enrichedDirtyTotal != null && enrichedDirtyTotal > 0
        ? '\n$enrichedDirtyTotal dirty RenderObjects '
            '(from timeline enrichment).'
        : '';

    final (hint, effort) = FixHintBuilder.excessiveRepaintVm();

    _issues.add(PerformanceIssue(
      stableId: 'excessive_repaint',
      severity: paintCount > paintFrequencyThreshold * 2
          ? IssueSeverity.critical
          : IssueSeverity.warning,
      category: IssueCategory.paint,
      confidence: IssueConfidence.confirmed,
      title: 'Excessive Repainting: $paintCount paints/sec',
      detail: '$paintCount paint events detected in 1 second. '
          'Threshold: $paintFrequencyThreshold/sec.$detailSuffix',
      fixHint: hint,
      fixEffort: effort,
      observationSource: ObservationSource.vmTimeline,
      detectedAt: DateTime.now(),
      confidenceReason: 'Measured directly from VM timeline paint events',
    ));
  }

  /// Debug callback path — per-widget paint attribution.
  void _evaluateDebugDataPerWidget(DebugSnapshot snapshot) {
    for (final entry in snapshot.paintCounts.entries) {
      final typeName = entry.key;
      final count = entry.value;
      final rate = snapshot.paintsPerSecondForType(typeName);

      if (rate < paintFrequencyThreshold) continue;

      final elapsedSec =
          snapshot.elapsed.inMicroseconds / Duration.microsecondsPerSecond;

      final (hint, effort) = FixHintBuilder.repaintDebugType(
        typeName: typeName,
        rate: rate.round(),
        ancestorChain: snapshot.ancestorChains[typeName],
      );

      _issues.add(PerformanceIssue(
        stableId: 'repaint_debug_$typeName',
        severity: rate > paintFrequencyThreshold * 2
            ? IssueSeverity.critical
            : IssueSeverity.warning,
        category: IssueCategory.paint,
        confidence: IssueConfidence.confirmed,
        title: 'Excessive Repainting: $typeName (${rate.round()}/sec)',
        detail: '$typeName: $count repaints in '
            '${elapsedSec.toStringAsFixed(1)}s '
            '(${rate.round()}/sec).',
        fixHint: hint,
        fixEffort: effort,
        widgetName: typeName,
        ancestorChain: snapshot.ancestorChains[typeName],
        observationSource: ObservationSource.debugCallback,
        detectedAt: DateTime.now(),
        confidenceReason: 'Measured directly from debug callback paint counter',
      ));
    }
  }

  /// Debug callback path — aggregate paint count (no per-widget attribution).
  void _evaluateDebugData(DebugSnapshot snapshot) {
    final rate = snapshot.paintsPerSecond;
    if (rate < paintFrequencyThreshold) return;

    final elapsedSec =
        snapshot.elapsed.inMicroseconds / Duration.microsecondsPerSecond;

    final (hint, effort) = FixHintBuilder.excessiveRepaintDebug();

    _issues.add(PerformanceIssue(
      stableId: 'excessive_repaint_debug',
      severity: rate > paintFrequencyThreshold * 2
          ? IssueSeverity.critical
          : IssueSeverity.warning,
      category: IssueCategory.paint,
      confidence: IssueConfidence.likely,
      title: 'Excessive Repainting: ~${rate.round()} paints/sec',
      detail: '${snapshot.totalPaintCount} paint calls in '
          '${elapsedSec.toStringAsFixed(1)}s '
          '(~${rate.round()}/sec, aggregate debug callback count).',
      fixHint: hint,
      fixEffort: effort,
      observationSource: ObservationSource.debugCallback,
      detectedAt: DateTime.now(),
      confidenceReason: 'Aggregate debug callback count + structural scan',
    ));
  }

  @override
  void dispose() {
    _issues.clear();
    _highlights.clear();
    _pendingEnrichedDirtyTotal = 0;
    _stagedEnrichedDirtyTotal = null;
    _pendingDebugSnapshot = null;
  }
}
