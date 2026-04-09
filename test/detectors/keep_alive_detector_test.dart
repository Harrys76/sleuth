import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/detectors/keep_alive_detector.dart';
import 'package:sleuth/src/models/performance_issue.dart';

void main() {
  group('KeepAliveDetector', () {
    late KeepAliveDetector detector;

    setUp(() {
      detector = KeepAliveDetector(threshold: 1);
    });

    // HARD GATE: fixture proof — verify KeepAlive nodes materialize
    testWidgets('fixture proof: KeepAlive nodes appear after scrolling',
        (tester) async {
      final controller = PageController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            height: 400,
            width: 400,
            child: PageView(
              controller: controller,
              children: List.generate(
                4,
                (i) => _KeepAlivePage(key: ValueKey(i), label: 'Page $i'),
              ),
            ),
          ),
        ),
      );

      // Visit pages so KeepAlive nodes are created for non-visible pages
      controller.jumpToPage(1);
      await tester.pumpAndSettle();
      controller.jumpToPage(2);
      await tester.pumpAndSettle();
      controller.jumpToPage(3);
      await tester.pumpAndSettle();

      // Go back so keep-alive pages persist in the tree
      controller.jumpToPage(0);
      await tester.pumpAndSettle();

      detector.scanTree(tester.element(find.byType(Directionality)));

      // At least some KeepAlive nodes should exist from visited pages
      expect(detector.issues, isNotEmpty,
          reason: 'KeepAlive nodes should be in the tree after visiting pages');
      expect(detector.issues.first.observationSource,
          ObservationSource.structural);
    });

    testWidgets('no issues when disabled', (tester) async {
      detector.isEnabled = false;
      final controller = PageController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            height: 400,
            width: 400,
            child: PageView(
              controller: controller,
              children: List.generate(
                4,
                (i) => _KeepAlivePage(key: ValueKey(i), label: 'Page $i'),
              ),
            ),
          ),
        ),
      );
      controller.jumpToPage(1);
      await tester.pumpAndSettle();
      controller.jumpToPage(0);
      await tester.pumpAndSettle();

      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, isEmpty);
    });

    testWidgets('flags excessive keep-alive above threshold', (tester) async {
      final controller = PageController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            height: 400,
            width: 400,
            child: PageView(
              controller: controller,
              children: List.generate(
                4,
                (i) => _KeepAlivePage(key: ValueKey(i), label: 'Page $i'),
              ),
            ),
          ),
        ),
      );

      // Visit all pages to create KeepAlive nodes
      for (int i = 1; i < 4; i++) {
        controller.jumpToPage(i);
        await tester.pumpAndSettle();
      }
      controller.jumpToPage(0);
      await tester.pumpAndSettle();

      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.title, contains('Keep-Alive'));
    });

    testWidgets('stableId, confidence, and category', (tester) async {
      final controller = PageController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            height: 400,
            width: 400,
            child: PageView(
              controller: controller,
              children: List.generate(
                4,
                (i) => _KeepAlivePage(key: ValueKey(i), label: 'Page $i'),
              ),
            ),
          ),
        ),
      );
      for (int i = 1; i < 4; i++) {
        controller.jumpToPage(i);
        await tester.pumpAndSettle();
      }
      controller.jumpToPage(0);
      await tester.pumpAndSettle();

      detector.scanTree(tester.element(find.byType(Directionality)));

      final issue = detector.issues.first;
      expect(issue.stableId, 'excessive_keep_alive:0');
      expect(issue.confidence, IssueConfidence.possible);
      expect(issue.category, IssueCategory.memory);
    });

    testWidgets('no issue when below threshold', (tester) async {
      // threshold=1, only visit 1 page → expect ≤1 KeepAlive (may be 1 for
      // the visited page, but also 1 for the current). Use higher threshold.
      detector = KeepAliveDetector(threshold: 10);
      final controller = PageController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            height: 400,
            width: 400,
            child: PageView(
              controller: controller,
              children: List.generate(
                4,
                (i) => _KeepAlivePage(key: ValueKey(i), label: 'Page $i'),
              ),
            ),
          ),
        ),
      );
      for (int i = 1; i < 4; i++) {
        controller.jumpToPage(i);
        await tester.pumpAndSettle();
      }
      controller.jumpToPage(0);
      await tester.pumpAndSettle();

      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, isEmpty);
    });

    testWidgets('critical severity when count > 2x threshold', (tester) async {
      // threshold=1, need >2 KeepAlive nodes for critical.
      // Visit all 4 pages so 3+ KeepAlive nodes persist.
      final controller = PageController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            height: 400,
            width: 400,
            child: PageView(
              controller: controller,
              children: List.generate(
                4,
                (i) => _KeepAlivePage(key: ValueKey(i), label: 'Page $i'),
              ),
            ),
          ),
        ),
      );
      for (int i = 1; i < 4; i++) {
        controller.jumpToPage(i);
        await tester.pumpAndSettle();
      }
      controller.jumpToPage(0);
      await tester.pumpAndSettle();

      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.severity, IssueSeverity.critical);
    });

    testWidgets('highlights emitted when issue detected', (tester) async {
      final controller = PageController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            height: 400,
            width: 400,
            child: PageView(
              controller: controller,
              children: List.generate(
                4,
                (i) => _KeepAlivePage(key: ValueKey(i), label: 'Page $i'),
              ),
            ),
          ),
        ),
      );
      for (int i = 1; i < 4; i++) {
        controller.jumpToPage(i);
        await tester.pumpAndSettle();
      }
      controller.jumpToPage(0);
      await tester.pumpAndSettle();

      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.highlights, isNotEmpty);
      expect(detector.highlights.first.detectorName, 'KeepAlive');
    });

    testWidgets(
        'not flagged when pages wrap in AutomaticKeepAlive with '
        'wantKeepAlive=false', (tester) async {
      // Regression: `AutomaticKeepAlive.build()` ALWAYS wraps children in a
      // `KeepAlive(keepAlive: _keepingAlive, ...)`, even when no descendant
      // has dispatched a KeepAliveNotification. Matching by type name alone
      // (or by the stale `element.widget.keepAlive` field) would count every
      // page in a PageView/TabBarView as a live keep-alive and falsely flag
      // any scrollable with enough tabs. We must read the render object
      // parent data to get the authoritative signal.
      detector = KeepAliveDetector(threshold: 1);
      final controller = PageController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            height: 400,
            width: 400,
            child: PageView(
              controller: controller,
              children: List.generate(
                6,
                (i) => _OptOutKeepAlivePage(key: ValueKey(i), label: 'P$i'),
              ),
            ),
          ),
        ),
      );
      // Visit all pages so their AutomaticKeepAlive wrappers materialize in
      // the element tree (they'd otherwise be lazily built). Pages use a
      // client mixin with `wantKeepAlive => false` so no notification fires
      // and `KeepAliveParentDataMixin.keepAlive` stays false.
      for (int i = 1; i < 6; i++) {
        controller.jumpToPage(i);
        await tester.pumpAndSettle();
      }
      controller.jumpToPage(0);
      await tester.pumpAndSettle();

      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, isEmpty,
          reason: 'inactive KeepAlive wrappers should not be counted');
    });

    testWidgets(
        'mixed wantKeepAlive: only opted-in pages counted toward threshold',
        (tester) async {
      // Mirrors the combined chat demo's "fixed" pattern: a small subset of
      // tabs keep alive, the majority opt out. The detector must count only
      // the opted-in subset, so a reasonable threshold keeps the fixed path
      // silent.
      detector = KeepAliveDetector(threshold: 5);
      final controller = PageController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            height: 400,
            width: 400,
            child: PageView(
              controller: controller,
              children: List.generate(
                6,
                (i) => _ConfigurableKeepAlivePage(
                  key: ValueKey(i),
                  label: 'P$i',
                  keepAlive: i < 2, // only first two opt in
                ),
              ),
            ),
          ),
        ),
      );
      for (int i = 1; i < 6; i++) {
        controller.jumpToPage(i);
        await tester.pumpAndSettle();
      }
      controller.jumpToPage(0);
      await tester.pumpAndSettle();

      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, isEmpty,
          reason: 'only 2 active keep-alives, below threshold of 5');
    });

    testWidgets('not flagged in ListView', (tester) async {
      // KeepAlive in ListView is normal framework behavior — detector only
      // checks PageView/TabBarView.
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            height: 400,
            child: ListView(
              children: List.generate(
                10,
                (i) => _KeepAlivePage(key: ValueKey(i), label: 'Item $i'),
              ),
            ),
          ),
        ),
      );
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, isEmpty);
    });

    testWidgets('dispose clears issues and highlights', (tester) async {
      final controller = PageController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            height: 400,
            width: 400,
            child: PageView(
              controller: controller,
              children: List.generate(
                4,
                (i) => _KeepAlivePage(key: ValueKey(i), label: 'Page $i'),
              ),
            ),
          ),
        ),
      );
      for (int i = 1; i < 4; i++) {
        controller.jumpToPage(i);
        await tester.pumpAndSettle();
      }
      controller.jumpToPage(0);
      await tester.pumpAndSettle();

      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, isNotEmpty);

      detector.dispose();
      expect(detector.issues, isEmpty);
      expect(detector.highlights, isEmpty);
    });

    // -----------------------------------------------------------------
    // Custom thresholds
    // -----------------------------------------------------------------

    testWidgets('higher threshold allows more keep-alive pages',
        (tester) async {
      // threshold: 10 means up to 10 keep-alive pages are acceptable
      detector = KeepAliveDetector(threshold: 10);
      final controller = PageController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            height: 400,
            width: 400,
            child: PageView(
              controller: controller,
              children: List.generate(
                6,
                (i) => _KeepAlivePage(key: ValueKey(i), label: 'Page $i'),
              ),
            ),
          ),
        ),
      );

      // Visit all pages to create KeepAlive nodes
      for (var i = 1; i < 6; i++) {
        controller.jumpToPage(i);
        await tester.pumpAndSettle();
      }
      controller.jumpToPage(0);
      await tester.pumpAndSettle();

      detector.scanTree(tester.element(find.byType(Directionality)));
      // 5 keep-alives (pages 1-5 retained) — below threshold of 10
      expect(detector.issues, isEmpty);
    });

    // -----------------------------------------------------------------
    // v11.17: Subtree cost enrichment
    // -----------------------------------------------------------------

    testWidgets('issue detail contains avg subtree size', (tester) async {
      final controller = PageController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            height: 400,
            width: 400,
            child: PageView(
              controller: controller,
              children: List.generate(
                4,
                (i) => _KeepAlivePage(key: ValueKey(i), label: 'Page $i'),
              ),
            ),
          ),
        ),
      );

      for (int i = 1; i < 4; i++) {
        controller.jumpToPage(i);
        await tester.pumpAndSettle();
      }
      controller.jumpToPage(0);
      await tester.pumpAndSettle();

      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.detail, contains('elements per page'));
      expect(detector.issues.first.detail, contains('total in scrollable'));
    });

    testWidgets('subtree cost increases with heavier page content',
        (tester) async {
      final controller = PageController();
      addTearDown(controller.dispose);

      // Use pages with more complex subtrees
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            height: 400,
            width: 400,
            child: PageView(
              controller: controller,
              children: List.generate(
                4,
                (i) => _HeavyKeepAlivePage(
                    key: ValueKey(i), label: 'Page $i', childCount: 20),
              ),
            ),
          ),
        ),
      );

      for (int i = 1; i < 4; i++) {
        controller.jumpToPage(i);
        await tester.pumpAndSettle();
      }
      controller.jumpToPage(0);
      await tester.pumpAndSettle();

      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues, hasLength(1));
      // Heavy pages should report a larger total element count
      final detail = detector.issues.first.detail;
      final totalMatch =
          RegExp(r'\((\d+) total in scrollable\)').firstMatch(detail);
      expect(totalMatch, isNotNull);
      final totalElements = int.parse(totalMatch!.group(1)!);
      // Each page has 20 SizedBox children + wrapper elements; total should
      // be significantly more than with simple pages.
      expect(totalElements, greaterThan(50));
    });

    // -----------------------------------------------------------------
    // v9.6: Per-scrollable accumulation
    // -----------------------------------------------------------------

    testWidgets('two PageViews each above threshold produce two issues',
        (tester) async {
      final controller1 = PageController();
      final controller2 = PageController();
      addTearDown(controller1.dispose);
      addTearDown(controller2.dispose);

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              SizedBox(
                height: 200,
                width: 400,
                child: PageView(
                  controller: controller1,
                  children: List.generate(
                    4,
                    (i) => _KeepAlivePage(key: ValueKey('a$i'), label: 'A$i'),
                  ),
                ),
              ),
              SizedBox(
                height: 200,
                width: 400,
                child: PageView(
                  controller: controller2,
                  children: List.generate(
                    4,
                    (i) => _KeepAlivePage(key: ValueKey('b$i'), label: 'B$i'),
                  ),
                ),
              ),
            ],
          ),
        ),
      );

      // Visit all pages in both PageViews
      for (int i = 1; i < 4; i++) {
        controller1.jumpToPage(i);
        await tester.pumpAndSettle();
      }
      controller1.jumpToPage(0);
      await tester.pumpAndSettle();

      for (int i = 1; i < 4; i++) {
        controller2.jumpToPage(i);
        await tester.pumpAndSettle();
      }
      controller2.jumpToPage(0);
      await tester.pumpAndSettle();

      detector.scanTree(tester.element(find.byType(Directionality)));

      expect(detector.issues, hasLength(2));
      expect(detector.issues[0].stableId, 'excessive_keep_alive:0');
      expect(detector.issues[1].stableId, 'excessive_keep_alive:1');
    });
  });
}

/// Widget that uses AutomaticKeepAliveClientMixin to create KeepAlive nodes.
class _KeepAlivePage extends StatefulWidget {
  const _KeepAlivePage({super.key, required this.label});
  final String label;

  @override
  State<_KeepAlivePage> createState() => _KeepAlivePageState();
}

class _KeepAlivePageState extends State<_KeepAlivePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Center(child: Text(widget.label));
  }
}

/// Heavier keep-alive page with many child widgets for subtree cost testing.
class _HeavyKeepAlivePage extends StatefulWidget {
  const _HeavyKeepAlivePage({
    super.key,
    required this.label,
    required this.childCount,
  });
  final String label;
  final int childCount;

  @override
  State<_HeavyKeepAlivePage> createState() => _HeavyKeepAlivePageState();
}

class _HeavyKeepAlivePageState extends State<_HeavyKeepAlivePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(
      children: List.generate(
        widget.childCount,
        (i) => SizedBox(height: 5, child: Text('${widget.label}:$i')),
      ),
    );
  }
}

/// Uses `AutomaticKeepAliveClientMixin` but opts OUT of keep-alive by
/// returning `false` from `wantKeepAlive`. `AutomaticKeepAlive` still wraps
/// the child in a `KeepAlive` widget, but its `keepAlive` parent data stays
/// false. The detector must NOT count these.
class _OptOutKeepAlivePage extends StatefulWidget {
  const _OptOutKeepAlivePage({super.key, required this.label});
  final String label;

  @override
  State<_OptOutKeepAlivePage> createState() => _OptOutKeepAlivePageState();
}

class _OptOutKeepAlivePageState extends State<_OptOutKeepAlivePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => false;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Center(child: Text(widget.label));
  }
}

/// Variant where each instance can independently opt in/out of keep-alive.
/// Mirrors the combined chat demo's "fixed" pattern where only a subset of
/// tabs actually requests keep-alive.
class _ConfigurableKeepAlivePage extends StatefulWidget {
  const _ConfigurableKeepAlivePage({
    super.key,
    required this.label,
    required this.keepAlive,
  });
  final String label;
  final bool keepAlive;

  @override
  State<_ConfigurableKeepAlivePage> createState() =>
      _ConfigurableKeepAlivePageState();
}

class _ConfigurableKeepAlivePageState extends State<_ConfigurableKeepAlivePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => widget.keepAlive;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Center(child: Text(widget.label));
  }
}
