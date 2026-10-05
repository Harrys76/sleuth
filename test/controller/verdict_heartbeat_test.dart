import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/capture_buffer.dart';
import 'package:sleuth/src/models/frame_stats.dart';
import 'package:sleuth/src/models/frame_verdict.dart';
import 'package:sleuth/src/models/phase_event.dart';
import 'package:sleuth/src/vm/timeline_parser.dart';
import 'package:sleuth/src/vm/vm_service_client.dart';
import 'package:vm_service/vm_service.dart';

// Frame i: vsync at 100 ms + i × 50 ms, 30 ms build, 10 ms raster.
int _vsyncOf(int i) => 100000 + i * 50000;

FrameStats _jankFrame(int i, {bool phaseTimestamps = true}) {
  final vsync = _vsyncOf(i);
  return FrameStats(
    frameNumber: i + 1,
    uiDuration: const Duration(milliseconds: 30),
    rasterDuration: const Duration(milliseconds: 10),
    timestamp: DateTime.now(),
    frameBudgetMs: 16,
    vsyncStartUs: phaseTimestamps ? vsync : null,
    buildStartUs: phaseTimestamps ? vsync + 500 : null,
    buildFinishUs: phaseTimestamps ? vsync + 30500 : null,
    rasterStartUs: phaseTimestamps ? vsync + 31000 : null,
    rasterFinishUs: phaseTimestamps ? vsync + 41000 : null,
  );
}

/// Build, layout, paint and raster events inside frame [i]'s windows.
ParsedTimelineData _batchForFrame(int i) {
  final vsync = _vsyncOf(i);
  return ParsedTimelineData(
    buildScopeDurations: const [20000],
    flushLayoutDurations: const [4000],
    flushPaintDurations: const [2000],
    rasterDurations: const [8000],
    phaseEvents: [
      PhaseEvent(
        phase: TimelinePhase.build,
        timestampUs: vsync + 1000,
        durationUs: 20000,
      ),
      PhaseEvent(
        phase: TimelinePhase.layout,
        timestampUs: vsync + 21000,
        durationUs: 4000,
      ),
      PhaseEvent(
        phase: TimelinePhase.paint,
        timestampUs: vsync + 26000,
        durationUs: 2000,
      ),
      PhaseEvent(
        phase: TimelinePhase.raster,
        timestampUs: vsync + 32000,
        durationUs: 8000,
      ),
    ],
  );
}

/// Phase events far from every frame: nothing correlates, so only the
/// batch-attributed full-mode path can produce a verdict.
ParsedTimelineData _uncorrelatedBatch() => ParsedTimelineData(
  buildScopeDurations: const [20000],
  rasterDurations: const [8000],
  phaseEvents: const [
    PhaseEvent(
      phase: TimelinePhase.build,
      timestampUs: 900000000,
      durationUs: 20000,
    ),
  ],
);

CpuSamples _cpuSamples() => CpuSamples(
  functions: [
    ProfileFunction(
      kind: 'Dart',
      inclusiveTicks: 0,
      exclusiveTicks: 0,
      resolvedUrl: 'package:app/a.dart',
      function: FuncRef(
        id: 'func/build',
        name: 'build',
        owner: ClassRef(
          id: 'class/Feed',
          name: 'Feed',
          library: LibraryRef(id: 'lib/a', uri: 'package:app/a.dart'),
        ),
      ),
    ),
  ],
  samples: [
    for (var i = 0; i < 10; i++)
      CpuSample(tid: 1, timestamp: 1000000 + i, stack: const [0]),
  ],
  samplePeriod: 1000,
  sampleCount: 10,
  maxStackDepth: 128,
  timeOriginMicros: 0,
  timeExtentMicros: 1000000,
  pid: 1,
);

class _CountingCpuClient extends VmServiceClient {
  int cpuSamplesCalls = 0;

  @override
  bool get isConnected => true;

  @override
  Future<CpuSamples?> getCpuSamples({
    required int timeOriginUs,
    required int timeExtentUs,
  }) async {
    cpuSamplesCalls++;
    return _cpuSamples();
  }

  @override
  void dispose() {}
}

void main() {
  late SleuthController controller;

  setUp(() {
    controller = SleuthController(
      config: const SleuthConfig(
        frameTimingWarmupFrameCount: 0,
        frameTimingWarmupDuration: Duration.zero,
      ),
    );
    controller.initializeDetectorsForTest();
    controller.markInitializedAtForTest(
      DateTime.now().subtract(const Duration(seconds: 10)),
    );
    controller.simulateVmStateChangeForTest(true);
  });

  tearDown(() {
    controller.dispose();
  });

  group('verdict after a correlated jank verdict', () {
    test('empty heartbeat batches leave the correlated verdict and the '
        'capture untouched', () {
      controller.addFrameForTest(_jankFrame(0));
      controller.feedTimelineDataForTest(_batchForFrame(0));

      final correlated = controller.verdictNotifier.value;
      expect(correlated, isNotNull);
      expect(correlated!.isCorrelated, isTrue);
      final captured = controller.captureBufferForTest.entries.single;
      expect(captured.verdict.isCorrelated, isTrue);

      var fired = 0;
      void listener() => fired++;
      controller.verdictNotifier.addListener(listener);
      for (var i = 0; i < 3; i++) {
        controller.feedTimelineDataForTest(ParsedTimelineData());
      }
      controller.verdictNotifier.removeListener(listener);

      expect(fired, 0);
      expect(identical(controller.verdictNotifier.value, correlated), isTrue);
      final after = controller.captureBufferForTest.entries.single;
      expect(identical(after, captured), isTrue);
    });

    test('a GC-only batch keeps the correlated verdict', () {
      controller.addFrameForTest(_jankFrame(0));
      controller.feedTimelineDataForTest(_batchForFrame(0));
      final correlated = controller.verdictNotifier.value;

      controller.feedTimelineDataForTest(
        ParsedTimelineData(
          gcEvents: [
            TimelineEvent.parse({
              'name': 'CollectNewGeneration',
              'cat': 'GC',
              'ph': 'X',
              'ts': 500000,
              'dur': 900,
            })!,
          ],
        ),
      );

      expect(identical(controller.verdictNotifier.value, correlated), isTrue);
    });

    test('a batch with phase data that correlates nothing keeps the '
        'correlated verdict of the latest frame', () {
      controller.addFrameForTest(_jankFrame(0));
      controller.feedTimelineDataForTest(_batchForFrame(0));
      final correlated = controller.verdictNotifier.value;

      controller.feedTimelineDataForTest(_uncorrelatedBatch());

      expect(identical(controller.verdictNotifier.value, correlated), isTrue);
    });

    test('a later batch with phase data for a new jank frame updates the '
        'verdict', () {
      controller.addFrameForTest(_jankFrame(0));
      controller.feedTimelineDataForTest(_batchForFrame(0));
      controller.feedTimelineDataForTest(ParsedTimelineData());

      controller.addFrameForTest(_jankFrame(1));
      controller.feedTimelineDataForTest(_batchForFrame(1));

      final verdict = controller.verdictNotifier.value!;
      expect(verdict.isCorrelated, isTrue);
      expect(verdict.frameNumber, 2);
      expect(controller.captureBufferForTest.entries, hasLength(2));
    });

    test('a full-mode verdict for a new frame replaces the correlated one '
        'for an earlier frame', () {
      controller.addFrameForTest(_jankFrame(0));
      controller.feedTimelineDataForTest(_batchForFrame(0));
      expect(controller.verdictNotifier.value!.isCorrelated, isTrue);

      controller.addFrameForTest(_jankFrame(1, phaseTimestamps: false));
      controller.feedTimelineDataForTest(_uncorrelatedBatch());

      final verdict = controller.verdictNotifier.value!;
      expect(verdict.isCorrelated, isFalse);
      expect(verdict.isFullMode, isTrue);
      expect(verdict.frameNumber, 2);
    });
  });

  group('CPU attribution', () {
    test('a frame is attributed once; a later verdict for it keeps the '
        'attribution', () async {
      final client = _CountingCpuClient();
      controller.setVmClientForTest(client);

      controller.addFrameForTest(_jankFrame(0));
      controller.feedTimelineDataForTest(_batchForFrame(0));
      await Future<void>.delayed(Duration.zero);

      expect(client.cpuSamplesCalls, 1);
      expect(controller.verdictNotifier.value!.topFunctions, isNotEmpty);
      expect(
        controller.captureBufferForTest.entries.single.verdict.topFunctions,
        isNotEmpty,
      );

      // The same frame is correlated again by a later batch.
      controller.feedTimelineDataForTest(_batchForFrame(0));
      await Future<void>.delayed(Duration.zero);
      for (var i = 0; i < 3; i++) {
        controller.feedTimelineDataForTest(ParsedTimelineData());
      }
      await Future<void>.delayed(Duration.zero);

      expect(client.cpuSamplesCalls, 1);
      final verdict = controller.verdictNotifier.value!;
      expect(verdict.isCorrelated, isTrue);
      expect(verdict.topFunctions, isNotEmpty);
    });
  });

  group('JankCaptureBuffer.updateVerdict', () {
    FrameVerdict verdict({required bool correlated, String reason = ''}) =>
        FrameVerdict(
          frameNumber: 7,
          totalFrameTime: Duration.zero,
          uiThreadTime: Duration.zero,
          rasterThreadTime: Duration.zero,
          suspectedPhase: PipelinePhase.build,
          reason: reason,
          isFullMode: true,
          isCorrelated: correlated,
        );

    CaptureEntry entry(FrameVerdict v) => CaptureEntry(
      frameStats: FrameStats(
        frameNumber: 7,
        uiDuration: const Duration(milliseconds: 30),
        rasterDuration: const Duration(milliseconds: 10),
        timestamp: DateTime.now(),
        frameBudgetMs: 16,
      ),
      verdict: v,
      relatedIssues: const [],
      capturedAt: DateTime.now(),
    );

    test('a correlated entry is not replaced by a non-correlated one', () {
      final buffer = JankCaptureBuffer()
        ..add(entry(verdict(correlated: true, reason: 'kept')));
      buffer.updateVerdict(7, verdict(correlated: false, reason: 'full'));
      expect(buffer.entries.single.verdict.reason, 'kept');
      expect(buffer.entries.single.verdict.isCorrelated, isTrue);
    });

    test('a correlated entry accepts a correlated replacement', () {
      final buffer = JankCaptureBuffer()
        ..add(entry(verdict(correlated: true, reason: 'old')));
      buffer.updateVerdict(7, verdict(correlated: true, reason: 'new'));
      expect(buffer.entries.single.verdict.reason, 'new');
    });

    test('a full entry accepts a full replacement', () {
      final buffer = JankCaptureBuffer()
        ..add(entry(verdict(correlated: false, reason: 'old')));
      buffer.updateVerdict(7, verdict(correlated: false, reason: 'new'));
      expect(buffer.entries.single.verdict.reason, 'new');
    });
  });
}
