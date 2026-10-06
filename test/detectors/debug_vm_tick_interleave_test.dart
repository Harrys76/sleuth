import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/debug/debug_snapshot.dart';
import 'package:sleuth/src/detectors/rebuild_detector.dart';
import 'package:sleuth/src/detectors/repaint_detector.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/utils/rate_hysteresis.dart';

import '../helpers/timeline_test_helpers.dart';

/// Debug snapshots arrive with each scan and VM windows about once a
/// second. Cards must not appear and vanish while the measured behaviour
/// is steady: each source keeps its issues until it updates, per-type
/// rates are held across scans, and the VM share's card is held through
/// one quiet window.
void main() {
  late DateTime fakeNow;

  setUp(() => fakeNow = DateTime(2026));

  /// A window in which each type in [counts] painted that often and was
  /// the likely origin of every paint [owned] does not cover.
  DebugSnapshot paints(
    Map<String, int> counts, {
    int? total,
    Map<String, int> owned = const {},
    int? totalOwned,
    int ms = 1000,
  }) => DebugSnapshot(
    rebuildCounts: const {},
    totalPaintCount: total ?? counts.values.fold(0, (a, b) => a + b),
    paintCounts: counts,
    animationOwnedPaintCounts: owned,
    totalAnimationOwnedPaintCount:
        totalOwned ?? owned.values.fold(0, (a, b) => a + b),
    paintOrigins: {
      for (final MapEntry(key: type, value: count) in counts.entries)
        if (count - (owned[type] ?? 0) > 0)
          type: PaintOriginStats(
            maxCount: count - (owned[type] ?? 0),
            animationOwnedCount: owned[type] ?? 0,
          ),
    },
    elapsed: Duration(milliseconds: ms),
  );

  DebugSnapshot rebuilds(
    Map<String, int> counts, {
    Map<String, int> forced = const {},
    int ms = 1000,
  }) => DebugSnapshot(
    rebuildCounts: counts,
    totalPaintCount: 0,
    forcedRebuildsByRoot: forced,
    elapsed: Duration(milliseconds: ms),
  );

  group('RepaintDetector', () {
    late RepaintDetector detector;

    setUp(() {
      detector = RepaintDetector(clock: () => fakeNow)..vmConnected = true;
      // Consume the reconnect's zero window.
      detector.evaluateNow();
    });
    tearDown(() => detector.dispose());

    void vmWindow(int percent) {
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(paintLoadData(paintTimeUs: percent * 20000));
      detector.evaluateNow();
    }

    void scan(DebugSnapshot snapshot) {
      detector.updateDebugSnapshot(snapshot);
      detector.evaluateNow();
    }

    List<String> ids() => [for (final i in detector.issues) i.stableId!];

    test('a per-widget issue survives the VM windows, and the latest VM '
        'window shows as soon as it clears', () {
      scan(paints({'_Chart': 90}));
      final perWidget = detector.issues.single;
      expect(perWidget.stableId, 'repaint_debug__Chart');

      vmWindow(2);
      vmWindow(15);
      expect(detector.issues.single, same(perWidget));

      scan(paints({}));
      expect(ids(), ['excessive_repaint']);
    });

    test('the VM share survives a snapshot without per-widget issues and '
        'is not swapped for the debug aggregate', () {
      vmWindow(15);
      final vmIssue = detector.issues.single;
      expect(vmIssue.stableId, 'excessive_repaint');

      // 200 paints/sec spread over sub-threshold widgets: the debug
      // aggregate's input.
      scan(paints({'Text': 20}, total: 200));
      expect(detector.issues.single, same(vmIssue));
    });

    test('without a VM connection the debug aggregate reports', () {
      detector.vmConnected = false;
      scan(paints({'Text': 20}, total: 200));
      expect(ids(), ['excessive_repaint_debug']);
    });

    test('a widget at the threshold stays shown across scans', () {
      // A true 30/s read over 1 s windows whose edges move with the
      // frame phase: 31, 29, 30, 29, 31, 29.
      final seen = <bool>[];
      for (final count in [31, 29, 30, 29, 31, 29]) {
        scan(paints({'Column': count}));
        seen.add(ids().contains('repaint_debug_Column'));
      }
      expect(seen, everyElement(isTrue));
    });

    test('a held widget clears at once on a window without it, and after a '
        'sustained drop', () {
      scan(paints({'Column': 40}));
      scan(paints({}));
      expect(ids(), isEmpty);

      scan(paints({'Column': 40}));
      scan(paints({'Column': 10})); // two-window rate 25: held
      expect(ids(), ['repaint_debug_Column']);
      scan(paints({'Column': 10})); // two-window rate 10: cleared
      expect(ids(), isEmpty);
    });

    test('severity holds around the critical boundary', () {
      scan(paints({'Column': 61}));
      expect(detector.issues.single.severity, IssueSeverity.critical);
      scan(paints({'Column': 59}));
      expect(detector.issues.single.severity, IssueSeverity.critical);
      scan(paints({'Column': 30}));
      scan(paints({'Column': 30}));
      expect(detector.issues.single.severity, IssueSeverity.warning);
    });

    test('Gate B needs every paint in the window owned, framework paints '
        'included', () {
      vmWindow(15);
      // The user-widget entry is fully owned, but framework paints (in
      // the total only) are not.
      scan(paints({'CustomPaint': 60}, total: 200, owned: {'CustomPaint': 60}));
      expect(ids(), ['excessive_repaint']);

      scan(
        paints(
          {'CustomPaint': 60},
          total: 200,
          totalOwned: 200,
          owned: {'CustomPaint': 60},
        ),
      );
      expect(ids(), isEmpty);
    });

    test('a route epoch drops held per-widget and VM issues', () {
      vmWindow(15);
      scan(paints({'Column': 40}));
      detector.markRouteEpoch();
      expect(ids(), isEmpty);
      // The next window starts after the epoch.
      vmWindow(2);
      expect(ids(), isEmpty);
    });

    test('an aborted scan drops held per-widget issues and keeps the VM '
        'share', () {
      vmWindow(15);
      scan(paints({'Column': 40}));
      expect(ids(), ['repaint_debug_Column']);
      detector.discardDebugEvidence();
      expect(ids(), ['excessive_repaint']);
    });

    test('a VM disconnect drops the VM card without any snapshot', () {
      vmWindow(15);
      expect(ids(), ['excessive_repaint']);
      detector.vmConnected = false;
      expect(ids(), isEmpty);
    });

    test('resetCaptureState drops every held issue', () {
      vmWindow(15);
      scan(paints({'Column': 40}));
      detector.resetCaptureState();
      expect(ids(), isEmpty);
      vmWindow(2);
      expect(ids(), isEmpty);
    });
  });

  group('RebuildDetector', () {
    late RebuildDetector detector;

    setUp(() {
      detector = RebuildDetector(clock: () => fakeNow)..vmConnected = true;
      detector.evaluateNow();
    });
    tearDown(() => detector.dispose());

    void vmWindow(int percent) {
      fakeNow = fakeNow.add(const Duration(seconds: 2));
      detector.processTimelineData(buildLoadData(buildTimeUs: percent * 20000));
      detector.evaluateNow();
    }

    void scan(DebugSnapshot snapshot) {
      detector.updateDebugSnapshot(snapshot);
      detector.evaluateNow();
    }

    List<String> ids() => [for (final i in detector.issues) i.stableId!];

    test('a per-type issue survives the VM windows, and the latest VM '
        'window shows as soon as it clears', () {
      scan(rebuilds({'_Tile': 40}));
      final perType = detector.issues.single;
      expect(perType.stableId, 'rebuild_debug__Tile');

      vmWindow(2);
      vmWindow(15);
      expect(detector.issues.single, same(perType));

      scan(rebuilds({}));
      expect(ids(), ['rebuild_activity']);
    });

    test('a type rebuilding at the threshold stays shown across scans', () {
      // A 10 Hz ticker read over 1 s windows: 11, 9, 10, 9, 11, 9.
      final seen = <bool>[];
      for (final count in [11, 9, 10, 9, 11, 9]) {
        scan(rebuilds({'_MetricGrid': count}));
        seen.add(ids().contains('rebuild_debug__MetricGrid'));
      }
      expect(seen, everyElement(isTrue));
    });

    test('the detail names the rebuilds its build forced', () {
      scan(rebuilds({'_Page': 20}, forced: {'_Page': 140}));
      expect(
        detector.issues.single.detail,
        contains('also rebuilt 140 widgets below it'),
      );
    });

    test('resetCaptureState drops held issues so a leg starts empty', () {
      vmWindow(15);
      expect(ids(), ['rebuild_activity']);
      scan(rebuilds({'_Tile': 40}));
      detector.resetCaptureState();
      expect(ids(), isEmpty);
      vmWindow(2);
      expect(ids(), isEmpty);
    });

    test('a route epoch drops held issues', () {
      vmWindow(15);
      scan(rebuilds({'_Tile': 40}));
      detector.markRouteEpoch();
      expect(ids(), isEmpty);
    });

    test('the VM card keeps critical near the critical boundary', () {
      vmWindow(35);
      expect(detector.issues.single.severity, IssueSeverity.critical);
      vmWindow(28); // a warning emission within 0.8x of 30 %
      expect(detector.issues.single.severity, IssueSeverity.critical);
      expect(
        detector.issues.single.extraTraceArgs!['observedBuildPercent'],
        '28.0',
      );
      // One window well under the boundary is not enough; two are.
      vmWindow(15);
      expect(detector.issues.single.severity, IssueSeverity.critical);
      vmWindow(15);
      expect(detector.issues.single.severity, IssueSeverity.warning);
    });

    test('every VM window moves the peak, whatever is shown', () {
      scan(rebuilds({'_Tile': 40}));
      vmWindow(25);
      expect(ids(), ['rebuild_debug__Tile']);
      expect(detector.peakObservedBuildPercent, closeTo(25, 1e-9));
    });
  });

  group('RateHysteresis', () {
    test('a type missing from a capped window keeps its state', () {
      final h = RateHysteresis();
      void feed(Map<String, int> counts, {bool capped = false}) => h.update(
        counts: counts,
        elapsedUs: 1000000,
        capped: capped,
        thresholdFor: (_) => 10,
        criticalMultiplier: 3,
      );
      feed({'A': 12});
      feed({'B': 50}, capped: true);
      expect(h.held.keys, containsAll(['A', 'B']));
      feed({'B': 50});
      expect(h.held.keys, ['B']);
    });

    test('a window with no length changes nothing', () {
      final h = RateHysteresis()
        ..update(
          counts: {'A': 12},
          elapsedUs: 1000000,
          capped: false,
          thresholdFor: (_) => 10,
          criticalMultiplier: 3,
        )
        ..update(
          counts: const {},
          elapsedUs: 0,
          capped: false,
          thresholdFor: (_) => 10,
          criticalMultiplier: 3,
        );
      expect(h.held.keys, ['A']);
    });
  });
}
