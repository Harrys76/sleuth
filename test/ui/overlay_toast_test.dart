import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/ui/overlay_toast.dart';

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
}
