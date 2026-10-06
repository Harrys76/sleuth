@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:sleuth_mcp/src/cli/serve_command.dart' show parseToolTimeout;
import 'package:test/test.dart';

import '../helpers/counting_session.dart';
import '../helpers/fake_vm_bridge.dart';

/// [FakeVmBridge] whose connect waits for [release] and counts disconnects.
class _SlowConnectBridge extends FakeVmBridge {
  _SlowConnectBridge() : super(fakeSessionUuid: 'fake-uuid');

  final Completer<void> release = Completer<void>();
  int disconnects = 0;

  @override
  Future<bool> connect(Uri wsUri) async {
    await release.future;
    return super.connect(wsUri);
  }

  @override
  Future<void> disconnect() {
    disconnects++;
    return super.disconnect();
  }
}

/// A slow-connecting bridge with the default fake diagnose envelope.
_SlowConnectBridge _slowBridge() => _SlowConnectBridge()
  ..setEnvelope(
    'ext.sleuth.diagnose',
    defaultFakeBridge().lastDiagnoseEnvelope!,
  );

String _frame(Map<String, Object?> msg) => '${jsonEncode(msg)}\n';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sleuth_serve_test_');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('--tool-timeout takes whole seconds of 1 or more only', () {
    expect(parseToolTimeout('10'), const Duration(seconds: 10));
    expect(parseToolTimeout(' 1 '), const Duration(seconds: 1));
    for (final bad in ['0', '-5', '', 'abc', '2.5', '1s']) {
      expect(parseToolTimeout(bad), isNull, reason: '"$bad"');
    }
  });

  test('stdin EOF detaches the session, cleans the handoff dir and '
      'disconnects the bridge', () async {
    final bridge = _slowBridge()..release.complete();
    final server = McpServer(bridge: bridge)..registerDefaults();
    final session = CountingSession();
    server.setDaemonSession(session);
    final handoff = SnapshotDiskHandoff(tempDir: tmp);
    final written = await handoff.write({'data': <String, Object?>{}});

    await serveUntilExit(
      server: server,
      bridge: bridge,
      handoff: handoff,
      input: const Stream<List<int>>.empty(),
      output: LineSink(),
    );

    expect(session.detachCalls, 1);
    expect(File(written['path'] as String).parent.existsSync(), isFalse);
    expect(bridge.disconnects, 1);
  });

  test('a shutdown signal detaches once and returns', () async {
    final bridge = _slowBridge()..release.complete();
    final server = McpServer(bridge: bridge)..registerDefaults();
    final session = CountingSession();
    server.setDaemonSession(session);
    final input = StreamController<List<int>>();
    final signal = StreamController<ProcessSignal>();

    final done = serveUntilExit(
      server: server,
      bridge: bridge,
      handoff: SnapshotDiskHandoff(tempDir: tmp),
      input: input.stream,
      output: LineSink(),
      signals: [signal.stream],
    );
    signal.add(ProcessSignal.sigterm);
    await done.timeout(const Duration(seconds: 5));
    expect(session.detachCalls, 1);
    await input.close();
    await signal.close();
  });

  test('a detach that hangs does not keep the process alive', () async {
    final bridge = _slowBridge()..release.complete();
    final server = McpServer(
      bridge: bridge,
      exitDetachTimeout: const Duration(milliseconds: 100),
    )..registerDefaults();
    server.setDaemonSession(CountingSession(hang: true));
    await serveUntilExit(
      server: server,
      bridge: bridge,
      handoff: SnapshotDiskHandoff(tempDir: tmp),
      input: const Stream<List<int>>.empty(),
      output: LineSink(),
    ).timeout(const Duration(seconds: 5));
  });

  test('the startup connect runs after serving starts; tool calls wait for '
      'it', () async {
    final bridge = _slowBridge();
    final server = McpServer(bridge: bridge)..registerDefaults();
    final input = StreamController<List<int>>();
    final out = LineSink();
    final errors = StringBuffer();

    final done = serveUntilExit(
      server: server,
      bridge: bridge,
      handoff: SnapshotDiskHandoff(tempDir: tmp),
      input: input.stream,
      output: out,
      startupUri: Uri.parse('http://127.0.0.1:5/x=/'),
      errorSink: errors,
    );

    input.add(
      utf8.encode(
        _frame({
          'jsonrpc': '2.0',
          'method': 'initialize',
          'params': {'protocolVersion': '2025-06-18'},
          'id': 1,
        }),
      ),
    );
    input.add(
      utf8.encode(
        _frame({
          'jsonrpc': '2.0',
          'method': 'tools/call',
          'params': {'name': 'diagnose', 'arguments': <String, Object?>{}},
          'id': 2,
        }),
      ),
    );
    // initialize is answered while the connect is still pending.
    await _waitFor(() => out.lines.isNotEmpty);
    expect(out.lines, hasLength(1));
    expect((jsonDecode(out.lines.single) as Map)['id'], 1);

    bridge.release.complete();
    await _waitFor(() => out.lines.length == 2);
    final call = jsonDecode(out.lines[1]) as Map<String, Object?>;
    expect(call['id'], 2);
    expect((call['result'] as Map).containsKey('isError'), isFalse);
    expect(bridge.lastConnectUri, Uri.parse('http://127.0.0.1:5/x=/'));

    await input.close();
    await done.timeout(const Duration(seconds: 5));
    expect(errors.toString(), isEmpty);
  });

  test('a startup connect slower than the wait lets tool calls run', () async {
    final bridge = _slowBridge();
    final server = McpServer(bridge: bridge)..registerDefaults();
    final input = StreamController<List<int>>();
    final out = LineSink();
    final errors = StringBuffer();

    final done = serveUntilExit(
      server: server,
      bridge: bridge,
      handoff: SnapshotDiskHandoff(tempDir: tmp),
      input: input.stream,
      output: out,
      startupUri: Uri.parse('ws://127.0.0.1:5/x=/ws'),
      startupConnectWait: const Duration(milliseconds: 50),
      errorSink: errors,
    );
    for (final msg in <Map<String, Object?>>[
      {
        'jsonrpc': '2.0',
        'method': 'initialize',
        'params': <String, Object?>{},
        'id': 1,
      },
      {
        'jsonrpc': '2.0',
        'method': 'tools/call',
        'params': {'name': 'diagnose', 'arguments': <String, Object?>{}},
        'id': 2,
      },
    ]) {
      input.add(utf8.encode(_frame(msg)));
    }
    await _waitFor(() => out.lines.length == 2);
    final text =
        ((((jsonDecode(out.lines[1]) as Map)['result'] as Map)['content']
                    as List)
                .first
            as Map)['text'];
    expect(text, startsWith('not_connected: '));
    expect(errors.toString(), contains('did not finish within'));

    bridge.release.complete();
    await input.close();
    await done.timeout(const Duration(seconds: 5));
  });
}

Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition not met within 5 s');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
