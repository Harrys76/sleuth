import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/src/detectors/frame_timing_detector.dart';
import 'package:widget_watchdog/src/models/frame_stats.dart';
import 'package:widget_watchdog/src/models/performance_issue.dart';
import 'package:widget_watchdog/src/vm/timeline_parser.dart';

void main() {
  group('FrameTimingDetector', () {
    late FrameTimingDetector detector;

    setUp(() {
      detector = FrameTimingDetector();
    });

    FrameStats makeFrame({
      required int uiMs,
      required int rasterMs,
      int frameNumber = 1,
      int frameBudgetMs = 16,
    }) {
      return FrameStats(
        frameNumber: frameNumber,
        uiDuration: Duration(milliseconds: uiMs),
        rasterDuration: Duration(milliseconds: rasterMs),
        timestamp: DateTime.now(),
        frameBudgetMs: frameBudgetMs,
      );
    }

    void addGoodFrames(int count) {
      for (var i = 0; i < count; i++) {
        detector.addFrameForTest(makeFrame(
          uiMs: 8,
          rasterMs: 6,
          frameNumber: i + 1,
        ));
      }
    }

    test('no issues when disabled', () {
      detector.isEnabled = false;
      for (var i = 0; i < 10; i++) {
        detector.addFrameForTest(makeFrame(
          uiMs: 40,
          rasterMs: 40,
          frameNumber: i + 1,
        ));
      }
      expect(detector.issues, isEmpty);
    });

    test('no issues with fewer than 5 frames', () {
      for (var i = 0; i < 4; i++) {
        detector.addFrameForTest(makeFrame(
          uiMs: 40,
          rasterMs: 40,
          frameNumber: i + 1,
        ));
      }
      expect(detector.issues, isEmpty);
    });

    test('no issues when all frames under budget', () {
      addGoodFrames(20);
      expect(detector.issues, isEmpty);
    });

    test('warning when >15% frames janky', () {
      // 10 good frames + 3 janky = 13 frames, 23% janky
      addGoodFrames(10);
      for (var i = 0; i < 3; i++) {
        detector.addFrameForTest(makeFrame(
          uiMs: 20,
          rasterMs: 8,
          frameNumber: 11 + i,
        ));
      }

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.severity, IssueSeverity.warning);
      expect(detector.issues.first.title, contains('Jank Detected'));
    });

    test('no warning when exactly 15% janky', () {
      // 17 good + 3 janky = 20 frames, 15% janky — boundary, should not trigger
      addGoodFrames(17);
      for (var i = 0; i < 3; i++) {
        detector.addFrameForTest(makeFrame(
          uiMs: 20,
          rasterMs: 8,
          frameNumber: 18 + i,
        ));
      }

      expect(detector.issues, isEmpty);
    });

    test('critical when >=3 severe jank frames', () {
      addGoodFrames(10);
      // 3 severe frames (>33ms)
      for (var i = 0; i < 3; i++) {
        detector.addFrameForTest(makeFrame(
          uiMs: 40,
          rasterMs: 8,
          frameNumber: 11 + i,
        ));
      }

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.severity, IssueSeverity.critical);
      expect(detector.issues.first.title, contains('Sustained Jank'));
    });

    test('issue confidence is confirmed', () {
      addGoodFrames(10);
      for (var i = 0; i < 3; i++) {
        detector.addFrameForTest(makeFrame(
          uiMs: 40,
          rasterMs: 8,
          frameNumber: 11 + i,
        ));
      }

      expect(detector.issues.first.confidence, IssueConfidence.confirmed);
    });

    test('detail includes bottleneck hint (UI dominant)', () {
      addGoodFrames(10);
      for (var i = 0; i < 3; i++) {
        detector.addFrameForTest(makeFrame(
          uiMs: 40,
          rasterMs: 8,
          frameNumber: 11 + i,
        ));
      }

      expect(detector.issues.first.detail, contains('UI thread'));
    });

    test('detail includes bottleneck hint (raster dominant)', () {
      addGoodFrames(10);
      for (var i = 0; i < 3; i++) {
        detector.addFrameForTest(makeFrame(
          uiMs: 8,
          rasterMs: 40,
          frameNumber: 11 + i,
        ));
      }

      expect(detector.issues.first.detail, contains('Raster thread'));
    });

    test('detail includes VM timeline sub-breakdown when available', () {
      detector.updateTimelineData(ParsedTimelineData(
        buildScopeDurations: [5000],
        flushLayoutDurations: [3000],
        flushPaintDurations: [2000],
      ));

      addGoodFrames(10);
      for (var i = 0; i < 3; i++) {
        detector.addFrameForTest(makeFrame(
          uiMs: 40,
          rasterMs: 8,
          frameNumber: 11 + i,
        ));
      }

      expect(detector.issues.first.detail, contains('buildScope'));
      expect(detector.issues.first.detail, contains('flushLayout'));
      expect(detector.issues.first.detail, contains('flushPaint'));
    });

    test('custom thresholds affect jank detection', () {
      // 120fps target: 8ms budget, severe = 16ms
      detector = FrameTimingDetector(fpsTarget: 120);

      // Frames at 12ms — not janky at 60fps but janky at 120fps
      for (var i = 0; i < 20; i++) {
        detector.addFrameForTest(makeFrame(
          uiMs: 12,
          rasterMs: 4,
          frameNumber: i + 1,
          frameBudgetMs: 8,
        ));
      }

      // All frames are janky at 120fps (12ms > 8ms budget)
      expect(detector.issues, isNotEmpty);
    });

    test('fpsTarget=120 uses 8ms budget', () {
      final detector120 = FrameTimingDetector(fpsTarget: 120);
      expect(detector120.warningThresholdMs, 8);
      expect(detector120.criticalThresholdMs, 16);
    });

    test('dispose clears state', () {
      addGoodFrames(10);
      for (var i = 0; i < 3; i++) {
        detector.addFrameForTest(makeFrame(
          uiMs: 40,
          rasterMs: 8,
          frameNumber: 11 + i,
        ));
      }
      expect(detector.issues, isNotEmpty);

      detector.dispose();
      expect(detector.issues, isEmpty);
      expect(detector.frameBuffer.isEmpty, isTrue);
    });
  });
}
