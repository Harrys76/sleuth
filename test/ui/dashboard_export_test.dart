import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/src/controller/watchdog_controller.dart';
import 'package:widget_watchdog/src/ui/dashboard_sheet.dart';

void main() {
  group('DashboardSheet export', () {
    late WatchdogController controller;

    setUp(() {
      controller = WatchdogController();
      controller.initializeDetectorsForTest();
    });

    tearDown(() {
      controller.dispose();
    });

    Widget buildDashboard() {
      return MaterialApp(
        home: Scaffold(
          body: DashboardSheet(
            controller: controller,
            onClose: () {},
          ),
        ),
      );
    }

    testWidgets('export button is present in header', (tester) async {
      await tester.pumpWidget(buildDashboard());

      expect(
        find.widgetWithIcon(IconButton, Icons.ios_share),
        findsOneWidget,
      );
    });

    testWidgets('tapping export copies JSON to clipboard', (tester) async {
      // Set up clipboard mock
      String? clipboardContent;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            final args = call.arguments as Map<dynamic, dynamic>;
            clipboardContent = args['text'] as String?;
          }
          return null;
        },
      );

      await tester.pumpWidget(buildDashboard());
      await tester.tap(find.widgetWithIcon(IconButton, Icons.ios_share));
      await tester.pump();

      expect(clipboardContent, isNotNull);
      expect(clipboardContent, contains('"capturedFrames"'));
      expect(clipboardContent, contains('"currentIssues"'));

      // Drain the 2s feedback banner timer
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('feedback banner appears on export tap', (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async => null,
      );

      await tester.pumpWidget(buildDashboard());
      await tester.tap(find.widgetWithIcon(IconButton, Icons.ios_share));
      await tester.pump();

      expect(find.text('Snapshot copied to clipboard'), findsOneWidget);

      // Drain the 2s feedback banner timer
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('feedback banner disappears after delay', (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async => null,
      );

      await tester.pumpWidget(buildDashboard());
      await tester.tap(find.widgetWithIcon(IconButton, Icons.ios_share));
      await tester.pump();
      expect(find.text('Snapshot copied to clipboard'), findsOneWidget);

      // Advance past the 2-second delay
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('Snapshot copied to clipboard'), findsNothing);
    });
  });
}
