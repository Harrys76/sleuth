import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/base_detector.dart';
import 'package:sleuth/src/models/performance_issue.dart';

import '../helpers/benchmark_helpers.dart';

void main() {
  group('Detector lazy initialization (M6)', () {
    testWidgets('only enabled detectors are constructed', (tester) async {
      await tester.pumpWidget(buildMixedTree(50));

      final controller = SleuthController(
        config: const SleuthConfig(
          enabledDetectors: {
            DetectorType.frameTiming,
            DetectorType.rebuild,
          },
        ),
      );
      controller.initializeDetectorsForTest();

      // 4 typed detectors (frameTiming, memoryPressure, networkMonitor,
      // rebuild) are always constructed. enabledDetectors restricts only
      // factory-map detectors. Total: 4 typed + 0 factory = 4.
      expect(controller.detectorCountForTest, 4);

      controller.dispose();
    });

    testWidgets('default config constructs all 18 detectors', (tester) async {
      await tester.pumpWidget(buildMixedTree(50));

      final controller = SleuthController();
      controller.initializeDetectorsForTest();

      // 4 typed + 14 factory = 18 total.
      expect(controller.detectorCountForTest, 18);

      controller.dispose();
    });

    testWidgets('enableDetector adds a non-typed detector at runtime',
        (tester) async {
      await tester.pumpWidget(buildMixedTree(50));
      final context = tester.element(find.byType(Directionality));

      final controller = SleuthController(
        config: const SleuthConfig(
          enabledDetectors: {
            DetectorType.frameTiming,
          },
        ),
      );
      controller.initializeDetectorsForTest();
      expect(controller.detectorCountForTest, 4); // 4 typed only

      // Enable opacity at runtime.
      controller.enableDetector(DetectorType.customPainter);
      expect(controller.detectorCountForTest, 5);

      // Verify it participates in a scan.
      controller.runTreeScanForTest(context);
      // No crash = detector was integrated correctly.

      controller.dispose();
    });

    testWidgets('disableDetector removes a non-typed detector', (tester) async {
      await tester.pumpWidget(buildMixedTree(50));

      final controller = SleuthController(
        config: const SleuthConfig(
          enabledDetectors: {
            DetectorType.frameTiming,
            DetectorType.customPainter,
          },
        ),
      );
      controller.initializeDetectorsForTest();
      expect(controller.detectorCountForTest, 5); // 4 typed + opacity

      controller.disableDetector(DetectorType.customPainter);
      expect(controller.detectorCountForTest, 4); // opacity removed

      controller.dispose();
    });

    testWidgets('typed detectors: enable/disable toggles flag without removal',
        (tester) async {
      await tester.pumpWidget(buildMixedTree(50));

      final controller = SleuthController(
        config: const SleuthConfig(
          enabledDetectors: {DetectorType.frameTiming},
        ),
      );
      controller.initializeDetectorsForTest();
      final countBefore = controller.detectorCountForTest;

      // Disable frameTiming — count stays the same (still in list).
      controller.disableDetector(DetectorType.frameTiming);
      expect(controller.detectorCountForTest, countBefore);

      // Re-enable.
      controller.enableDetector(DetectorType.frameTiming);
      expect(controller.detectorCountForTest, countBefore);

      controller.dispose();
    });

    testWidgets(
        'custom detectors always present regardless of enabledDetectors',
        (tester) async {
      await tester.pumpWidget(buildMixedTree(50));

      final customDetector = _TestCustomDetector();
      final controller = SleuthController(
        config: SleuthConfig(
          enabledDetectors: const {DetectorType.frameTiming},
          customDetectors: [customDetector],
        ),
      );
      controller.initializeDetectorsForTest();

      // 4 typed + 0 factory + 1 custom = 5.
      expect(controller.detectorCountForTest, 5);

      controller.dispose();
    });

    testWidgets('enableDetector is idempotent — no duplicates', (tester) async {
      await tester.pumpWidget(buildMixedTree(50));

      final controller = SleuthController(
        config: const SleuthConfig(
          enabledDetectors: {
            DetectorType.frameTiming,
            DetectorType.customPainter,
          },
        ),
      );
      controller.initializeDetectorsForTest();
      final countBefore = controller.detectorCountForTest;

      // Enable opacity again — already present. Should not add a duplicate.
      controller.enableDetector(DetectorType.customPainter);
      expect(controller.detectorCountForTest, countBefore);

      controller.dispose();
    });

    testWidgets('scan with partial detectors produces correct issues',
        (tester) async {
      await tester.pumpWidget(buildMixedTree(500));
      final context = tester.element(find.byType(Directionality));

      // Enable only rebuild (known to fire on buildMixedTree).
      final controller = SleuthController(
        config: const SleuthConfig(
          enabledDetectors: {
            DetectorType.frameTiming,
            DetectorType.rebuild,
          },
        ),
      );
      controller.initializeDetectorsForTest();
      controller.runTreeScanForTest(context);

      final issues = controller.issuesNotifier.value;
      // Should only see rebuild issues (if any), not issues from detectors
      // that weren't constructed.
      for (final issue in issues) {
        expect(
          issue.stableId,
          anyOf(
            startsWith('rebuild'),
            startsWith('stateful_density'),
            startsWith('sustained_jank'),
            startsWith('frame_timing'),
          ),
        );
      }

      controller.dispose();
    });
  });
}

class _TestCustomDetector extends BaseDetector {
  _TestCustomDetector()
      : super(
          type: DetectorType.custom,
          lifecycle: DetectorLifecycle.structural,
          name: 'Test Custom',
          description: 'Test custom detector for M6',
        );

  bool _isEnabled = true;

  @override
  List<PerformanceIssue> get issues => const [];
  @override
  bool get isEnabled => _isEnabled;
  @override
  set isEnabled(bool v) => _isEnabled = v;

  @override
  void scanTree(BuildContext context) {
    // No-op for testing.
  }

  @override
  void dispose() {}
}
