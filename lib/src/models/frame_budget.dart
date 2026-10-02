import 'dart:math' as math;

/// Where the effective frame rate behind a [FrameBudget] came from.
enum FrameRateSource {
  /// `SleuthConfig.fpsTarget` alone: auto budget disabled, no cadence
  /// measured yet, or the measured cadence fell below `fpsTarget`.
  fixed,

  /// The measured cadence exceeded the display's reported refresh rate and
  /// was clamped down to it.
  display,

  /// The measured vsync cadence, snapped to a common refresh rate.
  measured,
}

/// Per-frame time budget resolved by [resolveFrameBudget].
class FrameBudget {
  const FrameBudget({
    required this.budgetUs,
    required this.effectiveHz,
    required this.source,
  });

  /// Frame budget in microseconds (`1e6 / effectiveHz`, rounded).
  final int budgetUs;

  /// Frame rate the budget is derived from.
  final double effectiveHz;

  /// Where [effectiveHz] came from.
  final FrameRateSource source;

  @override
  bool operator ==(Object other) =>
      other is FrameBudget &&
      other.budgetUs == budgetUs &&
      other.effectiveHz == effectiveHz &&
      other.source == source;

  @override
  int get hashCode => Object.hash(budgetUs, effectiveHz, source);

  @override
  String toString() =>
      'FrameBudget(${budgetUs}us, ${effectiveHz.toStringAsFixed(1)} Hz, '
      '${source.name})';
}

const List<double> _kCommonRefreshRates = [30, 60, 90, 120, 144];
const double _kSnapTolerance = 0.08;

double _snap(double hz) {
  var nearest = _kCommonRefreshRates.first;
  for (final rate in _kCommonRefreshRates) {
    if ((hz - rate).abs() < (hz - nearest).abs()) nearest = rate;
  }
  return (hz - nearest).abs() <= nearest * _kSnapTolerance ? nearest : hz;
}

/// Resolves the per-frame budget from [fpsTarget], the display's reported
/// refresh rate, and the measured vsync cadence.
///
/// When [auto] is false the budget is `1e6 / fpsTarget` with source
/// [FrameRateSource.fixed].
///
/// When [auto] is true the effective rate is the measured cadence (snapped
/// to the nearest of 30/60/90/120/144 Hz when within 8 %), clamped to
/// `[fpsTarget, displayRefreshRateHz]`:
/// - The display rate is only an upper bound. iOS reports
///   `UIScreen.maximumFramesPerSecond` (120 on ProMotion) even while the
///   app renders at 60, so trusting it alone would halve the budget and
///   flag every 60 Hz frame as jank.
/// - `fpsTarget` is the lower bound. A janky app measures a slow cadence;
///   letting that loosen the budget would hide the jank being measured.
///
/// Without a measurement the effective rate is [fpsTarget]. A
/// non-positive or non-finite [displayRefreshRateHz] means "unknown" and
/// the cap falls back to [fpsTarget].
FrameBudget resolveFrameBudget({
  required int fpsTarget,
  required double displayRefreshRateHz,
  double? measuredCadenceHz,
  required bool auto,
}) {
  final target = fpsTarget.toDouble();
  if (!auto) return _budget(target, FrameRateSource.fixed);

  final displayKnown =
      displayRefreshRateHz.isFinite && displayRefreshRateHz > 0;
  final measured =
      measuredCadenceHz != null &&
          measuredCadenceHz.isFinite &&
          measuredCadenceHz > 0
      ? measuredCadenceHz
      : null;
  if (measured == null) return _budget(target, FrameRateSource.fixed);

  final cap = math.max(displayKnown ? displayRefreshRateHz : target, target);
  final candidate = _snap(measured);
  if (candidate < target) return _budget(target, FrameRateSource.fixed);
  if (candidate > cap) {
    return _budget(
      cap,
      displayKnown && cap == displayRefreshRateHz
          ? FrameRateSource.display
          : FrameRateSource.fixed,
    );
  }
  return _budget(candidate, FrameRateSource.measured);
}

FrameBudget _budget(double hz, FrameRateSource source) =>
    FrameBudget(budgetUs: (1e6 / hz).round(), effectiveHz: hz, source: source);
