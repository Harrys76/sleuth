import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/debug/debug_snapshot.dart';
import 'package:sleuth/src/detectors/rebuild_detector.dart';
import 'package:sleuth/src/detectors/repaint_detector.dart';

import '../helpers/timeline_test_helpers.dart';

/// Debug snapshots arrive with each scan and VM windows about once a
/// second. Each source's issues stay until that source updates again, so
/// the overlay does not show a card for one tick and drop it the next.
void main() {
  late DateTime fakeNow;

  setUp(() => fakeNow = DateTime(2026));

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

    List<String> ids() => [for (final i in detector.issues) i.stableId!];

    test('a per-widget issue survives the VM windows until the next '
        'snapshot', () {
      detector.updateDebugSnapshot(
        const DebugSnapshot(
          rebuildCounts: {},
          totalPaintCount: 90,
          paintCounts: {'_Chart': 90},
          elapsed: Duration(seconds: 1),
        ),
      );
      detector.evaluateNow();
      final perWidget = detector.issues.single;
      expect(perWidget.stableId, 'repaint_debug__Chart');

      vmWindow(2);
      vmWindow(15);
      expect(detector.issues.single, same(perWidget));

      detector.updateDebugSnapshot(
        const DebugSnapshot(
          rebuildCounts: {},
          totalPaintCount: 0,
          elapsed: Duration(seconds: 1),
        ),
      );
      detector.evaluateNow();
      expect(ids(), isEmpty);
    });

    test('the VM share survives a snapshot without per-widget issues and '
        'is not swapped for the debug aggregate', () {
      vmWindow(15);
      final vmIssue = detector.issues.single;
      expect(vmIssue.stableId, 'excessive_repaint');

      // 200 paints/sec spread over sub-threshold widgets: the debug
      // aggregate's input.
      detector.updateDebugSnapshot(
        const DebugSnapshot(
          rebuildCounts: {},
          totalPaintCount: 200,
          paintCounts: {'Text': 20},
          elapsed: Duration(seconds: 1),
        ),
      );
      detector.evaluateNow();
      expect(detector.issues.single, same(vmIssue));
    });

    test('without a VM connection the debug aggregate reports', () {
      detector.vmConnected = false;
      detector.updateDebugSnapshot(
        const DebugSnapshot(
          rebuildCounts: {},
          totalPaintCount: 200,
          paintCounts: {'Text': 20},
          elapsed: Duration(seconds: 1),
        ),
      );
      detector.evaluateNow();
      expect(ids(), ['excessive_repaint_debug']);
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

    test('a per-type issue survives the VM windows until the next '
        'snapshot', () {
      detector.updateDebugSnapshot(
        const DebugSnapshot(
          rebuildCounts: {'_Tile': 40},
          totalPaintCount: 0,
          elapsed: Duration(seconds: 1),
        ),
      );
      detector.evaluateNow();
      final perType = detector.issues.single;
      expect(perType.stableId, 'rebuild_debug__Tile');

      vmWindow(2);
      vmWindow(15);
      expect(detector.issues.single, same(perType));

      detector.updateDebugSnapshot(
        const DebugSnapshot(
          rebuildCounts: {},
          totalPaintCount: 0,
          elapsed: Duration(seconds: 1),
        ),
      );
      detector.evaluateNow();
      // The last window (15 %) was not evaluated while the per-type issue
      // won, so nothing shows until the next window.
      expect(detector.issues, isEmpty);
      vmWindow(15);
      expect(detector.issues.single.stableId, 'rebuild_activity');
    });
  });
}
