import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/models/frame_stats.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/ui/trigger_button.dart';

void main() {
  Widget wrap(Widget child) {
    return MaterialApp(home: Scaffold(body: child));
  }

  group('TriggerButton', () {
    testWidgets('renders dog emoji', (tester) async {
      final issues = ValueNotifier<List<PerformanceIssue>>([]);
      final vm = ValueNotifier<bool>(false);
      final fps = ValueNotifier<FrameStatsBuffer>(FrameStatsBuffer());

      await tester.pumpWidget(wrap(
        TriggerButton(
          issuesNotifier: issues,
          vmConnectedNotifier: vm,
          frameStatsNotifier: fps,
          isDebugMode: false,
          onTap: () {},
        ),
      ));

      expect(find.text('\u{1F415}'), findsOneWidget);

      issues.dispose();
      vm.dispose();
      fps.dispose();
    });

    testWidgets('tap fires onTap callback', (tester) async {
      var tapped = false;
      final issues = ValueNotifier<List<PerformanceIssue>>([]);
      final vm = ValueNotifier<bool>(false);
      final fps = ValueNotifier<FrameStatsBuffer>(FrameStatsBuffer());

      await tester.pumpWidget(wrap(
        TriggerButton(
          issuesNotifier: issues,
          vmConnectedNotifier: vm,
          frameStatsNotifier: fps,
          isDebugMode: false,
          onTap: () => tapped = true,
        ),
      ));

      await tester.tap(find.text('\u{1F415}'));
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

      await tester.pumpWidget(wrap(
        TriggerButton(
          issuesNotifier: issues,
          vmConnectedNotifier: vm,
          frameStatsNotifier: fps,
          isDebugMode: false,
          onTap: () {},
        ),
      ));

      expect(find.text('3'), findsOneWidget);

      issues.dispose();
      vm.dispose();
      fps.dispose();
    });

    testWidgets('no badge when issues empty', (tester) async {
      final issues = ValueNotifier<List<PerformanceIssue>>([]);
      final vm = ValueNotifier<bool>(false);
      final fps = ValueNotifier<FrameStatsBuffer>(FrameStatsBuffer());

      await tester.pumpWidget(wrap(
        TriggerButton(
          issuesNotifier: issues,
          vmConnectedNotifier: vm,
          frameStatsNotifier: fps,
          isDebugMode: false,
          onTap: () {},
        ),
      ));

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

      await tester.pumpWidget(wrap(
        TriggerButton(
          issuesNotifier: issues,
          vmConnectedNotifier: vm,
          frameStatsNotifier: fps,
          isDebugMode: true,
          onTap: () {},
        ),
      ));

      expect(find.text('\u26A0\uFE0F'), findsOneWidget);

      issues.dispose();
      vm.dispose();
      fps.dispose();
    });

    testWidgets('shows FPS text', (tester) async {
      final issues = ValueNotifier<List<PerformanceIssue>>([]);
      final vm = ValueNotifier<bool>(false);
      final fps = ValueNotifier<FrameStatsBuffer>(FrameStatsBuffer());

      await tester.pumpWidget(wrap(
        TriggerButton(
          issuesNotifier: issues,
          vmConnectedNotifier: vm,
          frameStatsNotifier: fps,
          isDebugMode: false,
          onTap: () {},
        ),
      ));

      // Default FrameStatsBuffer has 0 FPS
      expect(find.text('0'), findsOneWidget);

      issues.dispose();
      vm.dispose();
      fps.dispose();
    });

    testWidgets('initial position adapts to available space', (tester) async {
      final issues = ValueNotifier<List<PerformanceIssue>>([]);
      final vm = ValueNotifier<bool>(false);
      final fps = ValueNotifier<FrameStatsBuffer>(FrameStatsBuffer());

      await tester.pumpWidget(wrap(
        TriggerButton(
          issuesNotifier: issues,
          vmConnectedNotifier: vm,
          frameStatsNotifier: fps,
          isDebugMode: false,
          onTap: () {},
        ),
      ));

      // In test viewport (800×600), the button should be near the right edge.
      // Old hardcoded position was (16, 100) — emoji x would be ~28.
      // Adaptive position targets (maxWidth - 72, maxHeight * 0.4).
      final emojiPos = tester.getTopLeft(find.text('\u{1F415}'));
      expect(emojiPos.dx, greaterThan(100),
          reason: 'Should be right-aligned, not at x=16');

      issues.dispose();
      vm.dispose();
      fps.dispose();
    });

    testWidgets('topRight alignment with default offset matches old position',
        (tester) async {
      final issues = ValueNotifier<List<PerformanceIssue>>([]);
      final vm = ValueNotifier<bool>(false);
      final fps = ValueNotifier<FrameStatsBuffer>(FrameStatsBuffer());

      // 400×800 viewport
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

      // Old position was (maxWidth - 72, maxHeight * 0.4) ≈ (328, 320)
      // New: maxX = 400-56 = 344; anchorX = 344 - 16 = 328
      //      maxY = 800-78 = 722; anchorY = 722 is not right...
      //      top-right means y from top: anchorY = offset.dy = 64
      final emojiPos = tester.getTopLeft(find.text('\u{1F415}'));
      // X should be near right edge (~328)
      expect(emojiPos.dx, greaterThan(300));
      // Y should be near top (~64)
      expect(emojiPos.dy, lessThan(150));

      issues.dispose();
      vm.dispose();
      fps.dispose();
    });

    testWidgets('bottomLeft alignment places button at bottom-left',
        (tester) async {
      final issues = ValueNotifier<List<PerformanceIssue>>([]);
      final vm = ValueNotifier<bool>(false);
      final fps = ValueNotifier<FrameStatsBuffer>(FrameStatsBuffer());

      await tester.pumpWidget(wrap(
        TriggerButton(
          issuesNotifier: issues,
          vmConnectedNotifier: vm,
          frameStatsNotifier: fps,
          isDebugMode: false,
          onTap: () {},
          initialAlignment: Alignment.bottomLeft,
          initialOffset: const Offset(16, 64),
        ),
      ));

      final emojiPos = tester.getTopLeft(find.text('\u{1F415}'));
      // Left side: anchorX = offset.dx = 16
      expect(emojiPos.dx, lessThan(50));
      // Bottom: anchorY = maxY - offset.dy, should be near bottom
      expect(emojiPos.dy, greaterThan(300));

      issues.dispose();
      vm.dispose();
      fps.dispose();
    });

    testWidgets('topLeft with zero offset places button at origin',
        (tester) async {
      final issues = ValueNotifier<List<PerformanceIssue>>([]);
      final vm = ValueNotifier<bool>(false);
      final fps = ValueNotifier<FrameStatsBuffer>(FrameStatsBuffer());

      await tester.pumpWidget(wrap(
        TriggerButton(
          issuesNotifier: issues,
          vmConnectedNotifier: vm,
          frameStatsNotifier: fps,
          isDebugMode: false,
          onTap: () {},
          initialAlignment: Alignment.topLeft,
          initialOffset: Offset.zero,
        ),
      ));

      final emojiPos = tester.getTopLeft(find.text('\u{1F415}'));
      // Should be at (0, 0) — top-left corner
      expect(emojiPos.dx, lessThan(30));
      expect(emojiPos.dy, lessThan(100));

      issues.dispose();
      vm.dispose();
      fps.dispose();
    });

    testWidgets('drag does not crash', (tester) async {
      final issues = ValueNotifier<List<PerformanceIssue>>([]);
      final vm = ValueNotifier<bool>(false);
      final fps = ValueNotifier<FrameStatsBuffer>(FrameStatsBuffer());

      await tester.pumpWidget(wrap(
        TriggerButton(
          issuesNotifier: issues,
          vmConnectedNotifier: vm,
          frameStatsNotifier: fps,
          isDebugMode: false,
          onTap: () {},
        ),
      ));

      await tester.drag(find.text('\u{1F415}'), const Offset(50, 50));
      await tester.pump();
      // No crash after drag = success

      issues.dispose();
      vm.dispose();
      fps.dispose();
    });
  });
}
