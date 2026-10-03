@Tags(['benchmark'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/frame_stats.dart';
import 'package:sleuth/src/vm/timeline_parser.dart';
import 'package:sleuth/src/vm/vm_service_client.dart';
import 'package:vm_service/vm_service.dart';

import '../helpers/benchmark_helpers.dart';

/// Real on-device timeline (iPhone 12, profile mode, rebuild workload).
const _capturePath =
    'test/validation/captures/rebuild_detector/critical_at.json';

/// Raw events per dispatched batch, matching a janky screen's poll.
const _batchSize = 1800;

/// One batch of parsed timeline data and the frames that produced it.
class _Batch {
  _Batch(this.data, this.frames);
  final ParsedTimelineData data;
  final List<FrameStats> frames;
}

/// Replays the capture [replays] times end to end (timestamps shifted so
/// the stream stays monotonic) and cuts it into [_batchSize]-event
/// batches, parsed with shared begin/cursor state as the poll loop does.
/// Every frame is janky (40 ms raster), as on the FPS stress screen.
List<_Batch> _buildBatches(int replays) {
  final raw =
      jsonDecode(File(_capturePath).readAsStringSync()) as Map<String, dynamic>;
  final indexed = <(int, Map<String, dynamic>)>[];
  var i = 0;
  for (final e in (raw['traceEvents'] as List).cast<Map<String, dynamic>>()) {
    if (e['ts'] is int) indexed.add((i++, e));
  }
  indexed.sort((a, b) {
    final c = (a.$2['ts'] as int).compareTo(b.$2['ts'] as int);
    return c != 0 ? c : a.$1.compareTo(b.$1);
  });
  final base = [for (final e in indexed) e.$2];
  final first = base.first['ts'] as int;
  final span = (base.last['ts'] as int) - first + 10000;

  final stream = <Map<String, dynamic>>[
    for (var r = 0; r < replays; r++)
      for (final e in base)
        <String, dynamic>{...e, 'ts': (e['ts'] as int) + r * span},
  ];

  final pendingBuild = <int, List<Map<String, dynamic>>>{};
  final pendingLayout = <int, List<Map<String, dynamic>>>{};
  final pendingPaint = <int, List<Map<String, dynamic>>>{};
  final pendingRaster = <int, List<Map<String, dynamic>>>{};
  final pendingShader = <int, List<Map<String, dynamic>>>{};
  final pendingChannel = <String, int>{};
  final cursors = <int, TimelineCursor>{};

  final batches = <_Batch>[];
  var frameNumber = 0;
  int? frameBegin;
  for (
    var start = 0;
    start + _batchSize <= stream.length;
    start += _batchSize
  ) {
    final chunk = stream.sublist(start, start + _batchSize);
    final frames = <FrameStats>[];
    for (final e in chunk) {
      if (e['name'] != 'Frame') continue;
      final ts = e['ts'] as int;
      if (e['ph'] == 'b') {
        frameBegin = ts;
      } else if (e['ph'] == 'e' && frameBegin != null) {
        final rasterStart = ts + 200;
        frames.add(
          FrameStats(
            frameNumber: frameNumber++,
            uiDuration: Duration(microseconds: ts - frameBegin),
            rasterDuration: const Duration(milliseconds: 40),
            timestamp: DateTime.now(),
            vsyncStartUs: frameBegin,
            buildStartUs: frameBegin,
            buildFinishUs: ts,
            rasterStartUs: rasterStart,
            rasterFinishUs: rasterStart + 40000,
          ),
        );
        frameBegin = null;
      }
    }
    final data = TimelineParser.parse(
      [for (final e in chunk) TimelineEvent.parse(e)!],
      pendingBuildBegins: pendingBuild,
      pendingLayoutBegins: pendingLayout,
      pendingPaintBegins: pendingPaint,
      pendingRasterBegins: pendingRaster,
      pendingShaderBegins: pendingShader,
      pendingChannelBegins: pendingChannel,
      cursorsByTid: cursors,
    );
    batches.add(_Batch(data, frames));
  }
  return batches;
}

/// Mean per-segment cost of dispatching [batches] (after the first,
/// which warms the controller) through one controller, in microseconds.
({double total, double detectors, double correlate, double aggregate})
_runStream(List<_Batch> batches) {
  final controller = SleuthController()
    ..initializeDetectorsForTest()
    ..simulateVmStateChangeForTest(true);
  var total = 0;
  var detectors = 0;
  var correlate = 0;
  var aggregate = 0;
  final watch = Stopwatch();
  for (var b = 0; b < batches.length; b++) {
    for (final f in batches[b].frames) {
      controller.addFrameForTest(f);
    }
    watch
      ..reset()
      ..start();
    controller.feedTimelineDataForTest(batches[b].data);
    watch.stop();
    if (b == 0) continue;
    final s = controller.lastDispatchSegmentsForTest;
    total += watch.elapsedMicroseconds;
    detectors += s.detectors;
    correlate += s.correlate;
    aggregate += s.aggregate;
  }
  controller.dispose();
  final n = batches.length - 1;
  return (
    total: total / n,
    detectors: detectors / n,
    correlate: correlate / n,
    aggregate: aggregate / n,
  );
}

void main() {
  test('dispatch of 1,800-event batches from a real capture', () {
    final batches = _buildBatches(8);
    final phaseEvents = batches
        .map((b) => b.data.phaseEvents.length)
        .reduce((a, b) => a + b);
    final frames = batches.map((b) => b.frames.length).reduce((a, b) => a + b);

    // Two warm-up streams for the JIT, then the measured stream.
    _runStream(batches);
    _runStream(batches);
    final r = _runStream(batches);
    final other = r.total - r.detectors - r.correlate - r.aggregate;

    // ignore: avoid_print
    print(
      '  ${batches.length} batches x $_batchSize events '
      '(${(phaseEvents / batches.length).round()} phase events, '
      '${(frames / batches.length).round()} frames per batch)\n'
      '  dispatch ${r.total.toStringAsFixed(0)} us: '
      'detectors ${r.detectors.toStringAsFixed(0)}, '
      'correlate ${r.correlate.toStringAsFixed(0)}, '
      'aggregate ${r.aggregate.toStringAsFixed(0)}, '
      'other ${other.toStringAsFixed(0)}',
    );

    // measured (serial, debug JIT, M1 Pro): about 130 us per batch.
    expect(r.total, lessThan(2000 * budgetMultiplier));
  });

  // Each `getCpuSamples` request stalls the UI isolate: the VM builds the
  // profile on the isolate's own thread and the multi-MB response is
  // decoded there. Measured on an M1 Pro (JIT, 60 ms window): +19 ms on
  // the synchronous code it interrupts and +95 ms on the next await.
  test('CPU attribution requests over a janky stream', () async {
    final batches = _buildBatches(8);
    Future<int> requests(Duration minInterval) async {
      final service = _CountingVmService();
      final client = VmServiceClient(cpuSamplesMinInterval: minInterval)
        ..setServiceForTest(service, isolateId: 'isolates/1');
      final controller = SleuthController()
        ..initializeDetectorsForTest()
        ..setVmClientForTest(client)
        ..simulateVmStateChangeForTest(true);
      for (final batch in batches) {
        for (final f in batch.frames) {
          controller.addFrameForTest(f);
        }
        controller.feedTimelineDataForTest(batch.data);
        // Let the fake answer before the next poll.
        await Future<void>.delayed(Duration.zero);
      }
      controller.dispose();
      return service.cpuSamplesCalls;
    }

    final everyPoll = await requests(Duration.zero);
    final spaced = await requests(const Duration(seconds: 10));
    // ignore: avoid_print
    print(
      '  getCpuSamples over ${batches.length} janky polls: '
      'unspaced $everyPoll, default spacing $spaced',
    );
    expect(everyPoll, batches.length);
    expect(spaced, 1);
  });
}

/// Answers `getCpuSamples` with an empty profile and counts the calls.
class _CountingVmService implements VmService {
  int cpuSamplesCalls = 0;

  @override
  Future<CpuSamples> getCpuSamples(
    String isolateId,
    int timeOriginMicros,
    int timeExtentMicros,
  ) async {
    cpuSamplesCalls++;
    return CpuSamples(
      sampleCount: 0,
      samplePeriod: 1000,
      maxStackDepth: 128,
      timeOriginMicros: timeOriginMicros,
      timeExtentMicros: timeExtentMicros,
      pid: 1,
      functions: [],
      samples: [],
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
