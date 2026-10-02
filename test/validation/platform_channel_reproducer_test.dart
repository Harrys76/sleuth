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
// after a full 1000ms window. Per-call durations (async `b`/`e` pairs
// matched by `id`, sync `X` `dur`) are observational and never gate. Emission is deferred to the NEXT
// `processTimelineData` call whose timestamp crosses the window
// boundary, so every test advances the fake clock past 1000ms between
// the accumulation and the evaluation.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vm_service/vm_service.dart';

import 'package:sleuth/src/detectors/platform_channel_detector.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/vm/timeline_parser.dart';

import '_helpers/vm_reproducer_harness.dart';

void main() {
  group('PlatformChannelDetector reproducer', () {
    late PlatformChannelDetector detector;
    late DateTime now;

    setUp(() {
      now = DateTime(2026, 4, 25, 12);
      detector = PlatformChannelDetector(
        callsPerSecThreshold: 20,
        clock: () => now,
      );
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
        detector.processTimelineData(
          parseAndAssertShape(<TimelineEvent>[], (
            buildEventCount: 0,
            buildScopeCount: 0,
            layoutCount: 0,
            paintCount: 0,
            rasterCount: 0,
            shaderCount: 0,
            channelCount: 0,
            gcCount: 0,
            phaseEventCount: 0,
          )),
        );
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
        detector.processTimelineData(
          parseAndAssertShape(<TimelineEvent>[], (
            buildEventCount: 0,
            buildScopeCount: 0,
            layoutCount: 0,
            paintCount: 0,
            rasterCount: 0,
            shaderCount: 0,
            channelCount: 0,
            gcCount: 0,
            phaseEventCount: 0,
          )),
        );
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
        detector.processTimelineData(
          parseAndAssertShape(<TimelineEvent>[], (
            buildEventCount: 0,
            buildScopeCount: 0,
            layoutCount: 0,
            paintCount: 0,
            rasterCount: 0,
            shaderCount: 0,
            channelCount: 0,
            gcCount: 0,
            phaseEventCount: 0,
          )),
        );
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
        detector.processTimelineData(
          parseAndAssertShape(<TimelineEvent>[], (
            buildEventCount: 0,
            buildScopeCount: 0,
            layoutCount: 0,
            paintCount: 0,
            rasterCount: 0,
            shaderCount: 0,
            channelCount: 0,
            gcCount: 0,
            phaseEventCount: 0,
          )),
        );
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
        detector.processTimelineData(
          parseAndAssertShape(<TimelineEvent>[], (
            buildEventCount: 0,
            buildScopeCount: 0,
            layoutCount: 0,
            paintCount: 0,
            rasterCount: 0,
            shaderCount: 0,
            channelCount: 0,
            gcCount: 0,
            phaseEventCount: 0,
          )),
        );
        expect(detector.issues, hasStableId('platform_channel_traffic'));
      });
    });

    group('duration is observational (8000µs per call, never gates)', () {
      List<TimelineEvent> syncChannelCallsWithDur(
        int count,
        int perEventDurUs, {
        int startTs = 1000,
      }) {
        return List.generate(
          count,
          (i) => buildEvent(
            name: 'MethodChannel',
            ph: 'X',
            dur: perEventDurUs,
            ts: startTs + i,
          ),
        );
      }

      /// Async `b`/`e` pairs as `debugProfilePlatformChannels` emits them:
      /// unique hex `id` per call, no `dur`, in timestamp order (the
      /// parser's per-thread cursor drops events older than the last
      /// one seen).
      List<TimelineEvent> asyncChannelPairs(int count, int perCallDurUs) {
        final events = [
          for (var i = 0; i < count; i++) ...[
            TimelineEvent.parse({
              'name': 'Platform Channel send plugin.example/method#call',
              'cat': 'Dart',
              'ph': 'b',
              'id': (0x2d3216ee8457db26 + i).toRadixString(16),
              'ts': 1000 + i * 10,
              'pid': 1,
              'tid': 1,
            })!,
            TimelineEvent.parse({
              'name': 'Platform Channel send plugin.example/method#call',
              'cat': 'Dart',
              'ph': 'e',
              'id': (0x2d3216ee8457db26 + i).toRadixString(16),
              'ts': 1000 + i * 10 + perCallDurUs,
              'pid': 1,
              'tid': 1,
            })!,
          ],
        ];
        int tsOf(TimelineEvent e) => e.json!['ts'] as int;
        return events..sort((a, b) => tsOf(a).compareTo(tsOf(b)));
      }

      void advanceAndEvaluate() {
        now = now.add(const Duration(milliseconds: 1100));
        detector.processTimelineData(
          parseAndAssertShape(<TimelineEvent>[], (
            buildEventCount: 0,
            buildScopeCount: 0,
            layoutCount: 0,
            paintCount: 0,
            rasterCount: 0,
            shaderCount: 0,
            channelCount: 0,
            gcCount: 0,
            phaseEventCount: 0,
          )),
        );
      }

      test('3 sync calls × 2667µs (8001µs total) do NOT emit', () {
        detector.processTimelineData(
          parseAndAssertShape(syncChannelCallsWithDur(3, 2667), (
            buildEventCount: 0,
            buildScopeCount: 0,
            layoutCount: 0,
            paintCount: 0,
            rasterCount: 0,
            shaderCount: 0,
            channelCount: 3,
            gcCount: 0,
            phaseEventCount: 0,
          )),
        );
        advanceAndEvaluate();
        expect(detector.issues, lacksStableId('platform_channel_traffic'));
        expect(detector.lastWindowStats!.maxCallDurationUs, 2667);
        expect(detector.lastWindowStats!.callsOverThreshold, 0);
      });

      test('per-call threshold is strict: 8000µs is not over, 8001µs is', () {
        detector.processTimelineData(
          parseAndAssertShape(
            [
              ...syncChannelCallsWithDur(1, 8000),
              ...syncChannelCallsWithDur(2, 8001, startTs: 2000),
            ],
            (
              buildEventCount: 0,
              buildScopeCount: 0,
              layoutCount: 0,
              paintCount: 0,
              rasterCount: 0,
              shaderCount: 0,
              channelCount: 3,
              gcCount: 0,
              phaseEventCount: 0,
            ),
          ),
        );
        advanceAndEvaluate();
        expect(detector.issues, lacksStableId('platform_channel_traffic'));
        expect(detector.lastWindowStats!.callsOverThreshold, 2);
      });

      test('15 async calls × 20ms are observed but do NOT emit', () {
        detector.processTimelineData(
          parseAndAssertShape(asyncChannelPairs(15, 20000), (
            buildEventCount: 0,
            buildScopeCount: 0,
            layoutCount: 0,
            paintCount: 0,
            rasterCount: 0,
            shaderCount: 0,
            channelCount: 15,
            gcCount: 0,
            phaseEventCount: 0,
          )),
        );
        advanceAndEvaluate();
        expect(detector.issues, lacksStableId('platform_channel_traffic'));
        final stats = detector.lastWindowStats!;
        expect(stats.callCount, 15);
        expect(stats.maxCallDurationUs, 20000);
        expect(stats.callsOverThreshold, 15);
      });

      test('25 async calls × 9ms emit by count with durations stamped', () {
        detector.processTimelineData(
          parseAndAssertShape(asyncChannelPairs(25, 9000), (
            buildEventCount: 0,
            buildScopeCount: 0,
            layoutCount: 0,
            paintCount: 0,
            rasterCount: 0,
            shaderCount: 0,
            channelCount: 25,
            gcCount: 0,
            phaseEventCount: 0,
          )),
        );
        advanceAndEvaluate();
        expect(detector.issues, hasStableId('platform_channel_traffic'));
        final args = detector.issues.single.extraTraceArgs!;
        expect(args['observedCount'], '25');
        expect(args['maxCallDurationUs'], '9000');
        expect(args['p95CallDurationUs'], '9000');
        expect(args['callsOverThreshold'], '25');
      });
    });

    group('capture replay (count axis only)', () {
      // Replays each checked-in capture through the parser and detector
      // in 1s windows aligned to `sleuth.scenario.begin`, carrying
      // in-flight channel begins across windows. Per-call durations come
      // from `b`/`e` pairs; emission must still follow the count axis.
      ({
        List<int> windowCounts,
        int maxCallDurationUs,
        List<PerformanceIssue> issues,
        List<PerformanceIssue> finalIssues,
      })
      replay(String leg) {
        final file = File(
          'test/validation/captures/platform_channel/'
          'platform_channel_traffic_$leg.json',
        );
        final raw = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        final events =
            (raw['traceEvents'] as List)
                .cast<Map<String, dynamic>>()
                .where((e) => e['ts'] is int)
                .toList()
              ..sort((a, b) => (a['ts'] as int).compareTo(b['ts'] as int));
        final t0 =
            events.firstWhere((e) => e['name'] == 'sleuth.scenario.begin')['ts']
                as int;
        final buckets = <int, List<TimelineEvent>>{};
        for (final e in events) {
          final ts = e['ts'] as int;
          if (ts < t0) continue;
          buckets
              .putIfAbsent((ts - t0) ~/ 1000000, () => [])
              .add(TimelineEvent.parse(e)!);
        }
        final lastBucket = buckets.keys.reduce((a, b) => a > b ? a : b);
        final base = DateTime(2026, 5, 3);
        var clock = base;
        final replayDetector = PlatformChannelDetector(clock: () => clock);
        final pending = <String, int>{};
        final windowCounts = <int>[];
        var maxDur = 0;
        final issues = <PerformanceIssue>[];
        // Run 12 quiet seconds past the capture so the 10 s emission
        // persistence plays out.
        for (var k = 0; k <= lastBucket + 13; k++) {
          clock = base.add(Duration(seconds: k));
          replayDetector.processTimelineData(
            TimelineParser.parse(
              buckets[k] ?? const [],
              pendingChannelBegins: pending,
            ),
          );
          // Every call after the first crosses exactly one 1s boundary,
          // evaluating window k - 1.
          if (k >= 1) {
            final stats = replayDetector.lastWindowStats!;
            windowCounts.add(stats.callCount);
            if (stats.maxCallDurationUs > maxDur) {
              maxDur = stats.maxCallDurationUs;
            }
          }
          for (final i in replayDetector.issues) {
            if (!issues.contains(i)) issues.add(i);
          }
        }
        return (
          windowCounts: windowCounts,
          maxCallDurationUs: maxDur,
          issues: issues,
          finalIssues: replayDetector.issues,
        );
      }

      test('below leg: durations observed, no emission', () {
        final r = replay('below');
        expect(r.windowCounts.first, lessThanOrEqualTo(20));
        expect(r.windowCounts.every((c) => c <= 20), isTrue);
        expect(r.maxCallDurationUs, greaterThan(0));
        expect(r.issues, lacksStableId('platform_channel_traffic'));
      });

      // Distinct dedup identities = trace records the capture path
      // writes. Persistence retains the issue without re-emitting, so
      // each emitting leg still records exactly one.
      int records(List<PerformanceIssue> issues) => issues
          .where((i) => i.stableId == 'platform_channel_traffic')
          .map((i) => i.dedupIdentityMicros)
          .toSet()
          .length;

      test('at leg emits exactly one record, then clears', () {
        final r = replay('at');
        expect(r.maxCallDurationUs, greaterThan(0));
        expect(r.issues, hasStableId('platform_channel_traffic'));
        expect(records(r.issues), 1);
        expect(r.finalIssues, isEmpty);
      });

      test('above leg emits exactly one record, then clears', () {
        final r = replay('above');
        expect(r.maxCallDurationUs, greaterThan(0));
        expect(r.issues, hasStableId('platform_channel_traffic'));
        expect(records(r.issues), 1);
        expect(r.finalIssues, isEmpty);
      });
    });

    group('warning/critical escalation boundary (2× thresholds)', () {
      test(
        '40 calls/window stays at warning (not critical at 2× threshold)',
        () {
          final events = asyncChannelCalls(40);
          detector.processTimelineData(
            parseAndAssertShape(events, (
              buildEventCount: 0,
              buildScopeCount: 0,
              layoutCount: 0,
              paintCount: 0,
              rasterCount: 0,
              shaderCount: 0,
              channelCount: 40,
              gcCount: 0,
              phaseEventCount: 0,
            )),
          );
          now = now.add(const Duration(milliseconds: 1100));
          detector.processTimelineData(
            parseAndAssertShape(<TimelineEvent>[], (
              buildEventCount: 0,
              buildScopeCount: 0,
              layoutCount: 0,
              paintCount: 0,
              rasterCount: 0,
              shaderCount: 0,
              channelCount: 0,
              gcCount: 0,
              phaseEventCount: 0,
            )),
          );
          expect(detector.issues, hasStableId('platform_channel_traffic'));
          expect(detector.issues.first.severity.name, 'warning');
        },
      );
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
        detector.processTimelineData(
          parseAndAssertShape(<TimelineEvent>[], (
            buildEventCount: 0,
            buildScopeCount: 0,
            layoutCount: 0,
            paintCount: 0,
            rasterCount: 0,
            shaderCount: 0,
            channelCount: 0,
            gcCount: 0,
            phaseEventCount: 0,
          )),
        );
        expect(detector.issues, lacksStableId('platform_channel_traffic'));
      });
    });
  });
}
