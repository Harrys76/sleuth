import 'package:sleuth_mcp/src/resources/causal_graph.dart';
import 'package:test/test.dart';

import '../helpers/fake_vm_bridge.dart';

void main() {
  test('causal_graph caches and serves cached on second read', () async {
    final bridge = defaultFakeBridge();
    await bridge.connect(Uri.parse('ws://localhost/ws'));
    final res = CausalGraphResource(bridge: bridge);
    final first = await res.read();
    final second = await res.read();
    expect(identical(first, second), isTrue);
  });
}
