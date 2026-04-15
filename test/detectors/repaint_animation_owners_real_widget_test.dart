// Real-widget anti-tautology tests for spec_v0_15_3 C5 fix.
//
// The companion `repaint_detector_test.dart` group covers the gate
// algebra against hand-rolled `DebugSnapshot` fixtures populated with
// `animationOwnedPaintCounts` directly. Hand-written fixtures encode
// whatever the test author *thinks* the coordinator produces — they
// bypass the per-paint `isAnimationOwnedPaint` walk entirely. So they
// cannot catch a bug where the coordinator's hot path fails to attribute
// owned paints in production-like conditions: chain capture failing,
// descendant walks bailing on visit-cap, owner widgets that never reach
// `_handleProfilePaint` because they're stripped by `widget_location`,
// implicit-animation widgets whose internal render objects don't expose
// the wrapping `Animated*` in their captured chain, etc.
//
// `repaint_animation_filter_real_widget_test.dart` covers `CircularProgressIndicator`
// only. This file extends the coverage to the OTHER six animation owner
// categories (LinearProgressIndicator, RefreshProgressIndicator,
// AnimatedBuilder, ValueListenableBuilder, TweenAnimationBuilder,
// AnimatedContainer) and the two architectural edge cases the v0.15.3
// C1/C3 fixes were explicitly designed to close:
//
//  - **C1 polymorphic-key collision**: two `CustomPaint` widgets with
//    the same runtimeType key, one descendant-of-AnimatedBuilder (owned)
//    and one not (un-owned). Pre-C1, the chain cache stored whichever was
//    seen first and the gate either fully suppressed the chart's bug or
//    fully fired on the indicator's spinner. Post-C1, per-paint
//    attribution must produce a mixed `animationOwnedPaintCounts` entry.
//
//  - **C3 chain-walks-up gap**: `CircularProgressIndicator` mounted
//    WITHOUT a wrapping `RepaintBoundary`. The dirty-paint propagates UP
//    through the tree to the nearest layer-owning ancestor; some of the
//    paint events that fire are for render objects ABOVE CPI in the
//    tree (e.g. `Center`, `RenderPositionedBox`). The chain walk goes
//    UP from those elements and never finds CPI — only the bounded
//    descendant walk closes the gap.
//
// If chain capture format ever drifts from what the filter expects, or
// if the descendant walk's visit cap is too tight to reach the owner,
// or if a strip-set entry hides an owner from the chain, THIS file fails
// where the synthetic ones would silently keep passing.

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/debug/debug_instrumentation_coordinator.dart';
import 'package:sleuth/src/debug/debug_snapshot.dart';
import 'package:sleuth/src/detectors/repaint_detector.dart';

void main() {
  group('RepaintDetector — real animation owners (spec_v0_15_3 C5)', () {
    testWidgets('LinearProgressIndicator paints attributed as owned',
        (tester) async {
      final captured = await _captureRealPaints(
        tester: tester,
        // LinearProgressIndicator needs a bounded width and is wrapped in
        // a RepaintBoundary so the dirty-paint path matches the canonical
        // production layout (CPI also gets wrapped via Material).
        root: const Center(
          child: SizedBox(
            width: 200,
            child: RepaintBoundary(child: LinearProgressIndicator()),
          ),
        ),
      );
      _expectOwnedAttribution(captured, 'LinearProgressIndicator');
      _expectNoIssues(captured);
    });

    testWidgets('RefreshProgressIndicator paints attributed as owned',
        (tester) async {
      // RefreshProgressIndicator wraps RefreshProgressIndicator's own
      // internal AnimationController inside an AnimatedBuilder, then
      // wraps THAT in `_buildMaterialIndicator`'s decoration stack:
      // `Padding > SizedBox > _SemanticsWrapper > NotificationListener >
      // Material > Padding > Opacity > Transform > CustomPaint`. The
      // CustomPaint at the bottom of that stack is the painted leaf,
      // which means the AnimatedBuilder owner sits ~13 ancestors above.
      //
      // This is the canonical case for `hasAnimationOwnerAncestor`: the
      // ancestor-chain string maxes out at depth 6 (it's for human
      // source-location display) and the descendant walk can't see the
      // owner because the owner is *upstream* of the leaf, not
      // downstream. Without the dedicated ancestor walk, ownership
      // detection misses RPI entirely.
      //
      // The chain-cache assertion is opted out for the same reason —
      // the chain string genuinely cannot reach 'RefreshProgressIndicator'
      // within its budget. That is a deliberate display-budget choice,
      // not a regression.
      final captured = await _captureRealPaints(
        tester: tester,
        root: const Center(
          child: RepaintBoundary(child: RefreshProgressIndicator()),
        ),
      );
      _expectOwnedAttribution(
        captured,
        'RefreshProgressIndicator',
        expectOwnerInChainString: false,
      );
      _expectNoIssues(captured);
    });

    testWidgets('TweenAnimationBuilder paints attributed as owned',
        (tester) async {
      // Pure stateless owner — tween auto-starts on first build and
      // advances once per frame for the duration of the tween. With a
      // 1s tween and 10 pumps at 16ms (160ms total) we're firmly inside
      // the tween window.
      final captured = await _captureRealPaints(
        tester: tester,
        root: Center(
          child: RepaintBoundary(
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: 1),
              duration: const Duration(seconds: 1),
              builder: (_, value, __) => SizedBox(
                width: 50 + value * 50,
                height: 50,
                child: const ColoredBox(color: Color(0xFF000000)),
              ),
            ),
          ),
        ),
      );
      _expectOwnedAttribution(captured, 'TweenAnimationBuilder');
      _expectNoIssues(captured);
    });

    testWidgets('AnimatedBuilder paints attributed as owned', (tester) async {
      // AnimatedBuilder driven by a repeating AnimationController. Each
      // controller tick rebuilds the builder, which forces a paint.
      final captured = await _captureRealPaints(
        tester: tester,
        root: const Center(
          child: RepaintBoundary(child: _AnimatedBuilderHost()),
        ),
      );
      _expectOwnedAttribution(captured, 'AnimatedBuilder');
      _expectNoIssues(captured);
    });

    testWidgets('ValueListenableBuilder paints attributed as owned',
        (tester) async {
      // ValueListenableBuilder driven by a Ticker that bumps a
      // ValueNotifier per frame. Each value change triggers a rebuild
      // and a paint.
      final captured = await _captureRealPaints(
        tester: tester,
        root: const Center(
          child: RepaintBoundary(child: _ValueListenableBuilderHost()),
        ),
      );
      _expectOwnedAttribution(captured, 'ValueListenableBuilder');
      _expectNoIssues(captured);
    });

    testWidgets('AnimatedContainer paints attributed as owned', (tester) async {
      // Implicit animation widget — distinct from the explicit owners
      // above because the user never sees the AnimationController. A
      // post-frame setState bumps the width AFTER the first frame so
      // the coordinator (installed between frame 1 and frame 2) catches
      // the entire tween animation, not the initial mount.
      final captured = await _captureRealPaints(
        tester: tester,
        root: const Center(
          child: RepaintBoundary(child: _AnimatedContainerHost()),
        ),
      );
      _expectOwnedAttribution(captured, 'AnimatedContainer');
      _expectNoIssues(captured);
    });
  });

  group('RepaintDetector — C1 polymorphic-key collision (spec_v0_15_3 C1)', () {
    testWidgets(
        'mixed-ownership CustomPaint scene fires only on un-owned residual',
        (tester) async {
      // Two CustomPaint widgets in the same scene — one inside an
      // AnimatedBuilder (owned), one driven by an external Ticker that
      // calls setState on a non-owner host (un-owned). Both share the
      // runtimeType key 'CustomPaint' so they collide in `paintCounts`
      // and `animationOwnedPaintCounts`. Pre-C1 fix the chain cache
      // would store whichever ancestor chain was seen first and the
      // detector either fully suppressed both or fully fired on both.
      // Post-C1 the per-paint attribution must produce a MIXED entry:
      // some paints owned, some not.
      final captured = await _captureRealPaints(
        tester: tester,
        root: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RepaintBoundary(child: _UnownedCustomPaintHost()),
              SizedBox(height: 8),
              RepaintBoundary(child: _OwnedCustomPaintHost()),
            ],
          ),
        ),
      );

      // Both halves share the same key.
      final totalCustomPaint = captured.paintCounts['CustomPaint'] ?? 0;
      final ownedCustomPaint =
          captured.animationOwnedPaintCounts['CustomPaint'] ?? 0;

      expect(totalCustomPaint, greaterThan(0),
          reason: 'multi-CustomPaint scene must produce paint events keyed '
              'under "CustomPaint".');
      expect(ownedCustomPaint, greaterThan(0),
          reason: 'C1 fix: per-paint attribution must mark the AnimatedBuilder-'
              'descendant CustomPaint as owned. If this is zero, the chain '
              'walk failed to find AnimatedBuilder as an ancestor of the '
              'owned CustomPaint.');
      expect(ownedCustomPaint, lessThan(totalCustomPaint),
          reason: 'C1 fix: per-paint attribution must NOT mark the '
              'externally-rebuilt CustomPaint as owned. If owned == total, '
              'the un-owned host is being mis-attributed (likely because the '
              'descendant walk is finding something it should not).');

      // Pin elapsed to push residual rate above 30/sec so Gate A's
      // residual subtraction actually trips.
      final residual = totalCustomPaint - ownedCustomPaint;
      final pinnedSnapshot = DebugSnapshot(
        rebuildCounts: captured.rebuildCounts,
        paintCounts: captured.paintCounts,
        totalPaintCount: captured.totalPaintCount,
        ancestorChains: captured.ancestorChains,
        animationOwnedPaintCounts: captured.animationOwnedPaintCounts,
        totalAnimationOwnedPaintCount: captured.totalAnimationOwnedPaintCount,
        // residual / 0.1s must clear 30/sec: residual ≥ 4 paints suffices.
        elapsed: const Duration(milliseconds: 100),
        source: captured.source,
      );

      // The residual should be large enough to fire the gate. If the
      // un-owned host produced fewer than ~4 paints in the capture
      // window, this assertion will protect against a flaky test run
      // where the Ticker didn't tick enough; in that case retry with
      // more frames.
      expect(residual, greaterThanOrEqualTo(4),
          reason: 'un-owned half of the scene must produce at least 4 paints '
              'in the 10-frame capture window for the residual rate to clear '
              '30/sec after elapsed pinning. If this fails, the un-owned '
              'host\'s Ticker is not ticking — investigate test framework '
              'ticker dispatch, not the detector.');

      final detector = RepaintDetector()..vmConnected = false;
      detector.updateDebugSnapshot(pinnedSnapshot);
      detector.evaluateNow();

      // Exactly one issue should fire — the residual CustomPaint issue.
      // It should report the residual count, not the total, and the
      // detail line should disclose the excluded owned paints.
      final repaintIssues = detector.issues
          .where((i) => i.stableId?.startsWith('repaint_debug_') ?? false)
          .toList();
      expect(repaintIssues, hasLength(1),
          reason: 'C1 fix: residual CustomPaint paints must produce exactly '
              'one repaint_debug_CustomPaint issue. If zero, the gate is '
              'over-suppressing (treating mixed as fully owned). If more '
              'than one, the gate is double-counting.');

      final issue = repaintIssues.single;
      expect(issue.stableId, 'repaint_debug_CustomPaint');
      expect(issue.detail, contains('$residual repaints'),
          reason: 'issue detail must report the residual count, not the '
              'total. Total was $totalCustomPaint, residual was $residual.');
      expect(issue.detail, contains('Excludes $ownedCustomPaint'),
          reason: 'issue detail must disclose how many paints were '
              'excluded as animation-owned.');
    });
  });

  group('RepaintDetector — C3 chain-walks-up gap (spec_v0_15_3 C3)', () {
    testWidgets(
        'bare CircularProgressIndicator without RepaintBoundary attributed '
        'via descendant walk', (tester) async {
      // No RepaintBoundary wrapper — dirty-paint propagates up through
      // Center to the nearest layer owner (whatever the test view's
      // implicit boundary is). Some paint events fire for render objects
      // ABOVE CPI in the tree, whose ancestor chain walk goes UP and
      // never reaches CPI. Only the bounded descendant walk
      // (`hasAnimationOwnerDescendant`) can find CPI from those elements.
      //
      // If this test fails after the C3 fix, the descendant walk's
      // visit cap or depth cap is insufficient for a normal-depth tree,
      // OR `_handleProfilePaint` isn't calling `isAnimationOwnedPaint`
      // for ancestor paints at all. Either way the v0.15.3 C3 fix
      // would be incomplete.
      final captured = await _captureRealPaints(
        tester: tester,
        root: const Center(child: CircularProgressIndicator()),
      );

      expect(captured.animationOwnedPaintCounts, isNotEmpty,
          reason: 'C3 fix: bare CPI without RepaintBoundary must still get '
              'owned attribution via the descendant walk. If empty, the '
              'descendant walk in isAnimationOwnedPaint is not catching CPI '
              'when the dirty leaf is an ancestor of CPI in the tree.');
      expect(captured.totalAnimationOwnedPaintCount, greaterThan(0));

      _expectNoIssues(captured);
    });
  });
}

// ---------------------------------------------------------------------------
// Capture helper
// ---------------------------------------------------------------------------

/// Pumps [root] in a minimal Directionality+Theme tree, installs a fresh
/// `DebugInstrumentationCoordinator` AFTER the initial mount paint, then
/// pumps [frameCount] more frames at 16 ms each and returns the captured
/// snapshot. The coordinator is installed AFTER the first pump so the
/// initial build/paint doesn't pollute the counts (matches the canonical
/// pattern used by `repaint_animation_filter_real_widget_test.dart`).
Future<DebugSnapshot> _captureRealPaints({
  required WidgetTester tester,
  required Widget root,
  int frameCount = 10,
}) async {
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Theme(
        data: ThemeData.light(),
        child: root,
      ),
    ),
  );

  final coordinator = DebugInstrumentationCoordinator(installRebuild: false);
  coordinator.install();

  try {
    for (var i = 0; i < frameCount; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    return coordinator.snapshot();
  } finally {
    coordinator.dispose();
  }
}

/// Asserts the captured snapshot proves owned attribution actually fired
/// at runtime for [ownerName]. Checks two invariants:
///
/// 1. `animationOwnedPaintCounts` and `totalAnimationOwnedPaintCount` are
///    populated — proves `isAnimationOwnedPaint` matched against a real
///    paint event for SOME widget keyed in the snapshot.
/// 2. The captured ancestor chain cache contains [ownerName] — even
///    though the detector no longer reads chains for ownership decisions,
///    this is a smoke test that the strip set in `widget_location.dart`
///    isn't accidentally hiding the owner from the chain.
///
/// **[expectOwnerInChainString]**: defaults to true, but specific owners
/// can opt out when their framework wrapping puts them beyond
/// `buildAncestorChain`'s `maxDepth: 6` budget. `RefreshProgressIndicator`
/// is the canonical case — its painted leaf sits ~13 ancestors below the
/// owning `AnimatedBuilder` because of Material's internal wrapping
/// (`Padding > SizedBox > _SemanticsWrapper > NotificationListener >
/// Material > Padding > Opacity > Transform > CustomPaint`). The chain
/// string is for human source-location display and stays shallow on
/// purpose; the new `hasAnimationOwnerAncestor` walk has its own deeper
/// budget so ownership detection still works.
void _expectOwnedAttribution(
  DebugSnapshot captured,
  String ownerName, {
  bool expectOwnerInChainString = true,
}) {
  expect(captured.paintCounts, isNotEmpty,
      reason: '$ownerName scene must produce at least one paint event.');
  expect(captured.animationOwnedPaintCounts, isNotEmpty,
      reason: '$ownerName scene must populate animationOwnedPaintCounts. '
          'If empty, the per-paint isAnimationOwnedPaint walk in '
          '_handleProfilePaint never matched at runtime — the filter is '
          'dead code for $ownerName.');
  expect(captured.totalAnimationOwnedPaintCount, greaterThan(0));

  if (expectOwnerInChainString) {
    final chains = captured.ancestorChains;
    final hasOwnerInChain =
        chains.values.any((chain) => chain.contains(ownerName));
    expect(hasOwnerInChain, isTrue,
        reason: 'at least one captured ancestor chain must contain '
            '"$ownerName" — if missing, the strip set in widget_location.dart '
            'is hiding $ownerName from chains. The detector no longer reads '
            'chains for ownership decisions, but downstream source-location '
            'enrichment does, so this is still a regression.');
  }
}

/// Re-pins [captured] to a 100 ms elapsed window and feeds it to a fresh
/// `RepaintDetector` with `vmConnected = false` (forcing the debug-data
/// path through Gate A and Gate C). Asserts no `repaint_debug_*` or
/// `excessive_repaint_debug` issues fire.
///
/// The 100 ms pin is what makes this test exercise Gate A's per-widget
/// rate check rather than just falling out at Gate C's aggregate residual.
/// With ~10 captured paints and a 100 ms window, per-widget rates land
/// around 100/sec — comfortably above the 30/sec threshold so the gate
/// has to actually run residual subtraction logic on every owned widget.
void _expectNoIssues(DebugSnapshot captured) {
  final pinned = DebugSnapshot(
    rebuildCounts: captured.rebuildCounts,
    paintCounts: captured.paintCounts,
    totalPaintCount: captured.totalPaintCount,
    ancestorChains: captured.ancestorChains,
    animationOwnedPaintCounts: captured.animationOwnedPaintCounts,
    totalAnimationOwnedPaintCount: captured.totalAnimationOwnedPaintCount,
    elapsed: const Duration(milliseconds: 100),
    source: captured.source,
  );
  final detector = RepaintDetector()..vmConnected = false;
  detector.updateDebugSnapshot(pinned);
  detector.evaluateNow();

  expect(detector.issues, isEmpty,
      reason: 'animation-owned paints from the captured scene must be fully '
          'suppressed across all gates. Issues fired: '
          '${detector.issues.map((i) => i.stableId).join(", ")}');
}

// ---------------------------------------------------------------------------
// Stateful host widgets for owners that need an external animation driver
// ---------------------------------------------------------------------------

/// Wraps an [AnimatedBuilder] around a repeating [AnimationController]. The
/// controller is created in `initState` and disposed in `dispose`; the
/// builder rebuilds every frame the controller ticks.
class _AnimatedBuilderHost extends StatefulWidget {
  const _AnimatedBuilderHost();

  @override
  State<_AnimatedBuilderHost> createState() => _AnimatedBuilderHostState();
}

class _AnimatedBuilderHostState extends State<_AnimatedBuilderHost>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl =
      AnimationController(vsync: this, duration: const Duration(seconds: 2))
        ..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) => SizedBox(
        width: 50 + _ctrl.value * 50,
        height: 50,
        child: const ColoredBox(color: Color(0xFF000000)),
      ),
    );
  }
}

/// Wraps a [ValueListenableBuilder] around a [ValueNotifier] driven by a
/// per-frame [Ticker]. Each Ticker tick mutates the notifier, which causes
/// the builder to rebuild.
class _ValueListenableBuilderHost extends StatefulWidget {
  const _ValueListenableBuilderHost();

  @override
  State<_ValueListenableBuilderHost> createState() =>
      _ValueListenableBuilderHostState();
}

class _ValueListenableBuilderHostState
    extends State<_ValueListenableBuilderHost>
    with SingleTickerProviderStateMixin {
  final ValueNotifier<double> _value = ValueNotifier<double>(0);
  late final Ticker _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      _value.value = (elapsed.inMilliseconds % 1000) / 1000.0;
    })
      ..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _value.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: _value,
      builder: (_, value, __) => SizedBox(
        width: 50 + value * 50,
        height: 50,
        child: const ColoredBox(color: Color(0xFF000000)),
      ),
    );
  }
}

/// Wraps an [AnimatedContainer] that toggles its `width` from 50 to 200
/// via a post-frame `setState`. This kicks off the implicit tween AFTER
/// the first frame, so the coordinator (installed between frame 1 and
/// frame 2) catches the entire tween animation.
class _AnimatedContainerHost extends StatefulWidget {
  const _AnimatedContainerHost();

  @override
  State<_AnimatedContainerHost> createState() => _AnimatedContainerHostState();
}

class _AnimatedContainerHostState extends State<_AnimatedContainerHost> {
  double _width = 50;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _width = 200);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(seconds: 1),
      width: _width,
      height: 50,
      color: const Color(0xFF000000),
    );
  }
}

// ---------------------------------------------------------------------------
// C1 polymorphic-collision hosts: two CustomPaints with the same runtimeType
// key but different ownership.
// ---------------------------------------------------------------------------

/// Always-repaint painter — `shouldRepaint` returns true, so any rebuild
/// of the wrapping `CustomPaint` widget forces an actual render-object
/// repaint.
class _AlwaysRepaintPainter extends CustomPainter {
  const _AlwaysRepaintPainter(this.tag);
  final int tag;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFF000000),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

/// `CustomPaint` driven by an external `Ticker` + `setState` on a non-owner
/// host. Critically, `_UnownedCustomPaintHost` itself is NOT in
/// [animationOwnerNames], and there is no animation-owner widget anywhere
/// between this class and its `CustomPaint` child — so the per-paint
/// attribution must classify this CustomPaint's paints as un-owned.
class _UnownedCustomPaintHost extends StatefulWidget {
  const _UnownedCustomPaintHost();

  @override
  State<_UnownedCustomPaintHost> createState() =>
      _UnownedCustomPaintHostState();
}

class _UnownedCustomPaintHostState extends State<_UnownedCustomPaintHost>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  int _tick = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) {
      setState(() => _tick++);
    })
      ..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _AlwaysRepaintPainter(_tick),
      size: const Size(50, 50),
    );
  }
}

/// `CustomPaint` directly underneath an `AnimatedBuilder` driven by a
/// repeating `AnimationController`. Per-paint attribution must classify
/// THIS CustomPaint's paints as owned (chain walks UP and finds
/// `AnimatedBuilder` as an immediate ancestor).
class _OwnedCustomPaintHost extends StatefulWidget {
  const _OwnedCustomPaintHost();

  @override
  State<_OwnedCustomPaintHost> createState() => _OwnedCustomPaintHostState();
}

class _OwnedCustomPaintHostState extends State<_OwnedCustomPaintHost>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl =
      AnimationController(vsync: this, duration: const Duration(seconds: 2))
        ..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) => CustomPaint(
        painter: _AlwaysRepaintPainter((_ctrl.value * 1000).toInt()),
        size: const Size(50, 50),
      ),
    );
  }
}
