import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:sleuth_mcp/src/tools/tools.dart';
import 'package:test/test.dart';

import '../helpers/fake_vm_bridge.dart';

void main() {
  test('connect tool returns connected + sessionUuid', () async {
    final bridge = defaultFakeBridge();
    final handler = builtInTools['connect']!.handler;
    final result = await handler(bridge, {'uri': 'ws://localhost/ws'});
    final map = result as Map<String, Object?>;
    expect(map['connected'], true);
    expect(map['sessionUuid'], 'fake-uuid');
    expect(map['sidecarVersion'], sleuthMcpVersion);
    // matching version → no warning
    expect(map.containsKey('warning'), isFalse);
  });

  test('connect tool flags minor version skew on same-lineage patch drift',
      () async {
    // Same major.minor (0.33) as the sidecar pin, differing patch.
    // Wire contract holds — surface `version_skew_minor` advisory.
    final bridge = FakeVmBridge(fakeSessionUuid: 'uuid')
      ..setEnvelope('ext.sleuth.diagnose', {
        'connectionMode': 'basic',
        'schemaVersion': 1,
        'sessionUuid': 'uuid',
        'data': {'packageVersion': '0.33.99'},
      });
    final handler = builtInTools['connect']!.handler;
    final result = await handler(bridge, {'uri': 'ws://localhost/ws'});
    final map = result as Map<String, Object?>;
    expect(map['warning'], 'version_skew_minor');
  });

  test('connect tool refuses to serve on major version skew', () async {
    final bridge = FakeVmBridge(fakeSessionUuid: 'uuid')
      ..setEnvelope('ext.sleuth.diagnose', {
        'connectionMode': 'basic',
        'schemaVersion': 1,
        'sessionUuid': 'uuid',
        'data': {'packageVersion': '0.99.0'},
      });
    final handler = builtInTools['connect']!.handler;
    final result = await handler(bridge, {'uri': 'ws://localhost/ws'});
    expect(result, isA<ToolCallResult>());
    final tc = result as ToolCallResult;
    expect(tc.isError, isTrue);
    final text = tc.content.first['text'] as String;
    expect(text, contains('version_skew_major'));
    expect(text, contains('0.99.0'));
    // Bridge must be disconnected so subsequent tools can't keep hitting
    // an incompatible app.
    expect(bridge.isConnected, isFalse);
  });

  test('connect tool returns isError on missing uri', () async {
    final bridge = defaultFakeBridge();
    final handler = builtInTools['connect']!.handler;
    final result = await handler(bridge, {});
    expect(result, isA<ToolCallResult>());
    expect((result as ToolCallResult).isError, isTrue);
  });

  test('connect tool fails closed when packageVersion absent', () async {
    // Empty data — no packageVersion stamp at all. The sidecar cannot
    // prove the envelope shape; refuse rather than risk parsing a
    // contract-violating response.
    final bridge = FakeVmBridge(fakeSessionUuid: 'uuid')
      ..setEnvelope('ext.sleuth.diagnose', {
        'connectionMode': 'basic',
        'schemaVersion': 1,
        'sessionUuid': 'uuid',
        'data': const <String, Object?>{},
      });
    final handler = builtInTools['connect']!.handler;
    final result = await handler(bridge, {'uri': 'ws://localhost/ws'});
    expect(result, isA<ToolCallResult>());
    final tc = result as ToolCallResult;
    expect(tc.isError, isTrue);
    final text = tc.content.first['text'] as String;
    expect(text, contains('version_skew_unknown'));
    expect(bridge.isConnected, isFalse,
        reason: 'bridge must be torn down when version cannot be verified');
  });

  test('connect tool fails closed when packageVersion is non-String', () async {
    // Contract types packageVersion as `String`. An int/bool here means
    // the producer is malformed; we cannot trust any other field.
    final bridge = FakeVmBridge(fakeSessionUuid: 'uuid')
      ..setEnvelope('ext.sleuth.diagnose', {
        'connectionMode': 'basic',
        'schemaVersion': 1,
        'sessionUuid': 'uuid',
        'data': {'packageVersion': 42},
      });
    final handler = builtInTools['connect']!.handler;
    final result = await handler(bridge, {'uri': 'ws://localhost/ws'});
    expect(result, isA<ToolCallResult>());
    final tc = result as ToolCallResult;
    expect(tc.isError, isTrue);
    expect(tc.content.first['text'], contains('version_skew_unknown'));
    expect(bridge.isConnected, isFalse);
  });

  test('connect tool stamps version_skew_prior_lineage on accepted-prior drift',
      () async {
    // `acceptedPriorLineages` (v0.32) — the connection is allowed but
    // the warning string distinguishes "patch drift on the same
    // lineage" from "transition-window cross-lineage tolerance".
    final bridge = FakeVmBridge(fakeSessionUuid: 'uuid')
      ..setEnvelope('ext.sleuth.diagnose', {
        'connectionMode': 'basic',
        'schemaVersion': 1,
        'sessionUuid': 'uuid',
        'data': {'packageVersion': '0.32.0'},
      });
    final handler = builtInTools['connect']!.handler;
    final result = await handler(bridge, {'uri': 'ws://localhost/ws'});
    final map = result as Map<String, Object?>;
    expect(map['warning'], 'version_skew_prior_lineage',
        reason: 'cross-lineage tolerance must surface its own warning string');
    expect(bridge.isConnected, isTrue);
  });
}
