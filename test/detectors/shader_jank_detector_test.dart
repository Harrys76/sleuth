import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/detectors/shader_jank_detector.dart';
import 'package:sleuth/src/models/performance_issue.dart';

import '../helpers/timeline_test_helpers.dart';

void main() {
  group('ShaderJankDetector', () {
    late ShaderJankDetector detector;

    setUp(() {
      detector = ShaderJankDetector();
    });

    test('no issues when disabled', () {
      detector.isEnabled = false;
      detector.processTimelineData(
        shaderCompileData(shaderDurationsUs: [200000]),
      );
      expect(detector.issues, isEmpty);
    });

    test('no issues when shader duration below threshold', () {
      // 50ms < 100ms threshold
      detector.processTimelineData(
        shaderCompileData(shaderDurationsUs: [50000]),
      );
      expect(detector.issues, isEmpty);
    });

    test('no issue at boundary just below threshold', () {
      // 99.999ms. Condition is ms >= 100. 99.999 >= 100 is false.
      detector.processTimelineData(
        shaderCompileData(shaderDurationsUs: [99999]),
      );
      expect(detector.issues, isEmpty);
    });

    test('warning when shader duration >= 100ms but < 200ms', () {
      detector.processTimelineData(
        shaderCompileData(shaderDurationsUs: [150000]),
      );
      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.severity, IssueSeverity.warning);
      expect(detector.issues.first.observationSource,
          ObservationSource.vmTimeline);
    });

    test('critical when shader duration >= 200ms', () {
      detector.processTimelineData(
        shaderCompileData(shaderDurationsUs: [250000]),
      );
      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.severity, IssueSeverity.critical);
    });

    test('stableId, confidence, and category', () {
      detector.processTimelineData(
        shaderCompileData(shaderDurationsUs: [150000]),
      );
      final issue = detector.issues.first;
      expect(issue.stableId, 'shader_compilation');
      expect(issue.confidence, IssueConfidence.confirmed);
      expect(issue.category, IssueCategory.raster);
    });

    test('title contains duration', () {
      detector.processTimelineData(
        shaderCompileData(shaderDurationsUs: [150000]),
      );
      expect(detector.issues.first.title, contains('150ms'));
    });

    test('detail includes total shader event count', () {
      // First batch: 1 below-threshold event (still counted)
      detector.processTimelineData(
        shaderCompileData(shaderDurationsUs: [50000]),
      );
      // Second batch: 1 above-threshold event (total events = 2)
      detector.processTimelineData(
        shaderCompileData(shaderDurationsUs: [150000]),
      );
      expect(detector.issues.first.detail, contains('2'));
    });

    test('multiple shader events per call produce per-event issues', () {
      detector.processTimelineData(
        shaderCompileData(shaderDurationsUs: [150000, 250000]),
      );
      expect(detector.issues, hasLength(2));
      expect(detector.issues[0].severity, IssueSeverity.warning);
      expect(detector.issues[1].severity, IssueSeverity.critical);
    });

    test('events below threshold still increment total counter', () {
      detector.processTimelineData(
        shaderCompileData(shaderDurationsUs: [50000]),
      );
      expect(detector.issues, isEmpty);

      detector.processTimelineData(
        shaderCompileData(shaderDurationsUs: [150000]),
      );
      // Total should be 2 (1 from first call + 1 from second)
      expect(detector.issues.first.detail, contains('2'));
    });

    test('dispose clears issues', () {
      detector.processTimelineData(
        shaderCompileData(shaderDurationsUs: [150000]),
      );
      expect(detector.issues, isNotEmpty);
      detector.dispose();
      expect(detector.issues, isEmpty);
    });

    // -----------------------------------------------------------------
    // Custom thresholds
    // -----------------------------------------------------------------

    test('custom threshold fires at lower value', () {
      detector = ShaderJankDetector(thresholdMs: 50);
      detector.processTimelineData(
        shaderCompileData(shaderDurationsUs: [75000]), // 75ms > 50ms
      );
      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.severity, IssueSeverity.warning);
    });

    test('custom threshold below value does not fire', () {
      detector = ShaderJankDetector(thresholdMs: 50);
      detector.processTimelineData(
        shaderCompileData(shaderDurationsUs: [40000]), // 40ms < 50ms
      );
      expect(detector.issues, isEmpty);
    });

    test('custom threshold critical at 2x', () {
      detector = ShaderJankDetector(thresholdMs: 50);
      detector.processTimelineData(
        shaderCompileData(shaderDurationsUs: [110000]), // 110ms >= 100ms (50*2)
      );
      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.severity, IssueSeverity.critical);
    });
  });
}
