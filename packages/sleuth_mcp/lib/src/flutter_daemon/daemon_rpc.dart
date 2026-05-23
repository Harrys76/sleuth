import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'daemon_events.dart';

/// Surfaced when an RPC write fails (e.g. stdin closed, blocked).
class DaemonRpcException implements Exception {
  DaemonRpcException(this.message);
  final String message;
  @override
  String toString() => 'DaemonRpcException: $message';
}

/// Surfaced when a per-RPC response timeout expires.
class DaemonRpcTimeoutException implements Exception {
  DaemonRpcTimeoutException(this.method, this.timeout);
  final String method;
  final Duration timeout;
  @override
  String toString() =>
      'DaemonRpcTimeoutException: $method exceeded ${timeout.inSeconds}s';
}

/// Sends JSON-RPC requests to a `flutter --machine` child via its stdin
/// and correlates responses by id.
///
/// Request wire shape (single-element array, newline-terminated):
///   `[{"id":N,"method":"<name>","params":{...}}]\n`
///
/// Response wire shape (yielded by [DaemonParser] as [DaemonRpcResponse]):
///   `[{"id":N,"result":{...}}]\n` or `[{"id":N,"error":{...}}]\n`
class DaemonRpc {
  DaemonRpc({
    required IOSink stdin,
    required Stream<DaemonRpcResponse> responses,
    Duration writeTimeout = const Duration(seconds: 5),
    Sink<String>? logger,
  })  : _stdin = stdin,
        _writeTimeout = writeTimeout,
        _logger = logger {
    _sub = responses.listen(_dispatchResponse);
  }

  final IOSink _stdin;
  final Duration _writeTimeout;
  final Sink<String>? _logger;
  late final StreamSubscription<DaemonRpcResponse> _sub;
  int _nextId = 1;
  final Map<int, Completer<DaemonRpcResponse>> _inFlight = {};

  /// Send an RPC and await its response. [timeout] is the response
  /// deadline; the stdin write itself has a separate hard 5s timeout
  /// (because a stuck daemon won't drain our writes).
  Future<DaemonRpcResponse> call(
    String method,
    Map<String, Object?> params, {
    Duration? timeout,
  }) async {
    final id = _nextId++;
    final completer = Completer<DaemonRpcResponse>();
    _inFlight[id] = completer;
    final envelope =
        '[${jsonEncode({'id': id, 'method': method, 'params': params})}]\n';
    try {
      _stdin.add(utf8.encode(envelope));
      await _stdin.flush().timeout(_writeTimeout);
    } catch (e) {
      _inFlight.remove(id);
      throw DaemonRpcException('stdin write for $method failed: $e');
    }
    final future = timeout == null
        ? completer.future
        : completer.future.timeout(
            timeout,
            onTimeout: () {
              _inFlight.remove(id);
              throw DaemonRpcTimeoutException(method, timeout);
            },
          );
    return future;
  }

  void _dispatchResponse(DaemonRpcResponse r) {
    final c = _inFlight.remove(r.id);
    if (c == null) {
      _logger?.add('daemon RPC: out-of-band response id=${r.id} dropped');
      return;
    }
    c.complete(r);
  }

  Future<void> close() async {
    await _sub.cancel();
    // Fail any in-flight RPCs so callers don't hang forever.
    for (final c in _inFlight.values) {
      if (!c.isCompleted) {
        c.completeError(DaemonRpcException('rpc channel closed'));
      }
    }
    _inFlight.clear();
  }
}
