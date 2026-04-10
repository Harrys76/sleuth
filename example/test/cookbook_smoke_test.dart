// Smoke test for the custom detector cookbook.
//
// Purpose: this test lives in the example package (not the root sleuth
// package) so every import in the cookbook must resolve through the
// public `package:sleuth/sleuth.dart` barrel. If a cookbook file ever
// reaches into `package:sleuth/src/...`, the analyzer will fail here
// before the test even runs.
//
// What this test asserts:
// 1. Every cookbook detector constructs without throwing.
// 2. Each detector has a non-empty `name` and `description`.
// 3. Each detector has a stable `key` so it can be disabled via
//    SleuthConfig.disabledCustomDetectorKeys.
// 4. Their reported lifecycle and type match the cookbook's documented
//    shape — structural, runtime, hybrid.
// 5. The structural cookbook detector runs a one-shot scan over a tree
//    containing a Tooltip and produces exactly one issue.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/sleuth.dart';

import 'package:example/custom_detectors/01_simple_structural_detector.dart';
import 'package:example/custom_detectors/02_runtime_callback_detector.dart';
import 'package:example/custom_detectors/03_hybrid_vm_structural_detector.dart';

void main() {
  group('Cookbook smoke tests', () {
    test('01 TooltipUsageDetector constructs with expected metadata', () {
      final detector = TooltipUsageDetector();
      addTearDown(detector.dispose);

      expect(detector.name, isNotEmpty);
      expect(detector.description, isNotEmpty);
      expect(detector.key, 'tooltip_usage');
      expect(detector.type, DetectorType.custom);
      expect(detector.lifecycle, DetectorLifecycle.structural);
      expect(detector.isEnabled, isTrue);
    });

    test('02 SlowFrameDetector constructs with expected metadata', () {
      final detector = SlowFrameDetector();
      addTearDown(detector.dispose);

      expect(detector.name, isNotEmpty);
      expect(detector.description, isNotEmpty);
      expect(detector.key, 'slow_frame_detector');
      expect(detector.type, DetectorType.custom);
      expect(detector.lifecycle, DetectorLifecycle.runtime);
      expect(detector.isEnabled, isTrue);
      // No frames have been observed yet, so the issue list should be
      // empty even after a manual finalizeScan.
      detector.finalizeScan();
      expect(detector.issues, isEmpty);
    });

    test('03 RasterHotSpotDetector constructs with expected metadata', () {
      final detector = RasterHotSpotDetector();
      addTearDown(detector.dispose);

      expect(detector.name, isNotEmpty);
      expect(detector.description, isNotEmpty);
      expect(detector.key, 'raster_hot_spot');
      expect(detector.type, DetectorType.custom);
      expect(detector.lifecycle, DetectorLifecycle.hybrid);
      expect(detector.isEnabled, isTrue);
    });

    testWidgets(
      '01 TooltipUsageDetector flags Tooltips in a real widget tree',
      (tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: Tooltip(
                message: 'cookbook smoke test',
                child: Text('hover me'),
              ),
            ),
          ),
        );

        final detector = TooltipUsageDetector();
        addTearDown(detector.dispose);

        // scanTree is the public entry point on BaseDetector. It calls
        // prepareScan → checkElement (per element) → finalizeScan under
        // the hood, matching what the controller does in production.
        final context = tester.element(find.byType(MaterialApp));
        detector.scanTree(context);

        expect(
          detector.issues,
          isNotEmpty,
          reason: 'expected at least one Tooltip issue in the tree',
        );
        expect(detector.issues.first.title, 'Tooltip detected');
        expect(detector.issues.first.category, IssueCategory.build);
      },
    );

    testWidgets('01 TooltipUsageDetector ignores framework-provided tooltips', (
      tester,
    ) async {
      // AppBar's back button generates Tooltip("Back") — the detector
      // should skip it because it's a framework tooltip, not user-authored.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: const [
                Tooltip(message: 'Back', child: Text('framework')),
                Tooltip(message: 'Close', child: Text('framework')),
                Tooltip(message: 'user tooltip', child: Text('user-authored')),
              ],
            ),
          ),
        ),
      );

      final detector = TooltipUsageDetector();
      addTearDown(detector.dispose);

      final context = tester.element(find.byType(MaterialApp));
      detector.scanTree(context);

      // Only the user-authored tooltip should be flagged.
      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.detail, contains('user tooltip'));
    });

    test('All three detectors co-exist in a SleuthConfig', () {
      // This is the real-world wiring snippet from the README. We just
      // want to confirm that constructing a config with all three
      // cookbook detectors doesn't throw, to catch any ordering or
      // validation regressions.
      final config = SleuthConfig(
        customDetectors: [
          TooltipUsageDetector(),
          SlowFrameDetector(),
          RasterHotSpotDetector(),
        ],
      );
      addTearDown(() {
        for (final d in config.customDetectors) {
          d.dispose();
        }
      });

      expect(config.customDetectors, hasLength(3));
      expect(
        config.customDetectors.map((d) => d.key),
        containsAll(<String>[
          'tooltip_usage',
          'slow_frame_detector',
          'raster_hot_spot',
        ]),
      );
    });
  });
}
