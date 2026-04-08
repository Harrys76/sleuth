import 'dart:collection';

import '../models/allocation_entry.dart';
import '../models/base_detector.dart';
import '../models/heap_sample.dart';
import '../models/performance_issue.dart';
import '../utils/fix_hint_builder.dart';
import '../vm/timeline_parser.dart';

/// Detects memory pressure using VM GC events and heap growth trends.
///
/// **VM-Only Detector** — monitors GC frequency, heap growth rate via
/// linear regression over a rolling window, and heap capacity usage.
class MemoryPressureDetector extends BaseDetector {
  MemoryPressureDetector({
    DateTime Function()? clock,
    this.warmupDurationMs = 3000,
    this.growthThresholdBytesPerSec = 512000,
    this.capacityThresholdPercent = 0.80,
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

  /// Heap growth rate (bytes/sec) above which heap_growing is flagged.
  final int growthThresholdBytesPerSec;

  /// Heap usage as fraction of capacity (0.0–1.0) above which
  /// heap_near_capacity is flagged.
  final double capacityThresholdPercent;

  final DateTime Function() _clock;
  final List<PerformanceIssue> _issues = [];
  bool _isEnabled = true;

  int _gcEventCount = 0;
  DateTime _trackingStart;
  DateTime? _firstHeapSampleTime;

  // -- Heap trend rolling window --

  static const int _windowCapacity = 60; // 30 seconds at 500ms
  static const int _sustainedGrowthDurationSec = 10;
  static const int _nativeGrowthThresholdBytesPerSec = 1048576; // 1 MB/sec

  final Queue<HeapSample> _heapSamples = Queue<HeapSample>();
  DateTime? _sustainedGrowthStart;
  DateTime? _sustainedNativeGrowthStart;

  /// Cached allocation enrichment data. Preserved across _evaluate() cycles
  /// so the top-allocator data survives issue rebuilds.
  List<AllocationEntry>? _lastTopAllocators;

  @override
  List<PerformanceIssue> get issues => List.unmodifiable(_issues);

  @override
  bool get isEnabled => _isEnabled;

  @override
  set isEnabled(bool value) => _isEnabled = value;

  /// Unmodifiable view of the rolling heap sample window for session export.
  List<HeapSample> get heapSamples => List.unmodifiable(_heapSamples);

  @override
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
    if (_heapSamples.length > _windowCapacity) _heapSamples.removeFirst();

    _evaluate();
  }

  /// Enrich the existing heap_growing issue with top allocator data.
  /// Called by the controller after getAllocationProfile returns (phase 2).
  void enrichHeapGrowingIssue(List<AllocationEntry> allocators) {
    _lastTopAllocators = allocators;

    // Apply to current issue immediately (if it exists)
    final idx = _issues.indexWhere((i) => i.stableId == 'heap_growing');
    if (idx == -1) return;
    _issues[idx] = _issues[idx].copyWith(topAllocators: allocators);
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
    _evaluateNativeGrowth();
  }

  void _evaluateGcPressure(Duration elapsed) {
    final gcPerMinute = (_gcEventCount / elapsed.inSeconds) * 60;
    if (gcPerMinute > 30) {
      final (hint, effort) = FixHintBuilder.gcPressure();
      _issues.add(PerformanceIssue(
        stableId: 'gc_pressure',
        severity: IssueSeverity.warning,
        category: IssueCategory.memory,
        confidence: IssueConfidence.likely,
        title: 'High GC Pressure: ${gcPerMinute.toStringAsFixed(0)} GC/min',
        detail: 'Garbage collection is running frequently '
            '(${gcPerMinute.toStringAsFixed(0)}/min), indicating high '
            'object creation/disposal rate.',
        fixHint: hint,
        fixEffort: effort,
        observationSource: ObservationSource.vmTimeline,
        detectedAt: _clock(),
        confidenceReason: 'VM GC frequency elevated + object churn rate',
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

    if (slope > growthThresholdBytesPerSec) {
      _sustainedGrowthStart ??= _heapSamples.last.timestamp;
      final sustained =
          _heapSamples.last.timestamp.difference(_sustainedGrowthStart!);
      if (sustained.inSeconds >= _sustainedGrowthDurationSec) {
        final slopeKbSec = slope / 1024;
        final (hint, effort) = FixHintBuilder.heapGrowing();
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
          fixHint: hint,
          fixEffort: effort,
          observationSource: ObservationSource.vmTimeline,
          detectedAt: _clock(),
          topAllocators: _lastTopAllocators,
          confidenceReason: 'Heap trend analysis + sustained growth regression',
        ));
      }
    } else {
      _sustainedGrowthStart = null;
      _lastTopAllocators = null;
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
    if (ratio > capacityThresholdPercent) {
      final pct = (ratio * 100).toStringAsFixed(0);
      final (hint, effort) = FixHintBuilder.heapNearCapacity();
      _issues.add(PerformanceIssue(
        stableId: 'heap_near_capacity',
        severity: IssueSeverity.critical,
        category: IssueCategory.memory,
        confidence: IssueConfidence.confirmed,
        title: 'Heap Near Capacity: $pct% used',
        detail: 'App is using ${_formatBytes(latest.heapUsage)} of '
            '${_formatBytes(latest.heapCapacity)} available heap ($pct%). '
            'GC may become frequent and cause jank.',
        fixHint: hint,
        fixEffort: effort,
        observationSource: ObservationSource.vmTimeline,
        detectedAt: _clock(),
        confidenceReason: 'Measured directly from VM heap capacity sampling',
      ));
    }
  }

  void _evaluateNativeGrowth() {
    final nativeSamples =
        _heapSamples.where((s) => s.nativeBytes != null).toList();
    if (nativeSamples.length < 4) return;

    // Suppress during warmup (same guard as heap trend)
    if (_firstHeapSampleTime != null) {
      final sinceFirst = _clock().difference(_firstHeapSampleTime!);
      if (sinceFirst.inMilliseconds < warmupDurationMs) return;
    }

    final slope = _computeNativeSlopeBytesPerSec(nativeSamples);

    if (slope > _nativeGrowthThresholdBytesPerSec) {
      _sustainedNativeGrowthStart ??= nativeSamples.last.timestamp;
      final sustained =
          nativeSamples.last.timestamp.difference(_sustainedNativeGrowthStart!);
      if (sustained.inSeconds >= _sustainedGrowthDurationSec) {
        final slopeMbSec = slope / (1024 * 1024);
        final (hint, effort) = FixHintBuilder.nativeMemoryGrowth();
        _issues.add(PerformanceIssue(
          stableId: 'native_memory_growing',
          severity: IssueSeverity.warning,
          category: IssueCategory.memory,
          confidence: IssueConfidence.likely,
          title: 'Native Memory Growing: '
              '+${slopeMbSec.toStringAsFixed(1)} MB/s '
              'for ${sustained.inSeconds}s',
          detail: 'Process memory outside the Dart heap is growing at '
              '${slopeMbSec.toStringAsFixed(2)} MB/sec for '
              '${sustained.inSeconds} seconds. This may indicate undisposed '
              'GPU textures, decoded images at full resolution, or platform '
              'channel buffer accumulation. '
              'Current native estimate: '
              '${_formatBytes(nativeSamples.last.nativeBytes!)}.',
          fixHint: hint,
          fixEffort: effort,
          observationSource: ObservationSource.vmTimeline,
          detectedAt: _clock(),
          confidenceReason:
              'Native memory trend analysis + sustained growth regression',
        ));
      }
    } else {
      _sustainedNativeGrowthStart = null;
    }
  }

  /// Compute native memory growth rate in bytes/sec via linear regression.
  double _computeNativeSlopeBytesPerSec(List<HeapSample> samples) {
    final n = samples.length;
    if (n < 2) return 0;

    final firstTs = samples.first.timestamp;
    double sumX = 0, sumY = 0, sumXY = 0, sumX2 = 0;

    for (final sample in samples) {
      final x = sample.timestamp.difference(firstTs).inMilliseconds / 1000.0;
      final y = sample.nativeBytes!.toDouble();
      sumX += x;
      sumY += y;
      sumXY += x * y;
      sumX2 += x * x;
    }

    final denominator = n * sumX2 - sumX * sumX;
    if (denominator.abs() < 1e-10) return 0;

    return (n * sumXY - sumX * sumY) / denominator;
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
    _sustainedNativeGrowthStart = null;
    _firstHeapSampleTime = null;
    _lastTopAllocators = null;
    _trackingStart = _clock();
    _issues.clear();
  }

  @override
  void dispose() {
    _gcEventCount = 0;
    _trackingStart = _clock();
    _heapSamples.clear();
    _sustainedGrowthStart = null;
    _sustainedNativeGrowthStart = null;
    _firstHeapSampleTime = null;
    _lastTopAllocators = null;
    _issues.clear();
  }
}
