// Walks the example app's demos on a device and records what Sleuth reports
// for each one. The steps live in tool/demo_walk_plan.json, so the walk can
// be updated without code changes and runs the same on iOS and Android.
//
//   fvm dart run tool/demo_walk.dart <ws-uri> [options]
//
// Options:
//   --plan <file>      steps per demo (default tool/demo_walk_plan.json)
//   --out <file>       results JSON (default build/demo_walk/<time>.json)
//   --only "A|B"       walk only the demos with these titles
//   --from "Title"     start at this demo, for resuming a walk
//   --raw              also save raw data for calibration: every frame
//                      Sleuth holds at each frames step, and the GC
//                      window (ext.sleuthDemo.vmAxes) and heap samples at
//                      each read
//   --android <serial> run the Android-only steps too (real-touch swipes
//                      through adb, which raise a variable-rate panel to its
//                      top rate; synthetic drags do not)
//
// Start the app from example/ with
// `fvm flutter run --profile --no-dds -d <device>`. Without --no-dds the
// tool's DDS takes the VM service and Sleuth loses its VM link. Pass the
// printed service URI as ws://host:port/<auth>/ws.
//
// Plan steps are JSON arrays:
//   ["tap", "Label"]          tap the control showing this text
//   ["tapLabel", "Label"]     tap the control with this semantics label
//   ["tapAt", x, y]           tap a point in logical pixels
//   ["wait", seconds]
//   ["scroll", pixels, ms]    scroll the main scrollable; add "horizontal"
//   ["fling", dx, dy]         drag through the gesture arena
//   ["swipe", x1, y1, x2, y2, ms]  Android only, physical pixels
//   ["call", "ext.method", {"key": "value"}]
//   ["pop"]                   go back one route
//   ["read", "phase"]         merge the current issues into that phase
//   ["frames", "phase"]       record that phase's frame stats from the last
//                             90 frames
// The phase name is optional ("main" when left out), so a demo can record
// its bad and fixed patterns apart. A demo without a read step gets one at
// the end, and every demo ends with a pop. Runtime issues stay listed for
// up to 10 s after their cause stops, so wait at least that long after a
// switch before reading the new phase.
import 'dart:convert';
import 'dart:io';

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.first.startsWith('--')) {
    stderr.writeln(
      'usage: demo_walk.dart <ws-uri> [--plan f] [--out f] '
      '[--only "A|B"] [--from Title] [--raw] [--android serial]',
    );
    exitCode = 64;
    return;
  }
  final uri = args.first;
  String option(String name, String fallback) {
    final i = args.indexOf(name);
    return i > 0 && i + 1 < args.length ? args[i + 1] : fallback;
  }

  final planPath = option('--plan', 'tool/demo_walk_plan.json');
  final only = option('--only', '');
  final from = option('--from', '');
  final androidSerial = option('--android', '');
  final raw = args.contains('--raw');
  final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
  final outPath = option('--out', 'build/demo_walk/$stamp.json');

  final plan =
      jsonDecode(File(planPath).readAsStringSync()) as Map<String, dynamic>;
  final demos = (plan['demos'] as List).cast<Map<String, dynamic>>();
  final selected = only.isEmpty ? null : only.split('|').toSet();
  for (final demo in demos) {
    for (final step in (demo['steps'] as List).cast<List<dynamic>>()) {
      if (!_stepKinds.contains(step.first)) {
        stderr.writeln('${demo['title']}: unknown step ${jsonEncode(step)}');
        exitCode = 65;
        return;
      }
    }
  }

  final service = await vmServiceConnectUri(uri);
  try {
    final isolateId = await _sleuthIsolate(service);
    if (isolateId == null) {
      stderr.writeln('no isolate exposes ext.sleuth.issues');
      exitCode = 2;
      return;
    }
    Future<Map<String, dynamic>> call(
      String method, [
      Map<String, String>? params,
    ]) async {
      try {
        final r = await service.callServiceExtension(
          method,
          isolateId: isolateId,
          args: params,
        );
        final json = r.json ?? <String, dynamic>{};
        final data = json['data'];
        return data is Map<String, dynamic> ? data : json;
      } catch (e) {
        return <String, dynamic>{'error': '$e'};
      }
    }

    final results = <Map<String, dynamic>>[];
    String? stoppedAt;
    var started = from.isEmpty;
    for (final demo in demos) {
      final title = demo['title'] as String;
      started = started || title == from;
      if (!started) continue;
      if (selected != null && !selected.contains(title)) continue;
      // A lost device or app ends the walk; the rest would only log
      // failures.
      if (!await _alive(service)) {
        stoppedAt = title;
        stderr.writeln('lost the app before $title; resume with --from');
        break;
      }
      stdout.writeln('== $title');
      final result = await _walk(
        demo,
        call,
        androidSerial: androidSerial.isEmpty ? null : androidSerial,
        raw: raw,
      );
      results.add(result);
      stdout.writeln(_summary(result));
    }
    final out = File(outPath)..parent.createSync(recursive: true);
    out.writeAsStringSync(
      const JsonEncoder.withIndent(' ').convert({
        'walkedAt': DateTime.now().toIso8601String(),
        'plan': planPath,
        'androidSerial': androidSerial.isEmpty ? null : androidSerial,
        'stoppedAt': stoppedAt,
        'demos': results,
      }),
    );
    stdout.writeln('wrote $outPath');
  } finally {
    await service.dispose();
  }
}

const _stepKinds = {
  'tap',
  'tapLabel',
  'tapAt',
  'wait',
  'scroll',
  'fling',
  'swipe',
  'call',
  'pop',
  'read',
  'frames',
};

const _severityRank = {'critical': 3, 'warning': 2, 'info': 1, 'ok': 0};

typedef _Call =
    Future<Map<String, dynamic>> Function(
      String method, [
      Map<String, String>? params,
    ]);

Future<bool> _alive(VmService service) async {
  try {
    await service.getVersion().timeout(const Duration(seconds: 5));
    return true;
  } catch (_) {
    return false;
  }
}

Future<String?> _sleuthIsolate(VmService service) async {
  final vm = await service.getVM();
  for (final ref in vm.isolates ?? const <IsolateRef>[]) {
    final isolate = await service.getIsolate(ref.id!);
    if ((isolate.extensionRPCs ?? const <String>[]).contains(
      'ext.sleuth.issues',
    )) {
      return ref.id;
    }
  }
  return null;
}

Future<Map<String, dynamic>> _walk(
  Map<String, dynamic> demo,
  _Call call, {
  required String? androidSerial,
  required bool raw,
}) async {
  final title = demo['title'] as String;
  final actions = <Map<String, dynamic>>[];
  final issuesByPhase = <String, Map<String, Map<String, dynamic>>>{};
  final framesByPhase = <String, Map<String, dynamic>>{};
  final rawByPhase = <String, Map<String, dynamic>>{};

  Future<void> read(String phase) async {
    final issues = issuesByPhase.putIfAbsent(phase, () => {});
    final data = await call('ext.sleuth.issues');
    for (final issue in (data['issues'] as List? ?? const []).cast<Map>()) {
      final id = issue['stableId'] as String? ?? issue['title'] as String;
      final severity = issue['severity'] as String? ?? 'ok';
      final held = issues[id];
      if (held == null ||
          (_severityRank[severity] ?? 0) >
              (_severityRank[held['severity']] ?? 0)) {
        issues[id] = {
          'severity': severity,
          'confidence': issue['confidence'],
          'title': issue['title'],
        };
      }
    }
  }

  void record(List<dynamic> step, Map<String, dynamic> response) {
    final error = response['error'];
    actions.add({
      'step': step,
      'ok': error == null,
      if (error != null) 'error': '$error',
    });
  }

  final opened = await call('ext.sleuthDemo.open', {'demo': title});
  record(['open', title], opened);
  await Future<void>.delayed(const Duration(seconds: 2));

  for (final step in (demo['steps'] as List).cast<List<dynamic>>()) {
    final kind = step.first as String;
    switch (kind) {
      case 'tap':
        record(step, await call('ext.sleuthDemo.tap', {'text': '${step[1]}'}));
      case 'tapLabel':
        record(step, await call('ext.sleuthDemo.tap', {'label': '${step[1]}'}));
      case 'tapAt':
        record(
          step,
          await call('ext.sleuthDemo.tap', {
            'x': '${step[1]}',
            'y': '${step[2]}',
          }),
        );
      case 'wait':
        await Future<void>.delayed(
          Duration(milliseconds: ((step[1] as num) * 1000).round()),
        );
      case 'scroll':
        record(
          step,
          await call('ext.sleuthDemo.scroll', {
            'pixels': '${step[1]}',
            'ms': '${step[2]}',
            if (step.length > 3) 'axis': '${step[3]}',
          }),
        );
      case 'fling':
        record(
          step,
          await call('ext.sleuthDemo.fling', {
            'dx': '${step[1]}',
            'dy': '${step[2]}',
          }),
        );
      case 'swipe':
        if (androidSerial == null) {
          actions.add({'step': step, 'ok': true, 'skipped': 'not android'});
          break;
        }
        final r = await Process.run('adb', [
          '-s',
          androidSerial,
          'shell',
          'input',
          'swipe',
          for (final v in step.skip(1)) '$v',
        ]);
        record(step, r.exitCode == 0 ? {} : {'error': '${r.stderr}'.trim()});
      case 'call':
        final params = step.length > 2
            ? (step[2] as Map).map((k, v) => MapEntry('$k', '$v'))
            : null;
        record(step, await call('${step[1]}', params));
      case 'pop':
        record(step, await call('ext.sleuthDemo.pop'));
      case 'read':
        final phase = step.length > 1 ? '${step[1]}' : 'main';
        await read(phase);
        if (raw) {
          final slot = rawByPhase.putIfAbsent(phase, () => {});
          slot['gc'] = await call('ext.sleuthDemo.vmAxes');
          slot['heapSamples'] = (await call('ext.sleuth.snapshot', {
            'sections': 'heapSamples',
          }))['heapSamples'];
        }
      case 'frames':
        final phase = step.length > 1 ? '${step[1]}' : 'main';
        framesByPhase[phase] = await _frameStats(call);
        if (raw) {
          rawByPhase.putIfAbsent(phase, () => {})['frames'] = (await call(
            'ext.sleuth.snapshot',
            {'sections': 'recentFrames'},
          ))['recentFrames'];
        }
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  if (issuesByPhase.isEmpty) await read('main');
  final diagnose = await call('ext.sleuth.diagnose');
  await call('ext.sleuthDemo.pop');
  await Future<void>.delayed(const Duration(seconds: 2));
  return {
    'title': title,
    'actions': actions,
    'issues': issuesByPhase,
    'frames': framesByPhase,
    if (raw) 'raw': rawByPhase,
    'frameBudgetUs': diagnose['frameBudgetUs'],
    'effectiveFrameRateHz': diagnose['effectiveFrameRateHz'],
  };
}

Future<Map<String, dynamic>> _frameStats(_Call call) async {
  final snapshot = await call('ext.sleuth.snapshot', {
    'sections': 'recentFrames',
  });
  final frames = (snapshot['recentFrames'] as List? ?? const [])
      .cast<Map>()
      .toList();
  final recent = frames.length > 90
      ? frames.sublist(frames.length - 90)
      : frames;
  List<int> sorted(String key) =>
      [for (final f in recent) (f[key] as num?)?.toInt() ?? 0]..sort();
  int? at(List<int> values, double p) => values.isEmpty
      ? null
      : values[(values.length * p).floor().clamp(0, values.length - 1)];
  final raster = sorted('rasterDurationUs');
  final ui = sorted('uiDurationUs');
  return {
    'frames': recent.length,
    'rasterP50Us': at(raster, 0.5),
    'rasterP90Us': at(raster, 0.9),
    'uiP50Us': at(ui, 0.5),
    'uiP90Us': at(ui, 0.9),
  };
}

String _summary(Map<String, dynamic> result) {
  final failed = (result['actions'] as List)
      .cast<Map>()
      .where((a) => a['ok'] != true)
      .map((a) => jsonEncode(a['step']))
      .toList();
  final phases = (result['issues'] as Map).cast<String, Map>();
  final frames = (result['frames'] as Map).cast<String, Map>();
  return [
    for (final MapEntry(key: phase, value: issues) in phases.entries)
      '  $phase: ${issues.isEmpty ? 'no issues' : issues.entries.map((e) => '${e.key}:${(e.value as Map)['severity']}').join(', ')}',
    for (final MapEntry(key: phase, value: f) in frames.entries)
      '  $phase frames: raster p50 ${f['rasterP50Us']} p90 '
          '${f['rasterP90Us']} µs, ui p50 ${f['uiP50Us']} p90 '
          '${f['uiP90Us']} µs',
    '  budget: ${result['frameBudgetUs']} µs at '
        '${result['effectiveFrameRateHz']} Hz',
    if (failed.isNotEmpty) '  failed steps: ${failed.join(' ')}',
  ].join('\n');
}
