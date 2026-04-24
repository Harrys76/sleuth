// Hermetic reproducer for `PlatformChannelDetector`.
//
// Feeds platform-channel timeline events through `TimelineParser.parse()`
// into the detector. Exercises both async `'b'` (real
// `debugProfilePlatformChannels` output — lowercase, emitted per
// `TimelineTask`) and sync `'X'` complete-duration variants accepted by
// the parser. Uppercase `'B'` async-shaped events are silently dropped
// by the parser and must not trigger the detector; that is the
// canonical format-boundary trap for platform-channel observers.
//
// Detection is frequency-axis: `_recentCallCount > callsPerSecThreshold`
// after a full 1000ms window. Emission is deferred to the NEXT
// `processTimelineData` call whose timestamp crosses the window
// boundary, so every test advances the fake clock past 1000ms between
// the accumulation and the evaluation.

import 'package:flutter_test/flutter_test.dart';
import 'package:vm_service/vm_service.dart';

import 'package:sleuth/src/detectors/platform_channel_detector.dart';

import '_helpers/vm_reproducer_harness.dart';

void main() {
  group('PlatformChannelDetector reproducer', () {
    late PlatformChannelDetector detector;
    late DateTime now;

    setUp(() {
      now = DateTime(2026, 4, 25, 12);
      detector =
          PlatformChannelDetector(callsPerSecThreshold: 20, clock: () => now);
      detector.vmConnected = true;
    });

    List<TimelineEvent> asyncChannelCalls(int count, {int startTs = 1000}) {
      return List.generate(
        count,
        (i) => buildEvent(
          name: 'Platform Channel send plugin.example/method#call',
          ph: 'b',
          ts: startTs + i,
        ),
      );
    }

    group('frequency boundary triad (threshold 20 calls/sec, strict)', () {
      test('20 calls/window does NOT emit platform_channel_traffic', () {
        final events = asyncChannelCalls(20);
        final parsed = parseAndAssertShape(events, (
          buildEventCount: 0,
          buildScopeCount: 0,
          layoutCount: 0,
          paintCount: 0,
          rasterCount: 0,
          shaderCount: 0,
          channelCount: 20,
          gcCount: 0,
          phaseEventCount: 0,
        ));
        detector.processTimelineData(parsed);
        now = now.add(const Duration(milliseconds: 1100));
        detector.processTimelineData(parseAndAssertShape(
          <TimelineEvent>[],
          (
            buildEventCount: 0,
            buildScopeCount: 0,
            layoutCount: 0,
            paintCount: 0,
            rasterCount: 0,
            shaderCount: 0,
            channelCount: 0,
            gcCount: 0,
            phaseEventCount: 0,
          ),
        ));
        expect(detector.issues, lacksStableId('platform_channel_traffic'));
      });

      test('21 calls/window emits platform_channel_traffic (warning)', () {
        final events = asyncChannelCalls(21);
        final parsed = parseAndAssertShape(events, (
          buildEventCount: 0,
          buildScopeCount: 0,
          layoutCount: 0,
          paintCount: 0,
          rasterCount: 0,
          shaderCount: 0,
          channelCount: 21,
          gcCount: 0,
          phaseEventCount: 0,
        ));
        detector.processTimelineData(parsed);
        now = now.add(const Duration(milliseconds: 1100));
        detector.processTimelineData(parseAndAssertShape(
          <TimelineEvent>[],
          (
            buildEventCount: 0,
            buildScopeCount: 0,
            layoutCount: 0,
            paintCount: 0,
            rasterCount: 0,
            shaderCount: 0,
            channelCount: 0,
            gcCount: 0,
            phaseEventCount: 0,
          ),
        ));
        expect(detector.issues, hasStableId('platform_channel_traffic'));
        expect(detector.issues.first.severity.name, 'warning');
      });

      test('41 calls/window escalates to critical (>2× threshold)', () {
        final events = asyncChannelCalls(41);
        final parsed = parseAndAssertShape(events, (
          buildEventCount: 0,
          buildScopeCount: 0,
          layoutCount: 0,
          paintCount: 0,
          rasterCount: 0,
          shaderCount: 0,
          channelCount: 41,
          gcCount: 0,
          phaseEventCount: 0,
        ));
        detector.processTimelineData(parsed);
        now = now.add(const Duration(milliseconds: 1100));
        detector.processTimelineData(parseAndAssertShape(
          <TimelineEvent>[],
          (
            buildEventCount: 0,
            buildScopeCount: 0,
            layoutCount: 0,
            paintCount: 0,
            rasterCount: 0,
            shaderCount: 0,
            channelCount: 0,
            gcCount: 0,
            phaseEventCount: 0,
          ),
        ));
        expect(detector.issues, hasStableId('platform_channel_traffic'));
        expect(detector.issues.first.severity.name, 'critical');
      });
    });

    group('format-boundary coverage', () {
      test('uppercase sync `B` is silently dropped by parser, no emission', () {
        final events = List.generate(
          50,
          (i) => buildEvent(
            name: 'Platform Channel send plugin.example/method#call',
            ph: 'B',
            ts: 1000 + i,
          ),
        );
        final parsed = parseAndAssertShape(events, (
          buildEventCount: 0,
          buildScopeCount: 0,
          layoutCount: 0,
          paintCount: 0,
          rasterCount: 0,
          shaderCount: 0,
          channelCount: 0,
          gcCount: 0,
          phaseEventCount: 0,
        ));
        detector.processTimelineData(parsed);
        now = now.add(const Duration(milliseconds: 1100));
        detector.processTimelineData(parseAndAssertShape(
          <TimelineEvent>[],
          (
            buildEventCount: 0,
            buildScopeCount: 0,
            layoutCount: 0,
            paintCount: 0,
            rasterCount: 0,
            shaderCount: 0,
            channelCount: 0,
            gcCount: 0,
            phaseEventCount: 0,
          ),
        ));
        expect(detector.issues, lacksStableId('platform_channel_traffic'));
      });

      test('sync `X` with `MethodChannel` name classifies as channel', () {
        final events = List.generate(
          25,
          (i) => buildEvent(
            name: 'MethodChannel',
            ph: 'X',
            dur: 100,
            ts: 1000 + i,
          ),
        );
        final parsed = parseAndAssertShape(events, (
          buildEventCount: 0,
          buildScopeCount: 0,
          layoutCount: 0,
          paintCount: 0,
          rasterCount: 0,
          shaderCount: 0,
          channelCount: 25,
          gcCount: 0,
          phaseEventCount: 0,
        ));
        detector.processTimelineData(parsed);
        now = now.add(const Duration(milliseconds: 1100));
        detector.processTimelineData(parseAndAssertShape(
          <TimelineEvent>[],
          (
            buildEventCount: 0,
            buildScopeCount: 0,
            layoutCount: 0,
            paintCount: 0,
            rasterCount: 0,
            shaderCount: 0,
            channelCount: 0,
            gcCount: 0,
            phaseEventCount: 0,
          ),
        ));
        expect(detector.issues, hasStableId('platform_channel_traffic'));
      });
    });

    group('duration boundary triad (threshold 8000µs cumulative, strict)', () {
      // Duration axis is independent of frequency axis — detector fires on
      // `frequencyExceeded || durationExceeded`. Below tests isolate the
      // duration path by using 3 sync 'X' events (far under 20/sec frequency)
      // with per-event dur tuned to bracket the cumulative threshold.
      List<TimelineEvent> syncChannelCallsWithDur(int perEventDurUs) {
        return List.generate(
          3,
          (i) => buildEvent(
            name: 'MethodChannel',
            ph: 'X',
            dur: perEventDurUs,
            ts: 1000 + i,
          ),
        );
      }

      void advanceAndEvaluate() {
        now = now.add(const Duration(milliseconds: 1100));
        detector.processTimelineData(parseAndAssertShape(
          <TimelineEvent>[],
          (
            buildEventCount: 0,
            buildScopeCount: 0,
            layoutCount: 0,
            paintCount: 0,
            rasterCount: 0,
            shaderCount: 0,
            channelCount: 0,
            gcCount: 0,
            phaseEventCount: 0,
          ),
        ));
      }

      test('3 events × 2666µs = 7998µs cumulative does NOT emit', () {
        final events = syncChannelCallsWithDur(2666);
        detector.processTimelineData(parseAndAssertShape(events, (
          buildEventCount: 0,
          buildScopeCount: 0,
          layoutCount: 0,
          paintCount: 0,
          rasterCount: 0,
          shaderCount: 0,
          channelCount: 3,
          gcCount: 0,
          phaseEventCount: 0,
        )));
        advanceAndEvaluate();
        expect(detector.issues, lacksStableId('platform_channel_traffic'));
      });

      test(
          '8 events × 1000µs = 8000µs cumulative does NOT emit '
          '(inclusive-greater-than boundary)', () {
        final events = List.generate(
          8,
          (i) => buildEvent(
            name: 'MethodChannel',
            ph: 'X',
            dur: 1000,
            ts: 1000 + i,
          ),
        );
        detector.processTimelineData(parseAndAssertShape(events, (
          buildEventCount: 0,
          buildScopeCount: 0,
          layoutCount: 0,
          paintCount: 0,
          rasterCount: 0,
          shaderCount: 0,
          channelCount: 8,
          gcCount: 0,
          phaseEventCount: 0,
        )));
        advanceAndEvaluate();
        expect(detector.issues, lacksStableId('platform_channel_traffic'));
      });

      test('3 events × 2667µs = 8001µs cumulative emits via duration axis', () {
        final events = syncChannelCallsWithDur(2667);
        detector.processTimelineData(parseAndAssertShape(events, (
          buildEventCount: 0,
          buildScopeCount: 0,
          layoutCount: 0,
          paintCount: 0,
          rasterCount: 0,
          shaderCount: 0,
          channelCount: 3,
          gcCount: 0,
          phaseEventCount: 0,
        )));
        advanceAndEvaluate();
        expect(detector.issues, hasStableId('platform_channel_traffic'));
        final issue = detector.issues
            .firstWhere((i) => i.stableId == 'platform_channel_traffic');
        expect(issue.title, contains('Slow Platform Channels'));
      });
    });

    group('warning/critical escalation boundary (2× thresholds)', () {
      test('40 calls/window stays at warning (not critical at 2× threshold)',
          () {
        final events = asyncChannelCalls(40);
        detector.processTimelineData(parseAndAssertShape(events, (
          buildEventCount: 0,
          buildScopeCount: 0,
          layoutCount: 0,
          paintCount: 0,
          rasterCount: 0,
          shaderCount: 0,
          channelCount: 40,
          gcCount: 0,
          phaseEventCount: 0,
        )));
        now = now.add(const Duration(milliseconds: 1100));
        detector.processTimelineData(parseAndAssertShape(
          <TimelineEvent>[],
          (
            buildEventCount: 0,
            buildScopeCount: 0,
            layoutCount: 0,
            paintCount: 0,
            rasterCount: 0,
            shaderCount: 0,
            channelCount: 0,
            gcCount: 0,
            phaseEventCount: 0,
          ),
        ));
        expect(detector.issues, hasStableId('platform_channel_traffic'));
        expect(detector.issues.first.severity.name, 'warning');
      });
    });

    group('negative control', () {
      test('disabled detector never emits platform_channel_traffic', () {
        detector.isEnabled = false;
        final events = asyncChannelCalls(100);
        final parsed = parseAndAssertShape(events, (
          buildEventCount: 0,
          buildScopeCount: 0,
          layoutCount: 0,
          paintCount: 0,
          rasterCount: 0,
          shaderCount: 0,
          channelCount: 100,
          gcCount: 0,
          phaseEventCount: 0,
        ));
        detector.processTimelineData(parsed);
        now = now.add(const Duration(milliseconds: 1100));
        detector.processTimelineData(parseAndAssertShape(
          <TimelineEvent>[],
          (
            buildEventCount: 0,
            buildScopeCount: 0,
            layoutCount: 0,
            paintCount: 0,
            rasterCount: 0,
            shaderCount: 0,
            channelCount: 0,
            gcCount: 0,
            phaseEventCount: 0,
          ),
        ));
        expect(detector.issues, lacksStableId('platform_channel_traffic'));
      });
    });
  });
}
