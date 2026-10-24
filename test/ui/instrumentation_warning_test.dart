import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/debug/debug_instrumentation_config.dart';
import 'package:sleuth/src/ui/floating_issues_card.dart';

void main() {
  group('instrumentation warning banner', () {
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

    testWidgets('NOT shown when isDeepInstrumentationActive is false', (
      tester,
    ) async {
      final controller = SleuthController();
      controller.initializeDetectorsForTest();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FloatingIssuesCard(
              controller: controller,
              onClose: () {},
              isDebugMode: false,
            ),
          ),
        ),
      );

      expect(find.textContaining('Instrumentation active'), findsNothing);

      controller.dispose();
    });

    testWidgets('shown when isDeepInstrumentationActive is true', (
      tester,
    ) async {
      final controller = SleuthController(
        config: const SleuthConfig(enableDeepDebugInstrumentation: true),
      );
      controller.initializeDetectorsForTest();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FloatingIssuesCard(
              controller: controller,
              onClose: () {},
              isDebugMode: false,
            ),
          ),
        ),
      );

      expect(find.textContaining('Instrumentation active'), findsOneWidget);

      controller.dispose();
    });

    testWidgets('NOT shown when deep=true but all sub-flags off', (
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
      );
      controller.initializeDetectorsForTest();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FloatingIssuesCard(
              controller: controller,
              onClose: () {},
              isDebugMode: false,
            ),
          ),
        ),
      );

      expect(find.textContaining('Instrumentation active'), findsNothing);

      controller.dispose();
    });

    testWidgets('both warnings visible simultaneously', (tester) async {
      final controller = SleuthController(
        config: const SleuthConfig(enableDeepDebugInstrumentation: true),
      );
      controller.initializeDetectorsForTest();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FloatingIssuesCard(
              controller: controller,
              onClose: () {},
              isDebugMode: false,
            ),
          ),
        ),
      );

      // Debug mode warning
      expect(find.textContaining('Debug mode'), findsOneWidget);
      // Instrumentation warning
      expect(find.textContaining('Instrumentation active'), findsOneWidget);

      controller.dispose();
    });
  });
}
