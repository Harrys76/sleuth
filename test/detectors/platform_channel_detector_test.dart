import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/detectors/platform_channel_detector.dart';
import 'package:sleuth/src/models/issue_measurement.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/vm/timeline_parser.dart';
import 'package:vm_service/vm_service.dart' show TimelineEvent;

import '../helpers/measurement_matchers.dart';
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
      detector.processTimelineData(platformChannelData(channelEventCount: 25));
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());
      expect(detector.issues, isEmpty);
    });

    test('no issues when call count below threshold after flush', () {
      // Feed 15 events (below default threshold of 20)
      detector.processTimelineData(platformChannelData(channelEventCount: 15));
      // Advance past 1s window and flush
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());
      expect(detector.issues, isEmpty);
    });

    test('warning when calls/sec exceed threshold after flush', () {
      detector.processTimelineData(platformChannelData(channelEventCount: 25));
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.severity, IssueSeverity.warning);
      expect(
        detector.issues.first.observationSource,
        ObservationSource.vmTimeline,
      );
      expectMeasurement(
        detector.issues.first,
        value: 25,
        unit: MeasurementUnit.perSecond,
        warningAt: detector.callsPerSecThreshold.toDouble(),
        criticalAt:
            (detector.callsPerSecThreshold *
                    PlatformChannelDetector.criticalMultiplier)
                .toDouble(),
      );
      expectSeverityMatchesMeasurement(detector.issues.first, strict: true);
    });

    test('a configured threshold sets both measurement lines', () {
      detector = PlatformChannelDetector(
        callsPerSecThreshold: 10,
        clock: () => fakeNow,
      );
      detector.processTimelineData(platformChannelData(channelEventCount: 15));
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());

      final issue = detector.issues.single;
      expect(issue.severity, IssueSeverity.warning);
      expectMeasurement(
        issue,
        value: 15,
        unit: MeasurementUnit.perSecond,
        warningAt: 10,
        criticalAt: 20,
        strict: true,
      );
    });

    test('critical when calls/sec exceed 2x threshold after flush', () {
      detector.processTimelineData(platformChannelData(channelEventCount: 45));
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.severity, IssueSeverity.critical);
      expectMeasurement(
        detector.issues.first,
        value: 45,
        unit: MeasurementUnit.perSecond,
        warningAt: detector.callsPerSecThreshold.toDouble(),
        criticalAt:
            (detector.callsPerSecThreshold *
                    PlatformChannelDetector.criticalMultiplier)
                .toDouble(),
      );
      expectSeverityMatchesMeasurement(detector.issues.first, strict: true);
    });

    test('consecutive overloads during cooldown retain prior issue identity '
        '(do not emit fresh issue per window)', () {
      // First window: 25 events → warning, sets cooldown = 3,
      // stamps dedupIdentityMicros = _windowStart at fire time.
      detector.processTimelineData(platformChannelData(channelEventCount: 25));
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());
      expect(detector.issues, hasLength(1));
      final firstFireIdentity = detector.issues.first.dedupIdentityMicros;
      expect(firstFireIdentity, isNotNull);
      final firstMeasurement = detector.issues.first.measurement;
      expect(firstMeasurement, isNotNull);

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
        expect(
          detector.issues,
          hasLength(1),
          reason: 'cooldown cycle $i: issue retained',
        );
        expect(
          detector.issues.first.dedupIdentityMicros,
          firstFireIdentity,
          reason:
              'cooldown cycle $i: dedup identity preserved across '
              'suppressed cycles so composite-key dedup collapses '
              'consecutive overloads to one trace record',
        );
        expect(
          detector.issues.first.measurement,
          firstMeasurement,
          reason: 'cooldown cycle $i: the re-shown issue keeps its measurement',
        );
      }

      // After cooldown drains, next overload re-fires with FRESH
      // dedup identity (new _windowStart microsecond stamp).
      detector.processTimelineData(platformChannelData(channelEventCount: 25));
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());
      expect(detector.issues, hasLength(1));
      expect(
        detector.issues.first.dedupIdentityMicros,
        isNot(firstFireIdentity),
        reason:
            'post-cooldown re-fire stamps a new dedup identity from '
            'the new _windowStart so the controller emits a second '
            'trace record (not a duplicate of the prior fire).',
      );
    });

    test('emitted issue carries extraTraceArgs with observedCount and '
        'per-call duration stats', () {
      detector.processTimelineData(platformChannelData(channelEventCount: 25));
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());
      expect(detector.issues, hasLength(1));
      final issue = detector.issues.first;
      expect(issue.extraTraceArgs, isNotNull);
      expect(
        issue.extraTraceArgs!['observedCount'],
        '25',
        reason:
            'observedCount mirrors _recentCallCount at fire-time so '
            'the audit gate can cross-check the capture\'s send-side '
            'magnitude against the parser-observed count.',
      );
      expect(issue.extraTraceArgs!['maxCallDurationUs'], '100');
      expect(issue.extraTraceArgs!['p95CallDurationUs'], '100');
      expect(issue.extraTraceArgs!['callsOverThreshold'], '0');
      expect(issue.extraTraceArgs!.containsKey('cumulativeDurationUs'), false);
    });

    test('severity escalation breaks through cooldown — warning then critical '
        'emits fresh critical issue with new dedup identity', () {
      // Window 1: 25 events → warning fires, cooldown = 3, identity stamped.
      detector.processTimelineData(platformChannelData(channelEventCount: 25));
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
      detector.processTimelineData(platformChannelData(channelEventCount: 45));
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());
      expect(detector.issues, hasLength(1));
      expect(
        detector.issues.first.severity,
        IssueSeverity.critical,
        reason:
            'Escalation through cooldown must surface the critical '
            'severity, not retain the prior warning.',
      );
      expect(
        detector.issues.first.dedupIdentityMicros,
        isNot(warningIdentity),
        reason:
            'Escalated critical fire must stamp a new dedup identity '
            'so the controller does not collapse it to the prior warning '
            'trace record.',
      );

      // Window 3: 50 events → still critical. Cooldown active again (just
      // reset to 3 by escalation), prior was critical → severity matches
      // → suppressed, retains prior critical issue identity.
      final escalatedIdentity = detector.issues.first.dedupIdentityMicros;
      detector.processTimelineData(platformChannelData(channelEventCount: 50));
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());
      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.severity, IssueSeverity.critical);
      expect(
        detector.issues.first.dedupIdentityMicros,
        escalatedIdentity,
        reason:
            'Sustained critical (no escalation step) is suppressed '
            'by cooldown — retains escalated identity, no fresh fire.',
      );
    });

    test('severity de-escalation breaks through cooldown — critical then '
        'warning emits fresh warning with new dedup identity', () {
      // Window 1: 50 events → critical fires, cooldown = 3.
      detector.processTimelineData(platformChannelData(channelEventCount: 50));
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
      detector.processTimelineData(platformChannelData(channelEventCount: 25));
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());
      expect(detector.issues, hasLength(1));
      expect(
        detector.issues.first.severity,
        IssueSeverity.warning,
        reason:
            'De-escalation through cooldown must surface the '
            'warning severity, not retain stale critical.',
      );
      expect(
        detector.issues.first.dedupIdentityMicros,
        isNot(criticalIdentity),
        reason:
            'De-escalated warning fire must stamp a new dedup '
            'identity so the controller records a second trace event.',
      );
    });

    test('severity oscillation under cooldown emits fresh issues for each '
        'mismatch boundary (W → C → W → C)', () {
      // Window 1: warning (25 events).
      detector.processTimelineData(platformChannelData(channelEventCount: 25));
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());
      expect(detector.issues.first.severity, IssueSeverity.warning);
      final id1 = detector.issues.first.dedupIdentityMicros;

      // Window 2: critical (50 events). Mismatch → fresh.
      detector.processTimelineData(platformChannelData(channelEventCount: 50));
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());
      expect(detector.issues.first.severity, IssueSeverity.critical);
      final id2 = detector.issues.first.dedupIdentityMicros;
      expect(id2, isNot(id1));

      // Window 3: warning (25 events). Mismatch → fresh.
      detector.processTimelineData(platformChannelData(channelEventCount: 25));
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());
      expect(detector.issues.first.severity, IssueSeverity.warning);
      final id3 = detector.issues.first.dedupIdentityMicros;
      expect(id3, isNot(id2));

      // Window 4: critical (50 events). Mismatch → fresh.
      detector.processTimelineData(platformChannelData(channelEventCount: 50));
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());
      expect(detector.issues.first.severity, IssueSeverity.critical);
      final id4 = detector.issues.first.dedupIdentityMicros;
      expect(id4, isNot(id3));

      expect(
        {id1, id2, id3, id4}.length,
        4,
        reason:
            'Oscillating severity must produce 4 distinct dedup '
            'identities so the controller emits 4 separate trace records.',
      );
    });

    test(
      'reset() clears all per-scenario state for back-to-back capture legs',
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
        expect(
          detector.issues,
          isEmpty,
          reason: 'reset() clears retained issue list.',
        );

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
        expect(
          detector.issues.first.dedupIdentityMicros,
          isNot(leg1Identity),
          reason:
              'reset() makes the next leg\'s fire stamp a fresh '
              'dedup identity, so the controller\'s composite-key dedup '
              'does not collapse it to the prior leg\'s trace record.',
        );
      },
    );

    test('issue clears once emissionPersistence has passed after the '
        'cooldown', () {
      // First window: 25 events → warning at t = 2 s, cooldown = 3.
      detector.processTimelineData(platformChannelData(channelEventCount: 25));
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());
      expect(detector.issues, hasLength(1));

      // Cooldown windows at +2, +4, +6 s, then persistence at +8 s.
      for (var i = 0; i < 4; i++) {
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(emptyTimelineData());
        expect(detector.issues, hasLength(1), reason: 'evaluation $i');
      }
      // +10 s since the emission: cleared.
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());
      expect(detector.issues, isEmpty);
    });

    group('emission persistence', () {
      late DateTime emittedAt;

      /// One 1 s window with [count] calls, evaluated on the next poll.
      void window(int count) {
        detector.processTimelineData(
          platformChannelData(channelEventCount: count),
        );
        fakeNow = fakeNow.add(const Duration(seconds: 1));
        detector.processTimelineData(emptyTimelineData());
      }

      void burst() {
        window(50);
        emittedAt = fakeNow;
      }

      void quietUntil(Duration sinceEmission) {
        while (fakeNow.difference(emittedAt) < sinceEmission) {
          fakeNow = fakeNow.add(const Duration(seconds: 1));
          detector.processTimelineData(emptyTimelineData());
        }
      }

      test('defaults to 10 s', () {
        expect(PlatformChannelDetector().emissionPersistence.inSeconds, 10);
      });

      test('a burst stays through the cooldown and the persistence window', () {
        burst();
        final issue = detector.issues.single;
        expect(issue.severity, IssueSeverity.critical);

        // Three sub-threshold windows: cooldown retains the issue.
        for (var i = 0; i < 3; i++) {
          window(5);
          expect(detector.issues.single, same(issue));
        }
        quietUntil(const Duration(seconds: 4));
        expect(detector.issues.single, same(issue));
        quietUntil(const Duration(seconds: 9));
        expect(detector.issues.single, same(issue));
        quietUntil(const Duration(seconds: 11));
        expect(detector.issues, isEmpty);
      });

      test('a custom emissionPersistence is honoured', () {
        detector = PlatformChannelDetector(
          clock: () => fakeNow,
          emissionPersistence: const Duration(seconds: 5),
        );
        burst();
        quietUntil(const Duration(seconds: 4));
        expect(detector.issues, hasLength(1));
        quietUntil(const Duration(seconds: 5));
        expect(detector.issues, isEmpty);
      });

      test('a new burst inside persistence after the cooldown gets a fresh '
          'identity', () {
        burst();
        final first = detector.issues.single.dedupIdentityMicros;
        quietUntil(const Duration(seconds: 5));
        expect(detector.issues.single.dedupIdentityMicros, first);

        burst();
        final second = detector.issues.single;
        expect(second.dedupIdentityMicros, isNot(first));
        // And it persists from its own emission.
        quietUntil(const Duration(seconds: 9));
        expect(detector.issues.single, same(second));
      });

      test('severity flip during the cooldown still re-emits', () {
        window(25);
        final warning = detector.issues.single;
        expect(warning.severity, IssueSeverity.warning);
        window(50);
        final critical = detector.issues.single;
        expect(critical.severity, IssueSeverity.critical);
        expect(
          critical.dedupIdentityMicros,
          isNot(warning.dedupIdentityMicros),
        );
      });

      test('the retained issue keeps its sourceRoute', () {
        var route = '/burst';
        detector = PlatformChannelDetector(
          clock: () => fakeNow,
          sourceRouteProvider: () => route,
        );
        burst();
        route = '/elsewhere';
        quietUntil(const Duration(seconds: 8));
        expect(detector.issues.single.sourceRoute, '/burst');
      });

      test('reset and dispose drop a persisting issue', () {
        burst();
        quietUntil(const Duration(seconds: 6));
        detector.reset();
        expect(detector.issues, isEmpty);
        fakeNow = fakeNow.add(const Duration(seconds: 1));
        detector.processTimelineData(emptyTimelineData());
        expect(detector.issues, isEmpty);

        burst();
        quietUntil(const Duration(seconds: 6));
        detector.dispose();
        expect(detector.issues, isEmpty);
      });
    });

    test('stableId, confidence, and category', () {
      detector.processTimelineData(platformChannelData(channelEventCount: 25));
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());

      final issue = detector.issues.first;
      expect(issue.stableId, 'platform_channel_traffic');
      expect(issue.confidence, IssueConfidence.confirmed);
      expect(issue.category, IssueCategory.channel);
    });

    test('title contains call count', () {
      detector.processTimelineData(platformChannelData(channelEventCount: 25));
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());

      expect(detector.issues.first.title, contains('25'));
    });

    test('custom threshold works', () {
      detector = PlatformChannelDetector(
        callsPerSecThreshold: 5,
        clock: () => fakeNow,
      );
      detector.processTimelineData(platformChannelData(channelEventCount: 8));
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());

      expect(detector.issues, hasLength(1));
    });

    test('detail mentions call count, per-call durations, and threshold', () {
      detector.processTimelineData(platformChannelData(channelEventCount: 25));
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());

      final issue = detector.issues.first;
      expect(issue.detail, contains('25 calls'));
      expect(issue.detail, contains('Threshold: 20 calls/sec'));
      expect(
        issue.detail,
        contains('max call 0.1 ms, p95 0.1 ms, 0 calls over 8 ms'),
      );
      expect(issue.detail, isNot(contains('cumulative')));
    });

    test('fixHint recommends batching and Pigeon', () {
      detector.processTimelineData(platformChannelData(channelEventCount: 25));
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());

      expect(detector.issues.first.fixHint, contains('Batch'));
      expect(detector.issues.first.fixHint, contains('Pigeon'));
    });

    test(
      'no issue when duration below threshold despite moderate frequency',
      () {
        // 15 calls × 100µs each = 1.5ms (below 8ms threshold)
        // 15 calls (below 20 threshold)
        detector.processTimelineData(
          platformChannelData(channelEventCount: 15, durUs: 100),
        );
        fakeNow = fakeNow.add(const Duration(seconds: 2));
        detector.processTimelineData(emptyTimelineData());
        expect(detector.issues, isEmpty);
      },
    );

    test('15 slow calls (20 ms each) are observed but do not emit', () {
      detector.processTimelineData(
        platformChannelData(channelEventCount: 15, durUs: 20000),
      );
      expect(detector.callsOverThreshold, 15);
      expect(detector.maxCallDurationUs, 20000);
      expect(detector.p95CallDurationUs, 20000);
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());

      expect(detector.issues, isEmpty);
      final stats = detector.lastWindowStats!;
      expect(stats.callCount, 15);
      expect(stats.callsOverThreshold, 15);
      expect(stats.maxCallDurationUs, 20000);
    });

    test('3 very slow calls (50 ms each) do not emit', () {
      detector.processTimelineData(
        platformChannelData(channelEventCount: 3, durUs: 50000),
      );
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());
      expect(detector.issues, isEmpty);
    });

    test('25 slow calls emit by count with duration stats stamped', () {
      detector.processTimelineData(
        platformChannelData(channelEventCount: 25, durUs: 20000),
      );
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());

      expect(detector.issues, hasLength(1));
      final issue = detector.issues.first;
      expect(issue.severity, IssueSeverity.warning);
      expect(issue.title, contains('High Platform Channel Traffic: 25'));
      expect(issue.extraTraceArgs!['observedCount'], '25');
      expect(issue.extraTraceArgs!['maxCallDurationUs'], '20000');
      expect(issue.extraTraceArgs!['p95CallDurationUs'], '20000');
      expect(issue.extraTraceArgs!['callsOverThreshold'], '25');
      expect(issue.detail, contains('25 calls over 8 ms'));
    });

    test('p95 uses nearest rank over the window', () {
      // 19 calls at 1 ms + 1 call at 30 ms: rank ceil(0.95 × 20) = 19.
      detector.processTimelineData(
        platformChannelData(channelEventCount: 19, durUs: 1000),
      );
      detector.processTimelineData(
        platformChannelData(channelEventCount: 1, durUs: 30000),
      );
      expect(detector.p95CallDurationUs, 1000);
      expect(detector.maxCallDurationUs, 30000);
      expect(detector.callsOverThreshold, 1);
    });

    test('window with no completed calls reports zero durations', () {
      detector.processTimelineData(
        ParsedTimelineData(
          platformChannelEvents: platformChannelData(
            channelEventCount: 25,
          ).platformChannelEvents,
        ),
      );
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());
      final issue = detector.issues.single;
      expect(issue.extraTraceArgs!['maxCallDurationUs'], '0');
      expect(issue.detail, contains('no call durations observed'));
    });

    test('detail includes method names', () {
      detector.processTimelineData(
        platformChannelData(channelEventCount: 25, methodName: 'getLocation'),
      );
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.detail, contains('getLocation: 25 calls'));
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
        expect(
          detector.issues.first.title,
          contains('High Platform Channel Traffic'),
        );
        expect(detector.issues.first.title, contains('45'));
        // Detail includes call count and per-call duration
        expect(detector.issues.first.detail, contains('45 calls'));
        expect(detector.issues.first.detail, contains('max call 0.5 ms'));
      },
    );

    test('dispose clears issues', () {
      detector.processTimelineData(platformChannelData(channelEventCount: 25));
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(emptyTimelineData());
      expect(detector.issues, isNotEmpty);

      detector.dispose();
      expect(detector.issues, isEmpty);
    });

    group('sourceRoute binding (route-during-cooldown regression)', () {
      test('persisted issue across cooldown carries sourceRoute = route at '
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

        d.processTimelineData(platformChannelData(channelEventCount: 25));
        nowRef = nowRef.add(const Duration(seconds: 2));
        d.processTimelineData(emptyTimelineData());
        expect(d.issues, hasLength(1));
        expect(d.issues.first.sourceRoute, '/demo/Channel Stress');

        // User navigates while cooldown still suppressing.
        currentRoute = '/';
        nowRef = nowRef.add(const Duration(seconds: 1));
        d.processTimelineData(emptyTimelineData());

        expect(d.issues, hasLength(1));
        expect(
          d.issues.first.sourceRoute,
          '/demo/Channel Stress',
          reason: 'cooldown-retained issue must NOT mutate sourceRoute',
        );
      });

      test('cooldown-retained issue keeps its emission-time context', () {
        var context = InteractionContext.navigating;
        DateTime nowRef = DateTime(2026, 1, 1);
        final d = PlatformChannelDetector(
          clock: () => nowRef,
          interactionContextProvider: () => context,
        );

        d.processTimelineData(platformChannelData(channelEventCount: 25));
        nowRef = nowRef.add(const Duration(seconds: 2));
        d.processTimelineData(emptyTimelineData());
        expect(
          d.issues.single.interactionContext,
          InteractionContext.navigating,
        );

        context = InteractionContext.idle;
        nowRef = nowRef.add(const Duration(seconds: 1));
        d.processTimelineData(emptyTimelineData());
        expect(
          d.issues.single.interactionContext,
          InteractionContext.navigating,
        );
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

    group('counting by event time', () {
      // One sync call per entry of [tsUs], on thread 1 unless [tids] gives
      // each call its own, with [durationsUs] or 100 µs as durations.
      ParsedTimelineData calls(
        List<int> tsUs, {
        String method = 'tick',
        List<int>? tids,
        List<int>? durationsUs,
      }) => ParsedTimelineData(
        platformChannelEvents: [
          for (var i = 0; i < tsUs.length; i++)
            TimelineEvent.parse({
              'name': 'PlatformChannel',
              'cat': '',
              'ph': 'X',
              'dur': durationsUs?[i] ?? 100,
              'ts': tsUs[i],
              'pid': 1,
              'tid': tids?[i] ?? 1,
              'args': {'method': method},
            })!,
        ],
        platformChannelCalls: [
          for (var i = 0; i < tsUs.length; i++)
            PlatformChannelCall(
              name: method,
              beginTs: tsUs[i],
              durationUs: durationsUs?[i] ?? 100,
              tid: tids?[i] ?? 1,
            ),
        ],
      );

      List<int> spaced(int startUs, int count, int stepUs) => [
        for (var i = 0; i < count; i++) startUs + i * stepUs,
      ];

      void check() {
        fakeNow = fakeNow.add(const Duration(milliseconds: 1100));
        detector.processTimelineData(emptyTimelineData());
      }

      const s = 50000000;

      test('a second of calls split across two polls counts once, in '
          'full', () {
        // 25 calls 40 ms apart: 13 in the first poll, 12 in the next.
        final all = spaced(s, 25, 40000);
        detector.processTimelineData(calls(all.sublist(0, 13)));
        check();
        expect(detector.lastWindowStats!.callCount, 13);
        expect(detector.issues, isEmpty);

        detector.processTimelineData(calls(all.sublist(13)));
        check();
        expect(detector.lastWindowStats!.callCount, 25);
        expect(detector.issues.single.severity, IssueSeverity.warning);
        expect(detector.issues.single.title, contains('25 calls/sec'));
      });

      test('a burst split across two polls escalates at the second check', () {
        final all = spaced(s, 50, 10000);
        detector.processTimelineData(calls(all.sublist(0, 30)));
        check();
        final first = detector.issues.single;
        expect(first.severity, IssueSeverity.warning);

        detector.processTimelineData(calls(all.sublist(30)));
        check();
        final second = detector.issues.single;
        expect(second.severity, IssueSeverity.critical);
        expect(second.dedupIdentityMicros, isNot(first.dedupIdentityMicros));
      });

      test('a check with no new calls counts 0', () {
        detector.processTimelineData(calls(spaced(s, 25, 1000)));
        check();
        expect(detector.lastWindowStats!.callCount, 25);
        check();
        expect(detector.lastWindowStats!.callCount, 0);
      });

      test('out-of-order calls count as if sorted', () {
        detector.processTimelineData(
          calls(spaced(s, 25, 30000).reversed.toList()),
        );
        check();
        expect(detector.lastWindowStats!.callCount, 25);
      });

      test('calls more than 1 s apart do not share a span', () {
        detector.processTimelineData(
          calls([...spaced(s, 15, 1000), ...spaced(s + 1000000, 15, 1000)]),
        );
        check();
        expect(detector.lastWindowStats!.callCount, 15);
        expect(detector.issues, isEmpty);
      });

      test('the method counts and durations describe the counted span', () {
        detector.processTimelineData(
          calls(spaced(s, 15, 1000), method: 'tick'),
        );
        detector.processTimelineData(
          calls(spaced(s + 20000, 10, 1000), method: 'ping'),
        );
        // These calls lie outside the busiest span and must not reach the
        // method line.
        detector.processTimelineData(
          calls(spaced(s + 1500000, 5, 1000), method: 'late'),
        );
        check();
        final issue = detector.issues.single;
        expect(issue.title, contains('25 calls/sec'));
        expect(issue.detail, contains('tick: 15 calls'));
        expect(issue.detail, contains('ping: 10 calls'));
        expect(issue.detail, isNot(contains('late')));
        expect(issue.extraTraceArgs!['observedCount'], '25');
      });

      test('calls replayed after reset with earlier times are dropped', () {
        detector.processTimelineData(calls(spaced(s, 5, 1000)));
        detector.reset();
        detector.processTimelineData(calls(spaced(s - 500000, 25, 1000)));
        check();
        expect(detector.lastWindowStats!.callCount, 0);
        expect(detector.issues, isEmpty);
      });

      test('dispose drops retained calls', () {
        detector.processTimelineData(calls(spaced(s, 25, 1000)));
        detector.dispose();
        check();
        expect(detector.lastWindowStats!.callCount, 0);
      });

      test('repeated events after a reconnect are not counted again', () {
        final burst = spaced(s, 25, 1000);
        detector.processTimelineData(calls(burst));
        check();
        final first = detector.issues.single;
        expect(first.severity, IssueSeverity.warning);

        // A reconnect resets the client's cursors, reported or not, so its
        // first poll delivers the same events again.
        detector.processTimelineData(calls(burst));
        check();
        expect(detector.lastWindowStats!.callCount, 0);
        expect(
          detector.issues.single.dedupIdentityMicros,
          first.dedupIdentityMicros,
        );
      });

      test('repeats of calls that already aged out are not counted', () {
        final burst = spaced(s, 25, 1000);
        detector.processTimelineData(calls(burst));
        check();
        detector.processTimelineData(calls(spaced(s + 12000000, 5, 1000)));
        check();
        // A full read after a reconnect delivers the old burst again.
        detector.processTimelineData(calls(burst));
        check();
        expect(detector.lastWindowStats!.callCount, 0);
      });

      test('a burst not yet checked survives a reconnect', () {
        detector.processTimelineData(calls(spaced(s, 45, 10000)));
        detector.vmConnected = false;
        detector.vmConnected = true;
        check();
        expect(detector.lastWindowStats!.callCount, 45);
        expect(detector.issues.single.severity, IssueSeverity.critical);
      });

      test('calls after a reconnect still count', () {
        detector.processTimelineData(calls(spaced(s, 5, 1000)));
        detector.vmConnected = false;
        detector.vmConnected = true;
        detector.processTimelineData(calls(spaced(s + 2000000, 25, 1000)));
        check();
        expect(detector.lastWindowStats!.callCount, 25);
      });

      test('a reset boundary keeps earlier calls out of the scenario', () {
        detector.reset(horizonUs: s);
        // The app made these calls before the boundary; a later poll
        // delivers them.
        detector.processTimelineData(calls(spaced(s - 500000, 25, 1000)));
        // The app made these after it.
        detector.processTimelineData(calls(spaced(s + 100000, 5, 1000)));
        check();
        expect(detector.lastWindowStats!.callCount, 5);
        expect(detector.issues, isEmpty);
      });

      test('a scenario boundary only moves forward', () {
        detector.processTimelineData(calls(spaced(s - 3000000, 5, 1000)));
        detector.reset(horizonUs: s);
        // A later reset with an earlier boundary keeps the first one.
        detector.reset(horizonUs: s - 2000000);
        detector.processTimelineData(calls(spaced(s - 1000000, 25, 1000)));
        check();
        expect(detector.lastWindowStats!.callCount, 0);
      });

      test('a delayed batch spanning more than 2 s keeps its burst for '
          'the check', () {
        // One poll delivers a 45-call burst and a call 3 s later.
        detector.processTimelineData(
          calls([...spaced(s, 45, 10000), s + 3000000]),
        );
        check();
        expect(detector.lastWindowStats!.callCount, 45);
        expect(detector.issues.single.severity, IssueSeverity.critical);
      });

      test('a poll over the cap still counts its whole span', () {
        final n = PlatformChannelDetector.maxRetainedCalls + 500;
        detector.processTimelineData(calls(spaced(s, n, 100)));
        check();
        expect(detector.lastWindowStats!.callCount, n);
      });

      test('a burst the cap evicts before any check still counts', () {
        // One full read: a 45-call burst, then maxRetainedCalls calls at
        // 10 per second. The cap drops the burst before the check runs.
        detector.processTimelineData(
          calls([
            ...spaced(s, 45, 10000),
            ...spaced(
              s + 2000000,
              PlatformChannelDetector.maxRetainedCalls,
              100000,
            ),
          ]),
        );
        check();
        expect(detector.lastWindowStats!.callCount, 45);
        expect(detector.issues.single.severity, IssueSeverity.critical);
        expect(detector.issues.single.extraTraceArgs!['observedCount'], '45');
      });

      test('a burst the cap evicts keeps its call durations', () {
        detector.processTimelineData(
          calls(
            [
              ...spaced(s, 25, 10000),
              ...spaced(
                s + 2000000,
                PlatformChannelDetector.maxRetainedCalls,
                100000,
              ),
            ],
            durationsUs: [
              for (var i = 0; i < 25; i++) 9000,
              for (var i = 0; i < PlatformChannelDetector.maxRetainedCalls; i++)
                100,
            ],
          ),
        );
        check();
        final stats = detector.lastWindowStats!;
        expect(stats.callCount, 25);
        expect(stats.maxCallDurationUs, 9000);
        expect(stats.callsOverThreshold, 25);
      });

      test('a late call on another thread still counts', () {
        detector.processTimelineData(
          calls([...spaced(s, 5, 1000), s + 3000000]),
        );
        check();
        check();
        // Calls that began 3 s before the newest one, each on its own
        // thread, reach the detector only now. They count with the five
        // calls already checked in the same second.
        detector.processTimelineData(
          calls(
            spaced(s + 100000, 45, 10000),
            tids: [for (var i = 0; i < 45; i++) 100 + i],
          ),
        );
        check();
        expect(detector.lastWindowStats!.callCount, 50);
        expect(detector.issues.single.severity, IssueSeverity.critical);
      });

      test('late calls through the parser complete a burst already '
          'checked', () {
        final cursors = <int, TimelineCursor>{};
        final pending = PendingChannelBegins();
        Map<String, dynamic> x(int ts, int tid) => {
          'name': 'MethodChannel',
          'cat': 'Embedder',
          'ph': 'X',
          'dur': 100,
          'ts': ts,
          'pid': 1,
          'tid': tid,
        };
        ParsedTimelineData parse(List<Map<String, dynamic>> events) =>
            TimelineParser.parse(
              [for (final e in events) TimelineEvent.parse(e)!],
              pendingChannelBegins: pending,
              cursorsByTid: cursors,
            );

        // 20 calls in 0.2 s and one 3 s later, all on one thread.
        detector.processTimelineData(
          parse([
            for (final ts in spaced(s, 20, 10000)) x(ts, 1),
            x(s + 3000000, 1),
          ]),
        );
        check();
        expect(detector.lastWindowStats!.callCount, 20);
        expect(detector.issues, isEmpty);

        // 25 more calls from the same second end later on fresh threads.
        detector.processTimelineData(
          parse([
            for (var i = 0; i < 25; i++) x(s + 200000 + i * 10000, 100 + i),
          ]),
        );
        check();
        expect(detector.lastWindowStats!.callCount, 45);
        expect(detector.issues.single.severity, IssueSeverity.critical);
      });

      test('an open call keeps its duration when the cap drops its begin '
          'before a check', () {
        // 250 calls begin in a quarter second and all but the first end
        // in the same poll, then 4096 more begin later.
        final burst = spaced(s, 250, 1000);
        final later = spaced(
          s + 2000000,
          PlatformChannelDetector.maxRetainedCalls,
          5000,
        );
        final first = calls([...burst, ...later]);
        detector.processTimelineData(
          ParsedTimelineData(
            platformChannelEvents: first.platformChannelEvents,
            platformChannelCalls: first.platformChannelCalls.skip(1).toList(),
          ),
        );
        // The first call ends 23 s after it began, before any check.
        detector.processTimelineData(
          ParsedTimelineData(
            platformChannelCalls: [
              PlatformChannelCall(
                name: 'tick',
                beginTs: s,
                durationUs: 23000000,
                id: 'slow',
                tid: 1,
              ),
            ],
          ),
        );
        check();
        final stats = detector.lastWindowStats!;
        expect(stats.callCount, 250);
        expect(stats.maxCallDurationUs, 23000000);
        expect(stats.callsOverThreshold, 1);
      });

      test('repeats of begins the cap dropped are not counted', () {
        final batch = calls(
          spaced(s, PlatformChannelDetector.maxRetainedCalls + 500, 100),
        );
        detector.processTimelineData(batch);
        check();
        detector.processTimelineData(batch);
        check();
        expect(detector.lastWindowStats!.callCount, 0);
      });

      test('a late call that joins a reported span adds no second issue', () {
        detector.processTimelineData(calls(spaced(s, 25, 10000)));
        check();
        final first = detector.issues.single;
        // Three checks drain the cooldown.
        check();
        check();
        check();
        // A call from the same second arrives late on another thread.
        detector.processTimelineData(calls([s + 300000], tids: [100]));
        check();
        expect(detector.lastWindowStats!.callCount, 26);
        expect(
          detector.issues.single.dedupIdentityMicros,
          first.dedupIdentityMicros,
        );
      });

      test('late calls that raise a reported span to critical still emit', () {
        detector.processTimelineData(calls(spaced(s, 25, 10000)));
        check();
        final first = detector.issues.single;
        check();
        check();
        check();
        detector.processTimelineData(
          calls(
            spaced(s + 300000, 20, 10000),
            tids: [for (var i = 0; i < 20; i++) 100 + i],
          ),
        );
        check();
        final second = detector.issues.single;
        expect(detector.lastWindowStats!.callCount, 45);
        expect(second.severity, IssueSeverity.critical);
        expect(second.dedupIdentityMicros, isNot(first.dedupIdentityMicros));
      });

      test('a late call in a reported span does not hide a new burst in '
          'the same check', () {
        detector.processTimelineData(calls(spaced(s, 51, 10000)));
        check();
        expect(detector.issues.single.severity, IssueSeverity.critical);
        // The cooldown and the 10 s persistence run out.
        for (var i = 0; i < 10; i++) {
          check();
        }
        expect(detector.issues, isEmpty);
        // One poll brings a late call inside the reported span and a new
        // 45-call burst 12 s later.
        detector.processTimelineData(
          calls(
            [s + 600000, ...spaced(s + 12000000, 45, 10000)],
            tids: [100, for (var i = 0; i < 45; i++) 1],
          ),
        );
        check();
        final issue = detector.issues.single;
        expect(issue.severity, IssueSeverity.critical);
        expect(issue.title, contains('45 calls/sec'));
        expect(detector.lastWindowStats!.callCount, 45);
      });

      test('a late call in an earlier reported span adds no issue after '
          'a later one', () {
        final identities = <int?>{};
        void record() {
          for (final issue in detector.issues) {
            identities.add(issue.dedupIdentityMicros);
          }
        }

        detector.processTimelineData(calls(spaced(s, 25, 10000)));
        check();
        record();
        for (var i = 0; i < 3; i++) {
          check();
        }
        detector.processTimelineData(calls(spaced(s + 2000000, 25, 10000)));
        check();
        record();
        for (var i = 0; i < 3; i++) {
          check();
        }
        expect(identities, hasLength(2));
        // A call from the first span arrives late on another thread.
        detector.processTimelineData(calls([s + 300000], tids: [100]));
        check();
        record();
        expect(detector.lastWindowStats!.callCount, 26);
        expect(identities, hasLength(2));
      });

      test('many reports inside the retention window keep the first one '
          'covered', () {
        final identities = <int?>{};
        void record() {
          for (final issue in detector.issues) {
            identities.add(issue.dedupIdentityMicros);
          }
        }

        detector.processTimelineData(calls(spaced(s, 25, 40000)));
        check();
        record();
        // 64 more reports, each one call later, all within 3.6 s of event
        // time.
        for (var j = 0; j < 64; j++) {
          for (var i = 0; i < 3; i++) {
            check();
          }
          detector.processTimelineData(calls([s + 1000000 + j * 40000]));
          check();
          record();
        }
        expect(identities, hasLength(65));
        for (var i = 0; i < 3; i++) {
          check();
        }
        // A late call inside the first reported span adds no issue.
        detector.processTimelineData(calls([s + 1000], tids: [100]));
        check();
        record();
        expect(identities, hasLength(65));
      });

      test('a reset forgets the reported span', () {
        detector.processTimelineData(calls(spaced(s, 25, 10000)));
        check();
        expect(detector.issues.single.severity, IssueSeverity.warning);
        detector.reset(horizonUs: s + 300000);
        // The next scenario's calls begin inside the span reported before
        // the reset.
        detector.processTimelineData(calls(spaced(s + 400000, 25, 10000)));
        check();
        expect(detector.issues.single.severity, IssueSeverity.warning);
      });

      test('a sustained overload still emits after each cooldown', () {
        final identities = <int?>{};
        for (var k = 0; k < 6; k++) {
          detector.processTimelineData(
            calls(spaced(s + k * 1000000, 25, 40000)),
          );
          check();
          identities.add(detector.issues.single.dedupIdentityMicros);
        }
        // One emission, three cooldown checks, then a fresh emission.
        expect(identities, hasLength(2));
      });

      test('a call more than 10 s behind the newest is skipped', () {
        detector.processTimelineData(calls([s + 12000000]));
        check();
        check();
        detector.processTimelineData(
          calls(
            spaced(s + 1000000, 25, 1000),
            tids: [for (var i = 0; i < 25; i++) 100 + i],
          ),
        );
        check();
        expect(detector.lastWindowStats!.callCount, 0);
      });

      test('calls on two threads at the same time keep both durations', () {
        // A fast and a slow call begin in the same microsecond on two
        // threads, the fast one delivered first.
        final ts = [s, s, ...spaced(s + 1000, 23, 1000)];
        final tids = [1, 2, for (var i = 0; i < 23; i++) 1];
        final durations = [100, 9000, for (var i = 0; i < 23; i++) 100];
        final batch = calls(ts, tids: tids, durationsUs: durations);
        detector.processTimelineData(batch);
        check();
        final stats = detector.lastWindowStats!;
        expect(stats.callCount, 25);
        expect(stats.maxCallDurationUs, 9000);
        expect(stats.callsOverThreshold, 1);

        // A full re-read after a reconnect adds nothing.
        detector.processTimelineData(batch);
        check();
        expect(detector.lastWindowStats!.callCount, 0);
      });

      test('a long call that ends after the call cap evicted later calls '
          'keeps its duration', () {
        // A slow call begins first and is still open while
        // maxRetainedCalls + 1 fast calls end on the same thread. Only the
        // completed calls arrive for those, so the begin cap stays unused.
        detector.processTimelineData(
          ParsedTimelineData(
            platformChannelEvents: calls([s]).platformChannelEvents,
          ),
        );
        final fast = spaced(
          s + 100,
          PlatformChannelDetector.maxRetainedCalls + 1,
          100,
        );
        detector.processTimelineData(
          ParsedTimelineData(
            platformChannelCalls: calls(fast).platformChannelCalls,
          ),
        );
        // The slow call ends now; it began 100 µs before the first fast one.
        detector.processTimelineData(
          ParsedTimelineData(
            platformChannelCalls: [
              PlatformChannelCall(
                name: 'tick',
                beginTs: s,
                durationUs: 9000,
                tid: 1,
              ),
            ],
          ),
        );
        check();
        expect(detector.lastWindowStats!.maxCallDurationUs, 9000);
      });

      test('thread marks stay bounded and repeats stay skipped', () {
        // 300 threads each make one call, and the cap drops all of them
        // when 4096 more calls arrive in the same poll.
        final n = PlatformChannelDetector.maxRetainedCalls;
        final batch = calls(
          [...spaced(s, 300, 1000), ...spaced(s + 1000000, n, 100)],
          tids: [
            for (var i = 0; i < 300; i++) 1000 + i,
            for (var i = 0; i < n; i++) 1,
          ],
        );
        detector.processTimelineData(batch);
        check();
        expect(detector.threadMarkCount, lessThanOrEqualTo(256));

        detector.processTimelineData(batch);
        check();
        expect(detector.lastWindowStats!.callCount, 0);
      });
    });
  });
}
