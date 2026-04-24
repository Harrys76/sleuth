// Hermetic reproducer for `HeavyComputeDetector`.
//
// Feeds `BUILD` `'X'` events through `TimelineParser.parse()` into the
// detector. Covers both emission sites — enriched (`PhaseEvent` with
// `dirtyList`, "Heavy Build:" title) and non-enriched fallback (raw
// `buildScopeDurations` only, "Heavy Computation:" title). Duration
// threshold is strict inequality (`ms > lagThresholdMs`) so 8.000ms is
// silent and 8.001ms fires.

import 'package:flutter_test/flutter_test.dart';

import 'package:sleuth/src/detectors/heavy_compute_detector.dart';

import '_helpers/vm_reproducer_harness.dart';

void main() {
  group('HeavyComputeDetector reproducer', () {
    late HeavyComputeDetector detector;

    setUp(() {
      detector = HeavyComputeDetector();
      detector.vmConnected = true;
    });

    group('duration boundary triad (threshold 8ms, strict inequality)', () {
      test('8.000ms BUILD does NOT emit heavy_compute', () {
        final events = [
          buildEvent(name: 'BUILD', ph: 'X', dur: 8000, ts: 1000),
        ];
        final parsed = parseAndAssertShape(events, (
          buildEventCount: 1,
          buildScopeCount: 1,
          layoutCount: 0,
          paintCount: 0,
          rasterCount: 0,
          shaderCount: 0,
          channelCount: 0,
          gcCount: 0,
          phaseEventCount: 1,
        ));
        detector.processTimelineData(parsed);
        expect(detector.issues, isEmpty);
      });

      test('8.001ms BUILD emits heavy_compute (warning)', () {
        final events = [
          buildEvent(name: 'BUILD', ph: 'X', dur: 8001, ts: 1000),
        ];
        final parsed = parseAndAssertShape(events, (
          buildEventCount: 1,
          buildScopeCount: 1,
          layoutCount: 0,
          paintCount: 0,
          rasterCount: 0,
          shaderCount: 0,
          channelCount: 0,
          gcCount: 0,
          phaseEventCount: 1,
        ));
        detector.processTimelineData(parsed);
        expect(detector.issues, hasLength(1));
        expect(detector.issues.first.stableId, 'heavy_compute');
        expect(detector.issues.first.severity.name, 'warning');
      });

      test('16.001ms BUILD escalates to critical (2× threshold)', () {
        final events = [
          buildEvent(name: 'BUILD', ph: 'X', dur: 16001, ts: 1000),
        ];
        final parsed = parseAndAssertShape(events, (
          buildEventCount: 1,
          buildScopeCount: 1,
          layoutCount: 0,
          paintCount: 0,
          rasterCount: 0,
          shaderCount: 0,
          channelCount: 0,
          gcCount: 0,
          phaseEventCount: 1,
        ));
        detector.processTimelineData(parsed);
        expect(detector.issues.first.stableId, 'heavy_compute');
        expect(detector.issues.first.severity.name, 'critical');
      });
    });

    group('enriched emission path (PhaseEvent + dirtyList)', () {
      test(
          'parser extracts dirtyCount/dirtyList/scopeContext; detector '
          'surfaces them verbatim in issue.detail', () {
        final events = [
          buildEvent(
            name: 'BUILD',
            ph: 'X',
            dur: 12000,
            ts: 1000,
            args: {
              'build scope dirty count': '2',
              'build scope dirty list': '[MyWidget, OtherWidget]',
              'scope context': 'HomePage',
            },
          ),
        ];
        final parsed = parseAndAssertShape(events, (
          buildEventCount: 1,
          buildScopeCount: 1,
          layoutCount: 0,
          paintCount: 0,
          rasterCount: 0,
          shaderCount: 0,
          channelCount: 0,
          gcCount: 0,
          phaseEventCount: 1,
        ));

        // Parser-level: each enrichment field round-trips exactly. A
        // regression that collapses dirtyList into a single string, drops
        // bracket-stripping, or misparses the stringified int would break
        // these assertions even if the 9-count shape check still passed.
        final phase = parsed.phaseEvents.single;
        expect(phase.dirtyCount, 2);
        expect(phase.dirtyList, ['MyWidget', 'OtherWidget']);
        expect(phase.scopeContext, 'HomePage');

        // Detector-level: exact strings the enriched path emits, so a
        // regression that drops any enrichment field from the detail
        // output fails here.
        detector.processTimelineData(parsed);
        expect(detector.issues, hasLength(1));
        expect(detector.issues.first.stableId, 'heavy_compute');
        expect(detector.issues.first.title, contains('Heavy Build:'));
        expect(detector.issues.first.title, contains('MyWidget'));
        expect(
            detector.issues.first.detail, contains('Dirty widget count: 2.'));
        expect(detector.issues.first.detail,
            contains('Dirty widgets: MyWidget, OtherWidget.'));
        expect(
            detector.issues.first.detail, contains('Scope context: HomePage.'));
      });

      test('missing dirtyList still fires with non-enriched title', () {
        final events = [
          buildEvent(name: 'BUILD', ph: 'X', dur: 12000, ts: 1000),
        ];
        final parsed = parseAndAssertShape(events, (
          buildEventCount: 1,
          buildScopeCount: 1,
          layoutCount: 0,
          paintCount: 0,
          rasterCount: 0,
          shaderCount: 0,
          channelCount: 0,
          gcCount: 0,
          phaseEventCount: 1,
        ));
        detector.processTimelineData(parsed);
        expect(detector.issues, hasLength(1));
        expect(detector.issues.first.stableId, 'heavy_compute');
        expect(detector.issues.first.title, contains('Heavy Computation:'));
      });
    });

    group('warning/critical escalation boundary (2× threshold, strict)', () {
      test('16000µs (exactly 2× threshold) stays at warning', () {
        final events = [
          buildEvent(name: 'BUILD', ph: 'X', dur: 16000, ts: 1000),
        ];
        final parsed = parseAndAssertShape(events, (
          buildEventCount: 1,
          buildScopeCount: 1,
          layoutCount: 0,
          paintCount: 0,
          rasterCount: 0,
          shaderCount: 0,
          channelCount: 0,
          gcCount: 0,
          phaseEventCount: 1,
        ));
        detector.processTimelineData(parsed);
        expect(detector.issues, hasLength(1));
        expect(detector.issues.first.severity.name, 'warning');
      });
    });

    group('fallback emission path (_createGenericIssue, no PhaseEvent)', () {
      // Parser only creates a PhaseEvent when the BUILD 'X' event carries
      // a `ts` field. Events without `ts` populate `buildScopeDurations`
      // but not `phaseEvents` — detector then falls back to
      // `_createGenericIssue` instead of the enriched `_createIssue` path.
      // Reached in production when VM emits 'X' build events pre-2.x or
      // via tooling that omits timestamps.
      test('BUILD `X` event without `ts` fires via _createGenericIssue', () {
        final events = [
          buildEvent(name: 'BUILD', ph: 'X', dur: 12000),
        ];
        final parsed = parseAndAssertShape(events, (
          buildEventCount: 1,
          buildScopeCount: 1,
          layoutCount: 0,
          paintCount: 0,
          rasterCount: 0,
          shaderCount: 0,
          channelCount: 0,
          gcCount: 0,
          phaseEventCount: 0,
        ));
        detector.processTimelineData(parsed);
        expect(detector.issues, hasLength(1));
        expect(detector.issues.first.stableId, 'heavy_compute');
        expect(detector.issues.first.title, contains('Heavy Computation:'));
      });
    });

    group('negative control', () {
      test('disabled detector never emits heavy_compute', () {
        detector.isEnabled = false;
        final events = [
          buildEvent(name: 'BUILD', ph: 'X', dur: 50000, ts: 1000),
        ];
        final parsed = parseAndAssertShape(events, (
          buildEventCount: 1,
          buildScopeCount: 1,
          layoutCount: 0,
          paintCount: 0,
          rasterCount: 0,
          shaderCount: 0,
          channelCount: 0,
          gcCount: 0,
          phaseEventCount: 1,
        ));
        detector.processTimelineData(parsed);
        expect(detector.issues, lacksStableId('heavy_compute'));
      });
    });
  });
}
