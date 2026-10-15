// raster_dominance against recorded frames (`tool/demo_walk.dart --raw`):
// the 240 frames Sleuth held at one phase of a demo, from a Galaxy A07
// (Android 16, 90 Hz) and an iPhone 12 (iOS 17.5, 60 Hz), Flutter 3.47.6
// profile builds. Each fixture's provenance names the screen and phase, and
// its `expected` block holds the most missed raster-dominant frames inside
// one second and the outcome they call for.
import 'dart:developer' show Timeline;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/detectors/gpu_pressure_detector.dart';
import 'package:sleuth/src/models/performance_issue.dart';

import '../helpers/frame_fixture.dart';

const _dir = 'test/detectors/_fixtures/raster';

/// Replays the fixture's frames through `processFrame` in frame order, with
/// a scan whenever [scanEveryUs] of vsync time has passed (from the first
/// frame plus [phaseUs]) and one after the last frame, the way the
/// controller's scan loop interleaves them. Returns every `raster_dominance`
/// issue the scans produced.
List<PerformanceIssue> _replay(
  WidgetTester tester,
  String file, {
  int scanEveryUs = 1000000,
  int phaseUs = 0,
}) {
  final fixture = loadFrameFixture('$_dir/$file');
  final detector = GpuPressureDetector(
    appStartMonotonicUsForTest: () => Timeline.now - 60000000,
  );
  final root = tester.element(find.byType(SizedBox));
  final found = <PerformanceIssue>[];
  void scan() {
    detector.scanTree(root);
    found.addAll(
      detector.issues.where((i) => i.stableId == 'raster_dominance'),
    );
  }

  var nextScanUs = fixture.frames.first.vsyncStartUs! + phaseUs + scanEveryUs;
  for (final frame in fixture.frames) {
    while (frame.vsyncStartUs! >= nextScanUs) {
      scan();
      nextScanUs += scanEveryUs;
    }
    detector.processFrame(frame);
  }
  scan();
  detector.dispose();
  return found;
}

/// The most severe outcome across the scans: 'critical', 'warning' or
/// 'none'.
String _outcome(List<PerformanceIssue> issues) {
  if (issues.any((i) => i.severity == IssueSeverity.critical)) {
    return 'critical';
  }
  return issues.isEmpty ? 'none' : 'warning';
}

/// The largest count of frames inside one second any scan reported.
int _maxQualifying(List<PerformanceIssue> issues) {
  var best = 0;
  for (final issue in issues) {
    final match = RegExp(
      r'^(\d+) frames within one second',
    ).firstMatch(issue.detail);
    final count = int.parse(match!.group(1)!);
    if (count > best) best = count;
  }
  return best;
}

// The Galaxy's Live Waveform and High-Level setState recordings were made
// with Sleuth reading the timeline stream. Recorded while Sleuth still
// requested the timeline every 500 ms, both read warning from frames
// 500 ms apart, which the request had held on that phone's raster thread.
const _fixtures = [
  'galaxy_90_gpu_pressure.json',
  'galaxy_90_cupertino_blur.json',
  'galaxy_90_intrinsicheight_abuse.json',
  'galaxy_90_high_level_setstate.json',
  'galaxy_90_live_waveform.json',
  'galaxy_90_csv_import.json',
  'galaxy_90_non_lazy_listview.json',
  'iphone_60_gpu_pressure.json',
  'iphone_60_live_waveform.json',
];

void main() {
  for (final file in _fixtures) {
    final expected = loadFrameFixture('$_dir/$file').expected;
    final outcome = expected['rasterDominance'] as String;
    final maxMissed = expected['maxMissedPerSecond'] as int;

    testWidgets('$file: $maxMissed missed frames in one second → $outcome', (
      tester,
    ) async {
      await tester.pumpWidget(const SizedBox());
      final issues = _replay(tester, file);
      expect(_outcome(issues), outcome);
      for (final issue in issues) {
        expect(issue.confidence, IssueConfidence.likely);
        expect(issue.observationSource, ObservationSource.frameTiming);
      }
      // Below the critical count the 64-entry ring never fills, so the
      // scans find the recording's busiest second exactly.
      if (outcome != 'critical') {
        expect(_maxQualifying(issues), outcome == 'none' ? 0 : maxMissed);
      } else {
        expect(_maxQualifying(issues), greaterThanOrEqualTo(10));
      }
    });

    testWidgets('$file: the outcome holds at every scan phase and at a '
        '2 s scan interval', (tester) async {
      await tester.pumpWidget(const SizedBox());
      for (final phaseUs in [250000, 500000, 750000]) {
        expect(
          _outcome(_replay(tester, file, phaseUs: phaseUs)),
          outcome,
          reason: 'scan phase ${phaseUs ~/ 1000} ms',
        );
      }
      expect(
        _outcome(_replay(tester, file, scanEveryUs: 2000000)),
        outcome,
        reason: '2 s scan interval',
      );
    });
  }
}
