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

class _Args {
  _Args({
    required this.input,
    required this.output,
    required this.scenario,
    required this.magnitudeMin,
    required this.magnitudeObserved,
    required this.magnitudeMax,
    required this.unit,
    required this.device,
    required this.deviceOs,
    required this.flutterVersion,
    required this.force,
    this.captureCommand,
    this.captureNotes,
  });
  final String input;
  final String output;
  final String scenario;
  final num magnitudeMin;
  final num magnitudeObserved;
  final num magnitudeMax;
  final String unit;
  final String device;
  final String deviceOs;
  final String flutterVersion;
  final bool force;
  final String? captureCommand;
  final String? captureNotes;
}

_Args _parseArgs(List<String> args) {
  String? input,
      output,
      scenario,
      unit,
      device,
      deviceOs,
      flutterVersion,
      captureCommand,
      captureNotes;
  num? magnitudeMin, magnitudeObserved, magnitudeMax;
  var force = false;
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
  return _Args(
    input: input!,
    output: output!,
    scenario: scenario!,
    magnitudeMin: magnitudeMin!,
    magnitudeObserved: magnitudeObserved!,
    magnitudeMax: magnitudeMax!,
    unit: unit!,
    device: device!,
    deviceOs: deviceOs!,
    flutterVersion: flutterVersion!,
    force: force,
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
