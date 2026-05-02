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

    group(
        'critical-tier band coverage (additionalBrackets) — '
        'every magnitude in the bracket band must emit .critical', () {
      // Companion to the critical-tier `additionalBrackets` raise on
      // the detector. The schema validates per-leg observed magnitude
      // lands in the band, but the detector itself must also emit
      // `.critical` (not `.warning`, not silent) at every point in
      // that band — otherwise the bracket evidence is unmoored from
      // detector behaviour. Cases span the at-band, the schema seam at
      // 25.6/25.7 ms (atTolerance=0.60), and the above-ceiling:
      //
      //   - 18000µs sits at the at-band target (mid [16, 25.6])
      //   - 24000µs sits inside the at-band (mid-upper)
      //   - 24001µs sits above the prior 0.50-tolerance seam but still
      //     inside the current 0.60-tolerance at-band
      //   - 25600µs sits exactly at the schema's 0.60 at-band upper edge
      //   - 25601µs is the first above-band magnitude (schema-side
      //     boundary at threshold × (1 + 0.60))
      //   - 30000µs sits at the above-ceiling (1.875 × 16)
      //   - 30001µs proves there is no super-critical tier above
      //     (`.critical` is the maximum severity HeavyCompute can emit;
      //     a future "super critical" tier would surface as a regression
      //     in this assertion).

      test('18000µs (at-band target) emits .critical', () {
        final events = [
          buildEvent(name: 'BUILD', ph: 'X', dur: 18000, ts: 1000),
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
        expect(detector.issues.first.severity.name, 'critical');
      });

      test('24000µs (at-band mid-upper) stays .critical', () {
        final events = [
          buildEvent(name: 'BUILD', ph: 'X', dur: 24000, ts: 1000),
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
        expect(detector.issues.first.severity.name, 'critical');
      });

      test(
          '24001µs (above prior 0.50 seam, inside 0.60 at-band) stays .critical',
          () {
        final events = [
          buildEvent(name: 'BUILD', ph: 'X', dur: 24001, ts: 1000),
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
        expect(detector.issues.first.severity.name, 'critical');
      });

      test('25600µs (schema 0.60 at-band upper edge) stays .critical', () {
        final events = [
          buildEvent(name: 'BUILD', ph: 'X', dur: 25600, ts: 1000),
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
        expect(detector.issues.first.severity.name, 'critical');
      });

      test(
        '25601µs (first above the schema 0.60 at-upper) stays .critical',
        () {
          final events = [
            buildEvent(name: 'BUILD', ph: 'X', dur: 25601, ts: 1000),
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
          expect(detector.issues.first.severity.name, 'critical');
        },
      );

      test('30000µs (above-ceiling 1.875×16) stays .critical', () {
        final events = [
          buildEvent(name: 'BUILD', ph: 'X', dur: 30000, ts: 1000),
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
        expect(detector.issues.first.severity.name, 'critical');
      });

      test('30001µs (above above-ceiling) still .critical (no super tier)', () {
        final events = [
          buildEvent(name: 'BUILD', ph: 'X', dur: 30001, ts: 1000),
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
        expect(detector.issues.first.severity.name, 'critical');
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
