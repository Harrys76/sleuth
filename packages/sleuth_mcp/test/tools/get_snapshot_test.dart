import 'dart:io';

import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:sleuth_mcp/src/tools/tools.dart';
import 'package:test/test.dart';

import '../helpers/fake_vm_bridge.dart';

void main() {
  tearDown(snapshotDiskHandoff.cleanupAll);

  test('no args ⇒ full passthrough, no projection stamp', () async {
    final bridge = defaultFakeBridge();
    await bridge.connect(Uri.parse('ws://localhost/ws'));
    final handler = builtInTools['get_snapshot']!.handler;
    final result = await handler(bridge, {}) as Map<String, Object?>;
    expect(result['sessionUuid'], 'fake-uuid');
    final data = result['data'] as Map<String, Object?>;
    expect(data.containsKey('_projectionApplied'), isFalse);
  });

  test('diskHandoff=true returns a file pointer, not inline data', () async {
    final bridge = defaultFakeBridge();
    await bridge.connect(Uri.parse('ws://localhost/ws'));
    final handler = builtInTools['get_snapshot']!.handler;
    final result =
        await handler(bridge, {'diskHandoff': true}) as Map<String, Object?>;

    expect(result.containsKey('data'), isFalse,
        reason: 'handoff response omits inline data');
    final path = result['path'] as String;
    expect(File(path).existsSync(), isTrue);
    expect(result['sizeBytes'], isA<int>());
    expect(result['sha256'], isA<String>());
  });

  test(
      'diskHandoff stamps _projectionApplied=by_sidecar_fallback when the app '
      'response carries no projection metadata', () async {
    // defaultFakeBridge returns a snapshot WITHOUT _projectedSections —
    // simulates an app that predates projection support (lineage
    // fallback). The sidecar must mark the on-disk payload as
    // sidecar-fallback so its unprojected state is detectable.
    final bridge = defaultFakeBridge();
    await bridge.connect(Uri.parse('ws://localhost/ws'));
    final handler = builtInTools['get_snapshot']!.handler;
    final result = await handler(bridge, {
      'diskHandoff': true,
      'sections': ['currentIssues']
    }) as Map<String, Object?>;
    expect(result['_projectionApplied'], 'by_sidecar_fallback');
  });

  test(
      'INLINE projection against a pre-0.35 app returns '
      'projection_unsupported_by_app (full inline payload would overflow)',
      () async {
    // defaultFakeBridge returns a snapshot WITHOUT _projectedSections.
    // An inline projection request against that (no diskHandoff) must
    // refuse rather than dump the full payload the caller asked to trim.
    final bridge = defaultFakeBridge();
    await bridge.connect(Uri.parse('ws://localhost/ws'));
    final handler = builtInTools['get_snapshot']!.handler;
    final result = await handler(bridge, {
      'sections': ['currentIssues']
    });
    final tc = result as ToolCallResult;
    expect(tc.isError, isTrue);
    expect(tc.content.first['text'] as String,
        startsWith('projection_unsupported_by_app:'));
  });

  test('sections:[] is treated as full payload, NOT a projection request',
      () async {
    // Empty list must not forward an empty `sections` string nor trip the
    // fallback path — it means "full payload" per the documented contract.
    final bridge = defaultFakeBridge();
    await bridge.connect(Uri.parse('ws://localhost/ws'));
    final handler = builtInTools['get_snapshot']!.handler;
    final result =
        await handler(bridge, {'sections': <String>[]}) as Map<String, Object?>;
    final data = result['data'] as Map<String, Object?>;
    expect(data.containsKey('_projectionApplied'), isFalse,
        reason: 'empty sections is a full-payload request, not a projection');
  });

  test('diskHandoff fallback path still writes + stamps by_sidecar_fallback',
      () async {
    final bridge = defaultFakeBridge();
    await bridge.connect(Uri.parse('ws://localhost/ws'));
    final handler = builtInTools['get_snapshot']!.handler;
    final result = await handler(bridge, {
      'diskHandoff': true,
      'sections': ['currentIssues']
    }) as Map<String, Object?>;
    expect(result['_projectionApplied'], 'by_sidecar_fallback');
    expect(result.containsKey('path'), isTrue);
  });

  test(
      'diskHandoff:true with an app ERROR envelope surfaces the error '
      'inline, never a file pointer', () async {
    final bridge = FakeVmBridge(fakeSessionUuid: 'u')
      ..setEnvelope('ext.sleuth.diagnose', {
        'connectionMode': 'basic',
        'schemaVersion': 1,
        'sessionUuid': 'u',
        'data': {'packageVersion': '0.36.0'},
      })
      ..setEnvelope('ext.sleuth.snapshot', {
        'connectionMode': 'basic',
        'schemaVersion': 1,
        'sessionUuid': 'u',
        'error': 'arg_invalid_section: "bogus" is not a known section',
      });
    await bridge.connect(Uri.parse('ws://localhost/ws'));
    final handler = builtInTools['get_snapshot']!.handler;
    final result = await handler(bridge, {
      'diskHandoff': true,
      'sections': ['bogus']
    }) as Map<String, Object?>;
    expect(result.containsKey('error'), isTrue);
    expect(result.containsKey('path'), isFalse,
        reason: 'error envelopes must never be disk-handed-off');
  });
}
