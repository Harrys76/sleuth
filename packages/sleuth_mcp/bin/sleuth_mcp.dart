import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';

import 'package:sleuth_mcp/sleuth_mcp.dart';

const _redactRegex = r'((?:ws|http)s?://[^/]+/)[^=]+(=/)';

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
  if (argv.isNotEmpty && argv.first == 'attach-ios') {
    final result = await runAttachIosCommand(args: argv.skip(1).toList());
    exitCode = result.exitCode;
    return;
  }

  final parser = ArgParser()
    ..addOption(
      'uri',
      help:
          'VM service URI of the target app, as flutter run prints it (http '
          'or ws). The server starts at once and connects in the background.',
    )
    ..addOption(
      'tool-timeout',
      help: 'Per-tool timeout in seconds.',
      defaultsTo: '10',
    )
    ..addFlag(
      'verbose',
      abbr: 'v',
      negatable: false,
      help: 'Verbose logging to stderr.',
    )
    ..addFlag('version', negatable: false, help: 'Print version and exit.')
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Print usage and exit.',
    );

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
      'sleuth_mcp — MCP stdio sidecar for the sleuth Flutter package.\n',
    );
    stdout.writeln(parser.usage);
    return;
  }
  if (parsed['version'] as bool) {
    stdout.writeln(
      'sleuth_mcp $sleuthMcpVersion (against sleuth $sleuthPackageVersionPin)',
    );
    return;
  }

  final verbose = parsed['verbose'] as bool;
  final logger = verbose ? _StderrLogger(redact: _redactUri) : null;

  final timeoutSeconds = int.tryParse(parsed['tool-timeout'] as String) ?? 10;
  final toolTimeout = Duration(seconds: timeoutSeconds);
  final bridge = RealVmBridge(
    // Shorter than the tool timeout, so a slow app call fails with the
    // bridge's own error (naming the extension) and keeps the connection.
    callTimeout: bridgeCallTimeoutWithin(toolTimeout),
    logger: logger,
    // Bridge-layer skew validator. Connect / reconnect paths funnel
    // through `_connectUnlocked` — putting refusal here closes the
    // window where a transport-close reconnect could quietly bind to an
    // incompatible app between two tool calls.
    versionSkewValidator: defaultVersionSkewValidator,
  );
  Uri? startupUri;
  final uri = parsed['uri'] as String?;
  if (uri != null && uri.isNotEmpty) {
    try {
      startupUri = Uri.parse(uri.trim());
      logger?.add('connecting to ${_redactUri(uri)} in the background');
    } on FormatException catch (e) {
      stderr.writeln('ignoring --uri: ${e.message}');
      stderr.writeln(
        'continuing; the MCP client can call attach_app or connect instead.',
      );
    }
  }

  final server = McpServer(
    bridge: bridge,
    toolTimeout: toolTimeout,
    logger: logger,
  )..registerDefaults();
  final session = DaemonSession(bridge: bridge, server: server, logger: logger);
  server.setDaemonSession(session);

  // Serves at once, connects to --uri in the background, and on every exit
  // path (stdin EOF, SIGINT, SIGTERM, a stdout write failure) detaches the
  // daemon session with a bounded wait so a flutter attach child or an
  // iproxy tunnel cannot outlive the sidecar.
  await serveUntilExit(
    server: server,
    bridge: bridge,
    handoff: snapshotDiskHandoff,
    input: stdin,
    output: stdout,
    startupUri: startupUri,
    signals: shutdownSignals(),
    logger: logger,
    errorSink: stderr,
  );
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
