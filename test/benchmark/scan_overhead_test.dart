@Tags(['benchmark'])
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show debugOnProfilePaint;
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/debug/debug_instrumentation_coordinator.dart';
import 'package:sleuth/src/models/base_detector.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/models/widget_highlight.dart';
import 'package:sleuth/src/detectors/custom_painter_detector.dart';
import 'package:sleuth/src/detectors/font_loading_detector.dart';
import 'package:sleuth/src/detectors/gpu_pressure_detector.dart';
import 'package:sleuth/src/detectors/image_memory_detector.dart';
import 'package:sleuth/src/detectors/keep_alive_detector.dart';
import 'package:sleuth/src/detectors/layout_bottleneck_detector.dart';
import 'package:sleuth/src/detectors/listview_detector.dart';
import 'package:sleuth/src/detectors/rebuild_detector.dart';
import 'package:sleuth/src/detectors/repaint_detector.dart';
import 'package:sleuth/src/detectors/setstate_scope_detector.dart';

import '../helpers/benchmark_helpers.dart';

void main() {
  group('individual detector scan overhead (1000 elements)', () {
    // Budgets are about 5x the max of three serial runs' means.
    // CI runners get 2x tolerance via budgetMultiplier.
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
      // measured: 166 µs (serial, debug JIT, M1 Pro)
      expect(avgUs, lessThan(850 * budgetMultiplier));
    });

    testWidgets('RepaintDetector', (tester) async {
      await setup(tester);
      final detector = RepaintDetector();
      final avgUs = benchmarkUs('RepaintDetector', () {
        detector.scanTree(context);
      });
      // measured: 41 µs (serial, debug JIT, M1 Pro)
      expect(avgUs, lessThan(210 * budgetMultiplier));
    });

    testWidgets('GpuPressureDetector', (tester) async {
      await setup(tester);
      final detector = GpuPressureDetector();
      final avgUs = benchmarkUs('GpuPressureDetector', () {
        detector.scanTree(context);
      });
      // measured: 192 µs (serial, debug JIT, M1 Pro)
      expect(avgUs, lessThan(1000 * budgetMultiplier));
    });

    testWidgets('SetStateScopeDetector', (tester) async {
      await setup(tester);
      final detector = SetStateScopeDetector();
      final avgUs = benchmarkUs('SetStateScopeDetector', () {
        detector.scanTree(context);
      });
      // measured: 213 µs (serial, debug JIT, M1 Pro)
      expect(avgUs, lessThan(1100 * budgetMultiplier));
    });

    testWidgets('LayoutBottleneckDetector', (tester) async {
      await setup(tester);
      final detector = LayoutBottleneckDetector();
      final avgUs = benchmarkUs('LayoutBottleneckDetector', () {
        detector.scanTree(context);
      });
      // measured: 49 µs (serial, debug JIT, M1 Pro)
      expect(avgUs, lessThan(250 * budgetMultiplier));
    });

    testWidgets('ListviewDetector', (tester) async {
      await setup(tester);
      final detector = ListviewDetector();
      final avgUs = benchmarkUs('ListviewDetector', () {
        detector.scanTree(context);
      });
      // measured: 190 µs (serial, debug JIT, M1 Pro)
      expect(avgUs, lessThan(950 * budgetMultiplier));
    });

    testWidgets('ImageMemoryDetector', (tester) async {
      await setup(tester);
      final detector = ImageMemoryDetector();
      final avgUs = benchmarkUs('ImageMemoryDetector', () {
        detector.scanTree(context);
      });
      // measured: 83 µs (serial, debug JIT, M1 Pro)
      expect(avgUs, lessThan(420 * budgetMultiplier));
    });

    testWidgets('CustomPainterDetector', (tester) async {
      await setup(tester);
      final detector = CustomPainterDetector();
      final avgUs = benchmarkUs('CustomPainterDetector', () {
        detector.scanTree(context);
      });
      // measured: 60 µs (serial, debug JIT, M1 Pro)
      expect(avgUs, lessThan(300 * budgetMultiplier));
    });

    testWidgets('KeepAliveDetector', (tester) async {
      await setup(tester);
      final detector = KeepAliveDetector();
      final avgUs = benchmarkUs('KeepAliveDetector', () {
        detector.scanTree(context);
      });
      // measured: 62 µs (serial, debug JIT, M1 Pro)
      expect(avgUs, lessThan(310 * budgetMultiplier));
    });

    testWidgets('FontLoadingDetector', (tester) async {
      await setup(tester);
      final detector = FontLoadingDetector();
      final avgUs = benchmarkUs('FontLoadingDetector', () {
        detector.scanTree(context);
      });
      // measured: 72 µs (serial, debug JIT, M1 Pro)
      expect(avgUs, lessThan(360 * budgetMultiplier));
    });
  });

  group('full scan tick overhead', () {
    for (final size in [100, 500, 1000, 3000]) {
      // measured (serial, debug JIT, M1 Pro): 100 → 145 µs, 500 → 440 µs,
      // 1000 → 814 µs, 3000 → 2183 µs.
      final budget = switch (size) {
        100 => 750 * budgetMultiplier,
        500 => 2200 * budgetMultiplier,
        1000 => 4100 * budgetMultiplier,
        _ => 11000 * budgetMultiplier,
      };

      testWidgets('$size elements', (tester) async {
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
        SetStateScopeDetector(),
        LayoutBottleneckDetector(),
        ListviewDetector(),
        ImageMemoryDetector(),
        CustomPainterDetector(),
        KeepAliveDetector(),
        FontLoadingDetector(),
      ];

      final time500 = benchmarkUs('10 detectors × 500 elements', () {
        for (final d in detectors) {
          d.scanTree(context);
        }
      }, iterations: 30);

      // Measure 1000 elements
      await tester.pumpWidget(buildMixedTree(1000));
      context = tester.element(find.byType(Directionality));

      final time1000 = benchmarkUs('10 detectors × 1000 elements', () {
        for (final d in detectors) {
          d.scanTree(context);
        }
      }, iterations: 30);

      final ratio = time1000 / time500;
      // ignore: avoid_print
      print(
        '  Scaling ratio (1000/500): ${ratio.toStringAsFixed(2)} '
        '(ideal: 2.0, budget: < 2.5)',
      );

      // Pure O(N) would give ratio ~2.0. Allow noise up to 2.5.
      // If any detector regresses to O(N²), ratio would be ~4.0.
      expect(ratio, lessThan(2.5));
    });
  });

  group('full scan tick through the scheduled path', () {
    for (final size in [100, 500, 1000, 3000, 10000]) {
      // measured (serial, debug JIT, M1 Pro): 100 → 436 µs, 500 → 661 µs,
      // 1000 → 1030 µs, 3000 → 2600 µs, 10000 → 10927 µs.
      final budget = switch (size) {
        100 => 2200 * budgetMultiplier,
        500 => 3400 * budgetMultiplier,
        1000 => 5200 * budgetMultiplier,
        3000 => 13000 * budgetMultiplier,
        _ => 55000 * budgetMultiplier,
      };

      testWidgets('$size elements', (tester) async {
        await tester.pumpWidget(
          MaterialApp(home: Scaffold(body: buildMixedTree(size))),
        );
        final root = tester.element(find.byType(MaterialApp));

        final controller = SleuthController();
        controller.initializeDetectorsForTest();
        addTearDown(controller.dispose);

        final avgUs = benchmarkUs(
          'full path ($size-element body)',
          () => controller.scanTreeFullPathForTest(root),
          warmup: size >= 10000 ? 3 : 20,
          iterations: size >= 10000 ? 10 : 20,
        );
        // ignore: avoid_print
        print('  Walked ${controller.lastScanElementCount} elements');

        expect(controller.lastScanElementCount, greaterThan(size ~/ 2));
        expect(avgUs, lessThan(budget));
      });
    }
  });

  group('issue aggregation', () {
    testWidgets('40 distinct issues', (tester) async {
      await tester.pumpWidget(buildMixedTree(100));
      final context = tester.element(find.byType(Directionality));

      final detector = _FortyIssueDetector();
      final controller = SleuthController(
        config: SleuthConfig(customDetectors: [detector]),
      );
      controller.initializeDetectorsForTest();
      addTearDown(controller.dispose);
      controller.runTreeScanForTest(context);
      expect(controller.issuesNotifier.value.length, greaterThanOrEqualTo(40));

      final avgUs = benchmarkUs(
        'aggregate 40 issues',
        controller.aggregateIssuesForTest,
      );

      // measured: 210 µs (serial, debug JIT, M1 Pro)
      expect(avgUs, lessThan(1100 * budgetMultiplier));
    });
  });

  group('per-paint debug callback', () {
    testWidgets('1,000 paints of a real RenderObject', (tester) async {
      debugOnProfilePaint = null;
      debugOnRebuildDirtyWidget = null;
      final repaint = ValueNotifier<int>(0);
      addTearDown(repaint.dispose);
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Column(
            children: [
              for (var i = 0; i < 50; i++)
                RepaintBoundary(
                  child: CustomPaint(
                    size: const Size(10, 2),
                    painter: _BenchPainter(repaint),
                  ),
                ),
            ],
          ),
        ),
      );

      final coordinator = DebugInstrumentationCoordinator(
        installRebuild: false,
      );
      coordinator.install();
      coordinator.snapshot();

      // The framework reaches the handler on a real frame.
      repaint.value++;
      await tester.pump();
      expect(coordinator.snapshot().totalPaintCount, greaterThanOrEqualTo(50));

      final renderObject = tester.renderObject(find.byType(CustomPaint).first);
      final onPaint = debugOnProfilePaint!;
      final avgUs = benchmarkUs('1,000 paint callbacks', () {
        for (var i = 0; i < 1000; i++) {
          onPaint(renderObject);
        }
        coordinator.snapshot();
      });
      coordinator.dispose();

      // measured: 6101 µs (serial, debug JIT, M1 Pro)
      expect(avgUs, lessThan(31000 * budgetMultiplier));
    });
  });
}

class _FortyIssueDetector extends BaseDetector {
  _FortyIssueDetector()
    : super(
        type: DetectorType.custom,
        lifecycle: DetectorLifecycle.structural,
        name: 'Forty Issues',
        description: 'Emits 40 distinct issues per scan.',
      );

  final List<PerformanceIssue> _issues = [];
  bool _isEnabled = true;

  @override
  List<PerformanceIssue> get issues => _issues;
  @override
  List<WidgetHighlight> get highlights => const [];
  @override
  bool get isEnabled => _isEnabled;
  @override
  set isEnabled(bool v) => _isEnabled = v;

  @override
  void scanTree(BuildContext context) {
    _issues
      ..clear()
      ..addAll([
        for (var i = 0; i < 40; i++)
          PerformanceIssue(
            stableId: 'bench_issue_$i',
            severity: i.isEven ? IssueSeverity.warning : IssueSeverity.critical,
            category: IssueCategory.build,
            confidence: IssueConfidence.possible,
            title: 'Bench issue $i',
            detail: 'Detail $i',
            fixHint: 'Fix $i',
            observationSource: ObservationSource.structural,
            detectedAt: DateTime.now(),
          ),
      ]);
  }

  @override
  void dispose() => _issues.clear();
}

class _BenchPainter extends CustomPainter {
  _BenchPainter(Listenable repaint) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {}

  @override
  bool shouldRepaint(_BenchPainter oldDelegate) => false;
}
