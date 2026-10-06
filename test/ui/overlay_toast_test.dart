import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/ui/overlay_toast.dart';

import '../helpers/overlay_harness.dart';

void main() {
  late OverlayToastController toast;

  setUp(() => toast = OverlayToastController());
  tearDown(() => toast.dispose());

  Widget host() => MaterialApp(
    home: Stack(children: [OverlayToast(controller: toast)]),
  );

  group('OverlayToast', () {
    testWidgets('shows, then fades out after its duration', (tester) async {
      await tester.pumpWidget(host());
      toast.show('Copied');
      await tester.pump();
      expect(find.text('Copied'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 1900));
      expect(find.text('Copied'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('Copied'), findsNothing);
    });

    testWidgets('a new toast replaces the current one and restarts the timer', (
      tester,
    ) async {
      await tester.pumpWidget(host());
      toast.show('First');
      await tester.pump(const Duration(milliseconds: 1500));
      toast.show('Second');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('First'), findsNothing);
      expect(find.text('Second'), findsOneWidget);

      // 1.5 s after the replacement the first timer would have fired.
      await tester.pump(const Duration(milliseconds: 1200));
      expect(find.text('Second'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('Second'), findsNothing);
    });

    testWidgets('the action fires once and dismisses the toast', (
      tester,
    ) async {
      var undone = 0;
      await tester.pumpWidget(host());
      toast.show('Issue hidden', actionLabel: 'Undo', onAction: () => undone++);
      await tester.pump();
      expect(toast.value!.duration, OverlayToastController.actionDuration);

      final model = toast.value!;
      await tester.tap(find.text('Undo'));
      await tester.pump();
      expect(undone, 1);
      // Running the dismissed toast's action again does nothing.
      toast.runAction(model);
      await tester.pump(const Duration(milliseconds: 300));
      expect(undone, 1);
      expect(find.text('Issue hidden'), findsNothing);
    });

    testWidgets("a replaced toast's action never fires", (tester) async {
      var first = 0;
      await tester.pumpWidget(host());
      toast.show('One', actionLabel: 'Undo', onAction: () => first++);
      await tester.pump();
      final stale = toast.value!;
      toast.show('Two');
      await tester.pump();
      toast.runAction(stale);
      expect(first, 0);
      toast.dismiss();
    });

    testWidgets('announces itself as a live region', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(host());
      toast.show('Copied');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        tester.getSemantics(find.text('Copied')),
        matchesSemantics(label: 'Copied', isLiveRegion: true),
      );
      toast.dismiss();
      handle.dispose();
    });

    testWidgets('sits above the keyboard', (tester) async {
      await tester.pumpWidget(host());
      toast.show('Copied');
      await tester.pump();
      final withoutKeyboard = tester.getBottomLeft(find.text('Copied')).dy;

      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.pump();
      final withKeyboard = tester.getBottomLeft(find.text('Copied')).dy;
      expect(
        withKeyboard,
        closeTo(withoutKeyboard - 300 / tester.view.devicePixelRatio, 0.5),
      );
      toast.dismiss();
    });

    testWidgets('dispose cancels the pending timer', (tester) async {
      final local = OverlayToastController();
      local.show('Bye');
      local.dispose();
      // A timer left running would fail the test's pending-timer check.
      await tester.pump(const Duration(seconds: 3));
    });
  });

  group('Held action toasts', () {
    testWidgets('an action toast stays past its time until dismissed', (
      tester,
    ) async {
      await tester.pumpWidget(host());
      toast.holdActions = true;
      toast.show('Issue hidden', actionLabel: 'Undo', onAction: () {});
      await tester.pump();
      expect(toast.value!.held, isTrue);
      await tester.pump(const Duration(seconds: 30));
      expect(find.text('Issue hidden'), findsOneWidget);
      expect(find.text('Undo'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Dismiss'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Issue hidden'), findsNothing);
    });

    testWidgets('a held toast offers a dismiss action to screen readers', (
      tester,
    ) async {
      await tester.pumpWidget(host());
      toast.holdActions = true;
      toast.show('Issue hidden', actionLabel: 'Undo', onAction: () {});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final node = tester.getSemantics(find.text('Issue hidden'));
      expect(
        node.getSemanticsData().hasAction(SemanticsAction.dismiss),
        isTrue,
      );

      tester.binding.renderViews.first.owner!.semanticsOwner!.performAction(
        node.id,
        SemanticsAction.dismiss,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Issue hidden'), findsNothing);
    });

    testWidgets('an Undo toast is used once while held', (tester) async {
      var undone = 0;
      await tester.pumpWidget(host());
      toast.holdActions = true;
      toast.show('Issue hidden', actionLabel: 'Undo', onAction: () => undone++);
      await tester.pump();
      await tester.pump(const Duration(seconds: 10));
      await tester.tap(find.text('Undo'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(undone, 1);
      expect(find.text('Issue hidden'), findsNothing);
    });

    testWidgets('toasts without an action still leave on time', (tester) async {
      await tester.pumpWidget(host());
      toast.holdActions = true;
      toast.show('Copied');
      await tester.pump();
      expect(toast.value!.held, isFalse);
      expect(find.bySemanticsLabel('Dismiss'), findsNothing);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Copied'), findsNothing);
    });

    testWidgets('turning hold off lets a held toast past its time leave', (
      tester,
    ) async {
      await tester.pumpWidget(host());
      toast.holdActions = true;
      toast.show('Issue hidden', actionLabel: 'Undo', onAction: () {});
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      toast.holdActions = false;
      await tester.pump();
      // Still inside its display time.
      expect(find.text('Issue hidden'), findsOneWidget);

      toast.holdActions = true;
      await tester.pump(const Duration(seconds: 10));
      expect(find.text('Issue hidden'), findsOneWidget);
      toast.holdActions = false;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Issue hidden'), findsNothing);
    });
  });

  group('Toast duration scale', () {
    testWidgets('durationScale stretches every display time', (tester) async {
      await tester.pumpWidget(host());
      toast.durationScale = 3;
      toast.show('Copied');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 5900));
      expect(find.text('Copied'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('Copied'), findsNothing);

      toast.show('Hidden', actionLabel: 'Undo', onAction: () {});
      await tester.pump();
      expect(toast.value!.duration, const Duration(seconds: 12));
      toast.dismiss();
    });

    testWidgets('the card keeps toasts at their normal time with semantics '
        'off', (tester) async {
      final controller = await pumpOverlay(
        tester,
        config: const SleuthConfig(treeScanInterval: Duration(hours: 1)),
      );
      await openDashboard(tester, controller);
      await tester.tap(find.byIcon(Icons.brightness_auto));
      await tester.pump();
      expect(find.text('Theme: Light'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Theme: Light'), findsNothing);
    }, semanticsEnabled: false);

    testWidgets('the card triples toasts and holds Undo while semantics is '
        'on without accessible navigation', (tester) async {
      final controller = await pumpOverlay(
        tester,
        config: const SleuthConfig(treeScanInterval: Duration(hours: 1)),
      );
      final issue = mixedOverlayIssues()[2];
      controller.issuesNotifier.value = [issue];
      await openDashboard(tester, controller);
      expect(SemanticsBinding.instance.semanticsEnabled, isTrue);

      await tester.tap(find.bySemanticsLabel('Toggle theme'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      expect(find.text('Theme: Light'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Theme: Light'), findsNothing);

      await tester.tap(find.text(issue.title));
      await tester.pump();
      final hide = find.bySemanticsLabel('Hide this issue');
      await tester.ensureVisible(hide);
      await tester.pumpAndSettle();
      await tester.tap(hide);
      await tester.pump();
      expect(controller.overlayUiState.hiddenKeys, isNotEmpty);
      await tester.pump(const Duration(seconds: 30));
      expect(find.text('Issue hidden'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Dismiss'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Issue hidden'), findsNothing);
      expect(controller.overlayUiState.hiddenKeys, isNotEmpty);
    });

    testWidgets('the card triples toasts while a screen reader is on', (
      tester,
    ) async {
      final controller = await pumpOverlay(
        tester,
        accessibilityFeatures: const FakeAccessibilityFeatures(
          accessibleNavigation: true,
        ),
        config: const SleuthConfig(treeScanInterval: Duration(hours: 1)),
      );
      await openDashboard(tester, controller);
      await tester.tap(find.bySemanticsLabel('Toggle theme'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 5));
      expect(find.text('Theme: Light'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Theme: Light'), findsNothing);
    });
  });
}
