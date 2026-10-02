@Tags(['benchmark'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:vm_service/vm_service.dart';
import 'package:sleuth/src/detectors/gpu_pressure_detector.dart';
import 'package:sleuth/src/detectors/heavy_compute_detector.dart';
import 'package:sleuth/src/detectors/memory_pressure_detector.dart';
import 'package:sleuth/src/detectors/platform_channel_detector.dart';
import 'package:sleuth/src/detectors/rebuild_detector.dart';
import 'package:sleuth/src/detectors/repaint_detector.dart';
import 'package:sleuth/src/detectors/shader_jank_detector.dart';
import 'package:sleuth/src/models/phase_event.dart';
import 'package:sleuth/src/vm/timeline_parser.dart';

import '../helpers/benchmark_helpers.dart';

void main() {
  group('timeline data processing overhead', () {
    // Build synthetic data at different event counts
    ParsedTimelineData buildData(int eventCount) {
      return ParsedTimelineData(
        buildScopeDurations: List.generate(eventCount, (_) => 5000),
        flushLayoutDurations: List.generate(eventCount ~/ 2, (_) => 3000),
        flushPaintDurations: List.generate(eventCount ~/ 2, (_) => 2000),
        buildEventCount: eventCount,
        phaseEvents: List.generate(
          eventCount,
          (i) => PhaseEvent(
            phase: i.isEven ? TimelinePhase.build : TimelinePhase.paint,
            timestampUs: 100000 + i * 5000,
            durationUs: 5000,
            dirtyList: i.isEven ? ['WidgetA', 'WidgetB'] : null,
            dirtyCount: i.isOdd ? 3 : null,
          ),
        ),
      );
    }

    for (final count in [10, 100, 500]) {
      // measured (serial, debug JIT, M1 Pro): 10 → 21 µs, 100 → 36 µs,
      // 500 → 51 µs.
      final budget = switch (count) {
        10 => 110 * budgetMultiplier,
        100 => 180 * budgetMultiplier,
        _ => 260 * budgetMultiplier,
      };

      test('$count events', () {
        final data = buildData(count);

        // Create all detectors that consume timeline data
        final rebuild = RebuildDetector();
        final repaint = RepaintDetector();
        final gpuPressure = GpuPressureDetector();
        final shaderJank = ShaderJankDetector();
        final heavyCompute = HeavyComputeDetector();
        final platformChannel = PlatformChannelDetector();
        final memoryPressure = MemoryPressureDetector();

        rebuild.vmConnected = true;
        repaint.vmConnected = true;

        final avgUs = benchmarkUs('feed $count events to 7 detectors', () {
          shaderJank.processTimelineData(data);
          heavyCompute.processTimelineData(data);
          platformChannel.processTimelineData(data);
          memoryPressure.processTimelineData(data);
          repaint.processTimelineData(data);
          rebuild.processTimelineData(data);
          gpuPressure.processTimelineData(data);
          rebuild.evaluateNow();
          repaint.evaluateNow();
        });

        expect(avgUs, lessThan(budget));
      });
    }
  });

  group('timeline parser overhead', () {
    List<TimelineEvent> buildRawEvents(int count) {
      return List.generate(
        count,
        (i) => TimelineEvent.parse({
          'name': i.isEven ? 'BUILD' : 'PAINT',
          'cat': 'flutter',
          'ph': 'X',
          'dur': 5000,
          'ts': 100000 + i * 5000,
          'pid': 1,
          'tid': 1,
          if (i.isEven)
            'args': {
              'build scope dirty count': '${i + 1}',
              'dirty list': '[WidgetA, WidgetB]',
            },
        })!,
      );
    }

    for (final count in [100, 500]) {
      // measured per event (serial, debug JIT, M1 Pro): 100 → 1.12 µs,
      // 500 → 0.37 µs.
      final perEventBudgetUs = count == 100 ? 6 : 2;

      test('$count raw events', () {
        final events = buildRawEvents(count);

        final avgUs = benchmarkUs(
          'parse $count events',
          () => TimelineParser.parse(events),
        );

        final perEvent = avgUs / count;
        // ignore: avoid_print
        print('  Per-event: ${perEvent.toStringAsFixed(1)} µs');

        expect(perEvent, lessThan(perEventBudgetUs * budgetMultiplier));
      });
    }
  });
}
