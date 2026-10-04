import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/models/frame_stats.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/ui/overlay_ui_state.dart';
import 'package:sleuth/src/ui/trigger_button.dart';

import '../helpers/overlay_harness.dart';

void main() {
  Widget wrap(Widget child) {
    return MaterialApp(home: Scaffold(body: child));
  }

  /// Finds the paw icon — same role as the old emoji/logo finder.
  Finder findLogo() => find.byIcon(Icons.pets);

  group('TriggerButton', () {
    testWidgets('renders bloodhound logo', (tester) async {
      final issues = ValueNotifier<List<PerformanceIssue>>([]);
      final vm = ValueNotifier<bool>(false);
      final fps = ValueNotifier<FrameStatsBuffer>(FrameStatsBuffer());

      await tester.pumpWidget(
        wrap(
          TriggerButton(
            issuesNotifier: issues,
            vmConnectedNotifier: vm,
            frameStatsNotifier: fps,
            isDebugMode: false,
            onTap: () {},
          ),
        ),
      );

      expect(findLogo(), findsOneWidget);

      issues.dispose();
      vm.dispose();
      fps.dispose();
    });

    testWidgets('tap fires onTap callback', (tester) async {
      var tapped = false;
      final issues = ValueNotifier<List<PerformanceIssue>>([]);
      final vm = ValueNotifier<bool>(false);
      final fps = ValueNotifier<FrameStatsBuffer>(FrameStatsBuffer());

      await tester.pumpWidget(
        wrap(
          TriggerButton(
            issuesNotifier: issues,
            vmConnectedNotifier: vm,
            frameStatsNotifier: fps,
            isDebugMode: false,
            onTap: () => tapped = true,
          ),
        ),
      );

      await tester.tap(findLogo());
      expect(tapped, isTrue);

      issues.dispose();
      vm.dispose();
      fps.dispose();
    });

    testWidgets('shows issue count badge when issues present', (tester) async {
      final issues = ValueNotifier<List<PerformanceIssue>>(const [
        PerformanceIssue(
          severity: IssueSeverity.warning,
          category: IssueCategory.build,
          confidence: IssueConfidence.confirmed,
          title: 'Issue 1',
          detail: 'd',
          fixHint: 'f',
          stableId: 'i1',
        ),
        PerformanceIssue(
          severity: IssueSeverity.warning,
          category: IssueCategory.build,
          confidence: IssueConfidence.confirmed,
          title: 'Issue 2',
          detail: 'd',
          fixHint: 'f',
          stableId: 'i2',
        ),
        PerformanceIssue(
          severity: IssueSeverity.critical,
          category: IssueCategory.paint,
          confidence: IssueConfidence.likely,
          title: 'Issue 3',
          detail: 'd',
          fixHint: 'f',
          stableId: 'i3',
        ),
      ]);
      final vm = ValueNotifier<bool>(false);
      final fps = ValueNotifier<FrameStatsBuffer>(FrameStatsBuffer());

      await tester.pumpWidget(
        wrap(
          TriggerButton(
            issuesNotifier: issues,
            vmConnectedNotifier: vm,
            frameStatsNotifier: fps,
            isDebugMode: false,
            onTap: () {},
          ),
        ),
      );

      expect(find.text('3'), findsOneWidget);

      issues.dispose();
      vm.dispose();
      fps.dispose();
    });

    testWidgets('no badge when issues empty', (tester) async {
      final issues = ValueNotifier<List<PerformanceIssue>>([]);
      final vm = ValueNotifier<bool>(false);
      final fps = ValueNotifier<FrameStatsBuffer>(FrameStatsBuffer());

      await tester.pumpWidget(
        wrap(
          TriggerButton(
            issuesNotifier: issues,
            vmConnectedNotifier: vm,
            frameStatsNotifier: fps,
            isDebugMode: false,
            onTap: () {},
          ),
        ),
      );

      // Badge count '3' from the previous test case should not appear.
      // '0' does appear as the FPS text, but that's not a badge.
      expect(find.text('3'), findsNothing);
      expect(find.text('1'), findsNothing);

      issues.dispose();
      vm.dispose();
      fps.dispose();
    });

    testWidgets('shows debug warning badge in debug mode', (tester) async {
      final issues = ValueNotifier<List<PerformanceIssue>>([]);
      final vm = ValueNotifier<bool>(false);
      final fps = ValueNotifier<FrameStatsBuffer>(FrameStatsBuffer());

      await tester.pumpWidget(
        wrap(
          TriggerButton(
            issuesNotifier: issues,
            vmConnectedNotifier: vm,
            frameStatsNotifier: fps,
            isDebugMode: true,
            onTap: () {},
          ),
        ),
      );

      expect(find.text('\u26A0\uFE0F'), findsOneWidget);

      issues.dispose();
      vm.dispose();
      fps.dispose();
    });

    testWidgets('shows FPS text', (tester) async {
      final issues = ValueNotifier<List<PerformanceIssue>>([]);
      final vm = ValueNotifier<bool>(false);
      final fps = ValueNotifier<FrameStatsBuffer>(FrameStatsBuffer());

      await tester.pumpWidget(
        wrap(
          TriggerButton(
            issuesNotifier: issues,
            vmConnectedNotifier: vm,
            frameStatsNotifier: fps,
            isDebugMode: false,
            onTap: () {},
          ),
        ),
      );

      // v0.17.0: empty buffer → warm-up placeholder while windowSampleCount
      // is below the 3-frame threshold. The trigger shows '—' instead of
      // flashing red '0 FPS'.
      expect(find.text('—'), findsOneWidget);

      issues.dispose();
      vm.dispose();
      fps.dispose();
    });

    testWidgets('initial position adapts to available space', (tester) async {
      final issues = ValueNotifier<List<PerformanceIssue>>([]);
      final vm = ValueNotifier<bool>(false);
      final fps = ValueNotifier<FrameStatsBuffer>(FrameStatsBuffer());

      await tester.pumpWidget(
        wrap(
          TriggerButton(
            issuesNotifier: issues,
            vmConnectedNotifier: vm,
            frameStatsNotifier: fps,
            isDebugMode: false,
            onTap: () {},
          ),
        ),
      );

      // In test viewport (800x600), the button should be near the right edge.
      final logoPos = tester.getTopLeft(findLogo());
      expect(
        logoPos.dx,
        greaterThan(100),
        reason: 'Should be right-aligned, not at x=16',
      );

      issues.dispose();
      vm.dispose();
      fps.dispose();
    });

    testWidgets('topRight alignment with default offset matches old position', (
      tester,
    ) async {
      final issues = ValueNotifier<List<PerformanceIssue>>([]);
      final vm = ValueNotifier<bool>(false);
      final fps = ValueNotifier<FrameStatsBuffer>(FrameStatsBuffer());

      // 400x800 viewport
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(size: Size(400, 800)),
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: const MediaQueryData(size: Size(400, 800)),
              child: child!,
            ),
            home: Scaffold(
              body: TriggerButton(
                issuesNotifier: issues,
                vmConnectedNotifier: vm,
                frameStatsNotifier: fps,
                isDebugMode: false,
                onTap: () {},
                initialAlignment: Alignment.topRight,
                initialOffset: const Offset(16, 64),
              ),
            ),
          ),
        ),
      );

      final logoPos = tester.getTopLeft(findLogo());
      // X should be near right edge (~328)
      expect(logoPos.dx, greaterThan(300));
      // Y should be near top (~64)
      expect(logoPos.dy, lessThan(150));

      issues.dispose();
      vm.dispose();
      fps.dispose();
    });

    testWidgets('bottomLeft alignment places button at bottom-left', (
      tester,
    ) async {
      final issues = ValueNotifier<List<PerformanceIssue>>([]);
      final vm = ValueNotifier<bool>(false);
      final fps = ValueNotifier<FrameStatsBuffer>(FrameStatsBuffer());

      await tester.pumpWidget(
        wrap(
          TriggerButton(
            issuesNotifier: issues,
            vmConnectedNotifier: vm,
            frameStatsNotifier: fps,
            isDebugMode: false,
            onTap: () {},
            initialAlignment: Alignment.bottomLeft,
            initialOffset: const Offset(16, 64),
          ),
        ),
      );

      final logoPos = tester.getTopLeft(findLogo());
      // Left side: anchorX = offset.dx = 16
      expect(logoPos.dx, lessThan(50));
      // Bottom: anchorY = maxY - offset.dy, should be near bottom
      expect(logoPos.dy, greaterThan(300));

      issues.dispose();
      vm.dispose();
      fps.dispose();
    });

    testWidgets('topLeft with zero offset places button at origin', (
      tester,
    ) async {
      final issues = ValueNotifier<List<PerformanceIssue>>([]);
      final vm = ValueNotifier<bool>(false);
      final fps = ValueNotifier<FrameStatsBuffer>(FrameStatsBuffer());

      await tester.pumpWidget(
        wrap(
          TriggerButton(
            issuesNotifier: issues,
            vmConnectedNotifier: vm,
            frameStatsNotifier: fps,
            isDebugMode: false,
            onTap: () {},
            initialAlignment: Alignment.topLeft,
            initialOffset: Offset.zero,
          ),
        ),
      );

      final logoPos = tester.getTopLeft(findLogo());
      // Should be at (0, 0) — top-left corner
      expect(logoPos.dx, lessThan(30));
      expect(logoPos.dy, lessThan(100));

      issues.dispose();
      vm.dispose();
      fps.dispose();
    });

    testWidgets('drag does not crash', (tester) async {
      final issues = ValueNotifier<List<PerformanceIssue>>([]);
      final vm = ValueNotifier<bool>(false);
      final fps = ValueNotifier<FrameStatsBuffer>(FrameStatsBuffer());

      await tester.pumpWidget(
        wrap(
          TriggerButton(
            issuesNotifier: issues,
            vmConnectedNotifier: vm,
            frameStatsNotifier: fps,
            isDebugMode: false,
            onTap: () {},
          ),
        ),
      );

      await tester.drag(findLogo(), const Offset(50, 50));
      await tester.pump();
      // No crash after drag = success

      issues.dispose();
      vm.dispose();
      fps.dispose();
    });
  });

  group('TriggerButton safe area', () {
    late ValueNotifier<List<PerformanceIssue>> issues;
    late ValueNotifier<bool> vm;
    late ValueNotifier<FrameStatsBuffer> fps;
    late OverlayUiState state;

    setUp(() {
      issues = ValueNotifier<List<PerformanceIssue>>([]);
      vm = ValueNotifier<bool>(false);
      fps = ValueNotifier<FrameStatsBuffer>(FrameStatsBuffer());
      state = OverlayUiState();
    });

    tearDown(() {
      issues.dispose();
      vm.dispose();
      fps.dispose();
      state.dispose();
    });

    void setView(
      WidgetTester tester, {
      Size size = const Size(400, 800),
      double top = 0,
      double bottom = 0,
      double keyboard = 0,
    }) {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      tester.view.padding = FakeViewPadding(top: top, bottom: bottom);
      tester.view.viewPadding = FakeViewPadding(top: top, bottom: bottom);
      tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
      addTearDown(tester.view.reset);
    }

    Widget app({Alignment alignment = Alignment.topRight}) => MaterialApp(
      home: TriggerButton(
        issuesNotifier: issues,
        vmConnectedNotifier: vm,
        frameStatsNotifier: fps,
        isDebugMode: false,
        uiState: state,
        initialAlignment: alignment,
        onTap: () {},
      ),
    );

    Rect buttonRect(WidgetTester tester) =>
        tester.getRect(find.byType(GestureDetector).first);

    testWidgets('drags past the insets stay clear of notch, home indicator '
        'and keyboard', (tester) async {
      setView(tester, top: 59, bottom: 34, keyboard: 100);
      await tester.pumpWidget(app());

      await tester.drag(find.byIcon(Icons.pets), const Offset(0, -2000));
      await tester.pump();
      expect(buttonRect(tester).top, greaterThanOrEqualTo(59));

      await tester.drag(find.byIcon(Icons.pets), const Offset(0, 4000));
      await tester.pump();
      expect(buttonRect(tester).bottom, lessThanOrEqualTo(800 - 100));
    });

    for (final alignment in [Alignment.topRight, Alignment.bottomLeft]) {
      testWidgets('$alignment placement stays inside the view padding', (
        tester,
      ) async {
        setView(tester, top: 59, bottom: 34);
        await tester.pumpWidget(app(alignment: alignment));
        final rect = buttonRect(tester);
        expect(rect.top, greaterThanOrEqualTo(59));
        expect(rect.bottom, lessThanOrEqualTo(800 - 34));
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(400));
        // Inset by the configured offset from the padded edges.
        if (alignment == Alignment.topRight) {
          expect(rect.top, 59 + 64);
          expect(rect.right, 400 - 16);
        } else {
          expect(rect.bottom, 800 - 34 - 64);
          expect(rect.left, 16);
        }
      });
    }

    test('the stored anchor does not depend on the keyboard', () {
      TriggerBounds bounds(double keyboard) => TriggerBounds(
        area: const Size(400, 800),
        button: const Size(56, 80),
        viewPadding: const EdgeInsets.only(top: 59, bottom: 34),
        keyboardInset: keyboard,
        margin: 16,
      );
      for (final p in const [Offset(150, 300), Offset(180, 500)]) {
        expect(bounds(300).anchorFor(p), bounds(0).anchorFor(p));
      }
      // Edge split at the middle of the anchored (keyboard-free) rect.
      final b = bounds(0);
      final mid = b.anchored.center.dx;
      expect(b.anchorFor(Offset(mid - 1, 300)).edge, TriggerEdge.left);
      expect(b.anchorFor(Offset(mid + 1, 300)).edge, TriggerEdge.right);
    });

    testWidgets('drag end snaps to the nearest horizontal edge', (
      tester,
    ) async {
      setView(tester);
      await tester.pumpWidget(app());

      // Default placement is top-right; drag well past the middle.
      await tester.drag(find.byIcon(Icons.pets), const Offset(-300, 200));
      await tester.pump();
      expect(state.triggerAnchor!.edge, TriggerEdge.left);
      expect(buttonRect(tester).left, 16);
    });

    testWidgets('a tiny viewport with large insets does not throw', (
      tester,
    ) async {
      setView(
        tester,
        size: const Size(300, 300),
        top: 100,
        bottom: 100,
        keyboard: 100,
      );
      await tester.pumpWidget(app());
      await tester.drag(find.byIcon(Icons.pets), const Offset(-500, 500));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(state.triggerAnchor!.fraction.isFinite, isTrue);
    });

    testWidgets('rotation keeps the edge and the fraction', (tester) async {
      setView(tester, size: const Size(400, 800));
      state.triggerAnchor = (edge: TriggerEdge.left, fraction: 0.5);
      await tester.pumpWidget(app());
      final portrait = buttonRect(tester);
      expect(portrait.left, 16);

      tester.view.physicalSize = const Size(800, 400);
      await tester.pump();
      final landscape = buttonRect(tester);
      expect(landscape.left, 16);
      expect(state.triggerAnchor, (edge: TriggerEdge.left, fraction: 0.5));
      // Same fraction of the anchored vertical range in both orientations.
      double fractionOf(Rect r, double height) =>
          (r.top - 16) / (height - r.height - 32);
      expect(fractionOf(portrait, 800), closeTo(0.5, 0.01));
      expect(fractionOf(landscape, 400), closeTo(0.5, 0.01));
    });

    testWidgets('semantics label carries the visible issue count', (
      tester,
    ) async {
      setView(tester);
      issues.value = const [
        PerformanceIssue(
          severity: IssueSeverity.warning,
          category: IssueCategory.build,
          confidence: IssueConfidence.confirmed,
          title: 'one',
          detail: 'd',
          fixHint: 'f',
          stableId: 'one',
        ),
        PerformanceIssue(
          severity: IssueSeverity.critical,
          category: IssueCategory.build,
          confidence: IssueConfidence.confirmed,
          title: 'two',
          detail: 'd',
          fixHint: 'f',
          stableId: 'two',
        ),
      ];
      await tester.pumpWidget(app());
      expect(find.bySemanticsLabel('Open Sleuth, 2 issues'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);

      state.hide('two');
      await tester.pump();
      expect(find.bySemanticsLabel('Open Sleuth, 1 issue'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
    });

    testWidgets('the overlay keeps the trigger position across open and '
        'close', (tester) async {
      final controller = await pumpOverlay(tester);
      await tester.drag(find.byIcon(Icons.pets), const Offset(-400, 150));
      await tester.pump();
      final before = tester.getTopLeft(find.byIcon(Icons.pets));
      expect(controller.overlayUiState.triggerAnchor, isNotNull);

      await openDashboard(tester, controller);
      expect(find.byIcon(Icons.pets), findsWidgets); // card header paw
      controller.overlayUiState.dashboardOpen = false;
      await tester.pump();
      expect(tester.getTopLeft(find.byIcon(Icons.pets)), before);
    });
  });
}
