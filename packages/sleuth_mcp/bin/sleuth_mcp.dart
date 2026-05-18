import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:args/args.dart';

import 'package:sleuth_mcp/sleuth_mcp.dart';

const _redactRegex = r'(ws[s]?://[^/]+/)[^=]+(=/)';

String _redactUri(String s) =>
    s.replaceAll(RegExp(_redactRegex), r'$1<REDACTED>$2');

Future<void> main(List<String> argv) async {
  // Subcommand routing: `sleuth_mcp install [--remove]` registers the
  // server in `~/.claude.json` and exits. Bare invocation (no subcommand
  // or any flag) starts the stdio MCP server as before.
  if (argv.isNotEmpty && argv.first == 'install') {
    final result = await runInstallCommand(args: argv.skip(1).toList());
    stdout.writeln(result.message);
    exitCode = result.exitCode;
    return;
  }

  final parser = ArgParser()
    ..addOption('uri',
        help:
            'WebSocket URI of the target app VM service (from flutter run output).')
    ..addOption('tool-timeout',
        help: 'Per-tool timeout in seconds.', defaultsTo: '10')
    ..addFlag('verbose',
        abbr: 'v', negatable: false, help: 'Verbose logging to stderr.')
    ..addFlag('version', negatable: false, help: 'Print version and exit.')
    ..addFlag('help',
        abbr: 'h', negatable: false, help: 'Print usage and exit.');

  ArgResults parsed;
  try {
    parsed = parser.parse(argv);
  } on FormatException catch (e) {
    stderr.writeln('${e.message}\n');
    stderr.writeln(parser.usage);
    exitCode = 64;
    return;
  }

  if (parsed['help'] as bool) {
    stdout.writeln(
        'sleuth_mcp — MCP stdio sidecar for the sleuth Flutter package.\n');
    stdout.writeln(parser.usage);
    return;
  }
  if (parsed['version'] as bool) {
    stdout.writeln(
        'sleuth_mcp $sleuthMcpVersion (against sleuth $sleuthPackageVersionPin)');
    return;
  }

  final verbose = parsed['verbose'] as bool;
  final logger = verbose ? _StderrLogger(redact: _redactUri) : null;

  final timeoutSeconds = int.tryParse(parsed['tool-timeout'] as String) ?? 10;
  final bridge = RealVmBridge(
    callTimeout: Duration(seconds: timeoutSeconds),
    logger: logger,
    // Bridge-layer skew validator. Connect / reconnect paths funnel
    // through `_connectUnlocked` — putting refusal here closes the
    // window where a transport-close reconnect could quietly bind to an
    // incompatible app between two tool calls.
    versionSkewValidator: defaultVersionSkewValidator,
  );
  final uri = parsed['uri'] as String?;
  if (uri != null && uri.isNotEmpty) {
    logger?.add('connecting to ${_redactUri(uri)}');
    try {
      await bridge.connect(Uri.parse(uri));
      final uuid = bridge.baselineSessionUuid;
      final shortUuid =
          uuid == null ? '<none>' : uuid.substring(0, math.min(8, uuid.length));
      logger?.add('connected; sessionUuid=$shortUuid…');
    } catch (e) {
      stderr.writeln('initial --uri connect failed: $e');
      stderr.writeln('continuing; MCP client should invoke `connect` tool.');
    }
  }

  final server = McpServer(
    bridge: bridge,
    toolTimeout: Duration(seconds: timeoutSeconds),
    logger: logger,
  )..registerDefaults();
  final session = DaemonSession(
    bridge: bridge,
    server: server,
    logger: logger,
  );
  server.setDaemonSession(session);

  // Cooperative exit — signal handlers ask the server to drain, then
  // `serve()` returns once pending dispatches and the write chain settle.
  void requestShutdown(String reason) {
    logger?.add('$reason received, draining');
    server.shutdown();
  }

  final sigintSub =
      ProcessSignal.sigint.watch().listen((_) => requestShutdown('SIGINT'));
  final sigtermSub =
      ProcessSignal.sigterm.watch().listen((_) => requestShutdown('SIGTERM'));

  try {
    await server.serve(input: stdin, output: stdout);
  } finally {
    await sigintSub.cancel();
    await sigtermSub.cancel();
    try {
      await bridge.disconnect().timeout(const Duration(seconds: 2));
    } catch (e) {
      logger?.add('bridge disconnect failed: $e');
    }
  }
}

class _StderrLogger implements Sink<String> {
  _StderrLogger({required this.redact});
  final String Function(String) redact;
  @override
  void add(String data) {
    stderr.writeln(redact(data));
  }

  @override
  void close() {}
}
