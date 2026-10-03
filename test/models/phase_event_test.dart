import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/models/phase_event.dart';
import 'package:sleuth/src/analyzer/frame_event_correlator.dart';

void main() {
  group('PhaseEvent', () {
    test('endUs computes start + duration', () {
      const event = PhaseEvent(
        phase: TimelinePhase.build,
        timestampUs: 1000,
        durationUs: 500,
      );

      expect(event.endUs, 1500);
    });

    test('endUs with zero duration equals timestampUs', () {
      const event = PhaseEvent(
        phase: TimelinePhase.raster,
        timestampUs: 5000,
        durationUs: 0,
      );

      expect(event.endUs, 5000);
    });

    test('hasEnrichment is false when all enrichment fields null', () {
      const event = PhaseEvent(
        phase: TimelinePhase.build,
        timestampUs: 1000,
        durationUs: 500,
      );

      expect(event.hasEnrichment, isFalse);
    });

    test('hasEnrichment is true when dirtyCount is set', () {
      const event = PhaseEvent(
        phase: TimelinePhase.build,
        timestampUs: 1000,
        durationUs: 500,
        dirtyCount: 3,
      );

      expect(event.hasEnrichment, isTrue);
    });

    test('hasEnrichment is true when dirtyList is set', () {
      const event = PhaseEvent(
        phase: TimelinePhase.paint,
        timestampUs: 1000,
        durationUs: 500,
        dirtyList: ['RenderFlex'],
      );

      expect(event.hasEnrichment, isTrue);
    });

    test('scopeContext preserved correctly', () {
      const event = PhaseEvent(
        phase: TimelinePhase.build,
        timestampUs: 1000,
        durationUs: 500,
        scopeContext: 'MyApp(dirty)',
      );

      expect(event.scopeContext, 'MyApp(dirty)');
      // scopeContext alone does not make hasEnrichment true
      expect(event.hasEnrichment, isFalse);
    });
  });

  group('CorrelatedFrameData', () {
    test('batchCoverageRatio is 0 when totalBatchEventCount is 0', () {
      const data = CorrelatedFrameData(
        batchMatchedEventCount: 0,
        totalBatchEventCount: 0,
      );
      expect(data.batchCoverageRatio, 0);
    });

    test('batchCoverageRatio computes matched / total', () {
      const data = CorrelatedFrameData(
        matchedEventCount: 3,
        batchMatchedEventCount: 3,
        totalBatchEventCount: 10,
      );
      expect(data.batchCoverageRatio, 0.3);
    });

    test('batchCoverageRatio is 1.0 when all events matched', () {
      const data = CorrelatedFrameData(
        matchedEventCount: 5,
        batchMatchedEventCount: 5,
        totalBatchEventCount: 5,
      );
      expect(data.batchCoverageRatio, 1.0);
    });

    test('isTrustworthy requires matchedEventCount > 0', () {
      const data = CorrelatedFrameData(
        matchedEventCount: 0,
        batchMatchedEventCount: 10,
        totalBatchEventCount: 10,
      );
      expect(data.isTrustworthy, isFalse);
    });

    test('isTrustworthy reads the batch coverage, not the frame share', () {
      const data = CorrelatedFrameData(
        matchedEventCount: 2,
        batchMatchedEventCount: 6,
        totalBatchEventCount: 10,
      );
      // This frame holds 0.2 of the batch; the batch is 0.6 matched.
      expect(data.batchCoverageRatio, 0.6);
      expect(data.isTrustworthy, isTrue);
    });

    test('isTrustworthy requires coverage >= 0.5', () {
      const data = CorrelatedFrameData(
        matchedEventCount: 1,
        batchMatchedEventCount: 1,
        totalBatchEventCount: 10,
      );
      // coverage = 0.1 < 0.5
      expect(data.isTrustworthy, isFalse);
    });

    test('isTrustworthy is true at exactly 0.5 coverage', () {
      const data = CorrelatedFrameData(
        matchedEventCount: 5,
        batchMatchedEventCount: 5,
        totalBatchEventCount: 10,
      );
      expect(data.isTrustworthy, isTrue);
    });

    test('isTrustworthy is false between old and new threshold', () {
      const data = CorrelatedFrameData(
        matchedEventCount: 3,
        batchMatchedEventCount: 3,
        totalBatchEventCount: 10,
      );
      // coverage = 0.3 — was trustworthy at old 0.2 threshold, not at 0.5
      expect(data.isTrustworthy, isFalse);
    });

    test('isTrustworthy is true with full coverage', () {
      const data = CorrelatedFrameData(
        matchedEventCount: 5,
        batchMatchedEventCount: 5,
        totalBatchEventCount: 5,
      );
      expect(data.isTrustworthy, isTrue);
    });
  });
}
