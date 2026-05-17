import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:test/test.dart';

import '../helpers/fake_vm_bridge.dart';

/// Captures stdout writes. Implements just enough of IOSink for the
/// server's write chain to operate; splits on `\n` so tests can read
/// response frames as discrete lines.
class _CapturingSink implements IOSink {
  final List<String> lines = [];

  @override
  Encoding encoding = utf8;

  @override
  void write(Object? obj) {
    final s = obj.toString();
    final chunks = s.split('\n');
    for (int i = 0; i < chunks.length - 1; i++) {
      lines.add(chunks[i]);
    }
  }

  @override
  Future<void> flush() async {}

  @override
  void writeln([Object? obj = ""]) => write('$obj\n');
  @override
  void writeAll(Iterable<dynamic> objs, [String sep = ""]) =>
      write(objs.join(sep));
  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));
  @override
  void add(List<int> data) => write(utf8.decode(data));

  @override
  void addError(Object error, [StackTrace? st]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      add(chunk);
    }
  }

  @override
  Future<void> close() async {}

  @override
  Future<void> get done => Future.value();
}

String _frame(Map<String, Object?> msg) => '${jsonEncode(msg)}\n';

void main() {
  test(
    'concurrent JSON-RPC frames return correlated by id, no interleaved writes',
    () async {
      final input = StreamController<List<int>>();
      final output = _CapturingSink();
      final bridge = defaultFakeBridge();
      final server = McpServer(bridge: bridge)..registerDefaults();
      final servePromise = server.serve(input: input.stream, output: output);

      // Initialize first so the _initialized gate is open.
      input.add(utf8.encode(_frame({
        'jsonrpc': '2.0',
        'method': 'initialize',
        'params': {'protocolVersion': '2024-11-05'},
        'id': 1,
      })));
      await Future<void>.delayed(Duration.zero);

      // Blast frames without waiting between them.
      input.add(utf8.encode(_frame({
        'jsonrpc': '2.0',
        'method': 'tools/list',
        'id': 2,
      })));
      input.add(utf8.encode(_frame({
        'jsonrpc': '2.0',
        'method': 'tools/call',
        'params': {
          'name': 'diagnose',
          'arguments': const <String, Object?>{},
        },
        'id': 3,
      })));
      input.add(utf8.encode(_frame({
        'jsonrpc': '2.0',
        'method': 'tools/call',
        'params': {
          'name': 'get_snapshot',
          'arguments': const <String, Object?>{},
        },
        'id': 4,
      })));

      await input.close();
      await servePromise;

      expect(output.lines, hasLength(4));
      final byId = <Object?, Map<String, Object?>>{};
      for (final line in output.lines) {
        final decoded = jsonDecode(line) as Map<String, Object?>;
        byId[decoded['id']] = decoded;
      }
      expect(byId.keys, containsAll(<int>[1, 2, 3, 4]));
      expect(((byId[1]!['result']) as Map)['protocolVersion'], '2024-11-05');
      expect(((byId[2]!['result']) as Map)['tools'], hasLength(13));
      final diagContent = ((byId[3]!['result']) as Map)['content'] as List;
      expect((diagContent.first as Map)['type'], 'text');
      final snapContent = ((byId[4]!['result']) as Map)['content'] as List;
      expect((snapContent.first as Map)['type'], 'text');
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test('shutdown() waits for the in-flight dispatch to write its response',
      () async {
    final gate = Completer<void>();
    final bridge = _SlowBridge(gate);
    final input = StreamController<List<int>>();
    final output = _CapturingSink();
    final server = McpServer(bridge: bridge)..registerDefaults();
    final servePromise = server.serve(input: input.stream, output: output);

    input.add(utf8.encode(_frame({
      'jsonrpc': '2.0',
      'method': 'initialize',
      'params': {'protocolVersion': '2024-11-05'},
      'id': 1,
    })));
    while (output.lines.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    // Fire a slow tool — dispatcher parks on the gate.
    input.add(utf8.encode(_frame({
      'jsonrpc': '2.0',
      'method': 'tools/call',
      'params': {
        'name': 'diagnose',
        'arguments': const <String, Object?>{},
      },
      'id': 2,
    })));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    server.shutdown();
    Timer(const Duration(milliseconds: 50), () => gate.complete());

    await servePromise.timeout(const Duration(seconds: 5));
    await input.close();

    expect(output.lines, hasLength(2));
    final ids = output.lines.map((l) => (jsonDecode(l) as Map)['id']).toSet();
    expect(ids, {1, 2});
  });
}

class _SlowBridge implements VmBridge {
  _SlowBridge(this._gate);

  final Completer<void> _gate;

  @override
  String? get baselineSessionUuid => 'baseline';

  @override
  Map<String, Object?>? get lastDiagnoseEnvelope => const {
        'connectionMode': 'basic',
        'schemaVersion': 1,
        'sessionUuid': 'baseline',
        'data': <String, Object?>{'packageVersion': '0.32.0'},
      };

  @override
  bool get isConnected => true;

  @override
  int get baselineGeneration => 0;

  @override
  Future<void> refreshBaseline({bool acceptSessionRotation = false}) async {}

  @override
  Future<bool> connect(Uri wsUri) async => true;

  @override
  Future<Map<String, Object?>> callExtension(
    String method, {
    Map<String, dynamic> args = const <String, dynamic>{},
  }) async {
    await _gate.future;
    return const {
      'connectionMode': 'basic',
      'schemaVersion': 1,
      'sessionUuid': 'baseline',
      'data': <String, Object?>{'packageVersion': '0.32.0'},
    };
  }

  @override
  Future<void> disconnect() async {}
}
