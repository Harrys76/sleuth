import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:sleuth_mcp/src/tools/tools.dart';
import 'package:test/test.dart';

import '../helpers/fake_vm_bridge.dart';

void main() {
  test('check_budgets passes when within thresholds', () async {
    final bridge = defaultFakeBridge();
    await bridge.connect(Uri.parse('ws://localhost/ws'));
    final handler = builtInTools['check_budgets']!.handler;
    final result = await handler(bridge, {
      'minFps': 55,
      'maxIssues': 100,
      'maxCriticalIssues': 100,
    }) as Map<String, Object?>;
    expect(result['passed'], isTrue);
    expect(result['violations'], isEmpty);
  });

  test('check_budgets fails on low fps', () async {
    final bridge = FakeVmBridge(fakeSessionUuid: 'u')
      ..setEnvelope('ext.sleuth.diagnose', {
        'connectionMode': 'basic',
        'schemaVersion': 1,
        'sessionUuid': 'u',
        'data': {'packageVersion': '0.32.0'},
      })
      ..setEnvelope('ext.sleuth.snapshot', {
        'connectionMode': 'basic',
        'schemaVersion': 1,
        'sessionUuid': 'u',
        'data': {
          'currentIssues': <Map<String, Object?>>[],
          'frameStatsSummary': {'averageFps': 30.0},
        },
      });
    await bridge.connect(Uri.parse('ws://localhost/ws'));
    final handler = builtInTools['check_budgets']!.handler;
    final result = await handler(bridge, {
      'minFps': 55,
      'maxIssues': 100,
      'maxCriticalIssues': 100,
    }) as Map<String, Object?>;
    expect(result['passed'], isFalse);
    final violations = result['violations'] as List;
    expect(violations, hasLength(1));
    expect((violations.first as Map)['budget'], 'minFps');
  });

  test('check_budgets rejects non-number minFps', () async {
    final bridge = defaultFakeBridge();
    await bridge.connect(Uri.parse('ws://localhost/ws'));
    final handler = builtInTools['check_budgets']!.handler;
    final result = await handler(bridge, {
      'minFps': 'fast',
      'maxIssues': 1,
      'maxCriticalIssues': 0,
    });
    expect((result as ToolCallResult).isError, isTrue);
  });
}
