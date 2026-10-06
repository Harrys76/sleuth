import 'package:flutter/foundation.dart' show clampDouble;
import 'package:flutter/widgets.dart';

/// Largest text scale the overlay content follows. iOS accessibility sizes
/// reach 3.1x; above 2.0x the overlay's pages stop fitting a phone.
const double kOverlayMaxTextScale = 2.0;

/// Smallest text scale the overlay follows, so a user's smaller-than-default
/// text setting is kept.
const double kOverlayMinTextScale = 0.8;

/// Largest text scale of the overlay chrome (card header, summary bar,
/// status row, footer, badges, trigger): fixed-height rows that must keep
/// the issue list visible.
const double kChromeMaxTextScale = 1.3;

/// Returns [base] limited to `min * fontSize..max * fontSize`.
///
/// Unlike [TextScaler.clamp], never asserts: a range that does not overlap
/// one the host app already applied (for example through
/// `MediaQuery.withClampedTextScaling`) gives a fixed scale instead of an
/// assertion failure on Flutter versions whose clamped scaler requires
/// overlapping ranges. A non-linear [base] stays non-linear inside the
/// range. Clamping the result again composes the ranges: the later range
/// limits the earlier one, and an empty overlap pins the scale to the
/// nearest bound of the later range. [min] greater than [max] gives a fixed
/// scale of [max].
TextScaler clampTextScaler(
  TextScaler base, {
  double min = 0,
  double max = double.infinity,
}) {
  if (min > max) min = max;
  if (base is _SleuthClampedTextScaler) {
    return base._compose(min, max);
  }
  if (min <= 0 && max == double.infinity) return base;
  return _SleuthClampedTextScaler(base, min, max);
}

/// A [TextScaler] that limits [base] to `min..max` without calling
/// `base.clamp`.
@immutable
final class _SleuthClampedTextScaler extends TextScaler {
  const _SleuthClampedTextScaler(this.base, this.min, this.max);

  final TextScaler base;
  final double min;
  final double max;

  bool get _fixed => min == max;

  @override
  double scale(double fontSize) => _fixed
      ? min * fontSize
      : clampDouble(base.scale(fontSize), min * fontSize, max * fontSize);

  @override
  double get textScaleFactor =>
      // ignore: deprecated_member_use
      _fixed ? min : clampDouble(base.textScaleFactor, min, max);

  @override
  TextScaler clamp({
    double minScaleFactor = 0,
    double maxScaleFactor = double.infinity,
  }) => clampTextScaler(this, min: minScaleFactor, max: maxScaleFactor);

  /// This range limited to `newMin..newMax`: equal to clamping this
  /// scaler's output to the new range.
  _SleuthClampedTextScaler _compose(double newMin, double newMax) {
    final lo = clampDouble(min, newMin, newMax);
    final hi = clampDouble(max, newMin, newMax);
    if (lo == min && hi == max) return this;
    return _SleuthClampedTextScaler(base, lo, hi);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is _SleuthClampedTextScaler &&
        other.min == min &&
        other.max == max &&
        (_fixed || other.base == base);
  }

  @override
  int get hashCode => _fixed ? min.hashCode : Object.hash(base, min, max);

  @override
  String toString() =>
      _fixed ? 'fixed (${min}x)' : '$base clamped [$min, $max]';
}

/// Re-provides the ambient [MediaQuery] with its text scaler clamped to
/// [minScaleFactor]..[maxScaleFactor] through [clampTextScaler]. Nested
/// clamps compose: the inner range limits the outer one.
///
/// Used in place of `MediaQuery.withClampedTextScaling`, whose `Builder`
/// would show up in the app's own rebuild counts.
class SleuthTextScaleClamp extends StatelessWidget {
  const SleuthTextScaleClamp({
    super.key,
    this.minScaleFactor = 0,
    required this.maxScaleFactor,
    required this.child,
  });

  final double minScaleFactor;
  final double maxScaleFactor;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // The full data is needed to re-provide it with a clamped scaler.
    final data = MediaQuery.maybeOf(context);
    if (data == null) return child;
    return MediaQuery(
      data: data.copyWith(
        textScaler: clampTextScaler(
          data.textScaler,
          min: minScaleFactor,
          max: maxScaleFactor,
        ),
      ),
      child: child,
    );
  }
}

/// Scale factor of the overlay chrome at [context]: the ambient text scale
/// limited to `1.0..kChromeMaxTextScale`. Fixed chrome heights are
/// multiplied by it so they grow with the text inside them.
double chromeScaleOf(BuildContext context) {
  final scaler = MediaQuery.maybeTextScalerOf(context) ?? TextScaler.noScaling;
  return (scaler.scale(14) / 14).clamp(1.0, kChromeMaxTextScale);
}

/// Text scale factor at [context] (1.0 without a [MediaQuery]).
double textScaleOf(BuildContext context) {
  final scaler = MediaQuery.maybeTextScalerOf(context) ?? TextScaler.noScaling;
  return scaler.scale(14) / 14;
}
