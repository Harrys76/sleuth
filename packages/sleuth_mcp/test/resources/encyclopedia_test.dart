import 'dart:async';

import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:sleuth_mcp/src/resources/encyclopedia.dart';
import 'package:test/test.dart';

import '../helpers/fake_vm_bridge.dart';

void main() {
  test('encyclopedia caches and serves cached on second read', () async {
    final bridge = defaultFakeBridge();
    await bridge.connect(Uri.parse('ws://localhost/ws'));
    final res = EncyclopediaResource(bridge: bridge);
    final first = await res.read();
    final second = await res.read();
    expect(identical(first, second), isTrue);
  });

  test('encyclopedia refetches when sessionUuid changes', () async {
    final bridge = defaultFakeBridge();
    await bridge.connect(Uri.parse('ws://localhost/ws'));
    final res = EncyclopediaResource(bridge: bridge);
    final first = await res.read();
    expect(first['sessionUuid'], 'fake-uuid');

    // Replace canned envelope with a new sessionUuid + simulated drift.
    bridge.setEnvelope('ext.sleuth.encyclopedia', {
      'connectionMode': 'basic',
      'schemaVersion': 1,
      'sessionUuid': 'new-uuid',
      'data': {'count': 0, 'entries': <String, Object?>{}},
    });
    bridge.simulateSessionChange('new-uuid');
    await expectLater(res.read(), throwsA(isA<SessionChangedException>()));
  });

  test('invalidate during in-flight read discards the stale post-await write',
      () async {
    final completer = Completer<Map<String, Object?>>();
    final bridge = _DelayedBridge(completer);
    final res = EncyclopediaResource(bridge: bridge);

    final readFuture = res.read();
    await Future<void>.delayed(Duration.zero);
    res.invalidate();
    completer.complete({
      'connectionMode': 'basic',
      'sessionUuid': 'stale-uuid',
      'data': {'count': 1, 'entries': <String, Object?>{}},
    });
    final result = await readFuture;
    expect(result['sessionUuid'], 'stale-uuid');

    // Cache empty after invalidate → next read re-fetches.
    bridge.next = {
      'connectionMode': 'basic',
      'sessionUuid': 'fresh-uuid',
      'data': {'count': 2, 'entries': <String, Object?>{}},
    };
    final second = await res.read();
    expect(second['sessionUuid'], 'fresh-uuid');
  });
}

class _DelayedBridge implements VmBridge {
  _DelayedBridge(this._firstCall);

  final Completer<Map<String, Object?>> _firstCall;
  bool _consumed = false;
  Map<String, Object?>? next;

  @override
  String? get baselineSessionUuid => 'baseline-uuid';

  @override
  Map<String, Object?>? get lastDiagnoseEnvelope => null;

  @override
  bool get isConnected => true;

  @override
  int get baselineGeneration => 0;

  @override
  Future<void> refreshBaseline({bool acceptSessionRotation = false}) async {}

  @override
  Future<bool> connect(Uri wsUri) async => true;

  @override
  Future<Map<String, Object?>> callExtension(
    String method, {
    Map<String, dynamic> args = const <String, dynamic>{},
  }) async {
    if (!_consumed) {
      _consumed = true;
      return _firstCall.future;
    }
    final n = next;
    if (n == null) {
      throw VmBridgeException('no canned next envelope');
    }
    return n;
  }

  @override
  Future<void> disconnect() async {}
}
