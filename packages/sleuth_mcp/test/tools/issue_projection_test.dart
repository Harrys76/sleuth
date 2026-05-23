import 'package:sleuth_mcp/src/tools/issue_projection.dart';
import 'package:test/test.dart';

import '../helpers/fake_vm_bridge.dart';

void main() {
  group('compactIssue', () {
    test('keeps only the actionable subset, drops verbose noise', () {
      final full = fullFakeIssues().first;
      final compact = compactIssue(full);

      // Every kept key that was present survives.
      expect(compact.keys.toSet(), {
        'severity',
        'category',
        'confidence',
        'title',
        'detail',
        'fixHint',
        'stableId',
        'widgetName',
        'routeName',
        'sourceRoute',
        'confidenceReason',
        'rootCauseIds',
      });
      // Values pass through untouched.
      expect(compact['stableId'], 'jank_detected');
      expect(compact['severity'], 'warning');
      expect(compact['rootCauseIds'], ['heap_growing']);
      // Noise is gone.
      for (final dropped in [
        'captureTraceStableId',
        'observationSource',
        'debugModeDisclaimer',
        'detectedAt',
        'rankingScore',
        'rankingBreakdown',
        'downstreamIds',
        'packageName',
      ]) {
        expect(compact.containsKey(dropped), isFalse,
            reason: '$dropped must be dropped by compaction');
      }
    });

    test('absent optional keys stay absent (not coerced to null)', () {
      // Second fixture omits rootCauseIds entirely.
      final compact = compactIssue(fullFakeIssues()[1]);
      expect(compact.containsKey('rootCauseIds'), isFalse);
      expect(compact['stableId'], 'heap_growing');
    });
  });

  group('projectIssues', () {
    test('compact (default) trims fields, no cap drop ⇒ not truncated', () {
      final result =
          projectIssues(fullFakeIssues(), verbose: false, maxCount: 50);
      expect(result.issues, hasLength(2));
      expect(result.truncated, isFalse);
      expect(result.total, 2);
      expect(result.issues.first.containsKey('rankingScore'), isFalse);
    });

    test('verbose keeps full fields', () {
      final result =
          projectIssues(fullFakeIssues(), verbose: true, maxCount: 50);
      expect(result.issues, hasLength(2));
      expect(result.issues.first.containsKey('rankingScore'), isTrue);
    });

    test('cap drops the tail and reports pre-cap total', () {
      final result =
          projectIssues(fullFakeIssues(), verbose: false, maxCount: 1);
      expect(result.issues, hasLength(1));
      expect(result.truncated, isTrue);
      expect(result.total, 2);
      // Front-N of the already-ranked order — index 0 kept.
      expect(result.issues.first['stableId'], 'jank_detected');
    });

    test('cap applies even when verbose (field shape is orthogonal)', () {
      final result =
          projectIssues(fullFakeIssues(), verbose: true, maxCount: 1);
      expect(result.issues, hasLength(1));
      expect(result.truncated, isTrue);
      // Still full fields on the kept entry.
      expect(result.issues.first.containsKey('rankingScore'), isTrue);
    });

    test('maxCount 0 means unbounded', () {
      final result =
          projectIssues(fullFakeIssues(), verbose: false, maxCount: 0);
      expect(result.issues, hasLength(2));
      expect(result.truncated, isFalse);
    });

    test('empty input ⇒ empty, not truncated', () {
      final result = projectIssues(
        const <Map<String, Object?>>[],
        verbose: false,
        maxCount: 50,
      );
      expect(result.issues, isEmpty);
      expect(result.truncated, isFalse);
      expect(result.total, 0);
    });
  });
}
