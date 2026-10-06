import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:sleuth_mcp/src/bridge/app_log_stream.dart';
import 'package:sleuth_mcp/src/flutter_daemon/app_log_buffer.dart';
import 'package:sleuth_mcp/src/tools/budgets.dart';
import 'package:test/test.dart';

import '../helpers/fake_flutter_process.dart';
import '../helpers/fake_vm_bridge.dart';

JsonRpcMessage _call(String name, Map<String, Object?> args, {int id = 1}) =>
    JsonRpcMessage(
      method: 'tools/call',
      params: {'name': name, 'arguments': args},
      id: id,
    );

class _Ctx {
  _Ctx(this.server, this.bridge, this.session);
  final McpServer server;
  final FakeVmBridge bridge;
  final DaemonSession session;

  Future<Map<String, Object?>> call(
    String name, [
    Map<String, Object?> args = const {},
  ]) async {
    final resp = await server.handleForTest(_call(name, args));
    return resp!.result as Map<String, Object?>;
  }
}

Future<_Ctx> _setup({
  FakeVmBridge? bridge,
  List<FakeFlutterProcess> processes = const [],
  AppLogBuffer? appLogs,
  Duration hotReloadTimeout = const Duration(seconds: 2),
}) async {
  final b = bridge ?? defaultFakeBridge();
  final server = McpServer(bridge: b)..registerDefaults();
  await server.handleForTest(
    JsonRpcMessage(
      method: 'initialize',
      id: 0,
      params: const {'protocolVersion': '2024-11-05'},
    ),
  );
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
    attachTimeout: const Duration(seconds: 2),
    hotReloadTimeout: hotReloadTimeout,
    appLogs: appLogs,
  );
  server.setDaemonSession(session);
  return _Ctx(server, b, session);
}

String _text(Map<String, Object?> result, [int block = 0]) =>
    ((result['content'] as List)[block] as Map)['text'] as String;

Map<String, Object?> _json(Map<String, Object?> result, [int block = 0]) =>
    jsonDecode(_text(result, block)) as Map<String, Object?>;

Future<void> _driveToDebugPort(FakeFlutterProcess fake) async {
  await Future<void>.delayed(Duration.zero);
  fake.emitEvent('daemon.connected', {'version': '0.6.1', 'pid': 100});
  await Future<void>.delayed(Duration.zero);
  fake.emitEvent('app.start', {
    'appId': 'A',
    'deviceId': 'pixel',
    'launchMode': 'attach',
    'mode': 'profile',
  });
  await Future<void>.delayed(Duration.zero);
  fake.emitEvent('app.debugPort', {
    'appId': 'A',
    'port': 4242,
    'wsUri': 'ws://127.0.0.1:4242/tok/ws',
  });
}

/// Answers the next daemon RPC with [result].
Future<void> _answerRpc(FakeFlutterProcess fake, Object? result) async {
  await Future<void>.delayed(const Duration(milliseconds: 10));
  final request = (jsonDecode(fake.stdinFrames.last) as List).first as Map;
  fake.emitRpcResponse(request['id'] as int, result: result);
}

void main() {
  group('attach_app failures are errors', () {
    test('a refused debugUrl returns attach_failed with the status', () async {
      final ctx = await _setup(bridge: _RefusingBridge());
      final result = await ctx.call('attach_app', {
        'debugUrl': 'ws://127.0.0.1:1/tok/ws',
      });
      expect(result['isError'], isTrue);
      expect(
        _text(result),
        startsWith('attach_failed: debugUrl connect failed'),
      );
      final detail = _json(result, 1);
      expect(detail['error'], 'attach_failed');
      final status = detail['status'] as Map<String, Object?>;
      expect(status['state'], 'error');
      expect(status['attached'], isFalse);
      expect(status['lastError'], contains('connection refused'));
    });

    test('flutter failing to start returns attach_failed', () async {
      final ctx = await _setup();
      final result = await ctx.call('attach_app', const {});
      expect(result['isError'], isTrue);
      expect(
        _text(result),
        startsWith('attach_failed: failed to spawn flutter'),
      );
    });

    test(
      'flutter exiting early returns attach_failed with its output',
      () async {
        final fake = FakeFlutterProcess();
        final ctx = await _setup(processes: [fake]);
        final pending = ctx.call('attach_app', const {});
        await Future<void>.delayed(const Duration(milliseconds: 10));
        fake.emitStderr('More than one device connected.\n');
        fake.exitEarly(1);
        final result = await pending.timeout(const Duration(seconds: 3));
        expect(result['isError'], isTrue);
        expect(
          _text(result),
          startsWith('attach_failed: flutter attach exited'),
        );
        expect(_text(result), contains('More than one device connected.'));
      },
    );

    test('a successful attach is not an error', () async {
      final ctx = await _setup();
      final result = await ctx.call('attach_app', {
        'debugUrl': 'ws://127.0.0.1:1/tok/ws',
      });
      expect(result['isError'], isNot(isTrue));
      expect(_json(result)['connectedVia'], 'attach_debug_url');
    });
  });

  group('hot_reload', () {
    test(
      'a debugUrl session gets hot_reload_unsupported and keeps working',
      () async {
        final ctx = await _setup();
        await ctx.call('attach_app', {'debugUrl': 'ws://127.0.0.1:1/tok/ws'});
        final result = await ctx.call('hot_reload');
        expect(result['isError'], isTrue);
        expect(_text(result), startsWith('hot_reload_unsupported:'));
        expect(_text(result), contains('attach_app(device:)'));
        expect(_json(result, 1)['remedy'], contains('attach_app(device:'));
        final status = _json(await ctx.call('app_status'));
        expect(status['state'], 'ready');
        expect(status['attached'], isTrue);
        expect(ctx.bridge.isConnected, isTrue);
      },
    );

    test('a connect session gets hot_reload_unsupported', () async {
      final ctx = await _setup();
      await ctx.bridge.connect(Uri.parse('ws://127.0.0.1:1/tok/ws'));
      final result = await ctx.call('hot_reload');
      expect(result['isError'], isTrue);
      expect(_text(result), startsWith('hot_reload_unsupported:'));
      expect(_text(result), contains('opened with connect'));
    });

    test(
      'a reload flutter rejects returns hot_reload_failed and stays ready',
      () async {
        final fake = FakeFlutterProcess();
        final ctx = await _setup(processes: [fake]);
        final attach = ctx.call('attach_app', const {});
        await _driveToDebugPort(fake);
        await attach;
        final reload = ctx.call('hot_reload');
        await _answerRpc(fake, {'code': 1, 'message': 'Compilation failed'});
        final result = await reload.timeout(const Duration(seconds: 3));
        expect(result['isError'], isTrue);
        expect(_text(result), startsWith('hot_reload_failed:'));
        expect(_text(result), contains('Compilation failed'));
        final status = _json(result, 1)['status'] as Map<String, Object?>;
        expect(status['state'], 'ready');
      },
    );

    test(
      'a timed-out reload returns hot_reload_failed with state error',
      () async {
        final fake = FakeFlutterProcess();
        final ctx = await _setup(
          processes: [fake],
          hotReloadTimeout: const Duration(milliseconds: 50),
        );
        final attach = ctx.call('attach_app', const {});
        await _driveToDebugPort(fake);
        await attach;
        final result = await ctx.call('hot_reload');
        expect(result['isError'], isTrue);
        expect(
          _text(result),
          startsWith('hot_reload_failed: hot reload timed out'),
        );
        final status = _json(result, 1)['status'] as Map<String, Object?>;
        expect(status['state'], 'error');
      },
    );
  });

  group('detach_app and app_status after connect', () {
    test(
      'app_status reports a connect session without calling it attached',
      () async {
        final ctx = await _setup();
        await ctx.bridge.connect(Uri.parse('ws://127.0.0.1:1/tok/ws'));
        final status = _json(await ctx.call('app_status'));
        expect(status['attached'], isFalse);
        expect(status['state'], 'idle');
        expect(status['connected'], isTrue);
        expect(status['connectedVia'], 'connect');
      },
    );

    test('detach_app disconnects a bridge that connect opened', () async {
      final ctx = await _setup();
      await ctx.bridge.connect(Uri.parse('ws://127.0.0.1:1/tok/ws'));
      final issuesBefore = await ctx.call('get_issues');
      expect(issuesBefore['isError'], isNot(isTrue));

      final detached = _json(await ctx.call('detach_app'));
      expect(detached['connected'], isFalse);
      expect(ctx.bridge.isConnected, isFalse);

      final issuesAfter = await ctx.call('get_issues');
      expect(issuesAfter['isError'], isTrue);
      expect(_text(issuesAfter), contains(RegExp('not[ _]connected')));
    });
  });

  group('get_logs', () {
    AppLogLine line(String text, {String source = 'stdout'}) =>
        AppLogLine(time: DateTime.utc(2026, 10, 6), source: source, text: text);

    test('returns the newest lines, oldest first, and filters', () async {
      final logs = AppLogBuffer();
      final ctx = await _setup(appLogs: logs);
      for (var i = 0; i < 150; i++) {
        logs.add(line('line $i'));
      }
      logs.add(line('Error: boom', source: 'stderr'));

      final all = _json(await ctx.call('get_logs'));
      expect(all['count'], 100, reason: 'default maxLines');
      expect(all['matchedCount'], 151);
      expect(all['bufferedCount'], 151);
      expect(all['droppedCount'], 0);
      expect(all['capturing'], 'none');
      final lines = (all['lines'] as List).cast<Map<String, Object?>>();
      expect(lines.first['text'], 'line 51');
      expect(lines.last['text'], 'Error: boom');
      expect(lines.last['source'], 'stderr');
      expect(lines.last['time'], '2026-10-06T00:00:00.000Z');

      final filtered = _json(
        await ctx.call('get_logs', {'filter': 'ERROR', 'maxLines': 5}),
      );
      expect(filtered['count'], 1);
      expect(filtered['matchedCount'], 1);
      expect(
        ((filtered['lines'] as List).single as Map)['text'],
        'Error: boom',
      );

      final few = _json(await ctx.call('get_logs', {'maxLines': 2}));
      expect((few['lines'] as List).map((l) => (l as Map)['text']), [
        'line 149',
        'Error: boom',
      ]);
    });

    test('says how many lines the full buffer dropped', () async {
      final logs = AppLogBuffer(capacity: 3);
      final ctx = await _setup(appLogs: logs);
      for (var i = 0; i < 5; i++) {
        logs.add(line('l$i'));
      }
      final result = _json(await ctx.call('get_logs', {'maxLines': 999}));
      expect(result['droppedCount'], 2);
      expect(result['bufferedCount'], 3);
      expect((result['lines'] as List).map((l) => (l as Map)['text']), [
        'l2',
        'l3',
        'l4',
      ]);
    });

    test('rejects maxLines below 1', () async {
      final ctx = await _setup();
      final result = await ctx.call('get_logs', {'maxLines': 0});
      expect(result['isError'], isTrue);
      expect(_text(result), startsWith('arg_invalid_int: maxLines'));
    });

    test(
      'daemon app.log lines show up while attached through flutter',
      () async {
        final fake = FakeFlutterProcess();
        final ctx = await _setup(processes: [fake]);
        final attach = ctx.call('attach_app', const {});
        await _driveToDebugPort(fake);
        await attach;
        fake.emitEvent('app.log', {'appId': 'A', 'log': 'flutter: hello'});
        await Future<void>.delayed(const Duration(milliseconds: 10));
        final result = _json(await ctx.call('get_logs'));
        expect(result['capturing'], 'daemon');
        expect(
          ((result['lines'] as List).single as Map)['text'],
          'flutter: hello',
        );
      },
    );
  });

  group('check_budgets defaults', () {
    test('a call without arguments uses the sleuth_check defaults', () async {
      final bridge = defaultFakeBridge()
        ..setEnvelope(
          'ext.sleuth.snapshot',
          fakeSnapshotEnvelope(isVmConnected: true),
        );
      final ctx = await _setup(bridge: bridge);
      await bridge.connect(Uri.parse('ws://127.0.0.1:1/tok/ws'));
      final result = await ctx.call('check_budgets');
      expect(result['isError'], isNot(isTrue));
      final report = _json(result);
      // The fake snapshot has 59.5 fps, two issues and one critical.
      expect(report['passed'], isFalse);
      expect(report['violations'], [
        {'budget': 'maxCriticalIssues', 'expected': 0, 'observed': 1},
      ]);
    });

    test('the defaults match the sleuth_check option defaults', () {
      final source = File('lib/src/cli/check_command.dart').readAsStringSync();
      String defaultOf(String option) {
        final match = RegExp(
          "'$option',[^;]*?defaultsTo: '([^']+)'",
          dotAll: true,
        ).firstMatch(source);
        expect(match, isNotNull, reason: '--$option has no default');
        return match!.group(1)!;
      }

      expect(num.parse(defaultOf('min-fps')), defaultMinFps);
      expect(int.parse(defaultOf('max-issues')), defaultMaxIssues);
      expect(
        int.parse(defaultOf('max-critical-issues')),
        defaultMaxCriticalIssues,
      );
    });
  });
}

/// Fake bridge that refuses every connect.
class _RefusingBridge extends FakeVmBridge {
  _RefusingBridge() : super(fakeSessionUuid: 'u');

  @override
  Future<bool> connect(Uri wsUri) async =>
      throw VmBridgeException('failed to connect: connection refused');
}
