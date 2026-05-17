import 'package:sleuth_mcp/src/tools/tools.dart';
import 'package:test/test.dart';

import '../helpers/fake_vm_bridge.dart';

void main() {
  test('get_snapshot passes envelope through', () async {
    final bridge = defaultFakeBridge();
    await bridge.connect(Uri.parse('ws://localhost/ws'));
    final handler = builtInTools['get_snapshot']!.handler;
    final result = await handler(bridge, {}) as Map<String, Object?>;
    expect(result['sessionUuid'], 'fake-uuid');
    expect(result['data'], isA<Map<String, Object?>>());
  });
}
