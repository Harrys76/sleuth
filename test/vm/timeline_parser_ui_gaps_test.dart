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

  for (final file in const [
    'test/vm/_fixtures/vsync_gap_ios_profile.json',
    'test/vm/_fixtures/vsync_gap_android_profile.json',
  ]) {
    test('$file: split into two batches inside the gap, the carried idle '
        'stretch still covers the late frame\'s start delay', () {
      final json =
          jsonDecode(File(file).readAsStringSync()) as Map<String, dynamic>;
      final frame = json['frame'] as Map<String, dynamic>;
      final events = [
        for (final e
            in (json['traceEvents'] as List).cast<Map<String, dynamic>>())
          TimelineEvent.parse(e)!,
      ];
      final vsync = frame['vsyncStartUs'] as int;
      final build = frame['buildStartUs'] as int;
      final whole = _covered(
        TimelineParser.parse(events).uiThreadGaps,
        vsync,
        build,
      );
      // A poll that ends while the thread is held: the events before the
      // middle of the delay arrive in one batch, the rest in the next.
      final cut = vsync + (build - vsync) ~/ 2;
      final first = events.where((e) => (e.json!['ts'] as int? ?? 0) < cut);
      final second = events.where((e) => (e.json!['ts'] as int? ?? 0) >= cut);
      // In a session the frame thread is known from earlier batches.
      final frameTid =
          events
                  .firstWhere((e) => e.json!['name'] == 'Animator::BeginFrame')
                  .json!['tid']
              as int;
      final idle = <int, int?>{frameTid: null};
      final cursors = <int, TimelineCursor>{};
      final gaps = [
        ...TimelineParser.parse(
          first.toList(),
          cursorsByTid: cursors,
          frameThreadIdle: idle,
        ).uiThreadGaps,
        ...TimelineParser.parse(
          second.toList(),
          cursorsByTid: cursors,
          frameThreadIdle: idle,
        ).uiThreadGaps,
      ];
      expect(_covered(gaps, vsync, build), whole);
      // Without the carried stretch the second batch starts the thread
      // afresh and the part before its first event is lost.
      final fresh = [
        ...TimelineParser.parse(
          first.toList(),
          frameThreadIdle: {frameTid: null},
        ).uiThreadGaps,
        ...TimelineParser.parse(
          second.toList(),
          frameThreadIdle: {frameTid: null},
        ).uiThreadGaps,
      ];
      expect(_covered(fresh, vsync, build), lessThan(whole));
    });
  }

  group('carried across batches', () {
    test('a stretch idle at the end of one batch ends at the next batch\'s '
        'first event', () {
      final idle = <int, int?>{};
      final first = TimelineParser.parse([
        _e('Animator::BeginFrame', 'B', 0),
        _e('Animator::BeginFrame', 'E', 1000),
      ], frameThreadIdle: idle);
      expect(first.uiThreadGaps, isEmpty);
      expect(idle, {1: 1000});
      final second = TimelineParser.parse([
        _e('DartIsolate::HandleMessage', 'B', 31000),
        _e('DartIsolate::HandleMessage', 'E', 32000),
      ], frameThreadIdle: idle);
      // The second batch holds no BeginFrame; the thread is still known.
      expect(second.uiThreadGaps, [(1000, 31000)]);
      expect(second.frameTids, {1});
      expect(idle, {1: 32000});
    });

    test('a thread that ended inside a scope carries no stretch', () {
      final idle = <int, int?>{};
      TimelineParser.parse([
        _e('Animator::BeginFrame', 'B', 0),
        _e('Animator::BeginFrame', 'E', 1000),
        _e('DartIsolate::HandleMessage', 'B', 2000),
      ], frameThreadIdle: idle);
      expect(idle, {1: null});
      final second = TimelineParser.parse([
        _e('DartIsolate::HandleMessage', 'E', 40000),
        _e('BUILD', 'X', 50000, dur: 100),
      ], frameThreadIdle: idle);
      expect(second.uiThreadGaps, [(40000, 50000)]);
    });

    test('a gap inside an earlier batch is not reported again', () {
      final idle = <int, int?>{};
      final first = TimelineParser.parse([
        _e('Animator::BeginFrame', 'B', 0),
        _e('Animator::BeginFrame', 'E', 1000),
        _e('BUILD', 'X', 20000, dur: 500),
      ], frameThreadIdle: idle);
      expect(first.uiThreadGaps, [(1000, 20000)]);
      final second = TimelineParser.parse([
        _e('BUILD', 'X', 21000, dur: 500),
      ], frameThreadIdle: idle);
      expect(second.uiThreadGaps, isEmpty);
    });

    test('newest ts per thread leaves async events out; raster threads '
        'are named', () {
      final data = TimelineParser.parse([
        _e('Animator::BeginFrame', 'B', 100, tid: 1),
        _e('Animator::BeginFrame', 'E', 200, tid: 1),
        _e('GPURasterizer::Draw', 'B', 300, tid: 2),
        _e('GPURasterizer::Draw', 'E', 900, tid: 2),
        TimelineEvent.parse({
          'name': 'SceneDisplayLag',
          'cat': 'Embedder',
          'ph': 'e',
          'id': '1',
          'ts': 50000,
          'tid': 2,
          'pid': 1,
        })!,
      ]);
      expect(data.newestTsByTid, {1: 200, 2: 900});
      expect(data.frameTids, {1});
      expect(data.rasterTids, {2});
    });
  });

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
