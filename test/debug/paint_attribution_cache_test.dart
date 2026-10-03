import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/debug/debug_instrumentation_coordinator.dart';
import 'package:sleuth/src/debug/debug_snapshot.dart';

void main() {
  setUp(() {
    debugOnProfilePaint = null;
    debugOnRebuildDirtyWidget = null;
  });

  group('per-element paint attribution cache', () {
    testWidgets('a second paint of the same element reuses the attribution', (
      tester,
    ) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Center(child: _Painted(key: ValueKey('p'))),
        ),
      );
      final coord = DebugInstrumentationCoordinator(installRebuild: false);
      coord.install();
      final ro = tester.renderObject(find.byType(CustomPaint));
      final onPaint = debugOnProfilePaint!;

      onPaint(ro);
      final computes = coord.paintAttributionComputeCount;
      expect(computes, greaterThan(0));
      onPaint(ro);
      onPaint(ro);
      expect(coord.paintAttributionComputeCount, computes);

      coord.invalidatePaintAttribution();
      onPaint(ro);
      expect(coord.paintAttributionComputeCount, computes + 1);

      final snap = coord.snapshot();
      coord.dispose();
      expect(snap.paintCounts.values.fold<int>(0, (a, b) => a + b), 4);
    });

    testWidgets('reparenting the element recomputes its chain', (tester) async {
      // The key sits on the painting widget itself and both holders nest
      // it at the same depth, so only the parent identity changes.
      final key = GlobalKey();
      final painted = CustomPaint(
        key: key,
        size: const Size(10, 10),
        painter: _NoopPainter(),
      );
      Widget tree({required bool underA}) => Directionality(
        textDirection: TextDirection.ltr,
        child: Column(
          children: [
            HolderA(child: underA ? painted : null),
            HolderB(child: underA ? null : painted),
          ],
        ),
      );
      await tester.pumpWidget(tree(underA: true));
      final coord = DebugInstrumentationCoordinator(installRebuild: false);
      coord.install();
      final onPaint = debugOnProfilePaint!;

      final element = tester.element(find.byType(CustomPaint));
      final ro = tester.renderObject(find.byType(CustomPaint));
      onPaint(ro);
      final before = coord.snapshot().ancestorChains['CustomPaint'];
      final depth = element.depth;
      final computes = coord.paintAttributionComputeCount;
      onPaint(ro);
      final hitsOnly = coord.paintAttributionComputeCount == computes;

      // Move the same CustomPaint element under HolderB without a frame,
      // then paint it by hand: the stale entry must not be served.
      final holderB = tester.element(find.byType(HolderB));
      await tester.pumpWidget(tree(underA: false), phase: EnginePhase.build);
      expect(tester.element(find.byType(CustomPaint)), same(element));
      expect(element.depth, depth);
      expect(holderB.mounted, isTrue);
      final beforeReparentPaint = coord.paintAttributionComputeCount;
      onPaint(ro);
      final recomputed =
          coord.paintAttributionComputeCount - beforeReparentPaint;
      coord.snapshot();
      onPaint(ro);
      final after = coord.snapshot().ancestorChains['CustomPaint'];
      coord.dispose();
      await tester.pump();

      expect(hitsOnly, isTrue);
      expect(before, contains('HolderA'));
      expect(recomputed, 1);
      expect(after, contains('HolderB'));
      expect(after, isNot(contains('HolderA')));
    });

    test('unmounted elements are never cached', () {
      final coord = DebugInstrumentationCoordinator(installRebuild: false);
      coord.install();
      addTearDown(coord.dispose);
      final element = StatelessElement(const HolderA());
      final ro = RenderConstrainedBox(
        additionalConstraints: const BoxConstraints(),
      )..debugCreator = DebugCreator(element);
      debugOnProfilePaint!(ro);
      debugOnProfilePaint!(ro);
      expect(coord.paintAttributionComputeCount, 2);
    });
  });

  group('cached and uncached attribution agree on real animation owners', () {
    final fixtures = <String, Widget>{
      'CircularProgressIndicator without RepaintBoundary': const Center(
        child: CircularProgressIndicator(),
      ),
      'RefreshProgressIndicator': const Center(
        child: RepaintBoundary(child: RefreshProgressIndicator()),
      ),
      'AnimatedBuilder painter beside a static painter': const _MixedPainters(),
      'LinearProgressIndicator': const Center(
        child: SizedBox(
          width: 200,
          child: RepaintBoundary(child: LinearProgressIndicator()),
        ),
      ),
    };

    for (final entry in fixtures.entries) {
      testWidgets(entry.key, (tester) async {
        final cached = await _capture(tester, entry.value, uncached: false);
        final uncached = await _capture(tester, entry.value, uncached: true);
        expect(cached.paintCounts, isNotEmpty);
        expect(cached.paintCounts, uncached.paintCounts);
        expect(
          cached.animationOwnedPaintCounts,
          uncached.animationOwnedPaintCounts,
        );
        expect(
          cached.totalAnimationOwnedPaintCount,
          uncached.totalAnimationOwnedPaintCount,
        );
        expect(cached.ancestorChains, uncached.ancestorChains);
      });
    }
  });
}

Future<DebugSnapshot> _capture(
  WidgetTester tester,
  Widget root, {
  required bool uncached,
}) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Theme(data: ThemeData.light(), child: root),
    ),
  );
  final coord = DebugInstrumentationCoordinator(installRebuild: false);
  coord.install();
  final installed = debugOnProfilePaint!;
  if (uncached) {
    debugOnProfilePaint = (ro) {
      coord.invalidatePaintAttribution();
      installed(ro);
    };
  }
  try {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    return coord.snapshot();
  } finally {
    debugOnProfilePaint = installed;
    coord.dispose();
  }
}

class _Painted extends StatelessWidget {
  const _Painted({super.key});

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: const Size(10, 10), painter: _NoopPainter());
}

class HolderA extends StatelessWidget {
  const HolderA({super.key, this.child});
  final Widget? child;

  @override
  Widget build(BuildContext context) =>
      SizedBox(height: 20, child: child ?? const SizedBox());
}

class HolderB extends StatelessWidget {
  const HolderB({super.key, this.child});
  final Widget? child;

  @override
  Widget build(BuildContext context) =>
      SizedBox(height: 20, child: child ?? const SizedBox());
}

class _MixedPainters extends StatefulWidget {
  const _MixedPainters();

  @override
  State<_MixedPainters> createState() => _MixedPaintersState();
}

class _MixedPaintersState extends State<_MixedPainters>
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
  Widget build(BuildContext context) => Column(
    children: [
      RepaintBoundary(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (_, _) => CustomPaint(
            size: const Size(10, 10),
            painter: _ValuePainter(_controller.value),
          ),
        ),
      ),
      RepaintBoundary(
        child: CustomPaint(
          size: const Size(10, 10),
          painter: _RepaintingPainter(_controller),
        ),
      ),
    ],
  );
}

class _NoopPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {}

  @override
  bool shouldRepaint(_NoopPainter oldDelegate) => false;
}

class _ValuePainter extends CustomPainter {
  _ValuePainter(this.value);
  final double value;

  @override
  void paint(Canvas canvas, Size size) {}

  @override
  bool shouldRepaint(_ValuePainter oldDelegate) => oldDelegate.value != value;
}

class _RepaintingPainter extends CustomPainter {
  _RepaintingPainter(Listenable repaint) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {}

  @override
  bool shouldRepaint(_RepaintingPainter oldDelegate) => false;
}
