import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io' show ProcessInfo;
import 'package:flutter/foundation.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';
import '../models/heap_sample.dart';
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
    this.onHeapSample,
    this.onExtensionEvent,
    this.onConnectionChanged,
    this.onStartupTimelineEvents,
    this.retainTimeline = false,
  });

  /// When true, the polling loop does NOT call `clearVMTimeline` after
  /// each cycle, so raw events accumulate in the VM-side trace buffer
  /// and remain available to [fetchRawTimelineEventsJson]. Used by
  /// capture procedures so a later Export call can still see the
  /// scenario-span events; production sessions leave this false to
  /// keep the trace buffer bounded.
  ///
  /// The VM has its own ring-buffer cap (Dart trace buffer default
  /// ~5 MB). Long capture sessions still risk silent drop of the
  /// oldest events; capture screens should call Export within ~30 s
  /// of `markScenarioEnd`.
  final bool retainTimeline;

  final TimelineDataCallback? onTimelineData;
  final VmEventCallback? onGcEvent;
  final HeapSampleCallback? onHeapSample;
  final VmEventCallback? onExtensionEvent;
  final void Function(bool connected)? onConnectionChanged;

  /// One-shot callback for engine-level startup events extracted from the
  /// VM timeline ring buffer on the first poll. Called at most once.
  final StartupTimelineCallback? onStartupTimelineEvents;

  VmService? _service;
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

  /// Whether the client has been disposed.
  bool get isDisposed => _disposed;

  /// Test-only: inject a mock VmService and isolate ID to test polling/CPU paths.
  @visibleForTesting
  void setServiceForTest(VmService service, {String? isolateId}) {
    _service = service;
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

        // controlWebServer reports 127.0.0.1 (IPv4-only literal). Using
        // 'localhost' enables Dart's Happy Eyeballs dual-stack resolver so
        // WebSocket.connect tries both IPv4 and IPv6 automatically.
        if (wsUri.host == '127.0.0.1') {
          wsUri = wsUri.replace(host: 'localhost');
        }

        // Use a timeout to avoid hanging on unreachable addresses
        // (common on Android where the URI is host-forwarded).
        _service = await vmServiceConnectUri(wsUri.toString())
            .timeout(const Duration(seconds: 3));
        if (_disposed) {
          _cleanup();
          return false;
        }

        // Enable timeline streams for framework events
        await _service!.setVMTimelineFlags([
          'Dart',
          'Embedder',
          'GC',
        ]);

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
  /// timer. The returned Future completes after the timeline buffer has
  /// been drained AND `onTimelineData` has fired, so awaiting this
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
  /// returned list contains every event the VM has buffered since the
  /// last clear (or since service connection if [retainTimeline]).
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
  /// immediately to avoid wasted VM round-trips and `clearVMTimeline()`
  /// races. Capture-flow flush MUST guarantee a fresh observation of
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
  /// Survives `clearVMTimeline()` because the matching E for a B observed
  /// in batch N is emitted by Flutter AFTER the clear and lands in
  /// batch N+1's fresh buffer — it is not discarded by the VM along with
  /// the cleared events. Without surviving the clear, every poll-boundary
  /// BUILD on iOS profile mode would silently drop in the default
  /// live-monitoring path. Cleared only on `dispose()`/`_cleanup()`. Stale
  /// entries (B with no matching E within the idle window) are evicted by
  /// the age sweep in `_pollTimeline` using the events' own monotonic
  /// `ts` (microseconds since process boot) to avoid wall-clock drift.
  final Map<int, List<Map<String, dynamic>>> _pendingBuildBegins = {};

  /// Per-tid stacks of unmatched LAYOUT / PAINT / raster `ph: 'B'`
  /// events. iOS profile mode (Impeller backend) emits these phases
  /// as nested B/E pairs with no `X`-form complete events; the parser
  /// reconstructs durations from matching pairs and credits only the
  /// outermost scope per frame. Survive `clearVMTimeline()` for the
  /// same cross-batch reasoning as `_pendingBuildBegins`. Cleared in
  /// `_cleanup()`; stale begins evicted by the age sweep.
  final Map<int, List<Map<String, dynamic>>> _pendingLayoutBegins = {};
  final Map<int, List<Map<String, dynamic>>> _pendingPaintBegins = {};
  final Map<int, List<Map<String, dynamic>>> _pendingRasterBegins = {};

  /// Maximum age (in microseconds) for an unmatched BUILD `ph: 'B'` event
  /// to remain in [_pendingBuildBegins]. Beyond this, the entry is treated
  /// as orphan (its matching E was lost — VM buffer overflow, isolate
  /// crash mid-build, etc.) and evicted. 30s is conservative: a real
  /// BUILD typically completes in <16ms; anything pending longer than
  /// 30s is almost certainly never going to pair.
  ///
  /// Same cutoff applied to [_pendingLayoutBegins] / [_pendingPaintBegins]
  /// / [_pendingRasterBegins] — those phases also complete in <16ms in
  /// any healthy frame, so 30s is a safe orphan ceiling.
  static const int _pendingBuildBeginsMaxAgeMicros = 30 * 1000 * 1000;

  /// Maximum age (in microseconds) for a `_lastProcessedTsByTid` cursor
  /// to survive without observing fresh events. Beyond this idle
  /// window, the cursor is evicted by the post-parse sweep. Long-lived
  /// sessions with churning thread ids (worker isolates, GC helper
  /// threads) would otherwise grow the map indefinitely.
  ///
  /// Sweep runs only on polls with at least one event (the anchor `ts`
  /// is the max ts in the batch); fully idle polling sessions retain
  /// cursors until the next active poll. Worst case is bounded by the
  /// OS thread limit per process.
  static const int _cursorMaxIdleMicros = 30 * 1000 * 1000;

  /// Per-tid cross-call dedup cursors threaded into
  /// `TimelineParser.parse()` so capture-mode buffer re-reads don't
  /// inflate downstream counters. Cleared in `_cleanup()`.
  final Map<int, TimelineCursor> _lastProcessedTsByTid = {};

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
    try {
      final timeline = await _service!.getVMTimeline();
      // Drop stale poll if reconnect/dispose ran during the await.
      if (myGen != _sessionGeneration || _disposed) return;
      final events = timeline.traceEvents;
      if (events != null && events.isNotEmpty) {
        // One-shot: extract engine startup events before clearing the buffer.
        // Must happen before clearVMTimeline() or the events are lost.
        if (!_startupEventsExtracted && onStartupTimelineEvents != null) {
          _startupEventsExtracted = true;
          final startupEvents = TimelineParser.extractStartupEvents(events);
          if (startupEvents != null) {
            onStartupTimelineEvents!(startupEvents);
          }
        }

        final parsed = TimelineParser.parse(
          events,
          pendingBuildBegins: _pendingBuildBegins,
          pendingLayoutBegins: _pendingLayoutBegins,
          pendingPaintBegins: _pendingPaintBegins,
          pendingRasterBegins: _pendingRasterBegins,
          cursorsByTid: _lastProcessedTsByTid,
        );
        if (parsed.hasData) {
          onTimelineData?.call(parsed);
        }
        // Evict orphan begins (B with no matching E within the idle
        // window). Compares event-relative monotonic `ts` so the sweep
        // is drift-free across wall-clock skews. Skipped when the batch
        // has no anchor ts to measure against.
        _sweepStalePendingBegins(events);
      }
      // Clear the VM's timeline ring buffer to avoid re-processing the
      // same events on the next poll — unless capture mode wants them
      // retained for a later Export.
      //
      // `_pendingBuildBegins` deliberately survives this clear: the
      // matching E for a B observed in this batch is emitted by Flutter
      // AFTER the clear call and lands in the next batch's fresh buffer,
      // so the carry-over is required for cross-batch reconstruction in
      // the default live-monitoring path. The age sweep above bounds the
      // map's growth; `_cleanup()` clears it on dispose.
      if (!retainTimeline) {
        await _service!.clearVMTimeline();
        if (myGen != _sessionGeneration || _disposed) return;
      }

      // Poll heap memory (piggybacked on timeline poll, near-zero cost)
      if (_mainIsolateId != null && onHeapSample != null) {
        try {
          final mem = await _service!.getMemoryUsage(_mainIsolateId!);
          if (myGen != _sessionGeneration || _disposed) return;
          onHeapSample?.call(HeapSample(
            heapUsage: mem.heapUsage ?? 0,
            heapCapacity: mem.heapCapacity ?? 0,
            externalUsage: mem.externalUsage ?? 0,
            timestamp: DateTime.now(),
            rssBytes: _readRssBytes(),
          ));
        } on SentinelException {
          // Isolate ID stale (e.g., after hot restart) — re-fetch
          _mainIsolateId = await _resolveMainIsolateId();
        } catch (_) {
          // Memory poll failed but timeline poll succeeded — don't reconnect.
          // Will retry on next poll cycle.
        }
      }
    } catch (e) {
      // Connection may have been lost — cancel timer BEFORE callbacks
      // to prevent 500ms error loops if onConnectionChanged throws.
      if (!_disposed && !_reconnecting) {
        _pollTimer?.cancel();
        _pollTimer = null;
        _connected = false;
        onConnectionChanged?.call(false);
        // Fire-and-forget is intentional — reconnect runs in background
        unawaited(reconnect());
      }
    } finally {
      _pollInFlightCompleter = null;
      completer.complete();
    }
  }

  /// Evict orphan begins from [_pendingBuildBegins] and (in non-capture
  /// polling mode only) stale cursors from [_lastProcessedTsByTid]. Uses
  /// the events' own monotonic `ts` as the clock so the sweep is
  /// independent of wall-clock skew. The anchor ts is the maximum `ts`
  /// in this poll's batch.
  ///
  /// Pending begins: any B older than anchor by
  /// [_pendingBuildBeginsMaxAgeMicros] is evicted (matching E was lost
  /// — VM buffer overflow, isolate crash, etc.). Stack is bottom-to-top
  /// in arrival order; once the front entry is fresh, every later one
  /// is too — loop short-circuits. Runs in both modes because
  /// pending-begins are only populated by un-deduped B events; with
  /// cursor dedup intact, retained re-reads never reach the push
  /// branch, so the sweep operates on legitimate orphans only.
  ///
  /// Cursors: any tid whose `lastTs` is older than anchor by
  /// [_cursorMaxIdleMicros] is evicted — but ONLY when
  /// `retainTimeline=false`. In capture mode the VM buffer is
  /// intentionally re-read across polls and the cursor is the dedup
  /// mechanism preventing replay of retained events. Evicting a cursor
  /// for an idle tid would let its old events pass through the parser
  /// on the next poll, inflating `buildEventCount` and other
  /// accumulators. Idle sessions (no events this poll) skip the sweep
  /// entirely.
  void _sweepStalePendingBegins(List<TimelineEvent> events) {
    if (_pendingBuildBegins.isEmpty &&
        _pendingLayoutBegins.isEmpty &&
        _pendingPaintBegins.isEmpty &&
        _pendingRasterBegins.isEmpty &&
        _lastProcessedTsByTid.isEmpty) {
      return;
    }
    var anchorTs = 0;
    for (final event in events) {
      final ts = event.json?['ts'];
      if (ts is int && ts > anchorTs) anchorTs = ts;
    }
    if (anchorTs == 0) return;
    final pendingCutoff = anchorTs - _pendingBuildBeginsMaxAgeMicros;
    _evictStaleBegins(_pendingBuildBegins, pendingCutoff);
    _evictStaleBegins(_pendingLayoutBegins, pendingCutoff);
    _evictStaleBegins(_pendingPaintBegins, pendingCutoff);
    _evictStaleBegins(_pendingRasterBegins, pendingCutoff);
    if (!retainTimeline) {
      final cursorCutoff = anchorTs - _cursorMaxIdleMicros;
      _lastProcessedTsByTid
          .removeWhere((_, cursor) => cursor.lastTs < cursorCutoff);
    }
  }

  /// Drop entries older than [cutoffTs] from the head of each per-tid
  /// stack, then prune empty tid entries. Shared body for the BUILD /
  /// LAYOUT / PAINT / raster pending-begins sweep.
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

  Uri _toWebSocketUri(Uri httpUri) {
    final path =
        httpUri.path.endsWith('/') ? '${httpUri.path}ws' : '${httpUri.path}/ws';
    return httpUri.replace(
      scheme: httpUri.scheme == 'https' ? 'wss' : 'ws',
      path: path,
    );
  }

  void _cleanup() {
    // Bump generation before clearing so any in-flight `_pollTimeline`
    // detects the change at its next fence check and drops stale results.
    _sessionGeneration++;
    _pendingBuildBegins.clear();
    _pendingLayoutBegins.clear();
    _pendingPaintBegins.clear();
    _pendingRasterBegins.clear();
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
