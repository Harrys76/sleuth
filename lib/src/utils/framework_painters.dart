import 'package:flutter/cupertino.dart' show CupertinoActivityIndicator;
import 'package:flutter/material.dart';

import 'type_name_cache.dart';

/// Whether the [CustomPaint] at [element] is drawn by a framework painter
/// rather than user code.
///
/// Two checks, in order:
///
/// 1. Type checks. Material/Cupertino Checkbox, Switch, and Radio painters
///    extend [ToggleablePainter] (whose `shouldRepaint` always returns true
///    by design); Material `Scrollbar` and `RawScrollbar` paint through
///    [ScrollbarPainter].
/// 2. Name plus owner. Private framework painters (Material shape borders,
///    input borders, tab indicators, progress indicators, overscroll
///    effects, ...) are matched by painter class name **and** the widget
///    that builds them must be an ancestor of the [CustomPaint] within a
///    measured hop budget. A user painter that happens to share a framework
///    name but sits outside the owner keeps being reported.
///
/// Obfuscated builds rename the private classes; the name check then
/// misses and the paint is treated as user code.
bool isFrameworkPainterPaint(Element element) {
  final widget = element.widget;
  if (widget is! CustomPaint) return false;
  return _isFrameworkPainter(widget.painter, element) ||
      _isFrameworkPainter(widget.foregroundPainter, element);
}

/// Whether the [ClipPath] at [element] is the one [Material] builds for
/// `MaterialType.transparency`: its parent element's widget is the
/// [Material] itself.
///
/// A user `ClipPath` placed as a Material's `child` sits below Material's
/// own clip, shape-border paint, and ink layers, so its parent is never
/// the [Material] and it stays reported.
bool isMaterialOwnClip(Element element) {
  if (element.widget is! ClipPath) return false;
  var parentIsMaterial = false;
  element.visitAncestorElements((ancestor) {
    parentIsMaterial = ancestor.widget is Material;
    return false;
  });
  return parentIsMaterial;
}

bool _isFrameworkPainter(CustomPainter? painter, Element element) {
  if (painter == null) return false;
  if (painter is ToggleablePainter || painter is ScrollbarPainter) {
    return true;
  }
  final name = baseTypeName(typeNameCache.lookupType(painter.runtimeType));
  final owner = _ownedPainters[name];
  return owner != null && owner.owns(element);
}

/// The widget that builds a framework painter, and how far above the
/// painter's [CustomPaint] it may sit.
class _PainterOwner {
  const _PainterOwner(this.isOwner, this.maxHops, {this.parentName});

  /// Matches the owner widget. Public owners use a type check; private
  /// owners and owners missing from the oldest supported SDK use a name.
  final bool Function(Widget widget) isOwner;

  /// Maximum ancestor hops from the [CustomPaint] element to the owner.
  final int maxHops;

  /// When set, the [CustomPaint]'s parent element widget must carry this
  /// type name.
  final String? parentName;

  bool owns(Element element) {
    var hops = 0;
    var found = false;
    element.visitAncestorElements((ancestor) {
      hops++;
      final widget = ancestor.widget;
      if (hops == 1 &&
          parentName != null &&
          baseTypeName(typeNameCache.lookup(widget)) != parentName) {
        return false;
      }
      if (isOwner(widget)) {
        found = true;
        return false;
      }
      return hops < maxHops;
    });
    return found;
  }
}

bool _isMaterial(Widget w) => w is Material;
bool _isInputDecorator(Widget w) => w is InputDecorator;
bool _isTabBar(Widget w) => w is TabBar;
bool _isProgressIndicator(Widget w) => w is ProgressIndicator;
bool _isCupertinoActivityIndicator(Widget w) => w is CupertinoActivityIndicator;
bool _isGlowingOverscroll(Widget w) => w is GlowingOverscrollIndicator;
bool _isStretchingOverscroll(Widget w) => w is StretchingOverscrollIndicator;
bool _isAnimatedIcon(Widget w) => w is AnimatedIcon;
bool _isPlaceholder(Widget w) => w is Placeholder;
bool _isGridPaper(Widget w) => w is GridPaper;

// Not public on every supported SDK: matched by name.
bool _isCupertinoLinearActivityIndicator(Widget w) =>
    typeNameCache.lookup(w) == 'CupertinoLinearActivityIndicator';
bool _isDropdownMenu(Widget w) =>
    baseTypeName(typeNameCache.lookup(w)) == '_DropdownMenu';

/// Framework painters that sit on steady screens, keyed by painter class
/// name. Budgets sit at or just above the hops measured from the
/// [CustomPaint] element to the owner on Flutter 3.32 and 3.47 (listed as
/// 3.32/3.47):
///
/// - `_ShapeBorderPainter`: parent `_ShapeBorderPaint` (1), `Material` 3-4
///   on both (Card, buttons, FAB, dialogs, menus).
/// - `_InputBorderPainter`: `InputDecorator` 3/4.
/// - `_IndicatorPainter`: `TabBar` 3/11 fixed, 19/27 scrollable.
/// - `_DividerPainter`: `TabBar` 2/10.
/// - Linear / circular / refresh progress painters: `ProgressIndicator`
///   4/4, 4/5, 17/17.
/// - `_CupertinoActivityIndicatorPainter`: `CupertinoActivityIndicator` 2.
/// - `_CupertinoLinearActivityIndicator` (3.47 only):
///   `CupertinoLinearActivityIndicator` 2.
/// - `_GlowingOverscrollIndicatorPainter`: `GlowingOverscrollIndicator` 3.
/// - `_StretchEffectPainter` (3.47 only, shader-filter platforms):
///   `StretchingOverscrollIndicator` 7, read from the framework source
///   because the test engine has no shader filters.
/// - `_AnimatedIconPainter`: `AnimatedIcon` 2.
/// - `_DropdownMenuPainter`: `_DropdownMenu` 2.
/// - `_PlaceholderPainter`: `Placeholder` 2. `_GridPaperPainter`:
///   `GridPaper` 1.
const _ownedPainters = <String, _PainterOwner>{
  '_ShapeBorderPainter': _PainterOwner(
    _isMaterial,
    4,
    parentName: '_ShapeBorderPaint',
  ),
  '_InputBorderPainter': _PainterOwner(_isInputDecorator, 5),
  '_IndicatorPainter': _PainterOwner(_isTabBar, 28),
  '_DividerPainter': _PainterOwner(_isTabBar, 11),
  '_LinearProgressIndicatorPainter': _PainterOwner(_isProgressIndicator, 5),
  '_CircularProgressIndicatorPainter': _PainterOwner(_isProgressIndicator, 6),
  '_RefreshProgressIndicatorPainter': _PainterOwner(_isProgressIndicator, 18),
  '_CupertinoActivityIndicatorPainter': _PainterOwner(
    _isCupertinoActivityIndicator,
    3,
  ),
  '_CupertinoLinearActivityIndicator': _PainterOwner(
    _isCupertinoLinearActivityIndicator,
    3,
  ),
  '_GlowingOverscrollIndicatorPainter': _PainterOwner(_isGlowingOverscroll, 4),
  '_StretchEffectPainter': _PainterOwner(_isStretchingOverscroll, 8),
  '_AnimatedIconPainter': _PainterOwner(_isAnimatedIcon, 3),
  '_DropdownMenuPainter': _PainterOwner(_isDropdownMenu, 3),
  '_PlaceholderPainter': _PainterOwner(_isPlaceholder, 3),
  '_GridPaperPainter': _PainterOwner(_isGridPaper, 2),
};

/// Exposed for tests: every framework painter name in the owner table.
@visibleForTesting
Iterable<String> get frameworkPainterNames => _ownedPainters.keys;
