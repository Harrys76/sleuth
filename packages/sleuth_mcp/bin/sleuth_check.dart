import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';

import 'package:sleuth_mcp/sleuth_mcp.dart';

/// One-shot CI gate. Connects, calls `ext.sleuth.snapshot`, evaluates
/// budgets, prints report, exits 0 on pass / 1 on violation. NOT an MCP
/// server — designed for use in CI shell scripts.
Future<void> main(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('uri',
        help: 'WebSocket URI of the target app VM service.', mandatory: true)
    ..addOption('min-fps',
        help: 'Minimum acceptable averageFps.', defaultsTo: '55')
    ..addOption('max-issues',
        help: 'Maximum acceptable total issue count.', defaultsTo: '999999')
    ..addOption('max-critical-issues',
        help: 'Maximum acceptable critical issue count.', defaultsTo: '0')
    ..addFlag('json', negatable: false, help: 'Emit report as JSON to stdout.')
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
        'sleuth_check — one-shot CI gate for sleuth performance budgets.\n');
    stdout.writeln(parser.usage);
    return;
  }

  final uri = parsed['uri'] as String;
  final minFps = double.tryParse(parsed['min-fps'] as String) ?? 55.0;
  final maxIssues = int.tryParse(parsed['max-issues'] as String) ?? 999999;
  final maxCritical =
      int.tryParse(parsed['max-critical-issues'] as String) ?? 0;
  final emitJson = parsed['json'] as bool;

  final bridge = RealVmBridge();
  try {
    await bridge.connect(Uri.parse(uri));
  } catch (e) {
    stderr.writeln('connect failed: $e');
    exitCode = 2;
    return;
  }

  // Refuse on lineage skew — envelope shape may differ across boundaries.
  final diag = bridge.lastDiagnoseEnvelope;
  String? appVersion;
  if (diag != null) {
    final data = diag['data'];
    if (data is Map<String, Object?>) {
      final v = data['packageVersion'];
      if (v is String) appVersion = v;
    }
  }
  if (appVersion != null &&
      versionLineage(appVersion) != versionLineage(sleuthPackageVersionPin)) {
    stderr.writeln(
      'version skew: app=$appVersion sidecar-pin=$sleuthPackageVersionPin — '
      'budgets may be evaluated against a wrong envelope shape. Refusing to '
      'run; align sleuth dep with sleuth_check version.',
    );
    await bridge.disconnect();
    exitCode = 2;
    return;
  }

  try {
    final envelope = await bridge.callExtension('ext.sleuth.snapshot');
    final data = envelope['data'];
    if (data is! Map<String, Object?>) {
      stderr.writeln('snapshot envelope had no data field');
      exitCode = 2;
      return;
    }
    final report = evaluateBudgets(
      snapshot: data,
      minFps: minFps,
      maxIssues: maxIssues,
      maxCriticalIssues: maxCritical,
    );
    final passed = report['passed'] == true;

    if (emitJson) {
      stdout.writeln(jsonEncode(report));
    } else {
      stdout.writeln('budgets: ${passed ? "PASS" : "FAIL"}');
      final observed = report['observed'];
      if (observed is Map<String, Object?>) {
        stdout.writeln(
            '  fps=${observed['fps']} issues=${observed['issueCount']} critical=${observed['criticalCount']}');
      }
      final violations = report['violations'];
      if (violations is List && violations.isNotEmpty) {
        for (final v in violations) {
          stdout.writeln('  - $v');
        }
      }
    }
    exitCode = passed ? 0 : 1;
  } catch (e) {
    stderr.writeln('check failed: $e');
    exitCode = 2;
  } finally {
    await bridge.disconnect();
  }
}
