import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/models/frame_stats.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/models/route_session.dart';

FrameStats _frame({
  required int number,
  int uiUs = 4000,
  int rasterUs = 3000,
}) {
  return FrameStats(
    frameNumber: number,
    uiDuration: Duration(microseconds: uiUs),
    rasterDuration: Duration(microseconds: rasterUs),
    timestamp: DateTime.now(),
  );
}

PerformanceIssue _issue({
  required String stableId,
  IssueSeverity severity = IssueSeverity.warning,
}) {
  return PerformanceIssue(
    severity: severity,
    category: IssueCategory.build,
    confidence: IssueConfidence.confirmed,
    title: 'Test issue $stableId',
    detail: 'detail',
    fixHint: 'fix',
    stableId: stableId,
  );
}

void main() {
  group('RouteSession', () {
    test('newly created session is active', () {
      final session =
          RouteSession(routeName: '/home', startedAt: DateTime.now());
      expect(session.isActive, isTrue);
      expect(session.endedAt, isNull);
      expect(session.scanCycleCount, 0);
      expect(session.issueSnapshots, isEmpty);
      expect(session.frameStats.isEmpty, isTrue);
    });

    test('closing session sets endedAt and isActive becomes false', () {
      final session =
          RouteSession(routeName: '/home', startedAt: DateTime.now());
      session.endedAt = DateTime.now();
      expect(session.isActive, isFalse);
      expect(session.endedAt, isNotNull);
    });

    test('duration computes correctly for active session', () {
      final start = DateTime.now().subtract(const Duration(seconds: 5));
      final session = RouteSession(routeName: '/home', startedAt: start);
      expect(session.duration.inSeconds, greaterThanOrEqualTo(5));
    });

    test('duration computes correctly for closed session', () {
      final start = DateTime(2026, 1, 1, 10, 0, 0);
      final end = DateTime(2026, 1, 1, 10, 2, 14);
      final session = RouteSession(routeName: '/home', startedAt: start)
        ..endedAt = end;
      expect(session.duration, const Duration(minutes: 2, seconds: 14));
    });

    group('healthScore', () {
      test('returns 100 with no frames and no issues', () {
        final session =
            RouteSession(routeName: '/home', startedAt: DateTime.now());
        expect(session.healthScore, 100);
      });

      test('perfect FPS with no issues scores 100', () {
        final session =
            RouteSession(routeName: '/home', startedAt: DateTime.now());
        // Add 60 frames at ~62.5 FPS (16ms each)
        for (var i = 0; i < 60; i++) {
          session.frameStats.add(
            _frame(number: i + 1, uiUs: 16000, rasterUs: 10000),
          );
        }
        expect(session.healthScore, 100);
      });

      test('all jank frames reduce score significantly', () {
        final session =
            RouteSession(routeName: '/home', startedAt: DateTime.now());
        // Add 10 frames at 20ms each (jank at 60 FPS)
        for (var i = 0; i < 10; i++) {
          session.frameStats.add(
            _frame(number: i + 1, uiUs: 20000, rasterUs: 15000),
          );
        }
        // FPS is ~50 (below 60), all frames are jank
        expect(session.healthScore, lessThan(70));
      });

      test('critical issues reduce score by 10 each', () {
        final session =
            RouteSession(routeName: '/home', startedAt: DateTime.now());
        // Good FPS
        for (var i = 0; i < 10; i++) {
          session.frameStats.add(
            _frame(number: i + 1, uiUs: 10000, rasterUs: 5000),
          );
        }
        // Add 2 critical issues = 20 point penalty
        session.issueSnapshots['a'] =
            _issue(stableId: 'a', severity: IssueSeverity.critical);
        session.issueSnapshots['b'] =
            _issue(stableId: 'b', severity: IssueSeverity.critical);

        // Perfect FPS (40) + no jank (30) + issues (30 - 20 = 10) = 80
        expect(session.healthScore, closeTo(80, 2));
      });

      test('warning issues reduce score by 3 each', () {
        final session =
            RouteSession(routeName: '/home', startedAt: DateTime.now());
        for (var i = 0; i < 10; i++) {
          session.frameStats.add(
            _frame(number: i + 1, uiUs: 10000, rasterUs: 5000),
          );
        }
        // Add 5 warning issues = 15 point penalty
        for (var i = 0; i < 5; i++) {
          session.issueSnapshots['w$i'] = _issue(stableId: 'w$i');
        }

        // Perfect FPS (40) + no jank (30) + issues (30 - 15 = 15) = 85
        expect(session.healthScore, closeTo(85, 2));
      });

      test('issue penalty capped at 30', () {
        final session =
            RouteSession(routeName: '/home', startedAt: DateTime.now());
        for (var i = 0; i < 10; i++) {
          session.frameStats.add(
            _frame(number: i + 1, uiUs: 10000, rasterUs: 5000),
          );
        }
        // 10 critical issues = 100 penalty, but capped at 30
        for (var i = 0; i < 10; i++) {
          session.issueSnapshots['c$i'] =
              _issue(stableId: 'c$i', severity: IssueSeverity.critical);
        }

        // Perfect FPS (40) + no jank (30) + issues (30 - 30 = 0) = 70
        expect(session.healthScore, closeTo(70, 2));
      });

      test('score clamped to 0 minimum', () {
        final session =
            RouteSession(routeName: '/home', startedAt: DateTime.now());
        // Very slow frames: 100ms each ≈ 10 FPS
        for (var i = 0; i < 10; i++) {
          session.frameStats.add(
            _frame(number: i + 1, uiUs: 100000, rasterUs: 80000),
          );
        }
        // 10 critical issues
        for (var i = 0; i < 10; i++) {
          session.issueSnapshots['c$i'] =
              _issue(stableId: 'c$i', severity: IssueSeverity.critical);
        }
        expect(session.healthScore, greaterThanOrEqualTo(0));
      });

      test('ok-severity issues do not penalize score', () {
        final session =
            RouteSession(routeName: '/home', startedAt: DateTime.now());
        for (var i = 0; i < 10; i++) {
          session.frameStats.add(
            _frame(number: i + 1, uiUs: 10000, rasterUs: 5000),
          );
        }
        session.issueSnapshots['ok1'] =
            _issue(stableId: 'ok1', severity: IssueSeverity.ok);
        // Perfect FPS (40) + no jank (30) + no penalty (30) = 100
        expect(session.healthScore, 100);
      });

      test('fpsTarget 120 penalises 60 FPS correctly', () {
        final session = RouteSession(
          routeName: '/home',
          startedAt: DateTime.now(),
          fpsTarget: 120,
        );
        // 60 FPS frames (16ms each) — only 50% of 120 target.
        for (var i = 0; i < 10; i++) {
          session.frameStats.add(
            _frame(number: i + 1, uiUs: 16000, rasterUs: 10000),
          );
        }
        // FPS component ≈ 60/120 * 40 ≈ 20. No issues, no jank at 60Hz
        // threshold → score ≈ 80. Key: well below 100 (proves target
        // affects the formula, unlike hardcoded /60 which would give 100).
        expect(session.healthScore, lessThan(85));

        // Confirm same frames on a 60 FPS target give a perfect score.
        final session60 =
            RouteSession(routeName: '/x', startedAt: DateTime.now());
        for (var i = 0; i < 10; i++) {
          session60.frameStats.add(
            _frame(number: i + 1, uiUs: 16000, rasterUs: 10000),
          );
        }
        expect(session60.healthScore, 100);
      });

      test('fpsTarget defaults to 60', () {
        final session =
            RouteSession(routeName: '/home', startedAt: DateTime.now());
        expect(session.fpsTarget, 60);
      });
    });

    group('toJson', () {
      test('serialises active session', () {
        final start = DateTime(2026, 4, 11, 10, 0, 0);
        final session = RouteSession(routeName: '/settings', startedAt: start);
        session.scanCycleCount = 5;
        session.issueSnapshots['rebuild_debug_Foo'] = _issue(
          stableId: 'rebuild_debug_Foo',
          severity: IssueSeverity.warning,
        );
        session.issueSnapshots['opacity_zero'] = _issue(
          stableId: 'opacity_zero',
          severity: IssueSeverity.critical,
        );

        final json = session.toJson();
        expect(json['routeName'], '/settings');
        expect(json['startedAt'], start.toIso8601String());
        expect(json.containsKey('endedAt'), isFalse);
        expect(json['healthScore'], isA<int>());
        expect(json['scanCycles'], 5);
        expect(json['issueCount'], 2);
        expect(json['criticalCount'], 1);
        expect(json['warningCount'], 1);
        expect((json['issues'] as List).length, 2);

        final frameStats = json['frameStats'] as Map<String, dynamic>;
        expect(frameStats['totalFrames'], 0);
        expect(frameStats['jankFrames'], 0);
        expect(frameStats['averageFps'], 0.0);
      });

      test('serialises closed session with frames', () {
        final start = DateTime(2026, 4, 11, 10, 0, 0);
        final end = DateTime(2026, 4, 11, 10, 2, 0);
        final session = RouteSession(routeName: '/home', startedAt: start)
          ..endedAt = end;

        for (var i = 0; i < 5; i++) {
          session.frameStats.add(
            _frame(number: i + 1, uiUs: 16000, rasterUs: 10000),
          );
        }

        final json = session.toJson();
        expect(json['endedAt'], end.toIso8601String());
        final frameStats = json['frameStats'] as Map<String, dynamic>;
        expect(frameStats['totalFrames'], 5);
        expect(frameStats['averageFps'], greaterThan(0));
        expect(frameStats.containsKey('p50'), isTrue);
      });

      test('averageFps and percentiles clamped to fpsTarget in toJson', () {
        // Very fast frames (~666 FPS raw) — simulates ProMotion 120Hz idle
        // where FrameStatsBuffer.averageFps caps at 120, well above fpsTarget.
        final session = RouteSession(
          routeName: '/fast',
          startedAt: DateTime(2026, 4, 11),
          fpsTarget: 60,
        );
        for (var i = 0; i < 10; i++) {
          session.frameStats.add(
            _frame(number: i + 1, uiUs: 1000, rasterUs: 500),
          );
        }

        final json = session.toJson();
        final fs = json['frameStats'] as Map<String, dynamic>;

        // averageFps must be clamped to fpsTarget (60).
        expect(fs['averageFps'] as double, lessThanOrEqualTo(60.0));

        // Percentiles must also be clamped.
        expect(fs['p50'] as double, lessThanOrEqualTo(60.0));
        expect(fs['p95'] as double, lessThanOrEqualTo(60.0));
        expect(fs['p99'] as double, lessThanOrEqualTo(60.0));
      });

      test('no percentiles with fewer than 2 frames', () {
        final session =
            RouteSession(routeName: '/x', startedAt: DateTime.now());
        session.frameStats.add(_frame(number: 1));

        final json = session.toJson();
        final frameStats = json['frameStats'] as Map<String, dynamic>;
        expect(frameStats.containsKey('p50'), isFalse);
      });
    });

    // -----------------------------------------------------------------------
    // v0.14.1 per-tab session fields: scaffoldHashKey, tabVisitIndex,
    // hotReloadGeneration. Covers default construction, non-default values,
    // and toJson inclusion/omission rules.
    // -----------------------------------------------------------------------

    group('per-tab fields (v0.14.1)', () {
      test('defaults: scaffoldHashKey null, tabVisitIndex 1, genGen 0', () {
        final session =
            RouteSession(routeName: '/home', startedAt: DateTime.now());
        expect(session.scaffoldHashKey, isNull);
        expect(session.tabVisitIndex, 1);
        expect(session.hotReloadGeneration, 0);
      });

      test('constructor accepts non-default values', () {
        final session = RouteSession(
          routeName: '/home',
          startedAt: DateTime.now(),
          scaffoldHashKey: 0xABCDEF,
          tabVisitIndex: 3,
          hotReloadGeneration: 5,
        );
        expect(session.scaffoldHashKey, 0xABCDEF);
        expect(session.tabVisitIndex, 3);
        expect(session.hotReloadGeneration, 5);
      });

      test('toJson omits scaffoldHashKey when null', () {
        final session = RouteSession(
          routeName: '/home',
          startedAt: DateTime(2026, 4, 11),
        );
        final json = session.toJson();
        expect(json.containsKey('scaffoldHashKey'), isFalse);
      });

      test('toJson includes scaffoldHashKey when non-null', () {
        final session = RouteSession(
          routeName: '/home',
          startedAt: DateTime(2026, 4, 11),
          scaffoldHashKey: 12345,
        );
        final json = session.toJson();
        expect(json['scaffoldHashKey'], 12345);
      });

      test('toJson always includes tabVisitIndex', () {
        final first = RouteSession(
          routeName: '/home',
          startedAt: DateTime(2026, 4, 11),
        );
        final second = RouteSession(
          routeName: '/home',
          startedAt: DateTime(2026, 4, 11),
          tabVisitIndex: 2,
        );
        expect(first.toJson()['tabVisitIndex'], 1);
        expect(second.toJson()['tabVisitIndex'], 2);
      });

      test('toJson omits hotReloadGeneration when 0', () {
        final session = RouteSession(
          routeName: '/home',
          startedAt: DateTime(2026, 4, 11),
        );
        final json = session.toJson();
        expect(json.containsKey('hotReloadGeneration'), isFalse);
      });

      test('toJson includes hotReloadGeneration when non-zero', () {
        final session = RouteSession(
          routeName: '/home',
          startedAt: DateTime(2026, 4, 11),
          hotReloadGeneration: 7,
        );
        final json = session.toJson();
        expect(json['hotReloadGeneration'], 7);
      });

      test('toJson with all per-tab fields set emits full shape', () {
        final session = RouteSession(
          routeName: '/settings',
          startedAt: DateTime(2026, 4, 11, 10, 0, 0),
          scaffoldHashKey: 0x1234ABCD,
          tabVisitIndex: 4,
          hotReloadGeneration: 2,
        );
        final json = session.toJson();
        expect(json['routeName'], '/settings');
        expect(json['scaffoldHashKey'], 0x1234ABCD);
        expect(json['tabVisitIndex'], 4);
        expect(json['hotReloadGeneration'], 2);
      });
    });
  });
}
