import 'dart:collection';
import 'dart:math' as math;

import 'package:meta/meta.dart';

import '../models/allocation_entry.dart';
import '../models/base_detector.dart';
import '../validation/detector_metadata.dart';
import '../validation/evidence_tier.dart';
import '../models/heap_sample.dart';
import '../models/issue_measurement.dart';
import '../models/performance_issue.dart';
import '../utils/fix_hint_builder.dart';
import 'heap_floor_tracker.dart';

/// Detects memory pressure using VM GC events and heap growth trends.
///
/// **VM-Only Detector** — monitors GC frequency, heap growth rate via
/// linear regression over a rolling window, and process memory (RSS)
/// against an optional app-supplied budget.
///
/// **Capture-mode timing.** Calling [reset] (auto-invoked by
/// `Sleuth.markScenarioBegin` via `SleuthController.resetCaptureState`)
/// clears `_heapSamples`, `_firstHeapSampleTime`, the sample leg's
/// sustain start and the floor leg's points, so the heap-trend
/// evaluation starts fresh on every scenario. Effective first-fire latency post-reset:
/// ~3 s warmup + ~2 s sample-accumulation (4-sample minimum) + slope-
/// cross + 10 s sustained = ~14-15 s of scenario allocation before the
/// first `heap_growing` issue can fire. Capture procedures should
/// allocate ≥30 s for comfortable margin.
@experimental
class MemoryPressureDetector extends BaseDetector
    with DetectorMetadataProvider {
  MemoryPressureDetector({
    DateTime Function()? clock,
    this.warmupDurationMs = 3000,
    this.growthThresholdBytesPerSec = 512000,
    this.capacityThresholdPercent = 0.80,
    this.memoryBudgetBytes,
    this.gcRateThresholdPerMin = _defaultGcRateThresholdPerMin,
    this.captureMode = false,
    this.floorStartupWindowMs = 30000,
    int floorCycleGapMs = 100,
    int floorWindowMs = 60000,
    int floorMinPoints = 3,
    int floorMinSpanMs = 10000,
    int floorFreshnessMs = 30000,
  }) : assert(
         memoryBudgetBytes == null || memoryBudgetBytes > 0,
         'memoryBudgetBytes must be positive when set.',
       ),
       _clock = clock ?? DateTime.now,
       super(
         type: DetectorType.memoryPressure,
         lifecycle: DetectorLifecycle.vmOnly,
         name: 'Memory Pressure',
         description:
             'Detects memory pressure from GC frequency and heap trends',
       ) {
    _floor = HeapFloorTracker(
      thresholdBytesPerSec: growthThresholdBytesPerSec,
      cycleGapMs: floorCycleGapMs,
      windowMs: floorWindowMs,
      minPoints: floorMinPoints,
      minSpanMs: floorMinSpanMs,
      freshnessMs: floorFreshnessMs,
    );
    _floorStartupBoundaryMs =
        _clock().millisecondsSinceEpoch + floorStartupWindowMs;
    _floor.clear(notBeforeMs: _floorStartupBoundaryMs);
  }

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

  /// Young-generation collections (scavenges) per minute, extrapolated
  /// from a 10 s sliding window, above which `gc_pressure` fires.
  /// Old-generation sweeps and concurrent-marking starts do not count: on
  /// animated screens they follow promotion and pause the app briefly.
  /// On an iPhone 12 and a Galaxy A07 at 60 Hz, ordinary screens ran 168
  /// scavenges a minute or fewer, and the GC Churn demo ran 390 to 810.
  /// Scavenges rise with the frame rate: Live Waveform at 90 Hz on the
  /// Galaxy ran 186 to 246 a minute with 3.7 to 4.9 % of the time in GC
  /// pauses, more than the churn demo. Each emission stamps the
  /// young-generation / old-generation / marking-start split of the window,
  /// and the GC pause time when it can be measured.
  final int gcRateThresholdPerMin;

  static const int _defaultGcRateThresholdPerMin = 240;

  /// Whether this detector runs in a capture session. Only then does
  /// [setLegsEnabledForCapture] change anything.
  final bool captureMode;

  /// Idle-collection points whose event time falls within this many
  /// milliseconds of the detector's construction are ignored, so the
  /// floor leg does not report the retention of app startup as growth.
  /// [reset] does not move this boundary.
  final int floorStartupWindowMs;

  late final HeapFloorTracker _floor;
  late final int _floorStartupBoundaryMs;
  bool _floorLegEnabled = true;
  bool _sampleLegEnabled = true;

  // -- heap_growing episodes --
  //
  // An episode starts at the first `heap_growing` publication from either
  // leg and ends at the first evaluation that publishes nothing. Each leg
  // has its own capture identity within the episode, so a leg switch
  // records one trace record per leg; confidence is `confirmed` while the
  // floor leg has published in the episode and no drop has followed.
  int _episode = 0;
  int? _episodeStartMicros;
  // The floor tracker's drop count when the floor leg last published in
  // this episode; null until it does. A drop since then means the heap
  // fell after the evidence, so a sample-leg publication is `likely`.
  int? _floorConfirmedDropCount;
  int? _sampleIdentityMicros;
  int? _floorIdentityMicros;

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

  /// One record per GC event. [pauseUs] is the GC pause time since the
  /// previous event, null when it cannot be measured.
  final Queue<({DateTime ts, _GcClass gcClass, double? pauseUs})> _gcWindow =
      Queue();

  /// Cumulative GC pause seconds (new plus old space) from the last
  /// attributable event, the baseline for the next event's pause. Null
  /// after a break in continuity.
  double? _lastCumulativePauseSeconds;

  /// Maps the VM's `gcType` to a class. A concurrent old-generation
  /// cycle posts two events: `StartCMark` when marking starts, then
  /// `MarkSweep` or `MarkCompact` when it finishes, so only the finishing
  /// event counts as an old-generation collection. `Evacuate` is a
  /// new-space collection. Missing or unknown values count as young so
  /// the three counts always sum to the window total.
  static _GcClass _classifyGc(String? gcType) => switch (gcType) {
    'MarkSweep' || 'MarkCompact' => _GcClass.old,
    'StartCMark' => _GcClass.markStart,
    _ => _GcClass.young,
  };

  // -- Heap trend rolling window --

  static const int _windowCapacity = 60; // 30 seconds at 500ms
  /// Seconds a growth rate must stay above its threshold before
  /// `heap_growing` (sample leg) or `native_memory_growing` emits.
  @visibleForTesting
  static const int sustainedGrowthDurationSec = 10;

  /// `native_memory_growing` threshold in bytes per second (1 MiB/s).
  @visibleForTesting
  static const int nativeGrowthThresholdBytesPerSec = 1048576;

  /// Fewest heap samples each half of the window needs before
  /// `native_memory_growing` evaluates.
  @visibleForTesting
  static const int nativeMinSamplesPerHalf = 4;

  final Queue<HeapSample> _heapSamples = Queue<HeapSample>();
  // Sample leg: when the sample regression first crossed the threshold in
  // the current run of evaluations. Owned by the sample leg only; the
  // episode outlives it while the floor leg publishes.
  DateTime? _sampleSustainedStart;
  DateTime? _sustainedNativeGrowthStart;
  // The identity of the last gc_pressure emission is its `detectedAt` in
  // microseconds, moved 1 µs past the previous identity when two
  // evaluations share a clock reading. Every evaluation over the threshold
  // gets its own identity, so capture mode writes the young count at every
  // recording point instead of only the count at the first crossing.
  // Kept across `reset()`, because the controller's capture dedup set
  // outlives every leg.
  int _lastGcIdentityMicros = 0;

  // -- heap_near_capacity (RSS against memoryBudgetBytes) --
  //
  // [_evaluateHeapCapacity] reads the last [budgetWindowSize] heap
  // samples and needs [budgetRequiredHits] of them with
  // `rssBytes >= capacityThresholdPercent × memoryBudgetBytes`. A "K of
  // last N" window tolerates one sample dipping under the line as the
  // GC reclaims. Samples without RSS (web, unusual embeddings) never
  // count. The window is derived from `_heapSamples`, so an evaluation
  // triggered by [recordGcCycle] reads the same samples and cannot
  // double-count.
  /// Heap samples `heap_near_capacity` reads: the last this many.
  static const int budgetWindowSize = 5;

  /// Samples of the last [budgetWindowSize] that must be over budget.
  static const int budgetRequiredHits = 4;

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

  /// Number of `heap_growing` episodes started so far. Changes when a new
  /// episode starts, also while the issue stays visible across the
  /// switch, so readers can tell one episode from the next.
  int get heapGrowingEpisode => _episode;

  /// The floor leg's verdict now: the heap measured right after idle full
  /// collections.
  HeapFloorVerdict get floorVerdict => _floorLegEnabled
      ? _floor.verdict(_clock().millisecondsSinceEpoch)
      : HeapFloorTracker.unknownVerdict;

  /// Switches the two `heap_growing` legs on or off, so a capture can
  /// record each leg's evidence alone. Does nothing unless [captureMode]
  /// is true; a normal session always runs both legs.
  void setLegsEnabledForCapture({bool? floor, bool? sample}) {
    if (!captureMode) return;
    if (floor != null && floor != _floorLegEnabled) {
      _floorLegEnabled = floor;
      _floor.clear(notBeforeMs: _floorNotBeforeNow());
    }
    if (sample != null && sample != _sampleLegEnabled) {
      _sampleLegEnabled = sample;
      _sampleSustainedStart = null;
    }
    _evaluate();
  }

  int _floorNotBeforeMs(int nowMs) =>
      nowMs > _floorStartupBoundaryMs ? nowMs : _floorStartupBoundaryMs;

  int _floorNotBeforeNow() =>
      _floorNotBeforeMs(_clock().millisecondsSinceEpoch);

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
  /// - The sample leg's sustain start survives, so a heap_growing issue emitted
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
    // A new session starts without a pause baseline. A manual reconnect
    // while connected never reports `false`, and the GC events missed
    // during its backoff (up to 16 s) would otherwise all be booked into
    // the first event of the new session.
    _lastCumulativePauseSeconds = null;
    // Collections from before the change belong to another session.
    _floor.clear(notBeforeMs: _floorNotBeforeNow());
    if (!value) {
      _gcWindow.clear();
      _heapSamples.clear();
      _budgetCrossingStart = null;
      _sampleSustainedStart = null;
      _sustainedNativeGrowthStart = null;
      _firstHeapSampleTime = null;
      _lastHeapGrowingEmittedAtMicros = null;
      _endEpisode();
      _evaluate();
    }
    super.vmConnected = value;
  }

  /// Unmodifiable view of the rolling heap sample window for session export.
  List<HeapSample> get heapSamples => List.unmodifiable(_heapSamples);

  // processTimelineData intentionally NOT overridden.
  //
  // Previously, this method read `data.gcEvents.length` as the GC count
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
  /// Called by the controller's `SleuthController._onGcEvent` handler which
  /// listens to the VM's authoritative per-cycle GC stream. Each call
  /// contributes exactly one event to the sliding window.
  ///
  /// [gcType] is the event's raw `gcType` value, classified by
  /// [_classifyGc]. The split is stamped on `gc_pressure` and does not
  /// change the rule.
  ///
  /// [cumulativePauseSeconds] is the event's `new.time + old.time`: the
  /// VM's running total of GC pause time for the isolate group.
  /// [pauseAttributable] is true only when the event is known to come
  /// from the app's own isolate group. The difference from the previous
  /// attributable event is this event's pause. Anything else breaks
  /// continuity, and the next attributable event only sets a new
  /// baseline. The baseline is kept while the detector is disabled, so
  /// re-enabling it does not book the disabled interval's pauses into
  /// the current window.
  ///
  /// [reason], [heapUsedBytes] (`new.used + old.used` after the
  /// collection) and [eventTimestampMs] (the event's `timestamp`) feed the
  /// `heap_growing` floor leg, which only uses events that
  /// [pauseAttributable] marks as the app's own.
  void recordGcCycle({
    String? gcType,
    double? cumulativePauseSeconds,
    bool pauseAttributable = false,
    String? reason,
    int? heapUsedBytes,
    int? eventTimestampMs,
  }) {
    final pauseUs = _advancePauseBaseline(
      pauseAttributable ? cumulativePauseSeconds : null,
    );
    if (!_isEnabled) return;
    final now = _clock();
    _gcWindow.add((ts: now, gcClass: _classifyGc(gcType), pauseUs: pauseUs));
    if (_floorLegEnabled && pauseAttributable) {
      _floor.addCollection(
        gcType: gcType,
        reason: reason,
        heapUsedBytes: heapUsedBytes,
        eventMs: eventTimestampMs,
        arrivalMs: now.millisecondsSinceEpoch,
      );
    }
    _evaluate();
  }

  double? _advancePauseBaseline(double? cumulative) {
    final last = _lastCumulativePauseSeconds;
    _lastCumulativePauseSeconds = cumulative;
    if (cumulative == null || last == null || cumulative < last) return null;
    return (cumulative - last) * Duration.microsecondsPerSecond;
  }

  /// GC events in the current 10 s window, by class, and their summed
  /// pause time.
  ///
  /// `pauseAvailable` is true only when every event in the window has a
  /// measured pause. `pauseMs` is null whenever it is false, so "no
  /// pauses" (0.0) and "not measurable" stay distinct.
  ({
    int events,
    int young,
    int old,
    int markStarts,
    bool pauseAvailable,
    double? pauseMs,
  })
  get gcWindowStats {
    final cutoff = _clock().subtract(_gcWindowDuration);
    final window = [
      for (final r in _gcWindow)
        if (!r.ts.isBefore(cutoff)) r,
    ];
    final pauseMs = _windowPauseMs(window);
    return (
      events: window.length,
      young: window.where((r) => r.gcClass == _GcClass.young).length,
      old: window.where((r) => r.gcClass == _GcClass.old).length,
      markStarts: window.where((r) => r.gcClass == _GcClass.markStart).length,
      pauseAvailable: pauseMs != null,
      pauseMs: pauseMs,
    );
  }

  static double? _windowPauseMs(
    Iterable<({DateTime ts, _GcClass gcClass, double? pauseUs})> window,
  ) {
    if (window.isEmpty) return null;
    var totalUs = 0.0;
    for (final r in window) {
      final pause = r.pauseUs;
      if (pause == null) return null;
      totalUs += pause;
    }
    return totalUs / Duration.microsecondsPerMillisecond;
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
  ///
  /// A profile that arrives after the growth episode ended is dropped:
  /// kept, it would label the next episode's first emission.
  void enrichHeapGrowingIssue(List<AllocationEntry> allocators) {
    final idx = _issues.indexWhere((i) => i.stableId == 'heap_growing');
    if (idx == -1) return;
    _lastTopAllocators = allocators;
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
    _evaluateGcPressure();

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
    if (windowEvents == 0) return;

    // Young-generation collections set the rate. Each concurrent old-gen
    // cycle posts a marking start and then a sweep; counting them doubled
    // the old-gen cycles that ordinary animation triggers.
    //
    // Fixed-window denominator: (events / window seconds) * 60.
    // Using the window size rather than elapsed-since-first-event keeps
    // the rate stable under bursty traffic and prevents a lone event
    // from registering as "infinite rate" before the window has filled.
    final youngCount = _gcWindow
        .where((r) => r.gcClass == _GcClass.young)
        .length;
    final youngPerMinute = (youngCount / _gcWindowDuration.inSeconds) * 60;
    if (youngPerMinute > gcRateThresholdPerMin) {
      final detectedAt = _clock();
      _lastGcIdentityMicros = _nextGcIdentity(
        detectedAt,
        _lastGcIdentityMicros,
      );
      final oldGenCount = _gcWindow
          .where((r) => r.gcClass == _GcClass.old)
          .length;
      final markStartCount = _gcWindow
          .where((r) => r.gcClass == _GcClass.markStart)
          .length;
      final pauseMs = _windowPauseMs(_gcWindow);
      final pausePercent = pauseMs == null
          ? null
          : pauseMs / _gcWindowDuration.inMilliseconds * 100;
      final windowSeconds = _gcWindowDuration.inSeconds;
      final pauseSentence = pauseMs == null
          ? ''
          : 'GC paused the app for ${pauseMs.toStringAsFixed(1)} ms '
                '(${pausePercent!.toStringAsFixed(2)} %) in the last '
                '$windowSeconds s. ';
      final (hint, effort) = FixHintBuilder.gcPressure();
      _issues.add(
        PerformanceIssue(
          stableId: 'gc_pressure',
          severity: IssueSeverity.warning,
          category: IssueCategory.memory,
          confidence: IssueConfidence.likely,
          title:
              'High GC Pressure: '
              '${youngPerMinute.toStringAsFixed(0)} young GCs/min',
          detail:
              'Young-generation garbage collection runs '
              '${youngPerMinute.toStringAsFixed(0)}/min ($youngCount '
              'young-generation collections, $oldGenCount old-generation '
              'collections and $markStartCount concurrent-marking starts in '
              'the last $windowSeconds s). $pauseSentence'
              'This points to a high rate of object creation and disposal.',
          fixHint: hint,
          fixEffort: effort,
          observationSource: ObservationSource.vmTimeline,
          detectedAt: detectedAt,
          dedupIdentityMicros: _lastGcIdentityMicros,
          extraTraceArgs: {
            'observedGcEvents': windowEvents.toString(),
            'scavengeCount': youngCount.toString(),
            'oldGenCount': oldGenCount.toString(),
            'markStartCount': markStartCount.toString(),
            if (pauseMs != null) 'gcPauseMs': pauseMs.toStringAsFixed(1),
            if (pausePercent != null)
              'gcPausePercent': pausePercent.toStringAsFixed(2),
          },
          measurement: IssueMeasurement(
            value: youngPerMinute,
            unit: MeasurementUnit.perMinute,
            warningAt: gcRateThresholdPerMin.toDouble(),
            window: _gcWindowDuration,
            strict: true,
          ),
          confidenceReason: 'Elevated VM GC frequency and object churn rate',
        ),
      );
    }
  }

  /// [at] in microseconds, or 1 µs past [previous] when [at] is not later.
  static int _nextGcIdentity(DateTime at, int previous) {
    final micros = at.microsecondsSinceEpoch;
    return micros > previous ? micros : previous + 1;
  }

  /// Publishes `heap_growing` from one of two legs.
  ///
  /// The floor leg (`confirmed` evidence) reads the heap right after idle
  /// full collections. While its verdict is fresh it decides: growing
  /// publishes the floor leg; not growing publishes nothing and clears the
  /// recency stamp. Without a fresh verdict the sample leg (the 500 ms
  /// heap-sample regression, sustained 10 s) decides as before.
  void _evaluateHeapTrend() {
    final sample = _sampleLegEnabled ? _evaluateSampleLeg() : null;
    final floor = floorVerdict;
    switch (floor.state) {
      case HeapFloorState.growing:
        _publishFloorLeg(floor);
      case HeapFloorState.notGrowing:
        _endEpisode();
        _lastHeapGrowingEmittedAtMicros = null;
      case HeapFloorState.unknown:
        if (sample == null) {
          _endEpisode();
        } else {
          _publishSampleLeg(sample.slope, sample.sustained);
        }
    }
  }

  /// The sample leg's current reading: the regression slope when it has
  /// stayed above the threshold for the sustain period, else null. Keeps
  /// its sustain state current even while the floor leg decides.
  ({double slope, Duration sustained})? _evaluateSampleLeg() {
    if (_heapSamples.length < 4) {
      _sampleSustainedStart = null;
      return null;
    }
    // Suppress heap trend alerts during warmup to avoid false positives
    // from normal startup allocation (class loading, widget tree, images).
    if (_firstHeapSampleTime != null) {
      final sinceFirst = _clock().difference(_firstHeapSampleTime!);
      if (sinceFirst.inMilliseconds < warmupDurationMs) return null;
    }
    final slope = _computeSlopeBytesPerSec();
    if (slope <= growthThresholdBytesPerSec) {
      _sampleSustainedStart = null;
      return null;
    }
    _sampleSustainedStart ??= _heapSamples.last.timestamp;
    final sustained = _heapSamples.last.timestamp.difference(
      _sampleSustainedStart!,
    );
    if (sustained.inSeconds < sustainedGrowthDurationSec) return null;
    return (slope: slope, sustained: sustained);
  }

  /// Starts an episode if none is open and returns this leg's capture
  /// identity for it. A leg keeps its identity for the whole episode;
  /// the two legs never share one, so each records its own trace record.
  int _publishIdentity({required bool floorLeg}) {
    final nowMicros = _clock().microsecondsSinceEpoch;
    if (_episodeStartMicros == null) {
      _episode++;
      _episodeStartMicros = nowMicros;
      _floorConfirmedDropCount = null;
      _sampleIdentityMicros = null;
      _floorIdentityMicros = null;
      _lastTopAllocators = null;
    }
    if (floorLeg) _floorConfirmedDropCount = _floor.dropCount;
    _lastHeapGrowingEmittedAtMicros = nowMicros;
    final own = floorLeg ? _floorIdentityMicros : _sampleIdentityMicros;
    if (own != null) return own;
    final other = floorLeg ? _sampleIdentityMicros : _floorIdentityMicros;
    final identity = nowMicros == other ? nowMicros + 1 : nowMicros;
    if (floorLeg) {
      _floorIdentityMicros = identity;
    } else {
      _sampleIdentityMicros = identity;
    }
    return identity;
  }

  void _endEpisode() {
    _episodeStartMicros = null;
    _floorConfirmedDropCount = null;
    _sampleIdentityMicros = null;
    _floorIdentityMicros = null;
    _lastTopAllocators = null;
  }

  IssueConfidence get _episodeConfidence =>
      _floorConfirmedDropCount != null &&
          _floorConfirmedDropCount == _floor.dropCount
      ? IssueConfidence.confirmed
      : IssueConfidence.likely;

  void _publishFloorLeg(HeapFloorVerdict floor) {
    final identity = _publishIdentity(floorLeg: true);
    final slope = floor.slopeBytesPerSec ?? 0;
    final slopeKbSec = slope / 1024;
    final spanSec = (floor.runSpanMs / 1000).round();
    final ageSec = floor.newestEventMs == null
        ? 0
        : ((_clock().millisecondsSinceEpoch - floor.newestEventMs!) / 1000)
              .round();
    final (hint, effort) = FixHintBuilder.heapGrowing();
    _issues.add(
      PerformanceIssue(
        stableId: 'heap_growing',
        severity: IssueSeverity.warning,
        category: IssueCategory.memory,
        confidence: _episodeConfidence,
        title:
            'Heap Growing: +${slopeKbSec.toStringAsFixed(0)} KB/s '
            'over ${spanSec}s',
        detail:
            'Measured right after idle garbage collections, the heap grew '
            'at ${slopeKbSec.toStringAsFixed(1)} KB/sec across '
            '${floor.runPoints} collections spanning $spanSec seconds. The '
            'newest collection, ${ageSec}s ago, left '
            '${_formatBytes(floor.newestBytes ?? 0)} in use.',
        fixHint: hint,
        fixEffort: effort,
        observationSource: ObservationSource.vmTimeline,
        detectedAt: _clock(),
        dedupIdentityMicros: identity,
        extraTraceArgs: {
          'heapGrowingLeg': 'floor',
          'observedFloorSlopeBytesPerSec': slope.toStringAsFixed(0),
          'floorPointCount': floor.runPoints.toString(),
        },
        measurement: IssueMeasurement(
          value: slope,
          unit: MeasurementUnit.bytesPerSecond,
          warningAt: growthThresholdBytesPerSec.toDouble(),
          strict: true,
        ),
        topAllocators: _lastTopAllocators,
        confidenceReason:
            'Heap level measured right after idle full collections, which '
            'leaves out garbage the next collection would free',
      ),
    );
  }

  void _publishSampleLeg(double slope, Duration sustained) {
    final identity = _publishIdentity(floorLeg: false);
    final slopeKbSec = slope / 1024;
    final (hint, effort) = FixHintBuilder.heapGrowing();
    _issues.add(
      PerformanceIssue(
        stableId: 'heap_growing',
        severity: IssueSeverity.warning,
        category: IssueCategory.memory,
        confidence: _episodeConfidence,
        title:
            'Heap Growing: +${slopeKbSec.toStringAsFixed(0)} KB/s '
            'for ${sustained.inSeconds}s',
        detail:
            'The heap has grown at ${slopeKbSec.toStringAsFixed(1)} KB/sec '
            'for ${sustained.inSeconds} seconds. It now holds '
            '${_formatBytes(_heapSamples.last.heapUsage)}. The window has '
            '${_heapSamples.length} samples over '
            '${_heapSamples.last.timestamp.difference(_heapSamples.first.timestamp).inSeconds}s.',
        fixHint: hint,
        fixEffort: effort,
        observationSource: ObservationSource.vmTimeline,
        detectedAt: _clock(),
        // Stable per-leg identity for the episode, so the controller's
        // composite-key dedup records one trace record per leg per episode.
        dedupIdentityMicros: identity,
        // Stringified per the wire-format contract for VM timeline args
        // (see also HeavyComputeDetector.observedDurationMs,
        // RebuildDetector.observedBuildPercent). Schema's `args` parser
        // accepts both string and num and round-trips via num.tryParse.
        extraTraceArgs: {
          'heapGrowingLeg': 'sample',
          'observedSlopeBytesPerSec': slope.toStringAsFixed(0),
        },
        measurement: IssueMeasurement(
          value: slope,
          unit: MeasurementUnit.bytesPerSecond,
          warningAt: growthThresholdBytesPerSec.toDouble(),
          strict: true,
        ),
        topAllocators: _lastTopAllocators,
        confidenceReason:
            'Heap trend analysis and a sustained growth regression',
      ),
    );
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
    if (budget == null || _heapSamples.length < budgetWindowSize) {
      _budgetCrossingStart = null;
      return;
    }

    // Guard 1: RSS over the budget line for 4 of the last 5 samples.
    // `>=` so a budget line equal to the measured RSS counts.
    final line = capacityThresholdPercent * budget;
    var hits = 0;
    for (final sample in _heapSamples.skip(
      _heapSamples.length - budgetWindowSize,
    )) {
      final rss = sample.rssBytes;
      if (rss != null && rss >= line) hits++;
    }
    if (hits < budgetRequiredHits) {
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
        measurement: IssueMeasurement(
          value: rss.toDouble(),
          unit: MeasurementUnit.bytes,
          criticalAt: line.toDouble(),
        ),
        confidenceReason:
            'Measured process RSS above the budget the app configured, '
            'with sustained heap growth',
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

    final slope = continuedGrowthSlope(nativeSamples);

    if (slope > nativeGrowthThresholdBytesPerSec) {
      _sustainedNativeGrowthStart ??= nativeSamples.last.timestamp;
      final sustained = nativeSamples.last.timestamp.difference(
        _sustainedNativeGrowthStart!,
      );
      if (sustained.inSeconds >= sustainedGrowthDurationSec) {
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
                'Process memory outside the Dart heap has grown at '
                '${slopeMbSec.toStringAsFixed(2)} MB/sec for '
                '${sustained.inSeconds} seconds, in both halves of the last '
                '30 seconds, and the process RSS grew at least as fast. '
                'Possible causes are '
                'undisposed GPU textures, images decoded at full resolution, '
                'or platform channel buffers that keep growing. The current '
                'native estimate is '
                '${_formatBytes(nativeSamples.last.nativeBytes!)}.',
            fixHint: hint,
            fixEffort: effort,
            observationSource: ObservationSource.vmTimeline,
            detectedAt: _clock(),
            measurement: IssueMeasurement(
              value: slope,
              unit: MeasurementUnit.bytesPerSecond,
              warningAt: nativeGrowthThresholdBytesPerSec.toDouble(),
              strict: true,
            ),
            confidenceReason:
                'Native memory trend analysis and a sustained growth '
                'regression',
          ),
        );
      }
    } else {
      _sustainedNativeGrowthStart = null;
    }
  }

  /// The slowest growth rate across [samples], in bytes/sec, over the
  /// whole window and over each half split at its time midpoint. Each
  /// rate is the lower of the native and RSS regressions. Zero while a
  /// half holds fewer than [nativeMinSamplesPerHalf] samples.
  ///
  /// Native growth must show in the RSS itself. When RSS keeps the pages
  /// of freed Dart objects, a heap drop raises RSS minus the heap without
  /// moving RSS; a drop of about 25 MB or more read above 1 MiB/s for
  /// longer than 10 s.
  ///
  /// Growth must also continue through the window. A one-time jump of D
  /// bytes in the middle of a 30 s window reads about 1.5 D / 30 s as one
  /// slope, so a screen that allocated 25 MB once read as growth for more
  /// than 10 s. A jump leaves one half flat. Growth that arrives in chunks
  /// more than about 15 s apart can leave a half flat too and is not
  /// reported.
  @visibleForTesting
  static double continuedGrowthSlope(List<HeapSample> samples) {
    double rate(List<HeapSample> part) => math.min(
      _slopeBytesPerSec(part, (s) => s.nativeBytes!),
      _slopeBytesPerSec(part, (s) => s.rssBytes!),
    );
    final start = samples.first.timestamp;
    final middle = start.add(samples.last.timestamp.difference(start) ~/ 2);
    final split = samples.indexWhere((s) => !s.timestamp.isBefore(middle));
    if (split < nativeMinSamplesPerHalf ||
        samples.length - split < nativeMinSamplesPerHalf) {
      return 0;
    }
    return [
      rate(samples),
      rate(samples.sublist(0, split)),
      rate(samples.sublist(split)),
    ].reduce(math.min);
  }

  /// Growth rate of [value] across [samples] in bytes/sec, by linear
  /// regression.
  static double _slopeBytesPerSec(
    List<HeapSample> samples,
    int Function(HeapSample sample) value,
  ) {
    final n = samples.length;
    if (n < 2) return 0;

    final firstTs = samples.first.timestamp;
    double sumX = 0, sumY = 0, sumXY = 0, sumX2 = 0;

    for (final sample in samples) {
      final x = sample.timestamp.difference(firstTs).inMilliseconds / 1000.0;
      final y = value(sample).toDouble();
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

  /// Clears every window, issue and episode. It keeps the GC pause
  /// baseline, because `SleuthController.resetCaptureState` calls this at
  /// every capture leg start and the first GC of the leg still has a
  /// measurable pause against the last one before it. It keeps the last
  /// gc_pressure identity too, so a new leg's identities never repeat an
  /// earlier one.
  void reset() {
    _gcWindow.clear();
    _heapSamples.clear();
    _sampleSustainedStart = null;
    _sustainedNativeGrowthStart = null;
    _firstHeapSampleTime = null;
    _lastTopAllocators = null;
    _lastHeapGrowingEmittedAtMicros = null;
    _budgetCrossingStart = null;
    _floor.clear(notBeforeMs: _floorNotBeforeNow());
    _endEpisode();
    _issues.clear();
  }

  @override
  void dispose() {
    _gcWindow.clear();
    _lastCumulativePauseSeconds = null;
    _heapSamples.clear();
    _sampleSustainedStart = null;
    _sustainedNativeGrowthStart = null;
    _firstHeapSampleTime = null;
    _lastTopAllocators = null;
    _lastHeapGrowingEmittedAtMicros = null;
    _budgetCrossingStart = null;
    _floor.clear(notBeforeMs: _floorNotBeforeNow());
    _endEpisode();
    _issues.clear();
  }

  @override
  DetectorMetadata get validationMetadata => const DetectorMetadata(
    tier: EvidenceTier.reproducerOnly,
    rationale:
        'VM-only detector. A hermetic reproducer pins 4 families at the '
        'detector entry points (`processHeapSample` and `recordGcCycle`). '
        '`gc_pressure` fires above 40 young-generation collections in a '
        '10s sliding window, a rate above 240/min, by default; old-gen '
        'sweeps and marking starts do not count. Recorded GC dumps from an '
        'iPhone 12 and a Galaxy A07 pin the rule: GC Churn fires on both, '
        'and Live Waveform is silent at 60 Hz. The threshold is '
        'configurable, and '
        'the issue stamps the young-generation, old-generation and '
        'marking-start split, plus GC pause time when every event in the '
        'window has a measured pause. `heap_growing` '
        'fires on a slope above 512KB/s sustained for at least 10s. '
        '`heap_near_capacity` needs the opt-in `memoryBudgetBytes`. It '
        'fires when RSS is at least 80% of the budget in 4 of the last 5 '
        'samples and `heap_growing` emitted in the same evaluation. It '
        'stays silent when the budget is unset, and RSS-null samples never '
        'count. `native_memory_growing` fires when the slope of the '
        'RSS-heap gap and the slope of RSS itself are both above 1MB/s '
        'over the 30 s window and over each half of it, sustained for at '
        'least 10s; RSS stays flat while the Dart heap collects, so the '
        'heap sawtooth never fires it, and a one-time jump leaves one half '
        'flat. Recorded Galaxy A07 and iPhone 12 staircases (10 MB every '
        '2.5 s) fire it, and a Galaxy screen-open jump does not. The '
        'reproducer asserts that null rssBytes (web) and the zero-heap and '
        'zero-capacity null-coalesce edges emit nothing.\n\n'
        'v0.19.3 raises `heap_growing` (warning tier, 512 KB/s) to '
        'runtimeVerified via `perStableIdTier`, with one bracket per leg: '
        'the canonical bracket reads the sample leg '
        '(`observedSlopeBytesPerSec`, 10 s sustained regression) and '
        '`additionalBrackets[0]` the floor leg '
        '(`observedFloorSlopeBytesPerSec`, idle full collections). Each leg '
        'has three on-device captures (iPhone 12, iOS 17.5, Flutter 3.47.6) '
        'recorded with the other leg switched off, because every in-span '
        'record must carry its bracket\'s key. '
        '`MemoryPressureCaptureScreen` calibrates an allocation-loop rate '
        'and narrows VM timeline streams to `Dart` only, so heavy '
        'allocation does not overflow the ring buffer. It switches '
        'StreamResourceDetector off, holds Sleuth\'s own allocation-profile '
        'reads and waits for one in flight, settles for 2.5 s, then drives '
        'a 45 s sustained-allocation phase inside '
        '`Sleuth.markScenarioBegin/End`, with a 600 ms dwell before the end '
        'for the detector emission and an 800 ms dwell after it for the '
        'VM-service buffer flush. Last, it exports the wrapped JSON through '
        'the iOS clipboard. `markScenarioBegin` resets the detector window '
        'so the regression slope covers scenario allocation only. Flat '
        'samples from before the scenario would otherwise dilute the slope '
        'below the threshold. Producer-side dedup keys on each leg\'s '
        'first publication time in the growth episode, a stable per-leg '
        'identity, so `requireUniqueDetectedAtMicros: true` locks '
        'single-issue replay protection. v0.38.0 raises `gc_pressure` '
        '(warning) too, through `additionalBrackets[1]`: threshold 41 young '
        'collections in the 10 s window (the first count above 240/min), '
        'read from `scavengeCount` as the largest in-span value, on three '
        'iPhone 12 captures (iOS 17.5, Flutter 3.47.6). The capture screen '
        'counts its own isolate\'s young collections over its own VM '
        'service connection, holds the young rate at the leg\'s target '
        'with a closed allocation loop, and exports its own largest 10 s '
        'count; the audit compares that with the detector\'s records '
        'within 25 %. Each evaluation over the threshold carries its own '
        'identity, so the records follow the count as the window fills '
        'from the reset at `markScenarioBegin`. `heap_near_capacity` and '
        '`native_memory_growing` stay reproducerOnly. v0.19.18 backfills the `observedSlopeBytesPerSec` '
        'extraTraceArgs stamp and the `observedAxisArgKey` declaration on '
        'the canonical bracket. The capture screen writes the detector\'s '
        'slope into `expectedMagnitude.observed`, so the cross-check reads '
        'the same value; the measured operator rate is in the capture '
        'notes.\n\n'
        'The reproducer skips three upstream hops. (1) '
        '`VmServiceClient.getMemoryUsage` repacks `vm_service.MemoryUsage` '
        'into `HeapSample` and falls back from null to 0 on the heap, '
        'capacity and external fields. The reproducer exercises the '
        'zero-coalesce edge but not the repack. (2) `EventStreams.kGC`, '
        'then `_onGcEvent`, then `recordGcCycle` is the authoritative '
        'per-cycle GC signal. The reproducer calls `recordGcCycle` directly '
        'and skips the VM-service stream plumbing. (3) '
        '`VmServiceClient._readRssBytes()` calls `ProcessInfo.currentRss`, '
        'the OS-level RSS collection boundary. It sources '
        '`HeapSample.rssBytes`, so it gates `native_memory_growing` (which '
        'reads RSS and `nativeBytes = rssBytes - heapUsage`) and '
        '`heap_near_capacity`. The reproducer exercises the null-rssBytes '
        'edge (web, unusual embeddings) but not the `ProcessInfo` call and '
        'its try/catch. This detector does not use the `gcEvents` list from '
        'TimelineParser, because that list over-counts GC sub-phase events '
        '5 to 15 times per cycle. The controller boundary verifies that '
        'design choice, not this reproducer.',
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
    perStableIdTier: {
      'heap_growing': EvidenceTier.runtimeVerified,
      'gc_pressure': EvidenceTier.runtimeVerified,
    },
    coveredThresholds: {'heap_growing.warning', 'gc_pressure.warning'},
    bracketRequireUniqueDetectedAtMicros: true,
    // The floor leg's bracket. Its records carry
    // `observedFloorSlopeBytesPerSec` and never the sample leg's key, so
    // each bracket reads only its own leg; each triad was recorded with
    // the other leg switched off.
    additionalBrackets: [
      BracketSpec(
        stableId: 'heap_growing',
        severityLabel: 'warning',
        threshold: 512000,
        unit: 'bytes/sec',
        coveredThresholds: {'heap_growing.warning'},
        profileCapturePaths: [
          'test/validation/captures/memory_pressure_floor/heap_growing_floor_below.json',
          'test/validation/captures/memory_pressure_floor/heap_growing_floor_at.json',
          'test/validation/captures/memory_pressure_floor/heap_growing_floor_above.json',
        ],
        atTolerance: 0.50,
        aboveCeilingMultiplier: 2.0,
        observedAxisArgKey: 'observedFloorSlopeBytesPerSec',
        observedAxisTolerance: 0.10,
        requireUniqueDetectedAtMicros: true,
      ),
      // gc_pressure fires above 40 young collections in the 10 s window,
      // so 41 is the first count that fires. The at band [41, 61.5] and
      // the above band (61.5, 102.5] hold the window count; the count
      // climbs from 0 after the leg's reset, so the largest in-span value
      // is the leg's steady count. The capture screen exports its own
      // count of young collections, hence the 25 % tolerance.
      BracketSpec(
        stableId: 'gc_pressure',
        severityLabel: 'warning',
        threshold: 41,
        unit: 'gcevents',
        coveredThresholds: {'gc_pressure.warning'},
        profileCapturePaths: [
          'test/validation/captures/gc_pressure/gc_pressure_below.json',
          'test/validation/captures/gc_pressure/gc_pressure_at.json',
          'test/validation/captures/gc_pressure/gc_pressure_above.json',
        ],
        atTolerance: 0.5,
        aboveCeilingMultiplier: 2.5,
        observedAxisArgKey: 'scavengeCount',
        observedAxisTolerance: 0.25,
        observedAxisReduction: 'max',
        requireUniqueDetectedAtMicros: true,
        requireDetectorTraceRecord: true,
        // Every recording point after the crossing writes a record, so a
        // leg holds many in-band records.
        minInBandSamples: 2,
      ),
    ],
  );
}

/// The kind of collection a GC event reports.
enum _GcClass {
  /// A new-space collection: `Scavenge` or `Evacuate`.
  young,

  /// A completed old-generation cycle: `MarkSweep` or `MarkCompact`.
  old,

  /// The start of a concurrent old-generation mark (`StartCMark`).
  markStart,
}
