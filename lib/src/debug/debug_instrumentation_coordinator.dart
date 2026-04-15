import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../utils/widget_location.dart';
import 'debug_snapshot.dart';

/// Which installation path a coordinator is currently on.
///
/// Debug and profile are mutually exclusive (KDD-1): exactly one source
/// populates [DebugSnapshot.rebuildCounts] per coordinator lifetime.
enum _InstalledMode { none, debug, profile }

/// Manages per-widget rebuild/paint attribution via two mutually-exclusive
/// paths (KDD-1 in `doc/spec_v15_rebuild_stats.md`):
///
/// - **Debug mode** uses `debugOnRebuildDirtyWidget` + `debugOnProfilePaint`
///   global callbacks. Counts actual rebuilds only (initial builds are
///   excluded via the `builtOnce` flag).
/// - **Profile mode** uses `FlutterTimeline.debugCollect()` drained on every
///   scan. Counts include initial widget inflations as well as rebuilds
///   because the framework emits the same `FlutterTimeline.startSync` from
///   `_tryRebuild`, `updateChild`, AND `inflateWidget` (KDD-5). The rollup
///   issue copy, config doc, and CHANGELOG all disclose this divergence.
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
  /// anything. That is exactly the bug the M11 anti-tautology test catches,
  /// and the reason we cannot trust that parameter.
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
  /// Policy (KDD-1, M4 per spec v15):
  /// 1. Assert `!kReleaseMode`.
  /// 2. Refuse if already installed on either path.
  /// 3. **Refuse if `FlutterTimeline.debugCollectionEnabled` is already
  ///    `true`** — DevTools or another Sleuth instance owns the buffer. We
  ///    must not stomp their save/restore. This resolves R20 (DevTools
  ///    conflict) and B1 (two Sleuth instances stomping the buffer).
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
      // Double-install no-op (idempotent). The spec tolerates this in M12
      // because controller wiring may call install twice across hot-restart.
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
  ///   through the KDD-3 three-layer filter ([canonicalizeTypeName]) and
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
    final now = _clock();
    final elapsed = now.difference(_lastSnapshotTime);
    _lastSnapshotTime = now;

    final result = DebugSnapshot(
      rebuildCounts: Map<String, int>.of(_rebuildCounts),
      paintCounts: Map<String, int>.of(_paintCounts),
      totalPaintCount: _paintCount,
      elapsed: elapsed,
      ancestorChains: Map<String, String>.of(_ancestorChains),
      source: _installedMode == _InstalledMode.debug
          ? RebuildCountSource.debugCallback
          : RebuildCountSource.none,
    );
    _rebuildCounts.clear();
    _paintCounts.clear();
    _ancestorChains.clear();
    _paintCount = 0;
    return result;
  }

  /// Drains `FlutterTimeline.debugCollect()`, applies the three-layer filter
  /// (KDD-3, M8), aggregates by canonical type name, and produces a snapshot
  /// tagged with `RebuildCountSource.flutterTimeline`.
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
          continue; // 200-type cap (KDD-3 layer 4 — unbounded keys).
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
    _typeNames.clear();
    _paintCount = 0;
  }

  /// KDD-3 / KDD-10 / M8: five-layer filter applied to raw `TimedBlock.name`
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
  /// 5. **Framework + Sleuth overlay deny-list** (KDD-10 / v0.15.1 hotfix):
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
  /// canonical form to use as an aggregation key. Pure; unit-tested by M12.
  static String? canonicalizeTypeName(String raw) {
    if (_denyList.contains(raw)) return null;
    if (_isRenderObjectName(raw)) return null;
    if (!_identifierRegex.hasMatch(raw)) return null;
    final canonical =
        raw.contains('<') ? raw.replaceAll(_genericRegex, '') : raw;
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
    if (raw.codeUnitAt(0) == 0x5F /* '_' */) i = 1;
    // Need at least 'Render' (6 chars) after the optional underscore.
    if (raw.length - i < 6) return false;
    return raw.startsWith('Render', i);
  }

  static final RegExp _identifierRegex =
      RegExp(r'^_?[A-Z][A-Za-z0-9_]*(<.*>)?$');
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

  /// KDD-10 (v0.15.1 hotfix): Flutter framework widgets used inside Sleuth's
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
  static const Set<String> _frameworkWidgetDenyList = {
    // --- Flutter framework widgets used in lib/src/ui/ (49) ---
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
    'Expanded',
    'FadeTransition',
    'Flexible',
    'GestureDetector',
    'Icon',
    'IgnorePointer',
    'InkWell',
    'LayoutBuilder',
    'LinearProgressIndicator',
    'ListView',
    'Localizations',
    'Material',
    'MouseRegion',
    'NotificationListener',
    'Overlay',
    'Padding',
    'PopScope',
    'Positioned',
    'RepaintBoundary',
    'Row',
    'SafeArea',
    'Semantics',
    'ShaderMask',
    'SingleChildScrollView',
    'SizedBox',
    'SlideTransition',
    'SnackBar',
    'Spacer',
    'Stack',
    'Text',
    'TextField',
    'TweenAnimationBuilder',
    'ValueListenableBuilder',
    'Wrap',
    // --- Sleuth overlay widget classes (26) ---
    'FloatingIssuesCard',
    '_StatusRow',
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
    'GuidePage',
    '_GuideStep',
    '_LegendRow',
    'SleuthTheme',
  };

  void _handleRebuildDirtyWidget(Element element, bool builtOnce) {
    // First observation of this element = initial build (don't count).
    // Every subsequent observation = real rebuild. The framework's
    // `builtOnce` parameter is unreliable (see `_elementSeen` docs), so we
    // track first-observation ourselves via an Expando whose weak keying
    // lets dead elements get collected automatically.
    if (_elementSeen[element] == null) {
      _elementSeen[element] = true;
      return;
    }
    final typeName = _typeName(element.widget.runtimeType);
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
      final typeName = _typeName(creator.element.widget.runtimeType);
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
