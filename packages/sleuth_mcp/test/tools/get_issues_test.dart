import 'package:sleuth_mcp/src/tools/tools.dart';
import 'package:test/test.dart';

import '../helpers/fake_vm_bridge.dart';

void main() {
  test('get_issues without filter returns all issues', () async {
    final bridge = defaultFakeBridge();
    await bridge.connect(Uri.parse('ws://localhost/ws'));
    final handler = builtInTools['get_issues']!.handler;
    final result = await handler(bridge, {}) as Map<String, Object?>;
    final data = result['data'] as Map<String, Object?>;
    expect((data['issues'] as List), hasLength(2));
  });

  test('get_issues filters severityAtLeast warning', () async {
    final bridge = defaultFakeBridge();
    await bridge.connect(Uri.parse('ws://localhost/ws'));
    final handler = builtInTools['get_issues']!.handler;
    final result = await handler(
      bridge,
      {'severityAtLeast': 'warning'},
    ) as Map<String, Object?>;
    final data = result['data'] as Map<String, Object?>;
    expect((data['issues'] as List), hasLength(2));
  });

  test('get_issues filters severityAtLeast critical', () async {
    final bridge = defaultFakeBridge();
    await bridge.connect(Uri.parse('ws://localhost/ws'));
    final handler = builtInTools['get_issues']!.handler;
    final result = await handler(
      bridge,
      {'severityAtLeast': 'critical'},
    ) as Map<String, Object?>;
    final data = result['data'] as Map<String, Object?>;
    expect((data['issues'] as List), hasLength(1));
  });

  test('get_issues case-insensitive severity', () async {
    final bridge = defaultFakeBridge();
    await bridge.connect(Uri.parse('ws://localhost/ws'));
    final handler = builtInTools['get_issues']!.handler;
    final result = await handler(
      bridge,
      {'severityAtLeast': 'CRITICAL'},
    ) as Map<String, Object?>;
    final data = result['data'] as Map<String, Object?>;
    expect((data['issues'] as List), hasLength(1));
  });
}
