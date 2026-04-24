import '../models/base_detector.dart';
import '../validation/detector_metadata.dart';
import '../validation/evidence_tier.dart';
import '../models/performance_issue.dart';
import '../utils/fix_hint_builder.dart';
import '../vm/timeline_parser.dart';

/// Detects excessive platform channel calls.
///
/// **VM-Only Detector** — monitors platform channel timeline events for >20 calls/sec.
class PlatformChannelDetector extends BaseDetector
    with DetectorMetadataProvider {
  PlatformChannelDetector({
    this.callsPerSecThreshold = 20,
    this.durationThresholdUs = 8000,
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

  /// Cumulative duration threshold per window (microseconds). Default 8ms.
  final int durationThresholdUs;
  final DateTime Function() _clock;
  final List<PerformanceIssue> _issues = [];
  bool _isEnabled = true;

  int _recentCallCount = 0;
  int _cumulativeDurationUs = 0;
  final Map<String, int> _methodCounts = {};
  late DateTime _windowStart;
  int _cooldownCyclesRemaining = 0;
  PerformanceIssue? _lastEmittedIssue;

  @override
  List<PerformanceIssue> get issues => List.unmodifiable(_issues);

  @override
  bool get isEnabled => _isEnabled;

  @override
  set isEnabled(bool value) => _isEnabled = value;

  @override
  void processTimelineData(ParsedTimelineData data) {
    if (!_isEnabled) return;

    final now = _clock();
    final windowDuration = now.difference(_windowStart);

    // Reset window every second
    if (windowDuration.inMilliseconds >= 1000) {
      _evaluateWindow();
      _recentCallCount = 0;
      _cumulativeDurationUs = 0;
      _methodCounts.clear();
      _windowStart = now;
    }

    _recentCallCount += data.platformChannelEvents.length;

    for (final event in data.platformChannelEvents) {
      final json = event.json;
      if (json != null) {
        _cumulativeDurationUs += (json['dur'] as int?) ?? 0;
        final method =
            (json['args'] as Map<String, dynamic>?)?['method'] as String? ??
                json['name'] as String? ??
                'unknown';
        _methodCounts[method] = (_methodCounts[method] ?? 0) + 1;
      }
    }
  }

  void _evaluateWindow() {
    final frequencyExceeded = _recentCallCount > callsPerSecThreshold;
    final durationExceeded = _cumulativeDurationUs > durationThresholdUs;

    if (frequencyExceeded || durationExceeded) {
      _cooldownCyclesRemaining = 3;
      final durationMs = _cumulativeDurationUs / 1000;
      final topMethods = _methodCounts.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      final methodSummary =
          topMethods.take(3).map((e) => '${e.key}: ${e.value}×').join(', ');

      final topMethod = topMethods.isNotEmpty ? topMethods.first.key : null;
      final (hint, effort) =
          FixHintBuilder.platformChannelTraffic(topMethod: topMethod);
      _lastEmittedIssue = PerformanceIssue(
        stableId: 'platform_channel_traffic',
        severity: (frequencyExceeded &&
                    _recentCallCount > callsPerSecThreshold * 2) ||
                (durationExceeded &&
                    _cumulativeDurationUs > durationThresholdUs * 2)
            ? IssueSeverity.critical
            : IssueSeverity.warning,
        category: IssueCategory.channel,
        confidence: IssueConfidence.confirmed,
        title: durationExceeded && !frequencyExceeded
            ? 'Slow Platform Channels: ${durationMs.toStringAsFixed(1)}ms total'
            : 'High Platform Channel Traffic: $_recentCallCount calls/sec',
        detail:
            '$_recentCallCount calls (${durationMs.toStringAsFixed(1)}ms total) '
            'in the last second.'
            '${methodSummary.isNotEmpty ? '\nTop methods: $methodSummary' : ''}'
            '\nThresholds: $callsPerSecThreshold calls/sec, '
            '${durationThresholdUs ~/ 1000}ms cumulative.',
        fixHint: hint,
        fixEffort: effort,
        observationSource: ObservationSource.vmTimeline,
        detectedAt: _clock(),
        confidenceReason:
            'Measured directly from VM timeline platform channel events',
      );
      _issues
        ..clear()
        ..add(_lastEmittedIssue!);
    } else if (_cooldownCyclesRemaining > 0) {
      _cooldownCyclesRemaining--;
      _issues.clear();
      if (_lastEmittedIssue != null) _issues.add(_lastEmittedIssue!);
    } else {
      _issues.clear();
      _lastEmittedIssue = null;
    }
  }

  @override
  void dispose() {
    _issues.clear();
    _methodCounts.clear();
    _cooldownCyclesRemaining = 0;
    _lastEmittedIssue = null;
  }

  @override
  DetectorMetadata get validationMetadata => const DetectorMetadata(
        tier: EvidenceTier.reproducerOnly,
        rationale: 'VM-only detector. Both emission axes pinned by '
            'hermetic reproducer feeding events through '
            '`TimelineParser.parse()` into the detector: (a) >20/sec '
            'frequency (strict, 2× critical at 41 calls; 40 calls held '
            'at warning to pin critical-escalation inequality), and '
            '(b) >8000µs cumulative per 1s window (strict, tested at '
            '7998/8000/8001µs via sync `\'X\'` events with 3 calls — '
            'isolates duration axis from frequency axis). Two '
            'parser-accepted phase+name shapes covered: lowercase async '
            '`\'b\'` with `Platform Channel send ` prefix (real '
            '`debugProfilePlatformChannels` output via TimelineTask) and '
            'sync `\'X\'` with `MethodChannel` name. Parser allowlist '
            'accepts 9 shapes total (6 sync names + 3 async-prefix '
            'casings); the 7 untested shapes (`PlatformChannel`, '
            '`platformchannel`, `Platform_Channel`, `platform_channel`, '
            '`methodchannel`, `Platform Channel Send ` prefix, `platform '
            'channel send ` prefix) are implicitly uncovered at this '
            'tier. Uppercase sync `\'B\'` '
            'async-shaped events are silently dropped by the parser '
            'and asserted non-emitting — the canonical format-boundary '
            'trap for channel observers. Fixtures hand-built against '
            'parser allowlist; real-device capture comparison is '
            'runtime-verified-tier work.',
        reproducerPath: 'test/validation/platform_channel_reproducer_test.dart',
        coveredStableIds: {'platform_channel_traffic'},
      );
}
