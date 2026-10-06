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

  group('Reduced motion turned on mid-run', () {
    const settings = {
      'reduceMotion': FakeAccessibilityFeatures(reduceMotion: true),
      'disableAnimations': FakeAccessibilityFeatures(disableAnimations: true),
    };

    for (final MapEntry(key: label, value: features) in settings.entries) {
      testWidgets('a running Guide entrance comes to rest at once under '
          '$label', (tester) async {
        await tester.pumpWidget(MaterialApp(home: GuidePage(onClose: () {})));
        await tester.pump(const Duration(milliseconds: 100));
        final page = find.byType(GuidePage);
        expect(fadeOpacities(tester, page).any((o) => o < 1), isTrue);

        setFeatures(tester, features);
        await tester.pump();
        expect(fadeOpacities(tester, page), everyElement(1.0));
        // No ticker left running.
        expect(tester.binding.transientCallbackCount, 0);
      });

      testWidgets('a running toast fade-in finishes at once under $label', (
        tester,
      ) async {
        final toast = OverlayToastController();
        addTearDown(toast.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Stack(children: [OverlayToast(controller: toast)]),
          ),
        );
        toast.show('Copied');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        final fade = fadeOpacities(tester, find.byType(OverlayToast)).single;
        expect(fade, inExclusiveRange(0, 1));

        setFeatures(tester, features);
        await tester.pump();
        expect(fadeOpacities(tester, find.byType(OverlayToast)), [1.0]);
        toast.dismiss();
        await tester.pump();
      });

      testWidgets('a running toast fade-out finishes at once under $label', (
        tester,
      ) async {
        final toast = OverlayToastController();
        addTearDown(toast.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Stack(children: [OverlayToast(controller: toast)]),
          ),
        );
        toast.show('Copied');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        toast.dismiss();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.text('Copied'), findsOneWidget);

        setFeatures(tester, features);
        await tester.pump();
        expect(find.text('Copied'), findsNothing);
      });

      testWidgets('a running animateScrollTo jumps to its end under $label', (
        tester,
      ) async {
        final controller = ScrollController();
        addTearDown(controller.dispose);
        late BuildContext context;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (c) {
                context = c;
                return ListView(
                  controller: controller,
                  children: [
                    for (var i = 0; i < 50; i++)
                      SizedBox(height: 100, child: Text('row $i')),
                  ],
                );
              },
            ),
          ),
        );
        animateScrollTo(
          context,
          controller,
          2000,
          duration: const Duration(seconds: 1),
          curve: Curves.linear,
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(controller.offset, inExclusiveRange(0, 2000));

        setFeatures(tester, features);
        await tester.pump();
        expect(controller.offset, 2000);
        await tester.pump(const Duration(milliseconds: 100));
        expect(controller.offset, 2000);
      });

      testWidgets('a running ensureVisibleWithMotion jumps to its end under '
          '$label', (tester) async {
        final controller = ScrollController();
        addTearDown(controller.dispose);
        final target = GlobalKey();
        late BuildContext context;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (c) {
                context = c;
                return SingleChildScrollView(
                  controller: controller,
                  child: Column(
                    children: [
                      for (var i = 0; i < 50; i++)
                        SizedBox(
                          key: i == 30 ? target : null,
                          height: 100,
                          child: Text('row $i'),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        );
        ensureVisibleWithMotion(
          context,
          target.currentContext!,
          duration: const Duration(seconds: 1),
          curve: Curves.linear,
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(controller.offset, inExclusiveRange(0, 3000));

        setFeatures(tester, features);
        await tester.pump();
        expect(controller.offset, 3000);
        await tester.pump(const Duration(milliseconds: 100));
        expect(controller.offset, 3000);
      });
    }
  });
}
