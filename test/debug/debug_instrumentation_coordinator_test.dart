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

        // Simulate rebuild callbacks. First observation of each element is
        // the initial build (skipped by the Expando guard), every subsequent
        // observation is a real rebuild.
        final myWidget = _FakeElement('MyWidget');
        debugOnRebuildDirtyWidget?.call(myWidget, false); // initial — skipped
        debugOnRebuildDirtyWidget?.call(myWidget, true); // rebuild — counted
        debugOnRebuildDirtyWidget?.call(myWidget, true); // rebuild — counted

        final otherWidget = _FakeElement('OtherWidget');
        debugOnRebuildDirtyWidget?.call(
            otherWidget, false); // initial — skipped

        // Simulate paint callback.
        debugOnProfilePaint?.call(_FakeRenderObject());
        debugOnProfilePaint?.call(_FakeRenderObject());

        // Advance clock by 500ms.
        clockTime = clockTime.add(const Duration(milliseconds: 500));

        final snap = coord.snapshot();

        // OtherWidget is still on its first observation — initial build.
        expect(snap.rebuildCounts, {'MyWidget': 2});
        expect(snap.totalPaintCount, 2);
        expect(snap.elapsed, const Duration(milliseconds: 500));
        expect(snap.totalRebuilds, 2);

        coord.dispose();
        return true;
      }());
    });

    test('first observation of each element is treated as initial build', () {
      // The Expando-based guard replaces the unreliable framework `builtOnce`
      // parameter — see DebugInstrumentationCoordinator._elementSeen for why.
      // This test asserts the guard's semantics directly: only the 2nd+
      // observation of a given element counts as a rebuild.
      assert(() {
        coordinator.install();

        // Three brand-new elements: all first-observation, all filtered out
        // regardless of what framework passes as `builtOnce`.
        debugOnRebuildDirtyWidget?.call(_FakeElement('Alpha'), false);
        debugOnRebuildDirtyWidget?.call(_FakeElement('Beta'), true);
        debugOnRebuildDirtyWidget?.call(_FakeElement('Gamma'), false);

        final snap1 = coordinator.snapshot();
        expect(snap1.rebuildCounts, isEmpty);
        expect(snap1.totalRebuilds, 0);

        // A real rebuild: prime + rebuild on the same element.
        final alpha = _FakeElement('Alpha');
        debugOnRebuildDirtyWidget?.call(alpha, true); // initial — skipped
        debugOnRebuildDirtyWidget?.call(alpha, true); // rebuild — counted

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

        final w = _FakeElement('W');
        debugOnRebuildDirtyWidget?.call(w, true); // initial — skipped
        debugOnRebuildDirtyWidget?.call(w, true); // rebuild — counted
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

        // Prime each element so the Expando guard lets subsequent calls count.
        final a = _FakeElement('TypeA');
        final b = _FakeElement('TypeB');
        final c = _FakeElement('TypeC');
        debugOnRebuildDirtyWidget?.call(a, true); // prime
        debugOnRebuildDirtyWidget?.call(b, true); // prime
        debugOnRebuildDirtyWidget?.call(c, true); // prime

        // Real rebuilds.
        debugOnRebuildDirtyWidget?.call(a, true); // TypeA counted
        debugOnRebuildDirtyWidget?.call(b, true); // TypeB counted
        // Third TYPE would push the map past the cap — must be ignored.
        debugOnRebuildDirtyWidget?.call(c, true);
        // But existing types can still increment.
        debugOnRebuildDirtyWidget?.call(a, true); // TypeA counted again

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

    test('type name cache avoids repeated toString allocations', () {
      var clockTime = DateTime(2025, 1, 1, 0, 0, 0);
      final coord = DebugInstrumentationCoordinator(
        clock: () => clockTime,
      );

      assert(() {
        coord.install();

        // Fire 100 rebuild callbacks on 3 reused elements (prime + rebuilds).
        // Using long-lived elements means the Expando guard skips only the
        // first observation per element — subsequent calls all count.
        final a = _FakeElement('WidgetA');
        final b = _FakeElement('WidgetB');
        final c = _FakeElement('WidgetC');
        // Prime.
        debugOnRebuildDirtyWidget?.call(a, true);
        debugOnRebuildDirtyWidget?.call(b, true);
        debugOnRebuildDirtyWidget?.call(c, true);
        final elements = [a, b, c];
        for (int i = 0; i < 100; i++) {
          debugOnRebuildDirtyWidget?.call(elements[i % 3], true);
        }

        // Fire paint callbacks with 2 unique types.
        for (int i = 0; i < 50; i++) {
          final types = ['PaintX', 'PaintY'];
          debugOnProfilePaint?.call(
            _FakeRenderObjectWithCreator(
              _FakeElement(types[i % 2]),
            ),
          );
        }

        clockTime = clockTime.add(const Duration(seconds: 1));
        final snap = coord.snapshot();

        // Verify snapshot data is correct despite caching.
        expect(snap.rebuildCounts, {
          'WidgetA': 34,
          'WidgetB': 33,
          'WidgetC': 33,
        });
        expect(snap.paintCounts, {'PaintX': 25, 'PaintY': 25});
        expect(snap.totalPaintCount, 50);

        // After dispose, cache should be cleared (no leak).
        coord.dispose();
        return true;
      }());
    });

    test('type name cache persists across snapshot windows', () {
      var clockTime = DateTime(2025, 1, 1, 0, 0, 0);
      final coord = DebugInstrumentationCoordinator(
        clock: () => clockTime,
      );

      assert(() {
        coord.install();

        // Window 1: prime + one rebuild per type.
        final foo = _FakeElement('Foo');
        final bar = _FakeElement('Bar');
        debugOnRebuildDirtyWidget?.call(foo, true); // prime
        debugOnRebuildDirtyWidget?.call(bar, true); // prime
        debugOnRebuildDirtyWidget?.call(foo, true); // Foo counted
        debugOnRebuildDirtyWidget?.call(bar, true); // Bar counted
        clockTime = clockTime.add(const Duration(seconds: 1));
        final snap1 = coord.snapshot();
        expect(snap1.rebuildCounts, {'Foo': 1, 'Bar': 1});

        // Window 2: same elements — no re-priming needed.
        debugOnRebuildDirtyWidget?.call(foo, true); // Foo counted
        debugOnRebuildDirtyWidget?.call(bar, true); // Bar counted
        debugOnRebuildDirtyWidget?.call(foo, true); // Foo counted
        clockTime = clockTime.add(const Duration(seconds: 1));
        final snap2 = coord.snapshot();
        expect(snap2.rebuildCounts, {'Foo': 2, 'Bar': 1});

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
