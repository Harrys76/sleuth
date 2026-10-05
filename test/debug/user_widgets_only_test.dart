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
  tearDown(() {
    debugOnProfilePaint = null;
    debugOnRebuildDirtyWidget = null;
  });

  /// Runs 30 frames of a route whose ticker rebuilds a button and
  /// repaints the whole route (the app bar shares its layer).
  Future<DebugSnapshot> churn(
    WidgetTester tester, {
    required bool userWidgetsOnly,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(title: const Text('Title')),
          body: const Center(child: _Ticker()),
        ),
      ),
    );
    var now = DateTime(2026);
    final coord = DebugInstrumentationCoordinator(
      userWidgetsOnly: userWidgetsOnly,
      clock: () => now,
    );
    coord.install();
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    now = now.add(const Duration(seconds: 1));
    final snap = coord.snapshot();
    coord.dispose();
    return snap;
  }

  /// Framework widgets the user widgets above build internally.
  const frameworkInternals = {
    'RichText',
    '_InkFeatures',
    'PhysicalModel',
    'CustomMultiChildLayout',
    '_AppBarTitleBox',
    'InkWell',
    'Material',
    '_InputPadding',
  };

  testWidgets('counts only the widgets the app creates', (tester) async {
    final snap = await churn(tester, userWidgetsOnly: true);

    expect(snap.rebuildCounts['_Ticker'], greaterThanOrEqualTo(25));
    expect(snap.rebuildCounts['ElevatedButton'], greaterThanOrEqualTo(25));
    expect(snap.rebuildCounts['Text'], greaterThanOrEqualTo(25));
    expect(snap.paintCounts['CustomPaint'], greaterThanOrEqualTo(25));
    for (final name in frameworkInternals) {
      expect(snap.rebuildCounts.containsKey(name), isFalse, reason: name);
      expect(snap.paintCounts.containsKey(name), isFalse, reason: name);
    }
    // Framework paints stay in the aggregate.
    final perType = snap.paintCounts.values.fold<int>(0, (a, b) => a + b);
    expect(snap.totalPaintCount, greaterThan(perType));
  }, semanticsEnabled: false);

  testWidgets('userWidgetsOnly: false counts the framework widgets too', (
    tester,
  ) async {
    final snap = await churn(tester, userWidgetsOnly: false);

    expect(snap.paintCounts['RichText'], greaterThanOrEqualTo(25));
    expect(snap.paintCounts['_AppBarTitleBox'], greaterThanOrEqualTo(25));
    expect(snap.rebuildCounts['InkWell'], greaterThanOrEqualTo(25));
    final perType = snap.paintCounts.values.fold<int>(0, (a, b) => a + b);
    expect(snap.totalPaintCount, perType);
  }, semanticsEnabled: false);
}

/// Rebuilds every frame and repaints its route.
class _Ticker extends StatefulWidget {
  const _Ticker();

  @override
  State<_Ticker> createState() => _TickerState();
}

class _TickerState extends State<_Ticker> with SingleTickerProviderStateMixin {
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
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      CustomPaint(
        size: const Size(20, 20),
        painter: _BarPainter(_controller.value),
      ),
      ElevatedButton(
        onPressed: () {},
        child: Text('${(_controller.value * 100).round()}'),
      ),
    ],
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
