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

/// Connects to the app's own VM Service for exact performance data.
///
/// Uses [dart:developer.Service.getInfo()] to get the VM service URI
/// and connects via WebSocket. Works reliably on desktop and iOS.
/// On Android, the connection may fail because the reported URI uses
/// an adb-forwarded port — in that case the controller falls back to
/// BASIC mode (FrameTiming + structural analysis).
class VmServiceClient {
  VmServiceClient({
    this.onTimelineData,
    this.onGcEvent,
    this.onHeapSample,
    this.onExtensionEvent,
    this.onConnectionChanged,
  });

  final TimelineDataCallback? onTimelineData;
  final VmEventCallback? onGcEvent;
  final HeapSampleCallback? onHeapSample;
  final VmEventCallback? onExtensionEvent;
  final void Function(bool connected)? onConnectionChanged;

  VmService? _service;
  StreamSubscription<Event>? _timelineSub;
  StreamSubscription<Event>? _gcSub;
  StreamSubscription<Event>? _extensionSub;
  Timer? _pollTimer;
  bool _disposed = false;
  bool _connected = false;
  bool _reconnecting = false;

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
  Future<bool> connect({
    int maxRetries = 3,
    Duration retryDelay = const Duration(milliseconds: 500),
  }) async {
    if (kReleaseMode || _disposed) return false;

    for (var attempt = 0; attempt <= maxRetries; attempt++) {
      try {
        final info = await developer.Service.getInfo();
        final uri = info.serverUri;

        if (uri == null) {
          if (attempt < maxRetries) {
            await Future<void>.delayed(retryDelay);
            continue;
          }
          return false;
        }

        // Convert HTTP URI to WebSocket URI
        final wsUri = _toWebSocketUri(uri);

        // Use a timeout to avoid hanging on unreachable addresses
        // (common on Android where the URI is host-forwarded).
        _service = await vmServiceConnectUri(wsUri.toString())
            .timeout(const Duration(seconds: 3));

        // Enable timeline streams for framework events
        await _service!.setVMTimelineFlags([
          'Dart',
          'Embedder',
          'GC',
        ]);

        // Resolve main isolate ID for getMemoryUsage() polling
        _mainIsolateId = await _resolveMainIsolateId();

        // Subscribe to event streams
        await _subscribeToStreams();

        // Start periodic timeline polling
        _startTimelinePolling();

        _connected = true;
        onConnectionChanged?.call(true);
        return true;
      } catch (_) {
        if (attempt < maxRetries) {
          await Future<void>.delayed(retryDelay);
        }
      }
    }
    return false;
  }

  /// Reconnect with exponential backoff (1s, 2s, 4s).
  Future<bool> reconnect() async {
    if (_reconnecting || _disposed) return false;
    _reconnecting = true;
    _cleanup();

    const delays = [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
    ];

    try {
      for (final delay in delays) {
        if (_disposed) return false;
        await Future<void>.delayed(delay);
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
    } catch (_) {}
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

  Future<void> _pollTimeline() async {
    if (_service == null || _disposed) return;

    try {
      final timeline = await _service!.getVMTimeline();
      final events = timeline.traceEvents;
      if (events != null && events.isNotEmpty) {
        final parsed = TimelineParser.parse(events);
        if (parsed.hasData) {
          onTimelineData?.call(parsed);
        }
      }
      // Clear the timeline buffer to avoid re-processing
      await _service!.clearVMTimeline();

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
      // Connection may have been lost
      if (!_disposed && !_reconnecting) {
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
    } catch (_) {}
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
