import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/debug/debug_instrumentation_coordinator.dart';
import 'package:sleuth/src/debug/debug_snapshot.dart';
import 'package:sleuth/src/ui/sleuth_overlay.dart';
import 'package:sleuth/src/utils/overlay_ownership.dart';

import '../helpers/overlay_harness.dart';

void main() {
  setUp(() {
    debugOnProfilePaint = null;
    debugOnRebuildDirtyWidget = null;
  });
  tearDown(() {
    debugOnProfilePaint = null;
    debugOnRebuildDirtyWidget = null;
  });

  /// Runs 30 frames with the dashboard open, the issue list rebuilding
  /// every frame and the app's ticker rebuilding and repainting, and
  /// returns the coordinator's snapshot over that window.
  Future<DebugSnapshot> churn(
    WidgetTester tester,
    SleuthController controller,
  ) async {
    var now = DateTime(2026);
    // Framework widgets count too, so the overlay's Card, InkWell and
    // Material would show up without the ownership check.
    final coord = DebugInstrumentationCoordinator(
      userWidgetsOnly: false,
      clock: () => now,
    );
    coord.install();
    expect(coord.isRebuildInstalled && coord.isPaintInstalled, isTrue);
    for (var i = 0; i < 30; i++) {
      controller.issuesNotifier.value = List.of(mixedOverlayIssues());
      await tester.pump(const Duration(milliseconds: 16));
    }
    now = now.add(const Duration(seconds: 1));
    final snap = coord.snapshot();
    coord.dispose();
    return snap;
  }

  /// Type names of every element in the app's subtree.
  Set<String> appTypes(WidgetTester tester) => {
    for (final e in collectAllElementsFrom(
      tester.element(find.byType(MaterialApp)),
      skipOffstage: false,
    ))
      e.widget.runtimeType.toString(),
  };

  Future<SleuthController> pumpOpen(WidgetTester tester) async {
    final controller = await pumpOverlay(
      tester,
      app: const MaterialApp(
        home: Scaffold(body: Center(child: _AppTicker())),
      ),
    );
    controller.issuesNotifier.value = mixedOverlayIssues();
    await openDashboard(tester, controller);
    return controller;
  }

  testWidgets('debug counts leave out the overlay while the dashboard '
      'is open', (tester) async {
    final controller = await pumpOpen(tester);
    final snap = await churn(tester, controller);

    expect(snap.rebuildCounts['_AppTicker'], greaterThanOrEqualTo(25));
    expect(snap.paintCounts['CustomPaint'], greaterThanOrEqualTo(25));
    final app = appTypes(tester);
    expect(snap.rebuildCounts.keys.toSet().difference(app), isEmpty);
    expect(snap.forcedRebuildsByRoot.keys.toSet().difference(app), isEmpty);
    expect(snap.paintCounts.keys.toSet().difference(app), isEmpty);
    final perType = snap.paintCounts.values.fold<int>(0, (a, b) => a + b);
    expect(snap.totalPaintCount, perType);
  }, semanticsEnabled: false);

  testWidgets('without the registration the same run counts the overlay', (
    tester,
  ) async {
    final controller = await pumpOpen(tester);
    final overlay = tester.element(find.byType(SleuthOverlay));
    final appKey = tester
        .widget<ExcludeFocus>(
          find.byWidgetPredicate((w) => w is ExcludeFocus && w.key != null),
        )
        .key!;
    OverlayOwnership.unregister(overlay, appKey);
    final snap = await churn(tester, controller);

    // The card list's listenable builder rebuilds itself for each new
    // issue list and rebuilds every IssueCard under it.
    expect(
      snap.rebuildCounts.keys,
      contains('ValueListenableBuilder<List<PerformanceIssue>>'),
    );
    expect(
      snap.forcedRebuildsByRoot['ValueListenableBuilder<List<PerformanceIssue>>'],
      greaterThan(100),
    );
  }, semanticsEnabled: false);

  group('OverlayOwnership', () {
    testWidgets('splits elements at the registered overlay and app key', (
      tester,
    ) async {
      final appKey = GlobalKey();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: _Root(
            child: Stack(
              children: [
                KeyedSubtree(key: appKey, child: const Text('app')),
                const Text('chrome'),
              ],
            ),
          ),
        ),
      );
      final root = tester.element(find.byType(_Root));
      final app = tester.element(find.text('app'));
      final chrome = tester.element(find.text('chrome'));
      final above = tester.element(find.byType(Directionality));

      expect(OverlayOwnership.isOverlayOwned(chrome), isFalse);

      OverlayOwnership.register(root, appKey);
      expect(OverlayOwnership.isOverlayOwned(root), isTrue);
      expect(OverlayOwnership.isOverlayOwned(chrome), isTrue);
      expect(OverlayOwnership.isOverlayOwned(app), isFalse);
      expect(OverlayOwnership.isOverlayOwned(above), isFalse);

      OverlayOwnership.unregister(root, appKey);
      expect(OverlayOwnership.isOverlayOwned(chrome), isFalse);
    });

    testWidgets('an overlay inside another overlay\'s app owns only its '
        'own chrome', (tester) async {
      final outerKey = GlobalKey();
      final innerKey = GlobalKey();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: _Root(
            child: Stack(
              children: [
                KeyedSubtree(
                  key: outerKey,
                  child: _Root(
                    child: Stack(
                      children: [
                        KeyedSubtree(key: innerKey, child: const Text('app')),
                        const Text('inner chrome'),
                      ],
                    ),
                  ),
                ),
                const Text('outer chrome'),
              ],
            ),
          ),
        ),
      );
      final roots = tester.elementList(find.byType(_Root)).toList();
      OverlayOwnership.register(roots[0], outerKey);
      OverlayOwnership.register(roots[1], innerKey);
      addTearDown(() {
        OverlayOwnership.unregister(roots[0], outerKey);
        OverlayOwnership.unregister(roots[1], innerKey);
      });

      expect(
        OverlayOwnership.isOverlayOwned(tester.element(find.text('app'))),
        isFalse,
      );
      expect(
        OverlayOwnership.isOverlayOwned(
          tester.element(find.text('inner chrome')),
        ),
        isTrue,
      );
      expect(
        OverlayOwnership.isOverlayOwned(
          tester.element(find.text('outer chrome')),
        ),
        isTrue,
      );
    });
  });
}

class _Root extends StatelessWidget {
  const _Root({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// Rebuilds and repaints on every frame.
class _AppTicker extends StatefulWidget {
  const _AppTicker();

  @override
  State<_AppTicker> createState() => _AppTickerState();
}

class _AppTickerState extends State<_AppTicker>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(vsync: this, duration: const Duration(seconds: 1))
        ..addListener(() => setState(() {}))
        ..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: const Size(20, 20),
    painter: _BarPainter(_controller.value),
  );
}

class _BarPainter extends CustomPainter {
  _BarPainter(this.value);

  final double value;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & Size(size.width * value, size.height),
      Paint(),
    );
  }

  @override
  bool shouldRepaint(_BarPainter oldDelegate) => oldDelegate.value != value;
}
