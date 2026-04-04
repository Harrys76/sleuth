import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/src/controller/watchdog_controller.dart';
import 'package:widget_watchdog/src/models/base_detector.dart';
import 'package:widget_watchdog/src/models/performance_issue.dart';
import 'package:widget_watchdog/src/models/widget_highlight.dart';

void main() {
  group('highlight aggregation', () {
    late WatchdogController controller;

    setUp(() {
      controller = WatchdogController();
      controller.initializeDetectorsForTest();
    });

    tearDown(() {
      controller.dispose();
    });

    testWidgets('Opacity(0.0) highlights flow through to highlightsNotifier',
        (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Opacity(
            opacity: 0.0,
            child: SizedBox(width: 10, height: 10),
          ),
        ),
      );

      controller.runTreeScanForTest(
        tester.element(find.byType(Directionality)),
      );

      // Opacity detector should have found Opacity(0.0) and produced highlights
      final highlights = controller.highlightsNotifier.value.items;
      expect(
        highlights.any((h) => h.detectorName == 'Opacity'),
        isTrue,
        reason:
            'Opacity detector highlights should flow through _collectHighlights',
      );
    });

    testWidgets(
        'GpuPressureDetector highlights flow through to highlightsNotifier',
        (tester) async {
      // Opacity with deep subtree triggers GpuPressureDetector's RenderOpacity detection
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Opacity(
            opacity: 0.5,
            child: Column(
              children: List.generate(
                10,
                (i) => SizedBox(key: ValueKey(i), width: 10, height: 10),
              ),
            ),
          ),
        ),
      );

      controller.runTreeScanForTest(
        tester.element(find.byType(Directionality)),
      );

      final gpuHighlights = controller.highlightsNotifier.value.items
          .where((h) => h.detectorName == 'GPU');
      expect(gpuHighlights, isNotEmpty,
          reason:
              'GPU detector highlights should flow through _collectHighlights');
    });

    testWidgets(
        'disabled detector produces no highlights in highlightsNotifier',
        (tester) async {
      // Disable opacity detector via config
      controller = WatchdogController(
        config: WatchdogConfig(
          enabledDetectors: {
            // Enable everything except opacity
            ...DetectorType.values.where((t) => t != DetectorType.opacity),
          },
        ),
      );
      controller.initializeDetectorsForTest();

      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Opacity(
            opacity: 0.0,
            child: SizedBox(width: 10, height: 10),
          ),
        ),
      );

      controller.runTreeScanForTest(
        tester.element(find.byType(Directionality)),
      );

      final opacityHighlights = controller.highlightsNotifier.value.items
          .where((h) => h.detectorName == 'Opacity');
      expect(opacityHighlights, isEmpty);
    });

    testWidgets('highlights cleared and repopulated on each scan cycle',
        (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Opacity(
            opacity: 0.0,
            child: SizedBox(width: 10, height: 10),
          ),
        ),
      );

      controller.runTreeScanForTest(
        tester.element(find.byType(Directionality)),
      );
      final firstScan = controller.highlightsNotifier.value.items.length;

      controller.runTreeScanForTest(
        tester.element(find.byType(Directionality)),
      );
      final secondScan = controller.highlightsNotifier.value.items.length;

      // Should be repopulated, not accumulated
      expect(secondScan, firstScan);
    });

    testWidgets(
        'detector with issues but no highlights does not pollute highlightsNotifier',
        (tester) async {
      // Build a tree that triggers a structural detector that doesn't produce highlights
      // (e.g., NestedScrollDetector or FontLoadingDetector)
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(width: 10, height: 10),
        ),
      );

      controller.runTreeScanForTest(
        tester.element(find.byType(Directionality)),
      );

      // Simple tree — no highlights expected
      expect(controller.highlightsNotifier.value.items, isEmpty);
    });
  });

  group('selectHighlightForIssue', () {
    late WatchdogController controller;

    setUp(() {
      controller = WatchdogController();
      controller.initializeDetectorsForTest();
    });

    tearDown(() {
      controller.dispose();
    });

    test('matches highlight by widgetName', () {
      controller.highlightsNotifier.value = (
        generation: 1,
        items: [
          const WidgetHighlight(
            rect: Rect.fromLTWH(0, 0, 100, 100),
            widgetName: 'MyWidget',
            severity: IssueSeverity.warning,
            detectorName: 'Test',
            detail: 'test detail',
          ),
        ],
      );

      const issue = PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.build,
        confidence: IssueConfidence.possible,
        title: 'Test',
        detail: 'Test',
        fixHint: 'Test',
        widgetName: 'MyWidget',
      );

      final matched = controller.selectHighlightForIssue(issue);
      expect(matched, isTrue);
      expect(
          controller.selectedHighlightNotifier.value?.widgetName, 'MyWidget');
    });

    test('falls back to detectorName via category mapping', () {
      controller.highlightsNotifier.value = (
        generation: 1,
        items: [
          const WidgetHighlight(
            rect: Rect.fromLTWH(0, 0, 100, 100),
            widgetName: 'SomeWidget',
            severity: IssueSeverity.warning,
            detectorName: 'GPU',
            detail: 'test detail',
          ),
        ],
      );

      const issue = PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.raster,
        confidence: IssueConfidence.possible,
        title: 'Test',
        detail: 'Test',
        fixHint: 'Test',
      );

      final matched = controller.selectHighlightForIssue(issue);
      expect(matched, isTrue);
    });

    test('returns false when no highlights available', () {
      controller.highlightsNotifier.value = (generation: 0, items: []);

      const issue = PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.build,
        confidence: IssueConfidence.possible,
        title: 'Test',
        detail: 'Test',
        fixHint: 'Test',
      );

      final matched = controller.selectHighlightForIssue(issue);
      expect(matched, isFalse);
    });

    test('sets highlightEnabledNotifier to true on match', () {
      controller.highlightEnabledNotifier.value = false;
      controller.highlightsNotifier.value = (
        generation: 1,
        items: [
          const WidgetHighlight(
            rect: Rect.fromLTWH(0, 0, 100, 100),
            widgetName: 'MyWidget',
            severity: IssueSeverity.warning,
            detectorName: 'Test',
            detail: 'test detail',
          ),
        ],
      );

      const issue = PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.build,
        confidence: IssueConfidence.possible,
        title: 'Test',
        detail: 'Test',
        fixHint: 'Test',
        widgetName: 'MyWidget',
      );

      controller.selectHighlightForIssue(issue);
      expect(controller.highlightEnabledNotifier.value, isTrue);
    });

    test('clearSelectedHighlight resets state', () {
      controller.highlightsNotifier.value = (
        generation: 1,
        items: [
          const WidgetHighlight(
            rect: Rect.fromLTWH(0, 0, 100, 100),
            widgetName: 'MyWidget',
            severity: IssueSeverity.warning,
            detectorName: 'Test',
            detail: 'test detail',
          ),
        ],
      );

      const issue = PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.build,
        confidence: IssueConfidence.possible,
        title: 'Test',
        detail: 'Test',
        fixHint: 'Test',
        widgetName: 'MyWidget',
      );

      controller.selectHighlightForIssue(issue);
      expect(controller.selectedHighlightNotifier.value, isNotNull);

      controller.clearSelectedHighlight();
      expect(controller.selectedHighlightNotifier.value, isNull);
      expect(controller.pendingIssueSelection, isNull);
    });
  });

  group('detectorNamesForCategory', () {
    test('layout category maps to Layout and Opacity', () {
      final names =
          WatchdogController.detectorNamesForCategory(IssueCategory.layout);
      expect(names, containsAll(['Layout', 'Opacity']));
    });

    test('raster category maps to GPU', () {
      final names =
          WatchdogController.detectorNamesForCategory(IssueCategory.raster);
      expect(names, contains('GPU'));
    });

    test('build category maps to expected detector names', () {
      final names =
          WatchdogController.detectorNamesForCategory(IssueCategory.build);
      expect(
          names, containsAll(['Non-lazy', 'GlobalKey', 'setState', 'Rebuild']));
    });

    test('paint category maps to expected detector names', () {
      final names =
          WatchdogController.detectorNamesForCategory(IssueCategory.paint);
      expect(names, containsAll(['Painter', 'Repaint']));
    });
  });

  group('routeName stamping', () {
    late WatchdogController controller;

    setUp(() {
      controller = WatchdogController();
      controller.initializeDetectorsForTest();
    });

    tearDown(() {
      controller.dispose();
    });

    testWidgets('issues have null routeName when no ModalRoute in context',
        (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Opacity(
            opacity: 0.0,
            child: SizedBox(width: 10, height: 10),
          ),
        ),
      );

      controller.runTreeScanForTest(
        tester.element(find.byType(Directionality)),
      );

      final issues = controller.issuesNotifier.value;
      expect(issues, isNotEmpty, reason: 'Opacity(0.0) should produce issues');
      for (final issue in issues) {
        expect(issue.routeName, isNull);
      }
    });

    testWidgets('issues stamped with route name from MaterialApp named route',
        (tester) async {
      const pageKey = Key('routeTestPage');
      await tester.pumpWidget(
        MaterialApp(
          initialRoute: '/home',
          routes: {
            '/home': (_) => const Column(
                  key: pageKey,
                  children: [
                    Opacity(
                      opacity: 0.0,
                      child: SizedBox(width: 10, height: 10),
                    ),
                  ],
                ),
          },
        ),
      );

      // Scan from the keyed Column so Opacity is visited as a child
      controller.runTreeScanForTest(
        tester.element(find.byKey(pageKey)),
      );

      final issues = controller.issuesNotifier.value;
      expect(issues, isNotEmpty, reason: 'Opacity(0.0) should produce issues');
      expect(
        issues.any((i) => i.routeName == '/home'),
        isTrue,
        reason: 'Issues should be stamped with the named route',
      );
    });

    testWidgets('debugModeDisclaimer still stamped alongside routeName',
        (tester) async {
      const pageKey = Key('routeTestPage2');
      await tester.pumpWidget(
        MaterialApp(
          initialRoute: '/home',
          routes: {
            '/home': (_) => const Column(
                  key: pageKey,
                  children: [
                    Opacity(
                      opacity: 0.0,
                      child: SizedBox(width: 10, height: 10),
                    ),
                  ],
                ),
          },
        ),
      );

      controller.runTreeScanForTest(
        tester.element(find.byKey(pageKey)),
      );

      final issues = controller.issuesNotifier.value;
      expect(issues, isNotEmpty);
      for (final issue in issues) {
        // In test (debug mode), both should be stamped
        expect(issue.debugModeDisclaimer, isTrue);
        expect(issue.routeName, '/home');
      }
    });

    testWidgets('interactionContext stamped alongside routeName',
        (tester) async {
      const pageKey = Key('routeTestPage3');
      await tester.pumpWidget(
        MaterialApp(
          initialRoute: '/home',
          routes: {
            '/home': (_) => const Column(
                  key: pageKey,
                  children: [
                    Opacity(
                      opacity: 0.0,
                      child: SizedBox(width: 10, height: 10),
                    ),
                  ],
                ),
          },
        ),
      );

      controller.runTreeScanForTest(
        tester.element(find.byKey(pageKey)),
      );

      final issues = controller.issuesNotifier.value;
      expect(issues, isNotEmpty);
      for (final issue in issues) {
        expect(issue.routeName, '/home');
        expect(issue.interactionContext, isNotNull);
        expect(issue.interactionContext, InteractionContext.idle);
      }
    });
  });
}
