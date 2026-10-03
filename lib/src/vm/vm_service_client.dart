import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math' as math;
import 'dart:io' show ProcessInfo;
import 'package:flutter/foundation.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';
import '../models/heap_sample.dart';
import 'poll_timings.dart';
import 'timeline_parser.dart';

/// Read current process RSS in bytes. Returns null on platforms where
/// [ProcessInfo] is unavailable (web, unusual embeddings).
int? _readRssBytes() {
  try {
    return ProcessInfo.currentRss;
  } catch (_) {
    return null;
  }
}

/// Callback type for receiving parsed timeline data.
typedef TimelineDataCallback = void Function(ParsedTimelineData data);

/// Callback type for receiving VM events (GC, etc.).
typedef VmEventCallback = void Function(Event event);

/// Callback type for receiving heap memory samples.
typedef HeapSampleCallback = void Function(HeapSample sample);

/// Callback type for one-shot startup timeline event extraction.
typedef StartupTimelineCallback = void Function(StartupTimelineEvents events);

/// Connects to the app's own VM Service for exact performance data.
///
/// Uses [dart:developer.Service.controlWebServer] to start/query the
/// VM web server and connects via WebSocket. Works reliably on desktop
/// and simulators. On real iOS devices launched via IDE (USB bridge) or
/// Android with adb-forwarded ports, the reported URI may be unreachable
/// from the device — in that case the controller falls back to BASIC mode
/// (FrameTiming + structural analysis).
class VmServiceClient {
  VmServiceClient({
    this.onTimelineData,
    this.onGcEvent,
    this.idleHeartbeat = const Duration(seconds: 1),
    this.onHeapSample,
    this.onExtensionEvent,
    this.onConnectionChanged,
    this.onStartupTimelineEvents,
    this.retainTimeline = false,
  });

  /// Whether a later [fetchRawTimelineEventsJson] export relies on the
  /// VM keeping already-polled events (capture mode).
  ///
  /// The poll loop never clears the VM timeline: after the first poll of
  /// a session it fetches only a window that starts
  /// [TimelineParser.maxReconstructedPhaseUs] before the newest event it
  /// has seen, so the retained buffer is not re-read and the VM's
  /// bounded ring buffer costs no app memory. The flag therefore only
  /// records the export expectation. The ring buffer still drops its
  /// oldest events under load (Dart trace buffer default ~5 MB), so
  /// capture screens should export within ~30 s of `markScenarioEnd`.
  final bool retainTimeline;

  final TimelineDataCallback? onTimelineData;
  final VmEventCallback? onGcEvent;

  /// How often [onTimelineData] is still called while the timeline is
  /// quiet. Detectors that evaluate on a wall-clock window (the platform
  /// channel detector's 1 s window, persistence timers) only run inside
  /// that callback; on a static screen with no frames and no GC the VM
  /// returns empty batches, and without this tick a burst that landed in
  /// the last batch would be judged only when the next unrelated event
  /// arrived. The empty batch carries no events, so detectors see it as
  /// an idle window.
  final Duration idleHeartbeat;

  DateTime? _lastTimelineDispatchAt;
  final HeapSampleCallback? onHeapSample;
  final VmEventCallback? onExtensionEvent;
  final void Function(bool connected)? onConnectionChanged;

  /// One-shot callback for engine-level startup events extracted from the
  /// VM timeline ring buffer on the first poll. Called at most once.
  final StartupTimelineCallback? onStartupTimelineEvents;

  VmService? _service;

  /// Failed polls in a row. A VM under GC pressure can fail one timeline
  /// RPC without the socket being gone; declaring a disconnect on the
  /// first failure cleared every detector's VM state (the memory
  /// detector's windows took tens of seconds to refill) for a blip that
  /// the next poll would have survived. The connection is reported lost
  /// after [pollFailuresBeforeDisconnect] consecutive failures, or at
  /// once when the socket's `onDone` completes.
  int _consecutivePollFailures = 0;

  /// Consecutive failed polls (500 ms apart) before the connection is
  /// reported lost.
  static const int pollFailuresBeforeDisconnect = 3;
  StreamSubscription<Event>? _timelineSub;
  StreamSubscription<Event>? _gcSub;
  StreamSubscription<Event>? _extensionSub;
  Timer? _pollTimer;
  bool _disposed = false;
  bool _connected = false;

  /// One-shot guard — startup events are only extracted on the first poll.
  bool _startupEventsExtracted = false;
  bool _reconnecting = false;

  /// In-flight [connect] future. While non-null, additional [connect] calls
  /// return the same future instead of starting a second attempt in parallel
  /// — this is the guard that prevents the controller's background reconnect
  /// loop from racing with a user-triggered [reconnect] and leaking duplicate
  /// poll timers / service instances.
  Future<bool>? _connectInFlight;

  /// Cancellable timeout guard for the controlWebServer() call. See
  /// [_connectImpl] — we can't use `Future.timeout()` directly because the
  /// native controlWebServer future may never complete in test environments
  /// (FakeAsync doesn't drive it), which would leave `Future.timeout`'s
  /// internal Timer pending at widget dispose and trip the test framework's
  /// `A Timer is still pending` assertion. Owning the timer ourselves lets
  /// [dispose] cancel it cleanly.
  Timer? _controlWebServerTimer;

  /// Cached main isolate ID, resolved during [connect].
  String? _mainIsolateId;

  /// Whether the VM service is connected and streaming data.
  bool get isConnected => _connected;

  /// Test-only view of the resolved main isolate id.
  @visibleForTesting
  String? get mainIsolateIdForTest => _mainIsolateId;

  /// Whether the client has been disposed.
  bool get isDisposed => _disposed;

  /// Test-only: inject a mock VmService and isolate ID to test polling/CPU paths.
  @visibleForTesting
  void setServiceForTest(VmService service, {String? isolateId}) {
    _service = service;
    _watchSocket(service);
    _attachWireListeners(service);
    _mainIsolateId = isolateId;
    _connected = true;
  }

  /// Attempt to connect to the VM service with retry logic.
  ///
  /// Retries [maxRetries] times with [retryDelay] between attempts.
  /// Returns `true` if connected, `false` if all retries exhausted.
  ///
  /// **Concurrency**: if a prior [connect] is already in flight, this call
  /// joins it and returns the same future instead of starting a second
  /// attempt. That prevents the background reconnect loop and user-triggered
  /// [reconnect] from racing into duplicate poll timers / service instances.
  Future<bool> connect({
    int maxRetries = 3,
    Duration retryDelay = const Duration(milliseconds: 500),
  }) {
    final existing = _connectInFlight;
    if (existing != null) return existing;
    final future = _connectImpl(maxRetries: maxRetries, retryDelay: retryDelay);
    _connectInFlight = future;
    // Clear the slot when this attempt resolves, but only if it's still ours.
    future.whenComplete(() {
      if (identical(_connectInFlight, future)) _connectInFlight = null;
    });
    return future;
  }

  Future<bool> _connectImpl({
    required int maxRetries,
    required Duration retryDelay,
  }) async {
    if (kReleaseMode || _disposed) return false;

    for (var attempt = 0; attempt <= maxRetries; attempt++) {
      try {
        // Use controlWebServer(enable: true) rather than getInfo() so we
        // proactively *start* the VM web server if it's dormant. Service.getInfo()
        // only queries state — if the server hasn't bound its port yet (common
        // on cold start, especially Android adb-forwarded ports) it returns
        // a null serverUri and we'd have to poll-spin until the framework got
        // around to starting it. controlWebServer forces the bind and returns
        // a fully-populated ServiceProtocolInfo in one shot.
        //
        // **Timeout**: on some cold-start scenarios (Android Studio first
        // launch, embedder quirks) this call can block indefinitely instead
        // of failing fast. A 3 s bailout converts that hang into a normal
        // catch so the retry loop and, ultimately, the controller's
        // background reconnect ladder can take over. Without it,
        // initialize() never returns and Sleuth stays in FRAME mode forever.
        //
        // We can't use `Future.timeout()` here: in widget-test environments
        // the native controlWebServer future never completes, and
        // `Future.timeout` leaves its internal Timer pending until the fake
        // clock advances 3 s — which tripps the `A Timer is still pending`
        // assertion at widget dispose. Owning the timer ourselves lets
        // [dispose] cancel it before the invariant check runs.
        final completer = Completer<developer.ServiceProtocolInfo>();
        _controlWebServerTimer?.cancel();
        final timeoutTimer = Timer(const Duration(seconds: 3), () {
          if (!completer.isCompleted) {
            completer.completeError(
              TimeoutException(
                'Service.controlWebServer did not return within 3s',
                const Duration(seconds: 3),
              ),
            );
          }
        });
        _controlWebServerTimer = timeoutTimer;
        developer.Service.controlWebServer(
          enable: true,
          silenceOutput: true,
        ).then(
          (i) {
            if (!completer.isCompleted) completer.complete(i);
          },
          onError: (Object e, StackTrace st) {
            if (!completer.isCompleted) completer.completeError(e, st);
          },
        );
        developer.ServiceProtocolInfo info;
        try {
          info = await completer.future;
        } finally {
          timeoutTimer.cancel();
          if (identical(_controlWebServerTimer, timeoutTimer)) {
            _controlWebServerTimer = null;
          }
        }
        if (_disposed) return false;
        final uri = info.serverUri;

        if (uri == null) {
          if (attempt < maxRetries) {
            await Future<void>.delayed(retryDelay);
            if (_disposed) return false;
            continue;
          }
          return false;
        }

        // Prefer the SDK-provided WebSocket URI builder (handles pathSegments
        // and scheme rewrite correctly, available since Dart 2.14). Fall back
        // to our hand-rolled helper only if the getter returns null.
        var wsUri = info.serverWebSocketUri ?? _toWebSocketUri(uri);

        // Loopback first, reported host second (see
        // [candidateWebSocketUris]). Each attempt has its own timeout so an
        // unreachable address (host-forwarded on Android, a LAN address on
        // a wirelessly launched iOS app) fails fast.
        VmService? connected;
        Object? lastError;
        for (final candidate in candidateWebSocketUris(wsUri)) {
          try {
            connected = await vmServiceConnectUri(
              candidate.toString(),
            ).timeout(const Duration(seconds: 3));
            break;
          } catch (e) {
            lastError = e;
          }
        }
        if (connected == null) {
          throw lastError ?? StateError('no VM service address connected');
        }
        _service = connected;
        _watchSocket(connected);
        _attachWireListeners(connected);
        if (_disposed) {
          _cleanup();
          return false;
        }

        // Enable timeline streams for framework events
        await _service!.setVMTimelineFlags(['Dart', 'Embedder', 'GC']);

        // Resolve main isolate ID for getMemoryUsage() polling
        _mainIsolateId = await _resolveMainIsolateId();
        if (_disposed) {
          _cleanup();
          return false;
        }

        // Subscribe to event streams
        await _subscribeToStreams();
        if (_disposed) {
          _cleanup();
          return false;
        }

        // Start periodic timeline polling
        _startTimelinePolling();

        _connected = true;
        onConnectionChanged?.call(true);
        return true;
      } catch (_) {
        if (attempt < maxRetries) {
          await Future<void>.delayed(retryDelay);
          if (_disposed) return false;
        }
      }
    }
    return false;
  }

  /// Reconnect with exponential backoff: 1s → 2s → 4s → 8s → 16s
  /// (cumulative ~31s before giving up).
  ///
  /// Pre-v0.16.0 this ladder stopped at 4s (7s cumulative), which was
  /// shorter than the 30s window documented in CLAUDE.md and too
  /// impatient for cold-start scenarios on Android emulators where the
  /// VM service socket can take ~10–20s to bind. C3 fix: extend the
  /// ladder to match the documented window.
  Future<bool> reconnect() async {
    if (_reconnecting || _disposed) return false;

    // If a [connect] is already in flight (e.g., kicked off by the
    // controller's background reconnect loop), join it rather than starting
    // a second attempt that would race [_cleanup] against its state writes.
    // If that attempt succeeds we're done; if it fails we fall through to
    // a full cleanup + retry cycle.
    final existing = _connectInFlight;
    if (existing != null) {
      final ok = await existing;
      if (_disposed) return false;
      if (ok) return true;
    }

    _reconnecting = true;
    _cleanup();

    const delays = [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
      Duration(seconds: 16),
    ];

    try {
      for (final delay in delays) {
        if (_disposed) return false;
        await Future<void>.delayed(delay);
        if (_disposed) return false;
        // Another code path may have reconnected us during our delay.
        // Don't tear down a working connection — just return success.
        if (_connected) return true;
        if (await connect(maxRetries: 0)) return true;
      }
      return false;
    } finally {
      _reconnecting = false;
    }
  }

  Future<void> _subscribeToStreams() async {
    if (_service == null) return;

    try {
      await _service!.streamListen(EventStreams.kGC);
      _gcSub = _service!.onGCEvent.listen((event) {
        onGcEvent?.call(event);
      });
    } catch (_) {
      // GC stream may not be available on all platforms
    }

    try {
      await _service!.streamListen(EventStreams.kExtension);
      _extensionSub = _service!.onExtensionEvent.listen((event) {
        onExtensionEvent?.call(event);
      });
    } catch (_) {
      // Extension stream may not be available on all platforms — best effort.
    }
  }

  void _startTimelinePolling() {
    // Poll timeline every 500ms to batch events efficiently
    _pollTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _pollTimeline(),
    );
  }

  /// Run one poll cycle synchronously without waiting for the periodic
  /// timer. The returned Future completes after the new timeline events
  /// have been read AND `onTimelineData` has fired, so awaiting this
  /// guarantees that any pending detector emissions have landed before
  /// the awaiter proceeds.
  ///
  /// **Barrier semantics**: when invoked while a periodic poll is
  /// already in flight, this call AWAITS the in-flight poll AND THEN
  /// runs a guaranteed fresh poll cycle before returning. This is
  /// stronger than the periodic timer's own re-entry guard (which just
  /// returns immediately on overlap) — capture-flow callers
  /// (`Sleuth.flushTimelineNow`) need the barrier so the trace event
  /// for any BUILD that finished AFTER the periodic poll's snapshot
  /// lands inside the scenario span before `markScenarioEnd`.
  ///
  /// Used by both test code (deterministic poll) AND the public capture
  /// flow (`Sleuth.flushTimelineNow`). Do NOT remove or rename without
  /// updating both consumers.
  Future<void> pollTimelineSync() => _pollTimeline(forceFresh: true);

  /// Snapshots the current VM timeline buffer and returns the events
  /// as raw Chrome Trace Event JSON-encodable maps WITHOUT clearing
  /// the buffer. Used by the capture-export path so the same events
  /// can still be processed by the polling loop.
  ///
  /// Returns an empty list when the service is disconnected or no
  /// events are available. Each entry is the same JSON shape Chrome's
  /// trace-event format uses (`{ph, ts, name, dur, args, ...}`),
  /// suitable for direct emission into a `traceEvents` array.
  ///
  /// Caller is responsible for filtering to a scenario span — the
  /// returned list contains every event the VM ring buffer still holds.
  /// Narrow or restore the VM timeline stream allowlist at runtime. Used
  /// by capture procedures to suppress Embedder/GC stream churn during
  /// long allocation phases that would otherwise overflow the VM trace
  /// ring buffer and roll scenario markers off mid-leg. Pass
  /// `['Dart']` to keep only Dart-side Timeline events (scenario
  /// markers, issue trace events). Pass `['Dart', 'Embedder', 'GC']` to
  /// restore the default allowlist.
  Future<void> setTimelineStreams(List<String> streams) async {
    final service = _service;
    if (service == null || _disposed || !_connected) return;
    try {
      await service.setVMTimelineFlags(streams);
    } catch (e) {
      // Stream-flag updates are best-effort; capture procedures fall
      // back to the existing stream set if the call fails. Surface the
      // failure via debugPrint so capture-procedure operators can
      // distinguish "stream-narrow failed" from the downstream
      // "scenario markers not found" symptom that ring-buffer overflow
      // would produce.
      debugPrint(
        'VmServiceClient.setTimelineStreams($streams): RPC failed: $e. '
        'Capture procedures fall back to existing stream set; ring-'
        'buffer overflow is likely if scenario duration > ~5 s with '
        'Embedder/GC streams enabled.',
      );
    }
  }

  Future<List<Map<String, dynamic>>> fetchRawTimelineEventsJson() async {
    final service = _service;
    if (service == null || _disposed || !_connected) return const [];
    try {
      final timeline = await service.getVMTimeline();
      final events = timeline.traceEvents;
      if (events == null) return const [];
      return [
        for (final e in events)
          if (e.json != null) Map<String, dynamic>.from(e.json!),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Tracks the in-flight `_pollTimeline()` call (if any) so concurrent
  /// callers can either short-circuit (periodic timer — re-entry guard)
  /// or wait + force a guaranteed-fresh poll (capture-flow
  /// `pollTimelineSync` — barrier semantics).
  ///
  /// Periodic-timer overlap (the original v0.18.1 use case) returns
  /// immediately to avoid wasted VM round-trips. Capture-flow flush MUST guarantee a fresh observation of
  /// any BUILD that finished after the in-flight snapshot — otherwise
  /// the issue trace event lands outside the scenario span.
  Completer<void>? _pollInFlightCompleter;

  /// Per-thread stack of unmatched BUILD `ph: 'B'` events carried
  /// across `_pollTimeline()` invocations. iOS profile-mode emits BUILD
  /// as B/E pairs (not `ph: 'X'` complete-form); when a poll boundary
  /// falls between B (batch N) and E (batch N+1), this state lets
  /// `TimelineParser.parse()` reconstruct `dur = E.ts - B.ts` on the
  /// next call.
  ///
  /// The matching E for a B observed in batch N is emitted after that
  /// poll's fetch and arrives in batch N+1, so the stack must carry
  /// across polls; without it every poll-boundary BUILD on iOS profile
  /// mode would silently drop. Cleared only on `dispose()`/`_cleanup()`. Stale
  /// entries (B with no matching E within the idle window) are evicted by
  /// the age sweep in `_pollTimeline` using the events' own monotonic
  /// `ts` (microseconds since process boot) to avoid wall-clock drift.
  final Map<int, List<Map<String, dynamic>>> _pendingBuildBegins = {};

  /// Per-tid stacks of unmatched LAYOUT / PAINT / raster / shader
  /// `ph: 'B'` events. iOS profile mode (Impeller backend) emits these phases
  /// as nested B/E pairs with no `X`-form complete events; the parser
  /// reconstructs durations from matching pairs and credits only the
  /// outermost scope per frame. Carried across polls for the same
  /// cross-batch reasoning as `_pendingBuildBegins`. Cleared in
  /// `_cleanup()`; stale begins evicted by the age sweep.
  final Map<int, List<Map<String, dynamic>>> _pendingLayoutBegins = {};
  final Map<int, List<Map<String, dynamic>>> _pendingPaintBegins = {};
  final Map<int, List<Map<String, dynamic>>> _pendingRasterBegins = {};
  final Map<int, List<Map<String, dynamic>>> _pendingShaderBegins = {};

  /// In-flight async platform-channel calls (`id` → `b` timestamp),
  /// carried across polls so a call whose `e` lands in the next batch
  /// still yields a duration. Capped by the parser; stale entries evicted
  /// by the age sweep; cleared in `_cleanup()`.
  final Map<String, int> _pendingChannelBegins = {};

  /// Maximum age (in microseconds) for an unmatched BUILD `ph: 'B'` event
  /// to remain in [_pendingBuildBegins]. Beyond this, the entry is treated
  /// as orphan (its matching E was lost — VM buffer overflow, isolate
  /// crash mid-build, etc.) and evicted. 30s is conservative: a real
  /// BUILD typically completes in <16ms; anything pending longer than
  /// 30s is almost certainly never going to pair.
  ///
  /// Same cutoff applied to [_pendingLayoutBegins] / [_pendingPaintBegins]
  /// / [_pendingRasterBegins] / [_pendingShaderBegins] — those scopes
  /// complete well under a second, so 30s is a safe orphan ceiling.
  static const int _pendingBuildBeginsMaxAgeMicros = 30 * 1000 * 1000;

  /// Maximum age (in microseconds) for a `_lastProcessedTsByTid` cursor
  /// to survive without observing fresh events. Beyond this idle
  /// window, the cursor is evicted by the post-parse sweep. Long-lived
  /// sessions with churning thread ids (worker isolates, GC helper
  /// threads) would otherwise grow the map indefinitely. Eviction is
  /// safe because a windowed fetch never returns events older than
  /// [TimelineParser.maxReconstructedPhaseUs] before the newest event
  /// seen, far inside this age.
  ///
  /// Sweep runs only on polls with at least one accepted event (the
  /// anchor `ts` is the batch max); fully idle polling sessions retain
  /// cursors until the next active poll. Worst case is bounded by the
  /// OS thread limit per process.
  static const int _cursorMaxIdleMicros = 30 * 1000 * 1000;

  /// Per-tid cross-call dedup cursors threaded into
  /// `TimelineParser.parse()` so the overlap between consecutive fetch
  /// windows doesn't inflate downstream counters. Cleared in
  /// `_cleanup()`.
  final Map<int, TimelineCursor> _lastProcessedTsByTid = {};

  /// Test-only view of the dedup cursors.
  @visibleForTesting
  Map<int, TimelineCursor> get cursorsForTest =>
      Map.unmodifiable(_lastProcessedTsByTid);

  /// Largest event `ts` accepted in this session; null until the first
  /// poll that returned a timestamped event. Null makes the next poll a
  /// full fetch (startup events, first session after a reconnect).
  /// Reset in `_cleanup()`.
  int? _lastMaxTs;

  /// Margin added past the VM's current timeline clock reading so events
  /// stamped between the clock read and the fetch are included.
  static const int _windowExtentSlackUs = 1000000;

  /// Polls in this session that fell back to a full fetch after the
  /// timeline clock read failed or ran behind the newest event seen.
  int _windowFallbacks = 0;

  /// Bumped in `_cleanup()`. `_pollTimeline` captures this at start and
  /// re-checks after each await; a generation change means a reconnect
  /// or dispose ran during the await, so the poll drops its results
  /// instead of mutating session-shared state or firing callbacks.
  int _sessionGeneration = 0;

  Future<void> _pollTimeline({bool forceFresh = false}) async {
    if (_pollInFlightCompleter != null) {
      if (!forceFresh) return;
      // Capture-flow barrier: wait for the in-flight poll to finish,
      // then fall through to run a fresh one. The in-flight poll's
      // snapshot may pre-date the BUILD we want to observe; the fresh
      // poll guarantees we see post-snapshot events before returning.
      await _pollInFlightCompleter!.future;
    }
    if (_service == null || _disposed) return;
    final myGen = _sessionGeneration;
    final completer = Completer<void>();
    _pollInFlightCompleter = completer;
    // Per-segment timings. Each stopwatch covers one segment only; a
    // segment that did not run stays 0.
    var rpcUs = 0;
    var parseUs = 0;
    var dispatchUs = 0;
    var tailUs = 0;
    var eventCount = 0;
    var duplicates = 0;
    var windowFallback = false;
    final watch = Stopwatch();
    try {
      // Fetch window: the whole buffer on the first poll of a session,
      // otherwise from `maxReconstructedPhaseUs` before the newest event
      // seen up to the VM's current clock plus slack. The overlap lets a
      // begin/end pair or an `X` event that straddles the previous fetch
      // be read whole; the per-tid cursors drop what was already
      // processed. Nothing is cleared, so events written between two
      // fetches are never lost and DevTools keeps its timeline.
      final lastMaxTs = _lastMaxTs;
      int? originUs;
      int? extentUs;
      var floorUs = 0;
      if (lastMaxTs != null) {
        originUs = math.max(
          0,
          lastMaxTs - TimelineParser.maxReconstructedPhaseUs,
        );
        watch.start();
        final nowUs = await _readTimelineClock();
        tailUs += watch.elapsedMicroseconds;
        if (myGen != _sessionGeneration || _disposed) return;
        if (nowUs == null || nowUs < lastMaxTs) {
          // The clock read failed or is not on the event clock: read the
          // whole buffer and drop everything before the window client
          // side, so evicted cursors cannot replay old events.
          windowFallback = true;
          _windowFallbacks++;
          floorUs = originUs;
          originUs = null;
        } else {
          extentUs = nowUs - originUs + _windowExtentSlackUs;
        }
      }
      final Timeline timeline;
      watch
        ..reset()
        ..start();
      try {
        timeline = await _fetchTimeline(originUs, extentUs);
      } finally {
        rpcUs = watch.elapsedMicroseconds;
      }
      _consecutivePollFailures = 0;
      // Drop stale poll if reconnect/dispose ran during the await.
      if (myGen != _sessionGeneration || _disposed) return;
      final events = timeline.traceEvents;
      eventCount = events?.length ?? 0;
      ParsedTimelineData? parsed;
      if (events != null && events.isNotEmpty) {
        watch
          ..reset()
          ..start();
        // One-shot: extract engine startup events from the first full
        // fetch, while the ring buffer still holds them.
        if (!_startupEventsExtracted && onStartupTimelineEvents != null) {
          _startupEventsExtracted = true;
          final startupEvents = TimelineParser.extractStartupEvents(events);
          if (startupEvents != null) {
            onStartupTimelineEvents!(startupEvents);
          }
        }

        parsed = TimelineParser.parse(
          events,
          pendingBuildBegins: _pendingBuildBegins,
          pendingLayoutBegins: _pendingLayoutBegins,
          pendingPaintBegins: _pendingPaintBegins,
          pendingRasterBegins: _pendingRasterBegins,
          pendingShaderBegins: _pendingShaderBegins,
          pendingChannelBegins: _pendingChannelBegins,
          cursorsByTid: _lastProcessedTsByTid,
          minTimestampUs: floorUs,
        );
        duplicates = parsed.duplicatesDropped;
        final batchMaxTs = parsed.maxTimestampUs;
        if (batchMaxTs >= 0 && (lastMaxTs == null || batchMaxTs > lastMaxTs)) {
          _lastMaxTs = batchMaxTs;
        }
        // Evict orphan begins (B with no matching E within the idle
        // window). Compares event-relative monotonic `ts` so the sweep
        // is drift-free across wall-clock skews. Skipped when the batch
        // accepted no timestamped event.
        _sweepStalePendingBegins(batchMaxTs);
        parseUs = watch.elapsedMicroseconds;
      }
      // Dispatch every batch with data, and an empty batch once per
      // [idleHeartbeat] so window-based detectors keep evaluating while
      // the timeline is quiet.
      final dispatchAt = DateTime.now();
      final last = _lastTimelineDispatchAt;
      final hasData = parsed != null && parsed.hasData;
      if (hasData ||
          last == null ||
          dispatchAt.difference(last) >= idleHeartbeat) {
        _lastTimelineDispatchAt = dispatchAt;
        watch
          ..reset()
          ..start();
        onTimelineData?.call(
          parsed ?? TimelineParser.parse(const <TimelineEvent>[]),
        );
        dispatchUs = watch.elapsedMicroseconds;
      }
      watch
        ..reset()
        ..start();
      try {
        await _pollTail(myGen);
      } finally {
        tailUs += watch.elapsedMicroseconds;
      }
    } catch (e) {
      // One failed RPC retries on the next tick; a run of failures means
      // the connection is gone (see [_consecutivePollFailures]).
      _consecutivePollFailures++;
      if (_consecutivePollFailures >= pollFailuresBeforeDisconnect) {
        _consecutivePollFailures = 0;
        _handleConnectionLost();
      }
    } finally {
      watch.stop();
      final responseChars = _takeTimelineResponseChars();
      if (myGen == _sessionGeneration && !_disposed) {
        _recordPollTimings(
          PollTimings(
            rpcMicros: rpcUs,
            parseMicros: parseUs,
            dispatchMicros: dispatchUs,
            tailMicros: tailUs,
            eventCount: eventCount,
            responseChars: responseChars,
            duplicatesDropped: duplicates,
            completedAt: DateTime.now(),
            windowFallback: windowFallback,
          ),
        );
      }
      _pollInFlightCompleter = null;
      completer.complete();
    }
  }

  /// Issues the poll's `getVMTimeline` request (windowed when [originUs]
  /// is non-null) with the raw-response length capture armed (see
  /// [_attachWireListeners]).
  Future<Timeline> _fetchTimeline(int? originUs, int? extentUs) {
    _timelineRequestId = null;
    _timelineResponseChars = -1;
    _armTimelineRequest = true;
    try {
      return originUs == null
          ? _service!.getVMTimeline()
          : _service!.getVMTimeline(
              timeOriginMicros: originUs,
              timeExtentMicros: extentUs,
            );
    } finally {
      _armTimelineRequest = false;
    }
  }

  /// Current reading of the VM timeline clock (the clock event `ts`
  /// values use), or null when the RPC fails.
  Future<int?> _readTimelineClock() async {
    try {
      final stamp = await _service!.getVMTimelineMicros();
      return stamp.timestamp;
    } catch (_) {
      return null;
    }
  }

  /// The heap memory sample that follows each poll. Returns early when
  /// the session moved on.
  Future<void> _pollTail(int myGen) async {
    // Poll heap memory (piggybacked on timeline poll, near-zero cost)
    if (_mainIsolateId != null && onHeapSample != null) {
      try {
        final mem = await _service!.getMemoryUsage(_mainIsolateId!);
        if (myGen != _sessionGeneration || _disposed) return;
        onHeapSample?.call(
          HeapSample(
            heapUsage: mem.heapUsage ?? 0,
            heapCapacity: mem.heapCapacity ?? 0,
            externalUsage: mem.externalUsage ?? 0,
            timestamp: DateTime.now(),
            rssBytes: _readRssBytes(),
          ),
        );
      } on SentinelException {
        // Isolate ID stale (e.g., after hot restart) — re-fetch, unless
        // a reconnect replaced the service during the await.
        final isolateId = await _resolveMainIsolateId();
        if (myGen != _sessionGeneration || _disposed) return;
        _mainIsolateId = isolateId;
      } catch (_) {
        // Memory poll failed but timeline poll succeeded — don't reconnect.
        // Will retry on next poll cycle.
      }
    }
  }

  PollTimings? _lastPollTimings;
  final PollTimingsWindow _timingsWindow = PollTimingsWindow();
  int _duplicatesDroppedTotal = 0;

  /// Timings of the most recent completed poll of this session; null
  /// before the first poll.
  PollTimings? get lastPollTimings => _lastPollTimings;

  /// Largest RPC segment over the last 32 polls; null before the first.
  int? get maxPollRpcMicros => _timingsWindow.maxRpcMicros;

  /// Largest parse segment over the last 32 polls; null before the first.
  int? get maxPollParseMicros => _timingsWindow.maxParseMicros;

  /// Largest dispatch segment over the last 32 polls; null before the
  /// first.
  int? get maxPollDispatchMicros => _timingsWindow.maxDispatchMicros;

  /// Events dropped as already processed, summed over this session's
  /// polls; null before the first poll.
  int? get pollDuplicatesDropped =>
      _lastPollTimings == null ? null : _duplicatesDroppedTotal;

  /// Polls in this session that read the whole timeline buffer because
  /// the timeline clock could not bound a window; null before the first
  /// poll.
  int? get pollWindowFallbacks =>
      _lastPollTimings == null ? null : _windowFallbacks;

  void _recordPollTimings(PollTimings timings) {
    _lastPollTimings = timings;
    _timingsWindow.add(timings);
    _duplicatesDroppedTotal += timings.duplicatesDropped;
  }

  StreamSubscription<String>? _sendSub;
  StreamSubscription<String>? _receiveSub;

  /// True only while [_fetchTimeline] is issuing its request, so the
  /// export fetch and other RPCs are never mistaken for the poll's.
  bool _armTimelineRequest = false;

  /// Request id of the poll's in-flight `getVMTimeline` call.
  String? _timelineRequestId;

  /// Length of the matched raw response; −1 until matched.
  int _timelineResponseChars = -1;

  static final RegExp _requestIdPattern = RegExp(r'"id":"([^"]*)"');

  /// Listens to the service's raw wire traffic to measure the size of
  /// each poll's timeline response. Request ids are private to
  /// package:vm_service; `onSend` fires synchronously with the encoded
  /// request (which carries the id) before it is written, and
  /// `onReceive` fires with each raw response before it is decoded. The
  /// listeners only read lengths and short substrings.
  void _attachWireListeners(VmService service) {
    _sendSub?.cancel();
    _receiveSub?.cancel();
    _sendSub = null;
    _receiveSub = null;
    try {
      _sendSub = service.onSend.listen((message) {
        if (!_armTimelineRequest ||
            !message.contains('"method":"getVMTimeline"')) {
          return;
        }
        _timelineRequestId = _requestIdPattern.firstMatch(message)?.group(1);
      });
      _receiveSub = service.onReceive.listen((message) {
        final id = _timelineRequestId;
        if (id == null) return;
        if (message.lastIndexOf('"id":"$id"') < 0) return;
        _timelineResponseChars = message.length;
        _timelineRequestId = null;
      });
    } catch (_) {
      // A test double without wire streams reports −1 for every poll.
    }
  }

  int _takeTimelineResponseChars() {
    final chars = _timelineResponseChars;
    _timelineResponseChars = -1;
    _timelineRequestId = null;
    return chars;
  }

  /// Evict orphan begins from the pending-begin maps and idle cursors
  /// from [_lastProcessedTsByTid]. [anchorTs] is the largest `ts` the
  /// parser accepted in this poll ([ParsedTimelineData.maxTimestampUs]);
  /// using the events' own monotonic clock keeps the sweep independent
  /// of wall-clock skew, and taking it from the parse keeps the sweep
  /// O(pending) instead of another walk over the batch.
  ///
  /// Pending begins: any B older than anchor by
  /// [_pendingBuildBeginsMaxAgeMicros] is evicted (matching E was lost
  /// — VM buffer overflow, isolate crash, etc.). Stack is bottom-to-top
  /// in arrival order; once the front entry is fresh, every later one
  /// is too — loop short-circuits.
  ///
  /// Cursors: any tid whose `lastTs` is older than anchor by
  /// [_cursorMaxIdleMicros] is evicted. The fetch window never reaches
  /// that far back, so an evicted tid's old events are not read again.
  /// Polls that accepted no timestamped event skip the sweep.
  void _sweepStalePendingBegins(int anchorTs) {
    if (anchorTs <= 0) return;
    if (_pendingBuildBegins.isEmpty &&
        _pendingLayoutBegins.isEmpty &&
        _pendingPaintBegins.isEmpty &&
        _pendingRasterBegins.isEmpty &&
        _pendingShaderBegins.isEmpty &&
        _pendingChannelBegins.isEmpty &&
        _lastProcessedTsByTid.isEmpty) {
      return;
    }
    final pendingCutoff = anchorTs - _pendingBuildBeginsMaxAgeMicros;
    _evictStaleBegins(_pendingBuildBegins, pendingCutoff);
    _evictStaleBegins(_pendingLayoutBegins, pendingCutoff);
    _evictStaleBegins(_pendingPaintBegins, pendingCutoff);
    _evictStaleBegins(_pendingRasterBegins, pendingCutoff);
    _evictStaleBegins(_pendingShaderBegins, pendingCutoff);
    _pendingChannelBegins.removeWhere((_, ts) => ts < pendingCutoff);
    final cursorCutoff = anchorTs - _cursorMaxIdleMicros;
    _lastProcessedTsByTid.removeWhere(
      (_, cursor) => cursor.lastTs < cursorCutoff,
    );
  }

  /// Drop entries older than [cutoffTs] from the head of each per-tid
  /// stack, then prune empty tid entries. Shared body for the BUILD /
  /// LAYOUT / PAINT / raster / shader pending-begins sweep.
  static void _evictStaleBegins(
    Map<int, List<Map<String, dynamic>>> pending,
    int cutoffTs,
  ) {
    if (pending.isEmpty) return;
    final emptyTids = <int>[];
    for (final entry in pending.entries) {
      final stack = entry.value;
      while (stack.isNotEmpty) {
        final ts = stack.first['ts'];
        if (ts is int && ts < cutoffTs) {
          stack.removeAt(0);
        } else {
          break;
        }
      }
      if (stack.isEmpty) emptyTids.add(entry.key);
    }
    for (final tid in emptyTids) {
      pending.remove(tid);
    }
  }

  /// Resolve the main (non-system) isolate ID for memory polling.
  Future<String?> _resolveMainIsolateId() async {
    try {
      final vm = await _service!.getVM();
      final isolates = vm.isolates;
      if (isolates == null || isolates.isEmpty) return null;
      final main = isolates.firstWhere(
        (ref) => ref.isSystemIsolate != true,
        orElse: () => isolates.first,
      );
      return main.id;
    } catch (_) {
      return null;
    }
  }

  /// WebSocket addresses to try for this process's own VM service, in
  /// order.
  ///
  /// `controlWebServer` reports `127.0.0.1` for a loopback bind; `localhost`
  /// lets Dart's dual-stack resolver try IPv4 and IPv6. A service bound to
  /// the wildcard address reports an interface address instead (the Wi-Fi
  /// address of a wirelessly launched iOS app). Connecting to that from
  /// inside the app leaves through the LAN interface, which iOS
  /// local-network privacy blocks without a prompt in profile mode. A
  /// wildcard bind always serves loopback, so loopback goes first; the
  /// reported address stays as the fallback for a service bound to one
  /// specific interface.
  @visibleForTesting
  static List<Uri> candidateWebSocketUris(Uri wsUri) {
    final loopback = wsUri.replace(host: 'localhost');
    switch (wsUri.host) {
      case 'localhost' || '127.0.0.1' || '::1' || '[::1]':
        return [loopback];
      default:
        return [loopback, wsUri];
    }
  }

  Uri _toWebSocketUri(Uri httpUri) {
    final path = httpUri.path.endsWith('/')
        ? '${httpUri.path}ws'
        : '${httpUri.path}/ws';
    return httpUri.replace(
      scheme: httpUri.scheme == 'https' ? 'wss' : 'ws',
      path: path,
    );
  }

  /// Reports the connection lost once and starts the reconnect ladder.
  /// Cancels the poll timer BEFORE the callback so a throwing
  /// [onConnectionChanged] cannot produce a 500 ms error loop.
  void _handleConnectionLost() {
    if (_disposed || _reconnecting || !_connected && _service == null) return;
    _pollTimer?.cancel();
    _pollTimer = null;
    _connected = false;
    onConnectionChanged?.call(false);
    // Fire-and-forget is intentional — reconnect runs in background.
    unawaited(reconnect());
  }

  /// Reports a real socket closure as soon as the service's `onDone`
  /// completes, independent of the poll cadence. Ignored once the
  /// service has been replaced or cleaned up (a reconnect disposes the
  /// old service, which also completes its `onDone`).
  void _watchSocket(VmService service) {
    try {
      unawaited(
        service.onDone.then((_) {
          if (identical(_service, service)) _handleConnectionLost();
        }),
      );
    } catch (_) {
      // A test double without a socket has no `onDone`.
    }
  }

  void _cleanup() {
    _consecutivePollFailures = 0;
    _lastTimelineDispatchAt = null;
    _timingsWindow.clear();
    _duplicatesDroppedTotal = 0;
    _windowFallbacks = 0;
    _lastMaxTs = null;
    _sendSub?.cancel();
    _sendSub = null;
    _receiveSub?.cancel();
    _receiveSub = null;
    _timelineRequestId = null;
    _timelineResponseChars = -1;
    // Bump generation before clearing so any in-flight `_pollTimeline`
    // detects the change at its next fence check and drops stale results.
    _sessionGeneration++;
    _pendingBuildBegins.clear();
    _pendingLayoutBegins.clear();
    _pendingPaintBegins.clear();
    _pendingRasterBegins.clear();
    _pendingShaderBegins.clear();
    _pendingChannelBegins.clear();
    _lastProcessedTsByTid.clear();
    _pollTimer?.cancel();
    _pollTimer = null;
    _controlWebServerTimer?.cancel();
    _controlWebServerTimer = null;
    _timelineSub?.cancel();
    _timelineSub = null;
    _gcSub?.cancel();
    _gcSub = null;
    _extensionSub?.cancel();
    _extensionSub = null;
    _mainIsolateId = null;
    _connected = false;
    try {
      _service?.dispose();
    } catch (_) {
      // Service may already be disconnected — disposal is best effort.
    }
    _service = null;
  }

  /// Query CPU samples for a time window. Returns null on error or timeout.
  ///
  /// Used by the controller to attribute jank frames to specific functions.
  /// Only called on-demand when a jank frame is detected — not continuous.
  Future<CpuSamples?> getCpuSamples({
    required int timeOriginUs,
    required int timeExtentUs,
  }) async {
    final service = _service;
    final isolateId = _mainIsolateId;
    if (service == null || isolateId == null) return null;

    try {
      return await service
          .getCpuSamples(isolateId, timeOriginUs, timeExtentUs)
          .timeout(const Duration(milliseconds: 500));
    } on SentinelException {
      // Isolate ID stale (e.g., after hot restart) — re-fetch
      _mainIsolateId = await _resolveMainIsolateId();
      return null;
    } catch (_) {
      // CPU sample query failed — non-fatal, don't trigger reconnect
      return null;
    }
  }

  /// Query allocation profile for the main isolate. Returns null on error or timeout.
  ///
  /// Called with [reset: true] to get deltas since last call. First call
  /// establishes baseline; subsequent calls show allocation activity.
  /// Only called on-demand when heap growth is detected — not continuous.
  Future<AllocationProfile?> getAllocationProfile({
    bool reset = false,
    Duration timeout = const Duration(milliseconds: 500),
  }) async {
    final service = _service;
    final isolateId = _mainIsolateId;
    if (service == null || isolateId == null) return null;

    try {
      return await service
          .getAllocationProfile(isolateId, reset: reset)
          .timeout(timeout);
    } on SentinelException {
      _mainIsolateId = await _resolveMainIsolateId();
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Dispose all resources.
  void dispose() {
    _disposed = true;
    _cleanup();
  }
}
