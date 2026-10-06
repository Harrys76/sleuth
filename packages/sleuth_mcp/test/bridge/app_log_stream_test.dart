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

    vm.Event cutLog(String shown) => vm.Event(
      kind: vm.EventKind.kLogging,
      timestamp: 1,
      isolate: vm.IsolateRef(id: 'isolates/1'),
      logRecord: vm.LogRecord(
        message: vm.InstanceRef(
          id: 'objects/7',
          kind: vm.InstanceKind.kString,
          valueAsString: shown,
          valueAsStringIsTruncated: true,
        ),
        time: 1700000000500,
        level: 0,
      ),
    );

    test('a cut Logging message is read in full and keeps its order', () async {
      final requests = <String>[];
      final full = Completer<ResolvedLogMessage?>();
      decoder = VmLogEventDecoder(
        lines.add,
        resolveMessage: (isolateId, messageId) {
          requests.add('$isolateId $messageId');
          return full.future;
        },
      );
      decoder.onLogging(cutLog('first part'));
      decoder.onWrite('stdout', _write('after\n'));
      // The stdout line waits behind the log line being read.
      expect(lines, isEmpty);
      full.complete((text: 'first part and the rest', complete: true));
      await pumpEventQueue();
      expect(requests, ['isolates/1 objects/7']);
      expect(lines.map((l) => l.text), ['first part and the rest', 'after']);
      expect(lines.first.truncated, isFalse);
    });

    test('a cut message that cannot be read stays marked truncated', () async {
      decoder = VmLogEventDecoder(
        lines.add,
        resolveMessage: (_, _) async => throw StateError('gone'),
      );
      decoder.onLogging(cutLog('shown text'));
      await pumpEventQueue();
      expect(lines.single.text, 'shown text');
      expect(lines.single.truncated, isTrue);
    });

    test('a slow read gives up after resolveTimeout', () async {
      decoder = VmLogEventDecoder(
        lines.add,
        resolveMessage: (_, _) => Completer<ResolvedLogMessage?>().future,
        resolveTimeout: const Duration(milliseconds: 20),
      );
      decoder.onLogging(cutLog('shown text'));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(lines.single.truncated, isTrue);
    });

    test('a message read only in part stays marked truncated', () async {
      final start = 'x' * maxAppLogLineLength;
      decoder = VmLogEventDecoder(
        lines.add,
        resolveMessage: (_, _) async => (text: start, complete: false),
      );
      decoder.onLogging(cutLog('x' * 128));
      await pumpEventQueue();
      expect(lines.single.text, start);
      expect(lines.single.truncated, isTrue);
    });

    test('at most maxConcurrentResolves cut messages are read at once; '
        'the rest keep their prefix without a request', () async {
      final requests = <Completer<ResolvedLogMessage?>>[];
      decoder = VmLogEventDecoder(
        lines.add,
        maxConcurrentResolves: 2,
        resolveTimeout: const Duration(milliseconds: 20),
        resolveMessage: (_, _) {
          final request = Completer<ResolvedLogMessage?>();
          requests.add(request);
          return request.future;
        },
      );
      for (var i = 0; i < 4; i++) {
        decoder.onLogging(cutLog('message $i'));
      }
      expect(requests, hasLength(2));
      expect(decoder.resolvesInFlight, 2);
      // The decoder stops waiting at resolveTimeout, but the requests
      // still count until the app answers them.
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(lines.map((l) => l.text), [
        'message 0',
        'message 1',
        'message 2',
        'message 3',
      ]);
      expect(lines.map((l) => l.truncated), everyElement(isTrue));
      decoder.onLogging(cutLog('message 4'));
      expect(requests, hasLength(2), reason: 'both slots are still taken');

      requests.first.complete(null);
      await pumpEventQueue();
      expect(decoder.resolvesInFlight, 1);
      decoder.onLogging(cutLog('message 5'));
      expect(requests, hasLength(3), reason: 'an answered read frees a slot');
    });

    test('every line carries the decoder epoch', () async {
      final epoch = AppLogEpoch();
      decoder = VmLogEventDecoder(
        lines.add,
        epoch: epoch,
        resolveMessage: (_, _) async => (text: 'whole message', complete: true),
      );
      decoder.onWrite('stdout', _write('printed\n'));
      decoder.onLogging(cutLog('whole'));
      await pumpEventQueue();
      expect(lines, hasLength(2));
      expect(lines.map((l) => l.epoch), everyElement(same(epoch)));
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

    test('drops the lines of an ended epoch and refuses its late lines', () {
      final buffer = AppLogBuffer(capacity: 2);
      final first = AppLogEpoch();
      AppLogLine tagged(String text, AppLogEpoch epoch) => AppLogLine(
        time: DateTime.utc(2026),
        source: 'stdout',
        text: text,
        epoch: epoch,
      );
      for (final text in ['a1', 'a2', 'a3']) {
        buffer.add(tagged(text, first));
      }
      expect(buffer.droppedCount, 1);
      first.end();
      expect(buffer.length, 0);
      expect(buffer.droppedCount, 0);
      buffer.add(tagged('late a', first));
      expect(buffer.length, 0, reason: 'a line of an ended epoch is dropped');
      final second = AppLogEpoch();
      buffer.add(tagged('b1', second));
      expect(buffer.query(maxLines: 10).lines.map((l) => l.text), ['b1']);
    });

    test('daemon lines carry no epoch and stay when an epoch ends', () {
      final buffer = AppLogBuffer();
      final epoch = AppLogEpoch();
      buffer
        ..add(line('from daemon'))
        ..add(
          AppLogLine(
            time: DateTime.utc(2026),
            source: 'stdout',
            text: 'from vm',
            epoch: epoch,
          ),
        );
      epoch.end();
      expect(buffer.query(maxLines: 10).lines.map((l) => l.text), [
        'from daemon',
      ]);
    });

    test('a cut line keeps its epoch', () {
      final epoch = AppLogEpoch();
      final cut = AppLogLine(
        time: DateTime.utc(2026),
        source: 'stdout',
        text: 'abcdefgh',
        epoch: epoch,
      ).capped(4);
      expect(cut.epoch, same(epoch));
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
        // connect returns once the log streams are listened to.
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
