import 'dart:convert';

import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:sleuth_mcp/src/tools/tools.dart';
import 'package:test/test.dart';

Future<ToolCallResult> _runAttach(Map<String, Object?> args) async {
  final bridge = FakeVmBridge(fakeSessionUuid: 'u');
  final server = McpServer(bridge: bridge)..registerDefaults();
  final session = DaemonSession(
    bridge: bridge,
    server: server,
    processFactory: (String exe, List<String> args,
            {String? workingDirectory,
            Map<String, String>? environment}) async =>
        throw StateError('test path must not spawn flutter daemon'),
  );
  server.setDaemonSession(session);
  final tools = lifecycleTools(server);
  final attach = tools['attach_app']!.handler;
  final result = await attach(bridge, args);
  return result as ToolCallResult;
}

Map<String, Object?> _parseStructured(ToolCallResult r) =>
    jsonDecode(r.content[1]['text'] as String) as Map<String, Object?>;

void main() {
  group('attach_app iOS routing — typed errors', () {
    test('missing bundle → ios_missing_bundle envelope', () async {
      final result = await _runAttach(const {'udid': 'ABC123'});
      expect(result.isError, isTrue);
      expect(result.content.first['text'], contains('ios_missing_bundle'));
      expect(_parseStructured(result)['error'], 'ios_missing_bundle');
    });

    test('udid + device → ios_ambiguous_args envelope', () async {
      final result = await _runAttach(const {
        'udid': 'ABC123',
        'device': 'Pengen',
        'bundle': 'com.example.app',
      });
      expect(result.isError, isTrue);
      expect(_parseStructured(result)['error'], 'ios_ambiguous_args');
    });

    test('udid + debugUrl → ios_ambiguous_args envelope', () async {
      final result = await _runAttach(const {
        'udid': 'ABC123',
        'debugUrl': 'ws://127.0.0.1:1/tok/ws',
        'bundle': 'com.example.app',
      });
      expect(result.isError, isTrue);
      expect(_parseStructured(result)['error'], 'ios_ambiguous_args');
    });

    test('invalid transport value → ios_invalid_transport', () async {
      final result = await _runAttach(const {
        'udid': 'ABC123',
        'bundle': 'com.example.app',
        'transport': 'wifi',
      });
      expect(result.isError, isTrue);
      final structured = _parseStructured(result);
      expect(structured['error'], 'ios_invalid_transport');
      expect(structured['allowed'], contains('wireless'));
    });
  });
}
