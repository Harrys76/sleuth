import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:sleuth_mcp/src/tools/tools.dart';
import 'package:test/test.dart';

import '../helpers/fake_vm_bridge.dart';

void main() {
  test('diagnose augments data with sidecar version pin', () async {
    final bridge = defaultFakeBridge();
    await bridge.connect(Uri.parse('ws://localhost/ws'));
    final handler = builtInTools['diagnose']!.handler;
    final result = await handler(bridge, {}) as Map<String, Object?>;
    final data = result['data'] as Map<String, Object?>;
    expect(data['sidecarVersion'], sleuthMcpVersion);
    expect(data['sidecarBuiltAgainstSleuth'], isNotNull);
    expect(data['packageVersion'], '0.32.0');
  });
}
