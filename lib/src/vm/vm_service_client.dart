import 'dart:async';
import 'dart:developer' as developer;
import 'dart:isolate' as isolate show Isolate;
import 'dart:math' as math;
import 'dart:io' show ProcessInfo;
import 'package:flutter/foundation.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';
import '../models/heap_sample.dart';
import '../utils/own_work_log.dart';
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

/// Where a VM session reads its timeline from.
enum TimelineSource {
  /// The VM's `Timeline` stream, drained every tick, with catch-up reads.
  stream,

  /// A `getVMTimeline` request every tick.
  poll,
}

/// Connects to the app's own VM Service for exact performance data.
///
/// Uses [dart:developer.Service.controlWebServer] to start or query the
/// VM web server and connects to it over a WebSocket from inside the app,
/// loopback first (see [candidateWebSocketUris]), so the link between the
/// device and the host (USB or wireless) does not matter. `flutter run` and
/// `flutter attach` start DDS by default, and DDS keeps the VM service as
/// its only client, so this connection is refused and the controller falls
/// back to BASIC mode (FrameTiming plus structural analysis). Launching with
/// `--no-dds`, or starting the installed app from the home screen, leaves
/// the service open to this client.
class VmServiceClient {
  VmServiceClient({
    this.onTimelineData,
    this.onGcEvent,
    this.idleHeartbeat = const Duration(seconds: 1),
    this.onHeapSample,
    this.onExtensionEvent,
    this.onTimerEvent,
    this.onPauseEvent,
    this.onConnectionChanged,
    this.onStartupTimelineEvents,
    this.retainTimeline = false,
    this.readDispatchSegments,
    this.cpuSamplesMinInterval = const Duration(seconds: 10),
    this.ownIsolateIdResolver,
    this.streamTimeline = true,
    this.newestFrameRasterFinishUs,
    this.streamSilentFallback = const Duration(seconds: 10),
    this.catchUpMinInterval = const Duration(seconds: 1),
    this.catchUpMaxInterval = const Duration(seconds: 2),
    @visibleForTesting this.streamClockForTest,
  });

  /// Test-only clock for the stream's lag, fallback and catch-up timing,
  /// in timeline microseconds. Null uses the timeline clock.
  final int Function()? streamClockForTest;

  int _streamNowUs() => streamClockForTest?.call() ?? OwnWorkLog.now();

  /// Whether sessions read the timeline from the VM's `Timeline` stream
  /// instead of a `getVMTimeline` request every tick.
  ///
  /// A `getVMTimeline` request makes the VM write every event in its
  /// window while the app's threads wait to record theirs: on a Galaxy
  /// A07 a 1 s window (about 6,900 events) held the raster thread up to
  /// 41 ms and a whole-buffer read 110 ms, every poll. The stream posts
  /// each thread's events in blocks of 64 as the block fills, which cost
  /// the measured frames nothing. The 500 ms tick stays: it drains the
  /// blocks that arrived, parses them as one batch and dispatches it, so
  /// detectors keep their cadence. A thread that writes few events holds
  /// them in an unfinished block. Any `getVMTimeline` request makes the VM
  /// post every thread's unfinished block before it answers, so a request
  /// for an empty window (a catch-up read) delivers them for almost
  /// nothing: when a frame ([newestFrameRasterFinishUs]) outran the newest
  /// event seen on a frame or raster thread, and at least every
  /// [catchUpMaxInterval].
  ///
  /// False polls, as capture mode does so its recorded brackets keep the
  /// path they were recorded with. A session also polls when the stream
  /// cannot be subscribed, or delivers no block while frames are drawn.
  final bool streamTimeline;

  /// The raster finish of the newest presented frame, in timeline
  /// microseconds, or null before the first frame. Drives the catch-up
  /// read and the stream fallback.
  final int? Function()? newestFrameRasterFinishUs;

  /// Returns the service id of the isolate this client runs on. Null
  /// uses `Service.getIsolateId(Isolate.current)`. Tests inject ids that
  /// match their fake `getVM` isolates.
  final String? Function()? ownIsolateIdResolver;

  /// Shortest gap between the starts of two [getCpuSamples] requests.
  ///
  /// The VM serves `getCpuSamples` on the target isolate's own thread:
  /// it interrupts whatever Dart code is running there to build the
  /// profile, and the response (several MB even for a one-frame window,
  /// because it carries the function table) is decoded on the same
  /// isolate. For the UI isolate that is a stall of tens of milliseconds
  /// on desktop and hundreds on a phone, so requests are spaced by this
  /// interval and never overlap.
  final Duration cpuSamplesMinInterval;

  /// Reads the split of the [onTimelineData] call that just returned, for
  /// [PollTimings]. Null leaves the whole dispatch in
  /// [PollTimings.dispatchOtherMicros].
  final DispatchSegments Function()? readDispatchSegments;

  /// Whether a later [fetchRawTimelineEventsJson] export relies on the
  /// VM keeping already-polled events (capture mode).
  ///
  /// The poll loop never clears the VM timeline: after the first poll of
  /// a session it fetches only a window that starts [fetchOverlapMicros]
  /// before the newest event it has seen, so the retained buffer is not re-read and the VM's
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

  /// Receives the VM's `Timer` stream events (`TimerSignificantlyOverdue`,
  /// posted when a timer fires 100 ms or more late, Dart 3.9 / Flutter
  /// 3.35 and later) from this client's own isolate. Null leaves the
  /// stream unsubscribed.
  final VmEventCallback? onTimerEvent;

  /// Receives this client's own isolate's debugger pauses and resumes
  /// (`Debug` stream `Pause*` and `Resume`) and its hot reloads (`Isolate`
  /// stream `IsolateReload`), which make timers late without the app being
  /// busy. Subscribed only together with [onTimerEvent].
  final VmEventCallback? onPauseEvent;

  /// Whether the VM has a `Timer` stream. Null until a session tried to
  /// subscribe, false on Dart before 3.9, where `streamListen('Timer')`
  /// fails.
  bool? get timerStreamAvailable => _timerStreamAvailable;
  bool? _timerStreamAvailable;
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
  StreamSubscription<Event>? _timerSub;
  StreamSubscription<Event>? _debugSub;
  StreamSubscription<Event>? _isolateSub;
  Timer? _pollTimer;
  bool _disposed = false;
  bool _connected = false;

  /// One-shot guard: startup events are extracted from the first read of
  /// the client's first session only.
  bool _startupEventsExtracted = false;

  /// Whether a read of the whole buffer has run. Later sessions (after a
  /// reconnect) start from a window ending at the VM clock instead: a
  /// whole-buffer read on a Galaxy A07 wrote 31,474 events and held the
  /// raster thread for 110 ms.
  bool _wholeBufferRead = false;

  /// How far back a session's first windowed read reaches.
  static const int firstWindowMicros = 1000000;

  /// Whether this session's first read ran; stream ticks follow it.
  bool _sessionFirstReadDone = false;

  /// Where this session reads its timeline from.
  TimelineSource? _timelineSource;

  /// Where the current session reads its timeline from; null while
  /// disconnected.
  TimelineSource? get timelineSource => _timelineSource;

  /// Stream blocks waiting for the next tick, in arrival order.
  final List<List<TimelineEvent>> _streamBuffer = [];
  int _streamBufferedEvents = 0;

  /// Most events held between two ticks. A tick normally drains about
  /// 3,500; each decoded event holds its JSON map. Beyond this the
  /// oldest whole block is dropped and counted in [streamEventsDropped].
  static const int streamBufferCap = 16384;

  int _streamBlocks = 0;
  int _streamEvents = 0;
  int _streamEventsDropped = 0;
  int _catchUpReads = 0;
  int? _lastStreamLagMs;
  int? _streamSubscribedAtUs;
  int? _lastCatchUpAtUs;

  /// Stream blocks received this session.
  int get streamBlocks => _streamBlocks;

  /// Stream events received this session.
  int get streamEvents => _streamEvents;

  /// Stream events dropped this session because ticks fell behind.
  int get streamEventsDropped => _streamEventsDropped;

  /// Catch-up reads this session.
  int get catchUpReads => _catchUpReads;

  /// Age, when it arrived, of the newest event in the last stream block,
  /// in milliseconds; null before the first block.
  int? get lastStreamLagMs => _lastStreamLagMs;

  /// Newest ordered event seen per thread this session, from the stream
  /// or a read.
  final Map<int, int> _newestSeenByTid = {};

  /// Threads that recorded raster scopes this session.
  final Set<int> _rasterTids = {};

  /// A frame finishing this long after a frame or raster thread's newest
  /// event seen means that thread holds unsent events: a catch-up read
  /// follows.
  static const int catchUpStaleMicros = 250000;

  /// Shortest gap between two catch-up reads a late frame asks for.
  final Duration catchUpMinInterval;

  /// Longest gap between two catch-up reads, so threads that rarely fill
  /// a block (Impeller's pipeline workers, for one) deliver their events
  /// on a busy screen too.
  final Duration catchUpMaxInterval;

  /// How far past the timeline clock a catch-up read's window starts. No
  /// event carries such a timestamp, so the VM writes none back; it still
  /// posts every thread's unfinished block first.
  static const int catchUpWindowAheadMicros = 3600000000;

  /// True while a stream session waits on a `getVMTimeline` request. The
  /// blocks the request makes the VM post arrive then, holding events of
  /// any age, so they do not count for [lastStreamLagMs].
  bool _readInFlight = false;

  /// Events older than this are dropped in stream ticks: the start of the
  /// session's first read (0 for a whole-buffer read). A thread with no
  /// event in that read posts its unfinished block later, and the events
  /// in it from before the session were never read under polling either.
  int _streamFloorUs = 0;

  /// How long a subscribed stream may deliver no block at all while
  /// frames are drawn before the session falls back to polling. A stream
  /// that has delivered blocks never falls back: on a static screen they
  /// arrive seconds apart.
  final Duration streamSilentFallback;
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

  /// This client's own isolate id, set once per session when the VM's
  /// isolate list confirms it and cleared only by [_cleanup].
  ///
  /// The VM posts every GC event once per non-system isolate in the
  /// isolate group, so `compute` and `Isolate.run` helpers repeat each
  /// collection. The GC filter keys off this id, never [_mainIsolateId]:
  /// a stale-isolate re-resolution can set [_mainIsolateId] to null
  /// mid-session, and a filter reading it would then drop every event.
  String? _verifiedOwnIsolateId;

  /// Whether the VM confirmed this client's own isolate id for the
  /// current session. GC events that reach [onGcEvent] then all come
  /// from that isolate's group.
  bool get isOwnIsolateVerified => _verifiedOwnIsolateId != null;

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
        // on cold start) it returns a null serverUri and we'd have to
        // poll-spin until the framework got around to starting it. controlWebServer forces the bind and returns
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
        // unreachable address (such as the LAN address a wirelessly launched
        // iOS app reports) fails fast.
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
        return await _startSession(connected);
      } catch (_) {
        if (attempt < maxRetries) {
          await Future<void>.delayed(retryDelay);
          if (_disposed) return false;
        }
      }
    }
    return false;
  }

  /// Everything that follows an open WebSocket: timeline flags, isolate
  /// identity, event streams and the poll loop. Returns false when the
  /// client was disposed, or the session ended, while it ran.
  Future<bool> _startSession(VmService service) async {
    _service = service;
    _watchSocket(service);
    _attachWireListeners(service);
    if (_disposed) {
      _cleanup();
      return false;
    }
    final gen = _sessionGeneration;

    // Enable timeline streams for framework events
    await service.setVMTimelineFlags(['Dart', 'Embedder', 'GC']);

    // Resolve the isolate id used by memory, CPU and allocation RPCs and
    // by the GC filter. The result is committed only while the session
    // that asked for it is still current.
    final resolution = await _resolveMainIsolateId();
    if (_disposed) {
      _cleanup();
      return false;
    }
    if (gen != _sessionGeneration) return false;
    _mainIsolateId = resolution.id;
    _verifiedOwnIsolateId = resolution.verified ? resolution.id : null;
    debugPrint(
      'Sleuth: VM isolate ${resolution.id} '
      '(${resolution.verified ? 'verified' : 'not verified'}); '
      'legacy pick ${resolution.legacyId}',
    );

    // Subscribe to event streams
    await _subscribeToStreams(service);
    if (_disposed) {
      _cleanup();
      return false;
    }

    // Start periodic timeline polling
    _startTimelinePolling();

    _connected = true;
    onConnectionChanged?.call(true);
    return true;
  }

  /// Test-only: runs the post-connect session start against [service],
  /// the same path [connect] takes once its WebSocket is open.
  @visibleForTesting
  Future<bool> startSessionForTest(VmService service) => _startSession(service);

  /// Reconnect with exponential backoff: 1s → 2s → 4s → 8s → 16s
  /// (cumulative ~31s before giving up).
  ///
  /// Pre-v0.16.0 this ladder stopped at 4s (7s cumulative), which was
  /// shorter than the documented 30s reconnect window and too
  /// impatient for cold-start scenarios on Android emulators where the
  /// VM service socket can take ~10–20s to bind. v0.16.0 extended the
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

  Future<void> _subscribeTimeline(VmService service) async {
    if (!streamTimeline) {
      _timelineSource = TimelineSource.poll;
      return;
    }
    final gen = _sessionGeneration;
    try {
      _timelineSub = service.onTimelineEvent.listen((event) {
        if (gen != _sessionGeneration || _disposed) return;
        _onTimelineBlock(event);
      });
      await service.streamListen(EventStreams.kTimeline);
      if (gen != _sessionGeneration) return;
      _timelineSource = TimelineSource.stream;
      _streamSubscribedAtUs = _streamNowUs();
    } catch (_) {
      // An older VM or an embedder without the stream: poll. A later
      // session owns the subscription field by now; leave it alone.
      if (gen != _sessionGeneration) return;
      await _timelineSub?.cancel();
      _timelineSub = null;
      if (gen == _sessionGeneration) _timelineSource = TimelineSource.poll;
    }
  }

  void _onTimelineBlock(Event event) {
    if (event.kind != EventKind.kTimelineEvents) return;
    final block = event.timelineEvents;
    if (block == null || block.isEmpty) return;
    _streamBlocks++;
    _streamEvents += block.length;
    var newest = -1;
    for (final e in block) {
      final json = e.json;
      final ts = json?['ts'];
      if (ts is int && ts > newest && !_isAsyncPhase(json!['ph'])) {
        newest = ts;
      }
    }
    if (newest >= 0 && !_readInFlight) {
      _lastStreamLagMs = (_streamNowUs() - newest) ~/ 1000;
    }
    _streamBuffer.add(block);
    _streamBufferedEvents += block.length;
    while (_streamBufferedEvents > streamBufferCap &&
        _streamBuffer.length > 1) {
      final dropped = _streamBuffer.removeAt(0);
      _streamBufferedEvents -= dropped.length;
      _streamEventsDropped += dropped.length;
    }
  }

  static bool _isAsyncPhase(Object? ph) =>
      ph == 'b' ||
      ph == 'e' ||
      ph == 'n' ||
      ph == 's' ||
      ph == 't' ||
      ph == 'f' ||
      ph == 'S' ||
      ph == 'T' ||
      ph == 'p' ||
      ph == 'F';

  void _noteSeen(List<TimelineEvent> events) {
    for (final e in events) {
      final json = e.json;
      if (json == null) continue;
      final ts = json['ts'];
      final tid = json['tid'];
      if (ts is! int || tid is! int || _isAsyncPhase(json['ph'])) continue;
      final seen = _newestSeenByTid[tid];
      if (seen == null || ts > seen) _newestSeenByTid[tid] = ts;
    }
  }

  List<TimelineEvent> _drainStream() {
    final events = <TimelineEvent>[for (final block in _streamBuffer) ...block];
    _streamBuffer.clear();
    _streamBufferedEvents = 0;
    return events;
  }

  /// Switches the session to polling when the stream delivered no block
  /// while frames were drawn for [streamSilentFallback]. A quiet
  /// stream that has delivered blocks stays: on a static screen blocks
  /// arrive seconds apart.
  Future<void> _fallBackIfStreamSilent() async {
    final subscribedAt = _streamSubscribedAtUs;
    if (_timelineSource != TimelineSource.stream ||
        _streamBlocks > 0 ||
        subscribedAt == null) {
      return;
    }
    final newestFrame = newestFrameRasterFinishUs?.call();
    if (newestFrame == null || newestFrame <= subscribedAt) return;
    if (_streamNowUs() - subscribedAt < streamSilentFallback.inMicroseconds) {
      return;
    }
    _timelineSource = TimelineSource.poll;
    await _timelineSub?.cancel();
    _timelineSub = null;
    _streamBuffer.clear();
    _streamBufferedEvents = 0;
    try {
      await _service?.streamCancel(EventStreams.kTimeline);
    } catch (_) {
      // Already gone with the session.
    }
  }

  /// Whether a catch-up read is due: the newest frame finished more than
  /// [catchUpStaleMicros] after the newest event seen on a frame or raster
  /// thread and the last read is [catchUpMinInterval] old, or the last
  /// read (or the subscription) is [catchUpMaxInterval] old. [force] (a
  /// flush) is always due.
  bool _catchUpDue({required int nowUs, required bool force}) {
    if (force) return true;
    final last = _lastCatchUpAtUs ?? _streamSubscribedAtUs;
    if (last != null && nowUs - last >= catchUpMaxInterval.inMicroseconds) {
      return true;
    }
    if (_lastCatchUpAtUs case final at?
        when nowUs - at < catchUpMinInterval.inMicroseconds) {
      return false;
    }
    final newestFrame = newestFrameRasterFinishUs?.call();
    if (newestFrame == null) return false;
    for (final tid in _catchUpTids) {
      final seen = _newestSeenByTid[tid];
      if (seen != null && newestFrame - seen > catchUpStaleMicros) return true;
    }
    return false;
  }

  /// The frame and raster threads whose newest events decide on a
  /// catch-up read.
  Set<int> get _catchUpTids => {..._frameThreadIdle.keys, ..._rasterTids};

  Future<void> _subscribeToStreams(VmService service) async {
    // Before the first read, which runs at the first tick: a block that
    // finished between that read and a later subscription would never be
    // posted, and its events after the read would reach neither path. The
    // per-thread cursors drop what both deliver.
    await _subscribeTimeline(service);
    try {
      await service.streamListen(EventStreams.kGC);
      _gcSub = service.onGCEvent.listen((event) {
        // Drop the copies the VM posts for other isolates. An unverified
        // id, or an event without an isolate ref, passes through.
        final own = _verifiedOwnIsolateId;
        final eventIsolate = event.isolate?.id;
        if (own != null && eventIsolate != null && eventIsolate != own) {
          return;
        }
        onGcEvent?.call(event);
      });
    } catch (_) {
      // GC stream may not be available on all platforms
    }

    // Event-loop stalls. The stream id and event kind are strings because
    // `EventStreams.kTimer` and `onTimerEvent` need vm_service 15.0.1, and
    // the 3.32 floor resolves 15.0.0. A VM before Dart 3.9 rejects the
    // stream id (RPC error -32602).
    final timerCallback = onTimerEvent;
    if (timerCallback != null) {
      try {
        await service.streamListen('Timer');
        _timerStreamAvailable = true;
        _timerSub = service.onEvent('Timer').listen((event) {
          final own = _verifiedOwnIsolateId;
          final eventIsolate = event.isolate?.id;
          if (own != null && eventIsolate != null && eventIsolate != own) {
            return;
          }
          timerCallback(event);
        });
      } catch (_) {
        _timerStreamAvailable = false;
      }
      final pauseCallback = onPauseEvent;
      if (_timerStreamAvailable == true && pauseCallback != null) {
        bool own(Event event) {
          final ownId = _verifiedOwnIsolateId;
          final eventIsolate = event.isolate?.id;
          return ownId == null || eventIsolate == null || eventIsolate == ownId;
        }

        try {
          await service.streamListen(EventStreams.kDebug);
          _debugSub = service.onDebugEvent.listen((event) {
            if (own(event)) pauseCallback(event);
          });
        } catch (_) {
          // Another client may hold the stream, or the VM refuses it; pauses
          // then count toward stalls.
        }
        try {
          await service.streamListen(EventStreams.kIsolate);
          _isolateSub = service.onIsolateEvent.listen((event) {
            if (event.kind == EventKind.kIsolateReload && own(event)) {
              pauseCallback(event);
            }
          });
        } catch (_) {
          // As above, for reloads.
        }
      }
    }

    // Outside release builds the framework posts a `Flutter.Frame`
    // extension event for every frame. Subscribing makes the VM send
    // each one here and decode it on the UI isolate, so subscribe only
    // when someone consumes the events.
    final extensionCallback = onExtensionEvent;
    if (extensionCallback == null) return;
    try {
      await service.streamListen(EventStreams.kExtension);
      _extensionSub = service.onExtensionEvent.listen(extensionCallback);
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

  /// Test-only: one ordinary tick, as the periodic timer runs it (no
  /// forced catch-up read).
  @visibleForTesting
  Future<void> tickForTest() => _pollTimeline();

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
        'Capture procedures keep the existing stream set. The ring '
        'buffer will likely overflow if a scenario runs longer than '
        'about 5 s with the Embedder or GC streams on.',
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

  /// In-flight async platform-channel calls, carried across polls so a
  /// call whose `e` lands in the next batch still yields a duration.
  /// Capped by the parser; stale entries evicted by the age sweep;
  /// cleared in `_cleanup()`.
  final PendingChannelBegins _pendingChannelBegins = PendingChannelBegins();

  /// Frame threads and the idle stretch open on each at the end of the
  /// last parse, so a gap that spans two batches is found
  /// ([TimelineParser.parse] `frameThreadIdle`). Cleared in `_cleanup`.
  final Map<int, int?> _frameThreadIdle = {};

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
  /// [fetchOverlapMicros] before the newest event seen, far inside this
  /// age.
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

  /// How far before the newest event seen a windowed fetch starts: one
  /// poll interval.
  ///
  /// Covers events a thread appends with a timestamp older than another
  /// thread's newest event. A begin/end pair that straddles a fetch is
  /// joined by the pending-begin maps, not by re-fetching the begin, so
  /// the overlap does not need to span
  /// [TimelineParser.maxReconstructedPhaseUs]. The per-thread cursors drop
  /// the events the overlap reads again.
  static const int fetchOverlapMicros = 500000;

  /// Margin added past the VM's current timeline clock reading so events
  /// stamped between the clock read and the fetch are included.
  static const int _windowExtentSlackUs = 1000000;

  /// Polls in this session that fell back to a full fetch after the
  /// timeline clock read failed or ran behind the newest event seen.
  int _windowFallbacks = 0;

  /// Window fallbacks in a row. At [_fallbacksBeforeFullRead] the newest
  /// event seen is forgotten and the next poll reads the whole buffer
  /// with no floor, so a bad newest timestamp cannot hold the window
  /// shut for the rest of the session.
  int _consecutiveWindowFallbacks = 0;
  static const int _fallbacksBeforeFullRead = 3;

  /// Set when [_consecutiveWindowFallbacks] forgot the newest event: the
  /// next full read counts as a window fallback.
  bool _fullReadAfterFallbacks = false;

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
    int? decodeUs;
    var parseUs = 0;
    var dispatchUs = 0;
    DispatchSegments? segments;
    var tailUs = 0;
    var memoryUs = 0;
    final tailWindows = <(int, int)>[];
    final pollStartUs = _rpcClockUs();
    _cpuSpans.pruneBefore(pollStartUs);
    _allocationSpans.pruneBefore(pollStartUs);
    var eventCount = 0;
    var duplicates = 0;
    var windowFallback = false;
    final watch = Stopwatch();
    try {
      // Fetch window: the whole buffer on the first poll of a session,
      // otherwise from `fetchOverlapMicros` before the newest event seen
      // up to the VM's current clock plus slack. The overlap picks up
      // events a thread wrote late with an older `ts`; a begin/end pair
      // split across fetches is joined by the pending-begin maps. The
      // per-tid cursors drop what was already processed. Nothing is cleared, so events written between two
      // fetches are never lost and DevTools keeps its timeline.
      await _fallBackIfStreamSilent();
      if (myGen != _sessionGeneration || _disposed) return;
      List<TimelineEvent>? events;
      var floorUs = 0;
      var readFailed = false;
      if (_timelineSource == TimelineSource.stream && _sessionFirstReadDone) {
        // Stream tick: the blocks that arrived since the last tick, plus
        // every thread's unfinished block when a catch-up read is due.
        floorUs = _streamFloorUs;
        events = _drainStream();
        // The drained blocks count as seen before deciding on a read;
        // otherwise every tick on a busy screen looked a tick behind.
        _noteSeen(events);
        if (_catchUpDue(nowUs: _streamNowUs(), force: forceFresh)) {
          final nowUs = _streamNowUs();
          _lastCatchUpAtUs = nowUs;
          _catchUpReads++;
          watch
            ..reset()
            ..start();
          _readInFlight = true;
          try {
            // A window no event falls in: the VM posts every thread's
            // unfinished block before it answers, so the blocks are in the
            // buffer once the response arrives. The answer itself carries
            // only the threads' metadata.
            await _fetchTimeline(nowUs + catchUpWindowAheadMicros, 1);
            final receivedUs = _timelineResponseReceivedUs;
            if (receivedUs >= 0) decodeUs = _rpcClockUs() - receivedUs;
          } catch (_) {
            // The blocks drained above still go out this tick.
            readFailed = true;
            _countPollFailure();
          } finally {
            _readInFlight = false;
            rpcUs = watch.elapsedMicroseconds;
          }
          if (decodeUs != null && decodeUs > rpcUs) decodeUs = rpcUs;
          if (myGen != _sessionGeneration || _disposed) return;
          final flushed = _drainStream();
          _noteSeen(flushed);
          events.addAll(flushed);
        }
      } else {
        // The session's first read covers what came before the stream;
        // the blocks buffered until now hold nothing it does not.
        if (_timelineSource == TimelineSource.stream) _drainStream();
        var lastMaxTs = _lastMaxTs;
        int? originUs;
        int? extentUs;
        if (lastMaxTs == null && _fullReadAfterFallbacks) {
          _fullReadAfterFallbacks = false;
          windowFallback = true;
          _windowFallbacks++;
        }
        if (lastMaxTs != null) {
          originUs = math.max(0, lastMaxTs - fetchOverlapMicros);
          watch.start();
          final clockReadStartUs = _rpcClockUs();
          final nowUs = await _readTimelineClock();
          tailUs += watch.elapsedMicroseconds;
          tailWindows.add((clockReadStartUs, _rpcClockUs()));
          if (myGen != _sessionGeneration || _disposed) return;
          if (nowUs != null && _clampToClock(nowUs)) {
            lastMaxTs = _lastMaxTs!;
            originUs = math.max(0, lastMaxTs - fetchOverlapMicros);
          }
          if (nowUs == null || nowUs < lastMaxTs) {
            // The clock read failed or is not on the event clock: read the
            // whole buffer and drop everything before the window client
            // side, so evicted cursors cannot replay old events.
            windowFallback = true;
            _windowFallbacks++;
            floorUs = originUs;
            originUs = null;
            if (++_consecutiveWindowFallbacks >= _fallbacksBeforeFullRead) {
              _consecutiveWindowFallbacks = 0;
              _lastMaxTs = null;
              _fullReadAfterFallbacks = true;
            }
          } else {
            _consecutiveWindowFallbacks = 0;
            extentUs = nowUs - originUs + _windowExtentSlackUs;
          }
        }
        // A session after the first starts from a window ending at the VM
        // clock instead of re-reading the whole buffer.
        if (originUs == null &&
            lastMaxTs == null &&
            !windowFallback &&
            _wholeBufferRead) {
          final nowUs = await _readTimelineClock();
          if (myGen != _sessionGeneration || _disposed) return;
          if (nowUs != null) {
            originUs = math.max(0, nowUs - firstWindowMicros);
            extentUs = nowUs - originUs + _windowExtentSlackUs;
          }
        }
        final Timeline timeline;
        watch
          ..reset()
          ..start();
        _readInFlight = _timelineSource == TimelineSource.stream;
        try {
          timeline = await _fetchTimeline(originUs, extentUs);
          final receivedUs = _timelineResponseReceivedUs;
          if (receivedUs >= 0) decodeUs = _rpcClockUs() - receivedUs;
        } finally {
          _readInFlight = false;
          rpcUs = watch.elapsedMicroseconds;
        }
        // Both readings come from monotonic clocks started at different
        // instants; the decode lies inside the await by construction.
        if (decodeUs != null && decodeUs > rpcUs) decodeUs = rpcUs;
        // Drop stale poll if reconnect/dispose ran during the await.
        if (myGen != _sessionGeneration || _disposed) return;
        // An empty whole-buffer read leaves the next read whole too: it
        // found nothing to start from.
        if (originUs == null && (timeline.traceEvents?.isNotEmpty ?? false)) {
          _wholeBufferRead = true;
        }
        if (_timelineSource == TimelineSource.stream &&
            !_sessionFirstReadDone) {
          _streamFloorUs = originUs ?? 0;
        }
        _sessionFirstReadDone = true;
        events = timeline.traceEvents;
      }
      if (!readFailed) _consecutivePollFailures = 0;
      eventCount = events?.length ?? 0;
      ParsedTimelineData? parsed;
      final ownParseStart = OwnWorkLog.now();
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
          frameThreadIdle: _frameThreadIdle,
          cursorsByTid: _lastProcessedTsByTid,
          minTimestampUs: floorUs,
        );
        duplicates = parsed.duplicatesDropped;
        for (final MapEntry(key: tid, value: ts)
            in parsed.newestTsByTid.entries) {
          final seen = _newestSeenByTid[tid];
          if (seen == null || ts > seen) _newestSeenByTid[tid] = ts;
        }
        _rasterTids.addAll(parsed.rasterTids);
        final batchMaxTs = parsed.maxTimestampUs;
        final currentMaxTs = _lastMaxTs;
        if (batchMaxTs >= 0 &&
            (currentMaxTs == null || batchMaxTs > currentMaxTs) &&
            !(_fullReadAfterFallbacks && currentMaxTs == null)) {
          _lastMaxTs = batchMaxTs;
        }
        // Evict orphan begins (B with no matching E within the idle
        // window). Compares event-relative monotonic `ts` so the sweep
        // is drift-free across wall-clock skews. Skipped when the batch
        // accepted no timestamped event.
        _sweepStalePendingBegins(batchMaxTs);
        parseUs = watch.elapsedMicroseconds;
      }
      if (parsed != null) _recordVmHeldGaps(parsed.uiThreadGaps);
      ownWorkLog.record(ownParseStart, OwnWorkLog.now());
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
        ownWorkLog.measure(
          () => onTimelineData?.call(
            parsed ?? TimelineParser.parse(const <TimelineEvent>[]),
          ),
        );
        dispatchUs = watch.elapsedMicroseconds;
        segments = readDispatchSegments?.call();
      }
      watch
        ..reset()
        ..start();
      final tailStartUs = _rpcClockUs();
      try {
        memoryUs = await _pollTail(myGen);
      } finally {
        tailUs += watch.elapsedMicroseconds;
        tailWindows.add((tailStartUs, _rpcClockUs()));
      }
    } catch (e) {
      // A poll that outlived its session leaves the new session alone.
      if (myGen == _sessionGeneration && !_disposed) _countPollFailure();
    } finally {
      watch.stop();
      final responseChars = _takeTimelineResponseChars();
      if (myGen == _sessionGeneration && !_disposed) {
        final detectorsUs = segments?.detectors ?? 0;
        final correlateUs = segments?.correlate ?? 0;
        final aggregateUs = segments?.aggregate ?? 0;
        _recordPollTimings(
          PollTimings(
            rpcMicros: rpcUs,
            decodeMicros: decodeUs,
            parseMicros: parseUs,
            dispatchMicros: dispatchUs,
            dispatchDetectorsMicros: detectorsUs,
            dispatchCorrelateMicros: correlateUs,
            dispatchAggregateMicros: aggregateUs,
            dispatchOtherMicros: math.max(
              0,
              dispatchUs - detectorsUs - correlateUs - aggregateUs,
            ),
            tailMicros: tailUs,
            tailCpuSamplesMicros: math.min(
              tailUs,
              _cpuSpans.overlapWith(tailWindows),
            ),
            tailAllocationProfileMicros: math.min(
              tailUs,
              _allocationSpans.overlapWith(tailWindows),
            ),
            tailMemoryMicros: memoryUs,
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

  /// One failed RPC retries on the next tick; a run of failures means the
  /// connection is gone (see [_consecutivePollFailures]).
  void _countPollFailure() {
    _consecutivePollFailures++;
    if (_consecutivePollFailures >= pollFailuresBeforeDisconnect) {
      _consecutivePollFailures = 0;
      _handleConnectionLost();
    }
  }

  /// Issues the poll's `getVMTimeline` request (windowed when [originUs]
  /// is non-null) with the raw-response length capture armed (see
  /// [_attachWireListeners]).
  Future<Timeline> _fetchTimeline(int? originUs, int? extentUs) {
    _timelineRequestId = null;
    _closeTimelineOwnSpan();
    _timelineResponseChars = -1;
    _timelineResponseReceivedUs = -1;
    _armedTimelineCapUs = originUs == null
        ? ownTimelineFullReadCapUs
        : ownTimelineRpcCapUs;
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
  /// Bounds the session's timestamps by the timeline clock reading
  /// [nowUs]. No window reaches past `nowUs + _windowExtentSlackUs`, so a
  /// position beyond that bound came from an event stamped on another
  /// clock.
  ///
  /// Thread cursors past the bound are rewound to the newest cursor
  /// within it, so later events on those threads are not dropped as
  /// already seen; when every cursor lies past the bound, the clock is
  /// the outlier and the cursors stay. A newest event past the bound
  /// becomes that newest cursor and the call returns true, so this poll
  /// fetches a window; with no cursor within the bound it is pulled back
  /// to the bound for later polls and this poll falls back to a full
  /// read.
  bool _clampToClock(int nowUs) {
    final ceilingUs = nowUs + _windowExtentSlackUs;
    final newest = TimelineParser.clampOutlierCursors(
      _lastProcessedTsByTid,
      ceilingUs: ceilingUs,
    );
    final lastMaxTs = _lastMaxTs;
    if (lastMaxTs == null || lastMaxTs <= ceilingUs) return false;
    if (newest != null) {
      _lastMaxTs = newest;
      return true;
    }
    _lastMaxTs = ceilingUs;
    return false;
  }

  Future<int?> _readTimelineClock() async {
    try {
      final stamp = await _service!.getVMTimelineMicros();
      return stamp.timestamp;
    } catch (_) {
      return null;
    }
  }

  /// The heap memory sample that follows each poll. Returns the
  /// microseconds spent awaiting `getMemoryUsage` (0 when it did not
  /// run). Drops the sample when the session moved on.
  Future<int> _pollTail(int myGen) async {
    // Poll heap memory (piggybacked on timeline poll, near-zero cost)
    if (_mainIsolateId == null || onHeapSample == null) return 0;
    final watch = Stopwatch()..start();
    try {
      final mem = await _service!.getMemoryUsage(_mainIsolateId!);
      watch.stop();
      if (myGen != _sessionGeneration || _disposed) {
        return watch.elapsedMicroseconds;
      }
      ownWorkLog.measure(
        () => onHeapSample?.call(
          HeapSample(
            heapUsage: mem.heapUsage ?? 0,
            heapCapacity: mem.heapCapacity ?? 0,
            externalUsage: mem.externalUsage ?? 0,
            timestamp: DateTime.now(),
            rssBytes: _readRssBytes(),
          ),
        ),
      );
    } on SentinelException {
      watch.stop();
      // Isolate ID stale (e.g., after hot restart) — re-fetch, unless
      // a reconnect replaced the service during the await.
      await _refreshMainIsolateId(myGen);
    } catch (_) {
      watch.stop();
      // Memory poll failed but timeline poll succeeded — don't reconnect.
      // Will retry on next poll cycle.
    }
    return watch.elapsedMicroseconds;
  }

  /// Monotonic clock for [_cpuSpans], [_allocationSpans] and the decode
  /// stamp.
  final Stopwatch _rpcClock = Stopwatch()..start();
  int _rpcClockUs() =>
      _rpcClockOverride?.call() ?? _rpcClock.elapsedMicroseconds;

  int Function()? _rpcClockOverride;

  /// Test-only: replaces the monotonic RPC clock (microseconds).
  @visibleForTesting
  set rpcClockForTest(int Function() clock) => _rpcClockOverride = clock;

  /// Age after which an unanswered `getCpuSamples` request no longer
  /// blocks the next one. A VM that never answers while the socket stays
  /// open would otherwise stop CPU attribution until a reconnect.
  static const Duration cpuSamplesInFlightStaleAfter = Duration(seconds: 30);

  /// Start of the last `getCpuSamples` request on [_rpcClock].
  int? _lastCpuSamplesRequestUs;

  /// In-flight `getCpuSamples` requests, for
  /// [PollTimings.tailCpuSamplesMicros].
  late final RpcSpanTracker _cpuSpans = RpcSpanTracker(_rpcClockUs);

  /// In-flight `getAllocationProfile` requests, for
  /// [PollTimings.tailAllocationProfileMicros] and
  /// [drainAllocationProfileReads]. A request stays open until the VM
  /// answers, even when its caller already timed out.
  late final RpcSpanTracker _allocationSpans = RpcSpanTracker(_rpcClockUs);

  /// Holds placed by [holdAllocationProfileReads]. They outlive a
  /// reconnect; each one ends with [releaseAllocationProfileReads].
  int _allocationReadHolds = 0;

  PollTimings? _lastPollTimings;
  final PollTimingsWindow _timingsWindow = PollTimingsWindow();
  int _duplicatesDroppedTotal = 0;

  /// Timings of the most recent completed poll of this session; null
  /// before the first poll.
  PollTimings? get lastPollTimings => _lastPollTimings;

  /// Largest RPC segment over the last 32 polls; null before the first.
  int? get maxPollRpcMicros => _timingsWindow.maxRpcMicros;

  /// Largest decode segment over the last 32 polls; null before the first
  /// poll and when none of them matched its raw response.
  int? get maxPollDecodeMicros => _timingsWindow.maxDecodeMicros;

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

  /// [OwnWorkLog.open] handle of the poll's in-flight `getVMTimeline`
  /// request; null when none is open.
  int? _timelineOwnSpan;

  /// The longest part of a poll's `getVMTimeline` round trip counted as
  /// Sleuth's own work.
  ///
  /// The VM holds its timeline lock while it writes the response, and a
  /// thread that fills its event block in that time waits for the lock.
  /// On iOS and Android the UI and platform threads are one thread, so a
  /// frame whose vsync lands inside the wait starts late with nothing
  /// traced in the gap. On an iPhone 12 Sleuth's polls delayed frame starts
  /// by 5 to 20 ms. The wait lies between the request and its response, so
  /// that span counts as own work for frame start delay. The client logs
  /// the span when it sends the request, because frame timings can arrive
  /// before the response, and cuts it short when the response arrives. The
  /// cap bounds what the span can excuse when the app's own work holds the
  /// response back or no response is matched.
  @visibleForTesting
  static const int ownTimelineRpcCapUs = 25000;

  /// [ownTimelineRpcCapUs] for a full timeline read (the session's first
  /// poll and the fallbacks), which writes the whole buffer. On an iPhone
  /// 12 a full read from the host delayed frame starts by 23 to 50 ms.
  @visibleForTesting
  static const int ownTimelineFullReadCapUs = 60000;

  /// The part of a `getCpuSamples` request counted as Sleuth's own work.
  /// On an iPhone 12 the VM held the UI isolate for 250 to 410 ms, within
  /// the first 450 ms after the request was sent.
  @visibleForTesting
  static const int ownCpuSamplesCapUs = 600000;

  /// Cap for the timeline request being sent, set by [_fetchTimeline].
  int _armedTimelineCapUs = ownTimelineRpcCapUs;

  /// Sleuth's recent VM requests during which the VM can hold the UI
  /// thread (timeline reads, CPU samples). Each has a start and an end in
  /// `Timeline.now` microseconds; the end is null while it is in flight.
  final List<_RequestWindow> _requestWindows = [];

  _RequestWindow _openRequestWindow() {
    final now = OwnWorkLog.now();
    _requestWindows.removeWhere(
      (w) => w.endUs != null && w.endUs! < now - ownWorkLog.retainUs,
    );
    final window = _RequestWindow(now);
    _requestWindows.add(window);
    return window;
  }

  /// Logs as Sleuth's own work each part of a UI-thread gap in [gaps] that
  /// lies inside one of Sleuth's VM requests. A gap is a stretch of the
  /// timeline with no event at all, so it measures the stall. The capped
  /// span opened with the request is only an estimate made before the
  /// response. On a Galaxy A07 the timeline read held the UI thread for up
  /// to 70 ms, past the 25 ms cap.
  void _recordVmHeldGaps(List<(int, int)> gaps) {
    if (gaps.isEmpty || _requestWindows.isEmpty) return;
    final now = OwnWorkLog.now();
    for (final (gapStart, gapEnd) in gaps) {
      for (final window in _requestWindows) {
        final start = gapStart > window.startUs ? gapStart : window.startUs;
        final windowEnd = window.endUs ?? now;
        final end = gapEnd < windowEnd ? gapEnd : windowEnd;
        if (end > start) ownWorkLog.record(start, end);
      }
    }
  }

  /// The window of the poll's in-flight timeline request.
  _RequestWindow? _timelineWindow;

  /// Length of the matched raw response; −1 until matched.
  int _timelineResponseChars = -1;

  /// [_rpcClock] reading when the matched raw response arrived; −1 until
  /// matched. package:vm_service decodes the response and builds the
  /// `Timeline` on this isolate after `onReceive` fires, so the time
  /// from here to the completed await is the decode.
  int _timelineResponseReceivedUs = -1;

  static final RegExp _requestIdPattern = RegExp(r'"id":"([^"]*)"');

  /// Listens to the service's raw wire traffic to measure the size of
  /// each poll's timeline response. Request ids are private to
  /// package:vm_service; `onSend` fires synchronously with the encoded
  /// request (which carries the id) before it is written, and
  /// `onReceive` fires with each raw response before it is decoded. The
  /// listeners only read lengths and short substrings, and stamp the
  /// arrival time of the poll's response.
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
        _timelineOwnSpan = ownWorkLog.open(
          OwnWorkLog.now(),
          _armedTimelineCapUs,
        );
        _timelineWindow = _openRequestWindow();
      });
      _receiveSub = service.onReceive.listen((message) {
        // The listener runs synchronously before package:vm_service
        // decodes the message; the decode is Sleuth's own UI-isolate work.
        ownWorkLog.recordUntilMicrotask();
        final id = _timelineRequestId;
        if (id == null) return;
        if (!responseCarriesId(message, id)) return;
        _timelineResponseReceivedUs = _rpcClockUs();
        _timelineResponseChars = message.length;
        _timelineRequestId = null;
        _closeTimelineOwnSpan();
      });
    } catch (_) {
      // A test double without wire streams leaves every poll unmatched
      // (null decode and response size).
    }
  }

  /// Characters at each end of a raw response searched for its id.
  static const int _idSearchChars = 64;

  /// Whether the raw JSON-RPC [message] is the response to request [id].
  ///
  /// A response object carries its id at its start or its end, so only
  /// the first and last [_idSearchChars] characters are searched; ids
  /// nested in the payload (trace event ids in a timeline export,
  /// extension event data) cannot match, and a multi-MB response costs
  /// two short scans.
  @visibleForTesting
  static bool responseCarriesId(String message, String id) {
    final needle = '"id":"$id"';
    final length = message.length;
    if (length <= 2 * _idSearchChars) return message.contains(needle);
    return message.substring(0, _idSearchChars).contains(needle) ||
        message.substring(length - _idSearchChars).contains(needle);
  }

  /// The matched response length of this poll, or null when the
  /// response was not matched; resets the capture.
  int? _takeTimelineResponseChars() {
    final chars = _timelineResponseChars;
    _timelineResponseChars = -1;
    _timelineResponseReceivedUs = -1;
    _timelineRequestId = null;
    _closeTimelineOwnSpan();
    return chars >= 0 ? chars : null;
  }

  /// Ends the open own-work span of the poll's timeline request now.
  void _closeTimelineOwnSpan() {
    _timelineWindow?.endUs ??= OwnWorkLog.now();
    _timelineWindow = null;
    final span = _timelineOwnSpan;
    if (span == null) return;
    _timelineOwnSpan = null;
    ownWorkLog.close(span, OwnWorkLog.now());
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
    _pendingChannelBegins.evictBefore(pendingCutoff);
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

  /// Resolves the isolate id for memory, CPU and allocation RPCs.
  ///
  /// Prefers this client's own isolate when the VM lists it. Otherwise
  /// falls back to the first non-system isolate, unverified. Writes no
  /// field: callers commit the result under their session check.
  Future<_IsolateResolution> _resolveMainIsolateId() async {
    try {
      final vm = await _service!.getVM();
      final isolates = vm.isolates;
      if (isolates == null || isolates.isEmpty) {
        return const _IsolateResolution(null, verified: false);
      }
      final legacy = isolates
          .firstWhere(
            (ref) => ref.isSystemIsolate != true,
            orElse: () => isolates.first,
          )
          .id;
      final own = _readOwnIsolateId();
      if (own != null && isolates.any((ref) => ref.id == own)) {
        return _IsolateResolution(own, verified: true, legacyId: legacy);
      }
      return _IsolateResolution(legacy, verified: false, legacyId: legacy);
    } catch (_) {
      return const _IsolateResolution(null, verified: false);
    }
  }

  String? _readOwnIsolateId() {
    try {
      final resolver = ownIsolateIdResolver;
      if (resolver != null) return resolver();
      return developer.Service.getIsolateId(isolate.Isolate.current);
    } catch (_) {
      // `Isolate.current` throws on web compilers.
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
    _lastPollTimings = null;
    _timingsWindow.clear();
    _duplicatesDroppedTotal = 0;
    _windowFallbacks = 0;
    _consecutiveWindowFallbacks = 0;
    _fullReadAfterFallbacks = false;
    _lastMaxTs = null;
    _cpuSpans.clear();
    _allocationSpans.clear();
    _lastCpuSamplesRequestUs = null;
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
    _frameThreadIdle.clear();
    _lastProcessedTsByTid.clear();
    _pollTimer?.cancel();
    _pollTimer = null;
    _controlWebServerTimer?.cancel();
    _controlWebServerTimer = null;
    _timelineSub?.cancel();
    _timelineSub = null;
    _timelineSource = null;
    _sessionFirstReadDone = false;
    _streamBuffer.clear();
    _streamBufferedEvents = 0;
    _streamBlocks = 0;
    _streamEvents = 0;
    _streamEventsDropped = 0;
    _catchUpReads = 0;
    _lastStreamLagMs = null;
    _streamSubscribedAtUs = null;
    _lastCatchUpAtUs = null;
    _readInFlight = false;
    _streamFloorUs = 0;
    _newestSeenByTid.clear();
    _rasterTids.clear();
    _gcSub?.cancel();
    _gcSub = null;
    _extensionSub?.cancel();
    _extensionSub = null;
    _timerSub?.cancel();
    _timerSub = null;
    _debugSub?.cancel();
    _debugSub = null;
    _isolateSub?.cancel();
    _isolateSub = null;
    _timerStreamAvailable = null;
    _requestWindows.clear();
    _timelineWindow = null;
    _mainIsolateId = null;
    _verifiedOwnIsolateId = null;
    _connected = false;
    try {
      _service?.dispose();
    } catch (_) {
      // Service may already be disconnected — disposal is best effort.
    }
    _service = null;
  }

  /// Query CPU samples for a time window. Returns null on error or
  /// timeout, and without issuing the RPC while an earlier request is
  /// still in flight (a timed-out request stays in flight until the VM
  /// answers or [cpuSamplesInFlightStaleAfter] passes) or within
  /// [cpuSamplesMinInterval] of the previous request.
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
    final nowUs = _rpcClockUs();
    _cpuSpans.abandonOpenBefore(
      nowUs - cpuSamplesInFlightStaleAfter.inMicroseconds,
    );
    if (_cpuSpans.openCount > 0) return null;
    final lastUs = _lastCpuSamplesRequestUs;
    if (lastUs != null &&
        nowUs - lastUs < cpuSamplesMinInterval.inMicroseconds) {
      return null;
    }
    _lastCpuSamplesRequestUs = nowUs;

    // The VM builds the answer on this isolate's thread, so the UI stops
    // while it does; nothing of it is Dart code the own-work log could
    // time.
    final ownSpan = ownWorkLog.open(OwnWorkLog.now(), ownCpuSamplesCapUs);
    final cpuWindow = _openRequestWindow();
    final gen = _sessionGeneration;
    try {
      return await _cpuSpans
          .track(
            service
                .getCpuSamples(isolateId, timeOriginUs, timeExtentUs)
                .whenComplete(() {
                  cpuWindow.endUs ??= OwnWorkLog.now();
                  if (ownSpan != null) {
                    ownWorkLog.close(ownSpan, OwnWorkLog.now());
                  }
                }),
          )
          .timeout(const Duration(milliseconds: 500));
    } on SentinelException {
      // Isolate ID stale (e.g., after hot restart) — re-fetch
      await _refreshMainIsolateId(gen);
      return null;
    } catch (_) {
      // CPU sample query failed — non-fatal, don't trigger reconnect
      return null;
    }
  }

  /// Query allocation profile for the main isolate. Returns null on
  /// error, on timeout, and while [allocationProfileReadsHeld] is true.
  ///
  /// [reset] resets the VM's accumulated counters for every reader. A
  /// timeout ends the wait, not the request: the VM still builds the
  /// profile and the response is still decoded on this isolate.
  Future<AllocationProfile?> getAllocationProfile({
    bool reset = false,
    Duration timeout = const Duration(milliseconds: 500),
  }) async {
    final service = _service;
    final isolateId = _mainIsolateId;
    if (service == null || isolateId == null) return null;
    if (_allocationReadHolds > 0) return null;

    final gen = _sessionGeneration;
    try {
      return await _allocationSpans
          .track(service.getAllocationProfile(isolateId, reset: reset))
          .timeout(timeout);
    } on SentinelException {
      await _refreshMainIsolateId(gen);
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Changes whenever a VM service session ends or a new one starts, so a
  /// caller can tell whether a reply belongs to the session it asked in.
  int get sessionGeneration => _sessionGeneration;

  /// Whether [getAllocationProfile] refuses new requests.
  bool get allocationProfileReadsHeld => _allocationReadHolds > 0;

  /// `getAllocationProfile` requests the VM has not answered yet.
  int get allocationProfileReadsInFlight => _allocationSpans.openCount;

  /// Makes [getAllocationProfile] return null without a request until a
  /// matching [releaseAllocationProfileReads]. Holds nest.
  void holdAllocationProfileReads() => _allocationReadHolds++;

  /// Ends one [holdAllocationProfileReads]. Extra calls do nothing.
  void releaseAllocationProfileReads() {
    if (_allocationReadHolds > 0) _allocationReadHolds--;
  }

  /// Waits until no `getAllocationProfile` request is in flight. Returns
  /// false when [timeout] passes first, or when there is no session or
  /// the session changes while waiting (a new session clears the
  /// in-flight record, so an empty record would not prove the old
  /// request finished).
  Future<bool> drainAllocationProfileReads({
    Duration timeout = const Duration(seconds: 10),
    Duration pollInterval = const Duration(milliseconds: 50),
  }) async {
    final gen = _sessionGeneration;
    bool sessionCurrent() => gen == _sessionGeneration && _service != null;
    if (!sessionCurrent()) return false;
    final waited = Stopwatch()..start();
    while (_allocationSpans.openCount > 0) {
      if (waited.elapsed >= timeout) return false;
      await Future<void>.delayed(pollInterval);
      if (!sessionCurrent()) return false;
    }
    return sessionCurrent();
  }

  /// Re-resolves the main isolate id after a stale-isolate error. The
  /// answer is kept only while the session that saw the error is still
  /// current. A verified own id is kept as is: the isolate this client
  /// runs on cannot be collected while the client runs.
  Future<void> _refreshMainIsolateId(int gen) async {
    if (gen != _sessionGeneration || _service == null) return;
    if (_verifiedOwnIsolateId != null) return;
    final resolution = await _resolveMainIsolateId();
    if (gen == _sessionGeneration && !_disposed) {
      _mainIsolateId = resolution.id;
    }
  }

  /// Test-only: ends the session as a reconnect does, so an in-flight
  /// poll or request finishes against a newer generation.
  @visibleForTesting
  void endSessionForTest() => _cleanup();

  /// Test-only view of the consecutive failed-poll counter.
  @visibleForTesting
  int get consecutivePollFailuresForTest => _consecutivePollFailures;

  /// Dispose all resources.
  void dispose() {
    _disposed = true;
    _cleanup();
  }
}

/// The isolate id a session should use, and whether the VM's isolate
/// list confirmed it as this client's own isolate.
@immutable
class _IsolateResolution {
  const _IsolateResolution(this.id, {required this.verified, this.legacyId});

  final String? id;
  final bool verified;

  /// The first non-system isolate, the pick used before own-id
  /// verification. Kept for the connect log line.
  final String? legacyId;
}

/// One of Sleuth's VM requests, in `Timeline.now` microseconds.
class _RequestWindow {
  _RequestWindow(this.startUs);
  final int startUs;
  int? endUs;
}
