import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/debug/debug_instrumentation_coordinator.dart';
import 'package:sleuth/src/debug/debug_snapshot.dart';

void main() {
  group('DebugInstrumentationCoordinator', () {
    late DebugInstrumentationCoordinator coordinator;

    setUp(() {
      // Ensure globals are clean before each test.
      assert(() {
        debugOnRebuildDirtyWidget = null;
        debugOnProfilePaint = null;
        return true;
      }());
      coordinator = DebugInstrumentationCoordinator();
    });

    tearDown(() {
      coordinator.dispose();
      assert(() {
        debugOnRebuildDirtyWidget = null;
        debugOnProfilePaint = null;
        return true;
      }());
    });

    test('install sets debugOnRebuildDirtyWidget when null', () {
      assert(() {
        expect(debugOnRebuildDirtyWidget, isNull);
        coordinator.install();
        expect(debugOnRebuildDirtyWidget, isNotNull);
        expect(coordinator.isRebuildInstalled, isTrue);
        return true;
      }());
    });

    test('install sets debugOnProfilePaint when null', () {
      assert(() {
        expect(debugOnProfilePaint, isNull);
        coordinator.install();
        expect(debugOnProfilePaint, isNotNull);
        expect(coordinator.isPaintInstalled, isTrue);
        return true;
      }());
    });

    test('install skips rebuild slot when already occupied', () {
      assert(() {
        void existingCallback(Element e, bool b) {}
        debugOnRebuildDirtyWidget = existingCallback;

        coordinator.install();

        // Should NOT overwrite — still the existing callback.
        expect(debugOnRebuildDirtyWidget, same(existingCallback));
        expect(coordinator.isRebuildInstalled, isFalse);
        // But paint should be installed.
        expect(coordinator.isPaintInstalled, isTrue);

        debugOnRebuildDirtyWidget = null;
        return true;
      }());
    });

    test('install skips paint slot when already occupied', () {
      assert(() {
        void existingCallback(dynamic ro) {}
        debugOnProfilePaint = existingCallback;

        coordinator.install();

        expect(debugOnProfilePaint, same(existingCallback));
        expect(coordinator.isPaintInstalled, isFalse);
        // But rebuild should be installed.
        expect(coordinator.isRebuildInstalled, isTrue);

        debugOnProfilePaint = null;
        return true;
      }());
    });

    test('partial install: paint installed when rebuild occupied', () {
      assert(() {
        debugOnRebuildDirtyWidget = (Element e, bool b) {};

        coordinator.install();

        expect(coordinator.isRebuildInstalled, isFalse);
        expect(coordinator.isPaintInstalled, isTrue);
        expect(coordinator.isInstalled, isTrue);

        debugOnRebuildDirtyWidget = null;
        return true;
      }());
    });

    test('uninstall resets to null when still owner', () {
      assert(() {
        coordinator.install();
        expect(debugOnRebuildDirtyWidget, isNotNull);
        expect(debugOnProfilePaint, isNotNull);

        coordinator.uninstall();
        expect(debugOnRebuildDirtyWidget, isNull);
        expect(debugOnProfilePaint, isNull);
        expect(coordinator.isInstalled, isFalse);
        return true;
      }());
    });

    test('uninstall skips reset when callback overwritten by third party', () {
      assert(() {
        coordinator.install();

        // Third party overwrites both slots.
        void thirdPartyRebuild(Element e, bool b) {}
        void thirdPartyPaint(dynamic ro) {}
        debugOnRebuildDirtyWidget = thirdPartyRebuild;
        debugOnProfilePaint = thirdPartyPaint;

        coordinator.uninstall();

        // Should NOT reset — third party owns them now.
        expect(debugOnRebuildDirtyWidget, same(thirdPartyRebuild));
        expect(debugOnProfilePaint, same(thirdPartyPaint));

        // Clean up.
        debugOnRebuildDirtyWidget = null;
        debugOnProfilePaint = null;
        return true;
      }());
    });

    test('snapshot returns accumulated counts with elapsed duration', () {
      var clockTime = DateTime(2025, 1, 1, 0, 0, 0);
      final coord = DebugInstrumentationCoordinator(
        clock: () => clockTime,
      );

      assert(() {
        coord.install();

        // Simulate rebuild callbacks.
        debugOnRebuildDirtyWidget?.call(
          _FakeElement('MyWidget'),
          true,
        );
        debugOnRebuildDirtyWidget?.call(
          _FakeElement('MyWidget'),
          true,
        );
        debugOnRebuildDirtyWidget?.call(
          _FakeElement('OtherWidget'),
          false,
        );

        // Simulate paint callback.
        debugOnProfilePaint?.call(_FakeRenderObject());
        debugOnProfilePaint?.call(_FakeRenderObject());

        // Advance clock by 500ms.
        clockTime = clockTime.add(const Duration(milliseconds: 500));

        final snap = coord.snapshot();

        // OtherWidget was called with builtOnce=false, so it's filtered out.
        expect(snap.rebuildCounts, {'MyWidget': 2});
        expect(snap.totalPaintCount, 2);
        expect(snap.elapsed, const Duration(milliseconds: 500));
        expect(snap.totalRebuilds, 2);

        coord.dispose();
        return true;
      }());
    });

    test('initial builds (builtOnce=false) are not counted', () {
      assert(() {
        coordinator.install();

        // All initial builds — should be filtered.
        debugOnRebuildDirtyWidget?.call(_FakeElement('Alpha'), false);
        debugOnRebuildDirtyWidget?.call(_FakeElement('Beta'), false);
        debugOnRebuildDirtyWidget?.call(_FakeElement('Gamma'), false);

        final snap1 = coordinator.snapshot();
        expect(snap1.rebuildCounts, isEmpty);
        expect(snap1.totalRebuilds, 0);

        // Now a real rebuild — should be counted.
        debugOnRebuildDirtyWidget?.call(_FakeElement('Alpha'), true);

        final snap2 = coordinator.snapshot();
        expect(snap2.rebuildCounts, {'Alpha': 1});
        expect(snap2.totalRebuilds, 1);

        coordinator.dispose();
        return true;
      }());
    });

    test('snapshot clears counts for next window', () {
      assert(() {
        coordinator.install();

        debugOnRebuildDirtyWidget?.call(_FakeElement('W'), true);
        debugOnProfilePaint?.call(_FakeRenderObject());

        final snap1 = coordinator.snapshot();
        expect(snap1.totalRebuilds, 1);
        expect(snap1.totalPaintCount, 1);

        // Second snapshot without any new callbacks.
        final snap2 = coordinator.snapshot();
        expect(snap2.totalRebuilds, 0);
        expect(snap2.totalPaintCount, 0);
        return true;
      }());
    });

    test('maxTrackedTypes caps new rebuild type entries', () {
      final coord = DebugInstrumentationCoordinator(maxTrackedTypes: 2);

      assert(() {
        coord.install();

        debugOnRebuildDirtyWidget?.call(_FakeElement('TypeA'), true);
        debugOnRebuildDirtyWidget?.call(_FakeElement('TypeB'), true);
        // Third type should be ignored (cap = 2).
        debugOnRebuildDirtyWidget?.call(_FakeElement('TypeC'), true);
        // But existing types can still increment.
        debugOnRebuildDirtyWidget?.call(_FakeElement('TypeA'), true);

        final snap = coord.snapshot();
        expect(snap.rebuildCounts, {'TypeA': 2, 'TypeB': 1});
        expect(snap.rebuildCounts.containsKey('TypeC'), isFalse);

        coord.dispose();
        return true;
      }());
    });

    test('dispose calls uninstall', () {
      assert(() {
        coordinator.install();
        expect(coordinator.isInstalled, isTrue);

        coordinator.dispose();
        expect(coordinator.isInstalled, isFalse);
        expect(debugOnRebuildDirtyWidget, isNull);
        expect(debugOnProfilePaint, isNull);
        return true;
      }());
    });

    test('per-widget paint counts from debugCreator', () {
      var clockTime = DateTime(2025, 1, 1, 0, 0, 0);
      final coord = DebugInstrumentationCoordinator(
        clock: () => clockTime,
      );

      assert(() {
        coord.install();

        final element = _FakeElement('MyPaintWidget');
        final ro = _FakeRenderObjectWithCreator(element);

        debugOnProfilePaint?.call(ro);
        debugOnProfilePaint?.call(ro);
        debugOnProfilePaint?.call(_FakeRenderObject()); // no debugCreator

        clockTime = clockTime.add(const Duration(seconds: 1));
        final snap = coord.snapshot();

        expect(snap.paintCounts, {'MyPaintWidget': 2});
        expect(snap.totalPaintCount, 3); // aggregate includes all
        expect(snap.totalPaintsFromTypes, 2);

        coord.dispose();
        return true;
      }());
    });

    test('maxTrackedTypes caps new paint type entries', () {
      final coord = DebugInstrumentationCoordinator(maxTrackedTypes: 2);

      assert(() {
        coord.install();

        final roA = _FakeRenderObjectWithCreator(_FakeElement('PaintA'));
        final roB = _FakeRenderObjectWithCreator(_FakeElement('PaintB'));
        final roC = _FakeRenderObjectWithCreator(_FakeElement('PaintC'));

        debugOnProfilePaint?.call(roA);
        debugOnProfilePaint?.call(roB);
        debugOnProfilePaint?.call(roC); // cap = 2, should be ignored
        debugOnProfilePaint?.call(roA); // existing type, still increments

        final snap = coord.snapshot();
        expect(snap.paintCounts, {'PaintA': 2, 'PaintB': 1});
        expect(snap.paintCounts.containsKey('PaintC'), isFalse);
        expect(snap.totalPaintCount, 4); // aggregate counts all

        coord.dispose();
        return true;
      }());
    });

    test('snapshot clears paintCounts for next window', () {
      assert(() {
        coordinator.install();

        final ro = _FakeRenderObjectWithCreator(_FakeElement('W'));
        debugOnProfilePaint?.call(ro);

        final snap1 = coordinator.snapshot();
        expect(snap1.paintCounts, {'W': 1});

        final snap2 = coordinator.snapshot();
        expect(snap2.paintCounts, isEmpty);

        return true;
      }());
    });

    test('user callback in rebuild slot → coordinator installed → both fire',
        () {
      assert(() {
        var userRebuildCount = 0;
        debugOnRebuildDirtyWidget = (Element e, bool b) {
          userRebuildCount++;
        };

        coordinator.install();

        // Coordinator should have skipped rebuild (occupied) but installed
        // paint.
        expect(coordinator.isRebuildInstalled, isFalse);
        expect(coordinator.isPaintInstalled, isTrue);

        // Trigger user's rebuild callback.
        debugOnRebuildDirtyWidget?.call(_FakeElement('W'), true);
        expect(userRebuildCount, 1);

        // Trigger coordinator's paint callback.
        final ro = _FakeRenderObjectWithCreator(_FakeElement('W'));
        debugOnProfilePaint?.call(ro);

        final snap = coordinator.snapshot();
        expect(snap.paintCounts, {'W': 1});

        debugOnRebuildDirtyWidget = null;
        return true;
      }());
    });

    test('coordinator disposed → user callback still works', () {
      assert(() {
        var userRebuildCount = 0;
        void userCallback(Element e, bool b) {
          userRebuildCount++;
        }

        debugOnRebuildDirtyWidget = userCallback;
        coordinator.install();

        // Coordinator owns paint, user owns rebuild.
        expect(coordinator.isPaintInstalled, isTrue);

        coordinator.dispose();

        // Paint slot should be cleaned up.
        expect(debugOnProfilePaint, isNull);
        // User callback must survive — coordinator never owned it.
        expect(debugOnRebuildDirtyWidget, same(userCallback));
        debugOnRebuildDirtyWidget?.call(_FakeElement('W'), true);
        expect(userRebuildCount, 1);

        debugOnRebuildDirtyWidget = null;
        return true;
      }());
    });

    test('restore-order: nested test installs', () {
      assert(() {
        coordinator.install();
        expect(coordinator.isPaintInstalled, isTrue);

        // External code overwrites paint slot after coordinator installed.
        void externalCallback(dynamic ro) {}
        debugOnProfilePaint = externalCallback;

        // Coordinator uninstall sees identity mismatch on paint, leaves it.
        coordinator.uninstall();

        expect(debugOnProfilePaint, same(externalCallback));
        expect(debugOnRebuildDirtyWidget, isNull); // coordinator owned this

        debugOnProfilePaint = null;
        return true;
      }());
    });

    test('selective install: installRebuild=false', () {
      assert(() {
        final coord = DebugInstrumentationCoordinator(
          installRebuild: false,
        );
        coord.install();

        // Rebuild slot should remain empty even though it's available.
        expect(debugOnRebuildDirtyWidget, isNull);
        expect(coord.isRebuildInstalled, isFalse);
        // Paint should be installed.
        expect(debugOnProfilePaint, isNotNull);
        expect(coord.isPaintInstalled, isTrue);
        expect(coord.isInstalled, isTrue);

        coord.dispose();
        return true;
      }());
    });

    test('selective install: installPaint=false', () {
      assert(() {
        final coord = DebugInstrumentationCoordinator(
          installPaint: false,
        );
        coord.install();

        // Paint slot should remain empty.
        expect(debugOnProfilePaint, isNull);
        expect(coord.isPaintInstalled, isFalse);
        // Rebuild should be installed.
        expect(debugOnRebuildDirtyWidget, isNotNull);
        expect(coord.isRebuildInstalled, isTrue);
        expect(coord.isInstalled, isTrue);

        coord.dispose();
        return true;
      }());
    });
  });

  group('DebugSnapshot', () {
    test('totalRebuilds sums all values', () {
      const snap = DebugSnapshot(
        rebuildCounts: {'A': 5, 'B': 3, 'C': 2},
        totalPaintCount: 0,
        elapsed: Duration(seconds: 1),
      );
      expect(snap.totalRebuilds, 10);
    });

    test('rebuildsPerSecond normalizes by elapsed using microseconds', () {
      const snap = DebugSnapshot(
        rebuildCounts: {'A': 30},
        totalPaintCount: 0,
        elapsed: Duration(seconds: 1),
      );
      expect(snap.rebuildsPerSecond('A'), 30.0);
      expect(snap.rebuildsPerSecond('Unknown'), 0.0);
    });

    test('paintsPerSecond normalizes by elapsed using microseconds', () {
      const snap = DebugSnapshot(
        rebuildCounts: {},
        totalPaintCount: 60,
        elapsed: Duration(seconds: 1),
      );
      expect(snap.paintsPerSecond, 60.0);
    });

    test('paintsPerSecondForType normalizes by elapsed', () {
      const snap = DebugSnapshot(
        rebuildCounts: {},
        totalPaintCount: 100,
        paintCounts: {'CustomPaint': 40, 'AnimatedBuilder': 20},
        elapsed: Duration(seconds: 1),
      );
      expect(snap.paintsPerSecondForType('CustomPaint'), 40.0);
      expect(snap.paintsPerSecondForType('AnimatedBuilder'), 20.0);
      expect(snap.paintsPerSecondForType('Unknown'), 0.0);
      expect(snap.totalPaintsFromTypes, 60);
    });

    test('zero elapsed returns 0 rates (no division by zero)', () {
      const snap = DebugSnapshot(
        rebuildCounts: {'A': 10},
        totalPaintCount: 5,
        paintCounts: {'B': 3},
        elapsed: Duration.zero,
      );
      expect(snap.rebuildsPerSecond('A'), 0.0);
      expect(snap.paintsPerSecond, 0.0);
      expect(snap.paintsPerSecondForType('B'), 0.0);
    });

    test('sub-second elapsed produces correct rates (no int truncation)', () {
      const snap = DebugSnapshot(
        rebuildCounts: {'A': 10},
        totalPaintCount: 20,
        elapsed: Duration(milliseconds: 500),
      );
      // 10 rebuilds in 0.5s = 20/sec
      expect(snap.rebuildsPerSecond('A'), closeTo(20.0, 0.01));
      // 20 paints in 0.5s = 40/sec
      expect(snap.paintsPerSecond, closeTo(40.0, 0.01));
    });
  });
}

// -- Test helpers --

/// Minimal fake Element that returns a widget with the given runtimeType name.
class _FakeElement extends Element {
  _FakeElement(String typeName) : super(_FakeWidget(typeName));

  @override
  bool get debugDoingBuild => false;

  @override
  void performRebuild() {
    super.performRebuild();
  }
}

class _FakeWidget extends Widget {
  const _FakeWidget(this._typeName);

  final String _typeName;

  @override
  Element createElement() => throw UnimplementedError();

  @override
  String toString({DiagnosticLevel minLevel = DiagnosticLevel.info}) =>
      _typeName;

  @override
  Type get runtimeType => _FakeType(_typeName);
}

/// A Type whose toString returns the desired name.
class _FakeType implements Type {
  const _FakeType(this._name);
  final String _name;

  @override
  String toString() => _name;
}

class _FakeRenderObject extends RenderObject {
  @override
  void debugAssertDoesMeetConstraints() {}

  @override
  Rect get paintBounds => Rect.zero;

  @override
  void performLayout() {}

  @override
  void performResize() {}

  @override
  Rect get semanticBounds => Rect.zero;
}

/// Fake RenderObject with debugCreator set to a DebugCreator wrapping
/// the given Element, simulating the widget framework's behavior.
class _FakeRenderObjectWithCreator extends _FakeRenderObject {
  _FakeRenderObjectWithCreator(Element element) {
    assert(() {
      debugCreator = DebugCreator(element);
      return true;
    }());
  }
}
