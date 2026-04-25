// Smoke-tests the wrap_capture CLI by feeding a minimal raw timeline
// fixture through the tool and parsing the output via
// `ProfileCaptureSchema.parseFile`. Round-trips success means the
// wrapper produces sleuthMetadata of the exact shape the schema
// requires, which closes the same-author tautology vector — the
// procedure step "wrap with sleuthMetadata block" no longer needs
// hand-editing.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/validation/profile_capture_schema.dart';

void main() {
  group('tool/wrap_capture.dart', () {
    late Directory tempDir;
    late File rawInput;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('wrap_capture_test_');
      rawInput = File('${tempDir.path}/raw.json');
      // Minimum-viable DevTools timeline export: one work-phase event,
      // scenario markers, plus enough unrelated metadata to clear
      // ProfileCaptureSchema's `minTraceEvents` floor (= 10).
      final events = <Map<String, Object?>>[
        // Scenario markers — required for AB-1 cross-check.
        {
          'name': 'sleuth.scenario.begin',
          'cat': 'embedder',
          'ph': 'i',
          'ts': 1000000,
          'pid': 1,
          'tid': 1,
        },
        {
          'name': 'sleuth.scenario.end',
          'cat': 'embedder',
          'ph': 'i',
          'ts': 1010000,
          'pid': 1,
          'tid': 1,
        },
        // 3 work-phase events of "Build" duration totalling 8000us
        // (the magnitude we'll declare).
        for (int i = 0; i < 3; i++)
          {
            'name': 'Build',
            'cat': 'flutter',
            'ph': 'X',
            'ts': 1001000 + (i * 1000),
            'dur': 1000,
            'pid': 1,
            'tid': 1,
          },
        // Pad to clear minTraceEvents.
        for (int i = 0; i < 7; i++)
          {
            'name': 'idle',
            'cat': 'flutter',
            'ph': 'X',
            'ts': 1002000 + (i * 100),
            'dur': 50,
            'pid': 1,
            'tid': 1,
          },
      ];
      rawInput.writeAsStringSync(json.encode({'traceEvents': events}));
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('wraps + parses cleanly via ProfileCaptureSchema.parseFile', () async {
      final outputPath = '${tempDir.path}/wrapped.json';
      final result = await Process.run('dart', [
        'tool/wrap_capture.dart',
        '--input',
        rawInput.path,
        '--output',
        outputPath,
        '--scenario',
        'wrap_capture_test smoke',
        '--magnitude-min',
        '6',
        '--magnitude-observed',
        '8',
        '--magnitude-max',
        '12',
        '--unit',
        'ms',
        '--device',
        'iPhone 12',
        '--device-os',
        'iOS 17.5',
        '--flutter-version',
        '3.41.4',
      ]);
      if (result.exitCode != 0) {
        fail('wrap_capture exited ${result.exitCode}: '
            'stdout=${result.stdout}, stderr=${result.stderr}');
      }
      // ProfileCaptureSchema.parseFile must succeed on the wrapped
      // output without hand-editing.
      expect(
        () => ProfileCaptureSchema.parseFile(File(outputPath)),
        returnsNormally,
        reason: 'wrap_capture output failed schema parse — wrapper '
            'and schema are out of sync',
      );
    });

    test('exits non-zero on missing required flag', () async {
      final result = await Process.run('dart', [
        'tool/wrap_capture.dart',
        '--input', rawInput.path,
        // Missing every other flag.
      ]);
      expect(result.exitCode, isNot(0));
      expect(result.stderr.toString(), contains('Missing required flags'));
    });

    test('exits non-zero on unknown flag', () async {
      final result = await Process.run('dart', [
        'tool/wrap_capture.dart',
        '--bogus',
        'value',
      ]);
      expect(result.exitCode, isNot(0));
      expect(result.stderr.toString(), contains('Unknown flag'));
    });

    // M1 — refuse --input == --output to prevent destroying the raw
    // DevTools export.
    test('refuses --output that resolves to the same path as --input',
        () async {
      final result = await Process.run('dart', [
        'tool/wrap_capture.dart',
        '--input', rawInput.path,
        '--output', rawInput.path, // identical
        '--scenario', 'same-path attempt',
        '--magnitude-min', '6',
        '--magnitude-observed', '8',
        '--magnitude-max', '12',
        '--unit', 'ms',
        '--device', 'iPhone 12',
        '--device-os', 'iOS 17.5',
        '--flutter-version', '3.41.4',
      ]);
      expect(result.exitCode, isNot(0));
      expect(result.stderr.toString(),
          contains('Refusing to write output to the same path as --input'));
    });

    // M1 — refuse to overwrite an existing output file without --force.
    test('refuses to overwrite existing output without --force', () async {
      final outputPath = '${tempDir.path}/wrapped.json';
      File(outputPath).writeAsStringSync('{"prior": true}');
      final result = await Process.run('dart', [
        'tool/wrap_capture.dart',
        '--input',
        rawInput.path,
        '--output',
        outputPath,
        '--scenario',
        'overwrite attempt',
        '--magnitude-min',
        '6',
        '--magnitude-observed',
        '8',
        '--magnitude-max',
        '12',
        '--unit',
        'ms',
        '--device',
        'iPhone 12',
        '--device-os',
        'iOS 17.5',
        '--flutter-version',
        '3.41.4',
      ]);
      expect(result.exitCode, isNot(0));
      expect(result.stderr.toString(), contains('Output already exists'));
      expect(result.stderr.toString(), contains('--force'));
      // Prior file untouched.
      expect(File(outputPath).readAsStringSync(), contains('"prior"'));
    });

    // M1 — --force allows overwrite.
    test('--force overwrites an existing output file', () async {
      final outputPath = '${tempDir.path}/wrapped.json';
      File(outputPath).writeAsStringSync('{"prior": true}');
      final result = await Process.run('dart', [
        'tool/wrap_capture.dart',
        '--input',
        rawInput.path,
        '--output',
        outputPath,
        '--scenario',
        'forced overwrite',
        '--magnitude-min',
        '6',
        '--magnitude-observed',
        '8',
        '--magnitude-max',
        '12',
        '--unit',
        'ms',
        '--device',
        'iPhone 12',
        '--device-os',
        'iOS 17.5',
        '--flutter-version',
        '3.41.4',
        '--force',
      ]);
      expect(result.exitCode, 0,
          reason: 'wrap_capture --force should succeed: '
              'stdout=${result.stdout}, stderr=${result.stderr}');
      expect(File(outputPath).readAsStringSync(), contains('sleuthMetadata'));
    });

    // M1 — refuse to double-wrap an already-wrapped capture.
    test('refuses to double-wrap an already-wrapped capture', () async {
      final wrappedInput = File('${tempDir.path}/already_wrapped.json');
      wrappedInput.writeAsStringSync(json.encode({
        'traceEvents': [
          {
            'name': 'sleuth.scenario.begin',
            'cat': 'embedder',
            'ph': 'i',
            'ts': 1000000,
            'pid': 1,
            'tid': 1,
          },
        ],
        'sleuthMetadata': {'schemaVersion': 'v1'},
      }));
      final outputPath = '${tempDir.path}/double_wrapped.json';
      final result = await Process.run('dart', [
        'tool/wrap_capture.dart',
        '--input',
        wrappedInput.path,
        '--output',
        outputPath,
        '--scenario',
        'double-wrap attempt',
        '--magnitude-min',
        '6',
        '--magnitude-observed',
        '8',
        '--magnitude-max',
        '12',
        '--unit',
        'ms',
        '--device',
        'iPhone 12',
        '--device-os',
        'iOS 17.5',
        '--flutter-version',
        '3.41.4',
      ]);
      expect(result.exitCode, isNot(0));
      expect(result.stderr.toString(),
          contains('already contains a `sleuthMetadata` block'));
    });

    // BUILD cross-check: when the captured timeline contains a BUILD
    // event inside the scenario span, --magnitude-observed must agree
    // with that event's `dur` within ±10 %. This is what protects the
    // capture from Stopwatch-vs-BUILD skew on USB-tethered FRAME-mode
    // recordings — the BUILD is the signal the detector classifies on.
    Future<File> writeBuildFixture({required int buildDurUs}) async {
      // BUILD spans the scenario; scenario markers fall inside it.
      const scenarioBeginUs = 1001000;
      const scenarioEndUs = 1009000;
      final buildStartUs = scenarioBeginUs - 500;
      final events = <Map<String, Object?>>[
        {
          'name': 'BUILD',
          'cat': 'flutter',
          'ph': 'X',
          'ts': buildStartUs,
          'dur': buildDurUs,
          'pid': 1,
          'tid': 1,
        },
        {
          'name': 'sleuth.scenario.begin',
          'cat': 'embedder',
          'ph': 'i',
          'ts': scenarioBeginUs,
          'pid': 1,
          'tid': 1,
        },
        {
          'name': 'sleuth.scenario.end',
          'cat': 'embedder',
          'ph': 'i',
          'ts': scenarioEndUs,
          'pid': 1,
          'tid': 1,
        },
        for (int i = 0; i < 10; i++)
          {
            'name': 'idle',
            'cat': 'flutter',
            'ph': 'X',
            'ts': scenarioBeginUs + (i * 100),
            'dur': 50,
            'pid': 1,
            'tid': 1,
          },
      ];
      final f = File('${tempDir.path}/build_fixture.json');
      f.writeAsStringSync(json.encode({'traceEvents': events}));
      return f;
    }

    test('accepts when --magnitude-observed matches BUILD ms within ±10 %',
        () async {
      final input = await writeBuildFixture(buildDurUs: 10000);
      final outputPath = '${tempDir.path}/wrapped_match.json';
      final result = await Process.run('dart', [
        'tool/wrap_capture.dart',
        '--input',
        input.path,
        '--output',
        outputPath,
        '--scenario',
        'BUILD-match',
        '--magnitude-min',
        '8',
        '--magnitude-observed',
        '10',
        '--magnitude-max',
        '12',
        '--unit',
        'ms',
        '--device',
        'iPhone 12',
        '--device-os',
        'iOS 17.5',
        '--flutter-version',
        '3.41.4',
      ]);
      expect(result.exitCode, 0,
          reason: 'BUILD ms 10.0 should match observed 10 ±10%: '
              'stderr=${result.stderr}');
    });

    test('rejects when --magnitude-observed disagrees with BUILD ms', () async {
      final input = await writeBuildFixture(buildDurUs: 10000);
      final outputPath = '${tempDir.path}/wrapped_skew.json';
      final result = await Process.run('dart', [
        'tool/wrap_capture.dart',
        '--input', input.path,
        '--output', outputPath,
        '--scenario', 'BUILD-skew',
        '--magnitude-min', '6',
        '--magnitude-observed', '7', // BUILD is 10 ms; 30% drift
        '--magnitude-max', '8',
        '--unit', 'ms',
        '--device', 'iPhone 12',
        '--device-os', 'iOS 17.5',
        '--flutter-version', '3.41.4',
      ]);
      expect(result.exitCode, isNot(0));
      expect(result.stderr.toString(),
          contains('BUILD-event duration inside the scenario span'));
      expect(result.stderr.toString(), contains('--force'));
    });

    test('--force overrides BUILD cross-check', () async {
      final input = await writeBuildFixture(buildDurUs: 10000);
      final outputPath = '${tempDir.path}/wrapped_forced_skew.json';
      final result = await Process.run('dart', [
        'tool/wrap_capture.dart',
        '--input',
        input.path,
        '--output',
        outputPath,
        '--scenario',
        'BUILD-skew-force',
        '--magnitude-min',
        '6',
        '--magnitude-observed',
        '7',
        '--magnitude-max',
        '8',
        '--unit',
        'ms',
        '--device',
        'iPhone 12',
        '--device-os',
        'iOS 17.5',
        '--flutter-version',
        '3.41.4',
        '--force',
      ]);
      expect(result.exitCode, 0,
          reason: '--force must bypass BUILD-cross-check: '
              'stderr=${result.stderr}');
    });

    // Severity-boundary cross-check. The ±10% BUILD tolerance is
    // insufficient near hard severity thresholds (warning=8 ms,
    // critical=16 ms for HeavyCompute). When the observed/BUILD pair
    // straddles a boundary, the wrapped capture's claimed severity is
    // ambiguous and must be rejected.
    test('accepts when severity boundary not crossed', () async {
      final input = await writeBuildFixture(buildDurUs: 10000);
      final outputPath = '${tempDir.path}/wrapped_no_boundary_cross.json';
      // BUILD=10ms, observed=10ms — both > 8 (warning boundary), both
      // < 16 (critical boundary). Boundary list [8, 16] supplied.
      final result = await Process.run('dart', [
        'tool/wrap_capture.dart',
        '--input',
        input.path,
        '--output',
        outputPath,
        '--scenario',
        'no-boundary-cross',
        '--magnitude-min',
        '8',
        '--magnitude-observed',
        '10',
        '--magnitude-max',
        '12',
        '--unit',
        'ms',
        '--device',
        'iPhone 12',
        '--device-os',
        'iOS 17.5',
        '--flutter-version',
        '3.41.4',
        '--severity-boundary',
        '8',
        '--severity-boundary',
        '16',
      ]);
      expect(result.exitCode, 0,
          reason: 'BUILD/observed both inside (8, 16) should accept: '
              'stderr=${result.stderr}');
    });

    test('rejects when observed/BUILD pair straddles severity boundary',
        () async {
      // BUILD=16.5ms (would fire `.critical`), observed=15.5ms (would
      // emit `.warning`). Within ±10% tolerance (delta 1.0 ≤ 1.55) so
      // the BUILD cross-check passes — but they straddle the
      // critical boundary at 16, so the severity-boundary check must
      // refuse.
      final input = await writeBuildFixture(buildDurUs: 16500);
      final outputPath = '${tempDir.path}/wrapped_boundary_cross.json';
      final result = await Process.run('dart', [
        'tool/wrap_capture.dart',
        '--input',
        input.path,
        '--output',
        outputPath,
        '--scenario',
        'boundary-cross',
        '--magnitude-min',
        '14',
        '--magnitude-observed',
        '15.5',
        '--magnitude-max',
        '17',
        '--unit',
        'ms',
        '--device',
        'iPhone 12',
        '--device-os',
        'iOS 17.5',
        '--flutter-version',
        '3.41.4',
        '--severity-boundary',
        '8',
        '--severity-boundary',
        '16',
      ]);
      expect(result.exitCode, isNot(0));
      expect(
          result.stderr.toString(), contains('straddle severity boundary 16'));
      expect(result.stderr.toString(), contains('--force'));
    });

    test('--force overrides severity-boundary check', () async {
      final input = await writeBuildFixture(buildDurUs: 16500);
      final outputPath = '${tempDir.path}/wrapped_boundary_forced.json';
      final result = await Process.run('dart', [
        'tool/wrap_capture.dart',
        '--input',
        input.path,
        '--output',
        outputPath,
        '--scenario',
        'boundary-cross-forced',
        '--magnitude-min',
        '14',
        '--magnitude-observed',
        '15.5',
        '--magnitude-max',
        '17',
        '--unit',
        'ms',
        '--device',
        'iPhone 12',
        '--device-os',
        'iOS 17.5',
        '--flutter-version',
        '3.41.4',
        '--severity-boundary',
        '16',
        '--force',
      ]);
      expect(result.exitCode, 0,
          reason: '--force must bypass severity-boundary check: '
              'stderr=${result.stderr}');
    });
  });
}
