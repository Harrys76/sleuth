import '../models/base_detector.dart';
import '../models/performance_issue.dart';
import '../vm/timeline_parser.dart';

/// Detects memory pressure using VM GC events and heap growth trends.
///
/// **VM-Only Detector** — monitors GC frequency and heap growth patterns.
/// This is not leak detection — it surfaces pressure indicators.
class MemoryPressureDetector extends BaseDetector {
  MemoryPressureDetector({
    this.heapGrowthThresholdPercent = 10,
    DateTime Function()? clock,
  })  : _clock = clock ?? DateTime.now,
        _trackingStart = (clock ?? DateTime.now)(),
        super(
          type: DetectorType.memoryPressure,
          lifecycle: DetectorLifecycle.vmOnly,
          name: 'Memory Pressure',
          description: 'Detects memory pressure via GC frequency + heap growth',
        );

  final int heapGrowthThresholdPercent;
  final DateTime Function() _clock;
  final List<PerformanceIssue> _issues = [];
  bool _isEnabled = true;

  int _gcEventCount = 0;
  int _initialHeapEstimate = 0;
  int _currentHeapEstimate = 0;
  DateTime _trackingStart;

  @override
  List<PerformanceIssue> get issues => List.unmodifiable(_issues);

  @override
  bool get isEnabled => _isEnabled;

  @override
  set isEnabled(bool value) => _isEnabled = value;

  void processTimelineData(ParsedTimelineData data) {
    if (!_isEnabled) return;

    _gcEventCount += data.gcEvents.length;

    // Only evaluate when we have real GC events
    if (data.gcEvents.isEmpty) return;

    final elapsed = _clock().difference(_trackingStart);
    if (elapsed.inSeconds > 0) {
      _evaluateMemoryPressure(elapsed);
    }
  }

  /// Update heap statistics from VM service.
  void updateHeapStats({required int usedBytes, required int capacityBytes}) {
    if (_initialHeapEstimate == 0) {
      _initialHeapEstimate = usedBytes;
    }
    _currentHeapEstimate = usedBytes;
  }

  void _evaluateMemoryPressure(Duration elapsed) {
    _issues.clear();

    // Check GC frequency — high GC rate suggests memory pressure
    final gcPerMinute = (_gcEventCount / elapsed.inSeconds) * 60;
    if (gcPerMinute > 30) {
      _issues.add(PerformanceIssue(
        stableId: 'gc_pressure',
        severity: IssueSeverity.warning,
        category: IssueCategory.memory,
        confidence: IssueConfidence.likely,
        title: 'High GC Pressure: ${gcPerMinute.toStringAsFixed(0)} GC/min',
        detail: 'Garbage collection is running frequently '
            '(${gcPerMinute.toStringAsFixed(0)}/min), indicating high '
            'object creation/disposal rate.',
        fixHint: 'Reduce object allocations in hot paths. '
            'Reuse objects, use const constructors, '
            'and avoid creating objects in build().',
        observationSource: ObservationSource.vmTimeline,
        detectedAt: DateTime.now(),
      ));
    }

    // Check heap growth (only when real heap stats are wired)
    if (_initialHeapEstimate > 0 && _currentHeapEstimate > 0) {
      final growthPercent = ((_currentHeapEstimate - _initialHeapEstimate) /
              _initialHeapEstimate) *
          100;
      if (growthPercent > heapGrowthThresholdPercent) {
        _issues.add(PerformanceIssue(
          stableId: 'heap_growth',
          severity: growthPercent > 30
              ? IssueSeverity.critical
              : IssueSeverity.warning,
          category: IssueCategory.memory,
          confidence: IssueConfidence.likely,
          title: 'Heap Growing: +${growthPercent.toStringAsFixed(0)}%',
          detail: 'Heap has grown from ${_formatBytes(_initialHeapEstimate)} '
              'to ${_formatBytes(_currentHeapEstimate)} '
              '(+${growthPercent.toStringAsFixed(1)}%).',
          fixHint: 'Check for undisposed controllers, StreamSubscriptions, '
              'or AnimationControllers. '
              'Verify all dispose() methods are called.',
          observationSource: ObservationSource.vmTimeline,
          detectedAt: DateTime.now(),
        ));
      }
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
  }

  void reset() {
    _gcEventCount = 0;
    _initialHeapEstimate = 0;
    _currentHeapEstimate = 0;
    _trackingStart = _clock();
    _issues.clear();
  }

  @override
  void dispose() {
    _issues.clear();
  }
}
