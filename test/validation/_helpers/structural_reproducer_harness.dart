// Shared widget-tree scan harness for structural reproducer tests.
//
// Each reproducer mounts a small widget tree under a `Directionality`
// root, then runs the detector's unified walk directly. Returns the
// detector's emitted issues so individual tests can assert on stableId
// presence/absence without duplicating mount + scan scaffolding.
//
// Plumbing only — each reproducer constructs its own detector and widget
// fixtures inline so shared code cannot re-encode detector assumptions.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sleuth/src/models/base_detector.dart';
import 'package:sleuth/src/models/performance_issue.dart';

/// Pumps [body] under a `Directionality` root and drives the detector's
/// unified walk directly on the root element's children.
///
/// Calls `prepareScan` → visitor traversal → `notifyWalkCompleted` →
/// `finalizeScan` without going through `BaseDetector.scanTree`. That
/// bypasses `scanTree`'s `try/catch` so any exception thrown in
/// `checkElement` / `afterElement` / the visitor propagates to the test,
/// instead of being swallowed and emitting a partial-walk `issues` list.
Future<List<PerformanceIssue>> scanAndIssues(
  WidgetTester tester,
  BaseDetector detector,
  Widget body,
) async {
  await tester.pumpWidget(
    Directionality(textDirection: TextDirection.ltr, child: body),
  );
  final root = tester.element(find.byType(Directionality));
  detector.prepareScan(root);
  void visitor(Element element) {
    detector.checkElement(element);
    element.visitChildren(visitor);
    detector.afterElement(element);
  }

  root.visitChildElements(visitor);
  detector.notifyWalkCompleted();
  detector.finalizeScan();
  return detector.issues;
}

/// Convenience assertion: issue with matching stableId is present.
Matcher hasStableId(String stableId) => predicate<List<PerformanceIssue>>(
      (issues) => issues.any((i) => i.stableId == stableId),
      'contains stableId "$stableId"',
    );

/// Convenience assertion: NO issue with matching stableId is present.
Matcher lacksStableId(String stableId) => predicate<List<PerformanceIssue>>(
      (issues) => !issues.any((i) => i.stableId == stableId),
      'does not contain stableId "$stableId"',
    );

/// Convenience: issue with stableId starting with [prefix]. Used for
/// parameterised families like `excessive_keep_alive:<i>`.
Matcher hasStableIdPrefix(String prefix) => predicate<List<PerformanceIssue>>(
      (issues) => issues.any((i) => (i.stableId ?? '').startsWith(prefix)),
      'contains stableId starting with "$prefix"',
    );
