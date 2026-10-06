import 'dart:async';

/// Sends one `notifications/progress` frame for the request a
/// [ToolCallContext] serves.
typedef ProgressSender = void Function(num progress, String message);

/// Per-call state for one `tools/call` request: a way to report progress
/// when the client asked for it, and a signal that fires when the client
/// cancels the request.
///
/// The server runs each tool handler inside [run], so a handler reads its
/// context with [ToolCallContext.current]. Outside a `tools/call`, for
/// example when a test calls a handler directly, [current] is null and the
/// handler behaves as before.
class ToolCallContext {
  ToolCallContext({ProgressSender? sendProgress})
    : _sendProgress = sendProgress;

  static final Object _zoneKey = Object();

  /// The context of the `tools/call` request running in the current zone,
  /// or null outside one.
  static ToolCallContext? get current {
    final value = Zone.current[_zoneKey];
    return value is ToolCallContext ? value : null;
  }

  final ProgressSender? _sendProgress;
  final Completer<void> _cancelled = Completer<void>();
  num _lastProgress = 0;
  bool _finished = false;

  /// Runs [body] with this context as [current].
  R run<R>(R Function() body) => runZoned(body, zoneValues: {_zoneKey: this});

  /// True when the client sent a progress token with the request.
  bool get reportsProgress => _sendProgress != null;

  /// Sends a progress notification carrying [message]. The progress value
  /// goes up by one with every call, because the MCP spec requires it to
  /// increase. Does nothing when the client sent no progress token, after
  /// the request was cancelled, or after the handler returned.
  void reportProgress(String message) {
    final send = _sendProgress;
    if (send == null || _finished || isCancelled) return;
    _lastProgress += 1;
    send(_lastProgress, message);
  }

  /// Completes when the client cancels the request.
  Future<void> get cancelled => _cancelled.future;

  /// True once the client cancelled the request.
  bool get isCancelled => _cancelled.isCompleted;

  /// Marks the request as cancelled. The server calls this when a
  /// `notifications/cancelled` names the request while it is in flight.
  void cancel() {
    if (_finished || _cancelled.isCompleted) return;
    _cancelled.complete();
  }

  /// Marks the request as finished. The server calls this once the handler
  /// returned, so a late callback can no longer send progress and a late
  /// cancellation is ignored.
  void finish() {
    _finished = true;
  }
}
