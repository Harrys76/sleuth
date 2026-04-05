import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../utils/widget_location.dart';
import 'debug_snapshot.dart';

/// Manages debug-only `debugOnRebuildDirtyWidget` and `debugOnProfilePaint`
/// callbacks for per-widget rebuild and paint attribution.
///
/// All callback installation and access is inside `assert()` blocks — the
/// coordinator is never created in profile/release builds.
///
/// **Install policy**: Only installs when the global callback slot is `null`.
/// If DevTools (WidgetInspectorService) already occupies a slot, that slot is
/// skipped with a log warning. Each slot is tracked independently, so partial
/// install (e.g. paint only) is supported.
class DebugInstrumentationCoordinator {
  DebugInstrumentationCoordinator({
    int maxTrackedTypes = 200,
    DateTime Function()? clock,
    bool installRebuild = true,
    bool installPaint = true,
  })  : _maxTrackedTypes = maxTrackedTypes,
        _clock = clock ?? DateTime.now,
        _installRebuild = installRebuild,
        _installPaint = installPaint {
    // Create bound method references once so == checks work on uninstall.
    _onRebuildDirtyWidget = _handleRebuildDirtyWidget;
    _onProfilePaint = _handleProfilePaint;
  }

  final int _maxTrackedTypes;
  final DateTime Function() _clock;
  final bool _installRebuild;
  final bool _installPaint;

  late final void Function(Element, bool) _onRebuildDirtyWidget;
  late final void Function(RenderObject) _onProfilePaint;

  final Map<String, int> _rebuildCounts = {};
  final Map<String, int> _paintCounts = {};
  final Map<String, String> _ancestorChains = {};
  int _paintCount = 0;

  bool _rebuildInstalled = false;
  bool _paintInstalled = false;
  DateTime _lastSnapshotTime = DateTime.now();

  /// Whether at least one callback slot is installed.
  bool get isInstalled => _rebuildInstalled || _paintInstalled;

  /// Whether the rebuild callback specifically is installed.
  bool get isRebuildInstalled => _rebuildInstalled;

  /// Whether the paint callback specifically is installed.
  bool get isPaintInstalled => _paintInstalled;

  /// Install callbacks into available global slots.
  ///
  /// Each slot is checked independently — if one is occupied (e.g. by
  /// DevTools), the other can still be installed.
  void install() {
    assert(() {
      if (_installRebuild && !_rebuildInstalled) {
        if (debugOnRebuildDirtyWidget != null) {
          debugPrint('Sleuth: debugOnRebuildDirtyWidget already set '
              '(likely DevTools). Skipping rebuild callback.');
        } else {
          debugOnRebuildDirtyWidget = _onRebuildDirtyWidget;
          _rebuildInstalled = true;
        }
      }
      if (_installPaint && !_paintInstalled) {
        if (debugOnProfilePaint != null) {
          debugPrint('Sleuth: debugOnProfilePaint already set. '
              'Skipping paint callback.');
        } else {
          debugOnProfilePaint = _onProfilePaint;
          _paintInstalled = true;
        }
      }
      _lastSnapshotTime = _clock();
      return true;
    }());
  }

  /// Uninstall callbacks, restoring slots to `null`.
  ///
  /// Only resets a slot if we still own it (the global still points to our
  /// handler). If a third party overwrote after us, we leave their callback.
  void uninstall() {
    assert(() {
      if (_rebuildInstalled) {
        if (debugOnRebuildDirtyWidget == _onRebuildDirtyWidget) {
          debugOnRebuildDirtyWidget = null;
        }
        _rebuildInstalled = false;
      }
      if (_paintInstalled) {
        if (debugOnProfilePaint == _onProfilePaint) {
          debugOnProfilePaint = null;
        }
        _paintInstalled = false;
      }
      return true;
    }());
  }

  /// Returns accumulated counts since the last snapshot and resets counters.
  ///
  /// The returned [DebugSnapshot.elapsed] is the actual wall-clock time since
  /// the previous snapshot — detectors must use it to normalize to per-second
  /// rates.
  DebugSnapshot snapshot() {
    final now = _clock();
    final elapsed = now.difference(_lastSnapshotTime);
    _lastSnapshotTime = now;

    final result = DebugSnapshot(
      rebuildCounts: Map<String, int>.of(_rebuildCounts),
      paintCounts: Map<String, int>.of(_paintCounts),
      totalPaintCount: _paintCount,
      elapsed: elapsed,
      ancestorChains: Map<String, String>.of(_ancestorChains),
    );
    _rebuildCounts.clear();
    _paintCounts.clear();
    _ancestorChains.clear();
    _paintCount = 0;
    return result;
  }

  /// Uninstalls callbacks and clears state.
  void dispose() {
    uninstall();
    _rebuildCounts.clear();
    _paintCounts.clear();
    _ancestorChains.clear();
    _paintCount = 0;
  }

  void _handleRebuildDirtyWidget(Element element, bool builtOnce) {
    if (!builtOnce) return; // Skip initial builds — only count actual rebuilds
    final typeName = element.widget.runtimeType.toString();
    if (_rebuildCounts.length >= _maxTrackedTypes &&
        !_rebuildCounts.containsKey(typeName)) {
      return; // Cap reached, ignore new types
    }
    _rebuildCounts[typeName] = (_rebuildCounts[typeName] ?? 0) + 1;
    if (!_ancestorChains.containsKey(typeName)) {
      try {
        _ancestorChains[typeName] = buildAncestorChain(element);
      } catch (e, s) {
        // Element may be deactivated — skip chain capture.
        assert(() {
          debugPrint('Sleuth: rebuild ancestor chain failed: $e\n$s');
          return true;
        }());
      }
    }
  }

  void _handleProfilePaint(RenderObject renderObject) {
    _paintCount++;
    final creator = renderObject.debugCreator;
    if (creator is DebugCreator) {
      final typeName = creator.element.widget.runtimeType.toString();
      if (_paintCounts.length >= _maxTrackedTypes &&
          !_paintCounts.containsKey(typeName)) {
        return; // Cap reached, ignore new types
      }
      _paintCounts[typeName] = (_paintCounts[typeName] ?? 0) + 1;
      if (!_ancestorChains.containsKey(typeName)) {
        try {
          _ancestorChains[typeName] = buildAncestorChain(creator.element);
        } catch (e, s) {
          // Element may be deactivated — skip chain capture.
          assert(() {
            debugPrint('Sleuth: paint ancestor chain failed: $e\n$s');
            return true;
          }());
        }
      }
    }
  }
}
