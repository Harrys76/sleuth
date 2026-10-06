import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/widgets.dart' show Element;

/// Origin of the [DebugSnapshot.rebuildCounts] data.
///
/// Sleuth populates rebuild counts from exactly one source per mode; the
/// debug and profile sources never run together:
///
/// - [debugCallback]: debug-mode `debugOnRebuildDirtyWidget` callback.
///   Counts actual rebuilds only (initial builds excluded).
/// - [flutterTimeline]: profile-mode `FlutterTimeline.debugCollect()` drain.
///   Counts include initial widget inflations as well as rebuilds, so route
///   entry shows transient elevated values.
/// - [none]: no source is active; `rebuildCounts` is empty. Also the
///   default used by fixture/test snapshots that don't care about source.
enum RebuildCountSource { none, debugCallback, flutterTimeline }

/// A snapshot of debug callback data accumulated over a time window.
///
/// Produced by `DebugInstrumentationCoordinator.snapshot()` and consumed
/// by detectors to provide per-widget-type rebuild and paint attribution.
class DebugSnapshot {
  const DebugSnapshot({
    required this.rebuildCounts,
    required this.totalPaintCount,
    required this.elapsed,
    this.paintCounts = const {},
    this.ancestorChains = const {},
    this.animationOwnedPaintCounts = const {},
    this.totalAnimationOwnedPaintCount = 0,
    this.source = RebuildCountSource.none,
    this.forcedRebuildsByRoot = const {},
    this.rebuildTypesCapped = false,
    this.paintTypesCapped = false,
    this.paintOrigins = const {},
    this.paintOriginTypesCapped = false,
  });

  /// Per-widget-type rebuild counts (key = widget runtimeType name).
  ///
  /// From `debugOnRebuildDirtyWidget` which provides the [Element],
  /// giving us `.widget.runtimeType`. In debug mode only rebuilds of an
  /// element that marked itself dirty count here (`setState`, a changed
  /// dependency, a listenable builder); the widgets its build then
  /// updates are counted in [forcedRebuildsByRoot].
  final Map<String, int> rebuildCounts;

  /// Rebuilds a parent's build forced on the widgets below it, keyed by
  /// the type of the self-dirtied widget whose build caused them
  /// (debug mode).
  final Map<String, int> forcedRebuildsByRoot;

  /// Some widget types were left out of [rebuildCounts] by the type cap,
  /// so a type missing from it is not known to be idle.
  final bool rebuildTypesCapped;

  /// Some widget types were left out of [paintCounts] by the type cap.
  final bool paintTypesCapped;

  /// Per-widget-type paint counts (key = widget runtimeType name).
  ///
  /// From `debugOnProfilePaint` via `renderObject.debugCreator` mapping
  /// back to the originating widget type. Empty when `debugCreator` is
  /// unavailable (non-widget RenderObjects).
  ///
  /// These count participation: the framework calls the hook for every
  /// child a parent paints, so every widget in a repainting layer counts
  /// once per frame, including a `RepaintBoundary` whose cached layer is
  /// reused. [paintOrigins] holds the likely origins instead.
  final Map<String, int> paintCounts;

  /// Per-widget-type likely repaint origins (key = widget runtimeType
  /// name), debug mode only.
  ///
  /// Unlike [paintCounts], a widget counts here only in frames where it
  /// was the likely origin of its layer's repaint, so widgets that repaint
  /// only because they share a layer with it are left out. Counts are per
  /// instance; see [PaintOriginStats].
  final Map<String, PaintOriginStats> paintOrigins;

  /// Some widget types were left out of [paintOrigins] by the type cap,
  /// so a type missing from it is not known to be idle.
  final bool paintOriginTypesCapped;

  /// Per-widget-type ancestor chains (key = widget runtimeType name).
  ///
  /// Captured on first occurrence of each type in the debug callbacks.
  /// Provides widget tree hierarchy for source-location enrichment.
  final Map<String, String> ancestorChains;

  /// Per-widget-type **animation-owned** paint counts (key = widget
  /// runtimeType name). A subset of [paintCounts]: every entry here was
  /// also counted in [paintCounts], so detectors that want a "non-owned
  /// residual" must subtract.
  ///
  /// Populated by `DebugInstrumentationCoordinator._handleProfilePaint`
  /// using `isAnimationOwnedPaint` (chain-containment OR bounded
  /// descendant walk). Per-paint attribution sidesteps the
  /// `paintCounts` polymorphic-key collision:
  /// two distinct widgets that both report `'CustomPaint'` as their
  /// type can have completely different per-paint owned outcomes —
  /// e.g. a `CircularProgressIndicator`'s internal `CustomPaint` is
  /// fully owned, while a chart's bare `CustomPaint` is not.
  ///
  /// Defaults to `const {}` so existing fixture snapshots compile
  /// unchanged.
  final Map<String, int> animationOwnedPaintCounts;

  /// Aggregate count of paints attributed to an animation owner (across
  /// every widget type, regardless of whether the type made it into
  /// [paintCounts]). Used by the aggregate-residual gate
  /// (`residual = totalPaintCount - totalAnimationOwnedPaintCount`).
  ///
  /// Defaults to `0` so existing fixture snapshots compile unchanged.
  final int totalAnimationOwnedPaintCount;

  /// Aggregate paint call count (includes paints where widget attribution
  /// was not possible).
  final int totalPaintCount;

  /// Time since last snapshot. Detectors MUST normalize counts to
  /// per-second rates using this before applying thresholds, since
  /// the snapshot interval is not guaranteed to be 1 second.
  final Duration elapsed;

  /// Origin of [rebuildCounts]. See [RebuildCountSource] for semantics.
  ///
  /// Defaults to [RebuildCountSource.none] so existing const-literal
  /// fixture snapshots compile unchanged. Code that cares about the
  /// profile-mode path (e.g. the controller merge into
  /// `RouteSession.rebuildCountsByType`) should gate on
  /// `source == RebuildCountSource.flutterTimeline`.
  final RebuildCountSource source;

  /// Total rebuilds across all widget types.
  int get totalRebuilds => rebuildCounts.values.fold(0, (a, b) => a + b);

  /// Rebuilds per second for a specific widget type.
  ///
  /// Uses microseconds throughout to avoid int truncation at sub-second
  /// windows and division-by-zero when elapsed is very small.
  double rebuildsPerSecond(String typeName) {
    final us = elapsed.inMicroseconds;
    if (us == 0) return 0;
    return (rebuildCounts[typeName] ?? 0) /
        (us / Duration.microsecondsPerSecond);
  }

  /// Total paints per second (aggregate, not per-widget).
  double get paintsPerSecond {
    final us = elapsed.inMicroseconds;
    if (us == 0) return 0;
    return totalPaintCount / (us / Duration.microsecondsPerSecond);
  }

  /// Paints per second for a specific widget type.
  double paintsPerSecondForType(String typeName) {
    final us = elapsed.inMicroseconds;
    if (us == 0) return 0;
    return (paintCounts[typeName] ?? 0) / (us / Duration.microsecondsPerSecond);
  }

  /// Total paints with widget-type attribution.
  int get totalPaintsFromTypes => paintCounts.values.fold(0, (a, b) => a + b);

  /// Frames per second in which the busiest instance of [typeName] was a
  /// likely repaint origin ([PaintOriginStats.maxCount] over [elapsed]).
  double paintOriginsPerSecondForType(String typeName) {
    final us = elapsed.inMicroseconds;
    if (us == 0) return 0;
    return (paintOrigins[typeName]?.maxCount ?? 0) /
        (us / Duration.microsecondsPerSecond);
  }
}

/// The likely repaint origins of one widget type over a snapshot window.
///
/// In each frame the debug paint hook reads, for every render object a
/// parent paints, whether it was marked as needing paint. Marking a
/// render object also marks its ancestors up to the nearest repaint
/// boundary, so the deepest marked render object of a layer (none of its
/// painted children was marked) is taken as the likely origin of that
/// layer's repaint. A repaint boundary that repainted with no marked
/// child is its own origin. The origin is credited to the nearest widget
/// the app created: a `Text` whose content changes counts as that `Text`,
/// since the render object that paints it is the framework's.
///
/// Left out: a scroll view's viewport and slivers repainting as the offset
/// moves, content inside a scroll view while it is being scrolled, and the
/// framework's own control painters (a scrollbar thumb, a toggle, a tab
/// indicator).
///
/// This is a heuristic. An ancestor that marked itself in the same frame
/// as a descendant looks the same as one marked through that descendant,
/// and is not counted.
@immutable
class PaintOriginStats {
  const PaintOriginStats({
    required this.maxCount,
    this.instanceCount = 1,
    this.animationOwnedCount = 0,
    this.ancestorChain,
    this.busiest = const [],
  });

  /// Frames in which the busiest instance of the type was a likely
  /// origin, leaving out frames an animation owner drove.
  final int maxCount;

  /// Instances of the type that were a likely origin in at least one
  /// frame no animation owner drove.
  final int instanceCount;

  /// Frames, across all instances, in which an instance was a likely
  /// origin driven by an animation owner. Not part of [maxCount].
  final int animationOwnedCount;

  /// Ancestor chain of the busiest instance, when it was still mounted
  /// at snapshot time.
  final String? ancestorChain;

  /// The busiest instances, busiest first, at most [maxBusiest].
  final List<PaintOriginInstance> busiest;

  /// Most instances kept in [busiest].
  static const int maxBusiest = 3;
}

/// One widget instance credited as a likely repaint origin.
@immutable
class PaintOriginInstance {
  PaintOriginInstance({required Element element, required this.count})
    : _element = WeakReference(element);

  final WeakReference<Element> _element;

  /// The credited element, or null once it has been garbage collected. It
  /// can be unmounted.
  Element? get element => _element.target;

  /// Frames in which this instance was a likely origin, leaving out
  /// frames an animation owner drove.
  final int count;
}
