import 'dart:convert';

import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:test/test.dart';

import '../helpers/fake_vm_bridge.dart';

JsonRpcMessage _toolCall(String name, Map<String, Object?> args, {int id = 1}) {
  return JsonRpcMessage(
    method: 'tools/call',
    params: {'name': name, 'arguments': args},
    id: id,
  );
}

ToolCallResult _resultFromResp(Object? result) {
  final map = result as Map<String, Object?>;
  return ToolCallResult(
    content: (map['content'] as List).cast<Map<String, Object?>>(),
    isError: map['isError'] == true,
  );
}

void main() {
  // The attach_app handler ultimately rides the same bridge.connect() path
  // as the `connect` tool — but until v0.33.0 only the `connect` tool ran
  // _enforceVersionSkew. Daemon-spawn AND debugUrl attach paths would happily
  // attach to a sleuth lineage outside acceptedPriorLineages. These tests
  // exercise the now-shared enforcement at the attachHandler chokepoint.

  group('attach_app version-skew enforcement', () {
    test(
      'major lineage skew on debugUrl path returns refusal + detaches',
      () async {
        final bridge = defaultFakeBridge()
          ..setEnvelope('ext.sleuth.diagnose', {
            'connectionMode': 'basic',
            'schemaVersion': 1,
            'sessionUuid': 'fake-uuid',
            'data': {'packageVersion': '0.99.0'},
          });
        final server = McpServer(bridge: bridge)..registerDefaults();
        await server.handleForTest(JsonRpcMessage(
          method: 'initialize',
          id: 0,
          params: const {'protocolVersion': '2024-11-05'},
        ));
        final session = DaemonSession(
          bridge: bridge,
          server: server,
          processFactory: (_, __,
                  {String? workingDirectory,
                  Map<String, String>? environment}) async =>
              throw StateError('debugUrl path must bypass spawn'),
        );
        server.setDaemonSession(session);

        final resp = await server.handleForTest(_toolCall(
          'attach_app',
          {'debugUrl': 'ws://127.0.0.1:1/tok/ws'},
        ));
        final result = _resultFromResp(resp!.result);
        expect(result.isError, isTrue,
            reason: 'major skew on attach must surface as isError');
        final text = result.content.first['text'] as String;
        expect(text, contains('version_skew_major'));
        expect(text, contains('0.99.0'));
        // Bridge MUST be torn down — the contract is the sidecar refuses
        // to keep an incompatible connection alive once it has been
        // identified as out-of-lineage.
        expect(bridge.isConnected, isFalse,
            reason: 'bridge must be detached on refusal');
      },
    );

    test(
      'minor lineage skew on debugUrl path returns ready (warning carries '
      'through downstream `connect` call shape, not through attach payload)',
      () async {
        // Verifies the non-blocking branch: when versionLineage matches
        // (same major.minor) the attach still returns the AppStatusPayload
        // verbatim. Warning surfacing is the `connect` tool's concern —
        // attach_app's contract is only "is this app speakable?".
        final bridge = defaultFakeBridge()
          ..setEnvelope('ext.sleuth.diagnose', {
            'connectionMode': 'basic',
            'schemaVersion': 1,
            'sessionUuid': 'fake-uuid',
            'data': {'packageVersion': '0.33.99'},
          });
        final server = McpServer(bridge: bridge)..registerDefaults();
        await server.handleForTest(JsonRpcMessage(
          method: 'initialize',
          id: 0,
          params: const {'protocolVersion': '2024-11-05'},
        ));
        final session = DaemonSession(
          bridge: bridge,
          server: server,
          processFactory: (_, __,
                  {String? workingDirectory,
                  Map<String, String>? environment}) async =>
              throw StateError('debugUrl path must bypass spawn'),
        );
        server.setDaemonSession(session);

        final resp = await server.handleForTest(_toolCall(
          'attach_app',
          {'debugUrl': 'ws://127.0.0.1:1/tok/ws'},
        ));
        final result = _resultFromResp(resp!.result);
        expect(result.isError, isNot(isTrue));
        final decoded =
            jsonDecode(result.content.first['text'] as String) as Map;
        expect(decoded['state'], 'ready');
        expect(bridge.isConnected, isTrue,
            reason: 'minor skew must NOT disconnect the bridge');
      },
    );

    test(
      'null packageVersion on diagnose envelope fails closed at attachHandler',
      () async {
        // Fail-closed: an envelope without a verifiable packageVersion
        // could come from a corrupt/legacy build that doesn't speak the
        // documented wire shape. Treat as refusal.
        final bridge = defaultFakeBridge()
          ..setEnvelope('ext.sleuth.diagnose', {
            'connectionMode': 'basic',
            'schemaVersion': 1,
            'sessionUuid': 'fake-uuid',
            'data': const <String, Object?>{},
          });
        final server = McpServer(bridge: bridge)..registerDefaults();
        await server.handleForTest(JsonRpcMessage(
          method: 'initialize',
          id: 0,
          params: const {'protocolVersion': '2024-11-05'},
        ));
        final session = DaemonSession(
          bridge: bridge,
          server: server,
          processFactory: (_, __,
                  {String? workingDirectory,
                  Map<String, String>? environment}) async =>
              throw StateError('debugUrl path must bypass spawn'),
        );
        server.setDaemonSession(session);

        final resp = await server.handleForTest(_toolCall(
          'attach_app',
          {'debugUrl': 'ws://127.0.0.1:1/tok/ws'},
        ));
        final result = _resultFromResp(resp!.result);
        expect(result.isError, isTrue);
        final text = result.content.first['text'] as String;
        expect(text, contains('version_skew_unknown'));
        expect(bridge.isConnected, isFalse,
            reason: 'bridge must be detached when packageVersion is missing');
      },
    );

    test(
      'non-String packageVersion on diagnose envelope fails closed',
      () async {
        // The wire contract types packageVersion as `String`. Any other
        // type (int, bool, null) drops into the fail-closed branch — we
        // cannot prove the app speaks the documented contract.
        final bridge = defaultFakeBridge()
          ..setEnvelope('ext.sleuth.diagnose', {
            'connectionMode': 'basic',
            'schemaVersion': 1,
            'sessionUuid': 'fake-uuid',
            'data': {'packageVersion': 42},
          });
        final server = McpServer(bridge: bridge)..registerDefaults();
        await server.handleForTest(JsonRpcMessage(
          method: 'initialize',
          id: 0,
          params: const {'protocolVersion': '2024-11-05'},
        ));
        final session = DaemonSession(
          bridge: bridge,
          server: server,
          processFactory: (_, __,
                  {String? workingDirectory,
                  Map<String, String>? environment}) async =>
              throw StateError('debugUrl path must bypass spawn'),
        );
        server.setDaemonSession(session);

        final resp = await server.handleForTest(_toolCall(
          'attach_app',
          {'debugUrl': 'ws://127.0.0.1:1/tok/ws'},
        ));
        final result = _resultFromResp(resp!.result);
        expect(result.isError, isTrue);
        final text = result.content.first['text'] as String;
        expect(text, contains('version_skew_unknown'));
        expect(bridge.isConnected, isFalse);
      },
    );

    // Daemon-spawn path note: `attachHandler` is the single chokepoint
    // for both `device:` (spawn) and `debugUrl:` paths — once attach
    // reaches `state: ready` either way, the same `_enforceVersionSkew`
    // call runs against `bridge.lastDiagnoseEnvelope`. Driving the spawn
    // path here would require a full daemon-protocol process fake;
    // since the refusal arm shares the same code path that debugUrl
    // exercises above, an explicit daemon-spawn test is omitted as
    // structurally redundant.

    test(
      'bridge-layer refusal flowing through daemon catch path surfaces as '
      'isError (defaultVersionSkewValidator wired into bridge)',
      () async {
        // When the bridge has `defaultVersionSkewValidator` wired,
        // `bridge.connect()` throws `VmBridgeException('version_skew_…')`.
        // `DaemonSession.attach()` catches it and stamps the error into
        // `status.lastError` as `'bridge connect failed: version_skew_…'`,
        // returning a non-attached status. `attachHandler` must detect
        // the wrapped substring and return `ToolCallResult(isError: true)`
        // rather than the silent `status.toJson()` payload.
        final bridge = FakeVmBridge(
          fakeSessionUuid: 'fake-uuid',
          envelopes: {
            'ext.sleuth.diagnose': {
              'connectionMode': 'basic',
              'schemaVersion': 1,
              'sessionUuid': 'fake-uuid',
              'data': {'packageVersion': '0.99.0'},
            },
          },
          versionSkewValidator: defaultVersionSkewValidator,
        );
        final server = McpServer(bridge: bridge)..registerDefaults();
        await server.handleForTest(JsonRpcMessage(
          method: 'initialize',
          id: 0,
          params: const {'protocolVersion': '2024-11-05'},
        ));
        final session = DaemonSession(
          bridge: bridge,
          server: server,
          processFactory: (_, __,
                  {String? workingDirectory,
                  Map<String, String>? environment}) async =>
              throw StateError('debugUrl path must bypass spawn'),
        );
        server.setDaemonSession(session);

        final resp = await server.handleForTest(_toolCall(
          'attach_app',
          {'debugUrl': 'ws://127.0.0.1:1/tok/ws'},
        ));
        final result = _resultFromResp(resp!.result);
        expect(result.isError, isTrue,
            reason: 'bridge-layer refusal wrapped by daemon must reach the '
                'client as isError, not as a silent non-attached status');
        final text = result.content.first['text'] as String;
        expect(text, contains('version_skew_major'));
      },
    );

    test(
      'accepted-prior-lineage skew on debugUrl path returns ready '
      '(transition-window fallback fires from attach path)',
      () async {
        // `acceptedPriorLineages` lets the sidecar tolerate one prior
        // sleuth minor — e.g. v0.3.0 sidecar attached to v0.32.x app.
        // The attach path must honour the same fallback so a mid-upgrade
        // user can attach via `attach_app` (not just `connect`).
        final bridge = defaultFakeBridge()
          ..setEnvelope('ext.sleuth.diagnose', {
            'connectionMode': 'basic',
            'schemaVersion': 1,
            'sessionUuid': 'fake-uuid',
            'data': {'packageVersion': '0.32.0'},
          });
        final server = McpServer(bridge: bridge)..registerDefaults();
        await server.handleForTest(JsonRpcMessage(
          method: 'initialize',
          id: 0,
          params: const {'protocolVersion': '2024-11-05'},
        ));
        final session = DaemonSession(
          bridge: bridge,
          server: server,
          processFactory: (_, __,
                  {String? workingDirectory,
                  Map<String, String>? environment}) async =>
              throw StateError('debugUrl path must bypass spawn'),
        );
        server.setDaemonSession(session);

        final resp = await server.handleForTest(_toolCall(
          'attach_app',
          {'debugUrl': 'ws://127.0.0.1:1/tok/ws'},
        ));
        final result = _resultFromResp(resp!.result);
        expect(result.isError, isNot(isTrue),
            reason: 'accepted-prior lineage must NOT trip the refusal path');
        expect(bridge.isConnected, isTrue);
      },
    );
  });
}
