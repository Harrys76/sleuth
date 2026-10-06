// IDE analyzer false-positive: dart:core RegExp uses @Deprecated.implement
// (fires only on subclassing). Remove when analyzer-server recognizes the
// implement-only kind.
// ignore_for_file: deprecated_member_use

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../utils/animation_owner_names.dart';
import '../utils/framework_painters.dart';
import '../utils/overlay_ownership.dart';
import '../utils/widget_location.dart';
import 'debug_snapshot.dart';

/// Which installation path a coordinator is currently on.
///
/// Debug and profile are mutually exclusive: exactly one source
/// populates [DebugSnapshot.rebuildCounts] per coordinator lifetime.
enum _InstalledMode { none, debug, profile }

/// Manages per-widget rebuild/paint attribution via two mutually-exclusive
/// paths:
///
/// - **Debug mode** uses `debugOnRebuildDirtyWidget` + `debugOnProfilePaint`
///   global callbacks. Counts actual rebuilds only (initial builds are
///   excluded via the `builtOnce` flag). Paints feed two records: every
///   widget that takes part in a repaint (`paintCounts`) and, per frame,
///   the likely origin of each layer's repaint (`paintOrigins`).
/// - **Profile mode** uses `FlutterTimeline.debugCollect()` drained on every
///   scan. Counts include initial widget inflations as well as rebuilds
///   because the framework emits the same `FlutterTimeline.startSync` from
///   `_tryRebuild`, `updateChild`, AND `inflateWidget`. The rebuild stats
///   panel, its drilldown page and the config doc disclose this divergence.
///
/// Install policy (debug path): only installs when the global callback slot
/// is `null`. If DevTools (WidgetInspectorService) already occupies a slot,
/// that slot is skipped with a log warning. Each slot is tracked
/// independently, so partial install (e.g. paint only) is supported.
///
/// Install policy (profile path): refuses to install if
/// `FlutterTimeline.debugCollectionEnabled` is already `true` — DevTools or
/// another Sleuth instance owns the buffer and we must not stomp it. See
/// [installProfileMode].
class DebugInstrumentationCoordinator {
  DebugInstrumentationCoordinator({
    int maxTrackedTypes = 200,
    DateTime Function()? clock,
    bool installRebuild = true,
    bool installPaint = true,
    bool userWidgetsOnly = true,
  }) : _maxTrackedTypes = maxTrackedTypes,
       _clock = clock ?? DateTime.now,
       _installRebuild = installRebuild,
       _installPaint = installPaint,
       _userWidgetsOnly =
           userWidgetsOnly &&
           WidgetInspectorService.instance.isWidgetCreationTracked() {
    // Create bound method references once so == checks work on uninstall.
    _onRebuildDirtyWidget = _handleRebuildDirtyWidget;
    _onProfilePaint = _handleProfilePaint;
  }

  final int _maxTrackedTypes;
  final DateTime Function() _clock;
  final bool _installRebuild;
  final bool _installPaint;

  /// Whether per-widget counts keep only user widgets: widgets created
  /// outside the Flutter SDK, as the framework's own
  /// `debugIsWidgetLocalCreation` decides (only the project's files once
  /// DevTools has set its root directories). Framework widgets built
  /// inside them (`RichText` under `Text`, `_InkFeatures` under
  /// `InkWell`, a scaffold's layout) rebuild and repaint with the widget
  /// that builds them and would each report on their own. Needs creation
  /// tracking, which debug builds have; without it every widget counts.
  final bool _userWidgetsOnly;

  bool _isUserWidget(Widget widget) =>
      !_userWidgetsOnly || debugIsWidgetLocalCreation(widget);

  late final void Function(Element, bool) _onRebuildDirtyWidget;
  late final void Function(RenderObject) _onProfilePaint;

  final Map<String, int> _rebuildCounts = {};
  final Map<String, int> _paintCounts = {};
  final Map<String, String> _ancestorChains = {};
  final Map<String, int> _forcedRebuildsByRoot = {};
  bool _rebuildTypesCapped = false;
  bool _paintTypesCapped = false;
  int _paintCount = 0;

  /// The self-dirtied elements whose builds are running, outermost first,
  /// as (user type or null, depth). Callbacks arrive in tree pre-order
  /// inside a build, so an entry at or below a callback's depth is not its
  /// ancestor and is dropped. A forced rebuild is credited to the
  /// innermost entry; a framework widget's entry (null type) credits
  /// nothing. Cleared when a new frame starts.
  final List<({String? type, int depth})> _buildRoots = [];
  int? _buildRootsFrame;

  /// Frame (system time stamp in microseconds) in which each
  /// rebuild-driven animation owner last rebuilt itself. See
  /// [rebuildDrivenOwnerNames].
  final Expando<int> _ownerRebuildFrame = Expando<int>('SleuthOwnerRebuild');

  /// Per-widget-type **animation-owned** paint counts. A subset of
  /// [_paintCounts]: every increment here was also counted there.
  ///
  /// Computed per-paint via [isAnimationOwnedPaint] so that polymorphic-key
  /// collisions on [_paintCounts] (two `CustomPaint` widgets with different
  /// owners) get correct attribution: each paint event is judged on its
  /// live element, not on a cached chain that may belong to a different
  /// widget instance.
  final Map<String, int> _animationOwnedPaintCounts = {};

  /// Aggregate count of paints attributed to an animation owner. Drives the
  /// aggregate-residual gate in `RepaintDetector` (Gate C):
  /// `residual = totalPaintCount - totalAnimationOwnedPaintCount`.
  int _totalAnimationOwnedPaintCount = 0;

  /// Tracks which `Element`s we've already observed through the rebuild
  /// callback at least once. The first observation of an element is its
  /// initial build — we mark it and drop the count — and every subsequent
  /// observation is a real setState/parent rebuild that the detectors care
  /// about.
  ///
  /// Why not use the framework's `builtOnce` parameter? The framework passes
  /// `_debugBuiltOnce`, a field that is ONLY flipped to `true` inside the
  /// `if (debugPrintRebuildDirtyWidgets)` branch of
  /// `Element.rebuild()` (see `flutter/src/widgets/framework.dart` around
  /// line 5509–5514). When the app hasn't enabled rebuild-print debugging
  /// — the default in widget tests and in production — that field stays
  /// `false` for the entire element lifetime, so every call to the
  /// callback passes `builtOnce: false` and the detector would never count
  /// anything. That is exactly the bug the real-widget-tree rebuild test
  /// catches, and the reason we cannot trust that parameter.
  ///
  /// [Expando] key-weakly references the element, so entries are collected
  /// when the element is reclaimed. No manual cleanup required.
  final Expando<bool> _elementSeen = Expando<bool>('SleuthRebuildSeen');

  /// Per-callback type name cache. Avoids `runtimeType.toString()` string
  /// allocation on every rebuild/paint callback (~1,000/sec when active).
  /// Not cleared between snapshots — persists for maximum hit rate.
  /// Bounded naturally by unique widget types in the app (~50–200).
  final Map<Type, String> _typeNames = {};

  String _typeName(Type type) => _typeNames[type] ??= type.toString();

  /// Ancestor-derived paint attribution per painting [Element]: the
  /// ancestor chain and whether an animation owner sits above the
  /// element. A repainting widget paints every frame from the same
  /// element; rebuilding the chain (string joins, source-location
  /// lookups) and walking 16 ancestors each time was the dominant
  /// debug-mode paint cost. Entries are stamped with every ancestor the
  /// chain and the ownership walk read, the element's depth, and
  /// [_paintAttributionEpoch]; a different or unmounted ancestor at any
  /// stamped position, any other change, or an unmounted element
  /// recomputes. Weakly keyed, so entries die with their elements.
  final Expando<_PaintAttribution> _paintAttribution =
      Expando<_PaintAttribution>('SleuthPaintAttribution');

  /// Bumped by [invalidatePaintAttribution]; stale stamps recompute.
  int _paintAttributionEpoch = 0;

  int _paintAttributionComputes = 0;

  /// Number of paint attributions computed rather than served from the
  /// per-element cache.
  @visibleForTesting
  int get paintAttributionComputeCount => _paintAttributionComputes;

  /// Drops every cached paint attribution (hot reload can move widgets
  /// without replacing their elements' parents).
  void invalidatePaintAttribution() => _paintAttributionEpoch++;

  /// Most instances of one widget type counted as likely repaint origins
  /// in a window; further instances of the type are not counted.
  @visibleForTesting
  static const int maxOriginInstancesPerType = 128;

  /// Likely repaint origins credited this window, per user widget type:
  /// for each instance (the credited element), the frames in which it was
  /// an origin that no animation owner drove.
  final Map<String, Map<Element, int>> _originCounts = {};

  /// Frames per user widget type in which an instance was a likely origin
  /// driven by an animation owner.
  final Map<String, int> _ownedOriginCounts = {};
  bool _originTypesCapped = false;

  // The frame whose paints the origin pass is recording. A frame closes
  // after its paint phase (a post-frame callback), when the frame stamp
  // changes, or at a snapshot, whichever comes first.
  bool _originFrameOpen = false;
  int? _originFrameStamp;
  bool _originFrameEndScheduled = false;
  late final FrameCallback _onOriginFrameEnd = _handleOriginFrameEnd;

  /// Render objects painted this frame while marked as needing paint,
  /// with whether an animation owner drove the paint (null when the hook
  /// did not judge it).
  final Map<RenderObject, bool?> _frameDirty = {};

  /// Render objects with a child painted this frame while marked as
  /// needing paint: not the deepest marked node of their layer.
  final Set<RenderObject> _frameReached = {};

  /// Repaint boundaries that painted their children this frame without a
  /// hook call of their own: layer roots that `flushPaint` repainted.
  final Set<RenderObject> _frameRoots = {};

  /// Elements credited this frame, so an instance counts once per frame.
  final Set<Element> _frameCredited = {};

  bool _rebuildInstalled = false;
  bool _paintInstalled = false;
  DateTime _lastSnapshotTime = DateTime.now();

  // Profile-mode state.
  _InstalledMode _installedMode = _InstalledMode.none;
  bool? _prevDebugCollectionEnabled;

  /// Whether at least one callback slot is installed.
  bool get isInstalled => _rebuildInstalled || _paintInstalled;

  /// Whether the rebuild callback specifically is installed.
  bool get isRebuildInstalled => _rebuildInstalled;

  /// Whether the paint callback specifically is installed.
  bool get isPaintInstalled => _paintInstalled;

  /// Whether the profile-mode `FlutterTimeline` drain path is active.
  bool get isProfileModeInstalled => _installedMode == _InstalledMode.profile;

  /// Install callbacks into available global slots (debug-mode path).
  ///
  /// Each slot is checked independently — if one is occupied (e.g. by
  /// DevTools), the other can still be installed.
  void install() {
    assert(() {
      if (_installRebuild && !_rebuildInstalled) {
        if (debugOnRebuildDirtyWidget != null) {
          debugPrint(
            'Sleuth: debugOnRebuildDirtyWidget already set '
            '(likely DevTools). Skipping rebuild callback.',
          );
        } else {
          debugOnRebuildDirtyWidget = _onRebuildDirtyWidget;
          _rebuildInstalled = true;
        }
      }
      if (_installPaint && !_paintInstalled) {
        if (debugOnProfilePaint != null) {
          debugPrint(
            'Sleuth: debugOnProfilePaint already set. '
            'Skipping paint callback.',
          );
        } else {
          debugOnProfilePaint = _onProfilePaint;
          _paintInstalled = true;
        }
      }
      if (_rebuildInstalled || _paintInstalled) {
        _installedMode = _InstalledMode.debug;
      }
      _lastSnapshotTime = _clock();
      return true;
    }());
  }

  /// Seed the element-seen set with every element currently mounted in
  /// [root]'s subtree, so the NEXT rebuild-callback observation for each
  /// of them is counted as a rebuild instead of consumed by the Expando
  /// guard as the initial-build placeholder.
  ///
  /// In production Sleuth installs the coordinator before any user
  /// widgets mount, so the initial-build guard lines up naturally with
  /// actual inflations. In tests that pump a widget tree BEFORE
  /// installing the coordinator (a natural pattern for `flutter_test`),
  /// the first rebuild per element would otherwise be silently lost.
  /// Calling this after `install()` with the scan-root element restores
  /// the 1:1 rebuild-to-count accounting the detectors expect.
  ///
  /// Debug-path only — the profile-mode drain doesn't use the Expando.
  void primeExistingElements(Element root) {
    assert(() {
      void visit(Element e) {
        _elementSeen[e] = true;
        e.visitChildren(visit);
      }

      visit(root);
      return true;
    }());
  }

  /// Uninstall debug-mode callbacks, restoring slots to `null`.
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
      if (_installedMode == _InstalledMode.debug) {
        _installedMode = _InstalledMode.none;
      }
      return true;
    }());
  }

  /// Install the profile-mode `FlutterTimeline.debugCollect()` drain path.
  ///
  /// Precondition: caller must be in profile mode (asserted via
  /// `!kReleaseMode` — release throws a StateError on `debugCollectionEnabled`).
  /// Mutually exclusive with [install]: calling both is a programming error
  /// and the existing [_installedMode] guard throws.
  ///
  /// Policy:
  /// 1. Assert `!kReleaseMode`.
  /// 2. Refuse if already installed on either path.
  /// 3. **Refuse if `FlutterTimeline.debugCollectionEnabled` is already
  ///    `true`** — DevTools or another Sleuth instance owns the buffer. We
  ///    must not stomp their save/restore, whether the other owner is
  ///    DevTools or a second Sleuth instance.
  /// 4. Save the prior value, flip to `true`, mark `_installedMode.profile`.
  ///
  /// Setting `debugCollectionEnabled = true` when it was previously `false`
  /// implicitly calls `FlutterTimeline.debugReset()` inside the framework, so
  /// the buffer starts empty — no need for an extra reset here.
  void installProfileMode() {
    assert(
      !kReleaseMode,
      'installProfileMode is not supported in release mode',
    );
    if (_installedMode != _InstalledMode.none) {
      // Double-install no-op (idempotent), because controller wiring may
      // call install twice across hot-restart.
      return;
    }
    if (FlutterTimeline.debugCollectionEnabled) {
      throw StateError(
        'Sleuth: FlutterTimeline.debugCollectionEnabled is already true. '
        'Another consumer (DevTools or a second Sleuth instance) owns the '
        'buffer. Refusing to install the profile-mode drain.',
      );
    }
    _prevDebugCollectionEnabled = FlutterTimeline.debugCollectionEnabled;
    FlutterTimeline.debugCollectionEnabled = true;
    _installedMode = _InstalledMode.profile;
    _lastSnapshotTime = _clock();
  }

  /// Uninstall the profile-mode drain path and restore the prior
  /// `FlutterTimeline.debugCollectionEnabled` value.
  ///
  /// Safe to call when not installed (no-op). Calls `debugReset()` to drop
  /// any stale events that accumulated between the last drain and the
  /// uninstall, so a subsequent reinstall starts clean.
  void uninstallProfileMode() {
    if (_installedMode != _InstalledMode.profile) return;
    // Drop any events accumulated since the last drain so the next
    // installation (or DevTools after us) starts with an empty buffer.
    // Must happen BEFORE we flip the flag — `debugCollect` throws when
    // collection is disabled.
    try {
      FlutterTimeline.debugCollect();
    } catch (_) {
      // debugCollect throws in release or when collection is disabled.
      // Either way there's nothing to clean up.
    }
    if (_prevDebugCollectionEnabled != null) {
      FlutterTimeline.debugCollectionEnabled = _prevDebugCollectionEnabled!;
      _prevDebugCollectionEnabled = null;
    }
    _installedMode = _InstalledMode.none;
  }

  /// Returns accumulated counts since the last snapshot and resets counters.
  ///
  /// Dispatches based on [_installedMode]:
  /// - [_InstalledMode.debug]: drains the debug-callback maps populated by
  ///   `_handleRebuildDirtyWidget` / `_handleProfilePaint`.
  /// - [_InstalledMode.profile]: drains `FlutterTimeline.debugCollect()`
  ///   through the type-name filter ([canonicalizeTypeName]) and
  ///   aggregates by canonical type name.
  /// - [_InstalledMode.none]: returns an empty snapshot with
  ///   `source: RebuildCountSource.none` (test and no-op cases).
  ///
  /// The returned [DebugSnapshot.elapsed] is the actual wall-clock time since
  /// the previous snapshot — detectors must use it to normalize to per-second
  /// rates.
  DebugSnapshot snapshot() {
    if (_installedMode == _InstalledMode.profile) {
      return _drainProfileBuffer();
    }
    // Scans run after a frame's paint phase, so the open frame is
    // complete.
    _closeOriginFrame();
    final now = _clock();
    final elapsed = now.difference(_lastSnapshotTime);
    _lastSnapshotTime = now;

    final result = DebugSnapshot(
      rebuildCounts: Map<String, int>.of(_rebuildCounts),
      paintCounts: Map<String, int>.of(_paintCounts),
      totalPaintCount: _paintCount,
      elapsed: elapsed,
      ancestorChains: Map<String, String>.of(_ancestorChains),
      animationOwnedPaintCounts: Map<String, int>.of(
        _animationOwnedPaintCounts,
      ),
      totalAnimationOwnedPaintCount: _totalAnimationOwnedPaintCount,
      source: _installedMode == _InstalledMode.debug
          ? RebuildCountSource.debugCallback
          : RebuildCountSource.none,
      forcedRebuildsByRoot: Map<String, int>.of(_forcedRebuildsByRoot),
      rebuildTypesCapped: _rebuildTypesCapped,
      paintTypesCapped: _paintTypesCapped,
      paintOrigins: _originStats(),
      paintOriginTypesCapped: _originTypesCapped,
    );
    _clearWindow();
    return result;
  }

  /// Drops the counts gathered since the last [snapshot] and starts a new
  /// window now. A hot reload rebuilds every element and repaints every
  /// render object once; that burst is not app activity.
  void discardWindow() {
    if (_installedMode == _InstalledMode.profile) return;
    _lastSnapshotTime = _clock();
    _dropOriginFrame();
    _clearWindow();
  }

  void _clearWindow() {
    _rebuildCounts.clear();
    _paintCounts.clear();
    _ancestorChains.clear();
    _animationOwnedPaintCounts.clear();
    _forcedRebuildsByRoot.clear();
    _originCounts.clear();
    _ownedOriginCounts.clear();
    _rebuildTypesCapped = false;
    _paintTypesCapped = false;
    _originTypesCapped = false;
    _paintCount = 0;
    _totalAnimationOwnedPaintCount = 0;
  }

  /// Per-type origin statistics for the window, busiest instances first.
  Map<String, PaintOriginStats> _originStats() {
    if (_originCounts.isEmpty) return const {};
    final result = <String, PaintOriginStats>{};
    _originCounts.forEach((typeName, instances) {
      // The few busiest instances, without sorting every instance.
      final busiest = <MapEntry<Element, int>>[];
      for (final entry in instances.entries) {
        if (busiest.length == PaintOriginStats.maxBusiest &&
            entry.value <= busiest.last.value) {
          continue;
        }
        var at = busiest.length;
        while (at > 0 && busiest[at - 1].value < entry.value) {
          at--;
        }
        busiest.insert(at, entry);
        if (busiest.length > PaintOriginStats.maxBusiest) {
          busiest.removeLast();
        }
      }
      final top = busiest.first.key;
      String? chain;
      if (top.mounted) {
        try {
          chain = buildAncestorChain(top);
        } catch (e, s) {
          assert(() {
            debugPrint('Sleuth: paint origin chain failed: $e\n$s');
            return true;
          }());
        }
      }
      result[typeName] = PaintOriginStats(
        maxCount: busiest.first.value,
        instanceCount: instances.length,
        animationOwnedCount: _ownedOriginCounts[typeName] ?? 0,
        ancestorChain: chain,
        busiest: [
          for (final entry in busiest)
            PaintOriginInstance(element: entry.key, count: entry.value),
        ],
      );
    });
    return result;
  }

  /// Drains `FlutterTimeline.debugCollect()`, applies the type-name filter
  /// ([canonicalizeTypeName]), aggregates by canonical type name, and
  /// produces a snapshot tagged with `RebuildCountSource.flutterTimeline`.
  ///
  /// Destructive: each call empties the framework buffer.
  DebugSnapshot _drainProfileBuffer() {
    final now = _clock();
    final elapsed = now.difference(_lastSnapshotTime);
    _lastSnapshotTime = now;

    final counts = <String, int>{};
    try {
      final timings = FlutterTimeline.debugCollect();
      for (final block in timings.timedBlocks) {
        final canonical = canonicalizeTypeName(block.name);
        if (canonical == null) continue;
        if (counts.length >= _maxTrackedTypes &&
            !counts.containsKey(canonical)) {
          continue; // Type cap (default 200) keeps the key set bounded.
        }
        counts[canonical] = (counts[canonical] ?? 0) + 1;
      }
    } on StateError {
      // Collection disabled mid-scan (DevTools or test teardown raced with
      // us). Return an empty snapshot rather than crashing the scan loop.
    }

    return DebugSnapshot(
      rebuildCounts: counts,
      // Profile path intentionally leaves paint + ancestor chains empty;
      // those come from the debug-callback path only.
      paintCounts: const {},
      totalPaintCount: 0,
      elapsed: elapsed,
      ancestorChains: const {},
      source: RebuildCountSource.flutterTimeline,
    );
  }

  /// Uninstalls all callbacks, tears down the profile drain if active, and
  /// clears internal state. Safe to call from either mode.
  void dispose() {
    uninstall();
    uninstallProfileMode();
    _rebuildCounts.clear();
    _paintCounts.clear();
    _ancestorChains.clear();
    _animationOwnedPaintCounts.clear();
    _originCounts.clear();
    _ownedOriginCounts.clear();
    _dropOriginFrame();
    _typeNames.clear();
    _paintAttributionEpoch++;
    _paintCount = 0;
    _totalAnimationOwnedPaintCount = 0;
  }

  /// Five-layer filter applied to raw `TimedBlock.name`
  /// strings.
  ///
  /// 1. **Deny-list** of known frame-level scopes that the framework emits
  ///    unconditionally when `debugProfileBuildsEnabledUserWidgets` is true.
  /// 2. **`Render*` prefix deny** — drops `RenderObject` subclass runtime-
  ///    type strings (`RenderPadding`, `RenderFlex`, `RenderParagraph`,
  ///    `_RenderCustomPainter`, …). These only land in the timeline when
  ///    `debugProfileLayoutsEnabled` or `debugProfilePaintsEnabled` is on
  ///    (default `false` in [DebugInstrumentationConfig]), but can leak in
  ///    when DevTools or another plugin flips those flags. Render-tree
  ///    names are not widget-level rebuilds and would otherwise bury the
  ///    actual hotspot widgets in the drilldown under thousands of
  ///    framework leaf-node scopes. Dart convention reserves `Render*` for
  ///    `RenderObject` subclasses, so this prefix never collides with
  ///    user widget classes (`SliverList`, `SliverPadding`, etc. are still
  ///    admitted because they don't start with `Render`).
  /// 3. **Identifier regex** `^_?[A-Z][A-Za-z0-9_]*(<.*>)?$`: only type-name-
  ///    shaped strings pass. Drops any future framework scope that happens
  ///    to contain spaces or non-identifier characters. The optional `_`
  ///    prefix admits private Dart types (`_BadDashboard`, `_MetricCard`) —
  ///    the framework emits these unconditionally when they live in user
  ///    code, and Flutter's DevTools Rebuild Stats tab shows them too, so
  ///    filtering them out of Sleuth's drilldown silently hid the most
  ///    common hotspot shape (private widgets inside a page's own file).
  /// 4. **Generic canonicalization**: `Provider<Foo>` → `Provider`, so
  ///    parameterized generics don't explode the 200-type cap and inflate
  ///    the "unique hotspot widgets" count with spurious duplicates.
  /// 5. **Framework + Sleuth overlay deny-list** (v0.15.1 hotfix):
  ///    drops core Flutter framework widgets (`Container`, `Padding`,
  ///    `ValueListenableBuilder`, `FadeTransition`, …) and Sleuth's own
  ///    overlay widgets (`FloatingIssuesCard`, `TriggerButton`,
  ///    `_StatusRow`, …). Rationale: Flutter's emission gate
  ///    (`framework.dart:3503`) uses `debugIsWidgetLocalCreation`, whose
  ///    `_isLocalCreationLocationImpl` fallback at `widget_inspector.dart:
  ///    1801-1816` classifies anything NOT under `packages/flutter/` as
  ///    "user widget" — including `package:sleuth/...` overlays — when
  ///    `_pubRootDirectories` is null (the default when DevTools is not
  ///    attached). That causes Sleuth's own overlay to self-measure and
  ///    report 200-1000x inflated counts vs. DevTools. `addPubRootDirectories`
  ///    is additive-only so we cannot exclude `package:sleuth` upstream;
  ///    the denylist is the only place we can break the feedback loop.
  ///    Framework entries are applied AFTER generic stripping so
  ///    `ValueListenableBuilder<T>` collapses to `ValueListenableBuilder`
  ///    before the set lookup.
  ///
  /// Returns `null` when the name should be dropped; otherwise the
  /// canonical form to use as an aggregation key. Pure; unit-tested.
  static String? canonicalizeTypeName(String raw) {
    if (_denyList.contains(raw)) return null;
    if (_isRenderObjectName(raw)) return null;
    if (!_identifierRegex.hasMatch(raw)) return null;
    final canonical = raw.contains('<')
        ? raw.replaceAll(_genericRegex, '')
        : raw;
    if (_frameworkWidgetDenyList.contains(canonical)) return null;
    return canonical;
  }

  /// Returns `true` when [raw] is a `RenderObject` runtime-type string —
  /// either `Render…` or `_Render…`. The `_?` admits private render objects
  /// like `_RenderCustomPainter` without admitting unrelated `_` private
  /// widgets.
  static bool _isRenderObjectName(String raw) {
    if (raw.isEmpty) return false;
    var i = 0;
    if (raw.codeUnitAt(0) == 0x5F /* '_' */ ) i = 1;
    // Need at least 'Render' (6 chars) after the optional underscore.
    if (raw.length - i < 6) return false;
    return raw.startsWith('Render', i);
  }

  static final RegExp _identifierRegex = RegExp(
    r'^_?[A-Z][A-Za-z0-9_]*(<.*>)?$',
  );
  static final RegExp _genericRegex = RegExp(r'<.*>');
  // Framework frame-phase scopes emitted by `FlutterTimeline.startSync(...)`
  // from inside the Flutter SDK. These are NOT widget rebuilds — they fire
  // once per frame regardless of what the user's tree is doing — and they
  // would otherwise dominate the Build Hotspot drilldown with bogus counts
  // (~60/sec at 60 FPS just for `POST_FRAME` + `COMPOSITING`).
  //
  // We only need entries whose raw string passes the identifier-shape regex
  // (`^_?[A-Z][A-Za-z0-9_]*(<.*>)?$`), because anything containing spaces,
  // dots, or parentheses (e.g. `LAYOUT (root)`, `Semantics.updateChildren`,
  // `Framework initialization`) is already dropped by the regex layer in
  // `canonicalizeTypeName`. Audit performed against
  // `~/fvm/versions/stable/packages/flutter/lib/src/**/*.dart` for Flutter
  // 3.41.4. If a future SDK adds a new identifier-shaped phase scope to
  // `FlutterTimeline.startSync`, add it here AND to the regression test in
  // `debug_instrumentation_coordinator_profile_test.dart` ("rejects
  // denylisted frame scopes").
  //
  // Sources for current entries:
  //   BUILD              widgets/framework.dart:3087
  //   FINALIZE TREE      widgets/framework.dart:3341 (kept for parity even
  //                       though regex would also drop it — defense in depth)
  //   LAYOUT             rendering/object.dart:1150 (suffix-less branch)
  //   PAINT              rendering/object.dart:1306 (suffix-less branch)
  //   POST_FRAME         scheduler/binding.dart:1353
  //   COMPOSITING        rendering/view.dart:349
  //   SEMANTICS          rendering/object.dart:1440 (suffix-less branch)
  //   Preparing Hot Reload (widgets)
  //                      widgets/framework.dart:3455 (kept for parity)
  static const Set<String> _denyList = {
    'BUILD',
    'LAYOUT',
    'PAINT',
    'FINALIZE TREE',
    'POST_FRAME',
    'COMPOSITING',
    'SEMANTICS',
    'Preparing Hot Reload (widgets)',
  };

  /// Test-only accessor for the framework + overlay denylist. Used by
  /// `test/debug/overlay_denylist_audit_test.dart` to enforce parity between
  /// the hardcoded set and the current UI source tree.
  @visibleForTesting
  static Set<String> get debugFrameworkWidgetDenyList =>
      _frameworkWidgetDenyList;

  /// Since the v0.15.1 hotfix: Flutter framework widgets used inside Sleuth's
  /// own overlay AND Sleuth's own overlay widget classes. Any widget in this
  /// set is dropped from profile-mode `FlutterTimeline.debugCollect()` drains
  /// so Sleuth never self-measures its own UI.
  ///
  /// The list is mechanically derived from `lib/src/ui/**/*.dart` and
  /// enforced for parity by `test/debug/overlay_denylist_audit_test.dart`:
  /// if anyone adds a new framework widget to an overlay file or creates a
  /// new overlay widget class, CI fails until the denylist is updated.
  /// Never edit this set by hand without running the audit test — silent
  /// drift reintroduces the v0.15.0 self-measurement bug.
  ///
  /// Framework entries are matched AFTER generic stripping in
  /// [canonicalizeTypeName], so `ValueListenableBuilder<T>` reduces to
  /// `ValueListenableBuilder` before the lookup.
  ///
  /// The overlay does not use `ListenableBuilder`, `AnimatedContainer`,
  /// `AnimatedSwitcher`, `MergeSemantics` or `CustomSingleChildLayout`; it
  /// uses Sleuth-named equivalents listed below, so app-owned rebuilds of
  /// those widgets are counted.
  static const Set<String> _frameworkWidgetDenyList = {
    // --- Flutter framework widgets used in lib/src/ui/ (53) ---
    'Align',
    'AnimatedBuilder',
    'AnimatedRotation',
    'AnimatedSize',
    'Card',
    'Center',
    'Checkbox',
    'ClipRRect',
    'Column',
    'ConstrainedBox',
    'Container',
    'CustomPaint',
    'DecoratedBox',
    'DefaultTextEditingShortcuts',
    'Directionality',
    'Divider',
    'ExcludeSemantics',
    'ExcludeFocus',
    'Expanded',
    'FadeTransition',
    'Flexible',
    'FocusScope',
    'GestureDetector',
    'Icon',
    'IgnorePointer',
    'InkWell',
    'LayoutBuilder',
    'LinearProgressIndicator',
    'ListView',
    'Listener',
    'Localizations',
    'Material',
    'MediaQuery',
    'MouseRegion',
    'NotificationListener',
    'Overlay',
    'Padding',
    'Positioned',
    'RepaintBoundary',
    'Row',
    'SafeArea',
    'Semantics',
    'ShaderMask',
    'SingleChildScrollView',
    'SizedBox',
    'SlideTransition',
    'Spacer',
    'Stack',
    'Text',
    'TextField',
    'TweenAnimationBuilder',
    'ValueListenableBuilder',
    'Wrap',
    // --- Sleuth overlay widget classes (43) ---
    'FloatingIssuesCard',
    '_StatusRow',
    '_ThroughputDetailRow',
    '_FpsCell',
    '_DebugModeBanner',
    '_WarningBanners',
    '_CardFooter',
    '_IssuesSummaryBar',
    '_StartupMetricsBanner',
    '_RebuildStatsBanner',
    'TriggerButton',
    'SleuthOverlay',
    'HighlightOverlay',
    'IssueCard',
    '_AskAiShimmerLink',
    'IssueEncyclopediaPage',
    '_SearchBar',
    'RebuildStatsPage',
    '_EmptyState',
    '_SummaryChip',
    '_RebuildRow',
    'StartupMetricsPage',
    'AiChatPage',
    '_StarterChip',
    '_ChatTextAction',
    'GuidePage',
    '_GuideStep',
    '_LegendRow',
    'SleuthTheme',
    'SleuthTextScaleClamp',
    'OverlayToast',
    '_ToastBody',
    'HiddenIssuesPage',
    '_HiddenRow',
    '_TextAction',
    '_SeverityChip',
    '_SeverityChipPill',
    '_EmptyListMessage',
    '_ToastFade',
    '_TriggerLayout',
    'SleuthListenableBuilder',
    '_AppSemanticsBlocker',
    '_LeadTrailLine',
  };

  void _handleRebuildDirtyWidget(Element element, bool builtOnce) {
    // Sleuth's own overlay widgets, and the widget Sleuth wraps around
    // the app, are not the app's rebuilds.
    if (OverlayOwnership.isOverlayOwned(element) ||
        OverlayOwnership.isAppBoundary(element)) {
      return;
    }
    final frame = _frameStamp();
    if (frame != _buildRootsFrame) {
      _buildRoots.clear();
      _buildRootsFrame = frame;
    }
    final depth = element.depth;
    while (_buildRoots.isNotEmpty && _buildRoots.last.depth >= depth) {
      _buildRoots.removeLast();
    }
    // The hook runs before the framework clears the flag: true for an
    // element that marked itself dirty, false for one its parent's build
    // updated (StatelessElement, StatefulElement and ProxyElement.update
    // rebuild with `force: true`).
    final dirty = element.dirty;
    final widget = element.widget;
    if (dirty && frame != null && isRebuildDrivenOwnerElement(element)) {
      _ownerRebuildFrame[element] = frame;
    }
    if (!_isUserWidget(widget)) {
      if (dirty) _buildRoots.add((type: null, depth: depth));
      return;
    }
    // First observation of this element = initial build (don't count).
    // Every subsequent observation = real rebuild. The framework's
    // `builtOnce` parameter is unreliable (see `_elementSeen` docs), so we
    // track first-observation ourselves via an Expando whose weak keying
    // lets dead elements get collected automatically. Marked before the
    // dirty split, so an element first seen through a forced update
    // counts its first own rebuild.
    if (_elementSeen[element] == null) {
      _elementSeen[element] = true;
      return;
    }
    if (!dirty) {
      // Rebuilt because its parent's build passed it a new widget: part
      // of that parent's cost, not a rebuild of its own.
      final root = _buildRoots.isEmpty ? null : _buildRoots.last.type;
      if (root != null) {
        _forcedRebuildsByRoot[root] = (_forcedRebuildsByRoot[root] ?? 0) + 1;
      }
      return;
    }
    final typeName = _typeName(widget.runtimeType);
    _buildRoots.add((type: typeName, depth: depth));
    if (_rebuildCounts.length >= _maxTrackedTypes &&
        !_rebuildCounts.containsKey(typeName)) {
      _rebuildTypesCapped = true;
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

  /// The current frame's system time stamp in microseconds, or null
  /// outside a frame.
  static int? _frameStamp() {
    final binding = SchedulerBinding.instance;
    if (binding.schedulerPhase == SchedulerPhase.idle) return null;
    return binding.currentSystemFrameTimeStamp.inMicroseconds;
  }

  /// Whether [owner] drove a paint in [frame] (the current frame when
  /// null): a rebuild-driven owner only in a frame where it rebuilt
  /// itself, any other owner by being there. Without the rebuild callback
  /// there are no rebuild stamps, so presence decides.
  bool _ownerActive(Element owner, {int? frame}) {
    if (!_rebuildInstalled || !isRebuildDrivenOwnerElement(owner)) {
      return true;
    }
    final stamp = frame ?? _frameStamp();
    return stamp != null && _ownerRebuildFrame[owner] == stamp;
  }

  /// Framework widgets that only annotate the semantics tree. Their
  /// render objects paint as pass-throughs whenever a descendant repaints,
  /// and a screen reader keeps more of them in the tree, so while
  /// semantics are on their paints are left out of every debug paint
  /// count (per widget and aggregate). With semantics off they count
  /// like any widget, so a repainting `Semantics` the app wraps itself
  /// still reports.
  @visibleForTesting
  static const Set<String> semanticsOnlyWidgets = {
    'Semantics',
    'MergeSemantics',
    'ExcludeSemantics',
    'BlockSemantics',
    'IndexedSemantics',
    '_GestureSemantics',
  };

  void _handleProfilePaint(RenderObject renderObject) {
    final creator = renderObject.debugCreator;
    final element = creator is DebugCreator ? creator.element : null;
    // Every paint takes part in the origin pass, filtered or not, so the
    // marked chains it reads have no gaps. The overlay's are never
    // credited.
    final dirty = _notePaintForOrigins(renderObject);
    // Sleuth's own overlay paints count nowhere, not even in the total.
    if (element != null && OverlayOwnership.isOverlayOwned(element)) return;
    if (element == null) {
      _paintCount++;
      return;
    }

    final typeName = _typeName(element.widget.runtimeType);
    if (semanticsOnlyWidgets.contains(typeName) &&
        SemanticsBinding.instance.semanticsEnabled) {
      return;
    }
    _paintCount++;
    // A framework widget's paint still counts in the totals (and its
    // animation ownership below), so the aggregate gates see every paint;
    // only the per-widget maps leave it out.
    var perWidget = _isUserWidget(element.widget);
    if (perWidget &&
        _paintCounts.length >= _maxTrackedTypes &&
        !_paintCounts.containsKey(typeName)) {
      // Cap reached: the type gets no entry, but its ownership still
      // counts toward the aggregate.
      _paintTypesCapped = true;
      perWidget = false;
    }
    if (perWidget) {
      _paintCounts[typeName] = (_paintCounts[typeName] ?? 0) + 1;
    }

    // The chain and the ancestor legs of the ownership check are judged
    // per element, never per typeName: two distinct widgets sharing the
    // same `runtimeType.toString()` — e.g. CircularProgressIndicator's
    // internal `CustomPaint` and a chart's bare `CustomPaint` — can have
    // totally different owners. The per-element cache keeps that
    // property; it only skips recomputing for an element whose
    // ancestors and depth are unchanged since its last paint.
    //
    // The chain cache (`_ancestorChains`) is still populated on first
    // occurrence per typeName for the source-location enrichment use
    // case, where the polymorphic collision is already accepted.
    final attribution = _attributionFor(element);
    final chain = attribution.chain;
    if (perWidget && chain != null && !_ancestorChains.containsKey(typeName)) {
      _ancestorChains[typeName] = chain;
    }

    // Per-paint animation-owned attribution. The descendant leg runs on
    // every paint (a child can change without the element moving). An
    // owner only counts when it drove this frame ([_ownerActive]), so an
    // idle `AnimatedContainer` next to a repainting widget does not hide
    // it.
    final owned = _isOwnedPaint(element, attribution);
    if (dirty) _frameDirty[renderObject] = owned;

    if (owned) {
      if (perWidget) {
        _animationOwnedPaintCounts[typeName] =
            (_animationOwnedPaintCounts[typeName] ?? 0) + 1;
      }
      _totalAnimationOwnedPaintCount++;
    }
  }

  /// Whether an animation owner drove a paint of [element] in [frame]
  /// (the current frame when null): an active owner among the ancestors
  /// in [attribution], or one the bounded descendant walk reaches.
  bool _isOwnedPaint(
    Element element,
    _PaintAttribution attribution, {
    int? frame,
  }) {
    final ancestorOwner = attribution.owner?.target;
    if (ancestorOwner != null &&
        ancestorOwner.mounted &&
        _ownerActive(ancestorOwner, frame: frame)) {
      return true;
    }
    // Wrapped because `Element.visitChildren` can throw on deactivated
    // elements during teardown; a paint-callback exception must never
    // crash the host app.
    try {
      final descendantOwner = findAnimationOwnerDescendant(element);
      return descendantOwner != null &&
          _ownerActive(descendantOwner, frame: frame);
    } catch (e, s) {
      assert(() {
        debugPrint('Sleuth: animation-owned check failed: $e\n$s');
        return true;
      }());
      return false;
    }
  }

  /// Records [renderObject]'s paint for the per-frame origin pass and
  /// returns whether it was marked as needing paint.
  ///
  /// The framework calls the hook before it paints the child, and only
  /// that paint clears the flag, so the flag read here is the child's own.
  /// Marking a render object also marks its ancestors up to the nearest
  /// repaint boundary, so the marked nodes of a layer form chains from
  /// where each mark started up to the layer's root, and a marked node
  /// with a marked child is not where a chain started. Clean paints (the
  /// widgets that repaint only because they share the layer, and reused
  /// boundary layers) cost one flag read and a parent check.
  bool _notePaintForOrigins(RenderObject renderObject) {
    final dirty = renderObject.debugNeedsPaint;
    final parent = renderObject.parent;
    final parentIsBoundary = parent != null && parent.isRepaintBoundary;
    if (!dirty && !parentIsBoundary) return false;
    _openOriginFrame();
    // A boundary painting its children with no hook call of its own this
    // frame is a layer root that `flushPaint` repainted. A clean boundary
    // painted by its parent reuses its layer and paints no children.
    if (parentIsBoundary && !_frameDirty.containsKey(parent)) {
      _frameRoots.add(parent);
    }
    if (dirty) {
      _frameDirty[renderObject] = null;
      if (parent != null) _frameReached.add(parent);
    }
    return dirty;
  }

  /// Opens a frame for the origin pass, closing the open one first when
  /// the frame stamp has moved on.
  void _openOriginFrame() {
    final stamp = _frameStamp();
    if (_originFrameOpen) {
      if (stamp == _originFrameStamp) return;
      _closeOriginFrame();
    }
    _originFrameOpen = true;
    _originFrameStamp = stamp;
    if (!_originFrameEndScheduled) {
      _originFrameEndScheduled = true;
      SchedulerBinding.instance.addPostFrameCallback(
        _onOriginFrameEnd,
        debugLabel: 'Sleuth.paintOrigins',
      );
    }
  }

  void _handleOriginFrameEnd(Duration _) {
    _originFrameEndScheduled = false;
    _closeOriginFrame();
  }

  /// Credits the open frame's likely origins: every marked node none of
  /// whose painted children was marked, and every layer root none of
  /// whose children was marked (a boundary that marked itself).
  void _closeOriginFrame() {
    if (!_originFrameOpen) return;
    final frame = _originFrameStamp;
    try {
      _frameDirty.forEach((renderObject, owned) {
        if (!_frameReached.contains(renderObject)) {
          _creditOrigin(renderObject, owned, frame);
        }
      });
      for (final root in _frameRoots) {
        if (!_frameReached.contains(root)) _creditOrigin(root, null, frame);
      }
    } finally {
      _dropOriginFrame();
    }
  }

  void _dropOriginFrame() {
    _originFrameOpen = false;
    _frameDirty.clear();
    _frameReached.clear();
    _frameRoots.clear();
    _frameCredited.clear();
  }

  /// Counts one frame for the widget instance credited with
  /// [renderObject]'s repaint: the nearest widget the app created at or
  /// above the render object's creator. [owned] is the hook's animation
  /// ownership verdict, judged here for [frame] when the hook made none.
  void _creditOrigin(RenderObject renderObject, bool? owned, int? frame) {
    try {
      // A render object that another render object made directly has no
      // creator; it is credited through the nearest one that has.
      Element? element;
      for (
        RenderObject? node = renderObject;
        node != null;
        node = node.parent
      ) {
        final creator = node.debugCreator;
        if (creator is DebugCreator) {
          element = creator.element;
          break;
        }
      }
      if (element == null || !element.mounted) return;
      if (OverlayOwnership.isOverlayOwned(element)) return;
      // A scroll view repaints its viewport and slivers whenever its offset
      // moves, and the framework's own painters animate its controls (a
      // scrollbar thumb, a toggle, a tab indicator). Neither is a change
      // the app made, and both would otherwise be credited to the app
      // widget around them.
      if (renderObject is RenderSliver ||
          renderObject is RenderAbstractViewport ||
          isFrameworkPainterPaint(element)) {
        return;
      }
      if (semanticsOnlyWidgets.contains(
            _typeName(element.widget.runtimeType),
          ) &&
          SemanticsBinding.instance.semanticsEnabled) {
        return;
      }
      final credited = _nearestUserElement(element);
      if (credited == null || !_frameCredited.add(credited)) return;
      final typeName = _typeName(credited.widget.runtimeType);
      final isOwned =
          owned ??
          _isOwnedPaint(element, _attributionFor(element), frame: frame);
      if (isOwned) {
        if (_ownedOriginCounts.length < _maxTrackedTypes ||
            _ownedOriginCounts.containsKey(typeName)) {
          _ownedOriginCounts[typeName] =
              (_ownedOriginCounts[typeName] ?? 0) + 1;
        }
        return;
      }
      // Content that follows the scroll offset while the user scrolls (a
      // collapsing app bar, a header fading out) repaints because of the
      // scroll, not because of a change the app made to it.
      if (_inActiveScroll(element)) return;
      var instances = _originCounts[typeName];
      if (instances == null) {
        if (_originCounts.length >= _maxTrackedTypes) {
          _originTypesCapped = true;
          return;
        }
        _originCounts[typeName] = instances = <Element, int>{};
      }
      final count = instances[credited];
      if (count == null && instances.length >= maxOriginInstancesPerType) {
        return;
      }
      instances[credited] = (count ?? 0) + 1;
    } catch (e, s) {
      // An element torn down since its paint cannot be walked.
      assert(() {
        debugPrint('Sleuth: paint origin attribution failed: $e\n$s');
        return true;
      }());
    }
  }

  /// [element] when the app created its widget, else the nearest ancestor
  /// whose widget the app created, not looking past the widget Sleuth
  /// wraps around the app. Null when there is none.
  Element? _nearestUserElement(Element element) {
    if (_isUserWidget(element.widget)) return element;
    Element? found;
    element.visitAncestorElements((ancestor) {
      if (OverlayOwnership.isAppBoundary(ancestor)) return false;
      if (_isUserWidget(ancestor.widget)) {
        found = ancestor;
        return false;
      }
      return true;
    });
    return found;
  }

  /// Whether a scroll view above [element], below the widget Sleuth wraps
  /// around the app, is being scrolled (a drag, a fling or an animated
  /// scroll).
  static bool _inActiveScroll(Element element) {
    var scrolling = false;
    element.visitAncestorElements((ancestor) {
      if (OverlayOwnership.isAppBoundary(ancestor)) return false;
      if (ancestor is StatefulElement) {
        final state = ancestor.state;
        if (state is ScrollableState &&
            state.position.isScrollingNotifier.value) {
          scrolling = true;
          return false;
        }
      }
      return true;
    });
    return scrolling;
  }

  /// Ancestors read by the ownership walk ([hasAnimationOwnerAncestor]).
  static const int _ownerAncestorDepth = 16;

  /// Cached or freshly computed ancestor attribution for [element].
  _PaintAttribution _attributionFor(Element element) {
    var cacheable = element.mounted;
    if (cacheable) {
      final cached = _paintAttribution[element];
      if (cached != null &&
          cached.epoch == _paintAttributionEpoch &&
          cached.depth == element.depth &&
          _ancestorsUnchanged(element, cached.ancestors)) {
        return cached;
      }
    }

    _paintAttributionComputes++;
    String? chain;
    final chainAncestors = <Element>[];
    try {
      chain = buildAncestorChain(element, visitedAncestors: chainAncestors);
    } catch (e, s) {
      // Element may be deactivated mid-paint (rare but observed in
      // teardown races). Continue with `chain == null`; the ownership
      // check still has the descendant walk to fall back on.
      cacheable = false;
      assert(() {
        debugPrint('Sleuth: paint ancestor chain failed: $e\n$s');
        return true;
      }());
    }
    Element? owner;
    try {
      // The chain walk can read further than the owner walk; search as far
      // as either went.
      owner = findAnimationOwnerAncestor(
        element,
        maxDepth: math.max(_ownerAncestorDepth, chainAncestors.length),
      );
    } catch (e, s) {
      cacheable = false;
      assert(() {
        debugPrint('Sleuth: animation-owned check failed: $e\n$s');
        return true;
      }());
    }
    var ancestors = const <WeakReference<Element>>[];
    if (cacheable) {
      try {
        ancestors = _stampAncestors(element, chainAncestors.length);
      } catch (_) {
        cacheable = false;
      }
    }
    final attribution = _PaintAttribution(
      ancestors: ancestors,
      depth: cacheable ? element.depth : -1,
      epoch: _paintAttributionEpoch,
      chain: chain,
      owner: owner == null ? null : WeakReference(owner),
    );
    if (cacheable) _paintAttribution[element] = attribution;
    return attribution;
  }

  /// Weak references to the nearest ancestors of [element], as many as
  /// the chain walk ([chainRead]) or the ownership walk read, whichever
  /// is more. Each element has one parent, so the same objects at every
  /// position mean the same ancestry up to the last one read.
  static List<WeakReference<Element>> _stampAncestors(
    Element element,
    int chainRead,
  ) {
    final limit = math.max(chainRead, _ownerAncestorDepth);
    final refs = <WeakReference<Element>>[];
    element.visitAncestorElements((ancestor) {
      refs.add(WeakReference(ancestor));
      return refs.length < limit;
    });
    return refs;
  }

  /// Whether [element]'s nearest ancestors are still the mounted objects
  /// in [stamp], position by position, and the walk ends where it ended.
  static bool _ancestorsUnchanged(
    Element element,
    List<WeakReference<Element>> stamp,
  ) {
    var index = 0;
    var same = true;
    try {
      element.visitAncestorElements((ancestor) {
        if (index >= stamp.length) return false;
        if (!identical(stamp[index].target, ancestor) || !ancestor.mounted) {
          same = false;
          return false;
        }
        index++;
        return index < stamp.length;
      });
    } catch (_) {
      return false;
    }
    return same && index == stamp.length;
  }
}

/// Ancestor-derived attribution of one painting element, stamped with the
/// position it was computed at.
class _PaintAttribution {
  const _PaintAttribution({
    required this.ancestors,
    required this.depth,
    required this.epoch,
    required this.chain,
    required this.owner,
  });

  /// Nearest ancestors at computation time, nearest first; weak so a
  /// moved element's cache entry does not keep its old ancestors alive.
  final List<WeakReference<Element>> ancestors;
  final int depth;
  final int epoch;
  final String? chain;

  /// The nearest animation owner among the ancestors the chain or the
  /// bounded ownership walk read; weak, like [ancestors].
  final WeakReference<Element>? owner;
}
