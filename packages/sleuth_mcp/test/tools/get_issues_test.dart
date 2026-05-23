import 'package:sleuth_mcp/sleuth_mcp.dart';
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

  test('compact by default: each issue trimmed to the actionable subset',
      () async {
    final bridge = defaultFakeBridge();
    await bridge.connect(Uri.parse('ws://localhost/ws'));
    final handler = builtInTools['get_issues']!.handler;
    final result = await handler(bridge, {}) as Map<String, Object?>;
    final data = result['data'] as Map<String, Object?>;
    final issues = (data['issues'] as List).cast<Map<String, Object?>>();
    expect(issues.first['stableId'], 'jank_detected');
    expect(issues.first.containsKey('rankingScore'), isFalse,
        reason: 'verbose noise must be dropped by default');
    expect(issues.first.containsKey('title'), isTrue,
        reason: 'actionable fields are kept');
    // No cap hit ⇒ no truncation stamp.
    expect(data.containsKey('_truncated'), isFalse);
    expect(data.containsKey('_totalCount'), isFalse);
  });

  test('verbose: full issue fields returned', () async {
    final bridge = defaultFakeBridge();
    await bridge.connect(Uri.parse('ws://localhost/ws'));
    final handler = builtInTools['get_issues']!.handler;
    final result =
        await handler(bridge, {'verbose': true}) as Map<String, Object?>;
    final data = result['data'] as Map<String, Object?>;
    final issues = (data['issues'] as List).cast<Map<String, Object?>>();
    expect(issues, hasLength(2));
    expect(issues.first.containsKey('rankingScore'), isTrue);
  });

  test('maxIssueCount caps + stamps _truncated/_totalCount', () async {
    final bridge = defaultFakeBridge();
    await bridge.connect(Uri.parse('ws://localhost/ws'));
    final handler = builtInTools['get_issues']!.handler;
    final result =
        await handler(bridge, {'maxIssueCount': 1}) as Map<String, Object?>;
    final data = result['data'] as Map<String, Object?>;
    expect((data['issues'] as List), hasLength(1));
    expect(data['_truncated'], isTrue);
    expect(data['_totalCount'], 2, reason: 'pre-cap count after any filter');
  });

  test('cap is applied after the severity filter (total is post-filter)',
      () async {
    final bridge = defaultFakeBridge();
    await bridge.connect(Uri.parse('ws://localhost/ws'));
    final handler = builtInTools['get_issues']!.handler;
    // Filter to critical (1 issue), cap at 1 ⇒ no truncation.
    final result = await handler(
      bridge,
      {'severityAtLeast': 'critical', 'maxIssueCount': 1},
    ) as Map<String, Object?>;
    final data = result['data'] as Map<String, Object?>;
    expect((data['issues'] as List), hasLength(1));
    expect(data.containsKey('_truncated'), isFalse,
        reason: 'post-filter count (1) does not exceed the cap (1)');
  });

  test('negative maxIssueCount is rejected with arg_invalid_int', () async {
    final bridge = defaultFakeBridge();
    await bridge.connect(Uri.parse('ws://localhost/ws'));
    final handler = builtInTools['get_issues']!.handler;
    final result = await handler(bridge, {'maxIssueCount': -1});
    expect(result, isA<ToolCallResult>());
    final tc = result as ToolCallResult;
    expect(tc.isError, isTrue);
    expect(tc.content.first['text'] as String, startsWith('arg_invalid_int:'));
  });

  test('error envelope (no data map) passes through unmodified', () async {
    final bridge = FakeVmBridge(fakeSessionUuid: 'u')
      ..setEnvelope('ext.sleuth.diagnose', {
        'connectionMode': 'basic',
        'schemaVersion': 1,
        'sessionUuid': 'u',
        'data': {'packageVersion': '0.36.0'},
      })
      ..setEnvelope('ext.sleuth.issues', {
        'connectionMode': 'basic',
        'schemaVersion': 1,
        'sessionUuid': 'u',
        'error': 'some_extension_error',
      });
    await bridge.connect(Uri.parse('ws://localhost/ws'));
    final handler = builtInTools['get_issues']!.handler;
    final result =
        await handler(bridge, {'maxIssueCount': 1}) as Map<String, Object?>;
    expect(result['error'], 'some_extension_error');
    expect(result.containsKey('data'), isFalse);
  });
}
