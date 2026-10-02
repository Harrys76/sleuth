import 'dart:collection';

import '../models/allocation_entry.dart';
import '../models/base_detector.dart';
import '../validation/detector_metadata.dart';
import '../validation/evidence_tier.dart';
import '../models/heap_sample.dart';
import '../models/performance_issue.dart';
import '../utils/fix_hint_builder.dart';

/// Detects memory pressure using VM GC events and heap growth trends.
///
/// **VM-Only Detector** — monitors GC frequency, heap growth rate via
/// linear regression over a rolling window, and process memory (RSS)
/// against an optional app-supplied budget.
///
/// **Capture-mode timing.** Calling [reset] (auto-invoked by
/// `Sleuth.markScenarioBegin` via `SleuthController.resetCaptureState`)
/// clears `_heapSamples`, `_firstHeapSampleTime`, and
/// `_sustainedGrowthStart`, so the heap-trend evaluation window starts
/// fresh on every scenario. Effective first-fire latency post-reset:
/// ~3 s warmup + ~2 s sample-accumulation (4-sample minimum) + slope-
/// cross + 10 s sustained = ~14-15 s of scenario allocation before the
/// first `heap_growing` issue can fire. Capture procedures should
/// allocate ≥30 s for comfortable margin.
class MemoryPressureDetector extends BaseDetector
    with DetectorMetadataProvider {
  MemoryPressureDetector({
    DateTime Function()? clock,
    this.warmupDurationMs = 3000,
    this.growthThresholdBytesPerSec = 512000,
    this.capacityThresholdPercent = 0.80,
    this.memoryBudgetBytes,
    this.gcRateThresholdPerMin = _defaultGcRateThresholdPerMin,
  }) : assert(
         memoryBudgetBytes == null || memoryBudgetBytes > 0,
         'memoryBudgetBytes must be > 0 when set.',
       ),
       _clock = clock ?? DateTime.now,
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

  /// Fraction of [memoryBudgetBytes] (0.0–1.0) at or above which process
  /// RSS counts toward `heap_near_capacity`.
  final double capacityThresholdPercent;

  /// Process memory budget in bytes for `heap_near_capacity`. Null (the
  /// default) disables the issue: without a known budget there is no
  /// ceiling to be near. Dart's own `heapCapacity` grows with usage, so
  /// the usage/capacity ratio sits at 0.85–0.97 in steady state and says
  /// nothing about how close the process is to being killed.
  final int? memoryBudgetBytes;

  /// GC events per minute (extrapolated from a 10s sliding window) above
  /// which `gc_pressure` fires. Dart's `EventStreams.kGC` emits one event
  /// per GC cycle, new-space scavenges included. An idle app with Sleuth
  /// attached produces 1 to 2 scavenges per second from the VM-service
  /// poll traffic alone (66 to 138 per minute measured on an iPhone 12),
  /// while allocation churn runs at thousands per minute. The default of
  /// 180 (3 per second sustained over 10 s) sits above the idle band.
  /// Each emission stamps the scavenge / old-gen split of the window.
  final int gcRateThresholdPerMin;

  static const int _defaultGcRateThresholdPerMin = 180;

  final DateTime Function() _clock;
  final List<PerformanceIssue> _issues = [];
  bool _isEnabled = true;

  DateTime? _firstHeapSampleTime;

  // -- GC rate sliding window --
  //
  // Tracks GC batches received within the last [_gcWindowDuration]. Without
  // a sliding window, a long-running app dilutes any recent GC burst: a user
  // who explores other demos for 60s and then hits a churn-heavy demo would
  // see `(N events / 60s+ elapsed) * 60` fall below the per-minute threshold
  // even though N events in the last ~5s clearly indicates pressure. The
  // window gives us an "events per 10 seconds" rate that responds to real
  // bursts.
  static const Duration _gcWindowDuration = Duration(seconds: 10);
  final Queue<({DateTime ts, bool oldGen})> _gcWindow = Queue();

  /// `gcType` values reported for old-generation collections. Any other
  /// value, including null, counts as a scavenge so the two counts always
  /// sum to the window total.
  static const Set<String> _oldGenGcTypes = {
    'MarkSweep',
    'MarkCompact',
    'StartConcurrentMark',
  };

  // -- Heap trend rolling window --

  static const int _windowCapacity = 60; // 30 seconds at 500ms
  static const int _sustainedGrowthDurationSec = 10;
  static const int _nativeGrowthThresholdBytesPerSec = 1048576; // 1 MB/sec

  final Queue<HeapSample> _heapSamples = Queue<HeapSample>();
  DateTime? _sustainedGrowthStart;
  DateTime? _sustainedNativeGrowthStart;
  // First in-window event timestamp at the moment gc_pressure crossed
  // the >10/window threshold. Pinned for the full overage episode so
  // re-emissions across consecutive evaluations share dedup identity
  // and CaptureHelper collapses them to one trace record per episode.
  // Cleared in the no-emit branch (`windowEvents <= 10`) so a new
  // overage after a transient drop produces a distinct identity.
  DateTime? _gcOverageStart;

  // -- heap_near_capacity (RSS against memoryBudgetBytes) --
  //
  // [_evaluateHeapCapacity] reads the last [_budgetWindowSize] heap
  // samples and needs [_budgetRequiredHits] of them with
  // `rssBytes >= capacityThresholdPercent × memoryBudgetBytes`. A "K of
  // last N" window tolerates one sample dipping under the line as the
  // GC reclaims. Samples without RSS (web, unusual embeddings) never
  // count. The window is derived from `_heapSamples`, so an evaluation
  // triggered by [recordGcCycle] reads the same samples and cannot
  // double-count.
  static const int _budgetWindowSize = 5;
  static const int _budgetRequiredHits = 4;

  // Timestamp of the sample that completed the first over-budget window
  // of the current episode. Stable dedup identity for every emission
  // while RSS stays over the budget line; cleared when the window drops
  // below the required hits (or the budget is unset) so the next episode
  // carries a fresh identity.
  DateTime? _budgetCrossingStart;

  /// Cached allocation enrichment data. Preserved across _evaluate() cycles
  /// so the top-allocator data survives issue rebuilds.
  List<AllocationEntry>? _lastTopAllocators;

  // Last wall-clock micros at which an `heap_growing` issue was emitted
  // by [_evaluateHeapTrend]. Read by [isHeapGrowingActive] for cross-
  // detector gating (StreamResourceDetector co-fire). Stamped on every
  // emission so a sustained-growth window of N consecutive ticks keeps
  // the recency clock fresh; cleared on slope-drop reset and on
  // [vmConnected]=false / [reset] / [dispose] so a stale latch from a
  // prior session cannot mis-trigger downstream gating.
  int? _lastHeapGrowingEmittedAtMicros;
  static const int _defaultHeapGrowingRecencyMicros = 30000000;

  /// Whether `heap_growing` was emitted within the recency window.
  ///
  /// Returns false when no `heap_growing` has fired this session, or
  /// when the most recent emission is older than [windowMicros]
  /// (default 30 s). Distinct from the boolean "is the issue still in
  /// `_issues`?" — IssueRanker rotation and other persistence rules
  /// are not load-bearing for the recency claim. Used by
  /// `StreamResourceDetector` to gate its co-fire emission.
  bool isHeapGrowingActive([int? windowMicros]) {
    final last = _lastHeapGrowingEmittedAtMicros;
    if (last == null) return false;
    final window = windowMicros ?? _defaultHeapGrowingRecencyMicros;
    final now = _clock().microsecondsSinceEpoch;
    return now - last <= window;
  }

  @override
  List<PerformanceIssue> get issues => List.unmodifiable(_issues);

  @override
  bool get isEnabled => _isEnabled;

  @override
  set isEnabled(bool value) => _isEnabled = value;

  /// Clear all session state on VM disconnect.
  ///
  /// Without this cleanup, in-flight timers or reconnection delays let
  /// pre-disconnect samples leak into a post-reconnect window:
  /// - GC sliding window inflates rate, triggering `gc_pressure` on a
  ///   freshly reconnected app that has not actually GC'd yet.
  /// - Heap samples preserve a slope from the prior session, causing
  ///   `heap_growing` to fire on the first post-reconnect sample.
  /// - `_sustainedGrowthStart` survives, so a heap_growing issue emitted
  ///   post-reconnect carries a `dedupIdentityMicros` derived from a
  ///   prior-session timestamp — corrupting the producer-side dedup
  ///   composite key and the runtimeVerified audit trail.
  ///
  /// Clearing every identity-bearing field on disconnect guarantees the
  /// next reconnect starts fresh: warmup re-runs, dedup identities are
  /// freshly derived, and the budget window does not pre-charge with
  /// stale over-budget samples.
  ///
  /// `_evaluate()` runs after the clear so any stale issue still in
  /// `_issues` is removed from the UI immediately, rather than lingering
  /// until the next GC event or heap sample arrives (which may be never
  /// on a failed-reconnect path).
  @override
  set vmConnected(bool value) {
    if (!value) {
      _gcWindow.clear();
      _heapSamples.clear();
      _budgetCrossingStart = null;
      _sustainedGrowthStart = null;
      _sustainedNativeGrowthStart = null;
      _gcOverageStart = null;
      _firstHeapSampleTime = null;
      _lastHeapGrowingEmittedAtMicros = null;
      _evaluate();
    }
    super.vmConnected = value;
  }

  /// Unmodifiable view of the rolling heap sample window for session export.
  List<HeapSample> get heapSamples => List.unmodifiable(_heapSamples);

  // processTimelineData intentionally NOT overridden.
  //
  // Prior to Phase 1, this method read `data.gcEvents.length` as the GC count
  // and pushed it into the sliding window. That count came from TimelineParser,
  // which aggregates the VM's `'X'` complete GC events AND the `'B'/'E'`
  // begin/end pair events — a single GC cycle emits 5–15 sub-phase trace
  // events, so `data.gcEvents.length` was inflated roughly 5–15× over actual
  // cycles and fired "high GC pressure" on idle screens.
  //
  // The authoritative signal is `EventStreams.kGC` (via VmService.onGCEvent),
  // which emits exactly one event per completed GC cycle. The controller now
  // calls [recordGcCycle] from its `_onGcEvent` handler instead.

  /// Record a single completed GC cycle.
  ///
  /// Called by the controller's [SleuthController._onGcEvent] handler which
  /// listens to the VM's authoritative per-cycle GC stream. Each call
  /// contributes exactly one event to the sliding window.
  ///
  /// [gcType] is the event's raw `gcType` value. `MarkSweep`,
  /// `MarkCompact` and `StartConcurrentMark` count as old-generation
  /// collections; anything else, including null, counts as a scavenge.
  /// The split is stamped on `gc_pressure` and does not change the rule.
  void recordGcCycle({String? gcType}) {
    if (!_isEnabled) return;
    _gcWindow.add((ts: _clock(), oldGen: _oldGenGcTypes.contains(gcType)));
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
  ///
  /// Order matters: [_evaluateHeapTrend] runs before
  /// [_evaluateHeapCapacity], which reads this tick's `heap_growing`
  /// emission from `_issues`.
  void _evaluate() {
    _issues.clear();

    _evictExpiredGcBatches();
    if (_gcWindow.isNotEmpty) {
      _evaluateGcPressure();
    }

    _evaluateHeapTrend();
    _evaluateHeapCapacity();
    _evaluateNativeGrowth();
  }

  /// Evict GC batches older than the sliding window.
  ///
  /// Window boundary is inclusive: a batch whose timestamp equals
  /// `now - _gcWindowDuration` is retained. A batch strictly before
  /// that is dropped.
  void _evictExpiredGcBatches() {
    final cutoff = _clock().subtract(_gcWindowDuration);
    while (_gcWindow.isNotEmpty && _gcWindow.first.ts.isBefore(cutoff)) {
      _gcWindow.removeFirst();
    }
  }

  void _evaluateGcPressure() {
    final windowEvents = _gcWindow.length;
    if (windowEvents == 0) {
      _gcOverageStart = null;
      return;
    }

    // Fixed-window denominator: (events / window seconds) * 60.
    // Using the window size rather than elapsed-since-first-event keeps
    // the rate stable under bursty traffic and prevents a lone event
    // from registering as "infinite rate" before the window has filled.
    final gcPerMinute = (windowEvents / _gcWindowDuration.inSeconds) * 60;
    if (gcPerMinute > gcRateThresholdPerMin) {
      // Pin overage-start on first cross. Persists across consecutive
      // re-emissions during the same overage so CaptureHelper's
      // dedup collapses them to one trace record. Cleared in the
      // else-branch below when the rate drops back to or under
      // threshold so a new overage produces a fresh identity.
      _gcOverageStart ??= _gcWindow.first.ts;
      final oldGenCount = _gcWindow.where((b) => b.oldGen).length;
      final scavengeCount = windowEvents - oldGenCount;
      final (hint, effort) = FixHintBuilder.gcPressure();
      _issues.add(
        PerformanceIssue(
          stableId: 'gc_pressure',
          severity: IssueSeverity.warning,
          category: IssueCategory.memory,
          confidence: IssueConfidence.likely,
          title: 'High GC Pressure: ${gcPerMinute.toStringAsFixed(0)} GC/min',
          detail:
              'Garbage collection is running frequently '
              '(${gcPerMinute.toStringAsFixed(0)}/min: $scavengeCount '
              'scavenges, $oldGenCount old-generation collections in the '
              'last ${_gcWindowDuration.inSeconds} s), indicating a high '
              'object creation/disposal rate.',
          fixHint: hint,
          fixEffort: effort,
          observationSource: ObservationSource.vmTimeline,
          detectedAt: _clock(),
          dedupIdentityMicros: _gcOverageStart!.microsecondsSinceEpoch,
          extraTraceArgs: {
            'observedGcEvents': windowEvents.toString(),
            'scavengeCount': scavengeCount.toString(),
            'oldGenCount': oldGenCount.toString(),
          },
          confidenceReason: 'VM GC frequency elevated + object churn rate',
        ),
      );
    } else {
      // Below the per-minute threshold. Clearing here (instead of only on
      // windowEvents == 0) ensures two distinct overage episodes separated
      // by a sub-threshold dip do not share identity — the second emission
      // needs a fresh _gcOverageStart so dedup does not collapse two
      // episodes into one trace record.
      _gcOverageStart = null;
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
      final sustained = _heapSamples.last.timestamp.difference(
        _sustainedGrowthStart!,
      );
      if (sustained.inSeconds >= _sustainedGrowthDurationSec) {
        final slopeKbSec = slope / 1024;
        final (hint, effort) = FixHintBuilder.heapGrowing();
        _issues.add(
          PerformanceIssue(
            stableId: 'heap_growing',
            severity: IssueSeverity.warning,
            category: IssueCategory.memory,
            confidence: IssueConfidence.likely,
            title:
                'Heap Growing: +${slopeKbSec.toStringAsFixed(0)} KB/s '
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
            // Stable per-trigger identity for capture-mode producer-side
            // dedup. `_sustainedGrowthStart` is set once when the slope
            // first crosses threshold (above) and persists until the slope
            // drops below, so multiple polls during one sustained-growth
            // episode emit issues with the same `dedupIdentityMicros` →
            // the controller's composite-key dedup collapses them to a
            // single trace record. A scenario that observes ≥2 records
            // with distinct identities means the sustained window broke
            // and re-engaged — capture-procedure validator catches that.
            dedupIdentityMicros: _sustainedGrowthStart!.microsecondsSinceEpoch,
            // Stringified per the wire-format contract for VM timeline args
            // (see also HeavyComputeDetector.observedDurationMs,
            // RebuildDetector.observedRebuildRate). Schema's `args` parser
            // accepts both string and num and round-trips via num.tryParse.
            extraTraceArgs: {
              'observedSlopeBytesPerSec': slope.toStringAsFixed(0),
            },
            topAllocators: _lastTopAllocators,
            confidenceReason:
                'Heap trend analysis + sustained growth regression',
          ),
        );
        _lastHeapGrowingEmittedAtMicros = _clock().microsecondsSinceEpoch;
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
    final budget = memoryBudgetBytes;
    if (budget == null || _heapSamples.length < _budgetWindowSize) {
      _budgetCrossingStart = null;
      return;
    }

    // Guard 1: RSS over the budget line for 4 of the last 5 samples.
    // `>=` so a budget line equal to the measured RSS counts.
    final line = capacityThresholdPercent * budget;
    var hits = 0;
    for (final sample in _heapSamples.skip(
      _heapSamples.length - _budgetWindowSize,
    )) {
      final rss = sample.rssBytes;
      if (rss != null && rss >= line) hits++;
    }
    if (hits < _budgetRequiredHits) {
      _budgetCrossingStart = null;
      return;
    }
    final latest = _heapSamples.last;
    _budgetCrossingStart ??= latest.timestamp;

    // Guard 2: `heap_growing` emitted in this same evaluation (10 s of
    // sustained slope, not the first crossing). A process that sits over
    // the line without growing is the app's working set, not an
    // approaching kill. [_evaluateHeapTrend] runs first, so `_issues`
    // already holds this tick's trend result.
    if (!_issues.any((i) => i.stableId == 'heap_growing')) return;

    // The latest sample may be the one dip the window tolerates, or carry
    // no RSS; report the newest measured value.
    final rss = _heapSamples.lastWhere((s) => s.rssBytes != null).rssBytes!;
    final pct = (rss / budget * 100).toStringAsFixed(0);
    final (hint, effort) = FixHintBuilder.heapNearCapacity();
    _issues.add(
      PerformanceIssue(
        stableId: 'heap_near_capacity',
        severity: IssueSeverity.critical,
        category: IssueCategory.memory,
        confidence: IssueConfidence.likely,
        title: 'Memory Near Budget: $pct% of ${_formatBytes(budget)}',
        detail:
            'Process memory (RSS) is ${_formatBytes(rss)}, $pct% of the '
            '${_formatBytes(budget)} budget, and the Dart heap is still '
            'growing (${_formatBytes(latest.heapUsage)} used). Past the '
            'budget the OS may terminate the app.',
        fixHint: hint,
        fixEffort: effort,
        observationSource: ObservationSource.vmTimeline,
        detectedAt: _clock(),
        dedupIdentityMicros: _budgetCrossingStart!.microsecondsSinceEpoch,
        extraTraceArgs: {
          'observedRssBytes': rss.toString(),
          'memoryBudgetBytes': budget.toString(),
        },
        confidenceReason:
            'Measured process RSS over the configured budget + sustained '
            'heap growth (budget supplied by the app)',
      ),
    );
  }

  void _evaluateNativeGrowth() {
    final nativeSamples = _heapSamples
        .where((s) => s.nativeBytes != null)
        .toList();
    if (nativeSamples.length < 4) return;

    // Suppress during warmup (same guard as heap trend)
    if (_firstHeapSampleTime != null) {
      final sinceFirst = _clock().difference(_firstHeapSampleTime!);
      if (sinceFirst.inMilliseconds < warmupDurationMs) return;
    }

    final slope = _computeNativeSlopeBytesPerSec(nativeSamples);

    if (slope > _nativeGrowthThresholdBytesPerSec) {
      _sustainedNativeGrowthStart ??= nativeSamples.last.timestamp;
      final sustained = nativeSamples.last.timestamp.difference(
        _sustainedNativeGrowthStart!,
      );
      if (sustained.inSeconds >= _sustainedGrowthDurationSec) {
        final slopeMbSec = slope / (1024 * 1024);
        final (hint, effort) = FixHintBuilder.nativeMemoryGrowth();
        _issues.add(
          PerformanceIssue(
            stableId: 'native_memory_growing',
            severity: IssueSeverity.warning,
            category: IssueCategory.memory,
            confidence: IssueConfidence.likely,
            title:
                'Native Memory Growing: '
                '+${slopeMbSec.toStringAsFixed(1)} MB/s '
                'for ${sustained.inSeconds}s',
            detail:
                'Process memory outside the Dart heap is growing at '
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
          ),
        );
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
    _gcWindow.clear();
    _heapSamples.clear();
    _sustainedGrowthStart = null;
    _sustainedNativeGrowthStart = null;
    _gcOverageStart = null;
    _firstHeapSampleTime = null;
    _lastTopAllocators = null;
    _lastHeapGrowingEmittedAtMicros = null;
    _budgetCrossingStart = null;
    _issues.clear();
  }

  @override
  void dispose() {
    _gcWindow.clear();
    _heapSamples.clear();
    _sustainedGrowthStart = null;
    _sustainedNativeGrowthStart = null;
    _gcOverageStart = null;
    _firstHeapSampleTime = null;
    _lastTopAllocators = null;
    _lastHeapGrowingEmittedAtMicros = null;
    _budgetCrossingStart = null;
    _issues.clear();
  }

  @override
  DetectorMetadata get validationMetadata => const DetectorMetadata(
    tier: EvidenceTier.reproducerOnly,
    rationale:
        'VM-only detector. 4 families pinned by hermetic '
        'reproducer at detector entrypoints (`processHeapSample` + '
        '`recordGcCycle`): `gc_pressure` (>30 cycles / 10s sliding '
        'window = >180/min rate, default; configurable; scavenge / '
        'old-gen split stamped), '
        '`heap_growing` (slope > 512KB/s '
        'sustained ≥10s), `heap_near_capacity` (opt-in '
        '`memoryBudgetBytes`; RSS ≥ 80% of the budget in 4 of the last '
        '5 samples AND `heap_growing` emitted in the same evaluation; '
        'silent when the budget is unset; RSS-null samples never count), '
        '`native_memory_growing` (RSS-heap gap slope > 1MB/s '
        'sustained ≥10s). Null-rssBytes (web) and zero-heap / '
        'zero-capacity null-coalesce edges asserted non-emitting.\n'
        '\n'
        'v0.19.3 raises `heap_growing` (warning tier, 512 KB/s '
        'sustained ≥10 s) to runtimeVerified via `perStableIdTier`, '
        'backed by three on-device captures (iPhone 12 / iOS 17.5 / '
        'Flutter 3.41.x) recorded via the in-app capture procedure: '
        '`MemoryPressureCaptureScreen` calibrates an allocation-loop '
        'rate, narrows VM timeline streams to `Dart` only (so 30 s '
        'of heavy allocation does not overflow the ring buffer), '
        'drives a 30 s sustained-allocation phase inside '
        '`Sleuth.markScenarioBegin/End` with a 600 ms pre-end dwell '
        '(detector emission landing) and 800 ms post-end dwell '
        '(VM-service buffer flush), then exports the wrapped JSON '
        'via the iOS clipboard. `markScenarioBegin` resets the '
        'detector window so the regression slope is computed on '
        'scenario allocation only — pre-scenario flat samples '
        'would otherwise dilute slope below threshold. Producer-'
        'side dedup keys on `_sustainedGrowthStart.microsecondsSinceEpoch` '
        'for stable per-trigger identity → '
        '`requireUniqueDetectedAtMicros: true` locks single-issue '
        'replay protection. Other 3 families (`gc_pressure`, '
        '`heap_near_capacity`, `native_memory_growing`) stay '
        'reproducerOnly — each requires a separate capture campaign '
        'with multi-axis brackets the current single-bracket schema '
        'cannot express. v0.19.18 backfills the '
        '`observedSlopeBytesPerSec` extraTraceArgs stamp + '
        '`observedAxisArgKey` declaration on the canonical bracket; '
        'cross-check is plumbing-only until on-device captures are '
        'refreshed (schema skips per-record when the arg is absent).\n'
        '\n'
        'Three upstream hops disclosed as skipped: (1) '
        '`VmServiceClient.getMemoryUsage` repacks '
        '`vm_service.MemoryUsage` into `HeapSample` with `null → 0` '
        'fallback on heap/capacity/external fields — the '
        'zero-coalesce edge is exercised but the repack is not; '
        '(2) `EventStreams.kGC → _onGcEvent → recordGcCycle` is '
        'the authoritative per-cycle GC signal and is called '
        'directly, bypassing the VM-service stream plumbing; '
        '(3) `VmServiceClient._readRssBytes() → '
        '`ProcessInfo.currentRss` is the OS-level RSS collection '
        'boundary that sources `HeapSample.rssBytes` and therefore '
        'gates `native_memory_growing` (which derives `nativeBytes '
        '= rssBytes - heapUsage`) and `heap_near_capacity` — the '
        'null-rssBytes edge (web / unusual embeddings) is exercised '
        'but the `ProcessInfo` call and its try/catch are not. '
        'TimelineParser\'s `gcEvents` list is NOT used by this '
        'detector (it over-counts GC sub-phase events 5–15× per '
        'cycle); that design choice is verified at the controller '
        'boundary, not here.',
    reproducerPath: 'test/validation/memory_pressure_reproducer_test.dart',
    profileCapturePaths: [
      'test/validation/captures/memory_pressure/heap_growing_below.json',
      'test/validation/captures/memory_pressure/heap_growing_at.json',
      'test/validation/captures/memory_pressure/heap_growing_above.json',
    ],
    bracketThreshold: 512000,
    bracketUnit: 'bytes/sec',
    bracketStableId: 'heap_growing',
    bracketSeverityLabel: 'warning',
    bracketAtTolerance: 0.50,
    aboveCeilingMultiplier: 2.0,
    observedAxisArgKey: 'observedSlopeBytesPerSec',
    coveredStableIds: {
      'gc_pressure',
      'heap_growing',
      'heap_near_capacity',
      'native_memory_growing',
    },
    perStableIdTier: {'heap_growing': EvidenceTier.runtimeVerified},
    coveredThresholds: {'heap_growing.warning'},
    bracketRequireUniqueDetectedAtMicros: true,
  );
}
