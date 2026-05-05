import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/detectors/platform_channel_detector.dart';
import 'package:sleuth/src/models/performance_issue.dart';

import '../helpers/timeline_test_helpers.dart';

void main() {
  group('PlatformChannelDetector', () {
    late PlatformChannelDetector detector;
    late DateTime fakeNow;

    setUp(() {
      fakeNow = DateTime(2026, 1, 1);
      detector = PlatformChannelDetector(clock: () => fakeNow);
    });

    test('no issues when disabled', () {
      detector.isEnabled = false;
      detector.processTimelineData(
        platformChannelData(channelEventCount: 25),
      );
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());
      expect(detector.issues, isEmpty);
    });

    test('no issues when call count below threshold after flush', () {
      // Feed 15 events (below default threshold of 20)
      detector.processTimelineData(
        platformChannelData(channelEventCount: 15),
      );
      // Advance past 1s window and flush
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());
      expect(detector.issues, isEmpty);
    });

    test('warning when calls/sec exceed threshold after flush', () {
      detector.processTimelineData(
        platformChannelData(channelEventCount: 25),
      );
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.severity, IssueSeverity.warning);
      expect(detector.issues.first.observationSource,
          ObservationSource.vmTimeline);
    });

    test('critical when calls/sec exceed 2x threshold after flush', () {
      detector.processTimelineData(
        platformChannelData(channelEventCount: 45),
      );
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.severity, IssueSeverity.critical);
    });

    test(
        'consecutive overloads during cooldown retain prior issue identity '
        '(do not emit fresh issue per window)', () {
      // First window: 25 events → warning, sets cooldown = 3,
      // stamps dedupIdentityMicros = _windowStart at fire time.
      detector.processTimelineData(
        platformChannelData(channelEventCount: 25),
      );
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());
      expect(detector.issues, hasLength(1));
      final firstFireIdentity = detector.issues.first.dedupIdentityMicros;
      expect(firstFireIdentity, isNotNull);

      // Subsequent windows ALSO exceed threshold. Cooldown semantics
      // suppress fresh emission and retain the prior issue so the
      // controller's composite-key dedup collapses sustained-overload
      // re-records to a single trace event per cooldown window.
      for (var i = 0; i < 3; i++) {
        detector.processTimelineData(
          platformChannelData(channelEventCount: 25),
        );
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(emptyTimelineData());
        expect(detector.issues, hasLength(1),
            reason: 'cooldown cycle $i: issue retained');
        expect(detector.issues.first.dedupIdentityMicros, firstFireIdentity,
            reason: 'cooldown cycle $i: dedup identity preserved across '
                'suppressed cycles so composite-key dedup collapses '
                'consecutive overloads to one trace record');
      }

      // After cooldown drains, next overload re-fires with FRESH
      // dedup identity (new _windowStart microsecond stamp).
      detector.processTimelineData(
        platformChannelData(channelEventCount: 25),
      );
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());
      expect(detector.issues, hasLength(1));
      expect(
          detector.issues.first.dedupIdentityMicros, isNot(firstFireIdentity),
          reason: 'post-cooldown re-fire stamps a new dedup identity from '
              'the new _windowStart so the controller emits a second '
              'trace record (not a duplicate of the prior fire).');
    });

    test(
        'emitted issue carries extraTraceArgs with observedCount and '
        'cumulativeDurationUs', () {
      detector.processTimelineData(
        platformChannelData(channelEventCount: 25),
      );
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());
      expect(detector.issues, hasLength(1));
      final issue = detector.issues.first;
      expect(issue.extraTraceArgs, isNotNull);
      expect(issue.extraTraceArgs!['observedCount'], '25',
          reason: 'observedCount mirrors _recentCallCount at fire-time so '
              'the audit gate can cross-check the capture\'s send-side '
              'magnitude against the parser-observed count.');
      expect(issue.extraTraceArgs!['cumulativeDurationUs'], isNotNull,
          reason: 'cumulativeDurationUs exported alongside observedCount '
              'so a future duration-axis raise can cross-check the '
              'duration band without a second metadata extension.');
    });

    test(
        'severity escalation breaks through cooldown — warning then critical '
        'emits fresh critical issue with new dedup identity', () {
      // Window 1: 25 events → warning fires, cooldown = 3, identity stamped.
      detector.processTimelineData(
        platformChannelData(channelEventCount: 25),
      );
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());
      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.severity, IssueSeverity.warning);
      final warningIdentity = detector.issues.first.dedupIdentityMicros;
      expect(warningIdentity, isNotNull);

      // Window 2 (cooldown still active at 3): 45 events → would-be
      // CRITICAL (> 2× threshold = > 40). Escalation exception bypasses
      // suppression, emits fresh critical with NEW dedup identity so the
      // controller's composite-key dedup records a second trace event
      // (live monitoring sees the escalation in real time instead of
      // holding stale warning UI for 3 cycles).
      detector.processTimelineData(
        platformChannelData(channelEventCount: 45),
      );
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());
      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.severity, IssueSeverity.critical,
          reason: 'Escalation through cooldown must surface the critical '
              'severity, not retain the prior warning.');
      expect(detector.issues.first.dedupIdentityMicros, isNot(warningIdentity),
          reason: 'Escalated critical fire must stamp a new dedup identity '
              'so the controller does not collapse it to the prior warning '
              'trace record.');

      // Window 3: 50 events → still critical. Cooldown active again (just
      // reset to 3 by escalation), prior was critical → severity matches
      // → suppressed, retains prior critical issue identity.
      final escalatedIdentity = detector.issues.first.dedupIdentityMicros;
      detector.processTimelineData(
        platformChannelData(channelEventCount: 50),
      );
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());
      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.severity, IssueSeverity.critical);
      expect(detector.issues.first.dedupIdentityMicros, escalatedIdentity,
          reason: 'Sustained critical (no escalation step) is suppressed '
              'by cooldown — retains escalated identity, no fresh fire.');
    });

    test(
        'severity de-escalation breaks through cooldown — critical then '
        'warning emits fresh warning with new dedup identity', () {
      // Window 1: 50 events → critical fires, cooldown = 3.
      detector.processTimelineData(
        platformChannelData(channelEventCount: 50),
      );
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());
      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.severity, IssueSeverity.critical);
      final criticalIdentity = detector.issues.first.dedupIdentityMicros;
      expect(criticalIdentity, isNotNull);

      // Window 2 (cooldown still active): 25 events → would-be WARNING.
      // Severity mismatch with retained critical → fresh warning emits
      // with new dedup identity so live monitoring surfaces the
      // de-escalation immediately instead of holding stale critical UI
      // for up to 3 cycles.
      detector.processTimelineData(
        platformChannelData(channelEventCount: 25),
      );
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());
      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.severity, IssueSeverity.warning,
          reason: 'De-escalation through cooldown must surface the '
              'warning severity, not retain stale critical.');
      expect(detector.issues.first.dedupIdentityMicros, isNot(criticalIdentity),
          reason: 'De-escalated warning fire must stamp a new dedup '
              'identity so the controller records a second trace event.');
    });

    test(
        'severity oscillation under cooldown emits fresh issues for each '
        'mismatch boundary (W → C → W → C)', () {
      // Window 1: warning (25 events).
      detector.processTimelineData(
        platformChannelData(channelEventCount: 25),
      );
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());
      expect(detector.issues.first.severity, IssueSeverity.warning);
      final id1 = detector.issues.first.dedupIdentityMicros;

      // Window 2: critical (50 events). Mismatch → fresh.
      detector.processTimelineData(
        platformChannelData(channelEventCount: 50),
      );
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());
      expect(detector.issues.first.severity, IssueSeverity.critical);
      final id2 = detector.issues.first.dedupIdentityMicros;
      expect(id2, isNot(id1));

      // Window 3: warning (25 events). Mismatch → fresh.
      detector.processTimelineData(
        platformChannelData(channelEventCount: 25),
      );
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());
      expect(detector.issues.first.severity, IssueSeverity.warning);
      final id3 = detector.issues.first.dedupIdentityMicros;
      expect(id3, isNot(id2));

      // Window 4: critical (50 events). Mismatch → fresh.
      detector.processTimelineData(
        platformChannelData(channelEventCount: 50),
      );
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());
      expect(detector.issues.first.severity, IssueSeverity.critical);
      final id4 = detector.issues.first.dedupIdentityMicros;
      expect(id4, isNot(id3));

      expect({id1, id2, id3, id4}.length, 4,
          reason: 'Oscillating severity must produce 4 distinct dedup '
              'identities so the controller emits 4 separate trace records.');
    });

    test('reset() clears all per-scenario state for back-to-back capture legs',
        () {
      // Leg 1: fire warning, set cooldown=3.
      detector.processTimelineData(
        platformChannelData(channelEventCount: 25),
      );
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());
      expect(detector.issues, hasLength(1));
      final leg1Identity = detector.issues.first.dedupIdentityMicros;

      // Mid-leg-1 cooldown is active. Operator taps leg 2 → reset
      // clears window/cooldown/last-issue state. The next overload
      // window must fire fresh (not be suppressed by leftover cooldown
      // and dedup-blocked by the retained identity).
      detector.reset();
      expect(detector.issues, isEmpty,
          reason: 'reset() clears retained issue list.');

      // Leg 2: fire warning at the same severity. Without reset(), the
      // retained leg-1 _lastEmittedIssue would have severity=warning,
      // cooldown>0 → severity-mismatch rule says equal → SUPPRESS,
      // retain leg-1 identity. With reset(), cooldown=0 + last-issue
      // null → falls past cooldown gate → fresh emit with NEW identity.
      detector.processTimelineData(
        platformChannelData(channelEventCount: 25),
      );
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());
      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.dedupIdentityMicros, isNot(leg1Identity),
          reason: 'reset() makes the next leg\'s fire stamp a fresh '
              'dedup identity, so the controller\'s composite-key dedup '
              'does not collapse it to the prior leg\'s trace record.');
    });

    test('window reset clears issues after cooldown expires', () {
      // First window: 25 events → warning, sets cooldown = 3
      detector.processTimelineData(
        platformChannelData(channelEventCount: 25),
      );
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());
      expect(detector.issues, hasLength(1));

      // Cooldown cycles: issue persists for 3 empty evaluations,
      // then one more evaluation to reach the else branch that clears.
      for (var i = 0; i < 3; i++) {
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(emptyTimelineData());
        expect(detector.issues, hasLength(1), reason: 'cooldown cycle $i');
      }
      // Final evaluation after cooldown expired
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());
      expect(detector.issues, isEmpty);
    });

    test('stableId, confidence, and category', () {
      detector.processTimelineData(
        platformChannelData(channelEventCount: 25),
      );
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());

      final issue = detector.issues.first;
      expect(issue.stableId, 'platform_channel_traffic');
      expect(issue.confidence, IssueConfidence.confirmed);
      expect(issue.category, IssueCategory.channel);
    });

    test('title contains call count', () {
      detector.processTimelineData(
        platformChannelData(channelEventCount: 25),
      );
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());

      expect(detector.issues.first.title, contains('25'));
    });

    test('custom threshold works', () {
      detector = PlatformChannelDetector(
        callsPerSecThreshold: 5,
        clock: () => fakeNow,
      );
      detector.processTimelineData(
        platformChannelData(channelEventCount: 8),
      );
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());

      expect(detector.issues, hasLength(1));
    });

    test('detail mentions call count, duration, and thresholds', () {
      detector.processTimelineData(
        platformChannelData(channelEventCount: 25),
      );
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());

      final issue = detector.issues.first;
      expect(issue.detail, contains('25 calls'));
      expect(issue.detail, contains('Thresholds: 20 calls/sec'));
      expect(issue.detail, contains('8ms cumulative'));
    });

    test('fixHint recommends batching and Pigeon', () {
      detector.processTimelineData(
        platformChannelData(channelEventCount: 25),
      );
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());

      expect(detector.issues.first.fixHint, contains('Batch'));
      expect(detector.issues.first.fixHint, contains('Pigeon'));
    });

    test('no issue when duration below threshold despite moderate frequency',
        () {
      // 15 calls × 100µs each = 1.5ms (below 8ms threshold)
      // 15 calls (below 20 threshold)
      detector.processTimelineData(
        platformChannelData(channelEventCount: 15, durUs: 100),
      );
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());
      expect(detector.issues, isEmpty);
    });

    test('warning when cumulative duration exceeds threshold', () {
      // 3 calls × 5000µs = 15ms (> 8ms threshold), but only 3 calls (< 20)
      detector.processTimelineData(
        platformChannelData(channelEventCount: 3, durUs: 5000),
      );
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.severity, IssueSeverity.warning);
      expect(detector.issues.first.title, contains('Slow Platform Channels'));
      expect(detector.issues.first.title, contains('15.0ms'));
    });

    test('critical when cumulative duration far exceeds threshold', () {
      // 3 calls × 50000µs = 150ms (> 8ms × 2 = 16ms)
      detector.processTimelineData(
        platformChannelData(channelEventCount: 3, durUs: 50000),
      );
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.severity, IssueSeverity.critical);
    });

    test('detail includes method names', () {
      detector.processTimelineData(
        platformChannelData(channelEventCount: 25, methodName: 'getLocation'),
      );
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.detail, contains('getLocation: 25×'));
    });

    test(
        'single critical issue when both frequency and duration exceed thresholds',
        () {
      // 45 calls × 500µs = 22,500µs (> 8,000µs duration threshold)
      // 45 calls > 20 frequency threshold
      // 45 > 20 * 2 = 40 → critical severity
      detector.processTimelineData(
        platformChannelData(channelEventCount: 45, durUs: 500),
      );
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.severity, IssueSeverity.critical);
      // Title uses frequency variant when frequency is exceeded
      expect(detector.issues.first.title,
          contains('High Platform Channel Traffic'));
      expect(detector.issues.first.title, contains('45'));
      // Detail includes both call count and duration
      expect(detector.issues.first.detail, contains('45 calls'));
      expect(detector.issues.first.detail, contains('22.5ms'));
    });

    test('dispose clears issues', () {
      detector.processTimelineData(
        platformChannelData(channelEventCount: 25),
      );
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());
      expect(detector.issues, isNotEmpty);

      detector.dispose();
      expect(detector.issues, isEmpty);
    });

    group('sourceRoute binding (route-during-cooldown regression)', () {
      test(
          'persisted issue across cooldown carries sourceRoute = route at '
          'emission, not the route active at later cycles', () {
        // Cooldown semantics: emission on route A, navigation to B
        // mid-cooldown. Retained issue must keep sourceRoute=A so the
        // controller's aggregator does not reattribute to B.
        String currentRoute = '/demo/Channel Stress';
        final localFakeNow = DateTime(2026, 1, 1);
        DateTime nowRef = localFakeNow;
        final d = PlatformChannelDetector(
          clock: () => nowRef,
          sourceRouteProvider: () => currentRoute,
        );

        d.processTimelineData(
          platformChannelData(channelEventCount: 25),
        );
        nowRef = nowRef.add(const Duration(seconds: 2));
        d.processTimelineData(emptyTimelineData());
        expect(d.issues, hasLength(1));
        expect(d.issues.first.sourceRoute, '/demo/Channel Stress');

        // User navigates while cooldown still suppressing.
        currentRoute = '/';
        nowRef = nowRef.add(const Duration(seconds: 1));
        d.processTimelineData(emptyTimelineData());

        expect(d.issues, hasLength(1));
        expect(d.issues.first.sourceRoute, '/demo/Channel Stress',
            reason: 'cooldown-retained issue must NOT mutate sourceRoute');
      });

      test('null sourceRouteProvider yields null sourceRoute', () {
        detector.processTimelineData(
          platformChannelData(channelEventCount: 25),
        );
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(emptyTimelineData());
        expect(detector.issues.first.sourceRoute, isNull);
      });
    });
  });
}
