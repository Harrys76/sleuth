import 'package:flutter/widgets.dart';

/// Per-scan cache for `widget.runtimeType.toString()` results.
///
/// In a typical Flutter app, there are O(50-200) unique widget types but
/// O(5,000+) elements. Without caching, detectors calling
/// `runtimeType.toString()` per element create thousands of duplicate
/// string allocations per scan. This cache reduces that to one allocation
/// per unique [Type].
///
/// Usage:
///   - Call [clear] once at the start of each scan cycle.
///   - Replace `widget.runtimeType.toString()` with [lookup] everywhere.
///
/// Follows the same module-level singleton pattern as [sourceLocationCache].
class TypeNameCache {
  final _cache = <Type, String>{};

  /// Returns the cached type name for [widget], computing it on first access.
  String lookup(Widget widget) {
    final type = widget.runtimeType;
    return _cache[type] ??= type.toString();
  }

  /// Clears the cache. Call once per scan cycle from the controller.
  void clear() => _cache.clear();

  /// Current number of cached entries (exposed for testing).
  int get length => _cache.length;
}

/// Module-level cache shared across all detectors.
///
/// Cleared by [SleuthController] before each unified tree walk.
final typeNameCache = TypeNameCache();

/// Strips a generic suffix (`<...>`) from a runtime-type name.
///
/// `runtimeType.toString()` preserves generic arguments, so production
/// widgets surface as `StreamBuilder<int>` / `_ModalScope<dynamic>` etc.
/// Detectors that match against bare-name allowlists (`_builderWidgetTypes`,
/// framework filters) need the canonical base name to compare correctly.
/// Returns the input unchanged for non-generic names.
String baseTypeName(String typeName) {
  final i = typeName.indexOf('<');
  return i >= 0 ? typeName.substring(0, i) : typeName;
}
