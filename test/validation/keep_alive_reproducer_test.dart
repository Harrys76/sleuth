// Hermetic reproducer for [KeepAliveDetector].
//
// Pins the parameterised `excessive_keep_alive:<i>` family via the real
// `scanTree(root)` entry point on a materialised `PageView` with
// `AutomaticKeepAliveClientMixin` pages. Threshold: 1 so small counts
// cross. `_isActiveKeepAlive` reads render-object parent-data — pages
// must be VISITED via PageController navigation for the KeepAlive
// parent-data flag to flip true (stale `element.widget.keepAlive`
// would be false otherwise — see detector comments on the out-of-turn
// parent-data mutation).
//
// Only PageView / TabBarView count (detector filters by widget type).
// ListView/GridView keep-alives are framework-normal and suppressed.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sleuth/sleuth.dart' show IssueConfidence, IssueSeverity;
import 'package:sleuth/src/detectors/keep_alive_detector.dart';

/// Page that opts in to AutomaticKeepAlive.
class _KeepAlivePage extends StatefulWidget {
  const _KeepAlivePage({super.key, required this.label, this.keepAlive = true});
  final String label;
  final bool keepAlive;
  @override
  State<_KeepAlivePage> createState() => _KeepAlivePageState();
}

class _KeepAlivePageState extends State<_KeepAlivePage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => widget.keepAlive;
  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Center(child: Text(widget.label));
  }
}

/// Build a 4-page PageView, visit each page, then return to page 0 so
/// KeepAlive parent-data flips true on the visited pages. Returns the
/// Directionality root for scanTree.
Future<void> _buildAndVisitPageView(
  WidgetTester tester,
  PageController controller, {
  required int pageCount,
  required List<bool> keepAliveFlags,
}) async {
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox(
        height: 400,
        width: 400,
        child: PageView(
          controller: controller,
          children: List.generate(
            pageCount,
            (i) => _KeepAlivePage(
              key: ValueKey(i),
              label: 'Page $i',
              keepAlive: i < keepAliveFlags.length ? keepAliveFlags[i] : true,
            ),
          ),
        ),
      ),
    ),
  );
  for (var i = 1; i < pageCount; i++) {
    controller.jumpToPage(i);
    await tester.pumpAndSettle();
  }
  controller.jumpToPage(0);
  await tester.pumpAndSettle();
}

void main() {
  group('KeepAliveDetector reproducer', () {
    // --- excessive_keep_alive (parameterised) --------------------------

    testWidgets(
        'excessive_keep_alive:<i>: 4-page PageView above threshold=1 '
        'fires (all pages opt in)', (tester) async {
      final detector = KeepAliveDetector(threshold: 1);
      final controller = PageController();
      addTearDown(controller.dispose);
      await _buildAndVisitPageView(tester, controller,
          pageCount: 4, keepAliveFlags: const [true, true, true, true]);
      detector.scanTree(tester.element(find.byType(Directionality)));
      final keepAliveIssues = detector.issues
          .where((i) => (i.stableId ?? '').startsWith('excessive_keep_alive'))
          .toList();
      expect(keepAliveIssues, isNotEmpty,
          reason: 'PageView with 4 visited opt-in pages > threshold=1 '
              'must emit excessive_keep_alive:<i>.');
      // Every emitted stableId starts with the family prefix.
      for (final issue in keepAliveIssues) {
        expect(issue.stableId, startsWith('excessive_keep_alive:'));
      }
      // count=4 > threshold*2 (=2) → critical; structural-only path →
      // possible confidence.
      final first = keepAliveIssues.first;
      expect(first.severity, IssueSeverity.critical);
      expect(first.confidence, IssueConfidence.possible);
    });

    testWidgets(
        'excessive_keep_alive: no PageView → silent '
        '(ListView keep-alives are framework-normal and suppressed)',
        (tester) async {
      final detector = KeepAliveDetector(threshold: 1);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
            height: 400,
            width: 400,
            child: ListView(
              children: List.generate(
                5,
                (i) => _KeepAlivePage(key: ValueKey(i), label: 'Item $i'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, isEmpty,
          reason: 'Only PageView / TabBarView count; ListView ignored.');
    });

    testWidgets(
        'excessive_keep_alive: PageView with all pages opt-OUT silent '
        '(_isActiveKeepAlive returns false)', (tester) async {
      // wantKeepAlive=false across all pages — AutomaticKeepAlive wraps
      // each page's child in a KeepAlive node but the parent-data flag
      // stays false. Detector must count zero.
      final detector = KeepAliveDetector(threshold: 1);
      final controller = PageController();
      addTearDown(controller.dispose);
      await _buildAndVisitPageView(tester, controller,
          pageCount: 4, keepAliveFlags: const [false, false, false, false]);
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, isEmpty,
          reason: 'wantKeepAlive=false → parent-data.keepAlive stays '
              'false → _isActiveKeepAlive rejects.');
    });

    testWidgets(
        'excessive_keep_alive: PageView with mixed opt-in at threshold '
        'stays silent (strict-greater: `> threshold`)', (tester) async {
      // threshold=2, only 2 opt-in pages → count is exactly 2, not > 2.
      final detector = KeepAliveDetector(threshold: 2);
      final controller = PageController();
      addTearDown(controller.dispose);
      await _buildAndVisitPageView(tester, controller,
          pageCount: 4, keepAliveFlags: const [true, true, false, false]);
      detector.scanTree(tester.element(find.byType(Directionality)));
      expect(detector.issues, isEmpty,
          reason: 'Detector uses count > threshold (2 > 2 is false).');
    });
  });
}
