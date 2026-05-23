import 'dart:async';
import 'dart:convert';

import 'daemon_events.dart';

/// Minimum supported daemon protocol version (from `daemon.connected.version`).
/// Below this we refuse to attach — protocol shape may differ.
const String minDaemonProtocolVersion = '0.6.0';

/// Parses NDJSON from a `flutter --machine` child process stdout.
///
/// Wire format (verified against
/// `packages/flutter_tools/lib/src/commands/daemon.dart`):
///   * each event is one line ending `\n`
///   * each line is `[{...}]` — a single-element JSON array wrapping the
///     event/response object
///   * non-event lines (banners, progress text written by flutter_tools
///     outside the daemon channel) are interleaved on stdout and dropped
///   * RPC responses share the same line shape but carry `id` + (`result`
///     or `error`) instead of `event` + `params`
class DaemonParser {
  Stream<DaemonEvent> parse(Stream<List<int>> stdout) async* {
    final lines = stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter());
    await for (final line in lines) {
      final trimmed = line.trim();
      if (!trimmed.startsWith('[') || !trimmed.endsWith(']')) continue;
      Object? decoded;
      try {
        decoded = jsonDecode(trimmed);
      } catch (_) {
        continue;
      }
      if (decoded is! List) continue;
      // Protocol allows array-batched frames per line. Iterate every
      // element so we don't silently drop multi-event lines that a
      // future flutter_tools may emit under backpressure.
      for (final frame in decoded) {
        if (frame is! Map<String, Object?>) continue;
        if (frame.containsKey('id') &&
            (frame.containsKey('result') || frame.containsKey('error'))) {
          final id = frame['id'];
          if (id is! int) continue;
          yield DaemonRpcResponse(
            id: id,
            result: frame['result'],
            error: frame['error'] is Map<String, Object?>
                ? frame['error'] as Map<String, Object?>
                : null,
          );
          continue;
        }
        final eventName = frame['event'];
        final params = frame['params'];
        if (eventName is! String || params is! Map<String, Object?>) continue;
        yield _parseEvent(eventName, params);
      }
    }
  }

  DaemonEvent _parseEvent(String name, Map<String, Object?> params) {
    switch (name) {
      case 'daemon.connected':
        return DaemonConnectedEvent(
          version: (params['version'] as String?) ?? '',
          pid: (params['pid'] as int?) ?? 0,
        );
      case 'daemon.logMessage':
        return DaemonLogMessageEvent(
          level: (params['level'] as String?) ?? 'status',
          message: (params['message'] as String?) ?? '',
        );
      case 'daemon.showMessage':
        return DaemonShowMessageEvent(
          level: (params['level'] as String?) ?? 'status',
          title: (params['title'] as String?) ?? '',
          message: (params['message'] as String?) ?? '',
        );
      case 'app.start':
        final appId = params['appId'];
        final deviceId = params['deviceId'];
        if (appId is! String || deviceId is! String) {
          return UnknownDaemonEvent(eventName: name, params: params);
        }
        return AppStartEvent(
          appId: appId,
          deviceId: deviceId,
          launchMode: (params['launchMode'] as String?) ?? 'run',
          mode: (params['mode'] as String?) ?? 'debug',
          directory: params['directory'] as String?,
          supportsRestart: params['supportsRestart'] as bool?,
        );
      case 'app.debugPort':
        final appId = params['appId'];
        final wsUri = params['wsUri'];
        final port = params['port'];
        if (appId is! String || wsUri is! String || port is! int) {
          return UnknownDaemonEvent(eventName: name, params: params);
        }
        return AppDebugPortEvent(
          appId: appId,
          wsUri: wsUri,
          port: port,
          baseUri: params['baseUri'] as String?,
        );
      case 'app.started':
        final appId = params['appId'];
        if (appId is! String) {
          return UnknownDaemonEvent(eventName: name, params: params);
        }
        return AppStartedEvent(appId: appId);
      case 'app.stop':
        final appId = params['appId'];
        if (appId is! String) {
          return UnknownDaemonEvent(eventName: name, params: params);
        }
        return AppStopEvent(
          appId: appId,
          error: params['error'] as String?,
        );
      case 'app.log':
        final appId = params['appId'];
        final log = params['log'];
        if (appId is! String || log is! String) {
          return UnknownDaemonEvent(eventName: name, params: params);
        }
        return AppLogEvent(
          appId: appId,
          log: log,
          isError: (params['error'] as bool?) ?? false,
        );
      case 'app.progress':
        final appId = params['appId'];
        final id = params['id'];
        final progressId = params['progressId'];
        if (appId is! String || id is! String || progressId is! String) {
          return UnknownDaemonEvent(eventName: name, params: params);
        }
        return AppProgressEvent(
          appId: appId,
          id: id,
          progressId: progressId,
          message: params['message'] as String?,
          finished: (params['finished'] as bool?) ?? false,
        );
      default:
        return UnknownDaemonEvent(eventName: name, params: params);
    }
  }
}

/// Returns true if [version] is at least [minimum]. Both must be dotted
/// numeric strings (`major.minor.patch`). Missing components default to 0.
bool isAtLeastVersion(String version, String minimum) {
  final actual = _parts(version);
  final required = _parts(minimum);
  for (var i = 0; i < required.length; i++) {
    final a = i < actual.length ? actual[i] : 0;
    final r = required[i];
    if (a > r) return true;
    if (a < r) return false;
  }
  return true;
}

List<int> _parts(String v) {
  return v.split('.').map((p) => int.tryParse(p) ?? 0).toList();
}
