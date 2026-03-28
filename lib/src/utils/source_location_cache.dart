import 'package:flutter/widgets.dart';

/// Bounded cache of widget type → abbreviated "file:line" source locations.
///
/// Uses [InspectorSerializationDelegate.additionalNodeProperties] to access
/// creation location data injected by `--track-widget-creation` (the default
/// in debug mode). Returns null in profile mode or when tracking is disabled.
///
/// Cache is bounded by [maxEntries] — when full, new types are not cached
/// but existing lookups remain valid. Source locations are stable per widget
/// type, so eviction is unnecessary.
class SourceLocationCache {
  SourceLocationCache({this.maxEntries = 200});

  /// Maximum number of cached widget types.
  final int maxEntries;
  final Map<String, String> _cache = {};
  bool? _trackingAvailable;

  /// Returns abbreviated "file:line" for the [element]'s widget, or null.
  ///
  /// Results are cached by `widget.runtimeType`. Returns null when widget
  /// creation tracking is unavailable (profile mode, `--no-track-widget-creation`).
  String? lookup(Element element) {
    _trackingAvailable ??=
        WidgetInspectorService.instance.isWidgetCreationTracked();
    if (!_trackingAvailable!) return null;

    final typeName = element.widget.runtimeType.toString();
    if (_cache.containsKey(typeName)) return _cache[typeName];
    if (_cache.length >= maxEntries) return null;

    final location = _resolve(element);
    if (location != null) {
      _cache[typeName] = location;
    }
    return location;
  }

  /// Resolve the creation location for an element via the inspector
  /// serialization delegate — the only public path to creation location data.
  String? _resolve(Element element) {
    try {
      final node = element.toDiagnosticsNode();
      final delegate = InspectorSerializationDelegate(
        service: WidgetInspectorService.instance,
      );
      final props = delegate.additionalNodeProperties(node);
      final loc = props['creationLocation'];
      if (loc is! Map<String, Object?>) return null;

      final file = loc['file'] as String?;
      final line = loc['line'] as int?;
      if (file == null || line == null) return null;

      return '${abbreviatePath(file)}:$line';
    } catch (_) {
      return null;
    }
  }

  /// Strip path to `lib/...` form, or fall back to last 2 path segments.
  static String abbreviatePath(String path) {
    final libIndex = path.indexOf('lib/');
    if (libIndex >= 0) return path.substring(libIndex);
    final parts = path.split('/');
    if (parts.length >= 2) {
      return parts.sublist(parts.length - 2).join('/');
    }
    return path;
  }

  /// Clears cached entries and resets the tracking availability flag.
  void clear() {
    _cache.clear();
    _trackingAvailable = null;
  }

  /// Number of cached entries.
  int get length => _cache.length;
}
