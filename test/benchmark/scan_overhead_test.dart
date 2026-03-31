import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/src/controller/watchdog_controller.dart';
import 'package:widget_watchdog/src/detectors/animated_builder_detector.dart';
import 'package:widget_watchdog/src/detectors/custom_painter_detector.dart';
import 'package:widget_watchdog/src/detectors/font_loading_detector.dart';
import 'package:widget_watchdog/src/detectors/global_key_detector.dart';
import 'package:widget_watchdog/src/detectors/gpu_pressure_detector.dart';
import 'package:widget_watchdog/src/detectors/image_memory_detector.dart';
import 'package:widget_watchdog/src/detectors/keep_alive_detector.dart';
import 'package:widget_watchdog/src/detectors/layout_bottleneck_detector.dart';
import 'package:widget_watchdog/src/detectors/listview_detector.dart';
import 'package:widget_watchdog/src/detectors/nested_scroll_detector.dart';
import 'package:widget_watchdog/src/detectors/opacity_detector.dart';
import 'package:widget_watchdog/src/detectors/rebuild_detector.dart';
import 'package:widget_watchdog/src/detectors/repaint_detector.dart';
import 'package:widget_watchdog/src/detectors/setstate_scope_detector.dart';
import 'package:widget_watchdog/src/detectors/shallow_rebuild_risk_detector.dart';

import '../helpers/benchmark_helpers.dart';

void main() {
  group('individual detector scan overhead (1000 elements)', () {
    // Budget: 5ms per detector for 1000 elements.
    // SetStateScopeDetector gets 15ms due to O(N²) subtree counting.
    // CI runners get 2x tolerance via budgetMultiplier.
    final defaultBudgetUs = 5000 * budgetMultiplier;
    final setStateBudgetUs = 15000 * budgetMultiplier;

    late BuildContext context;

    Future<void> setup(WidgetTester tester) async {
      await tester.pumpWidget(buildMixedTree(1000));
      context = tester.element(find.byType(Directionality));
      final elements = countElements(context);
      // ignore: avoid_print
      print('  Tree has $elements elements');
    }

    testWidgets('RebuildDetector', (tester) async {
      await setup(tester);
      final detector = RebuildDetector();
      final avgUs = benchmarkUs('RebuildDetector', () {
        detector.scanTree(context);
      });
      expect(avgUs, lessThan(defaultBudgetUs));
    });

    testWidgets('RepaintDetector', (tester) async {
      await setup(tester);
      final detector = RepaintDetector();
      final avgUs = benchmarkUs('RepaintDetector', () {
        detector.scanTree(context);
      });
      expect(avgUs, lessThan(defaultBudgetUs));
    });

    testWidgets('GpuPressureDetector', (tester) async {
      await setup(tester);
      final detector = GpuPressureDetector();
      final avgUs = benchmarkUs('GpuPressureDetector', () {
        detector.scanTree(context);
      });
      expect(avgUs, lessThan(defaultBudgetUs));
    });

    testWidgets('ShallowRebuildRiskDetector', (tester) async {
      await setup(tester);
      final detector = ShallowRebuildRiskDetector();
      final avgUs = benchmarkUs('ShallowRebuildRiskDetector', () {
        detector.scanTree(context);
      });
      expect(avgUs, lessThan(defaultBudgetUs));
    });

    testWidgets('SetStateScopeDetector', (tester) async {
      await setup(tester);
      final detector = SetStateScopeDetector();
      final avgUs = benchmarkUs('SetStateScopeDetector', () {
        detector.scanTree(context);
      });
      // Higher budget — O(N²) subtree counting
      expect(avgUs, lessThan(setStateBudgetUs));
    });

    testWidgets('LayoutBottleneckDetector', (tester) async {
      await setup(tester);
      final detector = LayoutBottleneckDetector();
      final avgUs = benchmarkUs('LayoutBottleneckDetector', () {
        detector.scanTree(context);
      });
      expect(avgUs, lessThan(defaultBudgetUs));
    });

    testWidgets('ListviewDetector', (tester) async {
      await setup(tester);
      final detector = ListviewDetector();
      final avgUs = benchmarkUs('ListviewDetector', () {
        detector.scanTree(context);
      });
      expect(avgUs, lessThan(defaultBudgetUs));
    });

    testWidgets('ImageMemoryDetector', (tester) async {
      await setup(tester);
      final detector = ImageMemoryDetector();
      final avgUs = benchmarkUs('ImageMemoryDetector', () {
        detector.scanTree(context);
      });
      expect(avgUs, lessThan(defaultBudgetUs));
    });

    testWidgets('GlobalKeyDetector', (tester) async {
      await setup(tester);
      final detector = GlobalKeyDetector();
      final avgUs = benchmarkUs('GlobalKeyDetector', () {
        detector.scanTree(context);
      });
      expect(avgUs, lessThan(defaultBudgetUs));
    });

    testWidgets('NestedScrollDetector', (tester) async {
      await setup(tester);
      final detector = NestedScrollDetector();
      final avgUs = benchmarkUs('NestedScrollDetector', () {
        detector.scanTree(context);
      });
      expect(avgUs, lessThan(defaultBudgetUs));
    });

    testWidgets('CustomPainterDetector', (tester) async {
      await setup(tester);
      final detector = CustomPainterDetector();
      final avgUs = benchmarkUs('CustomPainterDetector', () {
        detector.scanTree(context);
      });
      expect(avgUs, lessThan(defaultBudgetUs));
    });

    testWidgets('KeepAliveDetector', (tester) async {
      await setup(tester);
      final detector = KeepAliveDetector();
      final avgUs = benchmarkUs('KeepAliveDetector', () {
        detector.scanTree(context);
      });
      expect(avgUs, lessThan(defaultBudgetUs));
    });

    testWidgets('AnimatedBuilderDetector', (tester) async {
      await setup(tester);
      final detector = AnimatedBuilderDetector();
      final avgUs = benchmarkUs('AnimatedBuilderDetector', () {
        detector.scanTree(context);
      });
      expect(avgUs, lessThan(defaultBudgetUs));
    });

    testWidgets('OpacityDetector', (tester) async {
      await setup(tester);
      final detector = OpacityDetector();
      final avgUs = benchmarkUs('OpacityDetector', () {
        detector.scanTree(context);
      });
      expect(avgUs, lessThan(defaultBudgetUs));
    });

    testWidgets('FontLoadingDetector', (tester) async {
      await setup(tester);
      final detector = FontLoadingDetector();
      final avgUs = benchmarkUs('FontLoadingDetector', () {
        detector.scanTree(context);
      });
      expect(avgUs, lessThan(defaultBudgetUs));
    });
  });

  group('full scan tick overhead', () {
    for (final size in [100, 500, 1000, 3000]) {
      final budget = switch (size) {
        100 => 10000 * budgetMultiplier,
        500 => 30000 * budgetMultiplier,
        1000 => 80000 * budgetMultiplier,
        3000 => 500000 * budgetMultiplier,
        _ => 100000 * budgetMultiplier,
      };

      testWidgets('$size elements < ${budget ~/ 1000}ms', (tester) async {
        await tester.pumpWidget(buildMixedTree(size));
        final context = tester.element(find.byType(Directionality));
        final elements = countElements(context);

        final controller = WatchdogController();
        controller.initializeDetectorsForTest();

        final avgUs = benchmarkUs(
          'full scan ($elements elements)',
          () => controller.runTreeScanForTest(context),
          iterations: 20,
        );

        final perElement = avgUs / elements;
        // ignore: avoid_print
        print('  Per-element: ${perElement.toStringAsFixed(1)} µs');

        expect(avgUs, lessThan(budget));

        controller.dispose();
      });
    }
  });

  group('scan overhead scales linearly (excluding SetStateScope)', () {
    testWidgets('ratio of 1000/500 elements < 2.5', (tester) async {
      // Measure 500 elements
      await tester.pumpWidget(buildMixedTree(500));
      var context = tester.element(find.byType(Directionality));

      // Use all detectors except SetStateScopeDetector (known O(N²))
      final detectors = [
        RebuildDetector(),
        RepaintDetector(),
        GpuPressureDetector(),
        ShallowRebuildRiskDetector(),
        LayoutBottleneckDetector(),
        ListviewDetector(),
        ImageMemoryDetector(),
        GlobalKeyDetector(),
        NestedScrollDetector(),
        CustomPainterDetector(),
        KeepAliveDetector(),
        AnimatedBuilderDetector(),
        OpacityDetector(),
        FontLoadingDetector(),
      ];

      final time500 = benchmarkUs(
        '14 detectors × 500 elements',
        () {
          for (final d in detectors) {
            d.scanTree(context);
          }
        },
        iterations: 30,
      );

      // Measure 1000 elements
      await tester.pumpWidget(buildMixedTree(1000));
      context = tester.element(find.byType(Directionality));

      final time1000 = benchmarkUs(
        '14 detectors × 1000 elements',
        () {
          for (final d in detectors) {
            d.scanTree(context);
          }
        },
        iterations: 30,
      );

      final ratio = time1000 / time500;
      // ignore: avoid_print
      print('  Scaling ratio (1000/500): ${ratio.toStringAsFixed(2)} '
          '(ideal: 2.0, budget: < 2.5)');

      // Pure O(N) would give ratio ~2.0. Allow noise up to 2.5.
      // If any detector regresses to O(N²), ratio would be ~4.0.
      expect(ratio, lessThan(2.5));
    });
  });
}
