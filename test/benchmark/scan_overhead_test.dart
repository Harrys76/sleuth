import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/base_detector.dart';
import 'package:sleuth/src/detectors/animated_builder_detector.dart';
import 'package:sleuth/src/detectors/custom_painter_detector.dart';
import 'package:sleuth/src/detectors/font_loading_detector.dart';
import 'package:sleuth/src/detectors/global_key_detector.dart';
import 'package:sleuth/src/detectors/gpu_pressure_detector.dart';
import 'package:sleuth/src/detectors/image_memory_detector.dart';
import 'package:sleuth/src/detectors/keep_alive_detector.dart';
import 'package:sleuth/src/detectors/layout_bottleneck_detector.dart';
import 'package:sleuth/src/detectors/listview_detector.dart';
import 'package:sleuth/src/detectors/nested_scroll_detector.dart';
import 'package:sleuth/src/detectors/opacity_detector.dart';
import 'package:sleuth/src/detectors/rebuild_detector.dart';
import 'package:sleuth/src/detectors/repaint_detector.dart';
import 'package:sleuth/src/detectors/setstate_scope_detector.dart';
import 'package:sleuth/src/detectors/shallow_rebuild_risk_detector.dart';

import '../helpers/benchmark_helpers.dart';

void main() {
  group('individual detector scan overhead (1000 elements)', () {
    // Budget: 5ms per detector for 1000 elements.
    // CI runners get 2x tolerance via budgetMultiplier.
    final defaultBudgetUs = 5000 * budgetMultiplier;

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
      expect(avgUs, lessThan(defaultBudgetUs));
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

        final controller = SleuthController();
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

  group('scan overhead scales linearly', () {
    testWidgets('ratio of 1000/500 elements < 2.5', (tester) async {
      // Measure 500 elements
      await tester.pumpWidget(buildMixedTree(500));
      var context = tester.element(find.byType(Directionality));

      final List<BaseDetector> detectors = [
        RebuildDetector(),
        RepaintDetector(),
        GpuPressureDetector(),
        ShallowRebuildRiskDetector(),
        SetStateScopeDetector(),
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
        '15 detectors × 500 elements',
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
        '15 detectors × 1000 elements',
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
