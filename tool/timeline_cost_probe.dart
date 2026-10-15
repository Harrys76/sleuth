// Measures what reading the VM timeline costs a running app, and records
// the VM's Timeline stream for tests.
//
//   fvm dart run tool/timeline_cost_probe.dart <ws-uri> measure <demo>
//       [--fixed] [--period ms] [--modes none,full,window1000,clock,...]
//   fvm dart run tool/timeline_cost_probe.dart <ws-uri> stream-dump <demo>
//       [--fixed] [--seconds n] [--keep-ms n] --out <file.json>
//
// Start the example app from example/ with
// `fvm flutter run --profile -d <device>` (DDS on) to measure the VM alone:
// Sleuth then has no VM link and reads nothing itself. With `--no-dds`
// Sleuth reads the timeline too, which `measure none` shows.
//
// measure: opens the demo (and its Fixed pattern with --fixed), then for
// each mode issues one request per period for 7 s and reads the app's
// frames through ext.sleuth.snapshot. Modes:
//   none          no request
//   full          getVMTimeline over the whole buffer
//   window<ms>    getVMTimeline from the VM clock minus <ms>
//   clock         getVMTimelineMicros only
//   memory        getMemoryUsage only
//   stream        listen to the Timeline stream for 7 s instead
// Each line gives the frames' raster spikes (> 25 ms), late starts
// (> 16.7 ms), raster p50 and worst, and the requests' cost and size.
//
// stream-dump: opens the demo, listens to the Timeline stream for
// --seconds (default 6), and writes the blocks in arrival order, keeping
// the frame thread, the raster thread, platform channel and shader events
// within the last --keep-ms (default 2000) of the recording, plus the
// frames Sleuth holds for that span. Test fixtures under
// test/vm/_fixtures/stream/ come from this mode.
import 'dart:convert';
import 'dart:io';

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

Future<void> main(List<String> args) async {
  if (args.length < 3) {
    stderr.writeln(
      'usage: timeline_cost_probe.dart <ws-uri> (measure|stream-dump) <demo> '
      '[--fixed] [--period ms] [--modes a,b] [--seconds n] [--keep-ms n] '
      '[--out file]',
    );
    exitCode = 64;
    return;
  }
  String? option(String name) {
    final i = args.indexOf(name);
    return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
  }

  final service = await vmServiceConnectUri(args[0]);
  try {
    final vm = await service.getVM();
    String? isolateId;
    for (final ref in vm.isolates ?? const <IsolateRef>[]) {
      final isolate = await service.getIsolate(ref.id!);
      if ((isolate.extensionRPCs ?? const []).contains('ext.sleuthDemo.open')) {
        isolateId = ref.id;
      }
    }
    if (isolateId == null) {
      stderr.writeln('no isolate with ext.sleuthDemo.open');
      exitCode = 1;
      return;
    }
    Future<Map<String, dynamic>> call(
      String method, [
      Map<String, String>? params,
    ]) async {
      final response = await service.callServiceExtension(
        method,
        isolateId: isolateId,
        args: params,
      );
      return response.json ?? const {};
    }

    await call('ext.sleuthDemo.open', {'demo': args[2]});
    await Future<void>.delayed(const Duration(seconds: 3));
    if (args.contains('--fixed')) {
      await call('ext.sleuthDemo.tap', {'text': 'Fixed Pattern'});
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    if (args[1] == 'measure') {
      await _measure(
        service,
        isolateId,
        call,
        periodMs: int.parse(option('--period') ?? '500'),
        modes: (option('--modes') ?? 'none,full,window1000,window100,clock')
            .split(','),
      );
    } else if (args[1] == 'stream-dump') {
      final out = option('--out');
      if (out == null) {
        stderr.writeln('stream-dump needs --out');
        exitCode = 64;
        return;
      }
      await _streamDump(
        service,
        call,
        seconds: int.parse(option('--seconds') ?? '6'),
        keepUs: int.parse(option('--keep-ms') ?? '2000') * 1000,
        demo: args[2],
        fixed: args.contains('--fixed'),
        out: out,
      );
    }
    await call('ext.sleuthDemo.pop');
  } finally {
    await service.dispose();
  }
}

typedef _Call =
    Future<Map<String, dynamic>> Function(
      String method, [
      Map<String, String>? params,
    ]);

Future<List<Map<String, dynamic>>> _recentFrames(_Call call) async {
  final envelope = await call('ext.sleuth.snapshot', {
    'sections': 'recentFrames',
  });
  final data = envelope['data'];
  final snapshot = (data is String ? jsonDecode(data) : data) as Map;
  return (snapshot['recentFrames'] as List).cast<Map<String, dynamic>>();
}

Future<void> _measure(
  VmService service,
  String isolateId,
  _Call call, {
  required int periodMs,
  required List<String> modes,
}) async {
  for (final mode in modes) {
    var calls = 0, totalMs = 0, worstMs = 0, events = 0;
    if (mode == 'stream') {
      final sub = service.onTimelineEvent.listen((e) {
        events += e.timelineEvents?.length ?? 0;
        calls++;
      });
      await service.streamListen(EventStreams.kTimeline);
      await Future<void>.delayed(const Duration(seconds: 7));
      await service.streamCancel(EventStreams.kTimeline);
      await sub.cancel();
    } else {
      final run = Stopwatch()..start();
      while (run.elapsedMilliseconds < 7000) {
        final request = Stopwatch()..start();
        if (mode == 'full') {
          events += (await service.getVMTimeline()).traceEvents!.length;
        } else if (mode.startsWith('window')) {
          final windowUs = int.parse(mode.substring(6)) * 1000;
          final now = (await service.getVMTimelineMicros()).timestamp!;
          events += (await service.getVMTimeline(
            timeOriginMicros: now - windowUs,
            timeExtentMicros: windowUs + 1000000,
          )).traceEvents!.length;
        } else if (mode == 'clock') {
          await service.getVMTimelineMicros();
        } else if (mode == 'memory') {
          await service.getMemoryUsage(isolateId);
        }
        if (mode != 'none') {
          calls++;
          final ms = request.elapsedMilliseconds;
          totalMs += ms;
          if (ms > worstMs) worstMs = ms;
        }
        final wait = periodMs - request.elapsedMilliseconds;
        await Future<void>.delayed(Duration(milliseconds: wait > 0 ? wait : 0));
      }
    }
    final frames = await _recentFrames(call);
    final newest = frames
        .map((f) => f['vsyncStartUs'] as int)
        .reduce((a, b) => a > b ? a : b);
    final recent = frames
        .where((f) => newest - (f['vsyncStartUs'] as int) < 5000000)
        .toList();
    final rasters = recent.map((f) => f['rasterDurationUs'] as int).toList()
      ..sort();
    final spikes = rasters.where((r) => r > 25000).length;
    final late = recent
        .where((f) => (f['vsyncOverheadUs'] as int? ?? 0) > 16667)
        .length;
    final cost = mode == 'stream'
        ? 'blocks $calls, events $events'
        : 'requests $calls, mean ${calls > 0 ? totalMs ~/ calls : 0} ms, '
              'worst $worstMs ms, events per request '
              '${calls > 0 ? events ~/ calls : 0}';
    stdout.writeln(
      '$mode: ${recent.length} frames, raster > 25 ms $spikes, '
      'late start > 16.7 ms $late, raster p50 '
      '${rasters[rasters.length ~/ 2]} us, worst ${rasters.last} us; $cost',
    );
  }
}

const _rasterNames = {'GPURasterizer::Draw', 'Rasterizer::DoDraw'};

bool _keepAnyThread(Map<String, dynamic> event) {
  final name = '${event['name']}';
  return name.startsWith('Platform Channel') ||
      name.contains('PipelineVK::Create') ||
      name.contains('CreateComputePipeline') ||
      name == 'LinkProgram' ||
      name == 'SceneDisplayLag';
}

Future<void> _streamDump(
  VmService service,
  _Call call, {
  required int seconds,
  required int keepUs,
  required String demo,
  required bool fixed,
  required String out,
}) async {
  final arrival = Stopwatch()..start();
  final blocks = <({int arrivalMs, List<Map<String, dynamic>> events})>[];
  final sub = service.onTimelineEvent.listen((e) {
    blocks.add((
      arrivalMs: arrival.elapsedMilliseconds,
      events: [
        for (final t in e.timelineEvents ?? const <TimelineEvent>[])
          Map<String, dynamic>.from(t.json!),
      ],
    ));
  });
  await service.streamListen(EventStreams.kTimeline);
  await Future<void>.delayed(Duration(seconds: seconds));
  await service.streamCancel(EventStreams.kTimeline);
  await sub.cancel();
  final frames = await _recentFrames(call);

  final all = [for (final b in blocks) ...b.events];
  int? frameTid, rasterTid;
  var newest = 0;
  for (final e in all) {
    final ts = e['ts'];
    if (ts is int && ts > newest && e['ph'] != 'b' && e['ph'] != 'e') {
      newest = ts;
    }
    if (e['name'] == 'Animator::BeginFrame') frameTid ??= e['tid'] as int?;
    if (_rasterNames.contains(e['name'])) rasterTid ??= e['tid'] as int?;
  }
  final fromUs = newest - keepUs;
  bool keep(Map<String, dynamic> e) {
    final ts = e['ts'];
    if (ts is! int || ts < fromUs) return false;
    final tid = e['tid'];
    return tid == frameTid || tid == rasterTid || _keepAnyThread(e);
  }

  final kept = [
    for (final b in blocks)
      if (b.events.where(keep).isNotEmpty)
        {'arrivalMs': b.arrivalMs, 'events': b.events.where(keep).toList()},
  ];
  final keptFrames = frames
      .where((f) => (f['vsyncStartUs'] as int? ?? 0) >= fromUs)
      .toList();
  final provenance = {
    'screen': '$demo${fixed ? ', Fixed pattern' : ''}',
    'source':
        'tool/timeline_cost_probe.dart stream-dump: Timeline stream blocks '
        'in arrival order, frame and raster threads plus platform channel '
        'and shader events, last ${keepUs ~/ 1000} ms of a $seconds s '
        'recording; frames from ext.sleuth.snapshot recentFrames',
    'blocksRecorded': blocks.length,
    'frameTid': frameTid,
    'rasterTid': rasterTid,
  };
  File(out).writeAsStringSync(
    jsonEncode({
      'provenance': provenance,
      'blocks': kept,
      'frames': keptFrames,
    }),
  );
  stdout.writeln(
    'wrote $out: ${kept.length} blocks, '
    '${kept.fold<int>(0, (n, b) => n + (b['events'] as List).length)} '
    'events, ${keptFrames.length} frames',
  );
}
