// Real-widget anti-tautology test for spec_v0_15_3 M1
// (RepaintDetector animation-owned filter).
//
// The companion `repaint_detector_test.dart` group covers the gate
// algebra against hand-rolled `DebugSnapshot` fixtures. Hand-written
// fixtures encode whatever the test author *thinks* the coordinator
// produces, so they cannot catch a bug where the filter relies on a
// chain key/string format the coordinator never emits in practice.
//
// This file pumps a real `CircularProgressIndicator` through a real
// `DebugInstrumentationCoordinator` paint pipeline, captures a real
// `DebugSnapshot`, asserts the captured ancestor chain actually
// contains the `CircularProgressIndicator` token the filter looks for,
// and then proves the detector skips the captured snapshot. If the
// chain capture format ever drifts from what the filter expects
// (e.g. KDD-6 polymorphic-key collision rewrites the chain, or
// `widget_location.dart` changes its strip rules) THIS test fails
// where the synthetic ones would silently keep passing.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/debug/debug_instrumentation_coordinator.dart';
import 'package:sleuth/src/debug/debug_snapshot.dart';
import 'package:sleuth/src/detectors/repaint_detector.dart';

void main() {
  group('RepaintDetector — real CircularProgressIndicator (spec_v0_15_3 M1)',
      () {
    testWidgets(
        'real CircularProgressIndicator paints captured with chain are '
        'suppressed by Gate A', (tester) async {
      // Pump a MINIMAL widget tree that gives a real
      // CircularProgressIndicator everything it needs to render
      // (Directionality + Theme) but NOTHING else. We deliberately
      // skip MaterialApp/Scaffold/Material because the test
      // environment does not RepaintBoundary-isolate Scaffold chrome
      // the way production does, so a richer tree ends up emitting
      // ~80 unrelated chrome paints that pollute the captured
      // aggregate and turn this test into a measurement of the test
      // environment, not of the filter.
      //
      // The `RepaintBoundary` around the indicator is what production
      // apps would normally have via `Material` — without it the
      // dirty-paint propagates up to `Center`, which lacks an
      // animation-owned chain and would fire `repaint_debug_Center`
      // (a real chain-containment limitation noted in spec_v0_15_3
      // KDD-2; descendant inspection is out of scope for the v0.15.3
      // patch).
      //
      // The indicator's own AnimationController is what generates
      // repaints between `tester.pump()` calls; no artificial driver.
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Theme(
            data: ThemeData.light(),
            child: const Center(
              child: RepaintBoundary(
                child: CircularProgressIndicator(),
              ),
            ),
          ),
        ),
      );

      // Install the paint callback AFTER the initial pump so the
      // first build/paint doesn't pollute the counts.
      final coordinator = DebugInstrumentationCoordinator(
        installRebuild: false, // not under test here
      );
      coordinator.install();

      DebugSnapshot? captured;
      try {
        // Advance the indicator's animation across several frames.
        // CircularProgressIndicator schedules a repaint per frame as
        // the rotation animation ticks, so each `pump` flushes a real
        // paint into `_handleProfilePaint`.
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        captured = coordinator.snapshot();
      } finally {
        coordinator.dispose();
      }

      // ---------- Real-data invariants ----------
      // The whole point of this test is to assert the *captured*
      // snapshot actually has the shape the filter depends on, before
      // we let the filter touch it. If any of these fail, the
      // synthetic fixtures in repaint_detector_test.dart are lying.
      expect(captured, isNotNull);
      expect(captured.paintCounts, isNotEmpty,
          reason: 'pumping a real CircularProgressIndicator must produce '
              'at least one paint event captured by the coordinator.');

      // The C1+C3 fix changed the filter contract: ownership is no
      // longer derived from chain-string containment in the detector,
      // it is computed per-paint by the coordinator and exposed as
      // `animationOwnedPaintCounts` / `totalAnimationOwnedPaintCount`.
      // The strongest invariant the real-widget test can assert is
      // that the coordinator actually populated these fields against
      // the live element — that's what proves the per-paint walk fired
      // on real CPI paints, not just on a hand-crafted fixture chain.
      expect(captured.animationOwnedPaintCounts, isNotEmpty,
          reason: 'coordinator must have attributed at least one paint '
              'to an animation owner via per-paint inspection of the '
              'live element. If this fails, isAnimationOwnedPaint never '
              'matched at runtime and the filter is dead code.');
      expect(captured.totalAnimationOwnedPaintCount, greaterThan(0));

      // For backwards-compat / source-location enrichment, the
      // coordinator also still caches one ancestor chain per typeName.
      // Assert the cache contains a CPI token so the chain-side of
      // `isAnimationOwnedPaint` is also exercised by real data.
      final chains = captured.ancestorChains;
      expect(chains, isNotEmpty,
          reason: 'paint callback must capture an ancestor chain for at '
              'least one painted widget.');
      final hasCpiChain = chains.values.any(
        (chain) => chain.contains('CircularProgressIndicator'),
      );
      expect(hasCpiChain, isTrue,
          reason: 'at least one captured ancestor chain must contain '
              '"CircularProgressIndicator" — even though the detector no '
              'longer reads it, this proves chain capture itself is '
              'working at runtime.');

      // ---------- The actual falsification ----------
      // Feed the *real* captured snapshot to a fresh detector. With the
      // animation filter active, this must NOT emit any issue, even
      // though the per-widget paint rate massively exceeds the 30/sec
      // threshold.
      //
      // To make the test ACTUALLY exercise Gate A (residual subtraction
      // with a positive rate floor) rather than just Gate C (aggregate
      // residual), we re-wrap the captured snapshot with a fixed
      // `elapsed: 100 ms`, which scales the rate by 10x. With ~10
      // paints captured per widget, that lands per-widget rates around
      // 100/sec — comfortably above the 30/sec threshold so Gate A's
      // per-widget rate check trips and its residual-subtraction logic
      // must run on every owned widget.
      //
      // We pass through `animationOwnedPaintCounts` and
      // `totalAnimationOwnedPaintCount` from the captured snapshot —
      // these are the fields the detector actually reads. Re-pinning
      // only `elapsed` (and dropping ownership) would test the OLD
      // chain-based contract, which is exactly the kind of fixture
      // tautology this file exists to prevent.
      //
      // If Gate A misses any owned widget, the per-widget loop will
      // emit a `repaint_debug_*` issue and this test fails. If Gate C's
      // residual subtraction is also broken, the aggregate path will
      // emit `excessive_repaint_debug` and this test fails. Both gates
      // are exercised in one shot against real captured ownership data.
      final pinnedSnapshot = DebugSnapshot(
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
      detector.updateDebugSnapshot(pinnedSnapshot);
      detector.evaluateNow();

      expect(detector.issues, isEmpty,
          reason: 'animation-owned paints from a real '
              'CircularProgressIndicator must be fully suppressed across '
              'all three gates (per-widget, VM fallback, aggregate).');
    });
  });
}
