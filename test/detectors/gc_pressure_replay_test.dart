// gc_pressure against recorded GC event dumps (`tool/device_pass.dart
// gc-dump`, 10 s each) from a Galaxy A07 (Android 16) and an iPhone 12
// (iOS 17.5), Flutter 3.47.6 profile builds. Each fixture's provenance
// names the screen.
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/detectors/memory_pressure_detector.dart';
import 'package:sleuth/src/models/performance_issue.dart';

import '../helpers/gc_fixture.dart';

const _dir = 'test/detectors/_fixtures/gc';

/// Feeds the dump's app-isolate events through `recordGcCycle` with the
/// detector clock at each event's time, at the default threshold, and
/// returns the last `gc_pressure` issue seen, or null.
PerformanceIssue? replay(String file) {
  final events = loadGcEvents('$_dir/$file');
  // A live session has a pause baseline long before any 10 s window. Prime
  // it with one sweep 11 s before the dump, which leaves the window before
  // the first evaluation; the first recorded event then counts no pause.
  var now = events.first.at.subtract(const Duration(seconds: 11));
  final detector = MemoryPressureDetector(clock: () => now, warmupDurationMs: 0)
    ..recordGcCycle(
      gcType: 'MarkSweep',
      cumulativePauseSeconds: events.first.cumulativePauseSeconds,
      pauseAttributable: true,
    );
  PerformanceIssue? last;
  for (final e in events) {
    now = e.at;
    detector.recordGcCycle(
      gcType: e.gcType,
      reason: e.reason,
      cumulativePauseSeconds: e.cumulativePauseSeconds,
      pauseAttributable: true,
    );
    for (final issue in detector.issues) {
      if (issue.stableId == 'gc_pressure') last = issue;
    }
  }
  detector.dispose();
  return last;
}

void main() {
  test('Galaxy A07, GC Churn: young collections fire gc_pressure', () {
    final issue = replay('galaxy_gc_churn.json');
    expect(issue, isNotNull);
    expect(issue!.title, contains('young GCs/min'));
  });

  test('iPhone 12, GC Churn: young collections fire gc_pressure', () {
    expect(replay('ios_gc_churn.json'), isNotNull);
  });

  test('Galaxy A07 at 60 Hz, Live Waveform: animation stays silent', () {
    // 20 scavenges and 10 concurrent old-gen cycles (marking start plus
    // sweep) in 10 s: 40 events, 120 young a minute.
    expect(replay('galaxy_live_waveform_60hz.json'), isNull);
  });

  test('iPhone 12, Live Waveform: promotion-driven marks stay silent', () {
    // 28 scavenges and 41 old-gen events (marks with reason promotion,
    // sweeps with reason finalize) in 10 s.
    expect(replay('ios_live_waveform.json'), isNull);
  });

  test('Galaxy A07 at 90 Hz, Live Waveform: 41 young collections fire, '
      'with GC pauses taking several percent of the time', () {
    // Scavenges rise with the frame rate. This screen spent more of its
    // time in GC pauses than the churn demo, so the card reports real cost.
    final issue = replay('galaxy_live_waveform_90hz.json');
    expect(issue, isNotNull);
    expect(issue!.extraTraceArgs!['scavengeCount'], '41');
    expect(
      double.parse(issue.extraTraceArgs!['gcPausePercent']!),
      greaterThanOrEqualTo(3),
    );
  });
}
