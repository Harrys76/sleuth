import 'dart:async';

import 'package:meta/meta.dart';
import 'package:vm_service/vm_service.dart';

import '../models/base_detector.dart';
import '../models/performance_issue.dart';
import '../utils/fix_hint_builder.dart';
import '../validation/detector_metadata.dart';
import '../validation/evidence_tier.dart';
import '../vm/timeline_parser.dart';
import '../vm/vm_service_client.dart';

/// Detects likely retained async resources (Stream subscriptions,
/// StreamControllers, WebSocket channels, optional rxdart Subjects)
/// via `getAllocationProfile` class-instance diff over a sliding
/// window, gated on a recent `MemoryPressureDetector.heap_growing`
/// emission.
///
/// **VM-Only Detector.** Polls allocation profile at most once per
/// [DetectorThresholds.streamResourceSampleSeconds] seconds; tracks
/// `instancesCurrent` for a hardcoded watchlist of dart:async,
/// dart:io, web_socket_channel, and (when present in profile) rxdart
/// classes; emits `stream_resource_growth.warning` only when:
/// (a) heap_growing is currently in its recency window,
/// (b) ≥2 watchlist classes show ≥3 of 3 ascending transitions
///     across the K=4 sample window, and
/// (c) sum of per-class net deltas exceeds
///     [DetectorThresholds.streamResourceMinDelta].
///
/// Confidence is `IssueConfidence.likely` — runtime allocation-
/// profile evidence + structural watchlist + runtime co-fire.
/// Evidence tier is `reproducerOnly`: the detector logic is hermetic-
/// reproducer covered, but a tier raise to runtimeVerified requires
/// on-device class-instance capture infrastructure that does not
/// exist yet.
class StreamResourceDetector extends BaseDetector
    with DetectorMetadataProvider {
  StreamResourceDetector({
    required VmServiceClient? vmClient,
    required bool Function() heapGrowingStateProvider,
    DateTime Function()? clock,
    this.sampleSeconds = 10,
    this.minDelta = 50,
    this.warmupSeconds = 20,
    this.pollFailureBackoffSeconds = 60,
    this.cooldownSeconds = 30,
    this.windowSize = 4,
    @visibleForTesting
    Future<AllocationProfile?> Function()? allocationProfileFetcherForTest,
  })  : assert(windowSize >= 2,
            'windowSize must be >= 2 (need at least one transition).'),
        assert(cooldownSeconds >= 0, 'cooldownSeconds must be >= 0.'),
        _vmClient = vmClient,
        _heapGrowingStateProvider = heapGrowingStateProvider,
        _clock = clock ?? DateTime.now,
        _allocationProfileFetcherForTest = allocationProfileFetcherForTest,
        super(
          type: DetectorType.streamResource,
          lifecycle: DetectorLifecycle.vmOnly,
          name: 'Stream Resource',
          description: 'Detects likely retained async resources (streams, '
              'subscriptions, sockets) via AllocationProfile diff',
        );

  /// Polling cadence in seconds — at most one allocation-profile
  /// fetch per this interval.
  final int sampleSeconds;

  /// Minimum sum of per-class net deltas required to emit. Below
  /// this, growth is indistinguishable from normal route-stack churn.
  final int minDelta;

  /// Warmup window in seconds. Suppresses emissions for this duration
  /// after the detector first becomes active. Re-engages on
  /// `isEnabled=false→true`, `vmConnected=false→true`, and
  /// `resetCaptureState()`.
  final int warmupSeconds;

  /// Backoff in seconds applied after 3 consecutive
  /// `getAllocationProfile` failures.
  final int pollFailureBackoffSeconds;

  /// Wall-clock duration the emitted issue persists post-fire. Wall-
  /// clock semantics (rather than poll-cycle counting) survive a
  /// VmService disconnect mid-cooldown without leaving a stale issue
  /// pinned to `_issues` indefinitely. Default 30 s.
  final int cooldownSeconds;

  /// Sample window size (K). Default 4 = 4 samples × 10 s = 40 s of
  /// history. ≥3 of 3 transitions ascending qualifies a class as
  /// "growing". Must be >= 2.
  final int windowSize;

  final VmServiceClient? _vmClient;
  final bool Function() _heapGrowingStateProvider;
  final DateTime Function() _clock;
  final Future<AllocationProfile?> Function()? _allocationProfileFetcherForTest;

  // Hardcoded class-name suffix watchlist. Suffix-match (`endsWith`)
  // shields against dart:async / dart:io private class renames across
  // Flutter SDK versions. Library scope check filters rxdart from
  // unrelated packages.
  static const List<String> _coreSuffixes = <String>[
    'StreamSubscription',
    '_BroadcastSubscription',
    '_ControllerSubscription',
    'StreamController',
    '_SyncBroadcastStreamController',
    '_AsyncBroadcastStreamController',
    '_WebSocketImpl',
    'WebSocketChannel',
  ];

  static const List<String> _rxdartSuffixes = <String>[
    'PublishSubject',
    'BehaviorSubject',
    'ReplaySubject',
  ];

  // Per-suffix sliding window of `instancesCurrent` values.
  final Map<String, List<int>> _perClassWindow = <String, List<int>>{};

  int? _activatedAtMicros;
  int? _lastSampleAtMicros;
  int? _pollPausedUntilMicros;
  int _consecutivePollFailures = 0;
  bool _pollInFlight = false;

  // Bumped on every `_clearRetainedState`. An in-flight poll snapshots
  // this at start; if the value differs at completion, the poll's
  // result is discarded so leg-N-1 sample data cannot leak into
  // leg-N's freshly-cleared `_perClassWindow`.
  int _resetGeneration = 0;

  // Stable identity for cooldown re-emits. Set once at the moment of
  // fresh emission; held across the cooldown window so the controller
  // dedup composite key collapses successive fires to one trace
  // record. Distinct from the sliding `_perClassWindow` start (which
  // advances every sample).
  int? _emissionStartMicros;
  // Wall-clock deadline at which `_lastEmittedIssue` expires. Wall-
  // clock semantics survive a VmService disconnect (or a long poll-
  // failure backoff) without leaving a stale issue pinned to
  // `_issues` until the next non-null poll arrives.
  int? _cooldownExpiresAtMicros;
  PerformanceIssue? _lastEmittedIssue;

  final List<PerformanceIssue> _issues = <PerformanceIssue>[];
  bool _isEnabled = true;

  @override
  List<PerformanceIssue> get issues => List.unmodifiable(_issues);

  @override
  bool get isEnabled => _isEnabled;

  @override
  set isEnabled(bool value) {
    _isEnabled = value;
    if (!value) _clearRetainedState();
  }

  @override
  set vmConnected(bool value) {
    if (!value) _clearRetainedState();
  }

  @override
  void processTimelineData(ParsedTimelineData data) {
    if (!_isEnabled) return;
    final nowMicros = _clock().microsecondsSinceEpoch;

    // Activation/warmup: stamp `_activatedAtMicros` on first eligible
    // tick (NOT in constructor) so a Sleuth instance constructed at
    // app boot but enabled later via config flip still observes a
    // proper warmup window.
    _activatedAtMicros ??= nowMicros;
    if (nowMicros - _activatedAtMicros! < warmupSeconds * 1000000) {
      return;
    }

    // Failure backoff window — skip polling entirely.
    if (_pollPausedUntilMicros != null && nowMicros < _pollPausedUntilMicros!) {
      return;
    }

    // Sample-rate gate. Advance `_lastSampleAtMicros` BEFORE
    // scheduling the async poll so a re-entrant tick within the
    // sample-rate window short-circuits cleanly even if the prior
    // poll has not yet completed.
    if (_lastSampleAtMicros != null &&
        nowMicros - _lastSampleAtMicros! < sampleSeconds * 1000000) {
      return;
    }

    // Re-entrancy guard: a prior async poll is still resolving.
    if (_pollInFlight) return;

    _pollInFlight = true;
    _lastSampleAtMicros = nowMicros;
    // Expire a wall-clock cooldown that lapsed silently (e.g. during a
    // VmService disconnect that ran out the cooldown window without
    // any non-null poll arriving to drain it). Without this, a stale
    // `_lastEmittedIssue` survives in `_issues` past its intended TTL.
    _maybeExpireCooldown(nowMicros);
    unawaited(_pollAllocationProfile());
  }

  Future<void> _pollAllocationProfile() async {
    final pollGeneration = _resetGeneration;
    try {
      AllocationProfile? profile;
      if (_allocationProfileFetcherForTest != null) {
        profile = await _allocationProfileFetcherForTest();
      } else if (_vmClient != null) {
        profile = await _vmClient.getAllocationProfile();
      }
      // Discard results from a generation that has been reset since
      // the poll was scheduled. Without this guard, a poll's post-
      // await continuation can write leg-N-1 sample data into the
      // freshly-cleared `_perClassWindow` of leg-N (capture-mode
      // scenario isolation invariant).
      if (pollGeneration != _resetGeneration) return;
      if (profile == null) {
        _consecutivePollFailures++;
        if (_consecutivePollFailures >= 3) {
          _pollPausedUntilMicros = _clock().microsecondsSinceEpoch +
              pollFailureBackoffSeconds * 1000000;
          _consecutivePollFailures = 0;
        }
        return;
      }
      _consecutivePollFailures = 0;
      _ingestProfile(profile);
      _evaluateWindow();
    } finally {
      _pollInFlight = false;
    }
  }

  void _maybeExpireCooldown(int nowMicros) {
    if (_cooldownExpiresAtMicros != null &&
        nowMicros >= _cooldownExpiresAtMicros!) {
      _dropEmissionState();
    }
  }

  // Clears every emission-state field together so a transient gate
  // failure mid-cooldown cannot leave `_cooldownExpiresAtMicros` set
  // while `_lastEmittedIssue` is null — that combination silences the
  // detector for the remainder of the cooldown window because the
  // drain branch sees a non-null cooldown deadline but a null retained
  // issue and adds nothing to `_issues`.
  void _dropEmissionState() {
    _cooldownExpiresAtMicros = null;
    _emissionStartMicros = null;
    _lastEmittedIssue = null;
    _issues.clear();
  }

  void _ingestProfile(AllocationProfile profile) {
    final members = profile.members;
    if (members == null) return;

    // Per-poll aggregation: sum `instancesCurrent` across every class
    // that maps to the same suffix bucket. Without this aggregation,
    // multiple classes-per-suffix in a single poll (e.g. two app-defined
    // broadcast subscriptions ending in `_BroadcastSubscription`) would
    // each call `window.add(...)`, inflating the window with multiple
    // samples per poll instead of one — corrupting the ascending-
    // transitions check.
    final perPollAggregates = <String, int>{};
    for (final m in members) {
      final classRef = m.classRef;
      if (classRef == null) continue;
      final name = classRef.name;
      if (name == null || name.isEmpty) continue;
      final libUri = classRef.library?.uri;
      final suffix = _matchWatchlist(name, libUri);
      if (suffix == null) continue;
      final instancesCurrent = m.instancesCurrent ?? 0;
      perPollAggregates[suffix] =
          (perPollAggregates[suffix] ?? 0) + instancesCurrent;
    }

    // Append exactly ONE sample per suffix this poll. For suffixes
    // already in `_perClassWindow` but absent from this poll's profile
    // (the leak was fixed and GC reclaimed every instance), append 0
    // so the ascending window ages out — without this, a stale
    // `[100, 130, 160, 190]` window survives forever and re-fires
    // after every cooldown expiry.
    final allSuffixes = <String>{
      ..._perClassWindow.keys,
      ...perPollAggregates.keys,
    };
    for (final suffix in allSuffixes) {
      final count = perPollAggregates[suffix] ?? 0;
      final window = _perClassWindow.putIfAbsent(suffix, () => <int>[]);
      window.add(count);
      while (window.length > windowSize) {
        window.removeAt(0);
      }
    }

    // Drop suffix windows that have been zero for the full window
    // length so the map cannot grow unboundedly across a long session.
    _perClassWindow.removeWhere(
      (_, w) => w.length == windowSize && w.every((v) => v == 0),
    );
  }

  String? _matchWatchlist(String className, String? libUri) {
    // dart:io's `_HttpClientStreamSubscription` ends with
    // `StreamSubscription` and would match the core watchlist purely
    // from in-flight HTTP responses, producing a false-positive on
    // network-heavy apps. Filter to dart:async / dart:io
    // (WebSocket only) / package:web_socket_channel sources.
    //
    // Longest-match semantics: a class named `_SyncBroadcastStreamController`
    // matches both the generic `StreamController` and the specific
    // `_SyncBroadcastStreamController` suffix; first-match would route
    // it to the generic bucket (collapsing distinct controller flavors
    // and shadowing the specific suffixes). Picking the longest matching
    // suffix preserves per-class buckets where the watchlist intends
    // them.
    if (libUri != null && _isCoreLibrary(className, libUri)) {
      final match = _longestMatch(className, _coreSuffixes);
      if (match != null) return match;
    }
    if (libUri != null && libUri.contains('rxdart')) {
      return _longestMatch(className, _rxdartSuffixes);
    }
    return null;
  }

  String? _longestMatch(String className, List<String> suffixes) {
    String? best;
    for (final suffix in suffixes) {
      if (className.endsWith(suffix) &&
          (best == null || suffix.length > best.length)) {
        best = suffix;
      }
    }
    return best;
  }

  bool _isCoreLibrary(String className, String libUri) {
    if (libUri.startsWith('dart:async')) return true;
    if (libUri.startsWith('package:web_socket_channel')) return true;
    // dart:io is included only for WebSocket implementations. The HTTP
    // client's internal `_HttpClientStreamSubscription` self-cancels on
    // response completion and is not a leak — exclude it explicitly.
    if (libUri.startsWith('dart:io')) {
      return className.endsWith('_WebSocketImpl') ||
          className.endsWith('WebSocketChannel');
    }
    return false;
  }

  void _evaluateWindow() {
    final nowMicros = _clock().microsecondsSinceEpoch;
    // Wall-clock cooldown drain: re-emit retained issue with a fresh
    // `detectedAt` (so UI does not show a stale timestamp) but the
    // SAME `dedupIdentityMicros` so the controller composite-key
    // dedup collapses successive fires to one trace record.
    if (_cooldownExpiresAtMicros != null &&
        nowMicros < _cooldownExpiresAtMicros!) {
      if (_lastEmittedIssue != null) {
        _lastEmittedIssue = _lastEmittedIssue!.copyWith(detectedAt: _clock());
        _issues
          ..clear()
          ..add(_lastEmittedIssue!);
      }
      return;
    }
    // Cooldown lapsed; drop the retained issue and fall through to
    // a fresh evaluation.
    if (_cooldownExpiresAtMicros != null) {
      _dropEmissionState();
    }

    final growing = <_GrowingClass>[];
    for (final entry in _perClassWindow.entries) {
      final window = entry.value;
      if (window.length < windowSize) continue;
      var ascendingCount = 0;
      for (var i = 1; i < window.length; i++) {
        if (window[i] > window[i - 1]) ascendingCount++;
      }
      // Require ≥(K-1) ascending transitions. K=4 → 3 of 3.
      if (ascendingCount < windowSize - 1) continue;
      final delta = window.last - window.first;
      if (delta <= 0) continue;
      growing.add(_GrowingClass(suffix: entry.key, delta: delta));
    }

    if (growing.length < 2) {
      _dropEmissionState();
      return;
    }

    final netDelta = growing.fold<int>(0, (sum, g) => sum + g.delta);
    if (netDelta < minDelta) {
      _dropEmissionState();
      return;
    }

    if (!_heapGrowingStateProvider()) {
      _dropEmissionState();
      return;
    }

    growing.sort((a, b) => b.delta.compareTo(a.delta));
    final top = growing.first;
    final suffixes = growing.map((g) => g.suffix).toList(growable: false);

    _emissionStartMicros = _clock().microsecondsSinceEpoch;
    final (hint, effort) = FixHintBuilder.streamResourceGrowth(
      growingClassSuffixes: suffixes,
      topGrowthDelta: top.delta,
    );
    _lastEmittedIssue = PerformanceIssue(
      stableId: 'stream_resource_growth',
      severity: IssueSeverity.warning,
      category: IssueCategory.memory,
      confidence: IssueConfidence.likely,
      title: 'Stream Resources Growing: '
          '${growing.length} classes, +$netDelta instances',
      detail: 'Watchlist async resource classes are accumulating across '
          'the sample window AND `heap_growing` is currently active. '
          'Top growth: ${top.suffix} (+${top.delta} instances). '
          'Other growing classes: ${suffixes.skip(1).take(3).join(', ')}. '
          'This pattern suggests retained subscriptions, undisposed '
          'StreamControllers, or open WebSocket channels — confirm by '
          'auditing dispose/cancel paths in recently navigated routes. '
          'Confidence is "likely" rather than "confirmed" because the '
          'VM cannot prove ownership intent — class growth alone is '
          'circumstantial evidence.',
      fixHint: hint,
      fixEffort: effort,
      observationSource: ObservationSource.vmTimeline,
      detectedAt: _clock(),
      dedupIdentityMicros: _emissionStartMicros,
      extraTraceArgs: <String, String>{
        'topGrowthClass': top.suffix,
        'topGrowthDelta': top.delta.toString(),
        'watchlistClassesGrowing': suffixes.join(','),
        'samplesInWindow': windowSize.toString(),
      },
      confidenceReason: 'Allocation profile diff + heap_growing co-fire',
    );
    _issues
      ..clear()
      ..add(_lastEmittedIssue!);
    _cooldownExpiresAtMicros =
        _emissionStartMicros! + cooldownSeconds * 1000000;
  }

  /// Clear all per-scenario state. Called on `Sleuth.markScenarioBegin`
  /// via `SleuthController.resetCaptureState`.
  void resetCaptureState() {
    _clearRetainedState();
  }

  void _clearRetainedState() {
    _resetGeneration++;
    _perClassWindow.clear();
    _activatedAtMicros = null;
    _lastSampleAtMicros = null;
    _pollPausedUntilMicros = null;
    _consecutivePollFailures = 0;
    _emissionStartMicros = null;
    _cooldownExpiresAtMicros = null;
    _lastEmittedIssue = null;
    _issues.clear();
    // _pollInFlight intentionally NOT reset — the in-flight future
    // will set it back to false in its own `finally`. Forcing it
    // false here would race with the resolution.
  }

  @override
  void dispose() {
    _clearRetainedState();
  }

  @override
  DetectorMetadata get validationMetadata => const DetectorMetadata(
        tier: EvidenceTier.reproducerOnly,
        rationale: 'VM-only detector. Heuristic flag for retained async '
            'resources (streams, subscriptions, sockets) via '
            '`getAllocationProfile` class-instance diff over a K=4 '
            'sample window, gated on a recent `heap_growing` emission. '
            'Watchlist matches dart:async, dart:io, and '
            'web_socket_channel class-name suffixes (suffix match '
            'shields against private-class renames across Flutter SDK '
            'versions); rxdart Subject family is included only when '
            '`classRef.library.uri` contains `rxdart`. Emission '
            'requires (a) `MemoryPressureDetector.isHeapGrowingActive` '
            'returns true within the recency window (default 30 s), '
            '(b) ≥2 watchlist classes show ≥3 of 3 ascending '
            'transitions across the window, and (c) sum of per-class '
            'net deltas exceeds the configured threshold (default 50 '
            'instances). Confidence is `likely`: runtime allocation-'
            'profile evidence is circumstantial — class growth alone '
            'cannot prove ownership intent. A 3-cycle cooldown holds '
            'the emission stable across multiple polls so the '
            'producer-side dedup composite key collapses successive '
            'fires to one trace record. Tier raise to runtimeVerified '
            'is deferred until on-device class-instance capture '
            'infrastructure exists; the current schema brackets '
            'detector emissions on a single observed-axis numeric '
            'magnitude (ms, bytes/sec, count) and does not yet model '
            'the multi-class delta axis this detector operates on.',
        reproducerPath: 'test/validation/stream_resource_reproducer_test.dart',
        coveredStableIds: {'stream_resource_growth'},
      );
}

class _GrowingClass {
  const _GrowingClass({required this.suffix, required this.delta});
  final String suffix;
  final int delta;
}
