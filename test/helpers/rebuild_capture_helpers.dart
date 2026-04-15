import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/debug/debug_instrumentation_coordinator.dart';
import 'package:sleuth/src/debug/debug_snapshot.dart';

/// Anti-tautology rebuild capture helpers — support for spec v15 M11.
///
/// Existing detector tests feed hand-coded `const DebugSnapshot` literals
/// into detectors, which validates that the detector's *reaction* to a
/// given snapshot is correct but does NOT verify that the debug-callback
/// pipeline actually produces those snapshots from real rebuilds. A bug
/// that changes the shape of [DebugSnapshot.rebuildCounts] at the
/// coordinator layer would not be caught by any of those tests because
/// the fixture author encoded the same assumption as the production code.
///
/// The helpers here install a real [DebugInstrumentationCoordinator] into
/// the global `debugOnRebuildDirtyWidget` slot, pump a [TestCounterWidget]
/// via the supplied [WidgetTester], trigger a known number of real
/// `setState()` rebuilds, and drain a real [DebugSnapshot] back out of
/// the coordinator. The resulting snapshot is what detectors receive in
/// production, and feeding it to them verifies the full pipeline end to
/// end without a hand-written fixture in sight.
///
/// Widget tests run under `kDebugMode`, so the coordinator installs on its
/// debug path (`debugOnRebuildDirtyWidget`) — the profile-mode
/// `FlutterTimeline` drain (KDD-1) is NOT exercised here; that path has
/// its own dedicated suite under `test/debug/`.

/// A tiny stateful widget whose build output is driven by an integer
/// counter on its state. Tests use [triggerRebuild] (via [GlobalKey]) to
/// deterministically produce N rebuilds and verify detectors pick them up
/// through the real coordinator pipeline.
///
/// The public name is deliberate — detectors filter out private-prefixed
/// (`_Foo`) widgets as framework internals (see
/// `RebuildDetector._frameworkWidgetNames`), so a private helper class
/// would be silently dropped and mask the very failure we are testing
/// for.
class TestCounterWidget extends StatefulWidget {
  const TestCounterWidget({super.key, this.childCount = 1});

  /// Number of child `SizedBox` leaves to pad the subtree with. The
  /// setstate-scope detector needs the widget's subtree to exceed
  /// `minSubtreeSize`, so its anti-tautology test bumps this up.
  final int childCount;

  @override
  State<TestCounterWidget> createState() => TestCounterWidgetState();
}

class TestCounterWidgetState extends State<TestCounterWidget> {
  int _counter = 0;

  /// Trigger one setState rebuild. Flushed into the pipeline on the next
  /// [WidgetTester.pump].
  void triggerRebuild() => setState(() => _counter++);

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // The mutable child keeps a ValueKey tied to the counter so
        // identity changes on every rebuild — this is what the
        // setstate-scope detector's mutable-ratio path keys on.
        SizedBox(key: ValueKey(_counter), height: 10),
        for (int i = 0; i < widget.childCount; i++)
          SizedBox(key: ValueKey('child-$i'), height: 10),
      ],
    );
  }
}

/// Drives [count] real setState rebuilds on [key] while a real
/// [DebugInstrumentationCoordinator] is installed, returns the resulting
/// [DebugSnapshot], and cleans up the coordinator on the way out.
///
/// The caller has already pumped a widget tree containing
/// `TestCounterWidget(key: key)` via [tester]. This helper:
///
///   1. Saves the current `debugOnRebuildDirtyWidget` slot and installs a
///      fresh coordinator in it.
///   2. Calls `key.currentState!.triggerRebuild()` + `tester.pump()` in a
///      loop, yielding real rebuild events into the coordinator's
///      internal map.
///   3. Calls `coordinator.snapshot()` to drain a real [DebugSnapshot].
///   4. Uninstalls the coordinator in a `finally` (restoring whatever was
///      in the slot before, which is almost always `null` in tests).
///
/// The returned snapshot has `source: RebuildCountSource.debugCallback`
/// and real per-type counts — exactly what production detectors see when
/// `enableDebugCallbacks = true`. Feeding this to a detector validates
/// that the detector's contract with the coordinator actually holds.
Future<DebugSnapshot> captureDebugCallbackCounts({
  required WidgetTester tester,
  required GlobalKey<TestCounterWidgetState> key,
  required int count,
}) async {
  final coordinator = DebugInstrumentationCoordinator(
    // Paint callback not needed — it would fight any other consumer of
    // `debugOnProfilePaint` and isn't what the anti-tautology tests
    // target.
    installPaint: false,
  );
  coordinator.install();
  // Seed the element-seen set with every element already in the tree
  // from the prior `pumpWidget`, so the coordinator counts the very
  // first rebuild after install instead of consuming it as a
  // first-observation placeholder (see `primeExistingElements` docs).
  coordinator.primeExistingElements(
    tester.element(find.byType(TestCounterWidget)),
  );
  try {
    for (int i = 0; i < count; i++) {
      key.currentState!.triggerRebuild();
      await tester.pump(const Duration(milliseconds: 16));
    }
    return coordinator.snapshot();
  } finally {
    coordinator.dispose();
  }
}

/// Generalized form of [captureDebugCallbackCounts] for detector tests
/// whose anti-tautology scenario doesn't fit the [TestCounterWidget]
/// shape (e.g. an `AnimatedBuilder` driven by a `ValueNotifier`).
///
/// Install → prime → drive [trigger] [iterations] times with a 16ms
/// pump between each → return the drained [DebugSnapshot] → dispose.
///
/// [scanRoot] must resolve to the top of the element subtree you care
/// about — every element from there downward is primed as
/// already-seen so the first rebuild after install is counted, not
/// swallowed by the Expando first-observation guard.
Future<DebugSnapshot> captureRebuildsViaTrigger({
  required WidgetTester tester,
  required Future<void> Function() trigger,
  required Finder scanRoot,
  int iterations = 1,
}) async {
  final coordinator = DebugInstrumentationCoordinator(installPaint: false);
  coordinator.install();
  coordinator.primeExistingElements(tester.element(scanRoot));
  try {
    for (int i = 0; i < iterations; i++) {
      await trigger();
      await tester.pump(const Duration(milliseconds: 16));
    }
    return coordinator.snapshot();
  } finally {
    coordinator.dispose();
  }
}
