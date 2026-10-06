import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/sleuth.dart' show Sleuth, StartupMetrics;
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/base_detector.dart';
import 'package:sleuth/src/models/frame_stats.dart';
import 'package:sleuth/src/models/heap_sample.dart';
import 'package:sleuth/src/models/performance_issue.dart'
    show IssueCategory, IssueConfidence, IssueSeverity, PerformanceIssue;
import 'package:sleuth/src/models/route_session.dart';
import 'package:sleuth/src/models/snapshot_sections.dart';
import 'package:sleuth/src/network/request_record.dart';
import 'package:sleuth/src/vm/connection_mode.dart';
import 'package:sleuth/src/vm/service_extension_handlers.dart';

import '../helpers/timeline_test_helpers.dart';

const _config = SleuthConfig(
  treeScanInterval: Duration(seconds: 1),
  enabledDetectors: {DetectorType.frameTiming},
);

SleuthController _newController() {
  final c = SleuthController(config: _config);
  addTearDown(c.dispose);
  return c;
}

FrameStats _frame(int frameNumber) => FrameStats(
  frameNumber: frameNumber,
  uiDuration: const Duration(microseconds: 8000),
  rasterDuration: const Duration(microseconds: 4000),
  timestamp: DateTime.now(),
);

void _addFrames(SleuthController c, int count) {
  for (var i = 1; i <= count; i++) {
    c.addFrameForTest(_frame(i));
  }
}

PerformanceIssue _issue({
  String? stableId,
  String? widgetName,
  String? confidenceReason,
}) => PerformanceIssue(
  severity: IssueSeverity.warning,
  category: IssueCategory.paint,
  confidence: IssueConfidence.likely,
  title: 'Issue ${stableId ?? 'without id'}',
  detail: 'detail',
  fixHint: 'fix',
  stableId: stableId,
  widgetName: widgetName,
  confidenceReason: confidenceReason,
);

/// Resolve `doc/mcp_schema.json` independent of test-runner cwd.
/// Walks up from the test file (or `Directory.current`) until it finds
/// a directory containing both `pubspec.yaml` and `doc/mcp_schema.json`.
File _resolveSchemaFile() {
  for (final start in [
    Directory.current,
    File.fromUri(Platform.script).parent,
  ]) {
    var dir = start;
    for (var i = 0; i < 8; i++) {
      final candidate = File('${dir.path}/doc/mcp_schema.json');
      final pubspec = File('${dir.path}/pubspec.yaml');
      if (candidate.existsSync() && pubspec.existsSync()) {
        // Disambiguate sleuth root from sleuth_mcp sub-package: only the
        // sleuth root has `name: sleuth` (sleuth_mcp's pubspec is
        // structurally similar but names a different package).
        final pubspecText = pubspec.readAsStringSync();
        if (pubspecText.contains('name: sleuth\n')) {
          return candidate;
        }
      }
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
  }
  throw StateError(
    'doc/mcp_schema.json not found by walking up from cwd or test file. '
    'Audit must run within the sleuth repo. Check .pubignore exception.',
  );
}

Map<String, Object?> _loadSchema() {
  final file = _resolveSchemaFile();
  return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
}

/// Schema-only metadata keys — never appear in handler envelopes. Audit
/// helpers skip these when comparing documented-vs-actual key sets.
/// Listed explicitly so future production fields can't be accidentally
/// dropped via a broad `startsWith('_')` filter.
const Set<String> _schemaMetaKeys = {
  '_shape_source',
  '_modes',
  '_doc',
  '_opaque_reason',
};

bool _isSchemaMeta(String key) => _schemaMetaKeys.contains(key);

Set<String> _documentedKeys(Map<String, Object?> handlerSchema) {
  final data = handlerSchema['data'];
  if (data is! Map<String, Object?>) return const <String>{};
  return data.keys.where((k) => !_isSchemaMeta(k)).toSet();
}

Set<String> _requiredKeys(Map<String, Object?> handlerSchema) {
  final data = handlerSchema['data'];
  if (data is! Map<String, Object?>) return const <String>{};
  final out = <String>{};
  for (final entry in data.entries) {
    if (_isSchemaMeta(entry.key)) continue;
    final v = entry.value;
    if (v is Map<String, Object?> && v['required'] == true) {
      out.add(entry.key);
    }
  }
  return out;
}

/// Recursive validator for handler payloads and on-device captures.
///
/// Walks a schema shape (field name → field spec) against [payload],
/// which must be a Map:
///
///   * `required: true` keys must be present.
///   * A present value may be null only when its spec says
///     `nullable: true`.
///   * A non-null value must match the spec's `type` (see [_matchesType]),
///     be one of `values` when listed, equal `value` when set, carry
///     exactly the `buckets` keys when listed, and parse as a date when
///     the type is annotated `(ISO-8601)`.
///   * Payload keys the shape does not document are errors.
///
/// It descends through every documented nested container:
///
///   * `shape`            → nested Map, validated the same way.
///   * `item_shape` (Map) → applied to every item of a List.
///   * `value_shape` (Map)→ applied to every value of a Map.
///   * `item_shape` / `value_shape` (String) → a reference, resolved
///                          through [refs] when listed there; otherwise
///                          not descended, and recorded in [skipped]
///                          when the container holds Maps (a list of
///                          scalars is covered by its type check).
///
/// Errors accumulate into [errors] with their full dotted path.
void _validateShape({
  required Map<String, Object?> schemaShape,
  required Object? payload,
  required String path,
  required List<String> errors,
  required Set<String> skipped,
  Map<String, Map<String, Object?>> refs = const {},
}) {
  if (payload is! Map) {
    errors.add('$path: expected Map but got ${payload.runtimeType}');
    return;
  }
  final documented = <String>{};
  for (final entry in schemaShape.entries) {
    final key = entry.key;
    if (_isSchemaMeta(key)) continue;
    final spec = entry.value;
    // Non-map values (`_projection_note`) are prose, not field specs.
    if (spec is! Map<String, Object?>) continue;
    documented.add(key);
    if (!payload.containsKey(key)) {
      if (spec['required'] == true) {
        errors.add('$path.$key missing (documented required)');
      }
      continue;
    }
    _validateValue(
      spec: spec,
      value: payload[key],
      path: '$path.$key',
      errors: errors,
      skipped: skipped,
      refs: refs,
    );
  }
  for (final key in payload.keys) {
    if (!documented.contains(key)) {
      errors.add('$path.$key emitted but not documented');
    }
  }
}

void _validateValue({
  required Map<String, Object?> spec,
  required Object? value,
  required String path,
  required List<String> errors,
  required Set<String> skipped,
  required Map<String, Map<String, Object?>> refs,
}) {
  if (value == null) {
    if (spec['nullable'] != true) {
      errors.add('$path is null (documented non-nullable)');
    }
    return;
  }
  final type = spec['type'];
  if (type is! String) {
    errors.add('$path: schema declares no type');
    return;
  }
  if (!_matchesType(value, type)) {
    errors.add(
      '$path: expected $type but got ${value.runtimeType} '
      '(${_preview(value)})',
    );
    return;
  }
  if (type.contains('(ISO-8601)') &&
      DateTime.tryParse(value as String) == null) {
    errors.add('$path: "$value" is not an ISO-8601 date');
  }
  final values = spec['values'];
  if (values is List && !values.contains(value)) {
    errors.add('$path: "$value" is not one of $values');
  }
  if (spec.containsKey('value') && spec['value'] != value) {
    errors.add('$path: expected ${spec['value']} but got $value');
  }
  final buckets = spec['buckets'];
  if (buckets is List && value is Map) {
    final expected = buckets.cast<String>().toSet();
    final actual = value.keys.cast<String>().toSet();
    if (actual.length != expected.length || !actual.containsAll(expected)) {
      errors.add('$path: keys $actual, documented buckets $expected');
    }
  }
  final nestedShape = spec['shape'];
  if (nestedShape is Map<String, Object?>) {
    _validateShape(
      schemaShape: nestedShape,
      payload: value,
      path: path,
      errors: errors,
      skipped: skipped,
      refs: refs,
    );
  }
  final rawItemShape = spec['item_shape'];
  final itemShape = _resolveShape(rawItemShape, refs);
  if (itemShape != null && value is List) {
    for (var i = 0; i < value.length; i++) {
      _validateShape(
        schemaShape: itemShape,
        payload: value[i],
        path: '$path[$i]',
        errors: errors,
        skipped: skipped,
        refs: refs,
      );
    }
  } else if (rawItemShape is String &&
      value is List &&
      value.any((e) => e is Map)) {
    skipped.add('$path (item_shape="$rawItemShape")');
  }
  final rawValueShape = spec['value_shape'];
  final valueShape = _resolveShape(rawValueShape, refs);
  if (valueShape != null && value is Map) {
    for (final mapEntry in value.entries) {
      _validateShape(
        schemaShape: valueShape,
        payload: mapEntry.value,
        path: '$path[${mapEntry.key}]',
        errors: errors,
        skipped: skipped,
        refs: refs,
      );
    }
  } else if (rawValueShape is String &&
      value is Map &&
      value.values.any((e) => e is Map)) {
    skipped.add('$path (value_shape="$rawValueShape")');
  }
}

Map<String, Object?>? _resolveShape(
  Object? shape,
  Map<String, Map<String, Object?>> refs,
) {
  if (shape is Map<String, Object?>) return shape;
  if (shape is String) return refs[shape];
  return null;
}

String _preview(Object value) {
  final text = '$value';
  return text.length <= 40 ? text : '${text.substring(0, 40)}...';
}

/// Whether [value] (as decoded from JSON) matches a schema type string:
/// `String`, `int`, `num`, `bool`, `Map`, `List`, `Object?`, `List<T>`
/// and `Map<K, V>` (recursively). A trailing annotation such as
/// ` (ISO-8601)` is ignored here. An unknown type throws, so a typo in
/// the schema fails the audit instead of passing silently.
bool _matchesType(Object? value, String type) {
  var t = type.trim();
  final annotation = t.indexOf(' (');
  if (annotation > 0) t = t.substring(0, annotation);
  switch (t) {
    case 'Object?':
      return true;
    case 'String':
      return value is String;
    case 'int':
      return value is int;
    case 'num':
      return value is num;
    case 'bool':
      return value is bool;
    case 'Map':
      return value is Map;
    case 'List':
      return value is List;
  }
  if (t.startsWith('List<') && t.endsWith('>')) {
    final inner = t.substring(5, t.length - 1);
    return value is List && value.every((e) => _matchesType(e, inner));
  }
  if (t.startsWith('Map<') && t.endsWith('>')) {
    final args = _splitTypeArgs(t.substring(4, t.length - 1));
    if (args.length != 2) {
      throw StateError('schema type "$type" is not Map<K, V>');
    }
    return value is Map &&
        value.entries.every(
          (e) => _matchesType(e.key, args[0]) && _matchesType(e.value, args[1]),
        );
  }
  throw StateError('unknown schema type "$type"');
}

/// Splits generic type arguments on top-level commas.
List<String> _splitTypeArgs(String args) {
  final out = <String>[];
  var depth = 0;
  var start = 0;
  for (var i = 0; i < args.length; i++) {
    final c = args[i];
    if (c == '<') depth++;
    if (c == '>') depth--;
    if (c == ',' && depth == 0) {
      out.add(args.substring(start, i).trim());
      start = i + 1;
    }
  }
  out.add(args.substring(start).trim());
  return out;
}

/// The snapshot data shape as it applies to [payload]: when the payload
/// is projected, a section missing from `_projectedSections` is not
/// serialized, so its key is no longer required.
Map<String, Object?> _projectedSnapshotShape(
  Map<String, Object?> shape,
  Map<String, Object?> payload,
) {
  final projected = (payload['_projectedSections'] as List?)
      ?.cast<String>()
      .toSet();
  if (projected == null) return shape;
  final sectionKeys = SnapshotSection.values.map((s) => s.jsonKey).toSet();
  return {
    for (final e in shape.entries)
      e.key:
          sectionKeys.contains(e.key) &&
              !projected.contains(e.key) &&
              e.value is Map<String, Object?>
          ? <String, Object?>{
              ...e.value! as Map<String, Object?>,
              'required': false,
            }
          : e.value,
  };
}

/// The payload as the wire carries it: the extension registry sends
/// `jsonEncode(envelope)`, so validation runs on the decoded form.
Map<String, Object?> _wire(Map<String, Object?> payload) =>
    jsonDecode(jsonEncode(payload)) as Map<String, Object?>;

/// Validates the wire form of [payload] against [schemaShape] and fails
/// with every error. Returns the references that were not resolved.
Set<String> _expectMatchesShape(
  Map<String, Object?> schemaShape,
  Map<String, Object?> payload, {
  required String path,
  Map<String, Map<String, Object?>> refs = const {},
}) {
  final errors = <String>[];
  final skipped = <String>{};
  _validateShape(
    schemaShape: schemaShape,
    payload: _wire(payload),
    path: path,
    errors: errors,
    skipped: skipped,
    refs: refs,
  );
  expect(
    errors,
    isEmpty,
    reason: '$path violates doc/mcp_schema.json:\n  ${errors.join('\n  ')}',
  );
  return skipped;
}

void main() {
  late Map<String, Object?> schema;
  late Map<String, Object?> handlers;

  setUpAll(() {
    schema = _loadSchema();
    handlers = schema['handlers'] as Map<String, Object?>;
  });

  Map<String, Object?> dataShape(String handler) =>
      (handlers[handler] as Map<String, Object?>)['data']
          as Map<String, Object?>;

  Map<String, Object?> explanationShape() =>
      (dataShape('ext.sleuth.explain')['explanation']
              as Map<String, Object?>)['shape']
          as Map<String, Object?>;

  Map<String, Object?> routeSessionShape() =>
      (dataShape('ext.sleuth.snapshot')['routeSessions']
              as Map<String, Object?>)['item_shape']
          as Map<String, Object?>;

  /// String references in the schema, resolved to the shapes they name.
  Map<String, Map<String, Object?>> refs() => {
    'see ext.sleuth.snapshot.data.routeSessions item_shape':
        routeSessionShape(),
    'same as ext.sleuth.explain.data.explanation': explanationShape(),
  };

  group('payload validator', () {
    // Guards against a vacuous validator: every rule must fire.
    test('reports missing, null, mistyped, out-of-set and undocumented '
        'values', () {
      const shape = <String, Object?>{
        'a': {'type': 'String', 'required': true, 'nullable': false},
        'b': {'type': 'int', 'required': true, 'nullable': true},
        'c': {
          'type': 'String',
          'required': false,
          'nullable': false,
          'values': ['x', 'y'],
        },
        'd': {
          'type': 'List<Map>',
          'required': false,
          'nullable': false,
          'item_shape': {
            'e': {'type': 'num', 'required': true, 'nullable': false},
          },
        },
        'f': {
          'type': 'Map<String, int>',
          'required': false,
          'nullable': false,
          'buckets': ['p', 'q'],
        },
      };
      final errors = <String>[];
      _validateShape(
        schemaShape: shape,
        payload: const <String, Object?>{
          'b': null,
          'c': 'z',
          'd': [
            {'e': 'one'},
            {'e': null},
            <String, Object?>{},
          ],
          'f': {'p': 1},
          'g': true,
        },
        path: 'p',
        errors: errors,
        skipped: <String>{},
      );
      expect(errors, [
        'p.a missing (documented required)',
        'p.c: "z" is not one of [x, y]',
        'p.d[0].e: expected num but got String (one)',
        'p.d[1].e is null (documented non-nullable)',
        'p.d[2].e missing (documented required)',
        'p.f: keys {p}, documented buckets {p, q}',
        'p.g emitted but not documented',
      ]);
    });

    test('rejects an unknown schema type', () {
      expect(() => _matchesType(1, 'Integer'), throwsA(isA<StateError>()));
    });
  });

  group('envelope shape', () {
    test('OK envelope keys match documented', () async {
      final c = _newController();
      final env = await extDiagnoseHandler(c, const {});
      final docOk = ((schema['envelope'] as Map)['ok'] as Map<String, Object?>);
      final docKeys = docOk.keys.toSet();
      // Documented keys ⊆ actual; every doc key must appear.
      expect(
        env.keys.toSet().containsAll(docKeys),
        isTrue,
        reason:
            'envelope missing documented keys: '
            '${docKeys.difference(env.keys.toSet())}',
      );
      // schemaVersion locked at the value the doc declares.
      expect(env['schemaVersion'], (docOk['schemaVersion'] as Map)['value']);
    });

    test('connectionMode is one of the documented enum values', () async {
      final c = _newController();
      final env = await extDiagnoseHandler(c, const {});
      final mode = env['connectionMode'] as String;
      final allowed =
          (((schema['envelope'] as Map)['ok'] as Map)['connectionMode']
                  as Map)['values']
              as List;
      expect(allowed, contains(mode));
    });
  });

  group('ext.sleuth.diagnose', () {
    test('data keys match documented (bidirectional)', () async {
      final c = _newController();
      final env = await extDiagnoseHandler(c, const {});
      final actual = (env['data'] as Map<String, Object?>).keys.toSet();
      final documented = _documentedKeys(
        handlers['ext.sleuth.diagnose'] as Map<String, Object?>,
      );
      expect(
        actual,
        equals(documented),
        reason:
            'diagnose data keys drift from schema. '
            'missing: ${documented.difference(actual)}, '
            'undocumented: ${actual.difference(documented)}',
      );
    });

    test('the sidecar tool schema lists the same diagnose keys, types '
        'and nullability', () {
      final toolSchemaFile = File(
        '${_resolveSchemaFile().parent.parent.path}'
        '/packages/sleuth_mcp/doc/mcp_tool_schema.json',
      );
      final toolSchema =
          jsonDecode(toolSchemaFile.readAsStringSync()) as Map<String, Object?>;
      final sidecarData =
          ((toolSchema['tools'] as Map<String, Object?>)['diagnose']
                  as Map<String, Object?>)['data']
              as Map<String, Object?>;
      final appData =
          (handlers['ext.sleuth.diagnose'] as Map<String, Object?>)['data']
              as Map<String, Object?>;
      // Keys the sidecar stamps on top of the passthrough.
      const sidecarStamped = {
        'sidecarVersion',
        'sidecarBuiltAgainstSleuth',
        'launchModeAdvisory',
      };
      final sidecarKeys = sidecarData.keys
          .where((k) => !_schemaMetaKeys.contains(k))
          .toSet()
          .difference(sidecarStamped);
      final appKeys = appData.keys
          .where((k) => !_schemaMetaKeys.contains(k))
          .toSet();
      expect(
        sidecarKeys,
        equals(appKeys),
        reason:
            'packages/sleuth_mcp/doc/mcp_tool_schema.json diagnose keys '
            'drift from doc/mcp_schema.json. '
            'missing in sidecar: ${appKeys.difference(sidecarKeys)}, '
            'extra in sidecar: ${sidecarKeys.difference(appKeys)}',
      );
      for (final key in appKeys) {
        final app = appData[key] as Map<String, Object?>;
        final sidecar = sidecarData[key] as Map<String, Object?>;
        expect(
          (sidecar['type'], sidecar['nullable']),
          (app['type'], app['nullable']),
          reason: key,
        );
      }
    });

    test('data values match documented types and nullability', () async {
      final c = _newController();
      final env = await extDiagnoseHandler(c, const {});
      _expectMatchesShape(
        dataShape('ext.sleuth.diagnose'),
        env['data'] as Map<String, Object?>,
        path: 'diagnose.data',
      );
    });

    test('packageVersion matches handler-stamped const', () async {
      final c = _newController();
      final env = await extDiagnoseHandler(c, const {});
      final data = env['data'] as Map<String, Object?>;
      expect(data['packageVersion'], kSleuthPackageVersion);
      expect(data['packageVersion'], isA<String>());
      expect(data['vmConnected'], isA<bool>());
      expect(data['captureMode'], isA<bool>());
      expect(data['unboundExtensionNames'], isA<List>());
    });
  });

  group('ext.sleuth.snapshot', () {
    test(
      'documented required-data-keys ⊆ actual on empty controller',
      () async {
        // SessionSnapshot.toJson emits every `required: true` key
        // unconditionally; optional/conditional keys (suppressedCount,
        // startupMetrics, recurrenceTrends, …) are exercised below. Verify
        // that the contract's required set is present after a fresh
        // controller produces a snapshot from default state.
        final c = _newController();
        final env = await extSnapshotHandler(c, const {});
        final actual = (env['data'] as Map<String, Object?>).keys.toSet();
        final required = _requiredKeys(
          handlers['ext.sleuth.snapshot'] as Map<String, Object?>,
        );
        expect(
          actual.containsAll(required),
          isTrue,
          reason:
              'snapshot missing required keys: '
              '${required.difference(actual)}',
        );
        // Conditional keys must NOT leak when their preconditions are unmet.
        expect(
          actual.contains('suppressedCount'),
          isFalse,
          reason: 'suppressedCount must only emit when > 0',
        );
        expect(
          actual.contains('startupMetrics'),
          isFalse,
          reason: 'startupMetrics must only emit when Sleuth.init ran',
        );
        // No ranked issue, no frame, no heap sample: nothing to summarise.
        expect(actual.contains('sessionSummary'), isFalse);
        _expectMatchesShape(
          dataShape('ext.sleuth.snapshot'),
          env['data'] as Map<String, Object?>,
          path: 'snapshot.data',
        );
      },
    );

    test(
      'suppressedCount + startupMetrics emit when their preconditions fire',
      () async {
        final c = _newController();
        c.suppressedCountNotifier.value = 1;
        addTearDown(Sleuth.resetStartupForTest);
        Sleuth.setStartupMetricsForTest(
          StartupMetrics(dartEntryTimestamp: DateTime.now(), ttffMs: 100.0),
        );
        final env = await extSnapshotHandler(c, const {});
        final actual = (env['data'] as Map<String, Object?>).keys.toSet();
        expect(
          actual,
          contains('suppressedCount'),
          reason: 'suppressedCount missing once notifier > 0',
        );
        expect(
          actual,
          contains('startupMetrics'),
          reason: 'startupMetrics missing once Sleuth.init captured it',
        );
        // Documented keys must be a superset of every key the handler emits —
        // any drift here surfaces undocumented runtime fields the schema lock
        // is meant to catch.
        final documented = _documentedKeys(
          handlers['ext.sleuth.snapshot'] as Map<String, Object?>,
        );
        expect(
          documented.containsAll(actual),
          isTrue,
          reason:
              'undocumented snapshot keys: ${actual.difference(documented)}',
        );
      },
    );

    test('recentRequests emits once the network buffer is non-empty', () async {
      // Precondition triad (see exportSnapshot): _initialized AND
      // _networkMonitor.isEnabled AND records.isNotEmpty. Drive each.
      final c = _newController()
        ..initializeDetectorsForTest()
        ..markInitializedForTest();
      c.networkMonitorForTest.isEnabled = true;
      c.networkMonitorForTest.processRecord(
        RequestRecord(
          url: 'https://example.test/api',
          method: 'GET',
          statusCode: 200,
          durationMs: 80,
          responseBytes: 256,
          startedAt: DateTime.now(),
        ),
      );
      final env = await extSnapshotHandler(c, const {});
      final actual = (env['data'] as Map<String, Object?>).keys.toSet();
      expect(
        actual,
        contains('recentRequests'),
        reason: 'recentRequests missing once a record is in the ring buffer',
      );
    });

    test('heapSamples emits once a sample has been fed', () async {
      // Precondition: _initialized AND _memoryPressure.heapSamples.isNotEmpty.
      // MemoryPressureDetector needs to be in `enabledDetectors` for
      // `processHeapSample` to push samples into the buffer.
      final c =
          SleuthController(
              config: const SleuthConfig(
                treeScanInterval: Duration(seconds: 1),
                enabledDetectors: {
                  DetectorType.frameTiming,
                  DetectorType.memoryPressure,
                },
              ),
            )
            ..initializeDetectorsForTest()
            ..markInitializedForTest();
      addTearDown(c.dispose);
      c.feedHeapSampleForTest(
        HeapSample(
          heapUsage: 10 * 1024 * 1024,
          heapCapacity: 20 * 1024 * 1024,
          externalUsage: 0,
          timestamp: DateTime.now(),
        ),
      );
      final env = await extSnapshotHandler(c, const {});
      final actual = (env['data'] as Map<String, Object?>).keys.toSet();
      expect(
        actual,
        contains('heapSamples'),
        reason: 'heapSamples missing once the detector buffer is non-empty',
      );
    });

    test('phaseEvents emits from timeline-data feed', () async {
      final c = _newController()..initializeDetectorsForTest();
      c.feedTimelineDataForTest(
        enrichedBuildData(buildDurationUs: 10000, dirtyCount: 3),
      );
      final env = await extSnapshotHandler(c, const {});
      final actual = (env['data'] as Map<String, Object?>).keys.toSet();
      expect(actual, contains('phaseEvents'));
    });

    test('gcEvents emits from timeline-data feed', () async {
      final c = _newController()..initializeDetectorsForTest();
      c.feedTimelineDataForTest(gcHeavyData(gcCount: 3));
      final env = await extSnapshotHandler(c, const {});
      final actual = (env['data'] as Map<String, Object?>).keys.toSet();
      expect(actual, contains('gcEvents'));
    });

    test('platformChannelEvents emits from timeline-data feed', () async {
      final c = _newController()..initializeDetectorsForTest();
      c.feedTimelineDataForTest(platformChannelData(channelEventCount: 2));
      final env = await extSnapshotHandler(c, const {});
      final actual = (env['data'] as Map<String, Object?>).keys.toSet();
      expect(actual, contains('platformChannelEvents'));
    });

    test('recentFrames + sessionSummary emit once frames are recorded; a '
        'session without ranked issues summarises frames only', () async {
      // recentFrames fires on `frames.isNotEmpty`; sessionSummary fires
      // when the summary builder produces at least one field. Frames
      // alone supply only the histogram: topIssues and detectorHitRates
      // need a ranked issue.
      final c = _newController()..initializeDetectorsForTest();
      _addFrames(c, 3);
      final env = await extSnapshotHandler(c, const {});
      final data = env['data'] as Map<String, Object?>;
      expect(data.keys, contains('recentFrames'));
      expect(
        data.keys,
        contains('sessionSummary'),
        reason:
            'sessionSummary should populate once frames feed the '
            'histogram builder',
      );
      final summary = data['sessionSummary'] as Map<String, Object?>;
      expect(summary.keys.toSet(), {'frameHistogram'});
      _expectMatchesShape(
        dataShape('ext.sleuth.snapshot'),
        data,
        path: 'snapshot.data',
      );
    });

    test('populated sessionSummary carries every key and the whole payload '
        'validates recursively', () async {
      final c =
          SleuthController(
              config: const SleuthConfig(
                treeScanInterval: Duration(seconds: 1),
                enabledDetectors: {
                  DetectorType.frameTiming,
                  DetectorType.memoryPressure,
                },
              ),
            )
            ..initializeDetectorsForTest()
            ..markInitializedForTest();
      addTearDown(c.dispose);
      _addFrames(c, 3);
      final start = DateTime.now();
      for (var i = 0; i < 2; i++) {
        c.feedHeapSampleForTest(
          HeapSample(
            heapUsage: (10 + i) * 1024 * 1024,
            heapCapacity: 20 * 1024 * 1024,
            externalUsage: 0,
            timestamp: start.add(Duration(seconds: i)),
          ),
        );
      }
      // A cause/effect pair (one causal edge), an issue that names a
      // widget and carries no confidence reason, and one without a
      // stableId.
      c.seedIssuesForTest([
        _issue(
          stableId: 'missing_repaint_boundary',
          confidenceReason: 'structural and runtime evidence',
        ),
        _issue(
          stableId: 'excessive_repaint',
          confidenceReason: 'VM paint share',
        ),
        _issue(stableId: 'non_lazy_listview', widgetName: 'ListView'),
        _issue(),
      ]);
      c.recordRecurrenceForTest('jank_detected', IssueSeverity.warning, 3);
      final route =
          RouteSession(
              routeName: 'home',
              startedAt: start,
              scaffoldHashKey: 7,
              tabVisitIndex: 2,
              hotReloadGeneration: 1,
            )
            ..endedAt = start.add(const Duration(seconds: 2))
            ..rebuildCountsByType['Row'] = 4
            ..issueSnapshots['jank_detected'] = _issue(
              stableId: 'jank_detected',
            );
      for (var i = 1; i <= 2; i++) {
        route.frameStats.add(_frame(i));
      }
      c.seedRouteHistoryForTest([route]);

      final env = await extSnapshotHandler(c, const {});
      final data = env['data'] as Map<String, Object?>;
      final summary = data['sessionSummary'] as Map<String, Object?>;
      expect(summary.keys.toSet(), {
        'topIssues',
        'frameHistogram',
        'detectorHitRates',
        'memoryTrendSummary',
        'causalEdges',
      });
      final top = (summary['topIssues'] as List).cast<Map<String, Object?>>();
      expect(top, hasLength(4));
      expect(top.where((i) => i['stableId'] == null), hasLength(1));
      expect(top.where((i) => i['widgetName'] == 'ListView'), hasLength(1));
      expect(
        top.where((i) => !i.containsKey('confidenceReason')),
        hasLength(2),
      );
      final route0 =
          (data['routeSessions'] as List).single as Map<String, Object?>;
      expect(
        route0.keys,
        containsAll(<String>[
          'endedAt',
          'hotReloadGeneration',
          'rebuildCountsByType',
          'totalRebuilds',
        ]),
      );
      expect(
        (route0['frameStats'] as Map<String, Object?>).keys,
        containsAll(<String>['p50', 'p95', 'p99']),
      );
      final skipped = _expectMatchesShape(
        dataShape('ext.sleuth.snapshot'),
        data,
        path: 'snapshot.data',
      );
      expect(skipped, isEmpty);
    });

    test(
      'recurrenceTrends emits + nested shape matches documented required',
      () async {
        // Drive the recurrence trend through the visibleForTesting seam so
        // the bucket fills without running the real scan loop. Required
        // keys per the documented value_shape:
        //   trend / totalOccurrences / totalObserved / lastSeenCycle
        // (severityStats is optional — present when ≥ 1 present obs).
        final c = _newController();
        c.recordRecurrenceForTest('jank_detected', IssueSeverity.warning, 6);
        final env = await extSnapshotHandler(c, const {});
        final data = env['data'] as Map<String, Object?>;
        expect(data.keys, contains('recurrenceTrends'));
        final trends = data['recurrenceTrends'] as Map<String, Object?>;
        final jank = trends['jank_detected'] as Map<String, Object?>;
        const requiredNested = <String>{
          'trend',
          'totalOccurrences',
          'totalObserved',
          'lastSeenCycle',
        };
        expect(
          jank.keys.toSet(),
          containsAll(requiredNested),
          reason:
              'recurrenceTrends nested shape missing documented '
              'required keys: ${requiredNested.difference(jank.keys.toSet())}',
        );
        // Driven by 6 successive presents -> totalOccurrences == 6.
        expect(jank['totalOccurrences'], 6);
        expect(jank['lastSeenCycle'], 6);
      },
    );

    test(
      'routeSessions emits + item shape matches documented required',
      () async {
        // Drive `_routeHistory` via the visibleForTesting seam so the
        // export path emits a populated `routeSessions` list. The seam
        // also republishes through `routeHistoryNotifier` for downstream
        // listeners, matching the production write order.
        final c = _newController();
        final session = RouteSession(
          routeName: 'home',
          startedAt: DateTime.now(),
          scaffoldHashKey: 12345,
        );
        c.seedRouteHistoryForTest([session]);
        final env = await extSnapshotHandler(c, const {});
        final data = env['data'] as Map<String, Object?>;
        expect(data.keys, contains('routeSessions'));
        final routes = data['routeSessions'] as List;
        expect(routes, isNotEmpty);
        final first = routes.first as Map<String, Object?>;
        // Required item-shape keys per mcp_schema.json routeSessions.item_shape.
        // scaffoldHashKey + p-percentiles are conditional (see schema); not
        // included here.
        const requiredItemKeys = <String>{
          'routeName',
          'tabVisitIndex',
          'startedAt',
          'healthScore',
          'durationSeconds',
          'scanCycles',
          'frameStats',
          'issueCount',
          'criticalCount',
          'warningCount',
          'issues',
        };
        expect(
          first.keys.toSet(),
          containsAll(requiredItemKeys),
          reason:
              'routeSessions item missing documented required keys: '
              '${requiredItemKeys.difference(first.keys.toSet())}',
        );
        // Optional scaffoldHashKey emits when non-null — verify the seam
        // surfaces it.
        expect(first['scaffoldHashKey'], 12345);
        // frameStats sub-shape required keys (p50/p95/p99 are conditional).
        final frameStats = first['frameStats'] as Map<String, Object?>;
        const requiredFrameStatsKeys = <String>{
          'totalFrames',
          'jankFrames',
          'averageFps',
        };
        expect(
          frameStats.keys.toSet(),
          containsAll(requiredFrameStatsKeys),
          reason:
              'frameStats sub-shape missing documented required keys: '
              '${requiredFrameStatsKeys.difference(frameStats.keys.toSet())}',
        );
      },
    );

    // widgetHeatMap remains seam-deferred — see `auditUnreachable` below.
    // Present in 5 of 6 device captures
    // (`snapshot_repaint`, `_heavy_compute`, `_recurrence`, `_routes`,
    // `_memory`); absent from `snapshot_idle`. Structurally documented
    // as opaque List<Map>, but seam-driving the underlying aggregated
    // PerformanceIssue list was deliberately out of scope for v0.34.0.

    /// Conditional fields the audit deliberately does not drive from the
    /// handler seam. Each entry must have a rationale + a pointer to the
    /// model-level coverage that does exercise it.
    const auditUnreachable = <String, String>{
      'widgetHeatMap':
          'Conditional on aggregated PerformanceIssue list with widget '
          'attribution. Present in 5 of 6 device captures '
          '(snapshot_repaint, _heavy_compute, _recurrence, _routes, _memory); '
          'structurally documented but seam-driving deferred. Covered in '
          'test/controller/export_snapshot_test.dart.',
    };

    test('projection args emit _projectedSections/_projectionLimits/'
        '_projectionApplied; no-arg call omits them', () async {
      final c = _newController();
      final session = RouteSession(
        routeName: 'home',
        startedAt: DateTime.now(),
        scaffoldHashKey: 12345,
      );
      c.seedRouteHistoryForTest([session]);

      // No-arg: metadata absent (backward-compat).
      final full =
          (await extSnapshotHandler(c, const {}))['data']
              as Map<String, Object?>;
      expect(full.containsKey('_projectedSections'), isFalse);
      expect(full.containsKey('_projectionApplied'), isFalse);

      // Projected: currentIssues-only with caps.
      final projected =
          (await extSnapshotHandler(c, const {
                'sections': 'currentIssues,routeSessions',
                'maxIssueCount': '5',
                'maxRouteCount': '3',
              }))['data']
              as Map<String, Object?>;
      expect(
        projected['_projectedSections'],
        equals(['currentIssues', 'routeSessions']),
      );
      expect(projected['_projectionApplied'], 'by_app');
      final limits = projected['_projectionLimits'] as Map<String, Object?>;
      expect(limits['maxIssueCount'], 5);
      expect(limits['maxRouteCount'], 3);
      // Omitted section absent.
      expect(projected.containsKey('frameStatsSummary'), isFalse);
      _expectMatchesShape(
        _projectedSnapshotShape(dataShape('ext.sleuth.snapshot'), projected),
        projected,
        path: 'snapshot.data(projected)',
      );

      // Typed errors.
      final badSection = await extSnapshotHandler(c, const {
        'sections': 'bogus',
      });
      expect(badSection['error'], startsWith('arg_invalid_section:'));
      final badInt = await extSnapshotHandler(c, const {
        'sections': 'currentIssues',
        'maxIssueCount': 'NaN',
      });
      expect(badInt['error'], startsWith('arg_invalid_int:'));
      final unused = await extSnapshotHandler(c, const {
        'sections': 'currentIssues',
        'maxRouteCount': '2',
      });
      expect(unused['error'], startsWith('arg_pagination_unused:'));
    });

    test('every optional schema key is exercised or explicitly deferred', () {
      // Bidirectional drift guard. Every documented optional key must
      // either get a test above (presence-driven) or sit in
      // `auditUnreachable` with a stated rationale. If a new optional
      // field lands without coverage AND without rationale, this fails.
      final snapshotHandler =
          handlers['ext.sleuth.snapshot'] as Map<String, Object?>;
      final data = snapshotHandler['data'] as Map<String, Object?>;
      final optionalKeys = <String>{
        for (final entry in data.entries)
          if (!_isSchemaMeta(entry.key) &&
              entry.value is Map<String, Object?> &&
              (entry.value as Map<String, Object?>)['required'] != true)
            entry.key,
      };
      // Keys explicitly exercised in this group (presence tests above):
      const exercisedHere = <String>{
        'suppressedCount',
        'startupMetrics',
        'recentRequests',
        'heapSamples',
        'phaseEvents',
        'gcEvents',
        'platformChannelEvents',
        'recentFrames',
        'sessionSummary',
        'recurrenceTrends',
        'routeSessions',
        '_projectedSections',
        '_projectionLimits',
        '_projectionApplied',
      };
      final covered = {...exercisedHere, ...auditUnreachable.keys};
      final uncovered = optionalKeys.difference(covered);
      expect(
        uncovered,
        isEmpty,
        reason:
            'optional snapshot keys without presence coverage or '
            'an `auditUnreachable` rationale: $uncovered',
      );
    });

    test('checkSnapshotCapturesMatchSchema — every on-device capture '
        'matches the documented snapshot shape (top-level + nested)', () {
      // Cross-check on-device captures against the documented shape.
      // Captures live in
      // test/validation/captures/mcp_snapshots/snapshot_*.json
      // (real iPhone iOS 17.5; see doc/mcp_schema_derivation.md). Each
      // capture is the raw ext.sleuth.snapshot.data payload — required
      // keys must appear in every file at every documented depth, every
      // value must match its documented type and nullability, and no
      // file may carry an undocumented key.
      //
      // The validator descends through `shape` (object), `item_shape`
      // (Map → applied to each list item), and `value_shape` (Map →
      // applied to each map value). String values for `item_shape` /
      // `value_shape` are references — unresolved ones are recorded as
      // `skipped` entries so the audit isn't silently incomplete.
      final schemaFile = _resolveSchemaFile();
      final repoRoot = schemaFile.parent.parent;
      final capturesDir = Directory(
        '${repoRoot.path}/test/validation/captures/mcp_snapshots',
      );
      expect(
        capturesDir.existsSync(),
        isTrue,
        reason:
            'mcp_snapshots/ directory missing — schema cross-check '
            'disabled. Re-record via the procedure in '
            'doc/mcp_schema_derivation.md.',
      );
      final snapshotSchema =
          handlers['ext.sleuth.snapshot'] as Map<String, Object?>;
      final snapshotDataSchema = snapshotSchema['data'] as Map<String, Object?>;
      final captureFiles =
          capturesDir
              .listSync()
              .whereType<File>()
              .where(
                (f) =>
                    f.path.endsWith('.json') &&
                    f.uri.pathSegments.last.startsWith('snapshot_'),
              )
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      expect(
        captureFiles,
        isNotEmpty,
        reason: 'no snapshot_*.json captures found — cross-check vacuous',
      );
      final errors = <String>[];
      final skipped = <String>{};
      for (final file in captureFiles) {
        final name = file.uri.pathSegments.last;
        final payload =
            jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
        _validateShape(
          schemaShape: snapshotDataSchema,
          payload: payload,
          path: name,
          errors: errors,
          skipped: skipped,
          refs: refs(),
        );
      }
      expect(
        errors,
        isEmpty,
        reason:
            'snapshot captures violate the documented snapshot '
            'shape:\n  ${errors.join("\n  ")}',
      );
      // Surface the opaque-ref skips so they remain visible — they are
      // the residual coverage gap until the schema DSL is normalised.
      if (skipped.isNotEmpty) {
        // ignore: avoid_print
        print(
          'checkSnapshotCapturesMatchSchema — opaque item_shape/value_shape '
          'references skipped (recursive enforcement deferred):\n  '
          '${skipped.join("\n  ")}',
        );
      }
    });
  });

  group('ext.sleuth.issues', () {
    test('data keys match documented when route arg absent', () async {
      final c = _newController();
      final env = await extIssuesHandler(c, const {});
      final actual = (env['data'] as Map<String, Object?>).keys.toSet();
      // `route` is optional — absent here. Required key is `issues`.
      expect(actual, contains('issues'));
      expect(actual, isNot(contains('route')));
      final required = _requiredKeys(
        handlers['ext.sleuth.issues'] as Map<String, Object?>,
      );
      expect(actual.containsAll(required), isTrue);
    });

    test('data includes route when route arg passed', () async {
      final c = _newController();
      final env = await extIssuesHandler(c, const {'route': '/home'});
      final actual = (env['data'] as Map<String, Object?>).keys.toSet();
      expect(actual, containsAll(<String>['issues', 'route']));
    });

    test('data values match documented types and nullability', () async {
      final c = _newController()..seedIssuesForTest([_issue()]);
      for (final args in const [
        <String, String>{},
        <String, String>{'route': '/home'},
      ]) {
        final env = await extIssuesHandler(c, args);
        _expectMatchesShape(
          dataShape('ext.sleuth.issues'),
          env['data'] as Map<String, Object?>,
          path: 'issues.data$args',
        );
      }
    });
  });

  group('ext.sleuth.routeHealth', () {
    test('absent route → data has `routes` key holding a list', () async {
      final c = _newController();
      final env = await extRouteHealthHandler(c, const {});
      final data = env['data'] as Map<String, Object?>;
      expect(data.keys, contains('routes'));
      expect(data['routes'], isA<List>());
      expect(
        data.containsKey('route'),
        isFalse,
        reason: 'absent-route shape must not include singular `route` key',
      );
    });

    test(
      'matching route → data has single `route` key wrapping the session',
      () async {
        final c = _newController();
        // Seed history directly through the public ValueNotifier — exercises
        // the same read path extRouteHealthHandler consumes.
        final session = RouteSession(
          routeName: 'home',
          startedAt: DateTime.now(),
        );
        c.routeHistoryNotifier.value = <RouteSession>[session];
        final env = await extRouteHealthHandler(c, const {'route': 'home'});
        final data = env['data'] as Map<String, Object?>;
        expect(
          data.keys,
          contains('route'),
          reason:
              'matching-route shape must wrap the single session under '
              '`route` (was previously emitted inline — polymorphism collapsed)',
        );
        expect(data['route'], isA<Map<String, Object?>>());
        final routeMap = data['route'] as Map<String, Object?>;
        expect(routeMap['routeName'], 'home');
        expect(
          data.containsKey('routes'),
          isFalse,
          reason: 'matching-route shape must not include the plural list key',
        );
      },
    );

    test('both shapes validate against the routeSessions item shape', () async {
      final c = _newController();
      c.seedRouteHistoryForTest([
        RouteSession(
          routeName: 'home',
          startedAt: DateTime.now(),
          scaffoldHashKey: 1,
        ),
      ]);
      final all = await extRouteHealthHandler(c, const {});
      final skipped = _expectMatchesShape(
        dataShape('ext.sleuth.routeHealth'),
        all['data'] as Map<String, Object?>,
        path: 'routeHealth.data',
        refs: refs(),
      );
      expect(skipped, isEmpty);
      // `route` holds one session (its `value_shape` names the session
      // shape itself, not the shape of each map value).
      final one = await extRouteHealthHandler(c, const {'route': 'home'});
      _expectMatchesShape(
        routeSessionShape(),
        (one['data'] as Map<String, Object?>)['route'] as Map<String, Object?>,
        path: 'routeHealth.data.route',
      );
    });

    test('no-match route → error envelope echoes the route arg', () async {
      final c = _newController();
      final env = await extRouteHealthHandler(c, const {'route': 'ghost'});
      expect(env['error'], 'unknown_route');
      expect(
        env['route'],
        'ghost',
        reason: 'error envelope must echo the unknown route',
      );
      expect(
        env.containsKey('data'),
        isFalse,
        reason: 'error envelope must not carry a `data` block',
      );
    });
  });

  group('ext.sleuth.encyclopedia', () {
    test('data keys + types match documented', () async {
      final c = _newController();
      final env = await extEncyclopediaHandler(c, const {});
      final actual = (env['data'] as Map<String, Object?>).keys.toSet();
      final documented = _documentedKeys(
        handlers['ext.sleuth.encyclopedia'] as Map<String, Object?>,
      );
      expect(actual, equals(documented));
      final data = env['data'] as Map<String, Object?>;
      expect(data['count'], isA<int>());
      expect(data['entries'], isA<Map<String, Object?>>());
    });

    test('every entry matches the explanation shape value by value', () async {
      // Keys, types and nullability of every field of every entry, so a
      // null the schema calls non-nullable (or a new key) fails here.
      final c = _newController();
      final env = await extEncyclopediaHandler(c, const {});
      final data = env['data'] as Map<String, Object?>;
      final skipped = _expectMatchesShape(
        dataShape('ext.sleuth.encyclopedia'),
        data,
        path: 'encyclopedia.data',
        refs: refs(),
      );
      expect(skipped, isEmpty);
      final entries = data['entries'] as Map<String, Object?>;
      expect(entries, isNotEmpty);
      expect(data['count'], entries.length);
      // Entries without ignore guidance exist; the schema must allow them.
      expect(
        entries.values.where(
          (e) => (e! as Map<String, Object?>)['whenToIgnore'] == null,
        ),
        isNotEmpty,
      );
    });
  });

  group('ext.sleuth.causalGraph', () {
    test('data keys + types match documented', () async {
      final c = _newController();
      final env = await extCausalGraphHandler(c, const {});
      final actual = (env['data'] as Map<String, Object?>).keys.toSet();
      final documented = _documentedKeys(
        handlers['ext.sleuth.causalGraph'] as Map<String, Object?>,
      );
      expect(actual, equals(documented));
      final data = env['data'] as Map<String, Object?>;
      expect(data['count'], isA<int>());
      expect(data['rules'], isA<List>());
    });

    test('rule items carry trigger + effect strings', () async {
      final c = _newController();
      final env = await extCausalGraphHandler(c, const {});
      final rules = (env['data'] as Map<String, Object?>)['rules'] as List;
      for (final r in rules.take(3)) {
        final m = r as Map<String, Object?>;
        expect(m.keys.toSet(), containsAll(<String>['trigger', 'effect']));
        expect(m['trigger'], isA<String>());
        expect(m['effect'], isA<String>());
      }
    });

    test('data values match documented types and nullability', () async {
      final c = _newController();
      final env = await extCausalGraphHandler(c, const {});
      _expectMatchesShape(
        dataShape('ext.sleuth.causalGraph'),
        env['data'] as Map<String, Object?>,
        path: 'causalGraph.data',
      );
    });
  });

  group('ext.sleuth.explain', () {
    test('error envelope shape for missing stableId', () async {
      final c = _newController();
      final env = await extExplainHandler(c, const {});
      final errorEnvKeys = env.keys.toSet();
      expect(
        errorEnvKeys,
        containsAll(<String>[
          'connectionMode',
          'schemaVersion',
          'sessionUuid',
          'error',
        ]),
      );
      expect(env['error'], 'missing_required_arg');
    });

    test('error envelope shape for unknown stableId', () async {
      final c = _newController();
      final env = await extExplainHandler(c, const {'stableId': 'no_such_id'});
      expect(env['error'], 'unknown_stable_id');
      // `stableId` + `canonical` are extra fields documented for this error.
      expect(env.keys, containsAll(<String>['stableId', 'canonical']));
    });

    test('OK envelope data keys match documented', () async {
      final c = _newController();
      final env = await extExplainHandler(c, const {
        'stableId': 'jank_detected',
      });
      // Some explanations may not exist in default config; if so, skip.
      if (env.containsKey('error')) {
        markTestSkipped('jank_detected unavailable in test config');
        return;
      }
      final actual = (env['data'] as Map<String, Object?>).keys.toSet();
      final documented = _documentedKeys(
        handlers['ext.sleuth.explain'] as Map<String, Object?>,
      );
      expect(actual, equals(documented));
    });

    test('data values match documented types and nullability', () async {
      final c = _newController()
        ..seedIssuesForTest([
          _issue(stableId: 'non_lazy_listview', widgetName: 'ListView'),
        ]);
      // Neutral wording, a live match, and an entry whose whenToIgnore is
      // null.
      for (final id in const [
        'jank_detected',
        'non_lazy_listview',
        'heavy_compute',
        'excessive_keep_alive:PageView~k-home',
      ]) {
        final env = await extExplainHandler(c, {'stableId': id});
        _expectMatchesShape(
          dataShape('ext.sleuth.explain'),
          env['data'] as Map<String, Object?>,
          path: 'explain($id).data',
        );
      }
      final heavy = await extExplainHandler(c, const {
        'stableId': 'heavy_compute',
      });
      final explanation =
          (heavy['data'] as Map<String, Object?>)['explanation']
              as Map<String, Object?>;
      expect(explanation.containsKey('whenToIgnore'), isTrue);
      expect(explanation['whenToIgnore'], isNull);
    });
  });

  group('schemaVersion contract', () {
    test('handler envelope schemaVersion matches doc-declared value', () {
      final docVersion =
          (((schema['envelope'] as Map)['ok'] as Map)['schemaVersion']
              as Map)['value'];
      expect(
        kMcpEnvelopeSchemaVersion,
        equals(docVersion),
        reason: 'kMcpEnvelopeSchemaVersion drifted from documented value',
      );
    });

    test('documented enum values match the Dart enums (reflective)', () {
      final topIssue =
          ((dataShape('ext.sleuth.snapshot')['sessionSummary']
                      as Map<String, Object?>)['shape']
                  as Map<String, Object?>)['topIssues']
              as Map<String, Object?>;
      final item = topIssue['item_shape'] as Map<String, Object?>;
      List<Object?> valuesOf(Map<String, Object?> shape, String key) =>
          (shape[key] as Map<String, Object?>)['values'] as List<Object?>;
      expect(
        valuesOf(item, 'severity').toSet(),
        IssueSeverity.values.map((v) => v.name).toSet(),
      );
      expect(
        valuesOf(item, 'confidence').toSet(),
        IssueConfidence.values.map((v) => v.name).toSet(),
      );
      expect(
        valuesOf(explanationShape(), 'category').toSet(),
        IssueCategory.values.map((v) => v.name).toSet(),
      );
    });

    test('ConnectionMode enum values match schema enum list (reflective)', () {
      // Drives mode-coverage statically: even if no test exercises a given
      // mode at runtime, this reflective check catches drift between the
      // enum and the doc.
      final actual = ConnectionMode.values.map((m) => m.name).toSet();
      final documented =
          (((schema['envelope'] as Map)['ok'] as Map)['connectionMode']
                  as Map)['values']
              as List;
      expect(
        actual,
        equals(documented.cast<String>().toSet()),
        reason: 'ConnectionMode enum drift: enum=$actual doc=$documented',
      );
    });
  });

  group('mirrored doc parity', () {
    test('doc/mcp_schema.json byte-equal across sleuth + sleuth_mcp copies', () {
      final repoSchema = _resolveSchemaFile();
      final mirrored = File(
        '${repoSchema.parent.parent.path}/packages/sleuth_mcp/doc/mcp_schema.json',
      );
      expect(
        mirrored.existsSync(),
        isTrue,
        reason: 'sidecar mirror missing — pub archive will ship without it',
      );
      expect(
        mirrored.readAsBytesSync(),
        equals(repoSchema.readAsBytesSync()),
        reason: 'mirror drift: re-copy doc/ into packages/sleuth_mcp/doc/',
      );
    });

    test('doc/mcp_schema.md byte-equal across sleuth + sleuth_mcp copies', () {
      final repoSchema = _resolveSchemaFile();
      final repoMd = File('${repoSchema.parent.path}/mcp_schema.md');
      final mirrored = File(
        '${repoSchema.parent.parent.path}/packages/sleuth_mcp/doc/mcp_schema.md',
      );
      expect(repoMd.existsSync(), isTrue);
      expect(
        mirrored.existsSync(),
        isTrue,
        reason: 'sidecar mirror missing — pub archive will ship without it',
      );
      expect(
        mirrored.readAsBytesSync(),
        equals(repoMd.readAsBytesSync()),
        reason: 'mirror drift: re-copy doc/ into packages/sleuth_mcp/doc/',
      );
    });

    test(
      'snapshot conditional-field presence text in MD matches JSON predicates',
      () {
        // Audit guard against MD drift: every `presence` predicate the JSON
        // declares for an optional snapshot field MUST appear verbatim in
        // the markdown render, so the two documents cannot describe the
        // same field with different semantics. The audit checks the
        // canonical JSON only — the mirror parity test above guarantees
        // the sidecar copy stays in lock-step.
        final repoSchema = _resolveSchemaFile();
        final repoMd = File(
          '${repoSchema.parent.path}/mcp_schema.md',
        ).readAsStringSync();
        final snapshotData =
            ((handlers['ext.sleuth.snapshot'] as Map<String, Object?>)['data']
                as Map<String, Object?>);
        // Field set the MD-vs-JSON predicate audit covers. Required
        // fields are excluded — their presence is "always" with no
        // predicate text. New optional fields land in this set so the
        // drift guard keeps a bidirectional anchor.
        const auditedOptionalFields = <String>{
          'suppressedCount',
          'recentRequests',
          'heapSamples',
          'phaseEvents',
          'gcEvents',
          'platformChannelEvents',
          'recentFrames',
          'widgetHeatMap',
        };
        for (final field in auditedOptionalFields) {
          final spec = snapshotData[field];
          expect(
            spec,
            isA<Map<String, Object?>>(),
            reason: 'audited field $field absent from JSON',
          );
          final presence =
              (spec as Map<String, Object?>)['presence'] as String?;
          expect(
            presence,
            isNotNull,
            reason: '$field must declare a presence predicate in JSON',
          );
          expect(
            repoMd,
            contains(presence!),
            reason:
                'MD presence text for $field drifts from JSON predicate '
                '"$presence" — re-copy / re-derive doc/mcp_schema.md',
          );
        }
        // sessionSummary and its keys are all conditional; the MD must
        // state the same conditions.
        final summary = snapshotData['sessionSummary'] as Map<String, Object?>;
        final summaryShape = summary['shape'] as Map<String, Object?>;
        final topIssueItem =
            (summaryShape['topIssues'] as Map<String, Object?>)['item_shape']
                as Map<String, Object?>;
        final conditional = <String, Map<String, Object?>>{
          'sessionSummary': summary,
          for (final e in summaryShape.entries)
            'sessionSummary.${e.key}': e.value! as Map<String, Object?>,
          for (final e in topIssueItem.entries)
            if ((e.value! as Map<String, Object?>)['required'] != true)
              'sessionSummary.topIssues[].${e.key}':
                  e.value! as Map<String, Object?>,
        };
        for (final entry in conditional.entries) {
          expect(
            entry.value['required'],
            isNot(true),
            reason: '${entry.key} is emitted conditionally',
          );
          final presence = entry.value['presence'] as String?;
          expect(
            presence,
            isNotNull,
            reason: '${entry.key} must declare a presence predicate in JSON',
          );
          expect(
            repoMd,
            contains(presence!),
            reason:
                'MD presence text for ${entry.key} drifts from JSON '
                'predicate "$presence" — re-copy / re-derive '
                'doc/mcp_schema.md',
          );
        }
      },
    );
  });
}
