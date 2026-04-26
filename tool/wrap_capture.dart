// Wraps a raw DevTools timeline JSON export with the `sleuthMetadata`
// block that `ProfileCaptureSchema.parseFile` requires. Eliminates the
// hand-edit step of the capture procedure — without this tool the
// developer hand-writes JSON metadata, which encodes whatever shape
// they remember from the schema and creates a same-author tautology
// risk for the audit gate.
//
// Usage (run from repo root via `fvm dart tool/wrap_capture.dart`):
//
//   --input <path>           Raw DevTools "Save timeline JSON" export
//   --output <path>          Wrapped capture file path
//   --scenario <name>        Scenario label (free text, identifies the
//                            captured workload — e.g. "HeavyCompute at
//                            8 ms threshold")
//   --magnitude-min <n>      expectedMagnitude.min
//   --magnitude-observed <n> expectedMagnitude.observed
//   --magnitude-max <n>      expectedMagnitude.max
//   --unit <s>               expectedMagnitude.unit (e.g. "ms")
//   --device <s>             Reference device name matching
//                            ProfileCaptureSchema.approvedDevicePairs
//   --device-os <s>          Reference device OS version matching the
//                            approved set (e.g. "iOS 17.5")
//   --flutter-version <s>    Flutter version pinned by the capture
//                            (e.g. "3.41.4")
//   --capture-command <s>    Optional. Defaults to a generic
//                            `fvm flutter run --profile -d <device>`
//                            string.
//   --capture-notes <s>      Optional free text appended to
//                            sleuthMetadata.captureNotes for context.
//   --force                  Optional. Allow overwriting an existing
//                            output file. Without this flag, the tool
//                            refuses to clobber to prevent accidental
//                            destruction of a freshly captured trace.
//                            Also overrides the BUILD-cross-check and
//                            severity-boundary guards (use sparingly).
//   --severity-boundary <n>  Optional, repeatable. Detector severity
//                            threshold in the same unit as
//                            --magnitude-observed (e.g. 8 and 16 for
//                            HeavyCompute). When the BUILD ms and the
//                            user-supplied --magnitude-observed straddle
//                            ANY of these boundaries, the wrapper
//                            refuses (a wrapped capture's emitted
//                            severity could disagree with what the
//                            detector would have classified on the
//                            same magnitude). --force overrides.

import 'dart:convert';
import 'dart:io';

const _captureSchemaVersion = 'v1';

void main(List<String> args) {
  final parsed = _parseArgs(args);
  final inputFile = File(parsed.input);
  if (!inputFile.existsSync()) {
    stderr.writeln('Input file does not exist: ${parsed.input}');
    exit(2);
  }
  // Guard: --input and --output must not resolve to the same path.
  // Writing the wrapped output back over the raw input destroys the
  // unmodified DevTools export and makes re-wrapping impossible.
  if (_canonicalPath(parsed.input) == _canonicalPath(parsed.output)) {
    stderr.writeln('Refusing to write output to the same path as --input '
        '(${parsed.input}). The raw DevTools export must remain '
        'untouched. Pick a separate --output path.');
    exit(2);
  }
  final outFile = File(parsed.output);
  if (outFile.existsSync() && !parsed.force) {
    stderr.writeln('Output already exists: ${parsed.output}. Pass --force to '
        'overwrite, or pick a different --output path. Refusing to '
        'clobber a previous wrapped capture by default.');
    exit(2);
  }
  final rawJson = json.decode(inputFile.readAsStringSync());
  if (rawJson is! Map<String, Object?>) {
    stderr.writeln('Input is not a JSON object at the root: ${parsed.input}');
    exit(2);
  }
  if (rawJson['traceEvents'] is! List) {
    stderr.writeln(
        'Input lacks `traceEvents` array — not a DevTools timeline export.');
    exit(2);
  }
  // Guard: refuse to double-wrap. If sleuthMetadata is already
  // present, the input is already a wrapped capture and re-running
  // the tool would silently overwrite the prior metadata block.
  if (rawJson['sleuthMetadata'] != null) {
    stderr
        .writeln('Input already contains a `sleuthMetadata` block — looks like '
            'an already-wrapped capture, not a raw DevTools export. '
            'Re-export from DevTools (Save timeline JSON) or re-wrap from '
            'the original raw file.');
    exit(2);
  }

  // Cross-check user-supplied --magnitude-observed against the actual
  // BUILD-event duration recorded inside the scenario span. Detectors
  // (HeavyComputeDetector, FrameTimingDetector, …) classify on the
  // BUILD event's `dur`, so the wrapped capture's expectedMagnitude
  // must reflect THAT signal, not a Stopwatch proxy that wraps a
  // narrower part of the build phase. Mismatches between the two
  // produce silently-misclassified captures whose audit-gate trace
  // record can disagree with what the detector would have emitted on
  // the same data.
  //
  // Skip the check when no BUILD event exists in the scenario span
  // (older captures, FRAME-mode runs without scenario markers, etc.)
  // — the schema and audit gate will catch those at validation time.
  final events = rawJson['traceEvents'] as List;
  final buildMs = _findScenarioBuildMs(events);
  if (buildMs != null) {
    final delta = (buildMs - parsed.magnitudeObserved).abs();
    final tolerance = parsed.magnitudeObserved * 0.10;
    if (delta > tolerance && !parsed.force) {
      stderr.writeln('BUILD-event duration inside the scenario span '
          '(${buildMs.toStringAsFixed(2)} ms) disagrees with '
          '--magnitude-observed (${parsed.magnitudeObserved}) by '
          '${delta.toStringAsFixed(2)} ms — outside ±10 % tolerance. '
          'The detector classifies on the BUILD event; the wrapped '
          'capture\'s observed magnitude should match. Either re-record '
          'with the correct iteration count, pass --magnitude-observed '
          '${buildMs.toStringAsFixed(1)}, or pass --force to override '
          '(NOT recommended: the trace record\'s severity may not match '
          'what the schema audit will accept).');
      exit(2);
    }
    // Severity-boundary check. The ±10% BUILD tolerance is too loose
    // near hard severity thresholds: e.g. observed=15.0 + BUILD=16.4
    // passes the percentage check (delta=1.4 ≤ 1.5 tolerance) but the
    // detector would classify BUILD>16 as `.critical` while a synthetic
    // record from observed=15 is `.warning`. Refuse when the
    // observed/BUILD pair straddles ANY user-supplied severity
    // boundary — the wrapped capture's severity claim can't be
    // trusted across that boundary regardless of percentage delta.
    if (!parsed.force) {
      final lo = buildMs < parsed.magnitudeObserved
          ? buildMs
          : parsed.magnitudeObserved.toDouble();
      final hi = buildMs > parsed.magnitudeObserved
          ? buildMs
          : parsed.magnitudeObserved.toDouble();
      for (final boundary in parsed.severityBoundaries) {
        if (lo < boundary && boundary <= hi) {
          stderr.writeln(
              'BUILD-event duration (${buildMs.toStringAsFixed(2)} ms) and '
              '--magnitude-observed (${parsed.magnitudeObserved}) straddle '
              'severity boundary $boundary ${parsed.unit}. '
              'A capture whose observed/BUILD pair crosses a detector '
              'severity threshold cannot reliably claim a single '
              'severity tier — re-record so both magnitudes fall on the '
              'same side of every boundary, or pass --force to override '
              '(NOT recommended).');
          exit(2);
        }
      }
    }
  }

  final wrapped = <String, Object?>{
    ...rawJson,
    'sleuthMetadata': <String, Object?>{
      'schemaVersion': _captureSchemaVersion,
      'device': parsed.device,
      'deviceOsVersion': parsed.deviceOs,
      'flutterVersion': parsed.flutterVersion,
      'captureCommand': parsed.captureCommand ??
          'fvm flutter run --profile -d <${parsed.device}>',
      'scenario': parsed.scenario,
      'expectedMagnitude': <String, Object?>{
        'min': parsed.magnitudeMin,
        'observed': parsed.magnitudeObserved,
        'max': parsed.magnitudeMax,
        'unit': parsed.unit,
      },
      'captureDate': DateTime.now().toUtc().toIso8601String(),
      'role': parsed.role,
      if (parsed.captureNotes != null) 'captureNotes': parsed.captureNotes,
    },
  };
  outFile.parent.createSync(recursive: true);
  outFile
      .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(wrapped));
  stdout.writeln('Wrapped capture written to ${parsed.output}');
}

// Resolve a path to its canonical absolute form so two textually
// distinct strings ("./foo.json" vs "foo.json") that point at the
// same on-disk file fail the same-path guard. Falls back to the raw
// path when the file does not yet exist (output) — Dart's
// `File.absolute.path` performs the prefix work without resolving
// symlinks, which is enough to catch the common "wrote --output to
// the same string as --input" footgun.
String _canonicalPath(String raw) => File(raw).absolute.path;

// Returns the maximum BUILD-event duration (ms) observed inside the
// `sleuth.scenario.begin` / `sleuth.scenario.end` span, or null when
// no scenario span / BUILD event exists. Used to cross-check the
// user-supplied --magnitude-observed against the signal the detector
// would actually classify on.
//
// Accepts both Chrome-native `ph: 'X'` complete events (Flutter
// emits these for buildScope when deep instrumentation is OFF) and
// the synthetic-discarded `ph: 'b'/'e'` async pairs (deep
// instrumentation ON — captures used for `runtimeVerified` should
// have it OFF, but parse both forms defensively).
double? _findScenarioBuildMs(List events) {
  int? scenarioBeginTs;
  int? scenarioEndTs;
  for (final event in events) {
    if (event is! Map) continue;
    final name = event['name'];
    final ph = event['ph'];
    final ts = event['ts'];
    if (ts is! num) continue;
    if (name == 'sleuth.scenario.begin' &&
        (ph == 'i' || ph == 'I' || ph == 'n')) {
      scenarioBeginTs = ts.toInt();
    } else if (name == 'sleuth.scenario.end' &&
        (ph == 'i' || ph == 'I' || ph == 'n')) {
      scenarioEndTs = ts.toInt();
    }
  }
  if (scenarioBeginTs == null || scenarioEndTs == null) return null;
  if (scenarioEndTs <= scenarioBeginTs) return null;

  // Sync `ph: 'X'` BUILD events have ts (start) and dur (microseconds).
  // The event is "inside the span" if its [ts, ts+dur] interval
  // overlaps [scenarioBeginTs, scenarioEndTs] — but for the
  // detector-relevant case the BUILD that runs the workload starts
  // at-or-before the scenario.begin (the markScenario call is inside
  // build()) and ends at-or-after scenario.end. We accept any BUILD
  // whose ts falls in the span OR whose [ts, ts+dur] interval contains
  // the span entirely.
  var maxBuildDurUs = 0;
  for (final event in events) {
    if (event is! Map) continue;
    if (event['name'] != 'BUILD') continue;
    final ph = event['ph'];
    final ts = event['ts'];
    if (ts is! num) continue;
    if (ph == 'X') {
      final dur = event['dur'];
      if (dur is! num) continue;
      final tsInt = ts.toInt();
      final durInt = dur.toInt();
      final tsEnd = tsInt + durInt;
      final inSpan = (tsInt >= scenarioBeginTs && tsInt <= scenarioEndTs) ||
          (tsEnd >= scenarioBeginTs && tsEnd <= scenarioEndTs) ||
          (tsInt <= scenarioBeginTs && tsEnd >= scenarioEndTs);
      if (inSpan && durInt > maxBuildDurUs) maxBuildDurUs = durInt;
    }
  }
  // Async `ph: 'b'/'e'` BUILD pairs — match by `id` / `id2.local` and
  // compute dur from the timestamp delta. Only used when no `ph: 'X'`
  // BUILD was found above, since the schema's preferred format is X.
  if (maxBuildDurUs == 0) {
    final asyncStarts = <String, int>{};
    for (final event in events) {
      if (event is! Map) continue;
      if (event['name'] != 'BUILD') continue;
      final ph = event['ph'];
      final ts = event['ts'];
      if (ts is! num) continue;
      final id = _eventCorrelationKey(event);
      if (id == null) continue;
      if (ph == 'b') {
        asyncStarts[id] = ts.toInt();
      } else if (ph == 'e') {
        final start = asyncStarts.remove(id);
        if (start == null) continue;
        final tsInt = ts.toInt();
        final durUs = tsInt - start;
        if (durUs <= 0) continue;
        final inSpan = (start >= scenarioBeginTs && start <= scenarioEndTs) ||
            (tsInt >= scenarioBeginTs && tsInt <= scenarioEndTs) ||
            (start <= scenarioBeginTs && tsInt >= scenarioEndTs);
        if (inSpan && durUs > maxBuildDurUs) maxBuildDurUs = durUs;
      }
    }
  }
  if (maxBuildDurUs == 0) return null;
  return maxBuildDurUs / 1000.0;
}

String? _eventCorrelationKey(Map event) {
  final id = event['id'];
  if (id is String) return id;
  final id2 = event['id2'];
  if (id2 is Map) {
    final local = id2['local'];
    if (local is String) return local;
    final global = id2['global'];
    if (global is String) return global;
  }
  return null;
}

class _Args {
  _Args({
    required this.input,
    required this.output,
    required this.scenario,
    required this.role,
    required this.magnitudeMin,
    required this.magnitudeObserved,
    required this.magnitudeMax,
    required this.unit,
    required this.device,
    required this.deviceOs,
    required this.flutterVersion,
    required this.force,
    required this.severityBoundaries,
    this.captureCommand,
    this.captureNotes,
  });
  final String input;
  final String output;
  final String scenario;
  final String role;
  final num magnitudeMin;
  final num magnitudeObserved;
  final num magnitudeMax;
  final String unit;
  final String device;
  final String deviceOs;
  final String flutterVersion;
  final bool force;
  final List<num> severityBoundaries;
  final String? captureCommand;
  final String? captureNotes;
}

_Args _parseArgs(List<String> args) {
  String? input,
      output,
      scenario,
      role,
      unit,
      device,
      deviceOs,
      flutterVersion,
      captureCommand,
      captureNotes;
  num? magnitudeMin, magnitudeObserved, magnitudeMax;
  var force = false;
  final severityBoundaries = <num>[];
  for (var i = 0; i < args.length; i++) {
    final flag = args[i];
    // Boolean flags consume no value.
    if (flag == '--force') {
      force = true;
      continue;
    }
    if (flag == '--help' || flag == '-h') {
      _printUsage();
      exit(0);
    }
    if (i + 1 >= args.length) {
      stderr.writeln('Missing value for flag: $flag');
      _printUsage();
      exit(2);
    }
    final value = args[i + 1];
    i++;
    switch (flag) {
      case '--input':
        input = value;
      case '--output':
        output = value;
      case '--scenario':
        scenario = value;
      case '--magnitude-min':
        magnitudeMin = num.parse(value);
      case '--magnitude-observed':
        magnitudeObserved = num.parse(value);
      case '--magnitude-max':
        magnitudeMax = num.parse(value);
      case '--unit':
        unit = value;
      case '--device':
        device = value;
      case '--device-os':
        deviceOs = value;
      case '--flutter-version':
        flutterVersion = value;
      case '--capture-command':
        captureCommand = value;
      case '--capture-notes':
        captureNotes = value;
      case '--role':
        role = value;
      case '--severity-boundary':
        severityBoundaries.add(num.parse(value));
      default:
        stderr.writeln('Unknown flag: $flag');
        _printUsage();
        exit(2);
    }
  }
  final missing = <String>[
    if (input == null) '--input',
    if (output == null) '--output',
    if (scenario == null) '--scenario',
    if (magnitudeMin == null) '--magnitude-min',
    if (magnitudeObserved == null) '--magnitude-observed',
    if (magnitudeMax == null) '--magnitude-max',
    if (unit == null) '--unit',
    if (device == null) '--device',
    if (deviceOs == null) '--device-os',
    if (flutterVersion == null) '--flutter-version',
  ];
  if (missing.isNotEmpty) {
    stderr.writeln('Missing required flags: ${missing.join(', ')}');
    _printUsage();
    exit(2);
  }
  // Default-derive role from filename suffix when --role not passed.
  // Backward-compat for existing scripts/CI invoking wrap_capture
  // without the new flag. Recognizes `*_below.json`, `*_at.json`,
  // `*_above.json`. Fail with explicit error if filename has no
  // recognizable suffix AND --role was not passed.
  if (role == null) {
    final base = output!.split('/').last.toLowerCase();
    if (base.endsWith('_below.json')) {
      role = 'below';
    } else if (base.endsWith('_at.json')) {
      role = 'at';
    } else if (base.endsWith('_above.json')) {
      role = 'above';
    } else {
      stderr
          .writeln('--role not passed AND output filename "$base" does not end '
              'with _below.json / _at.json / _above.json. Pass --role '
              'explicitly: --role below|at|above.');
      exit(2);
    }
  }
  if (!const {'below', 'at', 'above'}.contains(role)) {
    stderr.writeln('--role must be exactly one of: below, at, above '
        '(case-sensitive). Got: "$role".');
    exit(2);
  }
  return _Args(
    input: input!,
    output: output!,
    scenario: scenario!,
    role: role,
    magnitudeMin: magnitudeMin!,
    magnitudeObserved: magnitudeObserved!,
    magnitudeMax: magnitudeMax!,
    unit: unit!,
    device: device!,
    deviceOs: deviceOs!,
    flutterVersion: flutterVersion!,
    force: force,
    severityBoundaries: List.unmodifiable(severityBoundaries),
    captureCommand: captureCommand,
    captureNotes: captureNotes,
  );
}

void _printUsage() {
  stderr.writeln(
      'Usage: dart tool/wrap_capture.dart --input <raw.json> --output <wrapped.json> ');
  stderr.writeln(
      '       --scenario <name> --magnitude-min <n> --magnitude-observed <n>');
  stderr.writeln(
      '       --magnitude-max <n> --unit <s> --device <s> --device-os <s>');
  stderr.writeln(
      '       --flutter-version <s> [--capture-command <s>] [--capture-notes <s>]');
}
