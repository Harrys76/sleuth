import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/utils/own_work_log.dart';

void main() {
  group('overlapUs', () {
    test('an empty log covers nothing', () {
      expect(OwnWorkLog().overlapUs(0, 1000), 0);
    });

    test('one interval, fully inside, partly inside, outside', () {
      final log = OwnWorkLog()..record(100, 200);
      expect(log.overlapUs(0, 1000), 100);
      expect(log.overlapUs(150, 1000), 50);
      expect(log.overlapUs(0, 150), 50);
      expect(log.overlapUs(300, 400), 0);
    });

    test('overlapping intervals count once', () {
      final log = OwnWorkLog()
        ..record(100, 300)
        ..record(200, 400)
        ..record(500, 600);
      expect(log.overlapUs(0, 1000), 400);
      expect(log.overlapUs(250, 550), 200);
    });

    test('empty, inverted and reversed windows are ignored', () {
      final log = OwnWorkLog()
        ..record(100, 100)
        ..record(300, 200)
        ..record(100, 200);
      expect(log.overlapUs(0, 1000), 100);
      expect(log.overlapUs(500, 400), 0);
    });

    test('spans that ended more than retainUs before the newest are '
        'dropped', () {
      final log = OwnWorkLog(retainUs: 1000)
        ..record(0, 10)
        ..record(5000, 5010);
      expect(log.overlapUs(0, 100), 0);
      expect(log.overlapUs(0, 10000), 10);
      log.clear();
      expect(log.overlapUs(0, 10000), 0);
    });

    test('a burst of short spans keeps the long span that came before '
        'it', () {
      // A 400 ms own-work stall, then the decode spans of 200 timer events
      // that it delayed: the stall's span must survive the burst.
      final log = OwnWorkLog()..record(0, 400000);
      for (var i = 0; i < 200; i++) {
        log.record(400000 + i * 100, 400000 + i * 100 + 50);
      }
      expect(log.overlapUs(0, 400000), 400000);
    });

    test('at most maxSpans spans are kept, oldest first out', () {
      final log = OwnWorkLog(maxSpans: 2)
        ..record(0, 10)
        ..record(100, 110)
        ..record(200, 210);
      expect(log.overlapUs(0, 50), 0);
      expect(log.overlapUs(0, 1000), 20);
    });
  });

  group('open and close', () {
    test('an open span covers its cap until closed, then ends at the '
        'close', () {
      final log = OwnWorkLog();
      final handle = log.open(1000, 500)!;
      expect(log.overlapUs(0, 10000), 500);
      log.close(handle, 1200);
      expect(log.overlapUs(0, 10000), 200);
    });

    test('a close past the cap or before the start never lengthens the '
        'span', () {
      final log = OwnWorkLog();
      final late = log.open(1000, 500)!;
      log.close(late, 5000);
      expect(log.overlapUs(0, 10000), 500);
      final early = log.open(20000, 500)!;
      log.close(early, 10000);
      expect(log.overlapUs(19000, 30000), 0);
    });

    test('a close after the span was pruned changes nothing', () {
      final log = OwnWorkLog(retainUs: 100);
      final handle = log.open(0, 100)!;
      log.record(1000, 1100);
      log.close(handle, 50);
      expect(log.overlapUs(0, 10000), 100);
    });

    test('a non-positive cap opens nothing', () {
      final log = OwnWorkLog();
      expect(log.open(0, 0), isNull);
      expect(log.overlapUs(-10, 10), 0);
    });
  });

  test('measure records the synchronous body and returns its value', () {
    final log = OwnWorkLog();
    final start = OwnWorkLog.now();
    final value = log.measure(() {
      final sw = Stopwatch()..start();
      while (sw.elapsedMicroseconds < 2000) {}
      return 7;
    });
    final end = OwnWorkLog.now();
    expect(value, 7);
    expect(log.overlapUs(start, end), greaterThanOrEqualTo(2000));
  });

  test('a span started in a synchronous listener ends before an awaited '
      'continuation runs', () async {
    // Mirrors package:vm_service: a synchronous `onReceive` broadcast fires
    // first, then the message is decoded, then the request completes.
    final log = OwnWorkLog();
    final onReceive = StreamController<String>.broadcast(sync: true);
    onReceive.stream.listen((_) => log.recordUntilMicrotask());
    final completer = Completer<void>();
    int? continuationAt;

    Future<void> caller() async {
      await completer.future;
      continuationAt = OwnWorkLog.now();
      // App work after the await: it must not fall inside the span.
      final sw = Stopwatch()..start();
      while (sw.elapsedMicroseconds < 3000) {}
    }

    final pending = caller();
    final before = OwnWorkLog.now();
    onReceive.add('message');
    final sw = Stopwatch()..start();
    while (sw.elapsedMicroseconds < 2000) {} // the decode
    completer.complete();
    await pending;
    final after = OwnWorkLog.now();

    expect(log.overlapUs(before, after), greaterThanOrEqualTo(2000));
    expect(log.overlapUs(continuationAt!, after), 0);
    await onReceive.close();
  });
}
