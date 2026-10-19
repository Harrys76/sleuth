import 'package:flutter/foundation.dart';

/// Unit of an [IssueMeasurement] value and its threshold lines.
///
/// A class with const instances instead of an enum, so a later release can
/// add a unit without breaking an exhaustive `switch` in calling code. A
/// custom detector can name its own unit; units compare by [name].
@immutable
final class MeasurementUnit {
  const MeasurementUnit(this.name);

  /// Wire name, used as the `unit` value in issue JSON.
  final String name;

  /// Duration in milliseconds.
  static const milliseconds = MeasurementUnit('milliseconds');

  /// Duration in seconds.
  static const seconds = MeasurementUnit('seconds');

  /// Share in percent, 0 to 100.
  static const percent = MeasurementUnit('percent');

  /// Size in bytes.
  static const bytes = MeasurementUnit('bytes');

  /// Growth rate in bytes per second.
  static const bytesPerSecond = MeasurementUnit('bytesPerSecond');

  /// Number of things counted, such as widgets, instances or requests.
  /// [IssueMeasurement.window] gives the span when the count is per window.
  static const count = MeasurementUnit('count');

  /// Events per second.
  static const perSecond = MeasurementUnit('perSecond');

  /// Events per minute.
  static const perMinute = MeasurementUnit('perMinute');

  /// Number of frames.
  static const frames = MeasurementUnit('frames');

  /// The units built-in detectors use, in declaration order.
  static const List<MeasurementUnit> values = [
    milliseconds,
    seconds,
    percent,
    bytes,
    bytesPerSecond,
    count,
    perSecond,
    perMinute,
    frames,
  ];

  /// The built-in unit whose [name] is [name], else a unit with that name
  /// (one a newer release or a custom detector added). Null when [name] is
  /// not a non-empty string.
  static MeasurementUnit? fromName(Object? name) {
    if (name is! String || name.isEmpty) return null;
    for (final unit in values) {
      if (unit.name == name) return unit;
    }
    return MeasurementUnit(name);
  }

  @override
  bool operator ==(Object other) =>
      other is MeasurementUnit && other.name == name;

  @override
  int get hashCode => name.hashCode;

  @override
  String toString() => name;
}

/// The number a detector reported with an issue, with the detector's
/// warning and critical lines.
///
/// A line is null when the detector has no line at that severity. A value
/// at or above a line reaches that severity, or only a value above it when
/// the line's strict flag ([warningStrict], [criticalStrict]) is set.
/// Every measurement is higher-is-worse. A custom detector's must be too,
/// since the class has no way to mark a lower value as worse.
///
/// Most titles show the value; `raster_dominance` titles show a
/// raster-to-UI ratio and `heap_near_capacity` titles a percent of the
/// budget instead. The issue's severity is the detector's, and some
/// detectors take it from a different reading than the value, so the two
/// can disagree in either direction. Rebuild and paint shares and debug
/// rates hold a severity until the value stays low, and
/// `heap_near_capacity` tolerates one sample under its line, so a value
/// can sit below the line of the severity shown. Debug rates also go
/// critical only on the latest window's rate while the value averages the
/// last two windows, so a warning can carry a value above the critical
/// line.
@immutable
final class IssueMeasurement {
  /// [strict] sets both lines' strict flags; [warningStrict] and
  /// [criticalStrict] override it for one line. A flag is false when its
  /// line is null.
  const IssueMeasurement({
    required this.value,
    required this.unit,
    this.warningAt,
    this.criticalAt,
    this.window,
    bool strict = false,
    bool? warningStrict,
    bool? criticalStrict,
  }) : warningStrict = warningAt != null && (warningStrict ?? strict),
       criticalStrict = criticalAt != null && (criticalStrict ?? strict);

  /// Longest `windowMs` [fromJson] accepts, about 31 years.
  static const double _maxWindowMs = 1e12;

  /// Value the detector measured.
  final double value;

  /// Unit of [value], [warningAt] and [criticalAt].
  final MeasurementUnit unit;

  /// Line for a warning, or null.
  final double? warningAt;

  /// Line for critical, or null.
  final double? criticalAt;

  /// Span the value was counted over, for counts and rates measured in a
  /// window (for example, requests in 5 s). Null when the value is not
  /// tied to a window.
  final Duration? window;

  /// Whether a value must exceed [warningAt] to reach it. False without a
  /// warning line.
  final bool warningStrict;

  /// Whether a value must exceed [criticalAt] to reach it. False without a
  /// critical line.
  final bool criticalStrict;

  /// Whether [value] is a finite number. JSON cannot encode NaN or
  /// infinity, so `PerformanceIssue.toJson` leaves out a measurement whose
  /// value is not finite, and [toJson] leaves out a line that is not.
  bool get hasFiniteValue => value.isFinite;

  /// Writes [value] as it is, so a caller that encodes the map itself
  /// checks [hasFiniteValue] first. A line that is not finite is left out
  /// together with its strict flag.
  Map<String, dynamic> toJson() {
    final warning = _finite(warningAt);
    final critical = _finite(criticalAt);
    return {
      'value': value,
      'unit': unit.name,
      'warningAt': ?warning,
      'criticalAt': ?critical,
      'windowMs': ?_windowMs,
      if (warningStrict && warning != null) 'warningStrict': true,
      if (criticalStrict && critical != null) 'criticalStrict': true,
    };
  }

  /// Reads a measurement written by [toJson]. Returns null when [json] is
  /// not a map, when `value` is missing or not a finite number, or when
  /// `unit` is not a non-empty string; a unit this release does not know
  /// is kept by name. A line or window that is not a finite, in-range
  /// number is dropped, and so is a strict flag without its line.
  /// `windowMs` may carry a fraction; it is read to the microsecond.
  static IssueMeasurement? fromJson(Object? json) {
    if (json is! Map) return null;
    final value = json['value'];
    final unit = MeasurementUnit.fromName(json['unit']);
    if (value is! num || !value.isFinite || unit == null) return null;
    final windowMs = json['windowMs'];
    return IssueMeasurement(
      value: value.toDouble(),
      unit: unit,
      warningAt: _finite(json['warningAt']),
      criticalAt: _finite(json['criticalAt']),
      window:
          windowMs is num &&
              windowMs.isFinite &&
              windowMs >= 0 &&
              windowMs <= _maxWindowMs
          ? Duration(
              microseconds: (windowMs * Duration.microsecondsPerMillisecond)
                  .round(),
            )
          : null,
      warningStrict: json['warningStrict'] == true,
      criticalStrict: json['criticalStrict'] == true,
    );
  }

  /// [window] in milliseconds when [fromJson] can read it back, else null.
  double? get _windowMs {
    final w = window;
    if (w == null || w.isNegative) return null;
    final ms = w.inMicroseconds / Duration.microsecondsPerMillisecond;
    return ms <= _maxWindowMs ? ms : null;
  }

  static double? _finite(Object? raw) =>
      raw is num && raw.isFinite ? raw.toDouble() : null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is IssueMeasurement &&
          value == other.value &&
          unit == other.unit &&
          warningAt == other.warningAt &&
          criticalAt == other.criticalAt &&
          window == other.window &&
          warningStrict == other.warningStrict &&
          criticalStrict == other.criticalStrict;

  @override
  int get hashCode => Object.hash(
    value,
    unit,
    warningAt,
    criticalAt,
    window,
    warningStrict,
    criticalStrict,
  );

  @override
  String toString() =>
      'IssueMeasurement($value $unit, warning: $warningAt'
      '${warningStrict ? ' (strict)' : ''}, critical: $criticalAt'
      '${criticalStrict ? ' (strict)' : ''}, window: $window)';
}
