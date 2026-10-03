import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/vm/poll_timings.dart';

PollTimings _t({int rpc = 0, int parse = 0, int dispatch = 0}) => PollTimings(
  rpcMicros: rpc,
  parseMicros: parse,
  dispatchMicros: dispatch,
  tailMicros: 0,
  eventCount: 0,
  responseChars: -1,
  duplicatesDropped: 0,
  completedAt: DateTime(2026),
);

void main() {
  group('PollTimingsWindow', () {
    test('empty window has no maxima', () {
      final w = PollTimingsWindow();
      expect(w.maxRpcMicros, isNull);
      expect(w.maxParseMicros, isNull);
      expect(w.maxDispatchMicros, isNull);
    });

    test('maxima are per segment', () {
      final w = PollTimingsWindow()
        ..add(_t(rpc: 5, parse: 50, dispatch: 1))
        ..add(_t(rpc: 9, parse: 10, dispatch: 7));
      expect(w.maxRpcMicros, 9);
      expect(w.maxParseMicros, 50);
      expect(w.maxDispatchMicros, 7);
    });

    test('holds the last 32 polls', () {
      final w = PollTimingsWindow()..add(_t(rpc: 1000));
      for (var i = 0; i < 31; i++) {
        w.add(_t(rpc: i));
      }
      expect(w.length, 32);
      expect(w.maxRpcMicros, 1000);

      w.add(_t(rpc: 3));
      expect(w.length, 32);
      expect(w.maxRpcMicros, 30);
    });

    test('clear empties the window', () {
      final w = PollTimingsWindow()..add(_t(rpc: 4));
      w.clear();
      expect(w.length, 0);
      expect(w.maxRpcMicros, isNull);
    });
  });

  test('totalMicros sums the four segments and toJson is complete', () {
    final t = PollTimings(
      rpcMicros: 1,
      parseMicros: 2,
      dispatchMicros: 3,
      tailMicros: 4,
      eventCount: 5,
      responseChars: 6,
      duplicatesDropped: 7,
      completedAt: DateTime.fromMicrosecondsSinceEpoch(8),
      dispatchDetectorsMicros: 9,
      dispatchCorrelateMicros: 10,
      dispatchAggregateMicros: 11,
      dispatchOtherMicros: 12,
      tailCpuSamplesMicros: 13,
      tailAllocationProfileMicros: 14,
      tailMemoryMicros: 15,
    );
    expect(t.totalMicros, 10);
    expect(t.toJson(), {
      'rpcMicros': 1,
      'parseMicros': 2,
      'dispatchMicros': 3,
      'tailMicros': 4,
      'eventCount': 5,
      'responseChars': 6,
      'duplicatesDropped': 7,
      'completedAtMicros': 8,
      'windowFallback': false,
      'dispatchDetectorsMicros': 9,
      'dispatchCorrelateMicros': 10,
      'dispatchAggregateMicros': 11,
      'dispatchOtherMicros': 12,
      'tailCpuSamplesMicros': 13,
      'tailAllocationProfileMicros': 14,
      'tailMemoryMicros': 15,
    });
  });

  group('RpcSpanTracker', () {
    test('overlap counts only time inside the windows, merging '
        'concurrent requests', () async {
      var now = 0;
      final tracker = RpcSpanTracker(() => now);
      final a = Completer<void>();
      final b = Completer<void>();
      now = 100;
      final fa = tracker.track(a.future);
      now = 150;
      final fb = tracker.track(b.future);
      now = 300;
      a.complete();
      await fa;
      now = 400;
      b.complete();
      await fb;
      expect(tracker.length, 2);
      // Union of [100, 300] and [150, 400] inside [0, 200] and [350, 500].
      expect(tracker.overlapWith(const [(0, 200), (350, 500)]), 100 + 50);
      expect(tracker.overlapWith(const [(500, 600)]), 0);
    });

    test('an open request counts up to now', () {
      var now = 10;
      final tracker = RpcSpanTracker(() => now);
      tracker.track(Completer<void>().future);
      now = 60;
      expect(tracker.overlapWith(const [(0, 40)]), 30);
    });

    test('pruneBefore drops closed spans that ended earlier', () async {
      var now = 0;
      final tracker = RpcSpanTracker(() => now);
      final done = Completer<void>();
      final f = tracker.track(done.future);
      now = 50;
      done.complete();
      await f;
      tracker.pruneBefore(51);
      expect(tracker.length, 0);
    });
  });
}
