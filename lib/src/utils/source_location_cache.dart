import 'package:flutter/widgets.dart';

/// Abbreviated "file:line" creation locations of widgets, cached per
/// [Element].
///
/// Uses [InspectorSerializationDelegate.additionalNodeProperties] to access
/// creation location data injected by the track-widget-creation kernel
/// transform. Flutter's tool applies it in every build mode except release,
/// and `flutter run` (debug or profile) and `flutter build apk` / `appbundle`
/// turn it on by default, so profile builds usually have locations. Returns
/// null when the build does not track widget creation: release builds,
/// `--no-track-widget-creation`, or an iOS build from `flutter build ios` /
/// `ipa`, which writes `TRACK_WIDGET_CREATION=false` into the generated
/// xcconfig (Xcode or fastlane archives that reuse it inherit the setting).
///
/// Keyed by element, not by widget type, because a type built in several
/// places, such as a `ValueListenableBuilder<int>` on two screens, has one
/// location per call site. An element keeps its first result, which goes
/// stale only when its parent swaps in the same widget type from another
/// call site. The [Expando]s drop entries together with their elements.
class SourceLocationCache {
  SourceLocationCache();

  /// Marks an element whose lookup found no location.
  static const Object _none = Object();

  Expando<Object> _locations = Expando('Sleuth source location');
  Expando<({String location, String? packageName})> _structured = Expando(
    'Sleuth structured source location',
  );
  bool? _trackingAvailable;
  int _resolved = 0;

  /// Returns abbreviated "file:line" for the [element]'s widget, or null.
  ///
  /// Returns null when the build does not track widget creation (release,
  /// `--no-track-widget-creation`, or an iOS build from `flutter build ios`
  /// / `ipa` without the setting).
  String? lookup(Element element) {
    _trackingAvailable ??= WidgetInspectorService.instance
        .isWidgetCreationTracked();
    if (!_trackingAvailable!) return null;

    final cached = _locations[element];
    if (cached != null) return cached is String ? cached : null;
    final location = _resolve(element);
    _locations[element] = location ?? _none;
    _resolved++;
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
    } catch (e, s) {
      assert(() {
        debugPrint('Sleuth: source location resolve failed: $e\n$s');
        return true;
      }());
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

  /// Returns structured location data for the [element]'s widget, or null.
  ///
  /// Unlike [lookup] which returns a formatted string, this returns the
  /// abbreviated path, line number, and extracted package name separately.
  ({String location, String? packageName})? lookupStructured(Element element) {
    if (lookup(element) == null) return null;
    return _structured[element] ??= _resolveStructured(element);
  }

  ({String location, String? packageName})? _resolveStructured(
    Element element,
  ) {
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

      return (
        location: '${abbreviatePath(file)}:$line',
        packageName: extractPackageName(file),
      );
    } catch (_) {
      return null;
    }
  }

  /// Extracts the package name from a source file path.
  ///
  /// - `/path/packages/my_app/lib/screens/home.dart` → `my_app`
  /// - `lib/screens/home.dart` → null (app root code)
  /// - `/path/packages/flutter/lib/src/widgets/container.dart` → `flutter`
  static String? extractPackageName(String path) {
    final normalized = path.replaceAll('\\', '/');
    final packagesIdx = normalized.lastIndexOf('/packages/');
    if (packagesIdx == -1) return null;

    final afterPackages = normalized.substring(
      packagesIdx + '/packages/'.length,
    );
    final libIdx = afterPackages.indexOf('/lib/');
    if (libIdx == -1) return null;

    final name = afterPackages.substring(0, libIdx);
    return name.isNotEmpty ? name : null;
  }

  /// Clears cached entries and resets the tracking availability flag.
  void clear() {
    _locations = Expando('Sleuth source location');
    _structured = Expando('Sleuth structured source location');
    _trackingAvailable = null;
    _resolved = 0;
  }

  /// Number of elements resolved since construction or the last [clear].
  int get length => _resolved;
}
