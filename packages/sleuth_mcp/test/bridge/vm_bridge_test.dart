import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart' as vm;

import '../helpers/fake_vm_bridge.dart';

void main() {
  test('FakeVmBridge returns canned envelope', () async {
    final bridge = defaultFakeBridge();
    await bridge.connect(Uri.parse('ws://localhost/ws'));
    final env = await bridge.callExtension('ext.sleuth.diagnose');
    expect(env['sessionUuid'], 'fake-uuid');
    expect(env['schemaVersion'], 1);
    expect(env['data'], isA<Map<String, Object?>>());
  });

  test('FakeVmBridge throws on session drift', () async {
    final bridge = defaultFakeBridge();
    await bridge.connect(Uri.parse('ws://localhost/ws'));
    bridge.simulateSessionChange('different-uuid');
    expect(
      () => bridge.callExtension('ext.sleuth.diagnose'),
      throwsA(isA<SessionChangedException>()),
    );
  });

  test('FakeVmBridge errors before connect', () async {
    final bridge = defaultFakeBridge();
    expect(
      () => bridge.callExtension('ext.sleuth.diagnose'),
      throwsA(isA<VmBridgeException>()),
    );
  });

  test('FakeVmBridge exposes lastDiagnoseEnvelope', () async {
    final bridge = defaultFakeBridge();
    await bridge.connect(Uri.parse('ws://localhost/ws'));
    final diag = bridge.lastDiagnoseEnvelope;
    expect(diag, isNotNull);
    expect(diag!['sessionUuid'], 'fake-uuid');
  });

  group('RealVmBridge.pickMainIsolate', () {
    vm.IsolateRef ref({String? id, String? name}) =>
        vm.IsolateRef(id: id, name: name);

    test('prefers exact name=main', () {
      final picked = RealVmBridge.pickMainIsolate([
        ref(id: 'bg-1', name: 'background'),
        ref(id: 'main-2', name: 'main'),
        ref(id: 'bg-3', name: 'worker'),
      ]);
      expect(picked.id, 'main-2');
    });

    test('falls back to startsWith(main)', () {
      final picked = RealVmBridge.pickMainIsolate([
        ref(id: 'bg-1', name: 'background'),
        ref(id: 'main-iso-2', name: 'main-iso'),
      ]);
      expect(picked.id, 'main-iso-2');
    });

    test('falls back to first when no main candidate', () {
      final picked = RealVmBridge.pickMainIsolate([
        ref(id: 'bg-1', name: 'background'),
        ref(id: 'bg-2', name: 'worker'),
      ]);
      expect(picked.id, 'bg-1');
    });
  });
}
