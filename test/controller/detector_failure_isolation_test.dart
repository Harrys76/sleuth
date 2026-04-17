import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/base_detector.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/models/widget_highlight.dart';

import '../helpers/benchmark_helpers.dart';

/// Config that disables built-in structural detectors so the injected
/// [_FailingDetector] is the only non-runtime detector running during the
/// unified walk.
const _minimalConfig = SleuthConfig(
  treeScanInterval: Duration(seconds: 1),
  enabledDetectors: {DetectorType.frameTiming},
);

/// Stages at which [_FailingDetector] can be configured to throw.
enum _FailStage {
  prepareScan,
  checkElement,
  afterElement,
  notifyWalkCompleted,
  finalizeScan,
}

class _FailingDetector extends BaseDetector {
  _FailingDetector(this.failAt)
      : super(
          // Non-custom type so the controller routes this detector through
          // the unified walk (not the legacy scanTree path).
          type: DetectorType.layoutBottleneck,
          lifecycle: DetectorLifecycle.structural,
          name: 'FailingDetector(${failAt.name})',
          description: 'Test double that throws in ${failAt.name}.',
        );

  final _FailStage failAt;

  int prepareScanCalls = 0;
  int checkElementCalls = 0;
  int afterElementCalls = 0;
  int notifyWalkCompletedCalls = 0;
  int finalizeScanCalls = 0;

  bool isEnabledField = true;

  @override
  bool get isEnabled => isEnabledField;

  @override
  set isEnabled(bool value) => isEnabledField = value;

  @override
  List<PerformanceIssue> get issues => const [];

  @override
  List<WidgetHighlight> get highlights => const [];

  @override
  void dispose() {}

  @override
  void prepareScan(BuildContext context) {
    prepareScanCalls++;
    if (failAt == _FailStage.prepareScan) {
      throw StateError('boom in prepareScan');
    }
  }

  @override
  void checkElement(Element element) {
    checkElementCalls++;
    if (failAt == _FailStage.checkElement) {
      throw StateError('boom in checkElement');
    }
  }

  @override
  void afterElement(Element element) {
    afterElementCalls++;
    if (failAt == _FailStage.afterElement) {
      throw StateError('boom in afterElement');
    }
  }

  @override
  void notifyWalkCompleted() {
    notifyWalkCompletedCalls++;
    if (failAt == _FailStage.notifyWalkCompleted) {
      throw StateError('boom in notifyWalkCompleted');
    }
  }

  @override
  void finalizeScan() {
    finalizeScanCalls++;
    if (failAt == _FailStage.finalizeScan) {
      throw StateError('boom in finalizeScan');
    }
  }
}

/// Captures every [FlutterErrorDetails] routed through
/// [FlutterError.onError] for the duration of a scan. Installed *inside* the
/// test body (after `pumpWidget`) so the TestWidgetsFlutterBinding-installed
/// handler is the one being replaced, not the default. Restored before the
/// test ends so the binding's own teardown semantics still work.
///
/// Forwards every captured detail to the previously-installed handler
/// (`_previous?.call(details)`) so TestWidgetsFlutterBinding can still see
/// errors the test did not originate — without the forward, unrelated
/// framework errors (layout overflow, offstage assertions) would be
/// swallowed silently, hiding regressions in a separate failure mode
/// (advanced-adversarial-review Round 3, v0.16.0).
class _ScopedErrorCapture {
  _ScopedErrorCapture() : _previous = FlutterError.onError {
    FlutterError.onError = (FlutterErrorDetails details) {
      captured.add(details);
      _previous?.call(details);
    };
  }

  final List<FlutterErrorDetails> captured = [];
  final FlutterExceptionHandler? _previous;

  void restore() {
    FlutterError.onError = _previous;
  }
}

void main() {
  group('v0.16.0 F3 — detector failures route through FlutterError.reportError',
      () {
    for (final stage in _FailStage.values) {
      testWidgets('throw in ${stage.name} → FlutterError.reportError fires',
          (tester) async {
        await tester.pumpWidget(buildMixedTree(20));
        final context = tester.element(find.byType(Directionality));

        final controller = SleuthController(config: _minimalConfig);
        controller.initializeDetectorsForTest();
        final failing = _FailingDetector(stage);
        controller.addDetectorForTest(failing);

        final errors = _ScopedErrorCapture();
        try {
          controller.runTreeScanForTest(context);
        } finally {
          errors.restore();
        }

        // Advanced-adversarial-review Round 3 convergence: strict dual
        // assertion replaces the loose `isNotEmpty` check.
        //
        // (a) `matching.length == 1` — exactly one sleuth-library error
        //     for this stage. A regression that fires a duplicate from
        //     both the stage wrapper and the outer tree-walk catch would
        //     flip this to 2 and fail the test. `isNotEmpty` would pass.
        //
        // (b) `nonMatching` is empty — no non-sleuth errors fired during
        //     the scan. `_ScopedErrorCapture` forwards every detail to
        //     the binding's previous handler, so unrelated regressions
        //     (layout overflow, offstage assert) are also visible at
        //     teardown; this in-test assertion surfaces them as
        //     per-stage noise instead of a generic teardown failure.
        final matching = errors.captured
            .where((e) =>
                e.library == 'sleuth' &&
                e.context?.toDescription().contains(stage.name) == true &&
                e.exception is StateError)
            .toList();
        final nonMatching =
            errors.captured.where((e) => e.library != 'sleuth').toList();
        expect(
          matching.length,
          1,
          reason: 'Expected exactly one FlutterError.reportError under '
              'library "sleuth" for stage ${stage.name}, got '
              '${matching.length}. Duplicate-fire regression?',
        );
        expect(
          nonMatching,
          isEmpty,
          reason: 'Unrelated framework errors fired during the ${stage.name} '
              'scan: ${nonMatching.map((e) => e.exception).toList()}. '
              'This test must not pass while other errors leak — fix the '
              'underlying regression or narrow the capture scope.',
        );

        // Drain the sleuth-library exception the capture forwarded to the
        // binding's pending-exception list so teardown does not fail with
        // "Test completed with pending exceptions". `tester.takeException()`
        // consumes the single sleuth error we asserted above.
        final drained = tester.takeException();
        expect(drained, isA<StateError>(),
            reason: 'Expected the forwarded sleuth StateError to land in '
                'the binding\'s pending-exception list.');

        controller.dispose();
      });
    }
  });

  group('v0.16.0 F3 — quarantine skips a failing detector in later stages', () {
    testWidgets(
        'prepareScan throw → checkElement/afterElement/notifyWalkCompleted/'
        'finalizeScan all skipped', (tester) async {
      await tester.pumpWidget(buildMixedTree(50));
      final context = tester.element(find.byType(Directionality));

      final controller = SleuthController(config: _minimalConfig);
      controller.initializeDetectorsForTest();
      final failing = _FailingDetector(_FailStage.prepareScan);
      controller.addDetectorForTest(failing);

      final errors = _ScopedErrorCapture();
      try {
        controller.runTreeScanForTest(context);
      } finally {
        errors.restore();
      }

      expect(failing.prepareScanCalls, 1,
          reason: 'prepareScan is where the throw happens.');
      expect(failing.checkElementCalls, 0,
          reason: 'Quarantined — must not be called on any element.');
      expect(failing.afterElementCalls, 0,
          reason: 'Quarantined — must not be called on any element.');
      expect(failing.notifyWalkCompletedCalls, 0,
          reason: 'Quarantined — must not be called.');
      expect(failing.finalizeScanCalls, 0,
          reason: 'Quarantined — finalizeScan is also skipped so a '
              'half-initialised detector does not emit garbage issues.');

      // `_ScopedErrorCapture` now forwards to the binding's handler so
      // non-sleuth regressions stay visible (advanced-adversarial-review
      // Round 3). Drain the one sleuth StateError so teardown succeeds.
      expect(tester.takeException(), isA<StateError>());

      controller.dispose();
    });

    testWidgets(
        'checkElement throw on first element → later elements skip checkElement',
        (tester) async {
      await tester.pumpWidget(buildMixedTree(50));
      final context = tester.element(find.byType(Directionality));

      final controller = SleuthController(config: _minimalConfig);
      controller.initializeDetectorsForTest();
      final failing = _FailingDetector(_FailStage.checkElement);
      controller.addDetectorForTest(failing);

      final errors = _ScopedErrorCapture();
      try {
        controller.runTreeScanForTest(context);
      } finally {
        errors.restore();
      }

      expect(failing.prepareScanCalls, 1);
      expect(failing.checkElementCalls, 1,
          reason:
              'Quarantine must stop checkElement on the very next element.');
      expect(failing.afterElementCalls, 0,
          reason: 'afterElement is also skipped once quarantined.');
      expect(failing.notifyWalkCompletedCalls, 0,
          reason: 'notifyWalkCompleted is skipped for quarantined detectors.');
      expect(failing.finalizeScanCalls, 0,
          reason: 'finalizeScan is skipped for quarantined detectors.');

      expect(tester.takeException(), isA<StateError>());

      controller.dispose();
    });

    testWidgets(
        'one detector throws → other detectors in the same scan still run',
        (tester) async {
      await tester.pumpWidget(buildMixedTree(20));
      final context = tester.element(find.byType(Directionality));

      final controller = SleuthController(config: _minimalConfig);
      controller.initializeDetectorsForTest();
      final failing = _FailingDetector(_FailStage.prepareScan);
      final bystander = _NeverThrowsDetector();
      controller.addDetectorForTest(failing);
      controller.addDetectorForTest(bystander);

      final errors = _ScopedErrorCapture();
      try {
        controller.runTreeScanForTest(context);
      } finally {
        errors.restore();
      }

      expect(bystander.prepareScanCalls, 1);
      expect(bystander.checkElementCalls, greaterThan(0),
          reason: 'Healthy detector must continue running after a sibling '
              'detector throws in prepareScan.');
      expect(bystander.finalizeScanCalls, 1);

      expect(tester.takeException(), isA<StateError>());

      controller.dispose();
    });
  });

  group(
      'v0.16.0 F3 — aggregation filter drops partial output from failed '
      'detectors (advanced-adversarial-review Round 3)', () {
    testWidgets(
        'checkElement throw mid-walk → issues committed before throw do '
        'NOT leak into issuesNotifier', (tester) async {
      // This test guards against the Round-2 agreed blocker: the F3
      // quarantine stopped later-stage callbacks but aggregation
      // (_getAllIssues / _collectHighlights) still spread the failed
      // detector's `.issues` / `.highlights` into the public stream. A
      // SimpleStructuralDetector-style detector that reports findings
      // during checkElement and then throws had already committed partial
      // output; publishing it defeated the quarantine's purpose.
      //
      // The emitting detector below appends an issue + a highlight on
      // its first checkElement call, then throws on its second. Without
      // the aggregation filter, the public stream would surface the
      // committed issue/highlight as though the scan succeeded.
      await tester.pumpWidget(buildMixedTree(50));
      final context = tester.element(find.byType(Directionality));

      final controller = SleuthController(config: _minimalConfig);
      controller.initializeDetectorsForTest();
      final failing = _IssueEmittingFailingDetector();
      controller.addDetectorForTest(failing);

      final errors = _ScopedErrorCapture();
      try {
        controller.runTreeScanForTest(context);
      } finally {
        errors.restore();
      }

      expect(failing.emittedIssues, isNotEmpty,
          reason: 'Sanity check: the detector must actually have committed '
              'partial output during checkElement for this test to prove '
              'the filter is load-bearing.');

      final leaked = controller.issuesNotifier.value
          .where(
              (i) => i.title == _IssueEmittingFailingDetector.emittedIssueTitle)
          .toList();
      expect(
        leaked,
        isEmpty,
        reason: 'Aggregation filter must drop partial issues a quarantined '
            'detector committed before throwing. If this test fails, the '
            'F3 quarantine is leaky and the fix from '
            'advanced-adversarial-review Round 3 has regressed.',
      );

      final leakedHighlights = controller.highlightsNotifier.value.items
          .where((h) => h.detectorName == failing.name)
          .toList();
      expect(
        leakedHighlights,
        isEmpty,
        reason: 'Same rule applies to highlights — detectors that throw '
            'must not publish partial highlights.',
      );

      expect(tester.takeException(), isA<StateError>());

      controller.dispose();
    });

    testWidgets(
        'healthy detector beside failing one still publishes its issues',
        (tester) async {
      // Second half of the contract: the filter must NOT over-suppress.
      // A bystander detector that also emits issues during checkElement
      // must have its issues survive aggregation even when a sibling
      // detector throws in the same scan.
      await tester.pumpWidget(buildMixedTree(50));
      final context = tester.element(find.byType(Directionality));

      final controller = SleuthController(config: _minimalConfig);
      controller.initializeDetectorsForTest();
      final failing = _IssueEmittingFailingDetector();
      final healthy = _HealthyEmittingDetector();
      controller.addDetectorForTest(failing);
      controller.addDetectorForTest(healthy);

      final errors = _ScopedErrorCapture();
      try {
        controller.runTreeScanForTest(context);
      } finally {
        errors.restore();
      }

      final healthyPublished = controller.issuesNotifier.value
          .where((i) => i.title == _HealthyEmittingDetector.emittedIssueTitle)
          .toList();
      expect(
        healthyPublished,
        isNotEmpty,
        reason: 'Healthy detector must continue to publish issues when a '
            'sibling detector fails — the filter is per-detector, not '
            'per-scan.',
      );

      expect(tester.takeException(), isA<StateError>());

      controller.dispose();
    });
  });
}

class _NeverThrowsDetector extends BaseDetector {
  _NeverThrowsDetector()
      : super(
          type: DetectorType.layoutBottleneck,
          lifecycle: DetectorLifecycle.structural,
          name: 'NeverThrowsDetector',
          description: 'Test double that records calls without throwing.',
        );

  int prepareScanCalls = 0;
  int checkElementCalls = 0;
  int finalizeScanCalls = 0;

  bool isEnabledField = true;

  @override
  bool get isEnabled => isEnabledField;

  @override
  set isEnabled(bool value) => isEnabledField = value;

  @override
  List<PerformanceIssue> get issues => const [];

  @override
  List<WidgetHighlight> get highlights => const [];

  @override
  void dispose() {}

  @override
  void prepareScan(BuildContext context) => prepareScanCalls++;

  @override
  void checkElement(Element element) => checkElementCalls++;

  @override
  void finalizeScan() => finalizeScanCalls++;
}

/// Emits one issue + one highlight on the first `checkElement` call, then
/// throws on the second. Exercises the aggregation filter: without the
/// filter, the committed issue/highlight would leak into the public stream
/// even though the detector threw during the same scan.
class _IssueEmittingFailingDetector extends BaseDetector {
  _IssueEmittingFailingDetector()
      : super(
          type: DetectorType.layoutBottleneck,
          lifecycle: DetectorLifecycle.structural,
          name: 'IssueEmittingFailingDetector',
          description: 'Test double that emits partial output before throwing.',
        );

  static const String emittedIssueTitle =
      'Test partial-output issue (must be filtered out)';

  final List<PerformanceIssue> emittedIssues = [];
  final List<WidgetHighlight> emittedHighlights = [];
  int _checkElementCalls = 0;

  bool isEnabledField = true;

  @override
  bool get isEnabled => isEnabledField;

  @override
  set isEnabled(bool value) => isEnabledField = value;

  @override
  List<PerformanceIssue> get issues => emittedIssues;

  @override
  List<WidgetHighlight> get highlights => emittedHighlights;

  @override
  void dispose() {}

  @override
  void prepareScan(BuildContext context) {}

  @override
  void checkElement(Element element) {
    _checkElementCalls++;
    if (_checkElementCalls == 1) {
      emittedIssues.add(const PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.layout,
        confidence: IssueConfidence.possible,
        title: emittedIssueTitle,
        detail: 'Detector throws on next element; this partial output '
            'must not leak into aggregation.',
        fixHint: 'n/a — test double',
      ));
      emittedHighlights.add(WidgetHighlight(
        rect: Rect.zero,
        widgetName: 'TestWidget',
        severity: IssueSeverity.warning,
        detectorName: name,
      ));
      return;
    }
    throw StateError('boom in checkElement after partial emission');
  }

  @override
  void afterElement(Element element) {}

  @override
  void notifyWalkCompleted() {}

  @override
  void finalizeScan() {}
}

/// Companion to [_IssueEmittingFailingDetector]: emits one issue on the
/// first `checkElement` call and never throws. Guards against an
/// over-aggressive filter that would suppress healthy detectors' output
/// whenever ANY detector in the same scan fails.
class _HealthyEmittingDetector extends BaseDetector {
  _HealthyEmittingDetector()
      : super(
          type: DetectorType.rebuild,
          lifecycle: DetectorLifecycle.structural,
          name: 'HealthyEmittingDetector',
          description: 'Test double that emits one issue and never throws.',
        );

  static const String emittedIssueTitle =
      'Test healthy-output issue (must survive aggregation)';

  final List<PerformanceIssue> emittedIssues = [];
  bool _emitted = false;

  bool isEnabledField = true;

  @override
  bool get isEnabled => isEnabledField;

  @override
  set isEnabled(bool value) => isEnabledField = value;

  @override
  List<PerformanceIssue> get issues => emittedIssues;

  @override
  List<WidgetHighlight> get highlights => const [];

  @override
  void dispose() {}

  @override
  void prepareScan(BuildContext context) {}

  @override
  void checkElement(Element element) {
    if (_emitted) return;
    _emitted = true;
    emittedIssues.add(const PerformanceIssue(
      severity: IssueSeverity.warning,
      category: IssueCategory.build,
      confidence: IssueConfidence.possible,
      title: emittedIssueTitle,
      detail: 'Healthy detector output must survive when a sibling '
          'detector in the same scan is quarantined.',
      fixHint: 'n/a — test double',
    ));
  }

  @override
  void afterElement(Element element) {}

  @override
  void notifyWalkCompleted() {}

  @override
  void finalizeScan() {}
}
