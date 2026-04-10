import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/debug/debug_instrumentation_config.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/ui/floating_issues_card.dart';
import 'package:sleuth/src/ui/issue_card.dart';

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

    testWidgets('NOT shown when isDeepInstrumentationActive is false',
        (tester) async {
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

    testWidgets('shown when isDeepInstrumentationActive is true',
        (tester) async {
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

    testWidgets('NOT shown when deep=true but all sub-flags off',
        (tester) async {
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

  group('IssueCard fidelity annotation', () {
    testWidgets('shows annotation when deep active + debug source',
        (tester) async {
      const issue = PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.build,
        confidence: IssueConfidence.confirmed,
        title: 'Test rebuild issue',
        detail: 'Detail text',
        fixHint: 'Fix hint',
        observationSource: ObservationSource.debugCallback,
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: IssueCard(
                issue: issue,
                deepInstrumentationActive: true,
                initiallyExpanded: true,
              ),
            ),
          ),
        ),
      );

      expect(find.text('Attribution: high fidelity'), findsOneWidget);
      expect(find.text('Timing: overhead present'), findsOneWidget);
    });

    testWidgets('shows annotation for debugCallbackAndStructural source',
        (tester) async {
      const issue = PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.build,
        confidence: IssueConfidence.confirmed,
        title: 'Test combined issue',
        detail: 'Detail text',
        fixHint: 'Fix hint',
        observationSource: ObservationSource.debugCallbackAndStructural,
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: IssueCard(
                issue: issue,
                deepInstrumentationActive: true,
                initiallyExpanded: true,
              ),
            ),
          ),
        ),
      );

      expect(find.text('Attribution: high fidelity'), findsOneWidget);
    });

    testWidgets('NO annotation for structural source', (tester) async {
      const issue = PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.build,
        confidence: IssueConfidence.possible,
        title: 'Structural issue',
        detail: 'Detail text',
        fixHint: 'Fix hint',
        observationSource: ObservationSource.structural,
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: IssueCard(
                issue: issue,
                deepInstrumentationActive: true,
                initiallyExpanded: true,
              ),
            ),
          ),
        ),
      );

      expect(find.text('Attribution: high fidelity'), findsNothing);
    });

    testWidgets('NO annotation for vmTimeline source', (tester) async {
      const issue = PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.raster,
        confidence: IssueConfidence.confirmed,
        title: 'VM issue',
        detail: 'Detail text',
        fixHint: 'Fix hint',
        observationSource: ObservationSource.vmTimeline,
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: IssueCard(
                issue: issue,
                deepInstrumentationActive: true,
                initiallyExpanded: true,
              ),
            ),
          ),
        ),
      );

      expect(find.text('Attribution: high fidelity'), findsNothing);
    });

    testWidgets('NO annotation when deep instrumentation is off',
        (tester) async {
      const issue = PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.build,
        confidence: IssueConfidence.confirmed,
        title: 'Debug issue',
        detail: 'Detail text',
        fixHint: 'Fix hint',
        observationSource: ObservationSource.debugCallback,
      );

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: IssueCard(
                issue: issue,
                deepInstrumentationActive: false,
                initiallyExpanded: true,
              ),
            ),
          ),
        ),
      );

      expect(find.text('Attribution: high fidelity'), findsNothing);
    });
  });
}
