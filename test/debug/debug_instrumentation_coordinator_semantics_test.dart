import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/debug/debug_instrumentation_coordinator.dart';
import 'package:sleuth/src/debug/debug_snapshot.dart';
import 'package:sleuth/src/detectors/repaint_detector.dart';

void main() {
  setUp(() {
    debugOnProfilePaint = null;
    debugOnRebuildDirtyWidget = null;
  });
  tearDown(() {
    debugOnProfilePaint = null;
    debugOnRebuildDirtyWidget = null;
  });

  /// A tapable, labelled box whose painter repaints every frame.
  Widget churningTree() => const Directionality(
    textDirection: TextDirection.ltr,
    child: RepaintBoundary(child: Center(child: _Churning())),
  );

  /// Pumps [frames] frames of [churningTree] with a coordinator installed
  /// and returns its snapshot over a 1 s window.
  Future<DebugSnapshot> paintFrames(WidgetTester tester, int frames) async {
    var now = DateTime(2026);
    await tester.pumpWidget(churningTree());
    // `_GestureSemantics` is a framework widget; count it per widget.
    final coord = DebugInstrumentationCoordinator(
      installRebuild: false,
      userWidgetsOnly: false,
      clock: () => now,
    );
    coord.install();
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    now = now.add(const Duration(seconds: 1));
    final snap = coord.snapshot();
    coord.dispose();
    return snap;
  }

  group('semantics-only paints', () {
    testWidgets('are left out while semantics are on', (tester) async {
      final handle = tester.ensureSemantics();
      final snap = await paintFrames(tester, 40);
      handle.dispose();

      expect(snap.paintCounts['CustomPaint'], greaterThanOrEqualTo(40));
      for (final name in DebugInstrumentationCoordinator.semanticsOnlyWidgets) {
        expect(snap.paintCounts.containsKey(name), isFalse, reason: name);
      }
      final perType = snap.paintCounts.values.fold<int>(0, (a, b) => a + b);
      expect(snap.totalPaintCount, perType);
    });

    testWidgets('count like any widget while semantics are off', (
      tester,
    ) async {
      expect(tester.binding.semanticsEnabled, isFalse);
      final snap = await paintFrames(tester, 40);

      expect(snap.paintCounts['Semantics'], greaterThanOrEqualTo(40));
      expect(snap.paintCounts['_GestureSemantics'], greaterThanOrEqualTo(40));
      expect(snap.paintCounts['CustomPaint'], greaterThanOrEqualTo(40));
    }, semanticsEnabled: false);

    testWidgets('no repaint_debug_Semantics under a screen reader', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final snap = await paintFrames(tester, 40);
      handle.dispose();

      final detector = RepaintDetector(paintFrequencyThreshold: 30)
        ..vmConnected = false
        ..updateDebugSnapshot(snap)
        ..evaluateNow();
      final ids = [for (final i in detector.issues) i.stableId];
      expect(ids, isNot(contains('repaint_debug_Semantics')));
      expect(ids, isNot(contains('repaint_debug__GestureSemantics')));
      expect(ids, contains('repaint_debug_CustomPaint'));
      detector.dispose();
    });

    testWidgets('a hand-called paint of a Semantics render object is '
        'skipped only with semantics on', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Semantics(
            label: 'box',
            child: const SizedBox(width: 10, height: 10),
          ),
        ),
      );
      final ro = tester.renderObject(
        find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.label == 'box',
        ),
      );
      final coord = DebugInstrumentationCoordinator(
        installRebuild: false,
        userWidgetsOnly: false,
      );
      coord.install();
      final onPaint = debugOnProfilePaint!;

      onPaint(ro);
      final off = coord.snapshot();

      final handle = tester.ensureSemantics();
      onPaint(ro);
      final on = coord.snapshot();
      handle.dispose();
      coord.dispose();

      expect(off.paintCounts, {'Semantics': 1});
      expect(off.totalPaintCount, 1);
      expect(on.paintCounts, isEmpty);
      expect(on.totalPaintCount, 0);
    }, semanticsEnabled: false);
  });
}

class _Churning extends StatefulWidget {
  const _Churning();

  @override
  State<_Churning> createState() => _ChurningState();
}

class _ChurningState extends State<_Churning>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'churning',
      child: GestureDetector(
        onTap: () {},
        child: CustomPaint(
          size: const Size(20, 20),
          painter: _TickPainter(_controller),
        ),
      ),
    );
  }
}

class _TickPainter extends CustomPainter {
  _TickPainter(this.animation) : super(repaint: animation);

  final Animation<double> animation;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & Size(size.width * animation.value, size.height),
      Paint(),
    );
  }

  @override
  bool shouldRepaint(_TickPainter oldDelegate) => false;
}
