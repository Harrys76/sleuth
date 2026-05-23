import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:test/test.dart';

class _CapturingSink implements IOSink {
  final List<int> _bytes = [];
  bool _closed = false;
  bool failFlush = false;

  @override
  Encoding encoding = utf8;

  String get content => utf8.decode(_bytes);
  List<String> get frames =>
      content.split('\n').where((s) => s.isNotEmpty).toList();

  @override
  void add(List<int> data) {
    if (_closed) throw StateError('sink closed');
    _bytes.addAll(data);
  }

  @override
  void write(Object? obj) => add(utf8.encode(obj.toString()));
  @override
  void writeln([Object? obj = '']) => write('$obj\n');
  @override
  void writeAll(Iterable<dynamic> objs, [String sep = '']) =>
      write(objs.join(sep));
  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));

  @override
  void addError(Object error, [StackTrace? st]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      add(chunk);
    }
  }

  @override
  Future<void> flush() async {
    if (failFlush) {
      throw const SocketException('flush blocked');
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
  }

  @override
  Future<void> get done => Future.value();
}

class _ListLogSink implements Sink<String> {
  final List<String> lines = [];
  bool _closed = false;
  @override
  void add(String data) {
    if (_closed) return;
    lines.add(data);
  }

  @override
  void close() {
    _closed = true;
  }
}

void main() {
  group('DaemonRpc.call', () {
    test('writes single-element-array envelope with monotonic ids', () async {
      final stdin = _CapturingSink();
      final responses = StreamController<DaemonRpcResponse>();
      final rpc = DaemonRpc(stdin: stdin, responses: responses.stream);

      final pending1 = rpc.call('app.reload', const {'appId': 'A'});
      final pending2 = rpc.call('app.restart', const {'appId': 'A'});

      // Give the writes a microtask to land.
      await Future<void>.delayed(Duration.zero);

      expect(stdin.frames, hasLength(2));
      final first = jsonDecode(stdin.frames[0]) as List;
      final second = jsonDecode(stdin.frames[1]) as List;
      expect((first.first as Map)['id'], 1);
      expect((first.first as Map)['method'], 'app.reload');
      expect((second.first as Map)['id'], 2);
      expect((second.first as Map)['method'], 'app.restart');

      responses.add(const DaemonRpcResponse(id: 1, result: {'code': 0}));
      responses.add(const DaemonRpcResponse(id: 2, result: {'code': 0}));
      final r1 = await pending1;
      final r2 = await pending2;
      expect(r1.id, 1);
      expect(r2.id, 2);

      await rpc.close();
      await responses.close();
    });

    test('correlates responses by id even when arriving out of order',
        () async {
      final stdin = _CapturingSink();
      final responses = StreamController<DaemonRpcResponse>();
      final rpc = DaemonRpc(stdin: stdin, responses: responses.stream);

      final f1 = rpc.call('app.reload', const {});
      final f2 = rpc.call('app.restart', const {});

      // Reply to id=2 first.
      responses.add(const DaemonRpcResponse(id: 2, result: 'restart-ok'));
      responses.add(const DaemonRpcResponse(id: 1, result: 'reload-ok'));

      final r1 = await f1;
      final r2 = await f2;
      expect(r1.result, 'reload-ok');
      expect(r2.result, 'restart-ok');

      await rpc.close();
      await responses.close();
    });

    test('out-of-band response is dropped + logged', () async {
      final stdin = _CapturingSink();
      final responses = StreamController<DaemonRpcResponse>();
      final logger = _ListLogSink();
      final rpc = DaemonRpc(
        stdin: stdin,
        responses: responses.stream,
        logger: logger,
      );

      responses.add(const DaemonRpcResponse(id: 999, result: 'orphan'));
      await Future<void>.delayed(Duration.zero);

      expect(logger.lines, hasLength(1));
      expect(logger.lines.single, contains('id=999'));

      await rpc.close();
      await responses.close();
    });

    test('per-call timeout throws DaemonRpcTimeoutException', () async {
      final stdin = _CapturingSink();
      final responses = StreamController<DaemonRpcResponse>();
      final rpc = DaemonRpc(stdin: stdin, responses: responses.stream);

      expect(
        rpc.call('app.reload', const {},
            timeout: const Duration(milliseconds: 50)),
        throwsA(isA<DaemonRpcTimeoutException>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await rpc.close();
      await responses.close();
    });

    test('write failure throws DaemonRpcException', () async {
      final stdin = _CapturingSink()..failFlush = true;
      final responses = StreamController<DaemonRpcResponse>();
      final rpc = DaemonRpc(stdin: stdin, responses: responses.stream);

      expect(
        rpc.call('app.reload', const {}),
        throwsA(isA<DaemonRpcException>()),
      );
      await Future<void>.delayed(Duration.zero);

      await rpc.close();
      await responses.close();
    });

    test('close fails any pending in-flight calls', () async {
      final stdin = _CapturingSink();
      final responses = StreamController<DaemonRpcResponse>();
      final rpc = DaemonRpc(stdin: stdin, responses: responses.stream);

      final pending = rpc.call('app.reload', const {});
      await Future<void>.delayed(Duration.zero);
      await rpc.close();
      expect(pending, throwsA(isA<DaemonRpcException>()));
      await responses.close();
    });
  });
}
