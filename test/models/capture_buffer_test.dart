import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/sleuth.dart';

CaptureEntry _entry({required int totalDurationUs, int frameNumber = 0}) {
  return CaptureEntry(
    frameStats: FrameStats(
      frameNumber: frameNumber,
      uiDuration: Duration(microseconds: totalDurationUs),
      rasterDuration: Duration.zero,
      timestamp: DateTime.utc(2026),
    ),
    verdict: const FrameVerdict(
      frameNumber: 0,
      totalFrameTime: Duration.zero,
      uiThreadTime: Duration.zero,
      rasterThreadTime: Duration.zero,
      suspectedPhase: PipelinePhase.unknown,
      reason: '',
    ),
    relatedIssues: const [],
    capturedAt: DateTime.utc(2026),
  );
}

void main() {
  group('JankCaptureBuffer', () {
    test('add within capacity retains all entries', () {
      final buffer = JankCaptureBuffer(capacity: 5);
      for (int i = 0; i < 5; i++) {
        buffer.add(_entry(totalDurationUs: 20000 + i * 1000));
      }
      expect(buffer.length, 5);
    });

    test('eviction when full replaces mildest entry', () {
      final buffer = JankCaptureBuffer(capacity: 3);
      buffer.add(_entry(totalDurationUs: 20000, frameNumber: 1)); // 20ms
      buffer.add(_entry(totalDurationUs: 30000, frameNumber: 2)); // 30ms
      buffer.add(_entry(totalDurationUs: 25000, frameNumber: 3)); // 25ms

      // Full. Add a worse entry (35ms) — should evict 20ms.
      buffer.add(_entry(totalDurationUs: 35000, frameNumber: 4));

      expect(buffer.length, 3);
      final durations = buffer.entries
          .map((e) => e.frameStats.totalDuration.inMicroseconds)
          .toList();
      expect(durations, containsAll([30000, 25000, 35000]));
      expect(durations, isNot(contains(20000)));
    });

    test('no eviction for mild entry when full', () {
      final buffer = JankCaptureBuffer(capacity: 3);
      buffer.add(_entry(totalDurationUs: 20000));
      buffer.add(_entry(totalDurationUs: 30000));
      buffer.add(_entry(totalDurationUs: 25000));

      // New entry (15ms) is milder than all existing — rejected.
      buffer.add(_entry(totalDurationUs: 15000));

      expect(buffer.length, 3);
      final durations = buffer.entries
          .map((e) => e.frameStats.totalDuration.inMicroseconds)
          .toList();
      expect(durations, isNot(contains(15000)));
    });

    test('entries returns unmodifiable list', () {
      final buffer = JankCaptureBuffer(capacity: 5);
      buffer.add(_entry(totalDurationUs: 20000));
      expect(() => buffer.entries.add(_entry(totalDurationUs: 10000)),
          throwsUnsupportedError);
    });

    test('empty state', () {
      final buffer = JankCaptureBuffer();
      expect(buffer.isEmpty, isTrue);
      expect(buffer.length, 0);
    });

    test('clear empties buffer', () {
      final buffer = JankCaptureBuffer();
      buffer.add(_entry(totalDurationUs: 20000));
      expect(buffer.length, 1);
      buffer.clear();
      expect(buffer.isEmpty, isTrue);
    });

    test('custom capacity respected', () {
      final buffer = JankCaptureBuffer(capacity: 2);
      buffer.add(_entry(totalDurationUs: 20000));
      buffer.add(_entry(totalDurationUs: 30000));
      buffer.add(_entry(totalDurationUs: 25000)); // evicts 20ms
      expect(buffer.length, 2);
    });

    test('updateVerdict replaces verdict for matching frame', () {
      final buffer = JankCaptureBuffer();
      buffer.add(_entry(totalDurationUs: 20000, frameNumber: 42));
      buffer.add(_entry(totalDurationUs: 30000, frameNumber: 43));

      expect(buffer.entries[0].verdict.topFunctions, isNull);

      const enrichedVerdict = FrameVerdict(
        frameNumber: 42,
        totalFrameTime: Duration.zero,
        uiThreadTime: Duration.zero,
        rasterThreadTime: Duration.zero,
        suspectedPhase: PipelinePhase.build,
        reason: 'enriched',
        topFunctions: [
          CpuAttribution(
            functionName: 'build',
            className: 'W',
            libraryUri: 'package:app/w.dart',
            percentage: 80.0,
          ),
        ],
      );

      buffer.updateVerdict(42, enrichedVerdict);

      // Frame 42 updated
      expect(buffer.entries[0].verdict.topFunctions, hasLength(1));
      expect(buffer.entries[0].verdict.reason, 'enriched');
      // Frame 43 unchanged
      expect(buffer.entries[1].verdict.topFunctions, isNull);
    });

    test('updateVerdict no-ops for non-existent frame', () {
      final buffer = JankCaptureBuffer();
      buffer.add(_entry(totalDurationUs: 20000, frameNumber: 1));

      const newVerdict = FrameVerdict(
        frameNumber: 999,
        totalFrameTime: Duration.zero,
        uiThreadTime: Duration.zero,
        rasterThreadTime: Duration.zero,
        suspectedPhase: PipelinePhase.unknown,
        reason: 'should not appear',
      );

      buffer.updateVerdict(999, newVerdict);
      expect(buffer.entries[0].verdict.reason, '');
    });
  });
}
