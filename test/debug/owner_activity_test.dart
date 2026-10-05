import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/debug/debug_instrumentation_coordinator.dart';
import 'package:sleuth/src/debug/debug_snapshot.dart';
import 'package:sleuth/src/ui/overlay_ui_state.dart';

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

  /// Pumps [_Host] and returns the snapshot over 20 frames.
  Future<DebugSnapshot> run(
    WidgetTester tester, {
    required bool animate,
  }) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: _Host(animate: animate)),
      ),
    );
    await tester.pump(const Duration(milliseconds: 16));
    final coord = DebugInstrumentationCoordinator();
    coord.install();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final snap = coord.snapshot();
    coord.dispose();
    return snap;
  }

  testWidgets('an idle AnimatedContainer does not own a painter that '
      'repaints under it', (tester) async {
    final snap = await run(tester, animate: false);
    expect(snap.paintCounts['CustomPaint'], greaterThanOrEqualTo(20));
    expect(snap.animationOwnedPaintCounts['CustomPaint'] ?? 0, 0);
  }, semanticsEnabled: false);

  testWidgets('an animating AnimatedContainer owns the paints under it', (
    tester,
  ) async {
    final snap = await run(tester, animate: true);
    expect(snap.paintCounts['CustomPaint'], greaterThanOrEqualTo(20));
    expect(
      snap.animationOwnedPaintCounts['CustomPaint'],
      snap.paintCounts['CustomPaint'],
    );
  }, semanticsEnabled: false);

  testWidgets('an overlay-only rebuild counts nothing, the app boundary '
      'included', (tester) async {
    final controller = await pumpOverlay(tester);
    final coord = DebugInstrumentationCoordinator(userWidgetsOnly: false);
    coord.install();
    for (final mode in [SleuthThemeMode.dark, SleuthThemeMode.light]) {
      controller.overlayUiState.themeMode = mode;
      await tester.pump(const Duration(milliseconds: 16));
    }
    final snap = coord.snapshot();
    coord.dispose();
    expect(snap.rebuildCounts, isEmpty);
    expect(snap.forcedRebuildsByRoot, isEmpty);
  }, semanticsEnabled: false);
}

/// A painter repainting every frame from its own controller under an
/// [AnimatedContainer] that is idle, or (with [animate]) running a 10 s
/// colour animation.
class _Host extends StatefulWidget {
  const _Host({required this.animate});

  final bool animate;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with SingleTickerProviderStateMixin {
  late final AnimationController _ticks = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..repeat();
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    if (widget.animate) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _changed = true);
      });
    }
  }

  @override
  void dispose() {
    _ticks.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: const Duration(seconds: 10),
    color: _changed ? const Color(0xFFFF0000) : const Color(0xFF0000FF),
    child: CustomPaint(size: const Size(20, 20), painter: _Ticking(_ticks)),
  );
}

class _Ticking extends CustomPainter {
  _Ticking(this.animation) : super(repaint: animation);

  final Animation<double> animation;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & Size(size.width * animation.value, size.height),
      Paint(),
    );
  }

  @override
  bool shouldRepaint(_Ticking oldDelegate) => false;
}
