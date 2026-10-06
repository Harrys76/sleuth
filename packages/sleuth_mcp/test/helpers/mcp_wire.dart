import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sleuth_mcp/sleuth_mcp.dart';

/// [IOSink] that keeps every line written to it, decoded as JSON: a map
/// for one message, a list for the responses to a batch.
class JsonLineSink implements IOSink {
  final List<Object?> frames = [];
  String _partial = '';

  @override
  Encoding encoding = utf8;

  @override
  void write(Object? obj) {
    final parts = (_partial + obj.toString()).split('\n');
    _partial = parts.removeLast();
    for (final line in parts) {
      if (line.trim().isEmpty) continue;
      frames.add(jsonDecode(line));
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
  Future<void> get done => Future<void>.value();
}

/// An [McpServer] driven through [McpServer.serve] over in-memory pipes.
class McpWire {
  McpWire(this.server, {IOSink? output}) : output = output ?? JsonLineSink() {
    served = server.serve(input: _input.stream, output: this.output);
  }

  final McpServer server;
  final IOSink output;
  final StreamController<List<int>> _input = StreamController<List<int>>();
  late final Future<void> served;

  List<Object?> get frames =>
      output is JsonLineSink ? (output as JsonLineSink).frames : const [];

  void sendLine(String line) => _input.add(utf8.encode('$line\n'));

  void send(Map<String, Object?> message) =>
      sendLine(jsonEncode({'jsonrpc': '2.0', ...message}));

  void initialize(String protocolVersion, {Object id = 0}) => send({
    'method': 'initialize',
    'params': {'protocolVersion': protocolVersion},
    'id': id,
  });

  void call(
    Object? id,
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
    'id': ?id,
  });

  void ping(Object id) => send({'method': 'ping', 'id': id});

  void cancel(Object requestId) => send({
    'method': 'notifications/cancelled',
    'params': {'requestId': requestId},
  });

  Map<String, Object?>? _find(Object id) {
    for (final frame in frames) {
      if (frame is Map<String, Object?> &&
          frame['id'] == id &&
          !frame.containsKey('method')) {
        return frame;
      }
    }
    return null;
  }

  bool hasResponse(Object id) => _find(id) != null;

  /// Waits until the response to [id] arrives and returns it.
  Future<Map<String, Object?>> response(
    Object id, {
    Duration within = const Duration(seconds: 5),
  }) async {
    final watch = Stopwatch()..start();
    while (watch.elapsed < within) {
      final found = _find(id);
      if (found != null) return found;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    throw TimeoutException('no response for id $id within $within');
  }

  /// Closes stdin and waits for [McpServer.serve] to return.
  Future<void> close({Duration within = const Duration(seconds: 5)}) async {
    await _input.close();
    await served.timeout(within);
  }
}

/// The text of the first content block of a `tools/call` response.
String toolText(Map<String, Object?> response) =>
    (((response['result'] as Map)['content'] as List).first as Map)['text']
        as String;
