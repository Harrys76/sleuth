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
        'data': {'packageVersion': '0.33.0'},
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

  test(
      'evaluateBudgets returns arg_missing_required_section on a projected '
      'snapshot lacking frameStatsSummary', () {
    final result = evaluateBudgets(
      snapshot: {
        'currentIssues': <Map<String, Object?>>[],
        '_projectedSections': ['currentIssues'],
      },
      minFps: 55,
      maxIssues: 10,
      maxCriticalIssues: 0,
    );
    final tc = result as ToolCallResult;
    expect(tc.isError, isTrue);
    expect(tc.content.first['text'] as String,
        startsWith('arg_missing_required_section:'));
  });

  test(
      'evaluateBudgets keeps generic error when section absent + not '
      'projected (genuine drift)', () {
    final result = evaluateBudgets(
      snapshot: {'currentIssues': <Map<String, Object?>>[]},
      minFps: 55,
      maxIssues: 10,
      maxCriticalIssues: 0,
    );
    final tc = result as ToolCallResult;
    expect(tc.isError, isTrue);
    expect(tc.content.first['text'] as String,
        'snapshot missing required frameStatsSummary');
  });

  test('evaluateBudgets rejects a maxIssueCount-capped snapshot', () {
    final result = evaluateBudgets(
      snapshot: {
        'currentIssues': [
          {'severity': 'warning'}
        ],
        'frameStatsSummary': {'averageFps': 60.0},
        '_projectionLimits': {'maxIssueCount': 3},
      },
      minFps: 55,
      maxIssues: 10,
      maxCriticalIssues: 0,
    );
    final tc = result as ToolCallResult;
    expect(tc.isError, isTrue);
    expect(tc.content.first['text'] as String,
        startsWith('arg_capped_issues_unbudgetable:'));
  });

  test('evaluateBudgets evaluates normally when only maxRouteCount capped', () {
    final result = evaluateBudgets(
      snapshot: {
        'currentIssues': <Map<String, Object?>>[],
        'frameStatsSummary': {'averageFps': 60.0},
        '_projectionLimits': {'maxRouteCount': 3},
      },
      minFps: 55,
      maxIssues: 10,
      maxCriticalIssues: 0,
    );
    expect(result, isA<Map<String, Object?>>(),
        reason: 'maxRouteCount cap does not affect budget correctness');
    expect((result as Map<String, Object?>)['passed'], isTrue);
  });
}
