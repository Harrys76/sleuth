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

/// Diagnostic result of a single allocation-profile poll triggered by
/// [StreamResourceDetector.pollAllocationProfileNow]. Capture screens
/// log this every poll so an empty K=4 window can be diagnosed
/// without a second 50-second on-device session.
///
/// [errorReason] values when [succeeded] is false:
/// `'disabled'` (detector off), `'no_vm_client'` (no fetcher and no
/// VM service), `'rpc_null'` (RPC returned null — timeout, sentinel,
/// or caught exception), `'reset_during_poll'` (capture state cleared
/// mid-poll, result discarded).
@immutable
class StreamResourcePollResult {
  const StreamResourcePollResult({
    required this.succeeded,
    this.memberCount,
    this.matchedCount,
    this.droppedNullLibUriCount,
    this.sampleWindowSize,
    this.rpcElapsed,
    this.errorReason,
    this.skippedInFlight = false,
    this.bucketStates,
  });

  /// Profile fetched, members iterated, window updated. False when
  /// [errorReason] is set.
  final bool succeeded;

  /// `profile.members.length` on success. null on failure.
  final int? memberCount;

  /// Number of members whose class matched the watchlist this poll.
  final int? matchedCount;

  /// Number of members dropped because `classRef.library` was null AND
  /// the class name didn't match a private-suffix fallback (capture
  /// procedure indicator: high counts here suggest the watchlist's
  /// `_privateCoreSuffixes` is incomplete relative to current Dart SDK).
  final int? droppedNullLibUriCount;

  /// Maximum sample count across all per-class windows after this
  /// poll's ingestion. Reaches `windowSize` (default 4) once at least
  /// one watchlist class has been observed across all K samples.
  final int? sampleWindowSize;

  /// Wall-clock duration of the `getAllocationProfile` RPC call.
  final Duration? rpcElapsed;

  /// Failure category when [succeeded] is false.
  final String? errorReason;

  /// True when an automatic poll was already in flight; the explicit
  /// caller awaited it instead of starting its own (barrier semantics).
  /// The result reflects the awaited poll's outcome.
  final bool skippedInFlight;

  /// Snapshot of per-suffix sliding window after this poll's ingest.
  /// Keys are watchlist suffixes (e.g. `_BroadcastSubscription`,
  /// `StreamSubscription`); values are the most-recent-N
  /// `instancesCurrent` aggregates with N up to `windowSize`. Empty
  /// when no class matched. Capture screens use this to diagnose why
  /// a leg's K=4 window contains stable counts (workload allocations
  /// not landing in any expected bucket — suggests AOT class-name
  /// drift or GC reclaiming unreferenced subscriptions).
  final Map<String, List<int>>? bucketStates;

  @override
  String toString() {
    if (!succeeded) {
      return 'StreamResourcePollResult(failed: $errorReason'
          '${skippedInFlight ? ", skipped_in_flight" : ""}'
          '${rpcElapsed != null ? ", rpc=${rpcElapsed!.inMilliseconds}ms" : ""})';
    }
    final buckets = bucketStates;
    final bucketsStr = (buckets == null || buckets.isEmpty)
        ? ''
        : ', buckets={${buckets.entries.map((e) => "${e.key}:${e.value}").join(", ")}}';
    return 'StreamResourcePollResult(ok, members=$memberCount, '
        'matched=$matchedCount, droppedNullLib=$droppedNullLibUriCount, '
        'samples=$sampleWindowSize'
        '${rpcElapsed != null ? ", rpc=${rpcElapsed!.inMilliseconds}ms" : ""}'
        '${skippedInFlight ? ", awaited_in_flight" : ""}'
        '$bucketsStr)';
  }
}

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
/// (c) the dominant growing class's net delta exceeds
///     [DetectorThresholds.streamResourceMinDelta] (single-class
///     magnitude gate; multi-class growth in (b) is a structural
///     confidence escalator only).
///
/// Confidence is `IssueConfidence.likely` — runtime allocation-
/// profile evidence + structural watchlist + runtime co-fire.
/// Base tier `reproducerOnly`; `stream_resource_growth.warning`
/// raised to runtimeVerified via `perStableIdTier` on top of three
/// on-device captures.
class StreamResourceDetector extends BaseDetector
    with DetectorMetadataProvider {
  StreamResourceDetector({
    required VmServiceClient? Function() vmClientProvider,
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
        _vmClientProvider = vmClientProvider,
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

  /// Minimum dominant-class net delta to emit. Gates on the largest
  /// growing class (`growing.first` after descending sort) so the
  /// bracketed axis (`topGrowthDelta`) matches the firing axis. The
  /// ≥2-classes-growing precondition is structural, not part of the
  /// magnitude.
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

  // Lazy getter so the detector observes the live `VmServiceClient`
  // reference held by the controller. Direct injection at construction
  // time would capture null because `_initializeDetectors()` runs
  // before the controller assigns its `_vmClient` field.
  final VmServiceClient? Function() _vmClientProvider;
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

  // Subset of `_coreSuffixes` that are PRIVATE (start with `_`). When
  // the VM's `getAllocationProfile` reports a class with `library == null`
  // (Dart 3.6+ AOT does this for private dart:async classes), the
  // library-URI scope check in `_matchWatchlist` cannot run — we accept
  // the match anyway IF the suffix is in this private list. Public
  // suffixes (`StreamSubscription`, `StreamController`, `WebSocketChannel`)
  // still require a non-null libUri because app-defined subclasses ending
  // in those names are common and would false-positive without library
  // scoping.
  static const List<String> _privateCoreSuffixes = <String>[
    '_BroadcastSubscription',
    '_ControllerSubscription',
    '_SyncBroadcastStreamController',
    '_AsyncBroadcastStreamController',
    '_WebSocketImpl',
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

  // Future of the currently-resolving poll, or null when no poll is in
  // flight. Both the automatic poll path (driven by `processTimelineData`)
  // AND the explicit capture-pipeline path (`pollAllocationProfileNow`)
  // store/await this. Without barrier semantics, the explicit path's
  // `if (_pollInFlight) return` could silently no-op when the auto-path
  // grabbed the slot moments earlier — capture screen advances thinking
  // the poll succeeded, but no fresh sample lands.
  Future<StreamResourcePollResult>? _pollInFlight;

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

  // Monotonic per-detector emission sequence. Incremented on every
  // fresh emission (NOT on cooldown re-emits — those preserve the
  // dedup identity). Stamped into `extraTraceArgs.dedupIdentitySeq` so
  // BracketSpec's `requireUniqueDetectedAtMicros` can cross-check that
  // the 3 capture legs come from distinct emissions, not one emission
  // replayed across the cooldown window.
  int _emissionSeq = 0;

  // Last observed top-class delta within the K=4 window, set on every
  // window evaluation (regardless of whether emission fired). Capture-
  // pipeline accessor for cross-checking the emission axis against the
  // captured BracketSpec axis arg.
  int? _lastObservedTopGrowthDelta;
  String? _lastObservedTopGrowthClass;
  int _lastObservedSamplesInWindow = 0;

  /// Last delta of the dominant growing class within the K=4 window,
  /// or null if no classes have hit `windowSize` yet. Updated on every
  /// poll regardless of whether emission fires.
  int? get lastObservedTopGrowthDelta => _lastObservedTopGrowthDelta;

  /// Class-name suffix of the dominant growing class, or null.
  String? get lastObservedTopGrowthClass => _lastObservedTopGrowthClass;

  /// Maximum sample count any tracked class has accumulated within the
  /// current window. Reaches `windowSize` (4) when at least one class
  /// has been observed across all K samples — the capture screen uses
  /// this to gate next-leg activation.
  int get lastObservedSamplesInWindow => _lastObservedSamplesInWindow;

  /// Synchronously re-run the window evaluation against the current
  /// `_perClassWindow` snapshot, without waiting for the next 10 s
  /// poll tick. Capture-pipeline hook: `markScenarioBegin` →
  /// workload → `flushTimelineNow()` → `flushStreamResourceEvaluation()`
  /// → `markScenarioEnd()` → `composeCapture()`. Emission state is
  /// updated as if a real poll had completed; cooldown semantics
  /// apply normally.
  void flushStreamResourceEvaluation() {
    if (!isEnabled) return;
    _evaluateWindow();
  }

  /// Capture-pipeline hook: trigger an immediate `getAllocationProfile`
  /// RPC and ingest the result, bypassing the timeline-tick gate that
  /// drives [processTimelineData]. The capture screen calls this once
  /// per intended K=4 sample so the window populates regardless of
  /// whether the VM timeline buffer is producing parseable events.
  ///
  /// Returns a [StreamResourcePollResult] capturing the outcome —
  /// success/failure, member count, matched count, RPC duration. The
  /// capture screen logs this every poll so an empty K=4 window can
  /// be diagnosed without another blind capture session.
  ///
  /// **Barrier semantics.** If an automatic poll is already in flight
  /// (driven by [processTimelineData] from `VmServiceClient`'s 500 ms
  /// timer), this call awaits that poll's completion AND THEN runs a
  /// guaranteed fresh poll. Without this barrier, the explicit call
  /// would silently no-op behind the auto-path, and the capture screen
  /// would advance thinking it captured a sample.
  ///
  /// Bypasses the warmup gate (the capture flow has its own heap-
  /// pressure precondition) and the sample-rate gate (the caller is
  /// responsible for spacing calls ≥ [sampleSeconds] apart). Honors
  /// the `isEnabled` guard — returns a `disabled` result without
  /// running anything when the detector is off.
  Future<StreamResourcePollResult> pollAllocationProfileNow() async {
    if (!_isEnabled) {
      return const StreamResourcePollResult(
        succeeded: false,
        errorReason: 'disabled',
      );
    }
    final inFlight = _pollInFlight;
    if (inFlight != null) {
      // Wait for the auto-path's poll to finish, then run a fresh one
      // so the capture caller is guaranteed to see a post-await sample.
      await inFlight;
    }
    _lastSampleAtMicros = _clock().microsecondsSinceEpoch;
    _activatedAtMicros ??= _lastSampleAtMicros;
    _maybeExpireCooldown(_lastSampleAtMicros!);
    final freshPoll = _pollAllocationProfile();
    _pollInFlight = freshPoll;
    return freshPoll;
  }

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
    if (_pollInFlight != null) return;

    _lastSampleAtMicros = nowMicros;
    // Expire a wall-clock cooldown that lapsed silently (e.g. during a
    // VmService disconnect that ran out the cooldown window without
    // any non-null poll arriving to drain it). Without this, a stale
    // `_lastEmittedIssue` survives in `_issues` past its intended TTL.
    _maybeExpireCooldown(nowMicros);
    final autoPoll = _pollAllocationProfile();
    _pollInFlight = autoPoll;
    unawaited(autoPoll);
  }

  Future<StreamResourcePollResult> _pollAllocationProfile() async {
    final pollGeneration = _resetGeneration;
    final stopwatch = Stopwatch()..start();
    try {
      AllocationProfile? profile;
      final vmClient = _vmClientProvider();
      if (_allocationProfileFetcherForTest != null) {
        profile = await _allocationProfileFetcherForTest();
      } else if (vmClient != null) {
        // Capture mode benefits from a longer timeout: first iPhone
        // call enumerates thousands of classes and easily exceeds
        // the default 500ms. The detector has no signal that it's
        // running under capture vs. ambient monitoring, so we use a
        // generous fixed 5s — non-capture polls only run every
        // [sampleSeconds] anyway, and the auto-path's
        // `_consecutivePollFailures` backoff still protects against
        // a permanently broken VM.
        profile = await vmClient.getAllocationProfile(
          timeout: const Duration(seconds: 5),
        );
      } else {
        stopwatch.stop();
        return StreamResourcePollResult(
          succeeded: false,
          errorReason: 'no_vm_client',
          rpcElapsed: stopwatch.elapsed,
        );
      }
      stopwatch.stop();
      // Discard results from a generation that has been reset since
      // the poll was scheduled. Without this guard, a poll's post-
      // await continuation can write leg-N-1 sample data into the
      // freshly-cleared `_perClassWindow` of leg-N (capture-mode
      // scenario isolation invariant).
      if (pollGeneration != _resetGeneration) {
        return StreamResourcePollResult(
          succeeded: false,
          errorReason: 'reset_during_poll',
          rpcElapsed: stopwatch.elapsed,
        );
      }
      if (profile == null) {
        _consecutivePollFailures++;
        if (_consecutivePollFailures >= 3) {
          _pollPausedUntilMicros = _clock().microsecondsSinceEpoch +
              pollFailureBackoffSeconds * 1000000;
          _consecutivePollFailures = 0;
        }
        return StreamResourcePollResult(
          succeeded: false,
          errorReason: 'rpc_null',
          rpcElapsed: stopwatch.elapsed,
        );
      }
      _consecutivePollFailures = 0;
      final ingested = _ingestProfile(profile);
      _evaluateWindow();
      // Snapshot per-suffix windows so capture screens can see exactly
      // which buckets matched and how their counts evolved across polls.
      // A flat constant (e.g. `[18, 18, 18, 18]`) on every poll despite
      // a workload that should grow allocations means the workload's
      // class isn't landing in this bucket — either AOT renamed the
      // class, GC reclaimed the instances, or the watchlist suffix is
      // stale relative to the current Dart SDK.
      final bucketSnapshot = <String, List<int>>{
        for (final e in _perClassWindow.entries)
          e.key: List<int>.unmodifiable(e.value),
      };
      return StreamResourcePollResult(
        succeeded: true,
        memberCount: ingested.memberCount,
        matchedCount: ingested.matchedCount,
        droppedNullLibUriCount: ingested.droppedNullLibUriCount,
        sampleWindowSize: _lastObservedSamplesInWindow,
        rpcElapsed: stopwatch.elapsed,
        bucketStates: bucketSnapshot,
      );
    } finally {
      _pollInFlight = null;
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

  _IngestStats _ingestProfile(AllocationProfile profile) {
    final members = profile.members;
    if (members == null) {
      return const _IngestStats(
        memberCount: 0,
        matchedCount: 0,
        droppedNullLibUriCount: 0,
      );
    }

    // Per-poll aggregation: sum `instancesCurrent` across every class
    // that maps to the same suffix bucket. Without this aggregation,
    // multiple classes-per-suffix in a single poll (e.g. two app-defined
    // broadcast subscriptions ending in `_BroadcastSubscription`) would
    // each call `window.add(...)`, inflating the window with multiple
    // samples per poll instead of one — corrupting the ascending-
    // transitions check.
    final perPollAggregates = <String, int>{};
    var matched = 0;
    var droppedNullLibUri = 0;
    for (final m in members) {
      final classRef = m.classRef;
      if (classRef == null) continue;
      final name = classRef.name;
      if (name == null || name.isEmpty) continue;
      final libUri = classRef.library?.uri;
      final suffix = _matchWatchlist(name, libUri);
      if (suffix == null) {
        // Track classes that look watchlist-relevant (suffix matches a
        // public core suffix) but were dropped because libUri was null
        // and no private fallback applied. High counts here indicate
        // `_privateCoreSuffixes` is missing entries the current Dart
        // SDK reports without library metadata.
        if (libUri == null && _looksLikeCoreClass(name)) {
          droppedNullLibUri++;
        }
        continue;
      }
      matched++;
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

    return _IngestStats(
      memberCount: members.length,
      matchedCount: matched,
      droppedNullLibUriCount: droppedNullLibUri,
    );
  }

  // Heuristic for diagnostic counting only: does the class name end
  // with any watchlist suffix (public OR private)? Used to count
  // null-libUri members that look core-relevant but were dropped
  // because the private-suffix fallback didn't recognise them. NOT
  // used for matching — emits-eligibility goes through `_matchWatchlist`.
  bool _looksLikeCoreClass(String name) {
    for (final suffix in _coreSuffixes) {
      if (name.endsWith(suffix)) return true;
    }
    return false;
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
    // Null-library fallback: AOT VMs (Flutter 3.6+ on iPhone profile
    // mode) often report `ClassRef.library = null` for private
    // dart:async classes. Without this branch, every relevant
    // `_BroadcastSubscription` / `_ControllerSubscription` / similar
    // member is silently dropped on real devices, leaving the K=4
    // window empty even when the workload is legitimate. Restricted
    // to PRIVATE suffixes — public suffixes (`StreamSubscription`,
    // `StreamController`) without library scoping would falsely match
    // app-defined subclasses.
    if (libUri == null) {
      final match = _longestMatch(className, _privateCoreSuffixes);
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
    var maxSamplesObserved = 0;
    for (final entry in _perClassWindow.entries) {
      final window = entry.value;
      if (window.length > maxSamplesObserved) {
        maxSamplesObserved = window.length;
      }
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
    _lastObservedSamplesInWindow = maxSamplesObserved;

    // Update observed-delta accessors on EVERY evaluation, regardless
    // of whether emission gates pass. Capture screens display this so
    // the operator can see actual measured growth even on the below-
    // bracket leg (which intentionally fails the minDelta gate). When
    // no class is growing, both fields go null so a broken poll path
    // produces visibly distinct evidence (`samples=0, Δ=null`) from a
    // legitimate sub-threshold workload (`samples=4, Δ=25`).
    if (growing.isNotEmpty) {
      growing.sort((a, b) => b.delta.compareTo(a.delta));
      _lastObservedTopGrowthDelta = growing.first.delta;
      _lastObservedTopGrowthClass = growing.first.suffix;
    } else {
      _lastObservedTopGrowthDelta = null;
      _lastObservedTopGrowthClass = null;
    }

    if (growing.length < 2) {
      _dropEmissionState();
      return;
    }

    // `growing` already sorted descending by the
    // `_lastObservedTopGrowthDelta` update above.
    final top = growing.first;
    if (top.delta < minDelta) {
      _dropEmissionState();
      return;
    }

    if (!_heapGrowingStateProvider()) {
      _dropEmissionState();
      return;
    }

    final netDelta = growing.fold<int>(0, (sum, g) => sum + g.delta);
    final suffixes = growing.map((g) => g.suffix).toList(growable: false);

    _emissionStartMicros = _clock().microsecondsSinceEpoch;
    _emissionSeq++;
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
          '${top.suffix} +${top.delta} instances '
          '(${growing.length} classes, $netDelta total)',
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
        'detectedAtMicros': _emissionStartMicros!.toString(),
        'dedupIdentitySeq': _emissionSeq.toString(),
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
    _emissionSeq = 0;
    _lastObservedTopGrowthDelta = null;
    _lastObservedTopGrowthClass = null;
    _lastObservedSamplesInWindow = 0;
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
        rationale: 'VM-only detector. Flags retained async resources '
            '(streams, subscriptions, sockets) via `getAllocationProfile` '
            'class-instance diff over a K=4 sample window, gated on a '
            'recent `heap_growing` emission. Watchlist suffix-matches '
            'dart:async / dart:io / web_socket_channel class names '
            '(shields against private-class renames across SDK versions); '
            'rxdart Subjects included only when `classRef.library.uri` '
            'contains `rxdart`. Emission requires (a) `isHeapGrowingActive` '
            'true within recency window (default 30 s), (b) ≥2 watchlist '
            'classes show ≥3 of 3 ascending transitions (structural '
            'precondition), (c) the dominant growing class\'s net delta '
            '> `streamResourceMinDelta` (default 50). Single-class '
            'magnitude gate so the firing axis matches the bracketed '
            'axis (`extraTraceArgs.topGrowthDelta`). Confidence `likely` '
            '— class growth alone is circumstantial. 3-cycle cooldown '
            'collapses successive fires to one trace record via '
            'producer-side dedup keyed on `_emissionStartMicros`.\n'
            '\n'
            '`stream_resource_growth.warning` is runtimeVerified via '
            '`perStableIdTier`, backed by three iPhone 12 / iOS 17.5 / '
            'Flutter 3.41.4 captures bracketing threshold 50 instances. '
            'atTolerance 0.6 (at-band [50, 80]); aboveCeilingMultiplier '
            '3.0 (ceiling 150) — wider than NetworkMonitor / Repaint to '
            'absorb in-scenario heap_growing readiness-wait variance. '
            'Single-family detector — no critical tier, ceiling set by '
            'schema sanity bound. `requireUniqueDetectedAtMicros: true`.',
        reproducerPath: 'test/validation/stream_resource_reproducer_test.dart',
        coveredStableIds: {'stream_resource_growth'},
        perStableIdTier: {
          'stream_resource_growth': EvidenceTier.runtimeVerified,
        },
        coveredThresholds: {'stream_resource_growth.warning'},
        profileCapturePaths: [
          'test/validation/captures/stream_resource_growth/below.json',
          'test/validation/captures/stream_resource_growth/at.json',
          'test/validation/captures/stream_resource_growth/above.json',
        ],
        bracketStableId: 'stream_resource_growth',
        bracketSeverityLabel: 'warning',
        bracketThreshold: 50,
        bracketUnit: 'instances',
        bracketAtTolerance: 0.6,
        aboveCeilingMultiplier: 3.0,
        observedAxisArgKey: 'topGrowthDelta',
        bracketRequireUniqueDetectedAtMicros: true,
      );
}

class _IngestStats {
  const _IngestStats({
    required this.memberCount,
    required this.matchedCount,
    required this.droppedNullLibUriCount,
  });
  final int memberCount;
  final int matchedCount;
  final int droppedNullLibUriCount;
}

class _GrowingClass {
  const _GrowingClass({required this.suffix, required this.delta});
  final String suffix;
  final int delta;
}
