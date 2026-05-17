import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:test/test.dart';

void main() {
  group('DaemonParser', () {
    test('replays captured fixture without crashing', () async {
      final file = File(
        'test/fixtures/daemon_attach_flutter_3_41_4_ios.ndjson',
      );
      expect(file.existsSync(), isTrue,
          reason: 'fixture missing; see test/fixtures/README.md');
      final parser = DaemonParser();
      final events = await parser.parse(file.openRead()).toList();
      expect(events, isNotEmpty);
      // Expect at least one of each load-bearing event type.
      expect(events.whereType<DaemonConnectedEvent>(), isNotEmpty);
      expect(events.whereType<AppStartEvent>(), isNotEmpty);
      expect(events.whereType<AppDebugPortEvent>(), isNotEmpty);
      expect(events.whereType<AppStartedEvent>(), isNotEmpty);
      expect(events.whereType<AppStopEvent>(), isNotEmpty);
      expect(events.whereType<DaemonRpcResponse>(), isNotEmpty);
    });

    test('extracts wsUri from app.debugPort', () async {
      final parser = DaemonParser();
      final stream = _stringStream([
        '[{"event":"app.debugPort","params":{"appId":"abc","port":12345,"wsUri":"ws://127.0.0.1:12345/tok=/ws"}}]\n',
      ]);
      final events = await parser.parse(stream).toList();
      expect(events, hasLength(1));
      final debugPort = events.single as AppDebugPortEvent;
      expect(debugPort.wsUri, 'ws://127.0.0.1:12345/tok=/ws');
      expect(debugPort.port, 12345);
      expect(debugPort.appId, 'abc');
    });

    test('drops non-event banner lines silently', () async {
      final parser = DaemonParser();
      final stream = _stringStream([
        'Waiting for a connection from Flutter on iPhone 12...\n',
        '[{"event":"daemon.connected","params":{"version":"0.6.1","pid":1}}]\n',
        'Some random banner\n',
      ]);
      final events = await parser.parse(stream).toList();
      expect(events, hasLength(1));
      expect(events.single, isA<DaemonConnectedEvent>());
    });

    test('drops malformed JSON silently', () async {
      final parser = DaemonParser();
      final stream = _stringStream([
        '[{not-json}]\n',
        '[{"event":"app.started","params":{"appId":"abc"}}]\n',
      ]);
      final events = await parser.parse(stream).toList();
      expect(events, hasLength(1));
      expect(events.single, isA<AppStartedEvent>());
    });

    test('unknown event name surfaces as UnknownDaemonEvent', () async {
      final parser = DaemonParser();
      final stream = _stringStream([
        '[{"event":"some.future.event","params":{"foo":"bar"}}]\n',
      ]);
      final events = await parser.parse(stream).toList();
      expect(events.single, isA<UnknownDaemonEvent>());
      final unk = events.single as UnknownDaemonEvent;
      expect(unk.eventName, 'some.future.event');
      expect(unk.params['foo'], 'bar');
    });

    test('rpc response with id + result yields DaemonRpcResponse', () async {
      final parser = DaemonParser();
      final stream = _stringStream([
        '[{"id":42,"result":{"code":0,"message":"ok"}}]\n',
      ]);
      final events = await parser.parse(stream).toList();
      expect(events.single, isA<DaemonRpcResponse>());
      final rpc = events.single as DaemonRpcResponse;
      expect(rpc.id, 42);
      expect(rpc.isError, isFalse);
    });

    test('rpc response with id + error yields DaemonRpcResponse.isError',
        () async {
      final parser = DaemonParser();
      final stream = _stringStream([
        '[{"id":7,"error":{"code":1,"message":"bad"}}]\n',
      ]);
      final events = await parser.parse(stream).toList();
      final rpc = events.single as DaemonRpcResponse;
      expect(rpc.isError, isTrue);
      expect((rpc.error)?['message'], 'bad');
    });

    test('iterates multi-element arrays — no silent batch drop', () async {
      final parser = DaemonParser();
      final stream = _stringStream([
        '[{"event":"daemon.connected","params":{"version":"0.6.1","pid":1}},'
            '{"event":"app.started","params":{"appId":"A"}}]\n',
      ]);
      final events = await parser.parse(stream).toList();
      expect(events, hasLength(2));
      expect(events[0], isA<DaemonConnectedEvent>());
      expect(events[1], isA<AppStartedEvent>());
    });
  });

  group('isAtLeastVersion', () {
    test('matches and exceeds minimum', () {
      expect(isAtLeastVersion('0.6.0', '0.6.0'), isTrue);
      expect(isAtLeastVersion('0.6.1', '0.6.0'), isTrue);
      expect(isAtLeastVersion('1.0.0', '0.6.0'), isTrue);
      expect(isAtLeastVersion('0.5.99', '0.6.0'), isFalse);
      expect(isAtLeastVersion('0.5', '0.6.0'), isFalse);
    });
  });
}

Stream<List<int>> _stringStream(List<String> chunks) async* {
  for (final chunk in chunks) {
    yield utf8.encode(chunk);
  }
}
