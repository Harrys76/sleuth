import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:test/test.dart';

import '../helpers/fake_flutter_process.dart';
import '../helpers/fake_vm_bridge.dart';

/// Collects every frame the server writes, one decoded JSON map per line.
class _FrameSink implements IOSink {
  final List<Map<String, Object?>> frames = [];
  String _partial = '';

  @override
  Encoding encoding = utf8;

  @override
  void write(Object? obj) {
    final text = _partial + obj.toString();
    final parts = text.split('\n');
    _partial = parts.removeLast();
    for (final line in parts) {
      if (line.trim().isEmpty) continue;
      frames.add(jsonDecode(line) as Map<String, Object?>);
    }
  }

  @override
  Future<void> flush() async {}
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
  @override
  Future<void> get done => Future.value();
}

/// A server driven through [McpServer.serve] over in-memory pipes.
class _Wire {
  _Wire(this.server, this.session) {
    served = server.serve(input: _input.stream, output: output);
  }

  final McpServer server;
  final DaemonSession session;
  final StreamController<List<int>> _input = StreamController<List<int>>();
  final _FrameSink output = _FrameSink();
  late final Future<void> served;

  void send(Map<String, Object?> message) {
    _input.add(utf8.encode('${jsonEncode({'jsonrpc': '2.0', ...message})}\n'));
  }

  void initialize(String protocolVersion) => send({
    'method': 'initialize',
    'params': {'protocolVersion': protocolVersion},
    'id': 0,
  });

  void call(
    Object id,
    String tool, {
    Map<String, Object?> args = const {},
    Object? progressToken,
  }) => send({
    'method': 'tools/call',
    'params': {
      'name': tool,
      'arguments': args,
      if (progressToken != null) '_meta': {'progressToken': progressToken},
    },
    'id': id,
  });

  void cancel(Object requestId) => send({
    'method': 'notifications/cancelled',
    'params': {'requestId': requestId, 'reason': 'user stopped it'},
  });

  /// Waits until the response to [id] arrives and returns it.
  Future<Map<String, Object?>> response(Object id) async {
    final watch = Stopwatch()..start();
    while (watch.elapsed < const Duration(seconds: 5)) {
      for (final frame in output.frames) {
        if (frame['id'] == id && !frame.containsKey('method')) return frame;
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    throw TimeoutException('no response for id $id');
  }

  List<Map<String, Object?>> progressFrames() => [
    for (final frame in output.frames)
      if (frame['method'] == 'notifications/progress') frame,
  ];

  bool hasResponse(Object id) =>
      output.frames.any((f) => f['id'] == id && !f.containsKey('method'));

  Future<void> close() async {
    await _input.close();
    await served.timeout(const Duration(seconds: 5));
  }
}

_Wire _wire({
  FakeVmBridge? bridge,
  List<FakeFlutterProcess> processes = const [],
  IosAttacher? iosAttacher,
}) {
  final b = bridge ?? defaultFakeBridge();
  final server = McpServer(bridge: b)..registerDefaults();
  var next = 0;
  final session = DaemonSession(
    bridge: b,
    server: server,
    processFactory:
        (
          String exe,
          List<String> args, {
          String? workingDirectory,
          Map<String, String>? environment,
        }) async {
          if (next >= processes.length) {
            throw const ProcessException('flutter', [], 'not scripted');
          }
          return processes[next++];
        },
    iosAttacher: iosAttacher,
  );
  server.setDaemonSession(session);
  return _Wire(server, session);
}

void main() {
  group('progress notifications', () {
    test('attach_app reports each iOS stage before its response', () async {
      final wire = _wire(iosAttacher: _PhasedAttacher());
      wire.initialize('2025-06-18');
      await wire.response(0);
      wire.call(
        1,
        'attach_app',
        args: {'udid': 'U', 'bundle': 'com.example.app'},
        progressToken: 'attach-1',
      );
      final response = await wire.response(1);
      expect((response['result'] as Map)['isError'], isNot(isTrue));

      final progress = wire.progressFrames();
      final params = [for (final f in progress) f['params'] as Map];
      expect(params.map((p) => p['progressToken']), everyElement('attach-1'));
      expect(params.map((p) => p['progress']), [1, 2, 3, 4, 5]);
      expect(params.map((p) => p['message']), [
        'Detecting whether the device is on USB or wireless',
        'Looking for the app VM service over Bonjour',
        'Found 2 VM service announcement(s)',
        'Selecting the VM service to connect to',
        'Connecting to the app VM service',
      ]);
      expect(params.every((p) => !p.containsKey('total')), isTrue);
      // Every progress frame precedes the response frame.
      final responseIndex = wire.output.frames.indexOf(response);
      for (final frame in progress) {
        expect(wire.output.frames.indexOf(frame), lessThan(responseIndex));
      }
      await wire.close();
    });

    test('a numeric token works and old protocols get no message', () async {
      final wire = _wire();
      wire.initialize('2024-11-05');
      await wire.response(0);
      wire.call(
        1,
        'attach_app',
        args: {'debugUrl': 'ws://127.0.0.1:1/tok/ws'},
        progressToken: 42,
      );
      await wire.response(1);
      final params = wire.progressFrames().single['params'] as Map;
      expect(params['progressToken'], 42);
      expect(params['progress'], 1);
      expect(params.containsKey('message'), isFalse);
      await wire.close();
    });

    test('no progress token, no progress notifications', () async {
      final wire = _wire(iosAttacher: _PhasedAttacher());
      wire.initialize('2025-06-18');
      await wire.response(0);
      wire.call(1, 'attach_app', args: {'udid': 'U', 'bundle': 'b'});
      await wire.response(1);
      expect(wire.progressFrames(), isEmpty);
      await wire.close();
    });
  });

  group('cancellation', () {
    test('notifications/cancelled stops a daemon attach_app: no response, '
        'the flutter child stops and the session is idle', () async {
      final fake = FakeFlutterProcess();
      final wire = _wire(processes: [fake]);
      wire.initialize('2025-06-18');
      await wire.response(0);
      wire.call(7, 'attach_app', progressToken: 'p');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(wire.session.status.state, 'attaching');

      wire.cancel(7);
      // The detach the cancel starts takes a few event-loop turns.
      final watch = Stopwatch()..start();
      while (wire.session.status.state != 'idle' &&
          watch.elapsed < const Duration(seconds: 2)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      wire.call(8, 'app_status');
      final status = await wire.response(8);
      final payload =
          jsonDecode(
                (((status['result'] as Map)['content'] as List).first
                        as Map)['text']
                    as String,
              )
              as Map<String, Object?>;
      expect(payload['state'], 'idle');
      expect(fake.killed, isTrue);

      await wire.close();
      expect(wire.hasResponse(7), isFalse, reason: 'cancelled: no response');
      // No progress after the cancel either.
      final last = wire.progressFrames().last['params'] as Map;
      expect(last['message'], isNot(contains('Connecting')));
    });

    test('notifications/cancelled stops an iOS attach_app and frees the '
        'attach lock', () async {
      final wire = _wire(iosAttacher: _WaitForCancelAttacher());
      wire.initialize('2025-06-18');
      await wire.response(0);
      wire.call(3, 'attach_app', args: {'udid': 'U', 'bundle': 'b'});
      await Future<void>.delayed(const Duration(milliseconds: 30));
      wire.cancel(3);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(wire.session.status.state, 'idle');

      // A new attach is not refused with attach_in_progress.
      wire.call(4, 'attach_app', args: {'udid': 'U', 'bundle': 'b'});
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(wire.session.status.state, 'attaching');
      wire.cancel(4);
      await wire.close();
      expect(wire.hasResponse(3), isFalse);
      expect(wire.hasResponse(4), isFalse);
    });

    test('a cancel for an unknown or finished request is ignored', () async {
      final wire = _wire();
      wire.initialize('2025-06-18');
      await wire.response(0);
      wire.call(1, 'app_status');
      await wire.response(1);
      wire.cancel(1);
      wire.cancel('never-sent');
      wire.call(2, 'app_status');
      final second = await wire.response(2);
      expect((second['result'] as Map)['isError'], isNot(isTrue));
      await wire.close();
      expect(
        wire.output.frames.where((f) => f['id'] == 1),
        hasLength(1),
        reason: 'the finished request keeps its one response',
      );
    });

    test('a cancelled read-only tool gets no response', () async {
      final bridge = defaultFakeBridge();
      final wire = _wire(bridge: bridge);
      wire.initialize('2025-06-18');
      await wire.response(0);
      await bridge.connect(Uri.parse('ws://127.0.0.1:1/tok/ws'));
      final gate = bridge.gateExtension('ext.sleuth.snapshot');
      wire.call(5, 'get_snapshot');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      wire.cancel(5);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      gate.complete();
      wire.call(6, 'app_status');
      await wire.response(6);
      await wire.close();
      expect(wire.hasResponse(5), isFalse);
    });
  });
}

IosAttachResult _iosResult() {
  final announcement = BonjourAnnouncement(
    interfaceIndex: 24,
    host: 'Phone.local.',
    port: 50000,
    authCode: 'auth',
  );
  return IosAttachResult(
    wsUri: 'ws://127.0.0.1:50000/auth=/ws',
    transport: IosTransport.wired,
    announcements: [announcement],
    selected: announcement,
    hostPort: 50000,
    teardown: () async {},
    origin: IosAttachOrigin.probedExisting,
  );
}

/// iOS pipeline that reports a few stages, then succeeds.
class _PhasedAttacher extends IosAttacher {
  @override
  Future<IosAttachResult> attach({
    required String udid,
    required String bundle,
    String? authOverride,
    int? hostPortOverride,
    IosTransport? transportOverride,
    Duration bonjourCollectFor = const Duration(seconds: 8),
    Duration bonjourTimeout = const Duration(seconds: 20),
    Duration launchSettle = const Duration(seconds: 1),
    Duration readinessWindow = const Duration(milliseconds: 300),
    String pidfileDirectory = '/tmp',
    IosAttachProgress? onProgress,
    Stream<void>? cancelSignal,
    Map<String, String>? environment,
    bool forceRelaunch = false,
    Set<int> excludePorts = const <int>{},
    Duration devicectlTimeout = const Duration(seconds: 20),
  }) async {
    onProgress?.call(IosAttachPhase.detectingTransport);
    onProgress?.call(IosAttachPhase.resolvingBonjour);
    onProgress?.call(
      IosAttachPhase.announcementsCollected,
      data: <String, Object?>{
        'announcements': [<String, Object?>{}, <String, Object?>{}],
      },
    );
    onProgress?.call(IosAttachPhase.selectingAnnouncement);
    onProgress?.call(IosAttachPhase.attachComplete);
    return _iosResult();
  }
}

/// iOS pipeline that waits for its cancel signal, then reports the cancel.
class _WaitForCancelAttacher extends IosAttacher {
  @override
  Future<IosAttachResult> attach({
    required String udid,
    required String bundle,
    String? authOverride,
    int? hostPortOverride,
    IosTransport? transportOverride,
    Duration bonjourCollectFor = const Duration(seconds: 8),
    Duration bonjourTimeout = const Duration(seconds: 20),
    Duration launchSettle = const Duration(seconds: 1),
    Duration readinessWindow = const Duration(milliseconds: 300),
    String pidfileDirectory = '/tmp',
    IosAttachProgress? onProgress,
    Stream<void>? cancelSignal,
    Map<String, String>? environment,
    bool forceRelaunch = false,
    Set<int> excludePorts = const <int>{},
    Duration devicectlTimeout = const Duration(seconds: 20),
  }) async {
    await cancelSignal!.first;
    throw IosAttachException(
      IosAttachErrorKind.cancelled,
      'attach cancelled by caller',
    );
  }
}
