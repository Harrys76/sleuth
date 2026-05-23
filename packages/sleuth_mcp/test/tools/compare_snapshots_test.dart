import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:sleuth_mcp/src/tools/issue_projection.dart';
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

  test('compare_snapshots rejects mismatched _projectedSections', () async {
    final bridge = defaultFakeBridge();
    final handler = builtInTools['compare_snapshots']!.handler;
    final before = {
      'currentIssues': <Map<String, Object?>>[],
      'frameStatsSummary': {'averageFps': 60.0},
      '_projectedSections': ['currentIssues', 'frameStatsSummary'],
    };
    final after = {
      'currentIssues': <Map<String, Object?>>[],
      'frameStatsSummary': {'averageFps': 60.0},
      '_projectedSections': ['currentIssues'],
    };
    final result = await handler(bridge, {'before': before, 'after': after});
    final tc = result as ToolCallResult;
    expect(tc.isError, isTrue);
    expect(tc.content.first['text'] as String,
        startsWith('arg_section_mismatch:'));
  });

  test('compare_snapshots accepts identical projection (set-order agnostic)',
      () async {
    final bridge = defaultFakeBridge();
    final handler = builtInTools['compare_snapshots']!.handler;
    final before = {
      'currentIssues': <Map<String, Object?>>[],
      'frameStatsSummary': {'averageFps': 60.0},
      '_projectedSections': ['currentIssues', 'frameStatsSummary'],
    };
    final after = {
      'currentIssues': <Map<String, Object?>>[],
      'frameStatsSummary': {'averageFps': 55.0},
      // Same set, different list order — must NOT trip the mismatch guard.
      '_projectedSections': ['frameStatsSummary', 'currentIssues'],
    };
    final result = await handler(bridge, {'before': before, 'after': after});
    expect(result, isA<Map<String, Object?>>());
    expect((result as Map<String, Object?>)['fpsDelta'], -5.0);
  });

  test('compare_snapshots rejects mismatched pagination limits', () async {
    // Use maxRouteCount limits: maxIssueCount would trip the
    // capped-issues guard first (covered separately below).
    final bridge = defaultFakeBridge();
    final handler = builtInTools['compare_snapshots']!.handler;
    final before = {
      'currentIssues': <Map<String, Object?>>[],
      'frameStatsSummary': {'averageFps': 60.0},
      '_projectionLimits': {'maxRouteCount': 5},
    };
    final after = {
      'currentIssues': <Map<String, Object?>>[],
      'frameStatsSummary': {'averageFps': 60.0},
      '_projectionLimits': {'maxRouteCount': 10},
    };
    final result = await handler(bridge, {'before': before, 'after': after});
    final tc = result as ToolCallResult;
    expect(tc.isError, isTrue);
    expect(tc.content.first['text'] as String,
        startsWith('arg_section_mismatch:'));
  });

  test('compare_snapshots rejects maxIssueCount-capped inputs', () async {
    final bridge = defaultFakeBridge();
    final handler = builtInTools['compare_snapshots']!.handler;
    final capped = {
      'currentIssues': <Map<String, Object?>>[],
      'frameStatsSummary': {'averageFps': 60.0},
      '_projectionLimits': {'maxIssueCount': 5},
    };
    final full = {
      'currentIssues': <Map<String, Object?>>[],
      'frameStatsSummary': {'averageFps': 60.0},
    };
    final result = await handler(bridge, {'before': capped, 'after': full});
    final tc = result as ToolCallResult;
    expect(tc.isError, isTrue);
    expect(tc.content.first['text'] as String,
        startsWith('arg_capped_issues_uncomparable:'));
  });

  test('compare_snapshots diffs normally when only maxRouteCount capped',
      () async {
    final bridge = defaultFakeBridge();
    final handler = builtInTools['compare_snapshots']!.handler;
    final before = {
      'currentIssues': [
        {'stableId': 'a', 'severity': 'warning'}
      ],
      'frameStatsSummary': {'averageFps': 60.0},
      '_projectionLimits': {'maxRouteCount': 3},
    };
    final after = {
      'currentIssues': [
        {'stableId': 'a', 'severity': 'warning'}
      ],
      'frameStatsSummary': {'averageFps': 55.0},
      '_projectionLimits': {'maxRouteCount': 3},
    };
    final result = await handler(bridge, {'before': before, 'after': after});
    expect(result, isA<Map<String, Object?>>(),
        reason: 'maxRouteCount cap does not affect the issue diff');
    expect((result as Map<String, Object?>)['fpsDelta'], -5.0);
  });

  test('diffs correctly when fed compacted (v0.6.5 default) issue shapes',
      () async {
    // The compact projection keeps stableId + severity, so a diff over
    // compact snapshots must produce the same result as over full ones.
    final bridge = defaultFakeBridge();
    final handler = builtInTools['compare_snapshots']!.handler;
    final before = {
      'currentIssues': [compactIssue(fullFakeIssues().first)],
      'frameStatsSummary': {'averageFps': 60.0},
    };
    final after = {
      // Same stableId, severity elevated warning -> critical.
      'currentIssues': [
        {...compactIssue(fullFakeIssues().first), 'severity': 'critical'},
      ],
      'frameStatsSummary': {'averageFps': 50.0},
    };
    final result = await handler(bridge, {'before': before, 'after': after})
        as Map<String, Object?>;
    expect(result['added'], isEmpty);
    expect(result['removed'], isEmpty);
    final elevated = result['elevatedSeverity'] as List;
    expect(elevated, hasLength(1));
    expect(elevated.first, {
      'stableId': 'jank_detected',
      'before': 'warning',
      'after': 'critical',
    });
    expect(result['fpsDelta'], -10.0);
  });
}
