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
  }) : _stdin = stdin,
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

  /// Completes when [close] runs, so a call still writing to a stdin that
  /// flutter stopped reading returns at once.
  final Completer<void> _closed = Completer<void>();

  /// Send an RPC and await its response. [timeout] is the response
  /// deadline; the stdin write itself has a separate hard 5s timeout
  /// (because a stuck daemon won't drain our writes). After [close], and
  /// when [close] runs while the write is still pending, the call throws
  /// [DaemonRpcException].
  Future<DaemonRpcResponse> call(
    String method,
    Map<String, Object?> params, {
    Duration? timeout,
  }) async {
    if (_closed.isCompleted) {
      throw DaemonRpcException('rpc channel closed before $method was sent');
    }
    final id = _nextId++;
    final completer = Completer<DaemonRpcResponse>();
    // [close] can fail the completer while the write below still waits for
    // flutter to read its stdin. Nothing listens to the completer until the
    // write finishes, so mark its error as handled here. The caller still
    // gets the error from the future returned below.
    completer.future.ignore();
    _inFlight[id] = completer;
    final envelope =
        '[${jsonEncode({'id': id, 'method': method, 'params': params})}]\n';
    try {
      _stdin.add(utf8.encode(envelope));
      // Future.any also handles a late error from a flush it stopped
      // waiting for.
      await Future.any<void>([
        _stdin.flush().timeout(_writeTimeout),
        _closed.future,
      ]);
    } catch (e) {
      _inFlight.remove(id);
      throw DaemonRpcException('stdin write for $method failed: $e');
    }
    if (_closed.isCompleted) {
      _inFlight.remove(id);
      throw DaemonRpcException('rpc channel closed while $method was sent');
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

  /// Fails every call in flight with [DaemonRpcException] and stops reading
  /// responses. Idempotent. The calls are settled before anything is
  /// awaited, so a response subscription that is slow to cancel cannot keep
  /// a caller waiting.
  Future<void> close() async {
    if (!_closed.isCompleted) _closed.complete();
    final pending = List.of(_inFlight.values);
    _inFlight.clear();
    for (final c in pending) {
      if (!c.isCompleted) {
        c.completeError(DaemonRpcException('rpc channel closed'));
      }
    }
    await _sub.cancel();
  }
}
