import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/performance_issue.dart';

/// Minimal widget tree for getting a BuildContext that triggers a retained
/// detector (`non_lazy_list` via SingleChildScrollView + Column with >50
/// children).
Widget _minimalApp() => Directionality(
      textDirection: TextDirection.ltr,
      child: SingleChildScrollView(
        child: Column(
          children: List.generate(
            55,
            (i) => SizedBox(key: ValueKey(i), width: 10, height: 10),
          ),
        ),
      ),
    );

FixedScrollMetrics _scrollMetrics() => FixedScrollMetrics(
      minScrollExtent: 0,
      maxScrollExtent: 1000,
      pixels: 0,
      viewportDimension: 600,
      axisDirection: AxisDirection.down,
      devicePixelRatio: 1.0,
    );

ScrollStartNotification _scrollStart(BuildContext context) =>
    ScrollStartNotification(metrics: _scrollMetrics(), context: context);

ScrollEndNotification _scrollEnd(BuildContext context) =>
    ScrollEndNotification(metrics: _scrollMetrics(), context: context);

void main() {
  group('interaction context tracking', () {
    late SleuthController controller;

    setUp(() {
      controller = SleuthController();
      controller.initializeDetectorsForTest();
    });

    tearDown(() {
      controller.dispose();
    });

    group('scroll state', () {
      testWidgets('onScrollActivity sets scrolling on ScrollStartNotification',
          (tester) async {
        await tester.pumpWidget(_minimalApp());
        final ctx = tester.element(find.byType(Directionality));

        expect(controller.interactionStateForTest, InteractionContext.idle);
        controller.onScrollActivity(_scrollStart(ctx));
        expect(
            controller.interactionStateForTest, InteractionContext.scrolling);
      });

      testWidgets(
          'onScrollActivity sets idle after ScrollEndNotification debounce',
          (tester) async {
        await tester.pumpWidget(_minimalApp());
        final ctx = tester.element(find.byType(Directionality));

        controller.onScrollActivity(_scrollStart(ctx));
        expect(
            controller.interactionStateForTest, InteractionContext.scrolling);

        controller.onScrollActivity(_scrollEnd(ctx));
        // Still scrolling (debounce not elapsed)
        expect(
            controller.interactionStateForTest, InteractionContext.scrolling);

        await tester.pump(const Duration(milliseconds: 300));
        expect(controller.interactionStateForTest, InteractionContext.idle);
      });

      testWidgets('rapid scroll start cancels idle debounce timer',
          (tester) async {
        await tester.pumpWidget(_minimalApp());
        final ctx = tester.element(find.byType(Directionality));

        // Start → End → Start before debounce
        controller.onScrollActivity(_scrollStart(ctx));
        controller.onScrollActivity(_scrollEnd(ctx));

        // Before debounce fires, start again
        await tester.pump(const Duration(milliseconds: 100));
        controller.onScrollActivity(_scrollStart(ctx));

        // Wait past the original debounce — should still be scrolling
        await tester.pump(const Duration(milliseconds: 300));
        expect(
            controller.interactionStateForTest, InteractionContext.scrolling);
      });

      testWidgets('scroll notifications ignored during navigating state',
          (tester) async {
        await tester.pumpWidget(_minimalApp());
        final ctx = tester.element(find.byType(Directionality));

        controller.interactionStateForTest = InteractionContext.navigating;
        controller.onScrollActivity(_scrollStart(ctx));
        expect(
            controller.interactionStateForTest, InteractionContext.navigating);
      });
    });

    group('navigation state (real _scanTree path)', () {
      testWidgets(
          '_scanTree sets navigating when two Scaffolds visible (route transition)',
          (tester) async {
        // Two visible Scaffolds → _findVisiblePageContext returns null
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Column(
              children: [
                Expanded(child: Scaffold(body: Container())),
                Expanded(child: Scaffold(body: Container())),
              ],
            ),
          ),
        );

        final root = tester.element(find.byType(Directionality));
        expect(controller.interactionStateForTest, InteractionContext.idle);

        controller.scanTreeFullPathForTest(root);

        expect(
            controller.interactionStateForTest, InteractionContext.navigating);
      });

      testWidgets(
          '_scanTree resets navigating to idle when single Scaffold resolves',
          (tester) async {
        // First: trigger navigating via two Scaffolds
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Column(
              children: [
                Expanded(child: Scaffold(body: Container())),
                Expanded(child: Scaffold(body: Container())),
              ],
            ),
          ),
        );
        controller.scanTreeFullPathForTest(
            tester.element(find.byType(Directionality)));
        expect(
            controller.interactionStateForTest, InteractionContext.navigating);

        // Now: single Scaffold (transition complete)
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Scaffold(
              body: SingleChildScrollView(
                child: Column(
                  children: List.generate(
                    55,
                    (i) => SizedBox(key: ValueKey(i), width: 10, height: 10),
                  ),
                ),
              ),
            ),
          ),
        );
        controller.scanTreeFullPathForTest(
            tester.element(find.byType(Directionality)));

        expect(controller.interactionStateForTest, InteractionContext.idle);
      });

      testWidgets('_scanTree cancels scroll idle timer on navigation',
          (tester) async {
        await tester.pumpWidget(_minimalApp());
        final ctx = tester.element(find.byType(Directionality));

        // Start scrolling, then end (debounce timer starts)
        controller.onScrollActivity(_scrollStart(ctx));
        controller.onScrollActivity(_scrollEnd(ctx));
        expect(
            controller.interactionStateForTest, InteractionContext.scrolling);

        // Trigger navigation via two Scaffolds
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Column(
              children: [
                Expanded(child: Scaffold(body: Container())),
                Expanded(child: Scaffold(body: Container())),
              ],
            ),
          ),
        );
        controller.scanTreeFullPathForTest(
            tester.element(find.byType(Directionality)));
        expect(
            controller.interactionStateForTest, InteractionContext.navigating);

        // Wait past debounce — should still be navigating (timer was cancelled)
        await tester.pump(const Duration(milliseconds: 500));
        expect(
            controller.interactionStateForTest, InteractionContext.navigating);
      });

      testWidgets('no issues aggregated during navigation (scan returns early)',
          (tester) async {
        // First: produce issues via a single-Scaffold tree (Opacity(0.0) triggers detector).
        // _findVisiblePageContext requires exactly one Scaffold to return a valid context.
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Scaffold(
              body: SingleChildScrollView(
                child: Column(
                  children: List.generate(
                    55,
                    (i) => SizedBox(key: ValueKey(i), width: 10, height: 10),
                  ),
                ),
              ),
            ),
          ),
        );
        controller.scanTreeFullPathForTest(
            tester.element(find.byType(Directionality)));
        final beforeIssues = controller.issuesNotifier.value;
        expect(beforeIssues, isNotEmpty);
        expect(beforeIssues.first.interactionContext, InteractionContext.idle);

        // Now: trigger navigation via two Scaffolds — _scanTree returns early
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Column(
              children: [
                Expanded(child: Scaffold(body: Container())),
                Expanded(child: Scaffold(body: Container())),
              ],
            ),
          ),
        );
        controller.scanTreeFullPathForTest(
            tester.element(find.byType(Directionality)));

        // Issues are not re-aggregated during navigation — the notifier
        // still holds the old issues (from before navigation).
        // This verifies that scan-path issues are never stamped with navigating.
        final duringNav = controller.issuesNotifier.value;
        expect(duringNav, isNotEmpty);
        // Old issues still have idle context (from the pre-navigation scan)
        expect(duringNav.first.interactionContext, InteractionContext.idle);
      });
    });

    group('stamping', () {
      testWidgets('interactionContext stamped on aggregated issues',
          (tester) async {
        await tester.pumpWidget(_minimalApp());
        final ctx = tester.element(find.byType(Directionality));

        controller.runTreeScanForTest(ctx);

        final issues = controller.issuesNotifier.value;
        expect(issues, isNotEmpty);
        for (final issue in issues) {
          expect(issue.interactionContext, isNotNull);
        }
      });

      testWidgets('scrolling context stamped when actively scrolling',
          (tester) async {
        await tester.pumpWidget(_minimalApp());
        final ctx = tester.element(find.byType(Directionality));

        controller.interactionStateForTest = InteractionContext.scrolling;
        controller.runTreeScanForTest(ctx);

        final issues = controller.issuesNotifier.value;
        expect(issues, isNotEmpty);
        expect(issues.first.interactionContext, InteractionContext.scrolling);
      });

      testWidgets('idle context stamped when no interaction', (tester) async {
        await tester.pumpWidget(_minimalApp());
        final ctx = tester.element(find.byType(Directionality));

        controller.runTreeScanForTest(ctx);

        final issues = controller.issuesNotifier.value;
        expect(issues, isNotEmpty);
        expect(issues.first.interactionContext, InteractionContext.idle);
      });

      testWidgets('timeline path stamps navigating during transition',
          (tester) async {
        await tester.pumpWidget(_minimalApp());
        final ctx = tester.element(find.byType(Directionality));

        // First produce some issues via scan
        controller.runTreeScanForTest(ctx);
        expect(controller.issuesNotifier.value, isNotEmpty);

        // Simulate navigation starting
        controller.interactionStateForTest = InteractionContext.navigating;

        // Timeline path re-aggregates — should stamp navigating
        controller.aggregateIssuesForTest();

        final issues = controller.issuesNotifier.value;
        expect(issues, isNotEmpty);
        expect(issues.first.interactionContext, InteractionContext.navigating);
      });

      testWidgets('scrolling state change triggers immediate re-aggregation',
          (tester) async {
        await tester.pumpWidget(_minimalApp());
        final ctx = tester.element(find.byType(Directionality));

        // Produce issues with idle context
        controller.runTreeScanForTest(ctx);
        expect(controller.issuesNotifier.value.first.interactionContext,
            InteractionContext.idle);

        // Scroll start should re-aggregate immediately
        controller.onScrollActivity(_scrollStart(ctx));

        // Issues should now have scrolling context (no scan needed)
        expect(controller.issuesNotifier.value.first.interactionContext,
            InteractionContext.scrolling);
      });

      testWidgets('idle debounce triggers immediate re-aggregation',
          (tester) async {
        await tester.pumpWidget(_minimalApp());
        final ctx = tester.element(find.byType(Directionality));

        // Produce issues, then scroll
        controller.runTreeScanForTest(ctx);
        controller.onScrollActivity(_scrollStart(ctx));
        expect(controller.issuesNotifier.value.first.interactionContext,
            InteractionContext.scrolling);

        controller.onScrollActivity(_scrollEnd(ctx));

        // Wait for debounce
        await tester.pump(const Duration(milliseconds: 300));

        // Should be idle now — re-aggregated by the debounce timer
        expect(controller.issuesNotifier.value.first.interactionContext,
            InteractionContext.idle);
      });
    });

    group('keyboard/typing state', () {
      testWidgets('onKeyboardVisibilityChanged sets typing on keyboard show',
          (tester) async {
        await tester.pumpWidget(_minimalApp());
        expect(controller.interactionStateForTest, InteractionContext.idle);

        controller.onKeyboardVisibilityChanged(visible: true);
        expect(controller.interactionStateForTest, InteractionContext.typing);
      });

      testWidgets('typing returns to idle after keyboard hide debounce',
          (tester) async {
        await tester.pumpWidget(_minimalApp());
        controller.onKeyboardVisibilityChanged(visible: true);
        expect(controller.interactionStateForTest, InteractionContext.typing);

        controller.onKeyboardVisibilityChanged(visible: false);
        // Still typing (debounce not elapsed)
        expect(controller.interactionStateForTest, InteractionContext.typing);

        await tester.pump(const Duration(milliseconds: 300));
        expect(controller.interactionStateForTest, InteractionContext.idle);
      });

      testWidgets('typing has priority over scrolling', (tester) async {
        await tester.pumpWidget(_minimalApp());
        final ctx = tester.element(find.byType(Directionality));

        // Start typing
        controller.onKeyboardVisibilityChanged(visible: true);
        expect(controller.interactionStateForTest, InteractionContext.typing);

        // Scroll should NOT downgrade to scrolling
        controller.onScrollActivity(_scrollStart(ctx));
        expect(controller.interactionStateForTest, InteractionContext.typing);
      });

      testWidgets('navigating has priority over typing', (tester) async {
        await tester.pumpWidget(_minimalApp());

        // Navigate first
        controller.interactionStateForTest = InteractionContext.navigating;

        // Keyboard should NOT downgrade from navigating
        controller.onKeyboardVisibilityChanged(visible: true);
        expect(
            controller.interactionStateForTest, InteractionContext.navigating);
      });

      testWidgets('typing context stamped on issues', (tester) async {
        await tester.pumpWidget(_minimalApp());
        final ctx = tester.element(find.byType(Directionality));

        controller.onKeyboardVisibilityChanged(visible: true);
        controller.runTreeScanForTest(ctx);

        final issues = controller.issuesNotifier.value;
        expect(issues, isNotEmpty);
        expect(issues.first.interactionContext, InteractionContext.typing);
      });
    });

    group('app lifecycle state', () {
      test('onAppLifecycleChanged sets appLifecycle on pause', () {
        controller.onAppLifecycleChanged(AppLifecycleState.paused);
        expect(controller.interactionStateForTest,
            InteractionContext.appLifecycle);
      });

      test('onAppLifecycleChanged sets appLifecycle on inactive', () {
        controller.onAppLifecycleChanged(AppLifecycleState.inactive);
        expect(controller.interactionStateForTest,
            InteractionContext.appLifecycle);
      });

      test('onAppLifecycleChanged returns to idle on resume', () {
        controller.onAppLifecycleChanged(AppLifecycleState.paused);
        expect(controller.interactionStateForTest,
            InteractionContext.appLifecycle);

        controller.onAppLifecycleChanged(AppLifecycleState.resumed);
        expect(controller.interactionStateForTest, InteractionContext.idle);
      });

      testWidgets('appLifecycle context stamped on issues', (tester) async {
        await tester.pumpWidget(_minimalApp());
        final ctx = tester.element(find.byType(Directionality));

        // Produce issues
        controller.runTreeScanForTest(ctx);

        // Then background
        controller.onAppLifecycleChanged(AppLifecycleState.paused);

        final issues = controller.issuesNotifier.value;
        expect(issues, isNotEmpty);
        expect(
            issues.first.interactionContext, InteractionContext.appLifecycle);
      });
    });

    group('overlay isolation', () {
      testWidgets('dashboard scroll does not trigger onScrollActivity',
          (tester) async {
        // Verify the NotificationListener scoping: SleuthOverlay wraps only
        // widget.child in a NotificationListener, not the entire Stack.
        // Scrollables outside that scope (like the dashboard ListView) must
        // not trigger the scroll handler.
        //
        // We reproduce the same Stack structure as SleuthOverlay.build:
        // Stack → [NotificationListener(child: appChild), dashboardScrollable]
        var scrollCaptured = false;

        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: Stack(
              children: [
                // App child — under NotificationListener (mirrors overlay)
                NotificationListener<ScrollNotification>(
                  onNotification: (notification) {
                    scrollCaptured = true;
                    return false;
                  },
                  child: const SizedBox(width: 10, height: 10),
                ),
                // Dashboard area — outside NotificationListener scope
                Positioned.fill(
                  child: ListView.builder(
                    itemCount: 50,
                    itemBuilder: (_, i) =>
                        SizedBox(height: 40, child: Text('Item $i')),
                  ),
                ),
              ],
            ),
          ),
        );

        // Scroll the dashboard ListView
        await tester.drag(find.byType(ListView), const Offset(0, -200));
        await tester.pump();

        // Dashboard scroll should NOT reach the NotificationListener
        expect(scrollCaptured, isFalse,
            reason: 'NotificationListener scoped to app child should not '
                'capture scroll events from sibling widgets');
      });
    });

    group('lifecycle', () {
      test('initial state is idle', () {
        expect(controller.interactionStateForTest, InteractionContext.idle);
      });

      testWidgets('scroll idle timer cancelled on dispose', (tester) async {
        // Use a separate controller to avoid double-dispose in tearDown
        final c = SleuthController();
        c.initializeDetectorsForTest();

        await tester.pumpWidget(_minimalApp());
        final ctx = tester.element(find.byType(Directionality));

        // Start a debounce timer
        c.onScrollActivity(_scrollStart(ctx));
        c.onScrollActivity(_scrollEnd(ctx));

        // Dispose should not throw (timer is cancelled)
        c.dispose();

        // Wait past debounce — should not crash
        await tester.pump(const Duration(milliseconds: 500));
      });
    });
  });
}
