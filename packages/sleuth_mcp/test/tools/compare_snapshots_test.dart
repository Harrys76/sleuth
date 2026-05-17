import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:sleuth_mcp/src/tools/tools.dart';
import 'package:test/test.dart';

import '../helpers/fake_vm_bridge.dart';

void main() {
  test('compare_snapshots reports added/removed/elevated + fps delta',
      () async {
    final bridge = defaultFakeBridge();
    final handler = builtInTools['compare_snapshots']!.handler;
    final before = {
      'currentIssues': [
        {'stableId': 'a', 'severity': 'warning'},
        {'stableId': 'b', 'severity': 'warning'},
      ],
      'frameStatsSummary': {'averageFps': 60.0},
    };
    final after = {
      'currentIssues': [
        {'stableId': 'b', 'severity': 'critical'},
        {'stableId': 'c', 'severity': 'warning'},
      ],
      'frameStatsSummary': {'averageFps': 45.0},
    };
    final result = await handler(bridge, {'before': before, 'after': after})
        as Map<String, Object?>;
    expect(result['added'], ['c']);
    expect(result['removed'], ['a']);
    final elevated = result['elevatedSeverity'] as List;
    expect(elevated, hasLength(1));
    expect(elevated.first, {
      'stableId': 'b',
      'before': 'warning',
      'after': 'critical',
    });
    expect(result['fpsDelta'], -15.0);
  });

  test('compare_snapshots rejects non-object args', () async {
    final bridge = defaultFakeBridge();
    final handler = builtInTools['compare_snapshots']!.handler;
    final result = await handler(
      bridge,
      {'before': 'not-a-map', 'after': const <String, Object?>{}},
    );
    expect(result, isA<ToolCallResult>());
    final tc = result as ToolCallResult;
    expect(tc.isError, isTrue);
    final firstText = (tc.content.first['text'] as String);
    expect(firstText, contains('must be object'));
  });
}
