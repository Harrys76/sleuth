import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/src/detectors/global_key_detector.dart';
import 'package:widget_watchdog/src/models/performance_issue.dart';

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
