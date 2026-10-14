// UI-thread gaps: stretches in which the thread that ran the frames
// recorded no event. The fixtures are real: UI-thread events around one
// late frame, read from the VM timeline of a profile build on each phone,
// where Sleuth's own timeline request held the thread.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/vm/timeline_parser.dart';
import 'package:vm_service/vm_service.dart';

int _covered(List<(int, int)> gaps, int from, int to) {
  var covered = 0;
  for (final (start, end) in gaps) {
    final s = start > from ? start : from;
    final e = end < to ? end : to;
    if (e > s) covered += e - s;
  }
  return covered;
}

TimelineEvent _e(String name, String ph, int ts, {int tid = 1, int? dur}) =>
    TimelineEvent.parse({
      'name': name,
      'cat': 'Embedder',
      'ph': ph,
      'ts': ts,
      'tid': tid,
      'pid': 1,
      'dur': ?dur,
    })!;

void main() {
  for (final file in const [
    'test/vm/_fixtures/vsync_gap_ios_profile.json',
    'test/vm/_fixtures/vsync_gap_android_profile.json',
  ]) {
    test('$file: the gap covers the late frame\'s start delay', () {
      final json =
          jsonDecode(File(file).readAsStringSync()) as Map<String, dynamic>;
      final frame = json['frame'] as Map<String, dynamic>;
      final events = [
        for (final e
            in (json['traceEvents'] as List).cast<Map<String, dynamic>>())
          TimelineEvent.parse(e)!,
      ];
      final gaps = TimelineParser.parse(events).uiThreadGaps;
      final vsync = frame['vsyncStartUs'] as int;
      final build = frame['buildStartUs'] as int;
      final delay = build - vsync;
      // Only the vsync callback and the frame's setup are left.
      expect(_covered(gaps, vsync, build), greaterThan(delay - 600));
    });
  }

  group('synthetic', () {
    test('nested B/E work and X durations are busy; a PlatformVsync span '
        'is not', () {
      final gaps = TimelineParser.parse([
        _e('Animator::BeginFrame', 'B', 0),
        _e('Animator::BeginFrame', 'E', 1000),
        _e('DartIsolate::HandleMessage', 'B', 2000),
        _e('BUILD', 'B', 3000),
        _e('BUILD', 'E', 9000),
        _e('DartIsolate::HandleMessage', 'E', 10000),
        _e('PlatformVsync', 'B', 11000),
        _e('PlatformVsync', 'E', 30000),
        _e('VsyncFireCallback', 'X', 30010, dur: 20),
        _e('Animator::BeginFrame', 'B', 30100),
        _e('Animator::BeginFrame', 'E', 31000),
      ]).uiThreadGaps;
      // The gap from 1000 to 2000 is under the 2 ms minimum, HandleMessage
      // holds the thread to 10000, and the PlatformVsync span is idle.
      expect(gaps, [(10000, 30010)]);
    });

    test('only the thread that ran frames reports gaps', () {
      final gaps = TimelineParser.parse([
        _e('Animator::BeginFrame', 'B', 0, tid: 1),
        _e('Animator::BeginFrame', 'E', 1000, tid: 1),
        _e('GPURasterizer::Draw', 'B', 0, tid: 2),
        _e('GPURasterizer::Draw', 'E', 1000, tid: 2),
        _e('GPURasterizer::Draw', 'B', 9000, tid: 2),
        _e('GPURasterizer::Draw', 'E', 9500, tid: 2),
        _e('Animator::BeginFrame', 'B', 1500, tid: 1),
        _e('Animator::BeginFrame', 'E', 2000, tid: 1),
      ]).uiThreadGaps;
      expect(gaps, isEmpty);
    });

    test('an end whose begin came in an earlier batch leaves no gap '
        'before it', () {
      final gaps = TimelineParser.parse([
        _e('Animator::BeginFrame', 'B', 0),
        _e('Animator::BeginFrame', 'E', 1000),
        // Inside a HandleMessage that began in the previous batch.
        _e('BUILD', 'X', 5000, dur: 100),
        _e('DartIsolate::HandleMessage', 'E', 20000),
        _e('Animator::BeginFrame', 'B', 26000),
        _e('Animator::BeginFrame', 'E', 27000),
      ]).uiThreadGaps;
      expect(gaps, [(20000, 26000)]);
    });
  });
}
