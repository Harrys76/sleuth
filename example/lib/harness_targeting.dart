import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'demo_scaffold.dart';

// Target selection for the `ext.sleuthDemo.*` device-harness extensions.
//
// A depth-first walk meets the app before Sleuth's overlay, routes below
// before the current one, and the hidden tabs an IndexedStack keeps
// mounted. These lookups keep foreground matches only and prefer the last
// one in tree order, which paints on top. They read the tree without
// registering dependencies (`ModalRoute.of` and `Visibility.of` do), so a
// lookup never makes the elements it looked at rebuild on a later route or
// tab change.

/// Waits for the next frame, at most [timeout]. False when none came:
/// frames stop while the app is in the background, and `endOfFrame` alone
/// would never complete.
Future<bool> waitForFrame({
  Duration timeout = const Duration(seconds: 2),
}) async {
  try {
    await WidgetsBinding.instance.endOfFrame.timeout(timeout);
    return true;
  } on TimeoutException {
    return false;
  }
}

/// Whether [element] is in the foreground: mounted, onstage (not under an
/// [Offstage], a hidden [IndexedStack] child or an overlay entry below an
/// opaque one) and not in a route below its navigator's current route.
/// Children a list or viewport has scrolled out of view still count, since
/// scrolling reaches them.
bool isForeground(Element element) =>
    element.mounted && _isOnstage(element) && !_belowCurrentRoute(element);

/// The last foreground element that passes [test]. An overlay page comes
/// after the app in the tree and paints over it.
Element? findForeground(bool Function(Element) test) =>
    _matches(test).reversed.where(isForeground).firstOrNull;

/// The foreground [Text] or [Tooltip] labelled [text]: an exact label
/// first (a button), then any text containing it, so a description
/// paragraph that quotes a button label does not win.
Element? findText(String text) {
  String? label(Widget widget) {
    if (widget is Text) {
      return widget.data ?? widget.textSpan?.toPlainText();
    }
    if (widget is Tooltip) return widget.message;
    return null;
  }

  return findForeground((e) => label(e.widget)?.trim() == text) ??
      findForeground((e) => label(e.widget)?.contains(text) ?? false);
}

/// The foreground element whose [Semantics] widget carries [label] (exact,
/// then prefix match), for icon-only controls that have no text.
Element? findSemanticsLabel(String label) {
  String? of(Widget w) => w is Semantics ? w.properties.label : null;
  return findForeground((e) => of(e.widget) == label) ??
      findForeground((e) => of(e.widget)?.startsWith(label) ?? false);
}

/// The field `type` writes to: the focused [EditableText] when it is in
/// the foreground, else the last foreground one a tap at its centre would
/// reach (a field behind an open overlay page is skipped).
EditableTextState? findTypingTarget() {
  final focused = FocusManager.instance.primaryFocus?.context;
  if (focused is Element && focused.mounted) {
    final state =
        focused is StatefulElement && focused.state is EditableTextState
        ? focused.state as EditableTextState
        : focused.findAncestorStateOfType<EditableTextState>();
    final element = state?.context;
    if (element is Element && isForeground(element)) return state;
  }
  for (final element in _matches((e) => e.widget is EditableText).reversed) {
    if (isForeground(element) && _reachesCenter(element)) {
      return (element as StatefulElement).state as EditableTextState;
    }
  }
  return null;
}

/// The scrollable `scroll` and `fling` drive on the [horizontal] or
/// vertical axis. Candidates can scroll, have running tickers (an animated
/// scroll on a muted ticker never finishes), are in the foreground and sit
/// outside a demo's instruction header ([DemoScaffold.headerKey]). The
/// largest candidate a touch at its centre reaches wins, so an app list
/// behind an open overlay page loses to the page's list; when no candidate
/// is reachable, the largest one. Ties go to the later one, which paints
/// on top.
ScrollableState? findScrollable({required bool horizontal}) {
  final candidates = <(Element, ScrollableState, double)>[];
  for (final element in _matches(
    (e) => e is StatefulElement && e.state is ScrollableState,
  )) {
    final state = (element as StatefulElement).state as ScrollableState;
    final axis = state.widget.axis;
    final box = element.renderObject;
    if ((horizontal ? axis == Axis.horizontal : axis == Axis.vertical) &&
        state.position.hasContentDimensions &&
        state.position.maxScrollExtent > 0 &&
        TickerMode.getValuesNotifier(element).value.enabled &&
        box is RenderBox &&
        box.hasSize &&
        !_inDemoHeader(element) &&
        isForeground(element)) {
      candidates.add((element, state, box.size.width * box.size.height));
    }
  }
  ScrollableState? largest(Iterable<(Element, ScrollableState, double)> of) {
    ScrollableState? best;
    var bestArea = -1.0;
    for (final (_, state, area) in of) {
      if (area >= bestArea) {
        best = state;
        bestArea = area;
      }
    }
    return best;
  }

  return largest(candidates.where((c) => _reachesCenter(c.$1))) ??
      largest(candidates);
}

/// The centre of [element]'s render box in global logical pixels, or null
/// when it has no laid-out, attached box.
Offset? centerOf(Element element) {
  final ro = element.renderObject;
  if (ro is! RenderBox || !ro.hasSize || !ro.attached) return null;
  return ro.localToGlobal(ro.size.center(Offset.zero));
}

/// The id of the view [element] renders into, or null when it is not
/// attached to one. Hit tests and synthetic pointer events use it.
int? viewIdOf(Element element) {
  RenderObject? node = element.renderObject;
  while (node != null && node is! RenderView) {
    node = node.parent;
  }
  return node is RenderView ? node.flutterView.viewId : null;
}

/// Whether a pointer at [position] reaches [element]: its render object is
/// on the hit-test path, so nothing painted above it takes the touch.
bool reaches(Element element, Offset position) {
  final target = element.renderObject;
  final viewId = viewIdOf(element);
  if (target == null || viewId == null) return false;
  final result = HitTestResult();
  WidgetsBinding.instance.hitTestInView(result, position, viewId);
  return result.path.any((entry) => identical(entry.target, target));
}

/// Where [prepareTap] will tap, or why it will not.
class TapPoint {
  const TapPoint(Offset this.position, this.viewId) : error = null;

  const TapPoint.refused(String this.error) : position = null, viewId = 0;

  /// Global logical position of the target's centre; null when refused.
  final Offset? position;

  /// View the pointer events go to.
  final int viewId;

  /// `not_found` (the target left the tree or the foreground),
  /// `reveal_timeout` or `obscured`; null when [position] is set.
  final String? error;
}

/// Scrolls [element] into view, then checks it again before a tap: the
/// reveal spans frames, in which the target can unmount, leave the
/// foreground or end up under something else.
///
/// The reveal is bounded by [revealTimeout]: a scrollable whose tickers
/// are muted never finishes its animation, and a tap fired whenever it
/// did would land long after the call returned. A target that a touch at
/// its centre would not reach is refused as `obscured`.
Future<TapPoint> prepareTap(
  Element element, {
  Duration revealTimeout = const Duration(seconds: 2),
}) async {
  try {
    await Scrollable.ensureVisible(
      element,
      alignment: 0.5,
      duration: const Duration(milliseconds: 150),
    ).timeout(revealTimeout);
  } on TimeoutException {
    return const TapPoint.refused('reveal_timeout');
  } catch (_) {
    // Disposed during the reveal; checked below.
  }
  await waitForFrame();
  if (!isForeground(element)) return const TapPoint.refused('not_found');
  final center = centerOf(element);
  final viewId = viewIdOf(element);
  if (center == null || viewId == null) {
    return const TapPoint.refused('not_found');
  }
  if (!reaches(element, center)) return const TapPoint.refused('obscured');
  return TapPoint(center, viewId);
}

/// Every element under the root that passes [test], in tree order.
List<Element> _matches(bool Function(Element) test) {
  final found = <Element>[];
  void visit(Element element) {
    if (test(element)) found.add(element);
    element.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(visit);
  return found;
}

bool _reachesCenter(Element element) {
  final center = centerOf(element);
  return center != null && reaches(element, center);
}

bool _inDemoHeader(Element element) {
  var inside = false;
  element.visitAncestorElements((ancestor) {
    inside = ancestor.widget.key == DemoScaffold.headerKey;
    return !inside;
  });
  return inside;
}

/// Whether every ancestor lists the path to [element] among its onstage
/// children (the check finders use to skip offstage widgets). Lists and
/// viewports are skipped: they report children scrolled out of view as
/// offstage.
bool _isOnstage(Element element) {
  var onstage = true;
  var child = element;
  element.visitAncestorElements((ancestor) {
    if (ancestor is RenderObjectElement && !_scrolls(ancestor)) {
      var listed = false;
      ancestor.debugVisitOnstageChildren((c) {
        if (identical(c, child)) listed = true;
      });
      if (!listed) {
        onstage = false;
        return false;
      }
    }
    child = ancestor;
    return true;
  });
  return onstage;
}

bool _scrolls(RenderObjectElement element) {
  final renderObject = element.renderObject;
  return renderObject is RenderAbstractViewport ||
      (renderObject is RenderSliver && element.widget is! SliverOffstage);
}

/// Whether [element] sits in an overlay entry below its navigator's
/// current route: a page under a dialog, or under a route still sliding
/// in. Entries above the current route (an inserted overlay entry) count
/// as foreground. Nested navigators are checked from the inside out.
bool _belowCurrentRoute(Element element) {
  var below = false;
  Element child = element;
  Element? grandchild;
  OverlayState? overlay;
  Element? theater;
  Element? entry;
  element.visitAncestorElements((ancestor) {
    if (ancestor is StatefulElement) {
      final state = ancestor.state;
      if (state is OverlayState) {
        // An Overlay builds one theater element whose children are its
        // entries, bottom to top.
        overlay = state;
        theater = child;
        entry = grandchild;
      } else if (state is NavigatorState &&
          overlay != null &&
          identical(state.overlay, overlay)) {
        below = _entryBelowCurrentRoute(state, theater!, entry);
        if (below) return false;
      }
    }
    grandchild = child;
    child = ancestor;
    return true;
  });
  return below;
}

bool _entryBelowCurrentRoute(
  NavigatorState navigator,
  Element theater,
  Element? entry,
) {
  final route = _currentRoute(navigator);
  final page = route is ModalRoute ? route.subtreeContext : null;
  if (entry == null || page is! Element) return false;
  final current = _childOnPath(theater, page);
  final entries = <Element>[];
  theater.visitChildren(entries.add);
  final at = entries.indexOf(entry);
  final currentAt = current == null ? -1 : entries.indexOf(current);
  return at >= 0 && currentAt >= 0 && at < currentAt;
}

/// The navigator's current route. `popUntil` offers the top route to the
/// predicate first and pops nothing when the predicate accepts it; the
/// navigator has no other public read of its current route.
Route<dynamic>? _currentRoute(NavigatorState navigator) {
  Route<dynamic>? current;
  navigator.popUntil((route) {
    current = route;
    return true;
  });
  return current;
}

/// The child of [ancestor] on the path up from [element], or null when
/// [ancestor] is not above it.
Element? _childOnPath(Element ancestor, Element element) {
  Element? found;
  var child = element;
  element.visitAncestorElements((parent) {
    if (identical(parent, ancestor)) {
      found = child;
      return false;
    }
    child = parent;
    return true;
  });
  return found;
}
