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

/// Re-provides the ambient [MediaQuery] with its text scaler clamped to
/// [minScaleFactor]..[maxScaleFactor]. Nested clamps compose: the inner
/// range is intersected with the outer one.
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
        textScaler: data.textScaler.clamp(
          minScaleFactor: minScaleFactor,
          maxScaleFactor: maxScaleFactor,
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
