import 'package:flutter/widgets.dart';

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
};

/// Builds a human-readable ancestor chain from an Element, helping
/// users locate the widget in their source code.
///
/// Walks up the tree to find the nearest user page/screen widget,
/// then shows the path down to the flagged element.
///
/// Example output: "NestedScrollDemo > Column > SingleChildScrollView"
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

  return chain.reversed.join(' > ');
}

/// Get the global bounding rect for a RenderObject, or null if unavailable.
Rect? getGlobalRect(RenderObject ro) {
  try {
    if (ro is RenderBox && ro.hasSize) {
      return ro.localToGlobal(Offset.zero) & ro.size;
    }
  } catch (_) {}
  return null;
}
