import '../models/base_detector.dart';
import '../models/performance_issue.dart';
import '../vm/timeline_parser.dart';

/// Detects excessive platform channel calls.
///
/// **VM-Only Detector** — monitors Embedder events for >20 calls/sec.
class PlatformChannelDetector extends BaseDetector {
  PlatformChannelDetector({
    this.callsPerSecThreshold = 20,
    DateTime Function()? clock,
  })  : _clock = clock ?? DateTime.now,
        super(
          type: DetectorType.platformChannel,
          lifecycle: DetectorLifecycle.vmOnly,
          name: 'Platform Channel',
          description: 'Detects excessive platform channel calls (>20/sec)',
        ) {
    _windowStart = _clock();
  }

  final int callsPerSecThreshold;
  final DateTime Function() _clock;
  final List<PerformanceIssue> _issues = [];
  bool _isEnabled = true;

  int _recentCallCount = 0;
  late DateTime _windowStart;

  @override
  List<PerformanceIssue> get issues => List.unmodifiable(_issues);

  @override
  bool get isEnabled => _isEnabled;

  @override
  set isEnabled(bool value) => _isEnabled = value;

  void processTimelineData(ParsedTimelineData data) {
    if (!_isEnabled) return;

    final now = _clock();
    final windowDuration = now.difference(_windowStart);

    // Reset window every second
    if (windowDuration.inMilliseconds >= 1000) {
      _evaluateWindow();
      _recentCallCount = 0;
      _windowStart = now;
    }

    _recentCallCount += data.platformChannelEvents.length;
  }

  void _evaluateWindow() {
    _issues.clear();

    if (_recentCallCount > callsPerSecThreshold) {
      _issues.add(PerformanceIssue(
        stableId: 'platform_channel_traffic',
        severity: _recentCallCount > callsPerSecThreshold * 2
            ? IssueSeverity.critical
            : IssueSeverity.warning,
        category: IssueCategory.channel,
        confidence: IssueConfidence.confirmed,
        title: 'High Platform Channel Traffic: $_recentCallCount calls/sec',
        detail: '$_recentCallCount method channel calls in the last second. '
            'Threshold: $callsPerSecThreshold/sec.',
        fixHint: 'Batch platform channel calls where possible. '
            'Consider using Pigeon for type-safe communication '
            'or cache results to reduce call frequency.',
        observationSource: ObservationSource.vmTimeline,
        detectedAt: _clock(),
      ));
    }
  }

  @override
  void dispose() => _issues.clear();
}
