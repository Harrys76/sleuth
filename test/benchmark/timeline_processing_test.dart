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

  group('timeline parser with cursors', () {
    // One 60 Hz frame = BUILD X with args, LAYOUT and PAINT B/E pairs on
    // the UI thread, raster X on the raster thread: 6 events.
    List<TimelineEvent> frameEvents(int count) {
      final events = <TimelineEvent>[];
      var frame = 0;
      while (events.length < count) {
        final start = 1000000 + frame * 16667;
        events.addAll([
          TimelineEvent.parse({
            'name': 'BUILD',
            'ph': 'X',
            'ts': start,
            'dur': 3000,
            'pid': 1,
            'tid': 1,
            'args': {
              'build scope dirty count': '3',
              'build scope dirty list': '[WidgetA, WidgetB, WidgetC]',
            },
          })!,
          for (final (name, offset) in [('LAYOUT', 3100), ('PAINT', 4200)]) ...[
            TimelineEvent.parse({
              'name': name,
              'ph': 'B',
              'ts': start + offset,
              'pid': 1,
              'tid': 1,
            })!,
            TimelineEvent.parse({
              'name': name,
              'ph': 'E',
              'ts': start + offset + 900,
              'pid': 1,
              'tid': 1,
            })!,
          ],
          TimelineEvent.parse({
            'name': 'GPURasterizer::Draw',
            'ph': 'X',
            'ts': start + 6000,
            'dur': 4000,
            'pid': 1,
            'tid': 2,
          })!,
        ]);
        frame++;
      }
      return events.sublist(0, count);
    }

    ParsedTimelineData parseWith(
      List<TimelineEvent> events,
      Map<int, TimelineCursor> cursors,
    ) => TimelineParser.parse(
      events,
      pendingBuildBegins: {},
      pendingLayoutBegins: {},
      pendingPaintBegins: {},
      pendingRasterBegins: {},
      pendingShaderBegins: {},
      pendingChannelBegins: {},
      cursorsByTid: cursors,
    );

    // measured per event (serial, debug JIT, M1 Pro): 1k → 0.35 µs,
    // 5k → 0.2 µs.
    for (final count in [1000, 5000]) {
      test('$count fresh events, B/E pairs, cursors', () {
        final events = frameEvents(count);
        final avgUs = benchmarkUs(
          'parse $count fresh events with cursors',
          () => parseWith(events, {}),
        );
        expect(avgUs / count, lessThan(3 * budgetMultiplier));
      });
    }

    // A re-read event still costs three hash lookups (`ts`, `tid`, the
    // cursor), so it cannot be free; the trim removes the per-event
    // signature string. Measured (serial, debug JIT, M1 Pro): re-read
    // 17 % of a fresh parse (before the trim: 37 %, with the fresh parse
    // itself 40 % slower).
    test('5000 already-seen events cost under 30 % of a fresh parse and '
        'build one signature per thread', () {
      final events = frameEvents(5000);
      final fresh = benchmarkUs(
        'parse 5000 fresh events',
        () => parseWith(events, {}),
        warmup: 200,
        iterations: 100,
      );
      final cursors = <int, TimelineCursor>{};
      parseWith(events, cursors);
      late ParsedTimelineData last;
      final reread = benchmarkUs(
        're-read 5000 seen events',
        () => last = parseWith(events, cursors),
        warmup: 200,
        iterations: 100,
      );
      // ignore: avoid_print
      print(
        '  re-read / fresh: ${(reread / fresh * 100).toStringAsFixed(1)} %',
      );
      expect(last.duplicatesDropped, 5000);
      expect(last.hasData, isFalse);
      expect(last.maxTimestampUs, -1);
      for (final cursor in cursors.values) {
        expect(cursor.seenSignatures, hasLength(1));
      }
      expect(reread, lessThan(fresh * 0.3));
    });
  });
}
