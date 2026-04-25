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

  /// Test-only: run one poll cycle without the periodic timer.
  @visibleForTesting
  Future<void> pollTimelineForTest() => _pollTimeline();

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

  Future<void> _pollTimeline() async {
    if (_service == null || _disposed) return;

    try {
      final timeline = await _service!.getVMTimeline();
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

        final parsed = TimelineParser.parse(events);
        if (parsed.hasData) {
          onTimelineData?.call(parsed);
        }
      }
      // Clear the timeline buffer to avoid re-processing — unless
      // capture mode wants the events retained for a later Export.
      if (!retainTimeline) {
        await _service!.clearVMTimeline();
      }

      // Poll heap memory (piggybacked on timeline poll, near-zero cost)
      if (_mainIsolateId != null && onHeapSample != null) {
        try {
          final mem = await _service!.getMemoryUsage(_mainIsolateId!);
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
  }) async {
    final service = _service;
    final isolateId = _mainIsolateId;
    if (service == null || isolateId == null) return null;

    try {
      return await service
          .getAllocationProfile(isolateId, reset: reset)
          .timeout(const Duration(milliseconds: 500));
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
