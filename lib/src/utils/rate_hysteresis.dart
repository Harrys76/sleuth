import 'package:flutter/foundation.dart';

/// A per-type rate that is currently reported.
@immutable
class HeldRate {
  const HeldRate({
    required this.count,
    required this.seconds,
    required this.critical,
  });

  /// Events behind [rate]: the entering window's count, then the last
  /// two windows' summed count.
  final int count;

  /// Window length behind [count], in seconds.
  final double seconds;

  final bool critical;

  double get rate => seconds > 0 ? count / seconds : 0;
}

/// Keeps per-type debug rates from flipping on and off between scans.
///
/// A scan window's count of a periodic event depends on where the
/// window's two edges fall in the event's phase, so a widget rebuilding
/// exactly 10 times a second reads 9 to 11/s over 1 s windows and crosses
/// a 10/s threshold on alternate scans. A type enters when one window
/// reaches its threshold and leaves when the summed count of the last two
/// windows over their summed length falls below [exitFactor] times the
/// threshold, or at once on a window where it did not occur at all
/// (adjacent windows share an edge, so their phase errors cancel in the
/// sum). Severity works the same way around the critical boundary.
class RateHysteresis {
  RateHysteresis({this.exitFactor = 0.75});

  /// Fraction of a threshold a held rate must fall below to clear.
  final double exitFactor;

  Map<String, HeldRate> _held = const {};
  Map<String, int>? _previousCounts;
  int _previousUs = 0;
  bool _previousCapped = false;

  /// The types currently reported.
  Map<String, HeldRate> get held => _held;

  /// Feeds one window of per-type [counts] over [elapsedUs].
  ///
  /// [thresholdFor] gives a type's alert rate; a rate above it times
  /// [criticalMultiplier] is critical. A type missing from [counts] did
  /// not occur, unless [capped] says some types were left out, in which
  /// case a held type keeps its state. A window with no length changes
  /// nothing.
  void update({
    required Map<String, int> counts,
    required int elapsedUs,
    required bool capped,
    required double Function(String type) thresholdFor,
    required double criticalMultiplier,
  }) {
    if (elapsedUs <= 0) return;
    final seconds = elapsedUs / Duration.microsecondsPerSecond;
    final previous = _previousCounts;
    final next = <String, HeldRate>{};
    for (final type in {...counts.keys, ..._held.keys}) {
      final count = counts[type];
      final was = _held[type];
      if (count == null && capped) {
        if (was != null) next[type] = was;
        continue;
      }
      final current = count ?? 0;
      final threshold = thresholdFor(type);
      final criticalAt = threshold * criticalMultiplier;
      if (was == null) {
        final rate = current / seconds;
        if (rate < threshold) continue;
        next[type] = HeldRate(
          count: current,
          seconds: seconds,
          critical: rate > criticalAt,
        );
        continue;
      }
      if (current == 0) continue;
      final previousCount = previous?[type];
      final summable =
          previous != null && (previousCount != null || !_previousCapped);
      final summedCount = current + (summable ? previousCount ?? 0 : 0);
      final summedSeconds =
          seconds +
          (summable ? _previousUs / Duration.microsecondsPerSecond : 0);
      final rate = summedCount / summedSeconds;
      if (rate < threshold * exitFactor) continue;
      next[type] = HeldRate(
        count: summedCount,
        seconds: summedSeconds,
        critical: was.critical
            ? rate >= criticalAt * exitFactor
            : current / seconds > criticalAt,
      );
    }
    _held = next;
    _previousCounts = Map<String, int>.of(counts);
    _previousUs = elapsedUs;
    _previousCapped = capped;
  }

  /// Forgets every held type and the previous window.
  void reset() {
    _held = const {};
    _previousCounts = null;
    _previousUs = 0;
    _previousCapped = false;
  }
}
