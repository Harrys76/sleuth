// VmServiceClient reading the VM's Timeline stream: blocks drained once
// per tick, the session's first read, catch-up reads for threads whose
// last events wait in an unfinished block, the buffer cap, the fallback
// to polling and the reset on a new session.
import 'dart:developer' show Timeline;

import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/vm/timeline_parser.dart';
import 'package:sleuth/src/vm/vm_service_client.dart';
import 'package:vm_service/vm_service.dart' hide Timeline;

import '../helpers/fake_vm_service.dart';

const _ui = 1;
const _raster = 2;
const _other = 3;

void main() {
  // Timestamps sit just behind the in-app timeline clock, which the
  // catch-up read measures its window against.
  late int base;
  late List<ParsedTimelineData> batches;
  late FakeVmService service;
  int? newestFrame;

  Map<String, dynamic> event(
    String name,
    String ph,
    int ts, {
    int tid = _ui,
    int? dur,
  }) => {
    'name': name,
    'cat': 'Embedder',
    'ph': ph,
    'ts': ts,
    'tid': tid,
    'pid': 1,
    'dur': ?dur,
  };

  /// One frame: a BeginFrame and a BUILD of [buildUs] on the UI thread at
  /// [at], and a raster scope of [rasterUs] on the raster thread after it.
  List<Map<String, dynamic>> frame(
    int at, {
    int buildUs = 2000,
    int rasterUs = 4000,
  }) => [
    event('Animator::BeginFrame', 'B', at),
    event('Animator::BeginFrame', 'E', at + 100),
    event('BUILD', 'X', at + 200, dur: buildUs),
    event('GPURasterizer::Draw', 'B', at + 3000, tid: _raster),
    event('GPURasterizer::Draw', 'E', at + 3000 + rasterUs, tid: _raster),
  ];

  List<TimelineEvent> parsed(List<Map<String, dynamic>> events) => [
    for (final e in events) TimelineEvent.parse(e)!,
  ];

  Future<VmServiceClient> start({
    Duration silentFallback = const Duration(seconds: 10),
    Duration catchUpMinInterval = const Duration(seconds: 1),
  }) async {
    final client = VmServiceClient(
      onTimelineData: batches.add,
      ownIsolateIdResolver: () => 'isolates/1',
      newestFrameRasterFinishUs: () => newestFrame,
      streamSilentFallback: silentFallback,
      catchUpMinInterval: catchUpMinInterval,
    );
    addTearDown(client.dispose);
    expect(await client.startSessionForTest(service), isTrue);
    return client;
  }

  List<int> builds() => [for (final b in batches) ...b.buildScopeDurations];
  List<int> rasters() => [for (final b in batches) ...b.rasterDurations];

  setUp(() {
    base = Timeline.now - 800000;
    batches = [];
    service = FakeVmService();
    newestFrame = null;
  });

  test('the first tick reads the buffer; later ticks parse only the '
      'blocks that arrived', () async {
    service.timelineEvents = parsed(frame(base, buildUs: 1000));
    final client = await start();
    expect(client.timelineSource, TimelineSource.stream);

    await client.tickForTest();
    expect(service.timelineWindows, hasLength(1));
    expect(builds(), [1000]);

    service.timelineController.add(
      timelineBlock(frame(base + 16667, buildUs: 1100)),
    );
    await client.tickForTest();
    expect(service.timelineWindows, hasLength(1));
    expect(builds(), [1000, 1100]);
    expect(rasters(), [4000, 4000]);
    expect(client.streamBlocks, 1);
    expect(client.streamEvents, 5);
    expect(client.catchUpReads, 0);
  });

  test('a block holding events the first read already returned adds '
      'nothing twice', () async {
    final first = frame(base, buildUs: 1000);
    service.timelineEvents = parsed(first);
    final client = await start();
    await client.tickForTest();

    // The thread's block fills after the read: it repeats the read's
    // events and adds one more frame.
    service.timelineController.add(
      timelineBlock([...first, ...frame(base + 16667, buildUs: 1200)]),
    );
    await client.tickForTest();
    expect(builds(), [1000, 1200]);
  });

  test('blocks that arrive before the first read are covered by it, '
      'not parsed again', () async {
    service.timelineEvents = parsed(frame(base, buildUs: 1000));
    final client = await start();
    service.timelineController.add(timelineBlock(frame(base, buildUs: 1000)));
    await client.tickForTest();
    await client.tickForTest();
    expect(builds(), [1000]);
  });

  group('catch-up read', () {
    test('runs when a frame finished well after the newest event seen on '
        'the frame or raster thread, and keeps only those threads', () async {
      service.timelineEvents = parsed(frame(base));
      final client = await start();
      await client.tickForTest();

      // A frame finished 600 ms later, but its events wait in unfinished
      // blocks. The VM holds them, and an event on another thread.
      final late = base + 600000;
      newestFrame = late + 9000;
      service.timelineEvents = parsed([
        ...frame(base),
        ...frame(late, buildUs: 1500),
        event(
          'Platform Channel send foo',
          'X',
          late + 50,
          tid: _other,
          dur: 300,
        ),
      ]);
      await client.tickForTest();

      expect(client.catchUpReads, 1);
      final (origin, _) = service.timelineWindows.last;
      // From 5 ms before the older of the two threads' newest events.
      // The UI thread's newest event is the BUILD at base + 200.
      expect(origin, base + 200 - 5000);
      expect(builds(), [2000, 1500]);
      expect(rasters(), [4000, 4000]);
      expect([for (final b in batches) ...b.platformChannelEvents], isEmpty);

      // That thread's events still arrive when its block fills.
      service.timelineController.add(
        timelineBlock([
          event(
            'Platform Channel send foo',
            'X',
            late + 50,
            tid: _other,
            dur: 300,
          ),
        ]),
      );
      await client.tickForTest();
      expect([
        for (final b in batches) ...b.platformChannelEvents,
      ], hasLength(1));
    });

    test('does not run while the stream keeps up', () async {
      service.timelineEvents = parsed(frame(base));
      final client = await start();
      await client.tickForTest();
      service.timelineController.add(timelineBlock(frame(base + 16667)));
      newestFrame = base + 16667 + 7000;
      await client.tickForTest();
      expect(client.catchUpReads, 0);
    });

    test('does not repeat once a read has seen the frame', () async {
      service.timelineEvents = parsed(frame(base));
      final client = await start(catchUpMinInterval: Duration.zero);
      await client.tickForTest();

      final late = base + 300000;
      newestFrame = late + 9000;
      service.timelineEvents = parsed([...frame(base), ...frame(late)]);
      await client.tickForTest();
      expect(client.catchUpReads, 1);

      // Nothing new: the read moved the newest events seen.
      await client.tickForTest();
      expect(client.catchUpReads, 1);

      // A newer frame that has not arrived does.
      final later = late + 300000;
      newestFrame = later + 9000;
      service.timelineEvents = parsed([
        ...frame(base),
        ...frame(late),
        ...frame(later),
      ]);
      await client.tickForTest();
      expect(client.catchUpReads, 2);
    });

    test('runs at most once per catchUpMinInterval', () async {
      service.timelineEvents = parsed(frame(base));
      final client = await start();
      await client.tickForTest();

      final late = base + 300000;
      newestFrame = late + 9000;
      service.timelineEvents = parsed([...frame(base), ...frame(late)]);
      await client.tickForTest();
      expect(client.catchUpReads, 1);

      final later = late + 300000;
      newestFrame = later + 9000;
      service.timelineEvents = parsed([
        ...frame(base),
        ...frame(late),
        ...frame(later),
      ]);
      await client.tickForTest();
      expect(client.catchUpReads, 1);
    });

    test('spans at most one second', () async {
      service.timelineEvents = parsed(frame(base - 5000000));
      final client = await start();
      await client.tickForTest();
      newestFrame = Timeline.now;
      await client.tickForTest();
      final (origin, extent) = service.timelineWindows.last;
      expect(origin, greaterThanOrEqualTo(Timeline.now - 1100000));
      expect(origin! + extent!, greaterThan(Timeline.now));
    });

    test('a flush runs one whether or not a frame is waiting', () async {
      service.timelineEvents = parsed(frame(base));
      final client = await start();
      await client.tickForTest();
      await client.tickForTest();
      expect(client.catchUpReads, 0);
      await client.pollTimelineSync();
      expect(client.catchUpReads, 1);
    });
  });

  test('the buffer keeps at most streamBufferCap events, dropping the '
      'oldest whole blocks', () async {
    final client = await start();
    await client.tickForTest();
    final block = [
      for (var i = 0; i < 4096; i++) event('Other', 'i', base + i, tid: _other),
    ];
    for (var i = 0; i < 5; i++) {
      service.timelineController.add(timelineBlock(block));
    }
    expect(client.streamEventsDropped, 4096);
    expect(client.streamEvents, 5 * 4096);
  });

  test(
    'the lag of each block is the age of its newest ordered event',
    () async {
      final client = await start();
      service.timelineController.add(
        timelineBlock([
          event('BUILD', 'X', Timeline.now - 40000, dur: 100),
          // An async end stamped ahead does not count.
          {...event('SceneDisplayLag', 'e', Timeline.now + 30000), 'id': '1'},
        ]),
      );
      expect(client.lastStreamLagMs, inInclusiveRange(40, 200));
    },
  );

  group('fallback to polling', () {
    test('no block at all while frames are drawn', () async {
      final client = await start(silentFallback: Duration.zero);
      newestFrame = Timeline.now + 1;
      await client.tickForTest();
      expect(client.timelineSource, TimelineSource.poll);
    });

    test('a quiet stream that delivered blocks stays', () async {
      final client = await start(silentFallback: Duration.zero);
      service.timelineController.add(timelineBlock(frame(base)));
      newestFrame = Timeline.now + 1;
      await client.tickForTest();
      expect(client.timelineSource, TimelineSource.stream);
    });

    test('no frames, no fallback', () async {
      final client = await start(silentFallback: Duration.zero);
      await client.tickForTest();
      expect(client.timelineSource, TimelineSource.stream);
    });
  });

  test('a new session clears the stream state and subscribes again', () async {
    final client = await start();
    service.timelineController.add(timelineBlock(frame(base)));
    await client.tickForTest();
    expect(client.streamBlocks, 1);

    client.endSessionForTest();
    expect(client.timelineSource, isNull);
    expect(client.streamBlocks, 0);
    expect(client.catchUpReads, 0);
    expect(client.lastStreamLagMs, isNull);

    final next = FakeVmService();
    expect(await client.startSessionForTest(next), isTrue);
    expect(next.streamListenCalls, contains('Timeline'));
    expect(client.timelineSource, TimelineSource.stream);
    // A block posted to the old session's service is ignored.
    service.timelineController.add(timelineBlock(frame(base)));
    expect(client.streamBlocks, 0);
  });
}
