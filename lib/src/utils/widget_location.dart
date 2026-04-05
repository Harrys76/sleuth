import 'package:flutter/widgets.dart';

import 'source_location_cache.dart';

/// Module-level cache for widget source location lookups.
///
/// Shared across all [buildAncestorChain] calls. Bounded at 200 entries.
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
/// Example output (debug mode with source locations):
///   "NestedScrollDemo > Column > SingleChildScrollView (lib/screens/demo.dart:42)"
/// Example output (profile mode or tracking unavailable):
///   "NestedScrollDemo > Column > SingleChildScrollView"
String buildAncestorChain(Element element, {int maxDepth = 6}) {
  final chain = <String>[element.widget.runtimeType.toString()];

  element.visitAncestorElements((ancestor) {
    final name = ancestor.widget.runtimeType.toString();
    // Skip private and known framework widgets
    if (name.startsWith('_') || _frameworkNames.contains(name)) {
      return true; // keep walking
    }
    chain.add(name);
    return chain.length < maxDepth + 1;
  });

  final base = chain.reversed.join(' > ');

  // Append source location for the leaf element when available (debug mode).
  final sourceLocation = sourceLocationCache.lookup(element);
  if (sourceLocation != null) {
    return '$base ($sourceLocation)';
  }
  return base;
}

/// Get the global bounding rect for a RenderObject, or null if unavailable.
Rect? getGlobalRect(RenderObject ro) {
  try {
    if (ro is RenderBox && ro.hasSize) {
      return ro.localToGlobal(Offset.zero) & ro.size;
    }
  } catch (e, s) {
    assert(() {
      debugPrint('Sleuth: getGlobalRect failed: $e\n$s');
      return true;
    }());
  }
  return null;
}
