// heap_growing's two brackets read different legs of one family. The
// audit tells them apart by the axis key on each trace record, so a
// capture of one leg must fail the other leg's bracket, a capture that
// mixes the legs must fail both, and the floor bracket's uniqueness check
// must reject a replayed record.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sleuth/src/detectors/memory_pressure_detector.dart';
import 'package:sleuth/src/validation/detector_metadata.dart';
import 'package:sleuth/src/validation/evidence_tier.dart';
import 'package:sleuth/src/validation/profile_capture_schema.dart';

import '_support/audit_invariants.dart';

const _sampleDir = 'test/validation/captures/memory_pressure';
const _floorDir = 'test/validation/captures/memory_pressure_floor';

void main() {
  final meta = MemoryPressureDetector().validationMetadata;
  final floorSpec = meta.additionalBrackets!.singleWhere(
    (b) => b.observedAxisArgKey == 'observedFloorSlopeBytesPerSec',
  );
  final sampleSpec = BracketSpec(
    stableId: meta.bracketStableId!,
    severityLabel: meta.bracketSeverityLabel!,
    threshold: meta.bracketThreshold!,
    unit: meta.bracketUnit!,
    coveredThresholds: meta.coveredThresholds!,
    profileCapturePaths: meta.profileCapturePaths!,
    atTolerance: meta.bracketAtTolerance,
    aboveCeilingMultiplier: meta.aboveCeilingMultiplier,
    observedAxisArgKey: meta.observedAxisArgKey,
    requireUniqueDetectedAtMicros: meta.bracketRequireUniqueDetectedAtMicros,
  );

  List<String> carryCheck(BracketSpec spec, List<String> paths, String root) =>
      checkCapturesCarryObservedAxisArg(
        label: 'MemoryPressureDetector',
        tier: EvidenceTier.runtimeVerified,
        topLevelStableId: null,
        topLevelSeverityLabel: null,
        topLevelObservedAxisArgKey: null,
        topLevelCapturePaths: null,
        additionalBrackets: [
          BracketSpec(
            stableId: spec.stableId,
            severityLabel: spec.severityLabel,
            threshold: spec.threshold,
            unit: spec.unit,
            coveredThresholds: spec.coveredThresholds,
            profileCapturePaths: paths,
            observedAxisArgKey: spec.observedAxisArgKey,
          ),
        ],
        repoRoot: root,
      );

  List<String> triad(String dir, String stem) => [
    for (final role in ['below', 'at', 'above']) '$dir/$stem$role.json',
  ];

  test('each leg\'s triad passes its own bracket', () {
    for (final (spec, dir, stem) in [
      (sampleSpec, _sampleDir, 'heap_growing_'),
      (floorSpec, _floorDir, 'heap_growing_floor_'),
    ]) {
      final paths = triad(dir, stem);
      expect(
        () => ProfileCaptureSchema.validateBracketSpec(
          spec,
          belowFile: File(paths[0]),
          atFile: File(paths[1]),
          aboveFile: File(paths[2]),
        ),
        returnsNormally,
      );
      expect(carryCheck(spec, paths, Directory.current.path), isEmpty);
    }
  });

  test('a sample-leg capture fails the floor bracket, and a floor-leg '
      'capture fails the sample bracket', () {
    final root = Directory.current.path;
    expect(
      carryCheck(floorSpec, triad(_sampleDir, 'heap_growing_'), root),
      isNotEmpty,
    );
    expect(
      carryCheck(sampleSpec, triad(_floorDir, 'heap_growing_floor_'), root),
      isNotEmpty,
    );
  });

  group('modified captures', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('heap_growing_legs_');
      File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('name: x\n');
      Directory(p.join(root.path, 'c')).createSync();
    });
    tearDown(() => root.deleteSync(recursive: true));

    // The floor at capture with [edit] applied to its trace events.
    String floorAt(
      void Function(List<dynamic> events, Map<String, dynamic> record) edit,
    ) {
      final capture =
          jsonDecode(
                File(
                  '$_floorDir/heap_growing_floor_at.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final events = capture['traceEvents'] as List<dynamic>;
      final record =
          events.firstWhere(
                (e) =>
                    e is Map &&
                    e['name'] == 'sleuth.issue.heap_growing.warning',
              )
              as Map<String, dynamic>;
      edit(events, record);
      return jsonEncode(capture);
    }

    List<String> write(String name, String json) {
      File(p.join(root.path, 'c', name)).writeAsStringSync(json);
      return ['c/$name', 'c/$name', 'c/$name'];
    }

    test('a capture that mixes the legs fails both brackets', () {
      final mixed = floorAt((events, record) {
        final args = Map<String, dynamic>.from(record['args'] as Map)
          ..remove('observedFloorSlopeBytesPerSec')
          ..['observedSlopeBytesPerSec'] = '600000'
          ..['heapGrowingLeg'] = 'sample'
          ..['detectedAtMicros'] = '1';
        events.add({...record, 'ts': (record['ts'] as num) + 1, 'args': args});
      });
      final paths = write('mixed.json', mixed);
      expect(carryCheck(floorSpec, paths, root.path), isNotEmpty);
      expect(carryCheck(sampleSpec, paths, root.path), isNotEmpty);
    });

    test('a replayed floor record fails the floor bracket\'s uniqueness '
        'check', () {
      final replayed = floorAt((events, record) {
        events.add({...record, 'ts': (record['ts'] as num) + 1});
      });
      final file = File(p.join(root.path, 'c', 'heap_growing_floor_at.json'))
        ..writeAsStringSync(replayed);
      expect(
        () => ProfileCaptureSchema.validateBracketSpec(
          floorSpec,
          belowFile: File('$_floorDir/heap_growing_floor_below.json'),
          atFile: file,
          aboveFile: File('$_floorDir/heap_growing_floor_above.json'),
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('detectedAtMicros'),
          ),
        ),
      );
    });
  });
}
