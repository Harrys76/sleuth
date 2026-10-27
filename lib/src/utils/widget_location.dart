import 'package:flutter/widgets.dart';

import 'source_location_cache.dart';
import 'type_name_cache.dart';

/// Module-level cache for widget source location lookups.
///
/// Shared across all [buildAncestorChain] calls, one entry per element.
/// Call [SourceLocationCache.clear] in tests to reset state.
final sourceLocationCache = SourceLocationCache();

/// Known framework widgets that clutter the ancestor chain without
/// helping the user locate their code.
const _frameworkNames = {
  'Scaffold',
  'Material',
  'AnimatedTheme',
  'AppBar',
  'ScrollConfiguration',
  'PrimaryScrollController',
  'Overlay',
  'Navigator',
  'FocusScope',
  'FocusTraversalGroup',
  'Actions',
  'Shortcuts',
  'MediaQuery',
  'Directionality',
  'DefaultTextStyle',
  'AnimatedDefaultTextStyle',
  'IconTheme',
  'AnimatedPhysicalModel',
  'Theme',
  'InheritedTheme',
  'ScaffoldMessenger',
  'HeroControllerScope',
  // Infrastructure widgets that never represent user code
  'WidgetsApp',
  'Title',
  'DefaultTextEditingShortcuts',
  'DefaultTextEditingActions',
  'ScrollNotificationObserver',
  'Semantics',
  'MergeSemantics',
  'ExcludeSemantics',
  'BlockSemantics',
  // Transition / animation framework widgets
  'SlideTransition',
  'FadeTransition',
  'ScaleTransition',
  'RotationTransition',
  'SizeTransition',
  'FractionalTranslation',
  'PositionedTransition',
  'DecoratedBoxTransition',
  // Builder / listener plumbing
  'Builder',
  'ListenableBuilder',
  'NotificationListener',
  // Pointer / hit-test infrastructure
  'IgnorePointer',
  'AbsorbPointer',
  // Render optimisation infrastructure
  'RepaintBoundary',
  'Offstage',
  'TickerMode',
  'KeyedSubtree',
};

/// Builds a human-readable ancestor chain from an Element, helping
/// users locate the widget in their source code.
///
/// Walks up the tree to find the nearest user page/screen widget,
/// then shows the path down to the flagged element.
///
/// Example output (build tracks widget creation):
///   "NestedScrollDemo > Column > SingleChildScrollView (lib/screens/demo.dart:42)"
/// Example output (build does not track widget creation):
///   "NestedScrollDemo > Column > SingleChildScrollView"
///
/// When [visitedAncestors] is given, every ancestor the walk reads is
/// appended to it, nearest first.
String buildAncestorChain(
  Element element, {
  int maxDepth = 6,
  List<Element>? visitedAncestors,
}) {
  // Leaf element: always include, with source location if available.
  final leafName = typeNameCache.lookup(element.widget);
  final leafLoc = sourceLocationCache.lookup(element);
  final leafEntry = leafLoc != null ? '$leafName ($leafLoc)' : leafName;
  final chain = <String>[leafEntry];

  element.visitAncestorElements((ancestor) {
    visitedAncestors?.add(ancestor);
    final name = typeNameCache.lookup(ancestor.widget);
    // Skip private and known framework widgets
    if (name.startsWith('_') || _frameworkNames.contains(name)) {
      return true; // keep walking
    }
    // Append source location for each non-framework ancestor.
    final loc = sourceLocationCache.lookup(ancestor);
    chain.add(loc != null ? '$name ($loc)' : name);
    return chain.length < maxDepth + 1;
  });

  return chain.reversed.join(' > ');
}

/// The leaf widget's `file:line` from a [buildAncestorChain] result, or
/// null when the chain is null or its leaf has no location (the build
/// does not track widget creation).
String? leafSourceLocation(String? ancestorChain) {
  if (ancestorChain == null) return null;
  final separator = ancestorChain.lastIndexOf(' > ');
  final leaf = separator < 0
      ? ancestorChain
      : ancestorChain.substring(separator + 3);
  return _trailingLocation.firstMatch(leaf.trimRight())?.group(1);
}

final RegExp _trailingLocation = RegExp(r' \(([^()]+:\d+)\)$');

/// Extracts the package name from the leaf element's source location.
/// Returns null when the build does not track widget creation.
String? extractPackageNameFromElement(Element element) {
  final structured = sourceLocationCache.lookupStructured(element);
  return structured?.packageName;
}

/// Get the global bounding rect for a RenderObject, or null if unavailable.
///
/// Also null for a box that is not painted. A sliver list gives a kept-alive
/// child outside its viewport (a `TabBarView` page that is not showing) a
/// zero paint transform, so its global position comes out NaN, and a NaN
/// rect passes every `overlaps` check.
///
/// The rect is where the box is laid out, which a clip can hide; the
/// overlay shows what [getVisibleGlobalRect] measures.
Rect? getGlobalRect(RenderObject ro) {
  try {
    if (ro is RenderBox && ro.hasSize) {
      final rect = ro.localToGlobal(Offset.zero) & ro.size;
      return rect.isFinite ? rect : null;
    }
  } catch (e, s) {
    assert(() {
      debugPrint('Sleuth: getGlobalRect failed: $e\n$s');
      return true;
    }());
  }
  return null;
}

/// The part of [ro]'s box that shows on screen, in global coordinates.
/// Its bounds are cut to its ancestors' clips, such as a scroll view's edge.
///
/// Null when none of the box shows, when it is detached or unsized, and
/// when its position is not finite (see [getGlobalRect]). A list lays out
/// rows past its edge (its cache extent), and a row hidden there under an
/// app bar would otherwise count as on screen.
Rect? getVisibleGlobalRect(RenderObject ro) {
  try {
    if (ro is RenderBox && ro.attached && ro.hasSize) {
      final path = <RenderObject>[ro];
      for (var node = ro.parent; node != null; node = node.parent) {
        path.add(node);
      }
      // The walk localToGlobal makes, reading each ancestor's clip on the
      // way. Like localToGlobal, it leaves out the root view's transform,
      // which maps logical pixels to physical ones.
      final transform = Matrix4.identity();
      Rect? clip;
      for (var i = path.length - 2; i > 0; i--) {
        final parent = path[i];
        final child = path[i - 1];
        final local = parent.describeApproximatePaintClip(child);
        if (local != null) {
          final global = MatrixUtils.transformRect(transform, local);
          clip = clip?.intersect(global) ?? global;
        }
        parent.applyPaintTransform(child, transform);
      }
      // The box's corners, not its origin plus its size, so a flipped or
      // scaled box is measured where it shows.
      final rect = MatrixUtils.transformRect(transform, Offset.zero & ro.size);
      if (!rect.isFinite) return null;
      if (clip == null) return rect;
      if (clip.isEmpty || !rect.overlaps(clip)) return null;
      return rect.intersect(clip);
    }
  } catch (e, s) {
    assert(() {
      debugPrint('Sleuth: getVisibleGlobalRect failed: $e\n$s');
      return true;
    }());
  }
  return null;
}
