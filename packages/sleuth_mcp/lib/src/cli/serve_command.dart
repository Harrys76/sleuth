import 'dart:async';
import 'dart:io';

import '../bridge/vm_bridge.dart';
import '../mcp/mcp_server.dart';
import '../tools/snapshot_disk_handoff.dart';

/// How long tool calls wait for the startup `--uri` connect before they run
/// anyway.
const Duration defaultStartupConnectWait = Duration(seconds: 15);

/// Parses the `--tool-timeout` value: a whole number of seconds, 1 or more.
/// Returns null for anything else, which the binary reports as a usage
/// error, because a timeout of 0 or less would end every tool call at once.
Duration? parseToolTimeout(String raw) {
  final seconds = int.tryParse(raw.trim());
  if (seconds == null || seconds < 1) return null;
  return Duration(seconds: seconds);
}

/// Signals that ask the stdio server to shut down: SIGINT everywhere, and
/// SIGTERM except on Windows, where watching it throws.
List<Stream<ProcessSignal>> shutdownSignals() => [
  ProcessSignal.sigint.watch(),
  if (!Platform.isWindows) ProcessSignal.sigterm.watch(),
];

/// Runs [server] over stdio until stdin closes or a signal in [signals]
/// arrives, then cleans up on every exit path: it detaches the daemon
/// session (bounded by the server's exit detach timeout), deletes the
/// disk-handoff files and their directory, and disconnects [bridge]
/// (bounded by 2 seconds). The detach starts as soon as serving stops and
/// runs while the server waits for the requests still running, which is
/// bounded by the server's exit drain timeout, so with the defaults the
/// cleanup ends within about 12 seconds.
///
/// At startup it removes the handoff directories that earlier processes
/// left behind: empty ones, and the files older than 30 minutes in those
/// whose process is gone ([SnapshotDiskHandoff.sweepStaleProcessDirs]).
///
/// With [startupUri] the server starts serving first and connects in the
/// background, so a slow connect cannot make the client's `initialize` time
/// out. Tool calls wait for that connect, at most [startupConnectWait].
Future<void> serveUntilExit({
  required McpServer server,
  required VmBridge bridge,
  required SnapshotDiskHandoff handoff,
  Stream<List<int>>? input,
  IOSink? output,
  Uri? startupUri,
  List<Stream<ProcessSignal>> signals = const [],
  Duration startupConnectWait = defaultStartupConnectWait,
  Sink<String>? logger,
  StringSink? errorSink,
}) async {
  final err = errorSink ?? stderr;
  // The sweep never fails and runs in the background.
  unawaited(handoff.sweepStaleProcessDirs());
  if (startupUri != null) {
    server.holdToolCallsUntil(
      _connectAtStartup(bridge, startupUri, startupConnectWait, logger, err),
    );
  }
  final subscriptions = [
    for (final signal in signals)
      signal.listen((s) {
        logger?.add('$s received, draining');
        server.shutdown();
      }),
  ];
  try {
    await server.serve(input: input, output: output);
  } finally {
    for (final sub in subscriptions) {
      await sub.cancel();
    }
    await server.detachDaemonSession();
    handoff.cleanupAll();
    try {
      await bridge.disconnect().timeout(const Duration(seconds: 2));
    } catch (e) {
      logger?.add('bridge disconnect failed: $e');
    }
  }
}

Future<void> _connectAtStartup(
  VmBridge bridge,
  Uri uri,
  Duration wait,
  Sink<String>? logger,
  StringSink err,
) async {
  try {
    await bridge.connect(uri).timeout(wait);
    final uuid = bridge.baselineSessionUuid;
    final shortUuid = uuid == null
        ? '<none>'
        : uuid.substring(0, uuid.length < 8 ? uuid.length : 8);
    logger?.add('connected; sessionUuid starts with $shortUuid');
  } on TimeoutException {
    err.writeln(
      'The initial --uri connect did not finish within ${wait.inSeconds} '
      's. Tool calls run now, and the connect continues in the background.',
    );
  } catch (e) {
    err.writeln('The initial --uri connect failed: $e');
    err.writeln(
      'Continuing without it. The MCP client can call attach_app or '
      'connect instead.',
    );
  }
}
