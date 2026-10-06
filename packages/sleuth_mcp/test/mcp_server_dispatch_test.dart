@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:test/test.dart';

import 'helpers/counting_session.dart';
import 'helpers/fake_flutter_process.dart';
import 'helpers/fake_vm_bridge.dart';
import 'helpers/mcp_wire.dart';

const _fastDetach = DetachBudget(
  appDetach: Duration(milliseconds: 50),
  childTerm: Duration(milliseconds: 50),
  childKill: Duration(milliseconds: 50),
  bridgeDisconnect: Duration(milliseconds: 50),
  iosTeardown: Duration(milliseconds: 50),
);

/// Binds a [DaemonSession] over a fake `flutter attach` child to [server]
/// and attaches it, so `hot_reload` takes the daemon path.
Future<FakeFlutterProcess> _attachThroughDaemon(
  McpServer server,
  FakeVmBridge bridge,
) async {
  final fake = FakeFlutterProcess();
  final session = DaemonSession(
    bridge: bridge,
    server: server,
    processFactory:
        (
          _,
          _, {
          String? workingDirectory,
          Map<String, String>? environment,
        }) async => fake,
    attachTimeout: const Duration(seconds: 2),
    hotReloadTimeout: const Duration(seconds: 2),
    detachBudget: _fastDetach,
  );
  server.setDaemonSession(session);
  final attaching = session.attach();
  await Future<void>.delayed(Duration.zero);
  fake.emitEvent('daemon.connected', {'version': '0.6.1', 'pid': 100});
  await Future<void>.delayed(Duration.zero);
  fake.emitEvent('app.start', {
    'appId': 'A',
    'deviceId': 'iphone-12',
    'launchMode': 'attach',
    'mode': 'profile',
  });
  await Future<void>.delayed(Duration.zero);
  fake.emitEvent('app.debugPort', {
    'appId': 'A',
    'port': 4242,
    'wsUri': 'ws://127.0.0.1:4242/tok/ws',
  });
  final status = await attaching;
  expect(status.state, 'ready');
  return fake;
}

/// Waits for the `app.restart` request on the fake child's stdin and
/// returns its RPC id.
Future<int> _appRestartId(
  FakeFlutterProcess fake, {
  Duration within = const Duration(seconds: 2),
}) async {
  final watch = Stopwatch()..start();
  while (watch.elapsed < within) {
    for (final frame in fake.stdinFrames) {
      if (frame.contains('"app.restart"')) {
        return ((jsonDecode(frame) as List).first as Map)['id'] as int;
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('app.restart was not sent within $within');
}

/// [IOSink] whose flush fails from the [failFrom]th flush on (1-based), the
/// way stdout does once the client closed its end of the pipe.
class _BrokenPipeSink implements IOSink {
  _BrokenPipeSink({this.failFrom = 1});

  final int failFrom;
  int flushes = 0;
  final List<String> written = [];

  @override
  Encoding encoding = utf8;

  @override
  void write(Object? obj) => written.add(obj.toString());

  @override
  Future<void> flush() {
    flushes++;
    if (flushes >= failFrom) {
      return Future<void>.error(const FileSystemException('Broken pipe'));
    }
    return Future<void>.value();
  }

  @override
  void writeln([Object? obj = '']) => write('$obj\n');
  @override
  void writeAll(Iterable<dynamic> objs, [String sep = '']) =>
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

  final Completer<void> _done = Completer<void>();

  /// Fails the sink's `done` future, as a sink does when its target fails
  /// outside a flush.
  void failDone() => _done.completeError(const FileSystemException('EPIPE'));

  @override
  Future<void> get done => _done.future;
}

/// [DaemonSessionLifecycle] whose detach takes a while, so a test can tell
/// a detach that finished from one that only started.
class _SlowDetachSession implements DaemonSessionLifecycle {
  int detachCalls = 0;
  bool detachCompleted = false;

  @override
  Future<void> detach() async {
    detachCalls++;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    detachCompleted = true;
  }
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sleuth_dispatch_test_');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('hot_reload behind the startup gate', () {
    test('hot_reload after the startup connect sends app.restart at once, '
        'and the server keeps answering', () async {
      final bridge = defaultFakeBridge();
      final server = McpServer(bridge: bridge)..registerDefaults();
      // The binary passes its --uri connect here; this one is done already.
      server.holdToolCallsUntil(Future<void>.value());
      final fake = await _attachThroughDaemon(server, bridge);
      final wire = McpWire(server);
      wire.initialize('2025-06-18');
      await wire.response(0);
      expect(server.holdsToolCalls, isFalse);

      wire.call(1, 'hot_reload');
      final rpcId = await _appRestartId(fake);
      fake.emitRpcResponse(rpcId, result: {'code': 0});
      final reloaded = await wire.response(1);
      final status = jsonDecode(toolText(reloaded)) as Map<String, Object?>;
      expect(status['state'], 'ready');

      wire.ping(2);
      await wire.response(2);
      wire.call(3, 'app_status');
      expect(toolText(await wire.response(3)), contains('"state":"ready"'));
      await wire.close();
    });

    test('a hot_reload that waited for the startup gate does not wait for '
        'itself', () async {
      final bridge = defaultFakeBridge();
      final server = McpServer(bridge: bridge)..registerDefaults();
      final gate = Completer<void>();
      server.holdToolCallsUntil(gate.future);
      final fake = await _attachThroughDaemon(server, bridge);
      final wire = McpWire(server);
      wire.initialize('2025-06-18');
      await wire.response(0);

      wire.call(1, 'hot_reload');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        fake.stdinFrames.where((f) => f.contains('"app.restart"')),
        isEmpty,
        reason: 'the call waits for the startup connect first',
      );
      gate.complete();
      final rpcId = await _appRestartId(fake);
      fake.emitRpcResponse(rpcId, result: {'code': 0});
      await wire.response(1);
      wire.ping(2);
      await wire.response(2);
      await wire.close();
    });

    test('the startup gate is removed once it completes, and only by its '
        'own completion', () async {
      final server = McpServer(bridge: defaultFakeBridge());
      final first = Completer<void>();
      final second = Completer<void>();
      server.holdToolCallsUntil(first.future);
      server.holdToolCallsUntil(second.future);
      first.complete();
      await pumpEventQueue();
      expect(server.holdsToolCalls, isTrue);
      second.completeError(StateError('connect failed'));
      await pumpEventQueue();
      expect(server.holdsToolCalls, isFalse);
    });
  });

  group('a failed stdout write', () {
    test(
      'starts the shutdown, and the exit path finishes the detach',
      () async {
        final bridge = defaultFakeBridge();
        final server = McpServer(bridge: bridge)..registerDefaults();
        final session = _SlowDetachSession();
        server.setDaemonSession(session);
        final input = StreamController<List<int>>();
        final sink = _BrokenPipeSink();

        final exited = serveUntilExit(
          server: server,
          bridge: bridge,
          handoff: SnapshotDiskHandoff(tempDir: tmp),
          input: input.stream,
          output: sink,
        );
        // The response to a request is written by its dispatch; the parse
        // error after it, if it is still read, by its own write path.
        input.add(
          utf8.encode(
            '${jsonEncode({
              'jsonrpc': '2.0',
              'method': 'initialize',
              'params': {'protocolVersion': '2025-06-18'},
              'id': 1,
            })}\n',
          ),
        );
        input.add(utf8.encode('{not json\n'));
        await exited.timeout(const Duration(seconds: 5));
        expect(session.detachCalls, 1);
        expect(session.detachCompleted, isTrue);
        expect(sink.flushes, 1, reason: 'no write after the first failure');
        await input.close();
      },
    );

    test('a failed parse-error answer starts the shutdown', () async {
      final server = McpServer(bridge: defaultFakeBridge())..registerDefaults();
      final session = _SlowDetachSession();
      server.setDaemonSession(session);
      final input = StreamController<List<int>>();
      final served = server.serve(
        input: input.stream,
        output: _BrokenPipeSink(),
      );
      input.add(utf8.encode('{not json\n'));
      await served.timeout(const Duration(seconds: 5));
      await server.detachDaemonSession();
      expect(session.detachCalls, 1);
      expect(session.detachCompleted, isTrue);
      await input.close();
    });

    test('a failed progress write ends the session without an unhandled '
        'error', () async {
      final bridge = defaultFakeBridge();
      final server = McpServer(bridge: bridge)..registerDefaults();
      final session = DaemonSession(
        bridge: bridge,
        server: server,
        processFactory:
            (
              _,
              _, {
              String? workingDirectory,
              Map<String, String>? environment,
            }) async => throw StateError('debugUrl attach spawns nothing'),
        detachBudget: _fastDetach,
      );
      server.setDaemonSession(session);
      final input = StreamController<List<int>>();
      // The initialize response is written; the progress frame fails.
      final sink = _BrokenPipeSink(failFrom: 2);

      final exited = serveUntilExit(
        server: server,
        bridge: bridge,
        handoff: SnapshotDiskHandoff(tempDir: tmp),
        input: input.stream,
        output: sink,
      );
      for (final message in <Map<String, Object?>>[
        {
          'method': 'initialize',
          'params': {'protocolVersion': '2025-06-18'},
          'id': 1,
        },
        {
          'method': 'tools/call',
          'params': {
            'name': 'attach_app',
            'arguments': {'debugUrl': 'ws://127.0.0.1:1/tok/ws'},
            '_meta': {'progressToken': 'p'},
          },
          'id': 2,
        },
      ]) {
        input.add(
          utf8.encode('${jsonEncode({'jsonrpc': '2.0', ...message})}\n'),
        );
      }
      await exited.timeout(const Duration(seconds: 5));
      expect(session.status.state, 'idle');
      expect(bridge.isConnected, isFalse);
      await input.close();
    });

    test('a sink that fails through done starts the shutdown', () async {
      final server = McpServer(bridge: defaultFakeBridge())..registerDefaults();
      final session = CountingSession();
      server.setDaemonSession(session);
      final sink = _BrokenPipeSink(failFrom: 1 << 30);
      final input = StreamController<List<int>>();
      final served = server.serve(input: input.stream, output: sink);
      sink.failDone();
      await served.timeout(const Duration(seconds: 5));
      expect(session.detachCalls, 1);
      await input.close();
    });
  });

  group('exit drain', () {
    test('a shutdown before serving starts ends serving at once', () async {
      final server = McpServer(bridge: defaultFakeBridge())..registerDefaults();
      final session = CountingSession();
      server.setDaemonSession(session);
      server.shutdown();
      final input = StreamController<List<int>>();
      await server
          .serve(input: input.stream, output: JsonLineSink())
          .timeout(const Duration(seconds: 2));
      expect(session.detachCalls, 1);
      await input.close();
    });

    test(
      'serve returns after the drain bound while a request still runs',
      () async {
        final bridge = defaultFakeBridge();
        await bridge.connect(Uri.parse('ws://localhost/ws'));
        final server = McpServer(
          bridge: bridge,
          toolTimeout: const Duration(minutes: 5),
          exitDrainTimeout: const Duration(milliseconds: 100),
        )..registerDefaults();
        final stuck = bridge.gateExtension('ext.sleuth.diagnose');
        final wire = McpWire(server);
        wire.initialize('2025-06-18');
        await wire.response(0);
        wire.call(1, 'diagnose');
        await Future<void>.delayed(const Duration(milliseconds: 20));

        final watch = Stopwatch()..start();
        await wire.close(within: const Duration(seconds: 2));
        expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
        expect(wire.hasResponse(1), isFalse);
        stuck.complete();
      },
    );

    test(
      'a request that ends within the bound still gets its response',
      () async {
        final bridge = defaultFakeBridge();
        await bridge.connect(Uri.parse('ws://localhost/ws'));
        final server = McpServer(
          bridge: bridge,
          exitDrainTimeout: const Duration(seconds: 5),
        )..registerDefaults();
        final slow = bridge.gateExtension('ext.sleuth.diagnose');
        final wire = McpWire(server);
        wire.initialize('2025-06-18');
        await wire.response(0);
        wire.call(1, 'diagnose');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        Timer(const Duration(milliseconds: 50), slow.complete);
        await wire.close();
        expect((await wire.response(1))['result'], isA<Map<String, Object?>>());
      },
    );

    test(
      'serveUntilExit detaches and returns while a request still runs',
      () async {
        final bridge = defaultFakeBridge();
        await bridge.connect(Uri.parse('ws://localhost/ws'));
        final server = McpServer(
          bridge: bridge,
          toolTimeout: const Duration(minutes: 5),
          exitDrainTimeout: const Duration(milliseconds: 100),
        )..registerDefaults();
        final session = CountingSession();
        server.setDaemonSession(session);
        final stuck = bridge.gateExtension('ext.sleuth.diagnose');
        final input = StreamController<List<int>>();
        final exited = serveUntilExit(
          server: server,
          bridge: bridge,
          handoff: SnapshotDiskHandoff(tempDir: tmp),
          input: input.stream,
          output: JsonLineSink(),
        );
        for (final message in <Map<String, Object?>>[
          {
            'method': 'initialize',
            'params': {'protocolVersion': '2025-06-18'},
            'id': 1,
          },
          {
            'method': 'tools/call',
            'params': {'name': 'diagnose', 'arguments': <String, Object?>{}},
            'id': 2,
          },
        ]) {
          input.add(
            utf8.encode('${jsonEncode({'jsonrpc': '2.0', ...message})}\n'),
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await input.close();
        await exited.timeout(const Duration(seconds: 3));
        expect(session.detachCalls, 1);
        expect(bridge.isConnected, isFalse);
        stuck.complete();
      },
    );
  });
}
