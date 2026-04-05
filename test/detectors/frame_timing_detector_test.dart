import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/detectors/frame_timing_detector.dart';
import 'package:sleuth/src/models/frame_stats.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/vm/timeline_parser.dart';

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
      int pictureCacheCount = 0,
      int pictureCacheBytes = 0,
      int layerCacheCount = 0,
      int layerCacheBytes = 0,
    }) {
      return FrameStats(
        frameNumber: frameNumber,
        uiDuration: Duration(milliseconds: uiMs),
        rasterDuration: Duration(milliseconds: rasterMs),
        timestamp: DateTime.now(),
        frameBudgetMs: frameBudgetMs,
        pictureCacheCount: pictureCacheCount,
        pictureCacheBytes: pictureCacheBytes,
        layerCacheCount: layerCacheCount,
        layerCacheBytes: layerCacheBytes,
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

    // -- Raster Cache Trends --

    group('Raster Cache Trends', () {
      test('no cache issues with stable cache metrics', () {
        for (var i = 0; i < 20; i++) {
          detector.addFrameForTest(makeFrame(
            uiMs: 8,
            rasterMs: 6,
            frameNumber: i + 1,
            pictureCacheCount: 10,
            pictureCacheBytes: 50000,
            layerCacheCount: 5,
            layerCacheBytes: 20000,
          ));
        }

        final cacheIssues = detector.issues
            .where((i) => i.category == IssueCategory.raster)
            .toList();
        expect(cacheIssues, isEmpty);
      });

      test('no thrashing when variation <= 20%', () {
        // pictureCacheCount alternates between 10 and 12 → 20% variation (boundary)
        for (var i = 0; i < 20; i++) {
          detector.addFrameForTest(makeFrame(
            uiMs: 8,
            rasterMs: 6,
            frameNumber: i + 1,
            pictureCacheCount: i.isEven ? 10 : 12,
            pictureCacheBytes: 50000,
          ));
        }

        final thrashing = detector.issues
            .where((i) => i.stableId == 'raster_cache_thrashing')
            .toList();
        expect(thrashing, isEmpty);
      });

      test('no thrashing when cache count <= 5 despite high variation', () {
        // pictureCacheCount alternates between 2 and 3 → 50% variation
        // but count <= 5 should be ignored as noise
        for (var i = 0; i < 20; i++) {
          detector.addFrameForTest(makeFrame(
            uiMs: 8,
            rasterMs: 6,
            frameNumber: i + 1,
            pictureCacheCount: i.isEven ? 2 : 3,
            pictureCacheBytes: 5000,
          ));
        }

        final thrashing = detector.issues
            .where((i) => i.stableId == 'raster_cache_thrashing')
            .toList();
        expect(thrashing, isEmpty);
      });

      test('detects cache thrashing after 15 consecutive fluctuating frames',
          () {
        // Seed with one stable frame first
        detector.addFrameForTest(makeFrame(
          uiMs: 8,
          rasterMs: 6,
          frameNumber: 1,
          pictureCacheCount: 10,
          pictureCacheBytes: 50000,
        ));

        // 16 frames alternating between 10 and 15 → 50% variation
        for (var i = 0; i < 16; i++) {
          detector.addFrameForTest(makeFrame(
            uiMs: 8,
            rasterMs: 6,
            frameNumber: i + 2,
            pictureCacheCount: i.isEven ? 15 : 10,
            pictureCacheBytes: 50000,
          ));
        }

        final thrashing = detector.issues
            .where((i) => i.stableId == 'raster_cache_thrashing')
            .toList();
        expect(thrashing, hasLength(1));
        expect(thrashing.first.severity, IssueSeverity.warning);
        expect(thrashing.first.category, IssueCategory.raster);
        expect(thrashing.first.confidence, IssueConfidence.confirmed);
      });

      test('thrashing counter resets when variation drops', () {
        // Seed frame
        detector.addFrameForTest(makeFrame(
          uiMs: 8,
          rasterMs: 6,
          frameNumber: 1,
          pictureCacheCount: 10,
          pictureCacheBytes: 50000,
        ));

        // 10 thrashing frames (not enough for threshold of 15)
        for (var i = 0; i < 10; i++) {
          detector.addFrameForTest(makeFrame(
            uiMs: 8,
            rasterMs: 6,
            frameNumber: i + 2,
            pictureCacheCount: i.isEven ? 15 : 10,
            pictureCacheBytes: 50000,
          ));
        }

        // Then stable frames → counter resets
        for (var i = 0; i < 20; i++) {
          detector.addFrameForTest(makeFrame(
            uiMs: 8,
            rasterMs: 6,
            frameNumber: i + 12,
            pictureCacheCount: 10,
            pictureCacheBytes: 50000,
          ));
        }

        final thrashing = detector.issues
            .where((i) => i.stableId == 'raster_cache_thrashing')
            .toList();
        expect(thrashing, isEmpty);
      });

      test('no growth when cache bytes fluctuate', () {
        for (var i = 0; i < 40; i++) {
          detector.addFrameForTest(makeFrame(
            uiMs: 8,
            rasterMs: 6,
            frameNumber: i + 1,
            pictureCacheBytes: i.isEven ? 50000 : 48000,
            layerCacheBytes: 20000,
          ));
        }

        final growth = detector.issues
            .where((i) => i.stableId == 'raster_cache_growing')
            .toList();
        expect(growth, isEmpty);
      });

      test('detects cache growth after 30 consecutive monotonic frames', () {
        for (var i = 0; i < 32; i++) {
          detector.addFrameForTest(makeFrame(
            uiMs: 8,
            rasterMs: 6,
            frameNumber: i + 1,
            pictureCacheBytes: 50000 + i * 1024,
            layerCacheBytes: 20000,
          ));
        }

        final growth = detector.issues
            .where((i) => i.stableId == 'raster_cache_growing')
            .toList();
        expect(growth, hasLength(1));
        expect(growth.first.severity, IssueSeverity.warning);
        expect(growth.first.category, IssueCategory.raster);
        expect(growth.first.title, contains('KB'));
      });

      test('growth counter resets on decrease', () {
        // 25 growing frames
        for (var i = 0; i < 25; i++) {
          detector.addFrameForTest(makeFrame(
            uiMs: 8,
            rasterMs: 6,
            frameNumber: i + 1,
            pictureCacheBytes: 50000 + i * 1024,
            layerCacheBytes: 20000,
          ));
        }

        // One decrease
        detector.addFrameForTest(makeFrame(
          uiMs: 8,
          rasterMs: 6,
          frameNumber: 26,
          pictureCacheBytes: 40000,
          layerCacheBytes: 20000,
        ));

        // Then 25 more growing
        for (var i = 0; i < 25; i++) {
          detector.addFrameForTest(makeFrame(
            uiMs: 8,
            rasterMs: 6,
            frameNumber: 27 + i,
            pictureCacheBytes: 50000 + i * 1024,
            layerCacheBytes: 20000,
          ));
        }

        final growth = detector.issues
            .where((i) => i.stableId == 'raster_cache_growing')
            .toList();
        expect(growth, isEmpty);
      });

      test('layer cache growth triggers raster_cache_growing issue', () {
        // layerCacheBytes increasing monotonically for 35 frames
        // (growth window is 30 frames)
        for (var i = 0; i < 35; i++) {
          detector.addFrameForTest(makeFrame(
            uiMs: 8,
            rasterMs: 6,
            frameNumber: i + 1,
            pictureCacheCount: 10,
            pictureCacheBytes: 50000, // stable
            layerCacheCount: 5 + i,
            layerCacheBytes: 20000 + i * 2048, // growing
          ));
        }

        final growth = detector.issues
            .where((i) => i.stableId == 'raster_cache_growing')
            .toList();
        expect(growth, hasLength(1));
        expect(growth.first.detail, contains('Layer cache'));
      });

      test('suppresses cache analysis when all metrics zero for 30 frames', () {
        // 31 frames with all-zero cache → Impeller detected
        for (var i = 0; i < 31; i++) {
          detector.addFrameForTest(makeFrame(
            uiMs: 8,
            rasterMs: 6,
            frameNumber: i + 1,
          ));
        }

        final cacheIssues = detector.issues
            .where((i) => i.category == IssueCategory.raster)
            .toList();
        expect(cacheIssues, isEmpty);
      });

      test('Impeller suppression resets on non-zero frame', () {
        // 35 zero frames → Impeller detected
        for (var i = 0; i < 35; i++) {
          detector.addFrameForTest(makeFrame(
            uiMs: 8,
            rasterMs: 6,
            frameNumber: i + 1,
          ));
        }

        // Non-zero frame → suppression lifted, then thrashing frames
        detector.addFrameForTest(makeFrame(
          uiMs: 8,
          rasterMs: 6,
          frameNumber: 36,
          pictureCacheCount: 10,
          pictureCacheBytes: 50000,
        ));

        // Followed by enough thrashing frames to trigger
        for (var i = 0; i < 16; i++) {
          detector.addFrameForTest(makeFrame(
            uiMs: 8,
            rasterMs: 6,
            frameNumber: 37 + i,
            pictureCacheCount: i.isEven ? 15 : 10,
            pictureCacheBytes: 50000,
          ));
        }

        final thrashing = detector.issues
            .where((i) => i.stableId == 'raster_cache_thrashing')
            .toList();
        expect(thrashing, hasLength(1));
      });

      test('cache issues coexist with jank issues', () {
        // Seed with one stable frame
        detector.addFrameForTest(makeFrame(
          uiMs: 8,
          rasterMs: 6,
          frameNumber: 1,
          pictureCacheCount: 10,
          pictureCacheBytes: 50000,
        ));

        // 17 severe jank frames with alternating cache count (50% variation)
        // All frames alternate: 15, 10, 15, 10... ensuring continuous thrashing
        for (var i = 0; i < 17; i++) {
          detector.addFrameForTest(makeFrame(
            uiMs: 40,
            rasterMs: 40,
            frameNumber: 2 + i,
            pictureCacheCount: i.isEven ? 15 : 10,
            pictureCacheBytes: 50000,
          ));
        }

        // Jank: 17 severe frames in 18 total → critical sustained jank
        final jankIssues = detector.issues
            .where((i) => i.category == IssueCategory.build)
            .toList();
        expect(jankIssues, isNotEmpty);

        // Cache: seed(10)→15→10→15→10... = 17 consecutive thrashing frames
        final thrashing = detector.issues
            .where((i) => i.stableId == 'raster_cache_thrashing')
            .toList();
        expect(thrashing, hasLength(1));
      });
    });
  });
}
