import 'package:flutter_test/flutter_test.dart';
import 'package:vm_service/vm_service.dart';
import 'package:widget_watchdog/src/detectors/memory_pressure_detector.dart';
import 'package:widget_watchdog/src/detectors/network_monitor_detector.dart';
import 'package:widget_watchdog/src/models/heap_sample.dart';
import 'package:widget_watchdog/src/network/request_record.dart';
import 'package:widget_watchdog/src/vm/cpu_sample_aggregator.dart';

import '../helpers/benchmark_helpers.dart';

void main() {
  group('v2 performance benchmarks', () {
    // Gap 3: processRecord < 100µs, aggregate 1000 samples < 5ms,
    //         processHeapSample < 50µs

    test('NetworkMonitorDetector.processRecord < 100µs', () {
      final detector = NetworkMonitorDetector();
      detector.isEnabled = true;

      final record = RequestRecord(
        url: 'https://api.example.com/data',
        method: 'get',
        statusCode: 200,
        durationMs: 150,
        responseBytes: 4096,
        startedAt: DateTime.now(),
      );

      final avgUs = benchmarkUs(
        'processRecord',
        () => detector.processRecord(record),
      );

      expect(avgUs, lessThan(100 * budgetMultiplier),
          reason: 'processRecord should complete in < 100µs');
    });

    test('CpuSampleAggregator.aggregate 1000 samples < 5ms', () {
      const aggregator = CpuSampleAggregator();

      // Build a CpuSamples object with 1000 samples and 50 functions
      final functions = List.generate(
        50,
        (i) => ProfileFunction(
          kind: 'Dart',
          inclusiveTicks: 0,
          exclusiveTicks: 0,
          resolvedUrl: 'package:app/widget_$i.dart',
          function: FuncRef(
            id: 'func/$i',
            name: 'build',
            owner: ClassRef(
              id: 'class/$i',
              name: 'Widget$i',
              library: LibraryRef(
                id: 'lib/$i',
                uri: 'package:app/widget_$i.dart',
              ),
            ),
          ),
        ),
      );

      final samples = List.generate(
        1000,
        (i) => CpuSample(
          tid: 1,
          timestamp: i * 100,
          stack: [i % 50],
        ),
      );

      final cpuSamples = CpuSamples(
        sampleCount: 1000,
        samplePeriod: 100,
        maxStackDepth: 128,
        timeOriginMicros: 0,
        timeExtentMicros: 100000,
        pid: 1,
        functions: functions,
        samples: samples,
      );

      final avgUs = benchmarkUs(
        'aggregate 1000 samples',
        () => aggregator.aggregate(cpuSamples),
      );

      expect(avgUs, lessThan(5000 * budgetMultiplier),
          reason: 'aggregate 1000 samples should complete in < 5ms');
    });

    test('MemoryPressureDetector.processHeapSample < 50µs', () {
      final detector = MemoryPressureDetector();
      detector.isEnabled = true;

      int sampleIndex = 0;
      final avgUs = benchmarkUs(
        'processHeapSample',
        () {
          detector.processHeapSample(HeapSample(
            heapUsage: 50000000 + sampleIndex * 1000,
            heapCapacity: 100000000,
            externalUsage: 5000000,
            timestamp: DateTime.now(),
          ));
          sampleIndex++;
        },
      );

      expect(avgUs, lessThan(50 * budgetMultiplier),
          reason: 'processHeapSample should complete in < 50µs');
    });
  });
}
