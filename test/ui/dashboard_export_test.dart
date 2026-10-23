import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/issue_measurement.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/ui/floating_issues_card.dart';
import 'package:sleuth/src/utils/own_work_log.dart';

import '../helpers/overlay_harness.dart';

void main() {
  group('FloatingIssuesCard export', () {
    late SleuthController controller;

    setUp(() {
      controller = SleuthController();
      controller.initializeDetectorsForTest();
    });

    tearDown(() {
      controller.dispose();
    });

    /// Taps Copy snapshot in the More menu.
    Future<void> copySnapshot(WidgetTester tester) async {
      await openMoreMenu(tester);
      await tester.ensureVisible(moreMenuRow('Copy snapshot'));
      await tester.pump();
      await tester.tap(moreMenuRow('Copy snapshot'));
      await tester.pump();
    }

    Widget buildCard() {
      return MaterialApp(
        home: Scaffold(
          body: FloatingIssuesCard(controller: controller, onClose: () {}),
        ),
      );
    }

    testWidgets('Copy snapshot is in the More menu', (tester) async {
      await tester.pumpWidget(buildCard());
      expect(find.byIcon(Icons.ios_share), findsNothing);
      await openMoreMenu(tester);
      expect(moreMenuRow('Copy snapshot'), findsOneWidget);
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

      await tester.pumpWidget(buildCard());
      await copySnapshot(tester);

      expect(clipboardContent, isNotNull);
      expect(clipboardContent, contains('"capturedFrames"'));
      expect(clipboardContent, contains('"currentIssues"'));

      // Drain the 2s feedback banner timer
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('Copy details carries the Measured sentence', (tester) async {
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
      controller.issuesNotifier.value = const [
        PerformanceIssue(
          severity: IssueSeverity.critical,
          category: IssueCategory.build,
          confidence: IssueConfidence.confirmed,
          title: 'Heavy Computation: 243.7ms',
          detail: 'A long-running operation ran on the UI thread.',
          fixHint: 'Move the work off the UI thread.',
          stableId: 'heavy_compute',
          measurement: IssueMeasurement(
            value: 243.7,
            unit: MeasurementUnit.milliseconds,
            warningAt: 8,
            criticalAt: 16,
          ),
        ),
      ];

      await tester.pumpWidget(buildCard());
      await tester.tap(find.text('Heavy Computation: 243.7ms'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.ensureVisible(find.text('Copy details'));
      await tester.pump();
      await tester.tap(find.text('Copy details'));
      await tester.pump();

      expect(
        clipboardContent,
        contains(
          'Measured: 244 ms in one build on the UI thread. Warning at 8.0 '
          'ms. Critical at 16.0 ms.',
        ),
      );
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('the copy is recorded as Sleuth\'s own work', (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async => null,
      );
      await tester.pumpWidget(buildCard());
      final before = OwnWorkLog.now();

      await copySnapshot(tester);
      expect(ownWorkLog.overlapUs(before, OwnWorkLog.now()), greaterThan(0));
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('a second tap while a copy runs is ignored', (tester) async {
      var copies = 0;
      final release = Completer<void>();
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copies++;
            await release.future;
          }
          return null;
        },
      );
      await tester.pumpWidget(buildCard());
      await copySnapshot(tester);
      await copySnapshot(tester);
      expect(copies, 1);

      release.complete();
      await tester.pump();
      await tester.pump();
      expect(find.text('Snapshot copied to clipboard'), findsOneWidget);
      // The copy ended, so a new tap copies again.
      await tester.pump(const Duration(seconds: 3));
      await copySnapshot(tester);
      expect(copies, 2);
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('a failed copy offers Try again, which copies', (tester) async {
      var fail = true;
      var copies = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            if (fail) throw PlatformException(code: 'denied');
            copies++;
          }
          return null;
        },
      );

      await tester.pumpWidget(buildCard());
      await copySnapshot(tester);
      await tester.pump();
      expect(find.text("Couldn't copy snapshot"), findsOneWidget);

      fail = false;
      await tester.tap(find.text('Try again'));
      await tester.pump();
      await tester.pump();
      expect(copies, 1);
      expect(find.text('Snapshot copied to clipboard'), findsOneWidget);
      await tester.pump(const Duration(seconds: 15));
    });

    testWidgets('feedback banner appears on export tap', (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async => null,
      );

      await tester.pumpWidget(buildCard());
      await copySnapshot(tester);

      expect(find.text('Snapshot copied to clipboard'), findsOneWidget);

      // Drain the 2s feedback banner timer
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('feedback banner disappears after delay', (tester) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async => null,
      );

      await tester.pumpWidget(buildCard());
      await copySnapshot(tester);
      expect(find.text('Snapshot copied to clipboard'), findsOneWidget);

      // Advance past the 2-second delay and the 200 ms fade-out.
      await tester.pump(const Duration(seconds: 3));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Snapshot copied to clipboard'), findsNothing);
      // Semantics on would triple the display time.
    }, semanticsEnabled: false);
  });
}
