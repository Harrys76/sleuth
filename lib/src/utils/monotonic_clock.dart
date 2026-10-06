/// Returns a clock whose readings advance with a [Stopwatch] instead of
/// the system wall clock, anchored at the wall-clock time of the call.
///
/// Window arithmetic that divides by elapsed time must not see the
/// system clock jump (NTP sync, manual time change); readings from this
/// clock only move forward and their differences are real elapsed time.
DateTime Function() monotonicClock() {
  final anchor = DateTime.now();
  final stopwatch = Stopwatch()..start();
  return () => anchor.add(stopwatch.elapsed);
}
