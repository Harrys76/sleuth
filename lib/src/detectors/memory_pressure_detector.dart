import '../models/base_detector.dart';
import '../models/heap_sample.dart';
import '../models/performance_issue.dart';
import '../vm/timeline_parser.dart';

/// Detects memory pressure using VM GC events and heap growth trends.
///
/// **VM-Only Detector** — monitors GC frequency, heap growth rate via
/// linear regression over a rolling window, and heap capacity usage.
class MemoryPressureDetector extends BaseDetector {
  MemoryPressureDetector({
    DateTime Function()? clock,
    this.warmupDurationMs = 5000,
  })  : _clock = clock ?? DateTime.now,
        _trackingStart = (clock ?? DateTime.now)(),
        super(
          type: DetectorType.memoryPressure,
          lifecycle: DetectorLifecycle.vmOnly,
          name: 'Memory Pressure',
          description: 'Detects memory pressure via GC frequency + heap trends',
        );

  /// Duration in milliseconds to suppress heap trend alerts after first sample.
  /// Prevents false positives from normal startup allocation.
  final int warmupDurationMs;

  final DateTime Function() _clock;
  final List<PerformanceIssue> _issues = [];
  bool _isEnabled = true;

  int _gcEventCount = 0;
  DateTime _trackingStart;
  DateTime? _firstHeapSampleTime;

  // -- Heap trend rolling window --

  static const int _windowCapacity = 60; // 30 seconds at 500ms
  static const int _growthThresholdBytesPerSec = 512000; // ~500 KB/sec
  static const int _sustainedGrowthDurationSec = 10;
  static const double _capacityThresholdPercent = 0.80;

  final List<HeapSample> _heapSamples = [];
  DateTime? _sustainedGrowthStart;

  @override
  List<PerformanceIssue> get issues => List.unmodifiable(_issues);

  @override
  bool get isEnabled => _isEnabled;

  @override
  set isEnabled(bool value) => _isEnabled = value;

  /// Unmodifiable view of the rolling heap sample window for session export.
  List<HeapSample> get heapSamples => List.unmodifiable(_heapSamples);

  void processTimelineData(ParsedTimelineData data) {
    if (!_isEnabled) return;

    _gcEventCount += data.gcEvents.length;

    // Only evaluate when we have real GC events
    if (data.gcEvents.isEmpty) return;

    _evaluate();
  }

  /// Process a heap memory sample from the VM service.
  void processHeapSample(HeapSample sample) {
    if (!_isEnabled) return;

    _firstHeapSampleTime ??= _clock();
    _heapSamples.add(sample);
    if (_heapSamples.length > _windowCapacity) _heapSamples.removeAt(0);

    _evaluate();
  }

  /// Clear and rebuild all issues from current state.
  void _evaluate() {
    _issues.clear();

    // GC pressure needs elapsed > 0 to compute per-minute rate.
    // Heap evaluations work immediately — no elapsed guard needed.
    final elapsed = _clock().difference(_trackingStart);
    if (elapsed.inSeconds > 0 && _gcEventCount > 0) {
      _evaluateGcPressure(elapsed);
    }

    _evaluateHeapTrend();
    _evaluateHeapCapacity();
  }

  void _evaluateGcPressure(Duration elapsed) {
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
        detectedAt: _clock(),
      ));
    }
  }

  void _evaluateHeapTrend() {
    if (_heapSamples.length < 4) return;

    // Suppress heap trend alerts during warmup to avoid false positives
    // from normal startup allocation (class loading, widget tree, images).
    if (_firstHeapSampleTime != null) {
      final sinceFirst = _clock().difference(_firstHeapSampleTime!);
      if (sinceFirst.inMilliseconds < warmupDurationMs) return;
    }

    final slope = _computeSlopeBytesPerSec();

    if (slope > _growthThresholdBytesPerSec) {
      _sustainedGrowthStart ??= _heapSamples.last.timestamp;
      final sustained =
          _heapSamples.last.timestamp.difference(_sustainedGrowthStart!);
      if (sustained.inSeconds >= _sustainedGrowthDurationSec) {
        final slopeKbSec = slope / 1024;
        _issues.add(PerformanceIssue(
          stableId: 'heap_growing',
          severity: IssueSeverity.warning,
          category: IssueCategory.memory,
          confidence: IssueConfidence.likely,
          title: 'Heap Growing: +${slopeKbSec.toStringAsFixed(0)} KB/s '
              'for ${sustained.inSeconds}s',
          detail:
              'Heap has been growing at ${slopeKbSec.toStringAsFixed(1)} KB/sec '
              'for ${sustained.inSeconds} seconds. '
              'Current: ${_formatBytes(_heapSamples.last.heapUsage)}, '
              'Window: ${_heapSamples.length} samples over '
              '${_heapSamples.last.timestamp.difference(_heapSamples.first.timestamp).inSeconds}s.',
          fixHint:
              'Memory is growing steadily. Check for undisposed controllers, '
              'uncancelled streams, growing caches, or images decoded at full '
              'resolution. Use DevTools Memory view for per-object investigation.',
          observationSource: ObservationSource.vmTimeline,
          detectedAt: _clock(),
        ));
      }
    } else {
      _sustainedGrowthStart = null;
    }
  }

  /// Compute heap growth rate in bytes/sec via least-squares linear regression.
  double _computeSlopeBytesPerSec() {
    final n = _heapSamples.length;
    if (n < 2) return 0;

    final firstTs = _heapSamples.first.timestamp;
    double sumX = 0, sumY = 0, sumXY = 0, sumX2 = 0;

    for (final sample in _heapSamples) {
      final x = sample.timestamp.difference(firstTs).inMilliseconds / 1000.0;
      final y = sample.heapUsage.toDouble();
      sumX += x;
      sumY += y;
      sumXY += x * y;
      sumX2 += x * x;
    }

    final denominator = n * sumX2 - sumX * sumX;
    if (denominator.abs() < 1e-10) return 0;

    return (n * sumXY - sumX * sumY) / denominator;
  }

  void _evaluateHeapCapacity() {
    if (_heapSamples.isEmpty) return;
    final latest = _heapSamples.last;
    if (latest.heapCapacity <= 0) return;

    final ratio = latest.heapUsage / latest.heapCapacity;
    if (ratio > _capacityThresholdPercent) {
      final pct = (ratio * 100).toStringAsFixed(0);
      _issues.add(PerformanceIssue(
        stableId: 'heap_near_capacity',
        severity: IssueSeverity.critical,
        category: IssueCategory.memory,
        confidence: IssueConfidence.confirmed,
        title: 'Heap Near Capacity: $pct% used',
        detail: 'App is using ${_formatBytes(latest.heapUsage)} of '
            '${_formatBytes(latest.heapCapacity)} available heap ($pct%). '
            'GC may become frequent and cause jank.',
        fixHint: 'Consider releasing image caches, disposing unused '
            'controllers, or paginating large data sets. '
            'Use DevTools Memory view for per-object investigation.',
        observationSource: ObservationSource.vmTimeline,
        detectedAt: _clock(),
      ));
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
  }

  void reset() {
    _gcEventCount = 0;
    _heapSamples.clear();
    _sustainedGrowthStart = null;
    _firstHeapSampleTime = null;
    _trackingStart = _clock();
    _issues.clear();
  }

  @override
  void dispose() {
    _heapSamples.clear();
    _sustainedGrowthStart = null;
    _firstHeapSampleTime = null;
    _issues.clear();
  }
}
