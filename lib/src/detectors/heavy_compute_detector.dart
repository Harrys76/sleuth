import '../models/base_detector.dart';
import '../models/phase_event.dart';
import '../models/performance_issue.dart';
import '../utils/fix_hint_builder.dart';
import '../vm/timeline_parser.dart';

/// Detects heavy computation blocking the UI thread.
///
/// **VM-Only Detector** — monitors Dart isolate event gaps >8ms.
class HeavyComputeDetector extends BaseDetector {
  HeavyComputeDetector({this.lagThresholdMs = 8})
      : super(
          type: DetectorType.heavyCompute,
          lifecycle: DetectorLifecycle.vmOnly,
          name: 'Heavy Compute',
          description: 'Detects UI thread blocking (>8ms gaps)',
        );

  final int lagThresholdMs;
  final List<PerformanceIssue> _issues = [];
  bool _isEnabled = true;

  @override
  List<PerformanceIssue> get issues => List.unmodifiable(_issues);

  @override
  bool get isEnabled => _isEnabled;

  @override
  set isEnabled(bool value) => _isEnabled = value;

  /// Process timeline data looking for long-running Dart events.
  ///
  /// Prefers [PhaseEvent]s (which carry optional enrichment from timeline
  /// args like dirty widget names). Falls back to raw [buildScopeDurations]
  /// when no build phaseEvents exist (backward compat for direct construction).
  @override
  void processTimelineData(ParsedTimelineData data) {
    if (!_isEnabled) return;
    _issues.clear();

    final buildPhaseEvents =
        data.phaseEvents.where((e) => e.phase == TimelinePhase.build).toList();

    if (buildPhaseEvents.isNotEmpty) {
      for (final event in buildPhaseEvents) {
        final ms = event.durationUs / 1000;
        if (ms > lagThresholdMs) {
          _issues.add(_createIssue(ms, event));
        }
      }
    } else {
      // Fallback: raw durations only (no phaseEvents available)
      for (final durationUs in data.buildScopeDurations) {
        final ms = durationUs / 1000;
        if (ms > lagThresholdMs) {
          _issues.add(_createGenericIssue(ms));
        }
      }
    }
  }

  PerformanceIssue _createIssue(double ms, PhaseEvent event) {
    final dirtyWidgets = event.dirtyList;
    final enriched =
        event.hasEnrichment && dirtyWidgets != null && dirtyWidgets.isNotEmpty;

    final (hint, effort) = FixHintBuilder.heavyCompute(
      durationMs: ms,
      dirtyWidgets: enriched ? dirtyWidgets : null,
    );
    return PerformanceIssue(
      stableId: 'heavy_compute',
      severity: ms > lagThresholdMs * 2
          ? IssueSeverity.critical
          : IssueSeverity.warning,
      category: IssueCategory.build,
      confidence: IssueConfidence.confirmed,
      title: enriched
          ? 'Heavy Build: ${ms.toStringAsFixed(1)}ms '
              '(${_summarizeWidgets(dirtyWidgets)})'
          : 'Heavy Computation: ${ms.toStringAsFixed(1)}ms',
      detail: _buildDetail(ms, event),
      fixHint: hint,
      fixEffort: effort,
      observationSource: ObservationSource.vmTimeline,
      detectedAt: DateTime.now(),
    );
  }

  PerformanceIssue _createGenericIssue(double ms) {
    final (hint, effort) = FixHintBuilder.heavyCompute(durationMs: ms);
    return PerformanceIssue(
      stableId: 'heavy_compute',
      severity: ms > lagThresholdMs * 2
          ? IssueSeverity.critical
          : IssueSeverity.warning,
      category: IssueCategory.build,
      confidence: IssueConfidence.confirmed,
      title: 'Heavy Computation: ${ms.toStringAsFixed(1)}ms',
      detail: 'Long-running operation detected on UI thread '
          '(${ms.toStringAsFixed(1)}ms). This blocks frame rendering.',
      fixHint: hint,
      fixEffort: effort,
      observationSource: ObservationSource.vmTimeline,
      detectedAt: DateTime.now(),
    );
  }

  String _buildDetail(double ms, PhaseEvent event) {
    final buf = StringBuffer(
      'Long-running operation detected on UI thread '
      '(${ms.toStringAsFixed(1)}ms). This blocks frame rendering.',
    );
    if (event.dirtyCount != null) {
      buf.write('\nDirty widget count: ${event.dirtyCount}.');
    }
    final dirtyWidgets = event.dirtyList;
    if (dirtyWidgets != null && dirtyWidgets.isNotEmpty) {
      buf.write('\nDirty widgets: ${dirtyWidgets.join(', ')}.');
    }
    if (event.scopeContext != null) {
      buf.write('\nScope context: ${event.scopeContext}.');
    }
    return buf.toString();
  }

  static String _summarizeWidgets(List<String> names) {
    if (names.length <= 3) return names.join(', ');
    return '${names.take(3).join(', ')} +${names.length - 3} more';
  }

  @override
  void dispose() => _issues.clear();
}
