import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/models/recurrence_trend.dart';

void main() {
  // ---------------------------------------------------------------------------
  // Ring buffer capacity
  // ---------------------------------------------------------------------------

  group('ring buffer capacity', () {
    test('evicts oldest entry when capacity exceeded', () {
      final trend = RecurrenceTrend(capacity: 3);
      trend.recordPresent(1, severityIndex: 2);
      trend.recordPresent(2, severityIndex: 2);
      trend.recordPresent(3, severityIndex: 2);
      expect(trend.length, 3);

      trend.recordPresent(4, severityIndex: 2);
      expect(trend.length, 3);
      expect(trend.entries.first.scanCycle, 2); // oldest (1) evicted
      expect(trend.entries.last.scanCycle, 4);
    });

    test('default capacity is 60', () {
      final trend = RecurrenceTrend();
      expect(trend.capacity, 60);
    });

    test('empty trend has zero counts', () {
      final trend = RecurrenceTrend();
      expect(trend.length, 0);
      expect(trend.presentCount, 0);
      expect(trend.absentCount, 0);
    });
  });

  // ---------------------------------------------------------------------------
  // Present/absent tracking
  // ---------------------------------------------------------------------------

  group('present/absent tracking', () {
    test('counts present and absent entries', () {
      final trend = RecurrenceTrend();
      trend.recordPresent(1, severityIndex: 2);
      trend.recordPresent(2, severityIndex: 2);
      trend.recordAbsent(3);
      trend.recordPresent(4, severityIndex: 2);
      trend.recordAbsent(5);

      expect(trend.presentCount, 3);
      expect(trend.absentCount, 2);
      expect(trend.length, 5);
    });

    test('absent entries have null severityIndex', () {
      final trend = RecurrenceTrend();
      trend.recordAbsent(1);
      expect(trend.entries.first.present, false);
      expect(trend.entries.first.severityIndex, isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // Trend computation
  // ---------------------------------------------------------------------------

  group('trend computation', () {
    test('stable: consistent severity over window', () {
      final trend = RecurrenceTrend();
      for (var i = 1; i <= 10; i++) {
        trend.recordPresent(i, severityIndex: 2);
      }
      expect(trend.trend, TrendDirection.stable);
    });

    test('worsening: severity increasing over window', () {
      final trend = RecurrenceTrend();
      // First half: warning (2)
      for (var i = 1; i <= 5; i++) {
        trend.recordPresent(i, severityIndex: 2);
      }
      // Second half: critical (3)
      for (var i = 6; i <= 10; i++) {
        trend.recordPresent(i, severityIndex: 3);
      }
      expect(trend.trend, TrendDirection.worsening);
    });

    test('improving: severity decreasing over window', () {
      final trend = RecurrenceTrend();
      // First half: critical (3)
      for (var i = 1; i <= 5; i++) {
        trend.recordPresent(i, severityIndex: 3);
      }
      // Second half: warning (2)
      for (var i = 6; i <= 10; i++) {
        trend.recordPresent(i, severityIndex: 1);
      }
      expect(trend.trend, TrendDirection.improving);
    });

    test('intermittent: frequent present/absent toggling', () {
      final trend = RecurrenceTrend();
      // Toggle present/absent rapidly (3+ transitions)
      trend.recordPresent(1, severityIndex: 2);
      trend.recordAbsent(2);
      trend.recordPresent(3, severityIndex: 2);
      trend.recordAbsent(4);
      trend.recordPresent(5, severityIndex: 2);
      expect(trend.trend, TrendDirection.intermittent);
    });

    test('fewer than 3 entries returns stable', () {
      final trend = RecurrenceTrend();
      trend.recordPresent(1, severityIndex: 2);
      trend.recordPresent(2, severityIndex: 3);
      expect(trend.trend, TrendDirection.stable);
    });

    test('uses last N entries when window specified', () {
      final trend = RecurrenceTrend();
      // Old data: low severity
      for (var i = 1; i <= 20; i++) {
        trend.recordPresent(i, severityIndex: 1);
      }
      // Recent data: high severity
      for (var i = 21; i <= 25; i++) {
        trend.recordPresent(i, severityIndex: 3);
      }
      // Window of 10 should see the transition
      expect(trend.computeTrend(window: 10), TrendDirection.worsening);
    });
  });

  // ---------------------------------------------------------------------------
  // Stale eviction
  // ---------------------------------------------------------------------------

  group('stale eviction', () {
    test('not stale when recently present', () {
      final trend = RecurrenceTrend();
      trend.recordPresent(100, severityIndex: 2);
      expect(trend.isStale(150), false); // 50 cycles ago < 120 threshold
    });

    test('stale when absent for 120+ cycles', () {
      final trend = RecurrenceTrend();
      trend.recordPresent(100, severityIndex: 2);
      expect(trend.isStale(221), true); // 121 cycles ago > 120 threshold
    });

    test('empty trend is stale', () {
      final trend = RecurrenceTrend();
      expect(trend.isStale(0), true);
    });

    test('absent entries do not count as presence for staleness', () {
      final trend = RecurrenceTrend();
      trend.recordPresent(10, severityIndex: 2);
      trend.recordAbsent(50);
      trend.recordAbsent(100);
      // Last present was at cycle 10, not 100
      expect(trend.isStale(131), true); // 121 cycles since last present
    });
  });

  // ---------------------------------------------------------------------------
  // JSON serialization
  // ---------------------------------------------------------------------------

  group('toJson', () {
    test('summary includes trend and counts', () {
      final trend = RecurrenceTrend();
      trend.recordPresent(1, severityIndex: 2);
      trend.recordPresent(2, severityIndex: 2);
      trend.recordPresent(3, severityIndex: 2);
      trend.recordPresent(4, severityIndex: 2);

      final json = trend.toJson();
      expect(json['trend'], 'stable');
      expect(json['totalOccurrences'], 4);
      expect(json['totalObserved'], 4);
      expect(json['lastSeenCycle'], 4);
      expect(json['severityStats'], isNotNull);
      expect(json['severityStats']['min'], 2);
      expect(json['severityStats']['max'], 2);
    });

    test('empty trend produces null lastSeenCycle', () {
      final trend = RecurrenceTrend();
      final json = trend.toJson();
      expect(json['totalOccurrences'], 0);
      expect(json['lastSeenCycle'], isNull);
      expect(json.containsKey('severityStats'), false);
    });
  });

  // ---------------------------------------------------------------------------
  // RecurrenceEntry serialization
  // ---------------------------------------------------------------------------

  group('RecurrenceEntry', () {
    test('toJson round-trip for present entry', () {
      const entry =
          RecurrenceEntry(scanCycle: 42, present: true, severityIndex: 3);
      final json = entry.toJson();
      final restored = RecurrenceEntry.fromJson(json);
      expect(restored.scanCycle, 42);
      expect(restored.present, true);
      expect(restored.severityIndex, 3);
    });

    test('toJson round-trip for absent entry', () {
      const entry = RecurrenceEntry(scanCycle: 10, present: false);
      final json = entry.toJson();
      final restored = RecurrenceEntry.fromJson(json);
      expect(restored.scanCycle, 10);
      expect(restored.present, false);
      expect(restored.severityIndex, isNull);
    });
  });
}
