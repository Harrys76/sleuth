import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/ui/floating_issues_card.dart';

void main() {
  testWidgets('a hot reload drops the previous counts for Why it rebuilds', (
    tester,
  ) async {
    final controller = SleuthController(
      config: const SleuthConfig(enableDebugCallbacks: true),
    )..initializeDetectorsForTest();
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    final root = tester.element(find.byType(Scaffold));

    controller
      ..scanTreeFullPathForTest(root)
      ..scanTreeFullPathForTest(root);
    expect(controller.lastDebugSnapshot, isNotNull);

    controller
      ..reassembleForTest()
      ..scanTreeFullPathForTest(root);
    expect(controller.lastDebugSnapshot, isNull);

    controller.scanTreeFullPathForTest(root);
    expect(controller.lastDebugSnapshot, isNotNull);
    // Disposed here: debug callbacks set rendering debug variables that
    // the test binding checks before tear-down.
    controller.dispose();
  });

  testWidgets("a card from another screen does not read this screen's "
      'counts', (tester) async {
    final controller = SleuthController(
      config: const SleuthConfig(enableDebugCallbacks: true),
    )..initializeDetectorsForTest();
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    final root = tester.element(find.byType(Scaffold));
    controller
      ..scanTreeFullPathForTest(root)
      ..scanTreeFullPathForTest(root);
    final screen = controller.lastDebugSnapshotScreen!;

    PerformanceIssue issue(String? route) => PerformanceIssue(
      severity: IssueSeverity.warning,
      category: IssueCategory.build,
      confidence: IssueConfidence.likely,
      title: 'Wide setState Scope',
      detail: 'D',
      fixHint: 'F',
      stableId: 'setstate_scope',
      widgetName: 'DemoScaffold',
      routeName: route,
      scaffoldHashKey: screen.scaffoldHash,
    );

    Future<void> pumpCard(PerformanceIssue shown) async {
      controller.issuesNotifier.value = [shown];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FloatingIssuesCard(
              controller: controller,
              onClose: () {},
              isDebugMode: true,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Wide setState Scope'));
      await tester.pump();
    }

    await pumpCard(issue('/elsewhere'));
    expect(
      find.text("Open this issue's screen to count its rebuilds"),
      findsOneWidget,
    );

    // A fresh card on the snapshot's own screen reads its counts.
    await tester.pumpWidget(const SizedBox());
    await pumpCard(issue(screen.route));
    expect(
      find.text("Open this issue's screen to count its rebuilds"),
      findsNothing,
    );
    expect(find.textContaining('No rebuilds'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    // Disposed here: debug callbacks set rendering debug variables that
    // the test binding checks before tear-down.
    controller.dispose();
  });
}
