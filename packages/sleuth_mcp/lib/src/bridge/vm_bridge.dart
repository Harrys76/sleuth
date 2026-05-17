import 'dart:async';

import 'package:meta/meta.dart';
import 'package:synchronized/synchronized.dart';
import 'package:vm_service/vm_service.dart' as vm;
import 'package:vm_service/vm_service_io.dart';

/// Bridges MCP tool handlers to the running app's VM service.
///
/// `Response.json` is the parsed sleuth envelope
/// `{connectionMode, schemaVersion, sessionUuid, data|error}` directly —
/// vm_service inlines the extension result string into the JSON-RPC
/// `result` field, no manual decode needed.
abstract class VmBridge {
  Future<bool> connect(Uri wsUri);

  /// Returns the inner sleuth envelope as a `Map`. Throws
  /// [VmBridgeException] on transport / decode failure, [SessionChangedException]
  /// when the responding session's UUID differs from the baseline captured
  /// at [connect] time.
  Future<Map<String, Object?>> callExtension(
    String method, {
    Map<String, dynamic> args = const <String, dynamic>{},
  });

  /// UUID captured from the first `ext.sleuth.diagnose` call at [connect]
  /// time. Used to detect hot-restart of the target app.
  String? get baselineSessionUuid;

  /// Envelope from the connect-time `ext.sleuth.diagnose` call. Tool
  /// handlers can read `data.packageVersion` from here without paying a
  /// second round-trip.
  Map<String, Object?>? get lastDiagnoseEnvelope;

  bool get isConnected;

  Future<void> disconnect();
}

/// Connect / dispatch failure not attributable to a session change.
class VmBridgeException implements Exception {
  VmBridgeException(this.message);
  final String message;
  @override
  String toString() => 'VmBridgeException: $message';
}

/// The target app's `sessionUuid` differs from the baseline. Indicates a
/// hot-restart or a different app at the same URI.
class SessionChangedException implements Exception {
  SessionChangedException({
    required this.baseline,
    required this.current,
  });
  final String baseline;
  final String current;
  @override
  String toString() =>
      'SessionChangedException: baseline=$baseline current=$current';
}

/// Production [VmBridge] over a real WebSocket VM service.
///
/// Connect / disconnect / reconnect serialize via [Lock] so concurrent
/// dispatches don't observe half-initialized state. `callServiceExtension`
/// itself runs outside the lock — vm_service handles concurrent calls.
class RealVmBridge implements VmBridge {
  RealVmBridge({
    this.callTimeout = const Duration(seconds: 10),
    Sink<String>? logger,
    String? targetIsolateIdOverride,
  })  : _logger = logger,
        _targetIsolateIdOverride = targetIsolateIdOverride;

  final Duration callTimeout;
  final Sink<String>? _logger;

  /// Bypasses [pickMainIsolate] when set. In-process tests use it to bind
  /// the bridge to the test isolate when sibling isolates share the host VM.
  final String? _targetIsolateIdOverride;

  vm.VmService? _service;
  String? _mainIsolateId;
  String? _baselineSessionUuid;
  Map<String, Object?>? _lastDiagnoseEnvelope;
  Uri? _wsUri;
  final Lock _connectLock = Lock();
  Future<void>? _reconnectInFlight;

  @override
  String? get baselineSessionUuid => _baselineSessionUuid;

  @override
  Map<String, Object?>? get lastDiagnoseEnvelope => _lastDiagnoseEnvelope;

  @override
  bool get isConnected => _service != null && _mainIsolateId != null;

  /// Prefers `name == 'main'`, then `startsWith('main')`, falls back to
  /// the first entry. Iteration follows the input order — a sorted
  /// fallback breaks apps where multiple isolates share the name.
  @visibleForTesting
  static vm.IsolateRef pickMainIsolate(List<vm.IsolateRef> isolates) {
    for (final i in isolates) {
      if (i.name == 'main') return i;
    }
    for (final i in isolates) {
      if ((i.name ?? '').startsWith('main')) return i;
    }
    return isolates.first;
  }

  @override
  Future<bool> connect(Uri wsUri) {
    return _connectLock.synchronized(() => _connectUnlocked(wsUri));
  }

  Future<bool> _connectUnlocked(Uri wsUri) async {
    final prior = _service;
    if (prior != null) {
      try {
        await prior.dispose();
      } catch (e) {
        _logger?.add('prior service dispose failed: $e');
      }
    }
    _service = null;
    _mainIsolateId = null;
    _wsUri = wsUri;
    try {
      _service = await vmServiceConnectUri(wsUri.toString())
          .timeout(const Duration(seconds: 5));
    } catch (e) {
      throw VmBridgeException('failed to connect: $e');
    }
    final vmInfo = await _service!.getVM();
    final isolates = vmInfo.isolates ?? <vm.IsolateRef>[];
    if (isolates.isEmpty) {
      throw VmBridgeException('no isolates on target VM service');
    }
    final override = _targetIsolateIdOverride;
    if (override != null) {
      _mainIsolateId = override;
    } else {
      final main = pickMainIsolate(isolates);
      _mainIsolateId = main.id;
      if (_mainIsolateId == null) {
        throw VmBridgeException('main isolate has no id');
      }
    }
    final diag = await _callExtensionRaw('ext.sleuth.diagnose');
    final uuid = diag['sessionUuid'];
    if (uuid is! String) {
      throw VmBridgeException(
        'ext.sleuth.diagnose returned no sessionUuid — is sleuth attached?',
      );
    }
    _baselineSessionUuid = uuid;
    _lastDiagnoseEnvelope = diag;
    return true;
  }

  @override
  Future<Map<String, Object?>> callExtension(
    String method, {
    Map<String, dynamic> args = const <String, dynamic>{},
  }) async {
    // Per-call retry budget so concurrent transport-close callers each get
    // their own retry instead of sharing a per-bridge flag.
    var retriesRemaining = 1;
    Map<String, Object?> inner;
    while (true) {
      try {
        inner = await _callExtensionRaw(method, args: args);
        break;
      } on _TransportClosed {
        if (retriesRemaining == 0 || _wsUri == null) rethrow;
        retriesRemaining--;
        await _ensureReconnected();
      }
    }
    final uuid = inner['sessionUuid'];
    if (uuid is String &&
        _baselineSessionUuid != null &&
        uuid != _baselineSessionUuid) {
      throw SessionChangedException(
        baseline: _baselineSessionUuid!,
        current: uuid,
      );
    }
    return inner;
  }

  /// Coalesces concurrent transport-close retries onto one reconnect.
  Future<void> _ensureReconnected() {
    final inFlight = _reconnectInFlight;
    if (inFlight != null) return inFlight;
    final wsUri = _wsUri;
    if (wsUri == null) {
      return Future.error(VmBridgeException('no wsUri for reconnect'));
    }
    final future = _connectLock.synchronized(() => _connectUnlocked(wsUri));
    _reconnectInFlight = future.whenComplete(() {
      _reconnectInFlight = null;
    });
    return _reconnectInFlight!;
  }

  Future<Map<String, Object?>> _callExtensionRaw(
    String method, {
    Map<String, dynamic> args = const <String, dynamic>{},
  }) async {
    final service = _service;
    final isolateId = _mainIsolateId;
    if (service == null || isolateId == null) {
      throw VmBridgeException('not connected');
    }
    vm.Response response;
    try {
      response = await service
          .callServiceExtension(method, isolateId: isolateId, args: args)
          .timeout(callTimeout);
    } on TimeoutException {
      throw VmBridgeException('$method timed out after $callTimeout');
    } on vm.RPCError catch (e) {
      // vm_service raises this RPCError when the socket closes or the
      // service is dispose()d mid-call — transport state, not an
      // extension rejection, so route into the reconnect path.
      final msg = e.message;
      if (msg.startsWith('Service connection disposed')) {
        throw _TransportClosed('$method against disposed service');
      }
      throw VmBridgeException('$method rejected: $msg (code ${e.code})');
    } on vm.SentinelException catch (e) {
      throw VmBridgeException('$method against expired isolate: $e');
    } catch (e) {
      throw _TransportClosed('$method failed: $e');
    }
    final envelope = response.json;
    if (envelope == null) {
      throw VmBridgeException('$method returned null json');
    }
    return Map<String, Object?>.from(envelope);
  }

  @override
  Future<void> disconnect() {
    return _connectLock.synchronized(_disconnectUnlocked);
  }

  Future<void> _disconnectUnlocked() async {
    try {
      await _service?.dispose();
    } catch (e) {
      _logger?.add('service dispose failed: $e');
    }
    _service = null;
    _mainIsolateId = null;
    _baselineSessionUuid = null;
    _lastDiagnoseEnvelope = null;
    _wsUri = null;
  }
}

class _TransportClosed implements Exception {
  _TransportClosed(this.message);
  final String message;
  @override
  String toString() => 'TransportClosed: $message';
}

/// Test-only fake that returns canned envelopes per extension name.
class FakeVmBridge implements VmBridge {
  FakeVmBridge({
    this.fakeSessionUuid = 'fake-session-uuid',
    Map<String, Map<String, Object?>> envelopes = const {},
  })  : _envelopes = Map.of(envelopes),
        _baseline = fakeSessionUuid;

  final String fakeSessionUuid;
  final Map<String, Map<String, Object?>> _envelopes;
  String _baseline;
  bool _connected = false;
  bool _sessionDrifted = false;

  /// Replace the canned envelope for a given extension name.
  void setEnvelope(String method, Map<String, Object?> envelope) {
    _envelopes[method] = envelope;
  }

  /// Force the next callExtension to throw a SessionChangedException.
  void simulateSessionChange(String newUuid) {
    _sessionDrifted = true;
    _baseline = newUuid;
  }

  @override
  String? get baselineSessionUuid => _baseline;

  @override
  Map<String, Object?>? get lastDiagnoseEnvelope =>
      _envelopes['ext.sleuth.diagnose'];

  @override
  bool get isConnected => _connected;

  @override
  Future<bool> connect(Uri wsUri) async {
    _connected = true;
    return true;
  }

  @override
  Future<Map<String, Object?>> callExtension(
    String method, {
    Map<String, dynamic> args = const <String, dynamic>{},
  }) async {
    if (!_connected) {
      throw VmBridgeException('not connected');
    }
    if (_sessionDrifted) {
      _sessionDrifted = false;
      throw SessionChangedException(
        baseline: 'old-uuid',
        current: _baseline,
      );
    }
    final canned = _envelopes[method];
    if (canned == null) {
      throw VmBridgeException('no canned envelope for $method');
    }
    return canned;
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
  }
}
