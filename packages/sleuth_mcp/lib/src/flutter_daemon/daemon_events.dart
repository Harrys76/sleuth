/// Typed events from `flutter run --machine` / `flutter attach --machine`
/// NDJSON daemon protocol. Format reference:
/// `packages/flutter_tools/lib/src/commands/daemon.dart` (AppDomain
/// `_sendAppEvent` + handler registration).
sealed class DaemonEvent {
  const DaemonEvent();
}

class DaemonConnectedEvent extends DaemonEvent {
  const DaemonConnectedEvent({required this.version, required this.pid});
  final String version;
  final int pid;
}

class DaemonLogMessageEvent extends DaemonEvent {
  const DaemonLogMessageEvent({required this.level, required this.message});
  final String level;
  final String message;
}

class DaemonShowMessageEvent extends DaemonEvent {
  const DaemonShowMessageEvent({
    required this.level,
    required this.title,
    required this.message,
  });
  final String level;
  final String title;
  final String message;
}

class AppStartEvent extends DaemonEvent {
  const AppStartEvent({
    required this.appId,
    required this.deviceId,
    required this.launchMode,
    required this.mode,
    this.directory,
    this.supportsRestart,
  });
  final String appId;
  final String deviceId;

  /// `'attach'` (via `flutter attach`) or `'run'` (via `flutter run`).
  final String launchMode;

  /// `'debug'` / `'profile'` / `'release'`.
  final String mode;
  final String? directory;
  final bool? supportsRestart;
}

class AppDebugPortEvent extends DaemonEvent {
  const AppDebugPortEvent({
    required this.appId,
    required this.wsUri,
    required this.port,
    this.baseUri,
  });
  final String appId;
  final String wsUri;
  final int port;
  final String? baseUri;
}

class AppStartedEvent extends DaemonEvent {
  const AppStartedEvent({required this.appId});
  final String appId;
}

class AppStopEvent extends DaemonEvent {
  const AppStopEvent({required this.appId, this.error});
  final String appId;
  final String? error;
}

class AppLogEvent extends DaemonEvent {
  const AppLogEvent({
    required this.appId,
    required this.log,
    required this.isError,
  });
  final String appId;
  final String log;
  final bool isError;
}

class AppProgressEvent extends DaemonEvent {
  const AppProgressEvent({
    required this.appId,
    required this.id,
    required this.progressId,
    this.message,
    this.finished = false,
  });
  final String appId;
  final String id;
  final String progressId;
  final String? message;
  final bool finished;
}

class UnknownDaemonEvent extends DaemonEvent {
  const UnknownDaemonEvent({required this.eventName, required this.params});
  final String eventName;
  final Map<String, Object?> params;
}

/// Response to a daemon RPC request. Correlated by `id`.
class DaemonRpcResponse extends DaemonEvent {
  const DaemonRpcResponse({required this.id, this.result, this.error});

  final int id;

  /// Per JSON-RPC, exactly one of [result] / [error] is non-null on a
  /// well-formed response.
  final Object? result;
  final Map<String, Object?>? error;

  bool get isError => error != null;
}
