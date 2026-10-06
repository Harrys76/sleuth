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
        await server.handleForTest(
          JsonRpcMessage(
            method: 'initialize',
            id: 0,
            params: const {'protocolVersion': '2024-11-05'},
          ),
        );
        final session = DaemonSession(
          bridge: bridge,
          server: server,
          processFactory:
              (
                _,
                _, {
                String? workingDirectory,
                Map<String, String>? environment,
              }) async => throw StateError('debugUrl path must bypass spawn'),
        );
        server.setDaemonSession(session);

        final resp = await server.handleForTest(
          _toolCall('attach_app', {'debugUrl': 'ws://127.0.0.1:1/tok/ws'}),
        );
        final result = _resultFromResp(resp!.result);
        expect(
          result.isError,
          isTrue,
          reason: 'major skew on attach must surface as isError',
        );
        final text = result.content.first['text'] as String;
        expect(text, contains('version_skew_major'));
        expect(text, contains('0.99.0'));
        // Bridge MUST be torn down — the contract is the sidecar refuses
        // to keep an incompatible connection alive once it has been
        // identified as out-of-lineage.
        expect(
          bridge.isConnected,
          isFalse,
          reason: 'bridge must be detached on refusal',
        );
      },
    );

    test('minor lineage skew on debugUrl path returns ready with the same '
        '`version_skew_minor` warning `connect` returns', () async {
      // Verifies the non-blocking branch: when versionLineage matches
      // (same major.minor) the attach returns the AppStatusPayload plus
      // the advisory warning, as `connect` does.
      final bridge = defaultFakeBridge()
        ..setEnvelope('ext.sleuth.diagnose', {
          'connectionMode': 'basic',
          'schemaVersion': 1,
          'sessionUuid': 'fake-uuid',
          'data': {'packageVersion': '0.37.99'},
        });
      final server = McpServer(bridge: bridge)..registerDefaults();
      await server.handleForTest(
        JsonRpcMessage(
          method: 'initialize',
          id: 0,
          params: const {'protocolVersion': '2024-11-05'},
        ),
      );
      final session = DaemonSession(
        bridge: bridge,
        server: server,
        processFactory:
            (
              _,
              _, {
              String? workingDirectory,
              Map<String, String>? environment,
            }) async => throw StateError('debugUrl path must bypass spawn'),
      );
      server.setDaemonSession(session);

      final resp = await server.handleForTest(
        _toolCall('attach_app', {'debugUrl': 'ws://127.0.0.1:1/tok/ws'}),
      );
      final result = _resultFromResp(resp!.result);
      expect(result.isError, isNot(isTrue));
      final decoded = jsonDecode(result.content.first['text'] as String) as Map;
      expect(decoded['state'], 'ready');
      expect(decoded['warning'], 'version_skew_minor');
      expect(
        bridge.isConnected,
        isTrue,
        reason: 'minor skew must NOT disconnect the bridge',
      );
    });

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
        await server.handleForTest(
          JsonRpcMessage(
            method: 'initialize',
            id: 0,
            params: const {'protocolVersion': '2024-11-05'},
          ),
        );
        final session = DaemonSession(
          bridge: bridge,
          server: server,
          processFactory:
              (
                _,
                _, {
                String? workingDirectory,
                Map<String, String>? environment,
              }) async => throw StateError('debugUrl path must bypass spawn'),
        );
        server.setDaemonSession(session);

        final resp = await server.handleForTest(
          _toolCall('attach_app', {'debugUrl': 'ws://127.0.0.1:1/tok/ws'}),
        );
        final result = _resultFromResp(resp!.result);
        expect(result.isError, isTrue);
        final text = result.content.first['text'] as String;
        expect(text, contains('version_skew_unknown'));
        expect(
          bridge.isConnected,
          isFalse,
          reason: 'bridge must be detached when packageVersion is missing',
        );
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
        await server.handleForTest(
          JsonRpcMessage(
            method: 'initialize',
            id: 0,
            params: const {'protocolVersion': '2024-11-05'},
          ),
        );
        final session = DaemonSession(
          bridge: bridge,
          server: server,
          processFactory:
              (
                _,
                _, {
                String? workingDirectory,
                Map<String, String>? environment,
              }) async => throw StateError('debugUrl path must bypass spawn'),
        );
        server.setDaemonSession(session);

        final resp = await server.handleForTest(
          _toolCall('attach_app', {'debugUrl': 'ws://127.0.0.1:1/tok/ws'}),
        );
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

    test('bridge-layer refusal flowing through daemon catch path surfaces as '
        'isError (defaultVersionSkewValidator wired into bridge)', () async {
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
      await server.handleForTest(
        JsonRpcMessage(
          method: 'initialize',
          id: 0,
          params: const {'protocolVersion': '2024-11-05'},
        ),
      );
      final session = DaemonSession(
        bridge: bridge,
        server: server,
        processFactory:
            (
              _,
              _, {
              String? workingDirectory,
              Map<String, String>? environment,
            }) async => throw StateError('debugUrl path must bypass spawn'),
      );
      server.setDaemonSession(session);

      final resp = await server.handleForTest(
        _toolCall('attach_app', {'debugUrl': 'ws://127.0.0.1:1/tok/ws'}),
      );
      final result = _resultFromResp(resp!.result);
      expect(
        result.isError,
        isTrue,
        reason:
            'bridge-layer refusal wrapped by daemon must reach the '
            'client as isError, not as a silent non-attached status',
      );
      final text = result.content.first['text'] as String;
      expect(text, contains('version_skew_major'));
    });

    test('accepted-prior-lineage skew on debugUrl path returns ready '
        '(transition-window fallback fires from attach path)', () async {
      // `acceptedPriorLineages` lets the sidecar tolerate one prior
      // sleuth minor (mid-upgrade transition window). The attach path
      // must honour the same fallback so a mid-upgrade user can attach
      // via `attach_app` (not just `connect`).
      final bridge = defaultFakeBridge()
        ..setEnvelope('ext.sleuth.diagnose', {
          'connectionMode': 'basic',
          'schemaVersion': 1,
          'sessionUuid': 'fake-uuid',
          'data': {'packageVersion': '0.36.0'},
        });
      final server = McpServer(bridge: bridge)..registerDefaults();
      await server.handleForTest(
        JsonRpcMessage(
          method: 'initialize',
          id: 0,
          params: const {'protocolVersion': '2024-11-05'},
        ),
      );
      final session = DaemonSession(
        bridge: bridge,
        server: server,
        processFactory:
            (
              _,
              _, {
              String? workingDirectory,
              Map<String, String>? environment,
            }) async => throw StateError('debugUrl path must bypass spawn'),
      );
      server.setDaemonSession(session);

      final resp = await server.handleForTest(
        _toolCall('attach_app', {'debugUrl': 'ws://127.0.0.1:1/tok/ws'}),
      );
      final result = _resultFromResp(resp!.result);
      expect(
        result.isError,
        isNot(isTrue),
        reason: 'accepted-prior lineage must NOT trip the refusal path',
      );
      expect(bridge.isConnected, isTrue);
      final decoded = jsonDecode(result.content.first['text'] as String) as Map;
      expect(
        decoded['warning'],
        'version_skew_prior_lineage',
        reason:
            'attach_app must surface the same prior-lineage warning '
            '`connect` returns',
      );
    });

    test('exact pin match on debugUrl path carries no warning', () async {
      final (result, _) = await _attachWithVersion(sleuthPackageVersionPin);
      expect(result.isError, isNot(isTrue));
      final decoded = jsonDecode(result.content.first['text'] as String) as Map;
      expect(decoded['state'], 'ready');
      expect(decoded.containsKey('warning'), isFalse);
    });

    for (final (version, code) in <(String, String)>[
      ('0.35.9', 'version_skew_major'),
      ('0.38.0', 'version_skew_major'),
      ('0.37.garbage', 'version_skew_unknown'),
      ('0.36', 'version_skew_unknown'),
    ]) {
      test(
        'packageVersion $version is refused with $code and detaches',
        () async {
          final (result, bridge) = await _attachWithVersion(version);
          expect(result.isError, isTrue);
          expect(result.content.first['text'] as String, startsWith(code));
          expect(bridge.isConnected, isFalse);
        },
      );
    }
  });
}

/// Attach over the debugUrl path to an app whose diagnose envelope reports
/// [packageVersion]; returns the tool result and the bridge.
Future<(ToolCallResult, FakeVmBridge)> _attachWithVersion(
  String packageVersion,
) async {
  final bridge = defaultFakeBridge()
    ..setEnvelope('ext.sleuth.diagnose', {
      'connectionMode': 'full',
      'schemaVersion': 1,
      'sessionUuid': 'fake-uuid',
      'data': {'packageVersion': packageVersion, 'vmConnected': true},
    });
  final server = McpServer(bridge: bridge)..registerDefaults();
  await server.handleForTest(
    JsonRpcMessage(
      method: 'initialize',
      id: 0,
      params: const {'protocolVersion': '2024-11-05'},
    ),
  );
  server.setDaemonSession(
    DaemonSession(
      bridge: bridge,
      server: server,
      processFactory:
          (
            _,
            _, {
            String? workingDirectory,
            Map<String, String>? environment,
          }) async => throw StateError('debugUrl path must bypass spawn'),
    ),
  );
  final resp = await server.handleForTest(
    _toolCall('attach_app', {'debugUrl': 'ws://127.0.0.1:1/tok/ws'}),
  );
  return (_resultFromResp(resp!.result), bridge);
}
