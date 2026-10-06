import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';

import '../bridge/vm_bridge.dart';
import '../mcp/mcp_types.dart';
import '../tools/budgets.dart';
import '../tools/tools.dart' show defaultVersionSkewValidator;

/// `sleuth_check` exit code: every budget passed.
const int checkExitPass = 0;

/// `sleuth_check` exit code: at least one budget was violated.
const int checkExitViolation = 1;

/// `sleuth_check` exit code: the check could not run (connect failure,
/// version refusal, malformed snapshot, or `coverage_degraded`).
const int checkExitNotRun = 2;

/// `sleuth_check` exit code: a bad command line.
const int checkExitUsage = 64;

/// One-shot CI gate behind the `sleuth_check` binary. Connects, calls
/// `ext.sleuth.snapshot`, evaluates the budgets and prints a report.
/// Returns [checkExitPass], [checkExitViolation], [checkExitNotRun] when
/// the check could not run, or [checkExitUsage] for a bad command line,
/// such as a missing `--uri`. Not an MCP server; built for CI scripts.
///
/// [bridgeFactory] replaces the real VM service bridge in tests.
Future<int> runCheckCommand(
  List<String> argv, {
  StringSink? out,
  StringSink? err,
  VmBridge Function()? bridgeFactory,
}) async {
  final stdoutSink = out ?? stdout;
  final stderrSink = err ?? stderr;
  final parser = ArgParser()
    ..addOption(
      'uri',
      help:
          'VM service URI of the target app (required). Takes the http URI '
          'that flutter run prints or the ws form.',
    )
    ..addOption(
      'min-fps',
      help: 'Minimum acceptable averageFps.',
      defaultsTo: '55',
    )
    ..addOption(
      'max-issues',
      help: 'Maximum acceptable total issue count.',
      defaultsTo: '999999',
    )
    ..addOption(
      'max-critical-issues',
      help: 'Maximum acceptable critical issue count.',
      defaultsTo: '0',
    )
    ..addFlag('json', negatable: false, help: 'Emit report as JSON to stdout.')
    ..addFlag(
      'help',
      abbr: 'h',
      negatable: false,
      help: 'Print usage and exit.',
    );

  int usageError(String message) {
    stderrSink.writeln('$message\n');
    stderrSink.writeln(parser.usage);
    return checkExitUsage;
  }

  ArgResults parsed;
  try {
    parsed = parser.parse(argv);
  } on FormatException catch (e) {
    return usageError(e.message);
  }
  if (parsed['help'] as bool) {
    stdoutSink.writeln(
      'sleuth_check: one-shot CI gate for sleuth performance budgets.\n',
    );
    stdoutSink.writeln(parser.usage);
    stdoutSink.writeln(
      '\nExit codes: 0 pass, 1 budget violation, 2 check could not run '
      '(connect failure, version refusal, malformed snapshot, or '
      'coverage_degraded: no VM service link, so VM-only detectors never '
      'ran), 64 bad command line.',
    );
    return checkExitPass;
  }
  if (parsed.rest.isNotEmpty) {
    return usageError('Unexpected arguments: ${parsed.rest.join(' ')}');
  }

  final rawUri = (parsed['uri'] as String?)?.trim();
  if (rawUri == null || rawUri.isEmpty) {
    return usageError('Missing required option --uri.');
  }
  final Uri uri;
  try {
    uri = normalizeVmServiceUri(Uri.parse(rawUri));
  } on FormatException catch (e) {
    return usageError('Invalid --uri: ${e.message}');
  }
  final minFps = double.tryParse(parsed['min-fps'] as String);
  if (minFps == null) {
    return usageError('--min-fps must be a number, got "${parsed['min-fps']}"');
  }
  final maxIssues = int.tryParse(parsed['max-issues'] as String);
  if (maxIssues == null || maxIssues < 0) {
    return usageError(
      '--max-issues must be a non-negative integer, got '
      '"${parsed['max-issues']}"',
    );
  }
  final maxCritical = int.tryParse(parsed['max-critical-issues'] as String);
  if (maxCritical == null || maxCritical < 0) {
    return usageError(
      '--max-critical-issues must be a non-negative integer, got '
      '"${parsed['max-critical-issues']}"',
    );
  }
  final emitJson = parsed['json'] as bool;

  // The bridge-layer skew validator refuses the app (and fails closed on a
  // missing packageVersion) before the first snapshot fetch, so the budget
  // evaluator never sees an envelope from an out-of-lineage or
  // unverifiable app.
  final bridge =
      bridgeFactory?.call() ??
      RealVmBridge(versionSkewValidator: defaultVersionSkewValidator);
  try {
    await bridge.connect(uri);
  } on VmBridgeException catch (e) {
    if (e.message.startsWith('version_skew_')) {
      stderrSink.writeln(e.message);
    } else {
      stderrSink.writeln('connect failed: ${e.message}');
    }
    return checkExitNotRun;
  } catch (e) {
    stderrSink.writeln('connect failed: $e');
    return checkExitNotRun;
  }

  try {
    final envelope = await bridge.callExtension(
      'ext.sleuth.snapshot',
      args: budgetSnapshotArgs,
    );
    final data = envelope['data'];
    if (data is! Map<String, Object?>) {
      stderrSink.writeln('snapshot envelope had no data field');
      return checkExitNotRun;
    }
    final result = evaluateBudgets(
      snapshot: data,
      minFps: minFps,
      maxIssues: maxIssues,
      maxCriticalIssues: maxCritical,
    );
    if (result is ToolCallResult) {
      // Schema drift, a malformed snapshot or coverage_degraded: print the
      // error text and exit 2 so CI fails loudly instead of reading it as
      // a passing budget.
      for (final block in result.content) {
        final text = block['text'];
        if (text is String) stderrSink.writeln(text);
      }
      return checkExitNotRun;
    }
    final report = result as Map<String, Object?>;
    final passed = report['passed'] == true;

    if (emitJson) {
      stdoutSink.writeln(jsonEncode(report));
    } else {
      stdoutSink.writeln('budgets: ${passed ? "PASS" : "FAIL"}');
      final observed = report['observed'];
      if (observed is Map<String, Object?>) {
        stdoutSink.writeln(
          '  fps=${observed['fps']} issues=${observed['issueCount']} '
          'critical=${observed['criticalCount']}',
        );
      }
      final violations = report['violations'];
      if (violations is List && violations.isNotEmpty) {
        for (final v in violations) {
          stdoutSink.writeln('  - $v');
        }
      }
    }
    return passed ? checkExitPass : checkExitViolation;
  } catch (e) {
    stderrSink.writeln('check failed: $e');
    return checkExitNotRun;
  } finally {
    try {
      await bridge.disconnect().timeout(const Duration(seconds: 2));
    } catch (_) {
      // best effort
    }
  }
}
