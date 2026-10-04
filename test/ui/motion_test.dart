import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/ui/guide_page.dart';
import 'package:sleuth/src/ui/issue_encyclopedia_page.dart';
import 'package:sleuth/src/ui/motion.dart';
import 'package:sleuth/src/ui/overlay_toast.dart';
import 'package:sleuth/src/ui/rebuild_stats_page.dart';

void setFeatures(WidgetTester tester, FakeAccessibilityFeatures features) {
  tester.platformDispatcher.accessibilityFeaturesTestValue = features;
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
}

/// Opacity of every [FadeTransition] below [page].
List<double> fadeOpacities(WidgetTester tester, Finder page) => tester
    .widgetList<FadeTransition>(
      find.descendant(of: page, matching: find.byType(FadeTransition)),
    )
    .map((fade) => fade.opacity.value)
    .toList();

void main() {
  const normal = Duration(milliseconds: 250);

  group('motionDuration', () {
    Future<BuildContext> capture(WidgetTester tester) async {
      late BuildContext captured;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              captured = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      return captured;
    }

    testWidgets('is the normal duration with both flags off', (tester) async {
      final context = await capture(tester);
      expect(reducedMotionOf(context), isFalse);
      expect(motionDuration(context, normal), normal);
    });

    testWidgets('is zero under disableAnimations', (tester) async {
      setFeatures(
        tester,
        const FakeAccessibilityFeatures(disableAnimations: true),
      );
      final context = await capture(tester);
      expect(reducedMotionOf(context), isTrue);
      expect(motionDuration(context, normal), Duration.zero);
    });

    testWidgets('is zero under iOS reduceMotion', (tester) async {
      setFeatures(tester, const FakeAccessibilityFeatures(reduceMotion: true));
      final context = await capture(tester);
      // MediaQueryData carries only disableAnimations.
      expect(MediaQuery.disableAnimationsOf(context), isFalse);
      expect(reducedMotionOf(context), isTrue);
      expect(motionDuration(context, normal), Duration.zero);
    });

    testWidgets('an app MediaQuery with disableAnimations is enough', (
      tester,
    ) async {
      late BuildContext captured;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Builder(
            builder: (context) {
              captured = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(motionDuration(captured, normal), Duration.zero);
    });
  });

  group('Page entrances', () {
    final pages = <String, Widget Function()>{
      'GuidePage': () => GuidePage(onClose: () {}),
      'IssueEncyclopediaPage': () => IssueEncyclopediaPage(onClose: () {}),
      'RebuildStatsPage': () => RebuildStatsPage(
        routeDisplayName: '/home',
        countsByType: const {'ProductCard': 5},
        onClose: () {},
      ),
    };

    for (final MapEntry(key: name, value: build) in pages.entries) {
      testWidgets('$name animates in with motion on', (tester) async {
        await tester.pumpWidget(MaterialApp(home: build()));
        final opacities = fadeOpacities(tester, find.byType(MaterialApp));
        expect(opacities, isNotEmpty);
        expect(opacities.any((o) => o < 1), isTrue);
      });

      for (final MapEntry(key: label, value: features) in const {
        'reduceMotion': FakeAccessibilityFeatures(reduceMotion: true),
        'disableAnimations': FakeAccessibilityFeatures(disableAnimations: true),
      }.entries) {
        testWidgets('$name is fully in after one pump under $label', (
          tester,
        ) async {
          setFeatures(tester, features);
          await tester.pumpWidget(MaterialApp(home: build()));
          final opacities = fadeOpacities(tester, find.byType(MaterialApp));
          expect(opacities, isNotEmpty);
          expect(opacities, everyElement(1.0));
        });
      }
    }
  });

  group('Toast fade', () {
    testWidgets('shows and leaves at once under reduceMotion', (tester) async {
      setFeatures(tester, const FakeAccessibilityFeatures(reduceMotion: true));
      final toast = OverlayToastController();
      addTearDown(toast.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Stack(children: [OverlayToast(controller: toast)]),
        ),
      );
      toast.show('Copied');
      await tester.pump();
      expect(fadeOpacities(tester, find.byType(OverlayToast)), [1.0]);
      expect(tester.binding.hasScheduledFrame, isFalse);

      toast.dismiss();
      await tester.pump();
      expect(find.text('Copied'), findsNothing);
    });
  });
}
