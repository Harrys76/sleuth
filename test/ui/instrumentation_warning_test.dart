import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/debug/debug_instrumentation_config.dart';
import 'package:sleuth/src/ui/floating_issues_card.dart';

void main() {
  group('debug banner instrumentation sentence', () {
    setUp(() {
      assert(() {
        debugOnRebuildDirtyWidget = null;
        debugOnProfilePaint = null;
        return true;
      }());
    });

    tearDown(() {
      assert(() {
        debugOnRebuildDirtyWidget = null;
        debugOnProfilePaint = null;
        return true;
      }());
    });

    Future<void> pump(
      WidgetTester tester,
      SleuthController controller, {
      bool isDebugMode = true,
    }) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FloatingIssuesCard(
            controller: controller,
            onClose: () {},
            isDebugMode: isDebugMode,
          ),
        ),
      ),
    );

    Finder banner() =>
        find.textContaining('Timings run slower', findRichText: true);
    Finder instrumentation() =>
        find.textContaining('Instrumentation is on', findRichText: true);

    testWidgets('left out when deep instrumentation is off', (tester) async {
      final controller = SleuthController()..initializeDetectorsForTest();
      await pump(tester, controller);
      expect(banner(), findsOneWidget);
      expect(instrumentation(), findsNothing);
      controller.dispose();
    });

    testWidgets('added to the one banner when deep instrumentation is on', (
      tester,
    ) async {
      final controller = SleuthController(
        config: const SleuthConfig(enableDeepDebugInstrumentation: true),
      )..initializeDetectorsForTest();
      await pump(tester, controller);
      expect(banner(), findsOneWidget);
      expect(instrumentation(), findsOneWidget);
      controller.dispose();
    });

    testWidgets('left out when every instrumentation flag is off', (
      tester,
    ) async {
      final controller = SleuthController(
        config: const SleuthConfig(
          enableDeepDebugInstrumentation: true,
          advanced: DebugInstrumentationConfig(
            widgetBuildProfiling: false,
            layoutProfiling: false,
            paintProfiling: false,
            timelineEnrichment: false,
          ),
        ),
      )..initializeDetectorsForTest();
      await pump(tester, controller);
      expect(instrumentation(), findsNothing);
      controller.dispose();
    });

    testWidgets('no banner outside a debug run', (tester) async {
      final controller = SleuthController(
        config: const SleuthConfig(enableDeepDebugInstrumentation: true),
      )..initializeDetectorsForTest();
      await pump(tester, controller, isDebugMode: false);
      expect(banner(), findsNothing);
      expect(instrumentation(), findsNothing);
      controller.dispose();
    });
  });
}
