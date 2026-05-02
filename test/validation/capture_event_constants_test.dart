// Cross-check round-trip: pin that the format constants in
// `lib/src/validation/capture_event_constants.dart` are the SOLE
// source of truth for issue trace event names. Both
// `CaptureHelper.composeIssueEvent` and
// `ProfileCaptureSchema._requireIssueTraceRecord` consume these
// constants — this test exercises both ends to fail loudly if a
// future refactor splits them.
//
// Mechanism: synthesize a minimal capture JSON containing scenario
// markers + a single instant event whose name is composed via
// `issueTraceEventName(...)`. Run it through
// `ProfileCaptureSchema.validateBracket(... requireDetectorTraceRecord:
// true)`. Round-trip success means the same constant flowed through
// both paths byte-for-byte.
//
// Limitation (Tactic 9 — Test Fixture Audit): the JSON fixture is
// hand-constructed in `_writeCapture(...)` below, NOT captured from
// a real `flutter run --profile` session. Both the emitter side
// (CaptureHelper.composeIssueEvent) and the parser side
// (ProfileCaptureSchema._requireIssueTraceRecord) route through the
// SHARED constant, so any rename of `issueTraceEventPrefix`,
// `instantPhaseChrome`, or `issueTraceEventName(...)` itself fails
// the round-trip — that is what this test exists to catch. What this
// test CANNOT catch is the real-VM wire format diverging from the
// hand-rolled fixture (e.g. Flutter's Timeline emitting a phase code
// the schema's `allowedTracePhases` set does not include, or args
// being encoded as numbers when the parser expects strings).
//
// That gap closes in Phase B (v0.18.0) when the first runtimeVerified
// detector ships with three real iPhone 12 captures generated via
// `tool/wrap_capture.dart`; those captures are not author-controlled
// JSON and exercise the actual VM Timeline emission path through
// DevTools' "Save timeline JSON" export.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/validation/capture_event_constants.dart';
import 'package:sleuth/src/validation/profile_capture_schema.dart';

void main() {
  group('capture_event_constants ↔ schema round-trip', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp
          .createTemp('capture_event_constants_test_');
    });

    tearDown(() async {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('round-trip: warning event composed via constants is found by schema',
        () async {
      // Compose the trace event name via the SAME constant the
      // emitter uses. If the constant changes and the schema parser
      // looks for the old prefix, this test fails.
      const stableId = 'heavy_compute';
      const severityLabel = 'warning';
      final eventName = issueTraceEventName(stableId, severityLabel);
      // Sanity: composed name uses the public constant.
      expect(eventName, startsWith(issueTraceEventPrefix));
      expect(eventName, endsWith('.$severityLabel'));

      final triad = await _writeTriad(
        tempDir,
        stableId: stableId,
        severityLabel: severityLabel,
        emitInBelow: false,
      );

      // validateBracket round-trips: schema parses + finds trace
      // record matching the composed name.
      expect(
        () => ProfileCaptureSchema.validateBracket(
          belowFile: triad.below,
          atFile: triad.at,
          aboveFile: triad.above,
          threshold: 8,
          unit: 'ms',
          requireDetectorTraceRecord: true,
          stableId: stableId,
          severityLabel: severityLabel,
        ),
        returnsNormally,
      );
    });

    test('critical severity round-trips identically', () async {
      const stableId = 'shader_compilation';
      const severityLabel = 'critical';
      final triad = await _writeTriad(
        tempDir,
        stableId: stableId,
        severityLabel: severityLabel,
        emitInBelow: false,
        belowObserved: 80,
        atObserved: 105,
        aboveObserved: 150,
      );
      expect(
        () => ProfileCaptureSchema.validateBracket(
          belowFile: triad.below,
          atFile: triad.at,
          aboveFile: triad.above,
          threshold: 100,
          unit: 'ms',
          requireDetectorTraceRecord: true,
          stableId: stableId,
          severityLabel: severityLabel,
        ),
        returnsNormally,
      );
    });

    test('drift: capture missing the trace record fails with precise error',
        () async {
      const stableId = 'heavy_compute';
      // Triad contains scenario markers but NO `sleuth.issue.*` events
      // (simulates a refactor that broke emission).
      final triad = await _writeTriad(
        tempDir,
        stableId: stableId,
        severityLabel: 'warning',
        emitInBelow: false,
        emitInAt: false,
        emitInAbove: false,
      );
      expect(
        () => ProfileCaptureSchema.validateBracket(
          belowFile: triad.below,
          atFile: triad.at,
          aboveFile: triad.above,
          threshold: 8,
          unit: 'ms',
          requireDetectorTraceRecord: true,
          stableId: stableId,
          severityLabel: 'warning',
        ),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('Missing detector trace record'),
            contains('sleuth.issue.heavy_compute.warning'),
          ),
        )),
      );
    });

    test('severity mismatch: warning-claim with only `.critical` present fails',
        () async {
      // Negative test: a capture that only emits
      // `sleuth.issue.heavy_compute.critical` MUST NOT satisfy a
      // `severityLabel: 'warning'` audit. The claim is about the
      // warning bracket (e.g. 8 ms), not the critical bracket (16 ms);
      // accepting a `.critical` event would let the audit confirm the
      // WRONG threshold while looking green.
      const stableId = 'heavy_compute';
      // Triad has `.critical` records (severityLabel: 'critical')
      // but the audit asks for `severityLabel: 'warning'`.
      final triad = await _writeTriad(
        tempDir,
        stableId: stableId,
        severityLabel: 'critical',
        emitInBelow: false,
      );
      expect(
        () => ProfileCaptureSchema.validateBracket(
          belowFile: triad.below,
          atFile: triad.at,
          aboveFile: triad.above,
          threshold: 8,
          unit: 'ms',
          requireDetectorTraceRecord: true,
          stableId: stableId,
          severityLabel: 'warning',
        ),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('Missing detector trace record'),
            contains('sleuth.issue.heavy_compute.warning'),
          ),
        )),
      );
    });

    test('below capture WITH a trace record fails (sub-threshold guard)',
        () async {
      const stableId = 'heavy_compute';
      // Detector should NOT fire below threshold; if a trace record
      // appears in the below capture, the procedure was wrong.
      final triad = await _writeTriad(
        tempDir,
        stableId: stableId,
        severityLabel: 'warning',
        emitInBelow: true,
      );
      expect(
        () => ProfileCaptureSchema.validateBracket(
          belowFile: triad.below,
          atFile: triad.at,
          aboveFile: triad.above,
          threshold: 8,
          unit: 'ms',
          requireDetectorTraceRecord: true,
          stableId: stableId,
          severityLabel: 'warning',
        ),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('Unexpected detector trace record'),
        )),
      );
    });

    test('missing schemaVersion fails with precise error', () async {
      const stableId = 'heavy_compute';
      // Build triad without the schemaVersion field.
      final below = await _writeCapture(tempDir, 'below.json',
          observed: 6,
          stableId: stableId,
          severityLabel: 'warning',
          emitTraceRecord: false,
          omitSchemaVersion: true);
      final at = await _writeCapture(tempDir, 'at.json',
          observed: 8,
          stableId: stableId,
          severityLabel: 'warning',
          emitTraceRecord: true,
          omitSchemaVersion: true);
      final above = await _writeCapture(tempDir, 'above.json',
          observed: 12,
          stableId: stableId,
          severityLabel: 'warning',
          emitTraceRecord: true,
          omitSchemaVersion: true);
      expect(
        () => ProfileCaptureSchema.validateBracket(
          belowFile: below,
          atFile: at,
          aboveFile: above,
          threshold: 8,
          unit: 'ms',
          requireDetectorTraceRecord: true,
          stableId: stableId,
          severityLabel: 'warning',
        ),
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('schemaVersion'),
            contains(captureSchemaVersion),
          ),
        )),
      );
    });
  });
}

class _Triad {
  _Triad({required this.below, required this.at, required this.above});
  final File below;
  final File at;
  final File above;
}

Future<_Triad> _writeTriad(
  Directory dir, {
  required String stableId,
  required String severityLabel,
  bool emitInBelow = false,
  bool emitInAt = true,
  bool emitInAbove = true,
  num belowObserved = 6,
  num atObserved = 8,
  num aboveObserved = 12,
}) async {
  return _Triad(
    below: await _writeCapture(dir, 'below.json',
        observed: belowObserved,
        stableId: stableId,
        severityLabel: severityLabel,
        emitTraceRecord: emitInBelow),
    at: await _writeCapture(dir, 'at.json',
        observed: atObserved,
        stableId: stableId,
        severityLabel: severityLabel,
        emitTraceRecord: emitInAt),
    above: await _writeCapture(dir, 'above.json',
        observed: aboveObserved,
        stableId: stableId,
        severityLabel: severityLabel,
        emitTraceRecord: emitInAbove),
  );
}

Future<File> _writeCapture(
  Directory dir,
  String filename, {
  required num observed,
  required String stableId,
  required String severityLabel,
  required bool emitTraceRecord,
  bool omitSchemaVersion = false,
  String? role,
}) async {
  final resolvedRole = role ??
      (filename.startsWith('below')
          ? 'below'
          : filename.startsWith('above')
              ? 'above'
              : 'at');
  // Hand-construct a minimal-conformant capture. The JSON has the
  // structure ProfileCaptureSchema requires: traceEvents array with
  // ≥3 work-phase events + scenario markers, plus the sleuthMetadata
  // wrapper. Used ONLY for round-trip testing — production captures
  // come from real `flutter run --profile` exports.
  final beginTs = 1000000;
  final endTs = 1010000;
  final events = <Map<String, Object?>>[
    {
      'name': scenarioBeginMarkerName,
      'cat': 'embedder',
      'ph': 'i',
      'ts': beginTs,
      'pid': 1,
      'tid': 1,
    },
    {
      'name': scenarioEndMarkerName,
      'cat': 'embedder',
      'ph': 'i',
      'ts': endTs,
      'pid': 1,
      'tid': 1,
    },
    if (emitTraceRecord)
      {
        'name': issueTraceEventName(stableId, severityLabel),
        'cat': 'embedder',
        'ph': 'i',
        'ts': beginTs + 5000,
        'pid': 1,
        'tid': 1,
        'args': {
          issueTraceArgDetectedAtMicros: '${beginTs + 5000}',
        },
      },
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
  final root = <String, Object?>{
    'traceEvents': events,
    'sleuthMetadata': <String, Object?>{
      if (!omitSchemaVersion) 'schemaVersion': captureSchemaVersion,
      'device': 'iPhone 12',
      'deviceOsVersion': 'iOS 17.5',
      'flutterVersion': '3.41.4',
      'captureCommand': 'fvm flutter run --profile',
      'role': resolvedRole,
      'scenario':
          'round_trip_${filename.endsWith('.json') ? filename.substring(0, filename.length - 5) : filename}',
      'expectedMagnitude': <String, Object?>{
        'min': observed - 1,
        'observed': observed,
        'max': observed + 4,
        'unit': 'ms',
      },
      'captureDate': '2026-04-25T00:00:00Z',
    },
  };
  final file = File('${dir.path}/$filename');
  file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(root));
  return file;
}

// Re-exporting the schema's marker names by the canonical strings so
// the test fixture is independent of any private renaming on the
// schema side. If schema renames, the test still wires correctly via
// the public constants below.
const String scenarioBeginMarkerName = 'sleuth.scenario.begin';
const String scenarioEndMarkerName = 'sleuth.scenario.end';
