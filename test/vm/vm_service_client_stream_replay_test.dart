// VmServiceClient's stream mode against recorded Timeline streams. Each
// fixture holds the blocks a Galaxy A07 or an iPhone 12 posted, in arrival
// order, with the frames Sleuth held for the same span
// (`tool/timeline_cost_probe.dart stream-dump`; the provenance names the
// screen). The replay runs the client's 500 ms ticks on the recording's
// clock and delivers each block at its arrival. On both phones a read
// makes the VM post every thread's unfinished block before it answers, so
// the replay posts each thread's events written by then that no delivered
// block held. The recorded block still arrives later, as a repeat.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/models/phase_event.dart';
import 'package:sleuth/src/vm/timeline_parser.dart';
import 'package:sleuth/src/vm/vm_service_client.dart';
import 'package:vm_service/vm_service.dart';

import '../helpers/fake_vm_service.dart';

const _dir = 'test/vm/_fixtures/stream';
const _tickUs = 500000;

class _Recording {
  _Recording(String file) {
    final json =
        jsonDecode(File('$_dir/$file').readAsStringSync())
            as Map<String, dynamic>;
    final rawBlocks = (json['blocks'] as List).cast<Map<String, dynamic>>();
    blocks = [
      for (final b in rawBlocks)
        (
          arrivalMs: b['arrivalMs'] as int,
          events: (b['events'] as List).cast<Map<String, dynamic>>(),
        ),
    ];
    _allFrames = (json['frames'] as List).cast<Map<String, dynamic>>();
    // A block's arrival on the device clock is the host arrival plus the
    // smallest offset that puts no event after its block's arrival.
    var offset = -1 << 62;
    for (final b in blocks) {
      for (final e in b.events) {
        final ts = e['ts'];
        if (ts is int && !_async(e['ph'])) {
          final o = ts - b.arrivalMs * 1000;
          if (o > offset) offset = o;
        }
      }
    }
    _offsetUs = offset;
    // The tool read the frames list after the stream stopped. Frames that
    // finished after the last block posted have their events in blocks
    // that never filled, which the recording does not hold.
    frames = [
      for (final f in _allFrames)
        if ((f['rasterFinishUs'] as int? ?? 0) <= lastUs) f,
    ];
  }

  late final List<Map<String, dynamic>> _allFrames;

  late final List<({int arrivalMs, List<Map<String, dynamic>> events})> blocks;
  late final List<Map<String, dynamic>> frames;
  late final int _offsetUs;

  int arrivalUs(int arrivalMs) => arrivalMs * 1000 + _offsetUs;

  List<Map<String, dynamic>> get allEvents => [
    for (final b in blocks) ...b.events,
  ];

  int get firstUs => arrivalUs(blocks.first.arrivalMs);
  int get lastUs => arrivalUs(blocks.last.arrivalMs);

  static bool _async(Object? ph) =>
      ph == 'b' ||
      ph == 'e' ||
      ph == 'n' ||
      ph == 's' ||
      ph == 't' ||
      ph == 'f';
}

/// What the replay produced, and what parsing every event at once gives.
class _Result {
  _Result(this.batches, this.client);
  final List<(int tickUs, ParsedTimelineData data)> batches;
  final VmServiceClient client;

  List<int> get rasters => [for (final (_, b) in batches) ...b.rasterDurations];
  List<int> get builds => [
    for (final (_, b) in batches) ...b.buildScopeDurations,
  ];
}

Future<_Result> _replay(_Recording rec) async {
  final service = FakeVmService();
  var nowUs = rec.firstUs - 1;
  int? newestFrame() {
    int? newest;
    for (final f in rec.frames) {
      final finish = f['rasterFinishUs'] as int?;
      if (finish != null && finish <= nowUs) {
        if (newest == null || finish > newest) newest = finish;
      }
    }
    return newest;
  }

  final batches = <(int, ParsedTimelineData)>[];
  final client = VmServiceClient(
    onTimelineData: (data) => batches.add((nowUs, data)),
    ownIsolateIdResolver: () => 'isolates/1',
    newestFrameRasterFinishUs: newestFrame,
    streamClockForTest: () => nowUs,
  );
  addTearDown(client.dispose);
  final all = rec.allEvents;
  void writtenBy(int us) => service.timelineEvents = [
    for (final e in all)
      if ((e['ts'] as int? ?? 0) <= us) TimelineEvent.parse(e)!,
  ];

  var next = 0;
  service.flushOnRead = () {
    final byTid = <int, List<Map<String, dynamic>>>{};
    for (final b in rec.blocks.skip(next)) {
      for (final e in b.events) {
        if ((e['ts'] as int? ?? 0) <= nowUs) {
          (byTid[e['tid'] as int] ??= []).add(e);
        }
      }
    }
    return byTid.values.toList();
  };
  expect(await client.startSessionForTest(service), isTrue);
  // The session's first read happens before the recording starts.
  writtenBy(nowUs);
  await client.tickForTest();
  for (var tick = rec.firstUs; tick <= rec.lastUs + _tickUs; tick += _tickUs) {
    nowUs = tick;
    while (next < rec.blocks.length &&
        rec.arrivalUs(rec.blocks[next].arrivalMs) <= tick) {
      service.timelineController.add(timelineBlock(rec.blocks[next].events));
      next++;
    }
    writtenBy(tick);
    await client.tickForTest();
  }
  return _Result(batches, client);
}

ParsedTimelineData _atOnce(_Recording rec) => TimelineParser.parse([
  for (final e in rec.allEvents) TimelineEvent.parse(e)!,
], cursorsByTid: <int, TimelineCursor>{});

/// Build, layout and paint time per 1 s of tick time.
List<int> _uiPerSecond(List<(int, ParsedTimelineData)> batches, int fromUs) {
  final out = <int>[];
  for (final (tick, b) in batches) {
    final i = (tick - fromUs) ~/ 1000000;
    if (i < 0) continue;
    while (out.length <= i) {
      out.add(0);
    }
    out[i] += b.totalBuildScopeUs + b.totalFlushLayoutUs + b.totalFlushPaintUs;
  }
  return out;
}

void main() {
  for (final device in ['galaxy', 'iphone']) {
    for (final screen in ['live_waveform_fixed', 'gpu_pressure', 'static']) {
      final file = '${device}_$screen.json';

      test('$file: every raster frame and BUILD arrives once', () async {
        final rec = _Recording(file);
        final result = await _replay(rec);
        final once = _atOnce(rec);
        expect(result.rasters.length, once.rasterDurations.length);
        expect(result.rasters..sort(), once.rasterDurations.toList()..sort());
        expect(
          result.builds..sort(),
          once.buildScopeDurations.toList()..sort(),
        );
        expect(result.client.timelineSource, TimelineSource.stream);
        expect(result.client.streamEventsDropped, 0);
      });
    }

    for (final screen in ['live_waveform_fixed', 'gpu_pressure']) {
      final file = '${device}_$screen.json';

      test('$file: a busy screen needs no catch-up read, and UI time per '
          'second matches events counted by their own time', () async {
        final rec = _Recording(file);
        final result = await _replay(rec);
        expect(result.client.catchUpReads, 0);

        // Each tick gets the events stamped since the previous tick, as an
        // immediate read would hand them.
        final byTs = <(int, ParsedTimelineData)>[];
        final cursors = <int, TimelineCursor>{};
        final all = [for (final e in rec.allEvents) TimelineEvent.parse(e)!];
        for (var t = rec.firstUs; t <= rec.lastUs + _tickUs; t += _tickUs) {
          byTs.add((
            t,
            TimelineParser.parse([
              for (final e in all)
                if ((e.json!['ts'] as int? ?? 0) <= t) e,
            ], cursorsByTid: cursors),
          ));
        }
        final streamed = _uiPerSecond(result.batches, rec.firstUs);
        final stamped = _uiPerSecond(byTs, rec.firstUs);
        // The last second is cut off by the recording's end.
        for (var i = 0; i < stamped.length - 1 && i < streamed.length; i++) {
          expect(
            (streamed[i] - stamped[i]).abs(),
            lessThanOrEqualTo(stamped[i] * 0.1 + 1000),
            reason:
                'second $i: streamed ${streamed[i]} us, '
                'stamped ${stamped[i]} us',
          );
        }
      });
    }

    for (final screen in ['live_waveform_fixed', 'gpu_pressure', 'static']) {
      final file = '${device}_$screen.json';

      test('$file: each raster frame arrives within 1.75 s of its start, '
          'with at most one catch-up read a second', () async {
        final rec = _Recording(file);
        final result = await _replay(rec);
        final arrived = <int, int>{};
        for (final (tick, b) in result.batches) {
          for (final p in b.phaseEvents) {
            if (p.phase == TimelinePhase.raster) {
              arrived[p.timestampUs] ??= tick;
            }
          }
        }
        // A 500 ms tick, a 250 ms staleness check and a catch-up read at
        // most once a second bound the wait.
        const boundUs = 1750000;
        for (final p in _atOnce(rec).phaseEvents) {
          if (p.phase != TimelinePhase.raster) continue;
          if (p.timestampUs > rec.lastUs - boundUs) continue;
          final tick = arrived[p.timestampUs];
          expect(tick, isNotNull, reason: 'raster at ${p.timestampUs}');
          expect(tick! - p.timestampUs, lessThanOrEqualTo(boundUs));
        }
        final seconds = (rec.lastUs - rec.firstUs) ~/ 1000000 + 1;
        expect(result.client.catchUpReads, lessThanOrEqualTo(seconds + 1));
      });
    }
  }
}
