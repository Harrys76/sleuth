import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/detectors/global_key_detector.dart';
import 'package:sleuth/src/models/performance_issue.dart';

void main() {
  group('GlobalKeyDetector', () {
    late GlobalKeyDetector detector;

    setUp(() {
      // Use low threshold so tests only need a few mounted children.
      detector = GlobalKeyDetector(threshold: 2);
    });

    testWidgets('no issues when disabled', (tester) async {
      detector.isEnabled = false;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            height: 600,
            child: ListView(
              children: _keyedChildren(5),
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, isEmpty);
      expect(detector.highlights, isEmpty);
    });

    testWidgets('flags GlobalKeys exceeding threshold', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            height: 600,
            child: ListView(
              children: _keyedChildren(5),
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.title, contains('in ListView'));
      expect(detector.issues.first.observationSource,
          ObservationSource.structural);
    });

    testWidgets('no issue when count at or below threshold', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            height: 600,
            child: ListView(
              children: _keyedChildren(2),
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, isEmpty);
    });

    testWidgets('critical severity when count > 3x threshold', (tester) async {
      // threshold=2, critical at >6
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            height: 600,
            child: ListView(
              children: _keyedChildren(8),
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues.first.severity, IssueSeverity.critical);
    });

    testWidgets('warning severity when count <= 3x threshold', (tester) async {
      // threshold=2, 5 keys: > 2 but <= 6
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            height: 600,
            child: ListView(
              children: _keyedChildren(5),
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues.first.severity, IssueSeverity.warning);
    });

    testWidgets('highlights produced with detectorName GlobalKey',
        (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            height: 600,
            child: ListView(
              children: _keyedChildren(5),
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.highlights, isNotEmpty);
      expect(detector.highlights.first.detectorName, 'GlobalKey');
    });

    testWidgets('detects in GridView too', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            height: 600,
            child: GridView.count(
              crossAxisCount: 2,
              children: _keyedChildren(5),
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, hasLength(1));
    });

    testWidgets('skips private widget types (names starting with _)',
        (tester) async {
      // _PrivateWidget names start with '_', so GlobalKeys on them are not
      // counted. 5 private-keyed children should not exceed threshold=2.
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            height: 600,
            child: ListView(
              children: List.generate(
                5,
                (_) => _PrivateWidget(key: GlobalKey(), height: 10),
              ),
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, isEmpty);
    });

    testWidgets('skips framework widget types', (tester) async {
      // Focus is in the frameworkWidgets set, so GlobalKeys on Focus
      // are not counted. Use enough to exceed threshold if they were counted.
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            height: 600,
            child: ListView(
              children: List.generate(
                5,
                (_) => Focus(
                  key: GlobalKey(),
                  child: const SizedBox(height: 10),
                ),
              ),
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, isEmpty);
    });

    testWidgets('stableId, confidence, and category', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            height: 600,
            child: ListView(
              children: _keyedChildren(5),
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      final issue = detector.issues.first;
      expect(issue.stableId, 'excessive_global_keys:0');
      expect(issue.confidence, IssueConfidence.possible);
      expect(issue.category, IssueCategory.build);
    });

    testWidgets('dispose clears issues and highlights', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            height: 600,
            child: ListView(
              children: _keyedChildren(5),
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, isNotEmpty);

      detector.dispose();
      expect(detector.issues, isEmpty);
      expect(detector.highlights, isEmpty);
    });

    // -----------------------------------------------------------------
    // v11.16: GlobalKey recreation detection
    // -----------------------------------------------------------------

    testWidgets('no recreation issue on first scan (no previous data)',
        (tester) async {
      final recreationDetector =
          GlobalKeyDetector(threshold: 100, recreationThreshold: 3);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: List.generate(
              5,
              (_) => PublicWidget(key: GlobalKey(), height: 10),
            ),
          ),
        ),
      );
      recreationDetector.scanTree(tester.element(find.byType(Directionality)));
      final recIssues = recreationDetector.issues
          .where((i) => i.stableId == 'global_key_recreation');
      expect(recIssues, isEmpty,
          reason: 'First scan has no previous key set to compare');
    });

    testWidgets('recreation flagged when keys change between scans',
        (tester) async {
      final recreationDetector =
          GlobalKeyDetector(threshold: 100, recreationThreshold: 3);

      // Scan 1: pump with one set of GlobalKeys
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: List.generate(
              5,
              (_) => PublicWidget(key: GlobalKey(), height: 10),
            ),
          ),
        ),
      );
      recreationDetector.scanTree(tester.element(find.byType(Directionality)));

      // Scan 2: pump with NEW GlobalKeys (simulates build() recreation)
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: List.generate(
              5,
              (_) => PublicWidget(key: GlobalKey(), height: 10),
            ),
          ),
        ),
      );
      recreationDetector.scanTree(tester.element(find.byType(Directionality)));

      final recIssues = recreationDetector.issues
          .where((i) => i.stableId == 'global_key_recreation');
      expect(recIssues, hasLength(1));
      expect(recIssues.first.severity, IssueSeverity.warning);
      expect(recIssues.first.confidence, IssueConfidence.likely);
      expect(recIssues.first.category, IssueCategory.build);
      expect(recIssues.first.detail, contains('replaced with new instances'));
    });

    testWidgets('no recreation when same keys persist across scans',
        (tester) async {
      final recreationDetector =
          GlobalKeyDetector(threshold: 100, recreationThreshold: 3);

      // Use stable keys stored outside build
      final stableKeys = List.generate(5, (_) => GlobalKey());

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: stableKeys
                .map((k) => PublicWidget(key: k, height: 10))
                .toList(),
          ),
        ),
      );
      recreationDetector.scanTree(tester.element(find.byType(Directionality)));

      // Scan 2: same keys
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: stableKeys
                .map((k) => PublicWidget(key: k, height: 10))
                .toList(),
          ),
        ),
      );
      recreationDetector.scanTree(tester.element(find.byType(Directionality)));

      final recIssues = recreationDetector.issues
          .where((i) => i.stableId == 'global_key_recreation');
      expect(recIssues, isEmpty);
    });

    testWidgets('navigation (asymmetric churn) not flagged as recreation',
        (tester) async {
      final recreationDetector =
          GlobalKeyDetector(threshold: 100, recreationThreshold: 3);

      // Scan 1: 5 keys
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: List.generate(
              5,
              (_) => PublicWidget(key: GlobalKey(), height: 10),
            ),
          ),
        ),
      );
      recreationDetector.scanTree(tester.element(find.byType(Directionality)));

      // Scan 2: 8 keys (5 new + 3 extra — purely additive, like navigation)
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: List.generate(
              8,
              (_) => PublicWidget(key: GlobalKey(), height: 10),
            ),
          ),
        ),
      );
      recreationDetector.scanTree(tester.element(find.byType(Directionality)));

      // All 5 old keys are gone (goneKeys=5), 8 new keys (newKeys=8).
      // min(8, 5) = 5 >= threshold=3, so this WILL be flagged.
      // To test true asymmetric churn (navigation adding keys without
      // removing), we need stable keys that persist.
      // This is actually symmetric churn — let's test with real navigation.
      recreationDetector.dispose();

      // Real navigation test: keep old keys, add new ones
      final navDetector =
          GlobalKeyDetector(threshold: 100, recreationThreshold: 3);
      final stableKeys = List.generate(5, (_) => GlobalKey());

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: stableKeys
                .map((k) => PublicWidget(key: k, height: 10))
                .toList(),
          ),
        ),
      );
      navDetector.scanTree(tester.element(find.byType(Directionality)));

      // Scan 2: keep old keys + add 5 more (navigation push)
      final newKeys = List.generate(5, (_) => GlobalKey());
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              ...stableKeys.map((k) => PublicWidget(key: k, height: 10)),
              ...newKeys.map((k) => PublicWidget(key: k, height: 10)),
            ],
          ),
        ),
      );
      navDetector.scanTree(tester.element(find.byType(Directionality)));

      // newKeys=5, goneKeys=0 → min(5,0)=0 → no recreation
      final recIssues = navDetector.issues
          .where((i) => i.stableId == 'global_key_recreation');
      expect(recIssues, isEmpty,
          reason: 'Purely additive key changes (navigation) should not '
              'be flagged as recreation');
    });

    testWidgets('recreation below threshold not flagged', (tester) async {
      final recreationDetector =
          GlobalKeyDetector(threshold: 100, recreationThreshold: 5);

      // Scan 1: 3 keys
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: List.generate(
              3,
              (_) => PublicWidget(key: GlobalKey(), height: 10),
            ),
          ),
        ),
      );
      recreationDetector.scanTree(tester.element(find.byType(Directionality)));

      // Scan 2: 3 new keys (churn=3, below threshold=5)
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: List.generate(
              3,
              (_) => PublicWidget(key: GlobalKey(), height: 10),
            ),
          ),
        ),
      );
      recreationDetector.scanTree(tester.element(find.byType(Directionality)));

      final recIssues = recreationDetector.issues
          .where((i) => i.stableId == 'global_key_recreation');
      expect(recIssues, isEmpty);
    });

    testWidgets('critical severity at 3x recreation threshold', (tester) async {
      final recreationDetector =
          GlobalKeyDetector(threshold: 100, recreationThreshold: 3);

      // Scan 1
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: List.generate(
              10,
              (_) => PublicWidget(key: GlobalKey(), height: 10),
            ),
          ),
        ),
      );
      recreationDetector.scanTree(tester.element(find.byType(Directionality)));

      // Scan 2: 10 new keys → churn=10, threshold=3, 3x=9 → critical
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: List.generate(
              10,
              (_) => PublicWidget(key: GlobalKey(), height: 10),
            ),
          ),
        ),
      );
      recreationDetector.scanTree(tester.element(find.byType(Directionality)));

      final recIssue = recreationDetector.issues
          .firstWhere((i) => i.stableId == 'global_key_recreation');
      expect(recIssue.severity, IssueSeverity.critical);
    });

    testWidgets('dispose resets recreation tracking state', (tester) async {
      final recreationDetector =
          GlobalKeyDetector(threshold: 100, recreationThreshold: 3);

      // Scan 1
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: List.generate(
              5,
              (_) => PublicWidget(key: GlobalKey(), height: 10),
            ),
          ),
        ),
      );
      recreationDetector.scanTree(tester.element(find.byType(Directionality)));

      // Dispose resets state
      recreationDetector.dispose();

      // Scan 2 after dispose: should act like first scan (no prev data)
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: List.generate(
              5,
              (_) => PublicWidget(key: GlobalKey(), height: 10),
            ),
          ),
        ),
      );
      recreationDetector.scanTree(tester.element(find.byType(Directionality)));

      final recIssues = recreationDetector.issues
          .where((i) => i.stableId == 'global_key_recreation');
      expect(recIssues, isEmpty,
          reason: 'After dispose, prevKeyIds is empty — no comparison');
    });

    testWidgets('recreation fixHint mentions storing keys in State',
        (tester) async {
      final recreationDetector =
          GlobalKeyDetector(threshold: 100, recreationThreshold: 3);

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: List.generate(
              5,
              (_) => PublicWidget(key: GlobalKey(), height: 10),
            ),
          ),
        ),
      );
      recreationDetector.scanTree(tester.element(find.byType(Directionality)));

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: List.generate(
              5,
              (_) => PublicWidget(key: GlobalKey(), height: 10),
            ),
          ),
        ),
      );
      recreationDetector.scanTree(tester.element(find.byType(Directionality)));

      final recIssue = recreationDetector.issues
          .firstWhere((i) => i.stableId == 'global_key_recreation');
      expect(recIssue.fixHint, contains('State'));
      expect(recIssue.fixHint, contains('build()'));
    });

    // -----------------------------------------------------------------
    // v9.6: Per-scrollable accumulation
    // -----------------------------------------------------------------

    testWidgets('two scrollables each below threshold produce no issues',
        (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            height: 600,
            child: Column(
              children: [
                Expanded(
                  child: ListView(children: _keyedChildren(2)),
                ),
                Expanded(
                  child: ListView(children: _keyedChildren(2)),
                ),
              ],
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, isEmpty,
          reason: 'Each scrollable has ≤threshold keys — no issue');
    });

    testWidgets('two scrollables each above threshold produce two issues',
        (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            height: 600,
            child: Column(
              children: [
                Expanded(
                  child: ListView(children: _keyedChildren(5)),
                ),
                Expanded(
                  child: ListView(children: _keyedChildren(5)),
                ),
              ],
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues, hasLength(2));
      expect(detector.issues[0].stableId, 'excessive_global_keys:0');
      expect(detector.issues[1].stableId, 'excessive_global_keys:1');
    });

    testWidgets('one above one below threshold produces one issue',
        (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            height: 600,
            child: Column(
              children: [
                Expanded(
                  child: ListView(children: _keyedChildren(5)),
                ),
                Expanded(
                  child: ListView(children: _keyedChildren(1)),
                ),
              ],
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.stableId, 'excessive_global_keys:0');
    });
  });
}

/// Generate N public-name widgets with unique GlobalKeys.
/// Tiny height + large viewport ensures all children are mounted.
List<Widget> _keyedChildren(int count) => List.generate(
      count,
      (_) => PublicWidget(key: GlobalKey(), height: 10),
    );

/// Public-name widget so GlobalKeyDetector counts it
/// (skips private types starting with '_').
class PublicWidget extends StatelessWidget {
  const PublicWidget({super.key, this.height = 10});
  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(height: height);
}

/// Private-name widget — GlobalKeyDetector skips types starting with '_'.
class _PrivateWidget extends StatelessWidget {
  const _PrivateWidget({super.key, required this.height});
  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(height: height);
}
