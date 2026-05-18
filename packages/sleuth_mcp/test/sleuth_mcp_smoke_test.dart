@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:test/test.dart';

void main() {
  test('version constants are non-empty and exported', () {
    expect(sleuthMcpVersion, isNotEmpty);
    expect(sleuthPackageVersionPin, isNotEmpty);
  });

  test('sleuthPackageVersionPin matches kSleuthPackageVersion in sleuth source',
      () {
    // The sidecar can't `package:sleuth` import (sleuth pulls the Flutter
    // SDK; sidecar is a Flutter-free Dart CLI). Instead, parse the sleuth
    // source file at test-time and assert the literal matches. Drift between
    // the two declarations is caught here as a test failure rather than as
    // a silent runtime `version_skew_major` refusal.
    final sleuthSource = _resolveSleuthSourceFile();
    final text = sleuthSource.readAsStringSync();
    final match = RegExp(r"const String kSleuthPackageVersion = '([^']+)';")
        .firstMatch(text);
    expect(match, isNotNull,
        reason: 'kSleuthPackageVersion declaration not found in source');
    expect(match!.group(1), sleuthPackageVersionPin,
        reason: 'sleuthPackageVersionPin (sidecar) drifted from '
            'kSleuthPackageVersion (sleuth). Re-pin both to the same value.');
  });

  test(
    'binary spawns, initialize + tools/list returns 8 tool names',
    () async {
      final process = await Process.start(
        Platform.resolvedExecutable,
        ['run', 'bin/sleuth_mcp.dart'],
        workingDirectory: Directory.current.path,
      );

      final stdoutLines = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .where((l) => l.trim().isNotEmpty);

      final responses = StreamQueue(stdoutLines);

      process.stdin.writeln(jsonEncode({
        'jsonrpc': '2.0',
        'method': 'initialize',
        'params': {'protocolVersion': '2024-11-05'},
        'id': 1,
      }));
      await process.stdin.flush();
      final initResp = jsonDecode(await responses.next) as Map<String, Object?>;
      expect((initResp['result'] as Map)['protocolVersion'], '2024-11-05');

      process.stdin.writeln(jsonEncode({
        'jsonrpc': '2.0',
        'method': 'tools/list',
        'id': 2,
      }));
      await process.stdin.flush();
      final listResp = jsonDecode(await responses.next) as Map<String, Object?>;
      final tools = (listResp['result'] as Map)['tools'] as List;
      expect(tools, hasLength(13));
      final names = tools.map((t) => (t as Map)['name']).toSet();
      expect(names, {
        // diagnostic tools
        'connect',
        'get_snapshot',
        'get_issues',
        'get_route_health',
        'explain_issue',
        'compare_snapshots',
        'check_budgets',
        'diagnose',
        // attach-mode lifecycle tools
        'attach_app',
        'detach_app',
        'app_status',
        'list_devices',
        'hot_reload',
      });

      await process.stdin.close();
      await process.exitCode.timeout(const Duration(seconds: 10));
      await responses.cancel();
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );
}

/// Resolves `lib/src/vm/service_extension_handlers.dart` in the sleuth
/// root regardless of test-runner cwd. Walks up from `Directory.current`
/// and from the test script location looking for a `pubspec.yaml` that
/// names the sleuth package (`name: sleuth\n`). The cwd-walk pattern
/// mirrors `_resolveSchemaFile` in
/// `test/validation/mcp_schema_audit_test.dart`.
File _resolveSleuthSourceFile() {
  const relPath = 'lib/src/vm/service_extension_handlers.dart';
  for (final start in <Directory>[
    Directory.current,
    File.fromUri(Platform.script).parent,
  ]) {
    var dir = start;
    for (var i = 0; i < 8; i++) {
      final pubspec = File('${dir.path}/pubspec.yaml');
      final candidate = File('${dir.path}/$relPath');
      if (pubspec.existsSync() && candidate.existsSync()) {
        // Disambiguate the sleuth root from sibling packages — only the
        // sleuth root publishes `name: sleuth`.
        if (pubspec.readAsStringSync().contains('name: sleuth\n')) {
          return candidate;
        }
      }
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
  }
  throw StateError(
    'service_extension_handlers.dart not found by walking up from cwd or '
    'test file. Sidecar smoke test must run from inside the sleuth repo.',
  );
}

class StreamQueue<T> {
  StreamQueue(Stream<T> stream) {
    _sub = stream.listen(_buffer.add, onDone: () => _done = true);
  }

  late StreamSubscription<T> _sub;
  final List<T> _buffer = [];
  bool _done = false;

  Future<T> get next async {
    while (_buffer.isEmpty && !_done) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    if (_buffer.isNotEmpty) return _buffer.removeAt(0);
    throw StateError('stream closed before next message');
  }

  Future<void> cancel() => _sub.cancel();
}
