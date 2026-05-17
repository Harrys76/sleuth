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
      expect(tools, hasLength(8));
      final names = tools.map((t) => (t as Map)['name']).toSet();
      expect(names, {
        'connect',
        'get_snapshot',
        'get_issues',
        'get_route_health',
        'explain_issue',
        'compare_snapshots',
        'check_budgets',
        'diagnose',
      });

      await process.stdin.close();
      await process.exitCode.timeout(const Duration(seconds: 10));
      await responses.cancel();
    },
    timeout: const Timeout(Duration(seconds: 120)),
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
