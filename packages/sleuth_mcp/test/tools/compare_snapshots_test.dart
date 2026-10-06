import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:sleuth_mcp/src/tools/compare_snapshots.dart';
import 'package:sleuth_mcp/src/tools/issue_projection.dart';
import 'package:sleuth_mcp/src/tools/launch_mode_advisory.dart';
import 'package:sleuth_mcp/src/tools/tools.dart';
import 'package:test/test.dart';

import '../helpers/fake_vm_bridge.dart';

/// Snapshot `data` with the metadata every real snapshot carries
/// (`packageVersion`, `isVmConnected`) plus the diffed sections.
Map<String, Object?> _snap(
  List<Map<String, Object?>> issues, {
  double fps = 60.0,
  String? packageVersion = '0.37.0',
  Object? isVmConnected = true,
  Map<String, Object?> extra = const {},
}) => {
  'packageVersion': ?packageVersion,
  'isVmConnected': ?isVmConnected,
  'currentIssues': issues,
  'frameStatsSummary': {'averageFps': fps},
  ...extra,
};

Future<Object> _compare(
  Map<String, Object?> before,
  Map<String, Object?> after,
) => builtInTools['compare_snapshots']!.handler(defaultFakeBridge(), {
  'before': before,
  'after': after,
});

String _errorText(Object result) {
  expect(result, isA<ToolCallResult>());
  final tc = result as ToolCallResult;
  expect(tc.isError, isTrue);
  return tc.content.first['text'] as String;
}

void main() {
  test(
    'compare_snapshots reports added/removed/elevated + fps delta',
    () async {
      final result =
          await _compare(
                _snap([
                  {'stableId': 'a', 'severity': 'warning'},
                  {'stableId': 'b', 'severity': 'warning'},
                ]),
                _snap([
                  {'stableId': 'b', 'severity': 'critical'},
                  {'stableId': 'c', 'severity': 'warning'},
                ], fps: 45.0),
              )
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
      expect(result['countChanged'], isEmpty);
      expect(result['fpsDelta'], -15.0);
      expect(result.containsKey('coverageWarning'), isFalse);
    },
  );

  test('compare_snapshots rejects non-object args', () async {
    final bridge = defaultFakeBridge();
    final handler = builtInTools['compare_snapshots']!.handler;
    final result = await handler(bridge, {
      'before': 'not-a-map',
      'after': const <String, Object?>{},
    });
    expect(_errorText(result), contains('must be object'));
  });

  test('compare_snapshots rejects mismatched _projectedSections', () async {
    final result = await _compare(
      _snap(
        [],
        extra: {
          '_projectedSections': ['currentIssues', 'frameStatsSummary'],
        },
      ),
      _snap(
        [],
        extra: {
          '_projectedSections': ['currentIssues'],
        },
      ),
    );
    expect(_errorText(result), startsWith('arg_section_mismatch:'));
  });

  test(
    'compare_snapshots accepts identical projection (set-order agnostic)',
    () async {
      final result = await _compare(
        _snap(
          [],
          extra: {
            '_projectedSections': ['currentIssues', 'frameStatsSummary'],
          },
        ),
        _snap(
          [],
          fps: 55.0,
          // Same set, different list order — must NOT trip the mismatch guard.
          extra: {
            '_projectedSections': ['frameStatsSummary', 'currentIssues'],
          },
        ),
      );
      expect(result, isA<Map<String, Object?>>());
      expect((result as Map<String, Object?>)['fpsDelta'], -5.0);
    },
  );

  test('compare_snapshots rejects mismatched pagination limits', () async {
    // Use maxRouteCount limits: maxIssueCount would trip the
    // capped-issues guard first (covered separately below).
    final result = await _compare(
      _snap(
        [],
        extra: {
          '_projectionLimits': {'maxRouteCount': 5},
        },
      ),
      _snap(
        [],
        extra: {
          '_projectionLimits': {'maxRouteCount': 10},
        },
      ),
    );
    expect(_errorText(result), startsWith('arg_section_mismatch:'));
  });

  test('compare_snapshots rejects maxIssueCount-capped inputs', () async {
    final result = await _compare(
      _snap(
        [],
        extra: {
          '_projectionLimits': {'maxIssueCount': 5},
        },
      ),
      _snap([]),
    );
    expect(_errorText(result), startsWith('arg_capped_issues_uncomparable:'));
  });

  test(
    'compare_snapshots diffs normally when only maxRouteCount capped',
    () async {
      final result = await _compare(
        _snap(
          [
            {'stableId': 'a', 'severity': 'warning'},
          ],
          extra: {
            '_projectionLimits': {'maxRouteCount': 3},
          },
        ),
        _snap(
          [
            {'stableId': 'a', 'severity': 'warning'},
          ],
          fps: 55.0,
          extra: {
            '_projectionLimits': {'maxRouteCount': 3},
          },
        ),
      );
      expect(
        result,
        isA<Map<String, Object?>>(),
        reason: 'maxRouteCount cap does not affect the issue diff',
      );
      expect((result as Map<String, Object?>)['fpsDelta'], -5.0);
    },
  );

  test(
    'diffs correctly when fed compacted (v0.6.5 default) issue shapes',
    () async {
      // The compact projection keeps stableId + severity, so a diff over
      // compact snapshots must produce the same result as over full ones.
      final result =
          await _compare(
                _snap([compactIssue(fullFakeIssues().first)]),
                // Same stableId, severity elevated warning -> critical.
                _snap([
                  {
                    ...compactIssue(fullFakeIssues().first),
                    'severity': 'critical',
                  },
                ], fps: 50.0),
              )
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
    },
  );

  group('per-stableId aggregation', () {
    test('a new critical occurrence beside an existing warning is an elevation '
        'and a count change', () async {
      // One shrink-wrapped list before; the after run keeps it and adds a
      // larger one under the same stableId, ranked first.
      final result =
          await _compare(
                _snap([
                  {'stableId': 'non_lazy_shrinkwrap', 'severity': 'warning'},
                ]),
                _snap([
                  {'stableId': 'non_lazy_shrinkwrap', 'severity': 'critical'},
                  {'stableId': 'non_lazy_shrinkwrap', 'severity': 'warning'},
                ]),
              )
              as Map<String, Object?>;
      expect(result['added'], isEmpty);
      expect(result['removed'], isEmpty);
      expect(result['elevatedSeverity'], [
        {
          'stableId': 'non_lazy_shrinkwrap',
          'before': 'warning',
          'after': 'critical',
        },
      ]);
      expect(result['countChanged'], [
        {'stableId': 'non_lazy_shrinkwrap', 'before': 1, 'after': 2},
      ]);
    });

    test('highest severity wins regardless of list order', () async {
      final result =
          await _compare(
                _snap([
                  {'stableId': 'x', 'severity': 'warning'},
                ]),
                _snap([
                  {'stableId': 'x', 'severity': 'warning'},
                  {'stableId': 'x', 'severity': 'critical'},
                  {'stableId': 'x', 'severity': 'ok'},
                ]),
              )
              as Map<String, Object?>;
      expect((result['elevatedSeverity'] as List).single, {
        'stableId': 'x',
        'before': 'warning',
        'after': 'critical',
      });
      expect(result['countChanged'], [
        {'stableId': 'x', 'before': 1, 'after': 3},
      ]);
    });

    test(
      'a resolved second occurrence is a count change, not an elevation',
      () async {
        final result =
            await _compare(
                  _snap([
                    {'stableId': 'y', 'severity': 'warning'},
                    {'stableId': 'y', 'severity': 'warning'},
                  ]),
                  _snap([
                    {'stableId': 'y', 'severity': 'warning'},
                  ]),
                )
                as Map<String, Object?>;
        expect(result['elevatedSeverity'], isEmpty);
        expect(result['countChanged'], [
          {'stableId': 'y', 'before': 2, 'after': 1},
        ]);
      },
    );
  });

  group('sleuth lineage guard', () {
    test('refuses snapshots from different lineages', () async {
      final text = _errorText(
        await _compare(
          _snap([
            {'stableId': 'excessive_keep_alive:0', 'severity': 'warning'},
          ], packageVersion: '0.36.0'),
          _snap([
            {
              'stableId': 'excessive_keep_alive:PageView~k-feed',
              'severity': 'warning',
            },
          ]),
        ),
      );
      expect(text, startsWith('arg_lineage_mismatch:'));
      expect(text, contains('0.36.0'));
      expect(text, contains('0.37.0'));
    });

    test('accepts the same lineage at different patches', () async {
      final result = await _compare(
        _snap([], packageVersion: '0.37.0'),
        _snap([], packageVersion: '0.37.2'),
      );
      expect(result, isA<Map<String, Object?>>());
    });

    test('a prerelease or build stays in its lineage', () async {
      final result = await _compare(
        _snap([], packageVersion: '0.37.0-dev.1'),
        _snap([], packageVersion: '0.37.0+build.5'),
      );
      expect(result, isA<Map<String, Object?>>());
    });

    for (final (label, version) in <(String, Object?)>[
      ('missing', null),
      ('non-String', 37),
      ('two-part', '0.37'),
      ('malformed', '0.37.garbage'),
      ('empty', ''),
    ]) {
      test('refuses a packageVersion that is $label, on either side', () async {
        final bad = _snap([])..remove('packageVersion');
        if (version != null) bad['packageVersion'] = version;
        expect(
          _errorText(await _compare(bad, _snap([]))),
          startsWith('arg_lineage_mismatch:'),
        );
        expect(
          _errorText(await _compare(_snap([]), bad)),
          startsWith('arg_lineage_mismatch:'),
        );
      });
    }
  });

  group('VM coverage guard', () {
    test('refuses when only one snapshot had a VM link (heap_growing would '
        'read as removed)', () async {
      final text = _errorText(
        await _compare(
          _snap([
            {'stableId': 'heap_growing', 'severity': 'warning'},
          ]),
          _snap([], isVmConnected: false),
        ),
      );
      expect(text, startsWith('arg_coverage_mismatch:'));
      expect(text, contains('heap_growing'));
    });

    test('a launchModeAdvisory counts as no VM coverage', () async {
      final result = await _compare(
        _snap([]),
        _snap([], extra: {'launchModeAdvisory': launchAdvisoryWarmup}),
      );
      expect(_errorText(result), startsWith('arg_coverage_mismatch:'));
    });

    for (final (label, value) in <(String, Object?)>[
      ('missing', null),
      ('non-bool', 'true'),
    ]) {
      test('refuses a $label isVmConnected as unknown coverage', () async {
        final unknown = _snap([], isVmConnected: value);
        expect(
          _errorText(await _compare(unknown, _snap([]))),
          startsWith('arg_coverage_mismatch:'),
        );
        expect(
          _errorText(await _compare(_snap([]), unknown)),
          startsWith('arg_coverage_mismatch:'),
        );
      });
    }

    test('compares two snapshots without a VM link and warns that VM-only '
        'detectors were not observed', () async {
      final result =
          await _compare(
                _snap([
                  {'stableId': 'jank_detected', 'severity': 'warning'},
                ], isVmConnected: false),
                _snap(
                  [],
                  isVmConnected: false,
                  extra: {'launchModeAdvisory': launchAdvisoryBasic},
                ),
              )
              as Map<String, Object?>;
      expect(result['removed'], ['jank_detected']);
      expect(result['coverageWarning'], noVmCoverageWarning);
      expect(
        result['coverageWarning'] as String,
        startsWith('vm_detectors_not_observed:'),
      );
    });
  });
}
