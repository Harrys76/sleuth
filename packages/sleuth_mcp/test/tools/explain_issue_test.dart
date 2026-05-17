import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:sleuth_mcp/src/tools/tools.dart';
import 'package:test/test.dart';

import '../helpers/fake_vm_bridge.dart';

void main() {
  test('explain_issue returns isError on missing stableId', () async {
    final bridge = defaultFakeBridge();
    await bridge.connect(Uri.parse('ws://localhost/ws'));
    final handler = builtInTools['explain_issue']!.handler;
    final result = await handler(bridge, {});
    expect(result, isA<ToolCallResult>());
    expect((result as ToolCallResult).isError, isTrue);
  });

  test('explain_issue forwards stableId to extension', () async {
    final bridge = defaultFakeBridge();
    await bridge.connect(Uri.parse('ws://localhost/ws'));
    final handler = builtInTools['explain_issue']!.handler;
    final result = await handler(bridge, {'stableId': 'jank_detected'})
        as Map<String, Object?>;
    expect(result['data'], isA<Map<String, Object?>>());
  });

  test('explain_issue rejects empty stableId', () async {
    final bridge = defaultFakeBridge();
    await bridge.connect(Uri.parse('ws://localhost/ws'));
    final handler = builtInTools['explain_issue']!.handler;
    final result = await handler(bridge, {'stableId': ''});
    expect((result as ToolCallResult).isError, isTrue);
  });
}
