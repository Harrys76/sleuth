import 'package:flutter/widgets.dart';

/// Tells the elements of Sleuth's own overlay apart from the app's.
///
/// `SleuthOverlay` registers its element and the key of the widget that
/// holds the app. An element belongs to the overlay when the walk up from
/// it (itself first) reaches a registered overlay element before a widget
/// keyed with a registered app key; elements above every overlay and
/// trees without an overlay belong to the app. Debug rebuild and paint
/// counts use this to leave out the overlay's own widgets, which would
/// otherwise report as the app's.
///
/// Results are cached per element (weakly) and dropped whenever a
/// registration changes. An element never moves between the overlay and
/// the app: the app cannot place widgets inside the overlay, so a
/// reparented element keeps its side.
abstract final class OverlayOwnership {
  static final Expando<bool> _overlayElements = Expando<bool>(
    'SleuthOverlayElement',
  );
  static final Expando<bool> _appKeys = Expando<bool>('SleuthAppKey');

  /// Cached decision per element: `generation << 1 | owned`.
  static final Expando<int> _decisions = Expando<int>('SleuthOverlayOwned');

  static int _generation = 0;
  static int _registered = 0;

  /// Registers [overlay] as an overlay root whose app sits under the
  /// widget keyed [appKey].
  static void register(Element overlay, Key appKey) {
    if (_overlayElements[overlay] == true) return;
    _overlayElements[overlay] = true;
    _appKeys[appKey] = true;
    _registered++;
    _generation++;
  }

  /// Removes a registration made by [register].
  static void unregister(Element overlay, Key appKey) {
    if (_overlayElements[overlay] != true) return;
    _overlayElements[overlay] = null;
    _appKeys[appKey] = null;
    _registered--;
    _generation++;
  }

  /// Whether [element] belongs to a registered Sleuth overlay.
  static bool isOverlayOwned(Element element) {
    if (_registered == 0) return false;
    bool? owned = _decide(element);
    if (owned != null) return owned;
    final visited = <Element>[element];
    try {
      element.visitAncestorElements((ancestor) {
        owned = _decide(ancestor);
        if (owned != null) return false;
        visited.add(ancestor);
        return true;
      });
    } catch (_) {
      // An element outside the active tree cannot be walked; it is not
      // cached and counts as the app's.
      return false;
    }
    final result = owned ?? false;
    final stamp = _generation << 1 | (result ? 1 : 0);
    for (final e in visited) {
      _decisions[e] = stamp;
    }
    return result;
  }

  static bool? _decide(Element element) {
    final cached = _decisions[element];
    if (cached != null && cached >> 1 == _generation) return cached & 1 == 1;
    if (_overlayElements[element] == true) return true;
    final key = element.widget.key;
    if (key != null && _appKeys[key] == true) return false;
    return null;
  }
}
