@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:isolate';

import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:sleuth_mcp/src/bridge/app_log_stream.dart';
import 'package:sleuth_mcp/src/flutter_daemon/app_log_buffer.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart' as vm;

vm.Event _write(String text, {int timestamp = 1700000000000}) => vm.Event(
  kind: vm.EventKind.kWriteEvent,
  timestamp: timestamp,
  bytes: base64.encode(utf8.encode(text)),
);

void main() {
  group('VmLogEventDecoder', () {
    late List<AppLogLine> lines;
    late VmLogEventDecoder decoder;

    setUp(() {
      lines = [];
      decoder = VmLogEventDecoder(lines.add, maxPendingLength: 16);
    });

    test('splits a write into lines and keeps the unfinished tail', () {
      decoder.onWrite('stdout', _write('one\ntwo\r\nthr'));
      expect(lines.map((l) => l.text), ['one', 'two']);
      decoder.onWrite('stdout', _write('ee\n'));
      expect(lines.map((l) => l.text), ['one', 'two', 'three']);
      expect(lines.map((l) => l.source), everyElement('stdout'));
      expect(
        lines.first.time,
        DateTime.fromMillisecondsSinceEpoch(1700000000000),
      );
    });

    test('keeps stdout and stderr tails apart', () {
      decoder.onWrite('stdout', _write('out-'));
      decoder.onWrite('stderr', _write('err\n'));
      decoder.onWrite('stdout', _write('done\n'));
      expect(lines.map((l) => '${l.source}:${l.text}'), [
        'stderr:err',
        'stdout:out-done',
      ]);
    });

    test('a tail without a newline is emitted once it grows too long', () {
      decoder.onWrite('stdout', _write('0123456789abcdefXYZ'));
      expect(lines.single.text, '0123456789abcdefXYZ');
    });

    test('a Logging event becomes one line with level and logger', () {
      decoder.onLogging(
        vm.Event(
          kind: vm.EventKind.kLogging,
          timestamp: 1,
          logRecord: vm.LogRecord(
            message: vm.InstanceRef(
              id: 'm',
              kind: vm.InstanceKind.kString,
              valueAsString: 'cache miss',
              valueAsStringIsTruncated: true,
            ),
            time: 1700000000500,
            level: 900,
            loggerName: vm.InstanceRef(
              id: 'n',
              kind: vm.InstanceKind.kString,
              valueAsString: 'net',
            ),
          ),
        ),
      );
      final line = lines.single;
      expect(line.source, 'logging');
      expect(line.text, 'cache miss');
      expect(line.level, 900);
      expect(line.logger, 'net');
      expect(line.truncated, isTrue);
      expect(line.toJson(), containsPair('truncated', true));
    });
  });

  group('AppLogBuffer', () {
    AppLogLine line(String text) =>
        AppLogLine(time: DateTime.utc(2026), source: 'stdout', text: text);

    test('keeps the newest lines and counts the evicted ones', () {
      final buffer = AppLogBuffer(capacity: 3);
      for (var i = 0; i < 5; i++) {
        buffer.add(line('l$i'));
      }
      expect(buffer.length, 3);
      expect(buffer.droppedCount, 2);
      expect(buffer.query(maxLines: 10).lines.map((l) => l.text), [
        'l2',
        'l3',
        'l4',
      ]);
      buffer.clear();
      expect(buffer.length, 0);
      expect(buffer.droppedCount, 0);
    });

    test('cuts long lines and marks them truncated', () {
      final buffer = AppLogBuffer(maxLineLength: 4);
      buffer.add(line('abcdefgh'));
      final kept = buffer.query(maxLines: 1).lines.single;
      expect(kept.text, 'abcd');
      expect(kept.truncated, isTrue);
    });

    test('filters case-insensitively and caps to the newest matches', () {
      final buffer = AppLogBuffer();
      for (final text in ['GET /a', 'error one', 'get /b', 'Error two']) {
        buffer.add(line(text));
      }
      final result = buffer.query(maxLines: 1, filter: 'ERROR');
      expect(result.matched, 2);
      expect(result.lines.single.text, 'Error two');
    });
  });

  group('RealVmBridge app log streams', () {
    final isolateId = developer.Service.getIsolateId(Isolate.current);

    setUpAll(() {
      developer.registerExtension('ext.sleuth.diagnose', (method, args) async {
        return developer.ServiceExtensionResponse.result(
          jsonEncode({
            'connectionMode': 'basic',
            'schemaVersion': 1,
            'sessionUuid': 'log-test-uuid',
            'data': {'packageVersion': '0.37.0'},
          }),
        );
      });
    });

    test('forwards dart:developer log records after connect', () async {
      final info = await developer.Service.controlWebServer(
        enable: true,
        silenceOutput: true,
      );
      final wsUri = info.serverWebSocketUri;
      if (wsUri == null) {
        markTestSkipped('VM service not available');
        return;
      }
      final bridge = RealVmBridge(
        callTimeout: const Duration(seconds: 5),
        targetIsolateIdOverride: isolateId,
      );
      final received = <AppLogLine>[];
      final subscription = bridge.appLogLines.listen(received.add);
      await bridge.connect(wsUri);
      try {
        final watch = Stopwatch()..start();
        while (!bridge.appLogStreamsActive &&
            watch.elapsed < const Duration(seconds: 5)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(bridge.appLogStreamsActive, isTrue);

        developer.log('sidecar log probe', name: 'probe', level: 800);
        while (!received.any((l) => l.text == 'sidecar log probe') &&
            watch.elapsed < const Duration(seconds: 10)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        final line = received.firstWhere((l) => l.text == 'sidecar log probe');
        expect(line.source, 'logging');
        expect(line.logger, 'probe');
        expect(line.level, 800);
      } finally {
        await subscription.cancel();
        await bridge.disconnect();
      }
      expect(bridge.appLogStreamsActive, isFalse);
    }, timeout: const Timeout(Duration(seconds: 30)));
  });
}
