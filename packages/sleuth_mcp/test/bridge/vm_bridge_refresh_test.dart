import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:test/test.dart';

import '../helpers/fake_vm_bridge.dart';

void main() {
  group('FakeVmBridge.refreshBaseline', () {
    test('bumps baselineGeneration on connect + refresh', () async {
      final bridge = defaultFakeBridge();
      expect(bridge.baselineGeneration, 0);
      await bridge.connect(Uri.parse('ws://localhost/ws'));
      expect(bridge.baselineGeneration, 1);
      await bridge.refreshBaseline();
      expect(bridge.baselineGeneration, 2);
      await bridge.refreshBaseline();
      expect(bridge.baselineGeneration, 3);
    });

    test('throws VmBridgeException when not connected', () async {
      final bridge = defaultFakeBridge();
      expect(
        () => bridge.refreshBaseline(),
        throwsA(isA<VmBridgeException>()),
      );
    });
  });
}
