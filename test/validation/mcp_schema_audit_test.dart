import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/sleuth.dart' show Sleuth, StartupMetrics;
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/base_detector.dart';
import 'package:sleuth/src/models/frame_stats.dart';
import 'package:sleuth/src/models/heap_sample.dart';
import 'package:sleuth/src/models/route_session.dart';
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

void main() {
  late Map<String, Object?> schema;
  late Map<String, Object?> handlers;

  setUpAll(() {
    schema = _loadSchema();
    handlers = schema['handlers'] as Map<String, Object?>;
  });

  group('envelope shape', () {
    test('OK envelope keys match documented', () async {
      final c = _newController();
      final env = await extDiagnoseHandler(c, const {});
      final docOk = ((schema['envelope'] as Map)['ok'] as Map<String, Object?>);
      final docKeys = docOk.keys.toSet();
      // Documented keys ⊆ actual; every doc key must appear.
      expect(env.keys.toSet().containsAll(docKeys), isTrue,
          reason: 'envelope missing documented keys: '
              '${docKeys.difference(env.keys.toSet())}');
      // schemaVersion locked at the value the doc declares.
      expect(env['schemaVersion'], (docOk['schemaVersion'] as Map)['value']);
    });

    test('connectionMode is one of the documented enum values', () async {
      final c = _newController();
      final env = await extDiagnoseHandler(c, const {});
      final mode = env['connectionMode'] as String;
      final allowed = (((schema['envelope'] as Map)['ok']
          as Map)['connectionMode'] as Map)['values'] as List;
      expect(allowed, contains(mode));
    });
  });

  group('ext.sleuth.diagnose', () {
    test('data keys match documented (bidirectional)', () async {
      final c = _newController();
      final env = await extDiagnoseHandler(c, const {});
      final actual = (env['data'] as Map<String, Object?>).keys.toSet();
      final documented = _documentedKeys(
          handlers['ext.sleuth.diagnose'] as Map<String, Object?>);
      expect(actual, equals(documented),
          reason: 'diagnose data keys drift from schema. '
              'missing: ${documented.difference(actual)}, '
              'undocumented: ${actual.difference(documented)}');
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
    test('documented required-data-keys ⊆ actual on empty controller',
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
          handlers['ext.sleuth.snapshot'] as Map<String, Object?>);
      expect(actual.containsAll(required), isTrue,
          reason: 'snapshot missing required keys: '
              '${required.difference(actual)}');
      // Conditional keys must NOT leak when their preconditions are unmet.
      expect(actual.contains('suppressedCount'), isFalse,
          reason: 'suppressedCount must only emit when > 0');
      expect(actual.contains('startupMetrics'), isFalse,
          reason: 'startupMetrics must only emit when Sleuth.init ran');
    });

    test('suppressedCount + startupMetrics emit when their preconditions fire',
        () async {
      final c = _newController();
      c.suppressedCountNotifier.value = 1;
      addTearDown(Sleuth.resetStartupForTest);
      Sleuth.setStartupMetricsForTest(StartupMetrics(
        dartEntryTimestamp: DateTime.now(),
        ttffMs: 100.0,
      ));
      final env = await extSnapshotHandler(c, const {});
      final actual = (env['data'] as Map<String, Object?>).keys.toSet();
      expect(actual, contains('suppressedCount'),
          reason: 'suppressedCount missing once notifier > 0');
      expect(actual, contains('startupMetrics'),
          reason: 'startupMetrics missing once Sleuth.init captured it');
      // Documented keys must be a superset of every key the handler emits —
      // any drift here surfaces undocumented runtime fields the schema lock
      // is meant to catch.
      final documented = _documentedKeys(
          handlers['ext.sleuth.snapshot'] as Map<String, Object?>);
      expect(documented.containsAll(actual), isTrue,
          reason:
              'undocumented snapshot keys: ${actual.difference(documented)}');
    });

    test('recentRequests emits once the network buffer is non-empty', () async {
      // Precondition triad (see exportSnapshot): _initialized AND
      // _networkMonitor.isEnabled AND records.isNotEmpty. Drive each.
      final c = _newController()
        ..initializeDetectorsForTest()
        ..markInitializedForTest();
      c.networkMonitorForTest.isEnabled = true;
      c.networkMonitorForTest.processRecord(RequestRecord(
        url: 'https://example.test/api',
        method: 'GET',
        statusCode: 200,
        durationMs: 80,
        responseBytes: 256,
        startedAt: DateTime.now(),
      ));
      final env = await extSnapshotHandler(c, const {});
      final actual = (env['data'] as Map<String, Object?>).keys.toSet();
      expect(actual, contains('recentRequests'),
          reason: 'recentRequests missing once a record is in the ring buffer');
    });

    test('heapSamples emits once a sample has been fed', () async {
      // Precondition: _initialized AND _memoryPressure.heapSamples.isNotEmpty.
      // MemoryPressureDetector needs to be in `enabledDetectors` for
      // `processHeapSample` to push samples into the buffer.
      final c = SleuthController(
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
      c.feedHeapSampleForTest(HeapSample(
        heapUsage: 10 * 1024 * 1024,
        heapCapacity: 20 * 1024 * 1024,
        externalUsage: 0,
        timestamp: DateTime.now(),
      ));
      final env = await extSnapshotHandler(c, const {});
      final actual = (env['data'] as Map<String, Object?>).keys.toSet();
      expect(actual, contains('heapSamples'),
          reason: 'heapSamples missing once the detector buffer is non-empty');
    });

    test('phaseEvents emits from timeline-data feed', () async {
      final c = _newController()..initializeDetectorsForTest();
      c.feedTimelineDataForTest(enrichedBuildData(
        buildDurationUs: 10000,
        dirtyCount: 3,
      ));
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

    test('recentFrames + sessionSummary emit once frames are recorded',
        () async {
      // recentFrames fires on `frames.isNotEmpty`; sessionSummary fires
      // when the summary builder produces at least one field (which it
      // does as soon as frames.isNotEmpty supplies the frame-time
      // histogram).
      final c = _newController()..initializeDetectorsForTest();
      for (var i = 1; i <= 3; i++) {
        c.addFrameForTest(FrameStats(
          frameNumber: i,
          uiDuration: const Duration(microseconds: 8000),
          rasterDuration: const Duration(microseconds: 4000),
          timestamp: DateTime.now(),
        ));
      }
      final env = await extSnapshotHandler(c, const {});
      final actual = (env['data'] as Map<String, Object?>).keys.toSet();
      expect(actual, contains('recentFrames'));
      expect(actual, contains('sessionSummary'),
          reason: 'sessionSummary should populate once frames feed the '
              'histogram builder');
    });

    // widgetHeatMap, recurrenceTrends, routeSessions: see `_audit_unreachable`
    // declaration below. These fields require either issue aggregation
    // (depends on full scan pipeline) or write-access to a private deque
    // (`_routeHistory`) that has no public setter. Adding a test-only
    // seam for them was deliberately out of scope for this audit; the
    // schema's `presence` predicate is documented and exercised at
    // `SessionSnapshot.toJson()` level in test/models/serialization_test.dart.

    /// Conditional fields the audit deliberately does not drive from the
    /// handler seam. Each entry must have a rationale + a pointer to the
    /// model-level coverage that does exercise it.
    const auditUnreachable = <String, String>{
      'widgetHeatMap':
          'requires aggregated PerformanceIssue list — populated only via the '
              'real scan pipeline. Covered in test/controller/export_snapshot_test.dart',
      'recurrenceTrends': 'requires _recurrenceTrends to fill from repeated '
          'issue emissions across scan cycles. Covered in '
          'test/controller/sleuth_controller_test.dart recurrence groups.',
      'routeSessions':
          '_routeHistory is private + has no public setter. Covered in '
              'test/models/serialization_test.dart SessionSnapshot v4 group.',
    };

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
      };
      final covered = {...exercisedHere, ...auditUnreachable.keys};
      final uncovered = optionalKeys.difference(covered);
      expect(uncovered, isEmpty,
          reason: 'optional snapshot keys without presence coverage or '
              'an `auditUnreachable` rationale: $uncovered');
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
      final required =
          _requiredKeys(handlers['ext.sleuth.issues'] as Map<String, Object?>);
      expect(actual.containsAll(required), isTrue);
    });

    test('data includes route when route arg passed', () async {
      final c = _newController();
      final env = await extIssuesHandler(c, const {'route': '/home'});
      final actual = (env['data'] as Map<String, Object?>).keys.toSet();
      expect(actual, containsAll(<String>['issues', 'route']));
    });
  });

  group('ext.sleuth.routeHealth', () {
    test('absent route → data has `routes` key holding a list', () async {
      final c = _newController();
      final env = await extRouteHealthHandler(c, const {});
      final data = env['data'] as Map<String, Object?>;
      expect(data.keys, contains('routes'));
      expect(data['routes'], isA<List>());
      expect(data.containsKey('route'), isFalse,
          reason: 'absent-route shape must not include singular `route` key');
    });

    test('matching route → data has single `route` key wrapping the session',
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
      expect(data.keys, contains('route'),
          reason: 'matching-route shape must wrap the single session under '
              '`route` (was previously emitted inline — polymorphism collapsed)');
      expect(data['route'], isA<Map<String, Object?>>());
      final routeMap = data['route'] as Map<String, Object?>;
      expect(routeMap['routeName'], 'home');
      expect(data.containsKey('routes'), isFalse,
          reason: 'matching-route shape must not include the plural list key');
    });

    test('no-match route → error envelope echoes the route arg', () async {
      final c = _newController();
      final env = await extRouteHealthHandler(c, const {'route': 'ghost'});
      expect(env['error'], 'unknown_route');
      expect(env['route'], 'ghost',
          reason: 'error envelope must echo the unknown route');
      expect(env.containsKey('data'), isFalse,
          reason: 'error envelope must not carry a `data` block');
    });
  });

  group('ext.sleuth.encyclopedia', () {
    test('data keys + types match documented', () async {
      final c = _newController();
      final env = await extEncyclopediaHandler(c, const {});
      final actual = (env['data'] as Map<String, Object?>).keys.toSet();
      final documented = _documentedKeys(
          handlers['ext.sleuth.encyclopedia'] as Map<String, Object?>);
      expect(actual, equals(documented));
      final data = env['data'] as Map<String, Object?>;
      expect(data['count'], isA<int>());
      expect(data['entries'], isA<Map<String, Object?>>());
    });

    test('every entry has documented explanation shape', () async {
      final c = _newController();
      final env = await extEncyclopediaHandler(c, const {});
      final data = env['data'] as Map<String, Object?>;
      final entries = data['entries'] as Map<String, Object?>;
      final explainShape = (((handlers['ext.sleuth.explain'] as Map)['data']
          as Map)['explanation'] as Map)['shape'] as Map<String, Object?>;
      final docKeys = explainShape.keys.toSet();
      for (final entry in entries.entries) {
        final actual = (entry.value as Map<String, Object?>).keys.toSet();
        expect(actual, equals(docKeys),
            reason: 'entry ${entry.key} drifts from explanation schema');
      }
    });
  });

  group('ext.sleuth.causalGraph', () {
    test('data keys + types match documented', () async {
      final c = _newController();
      final env = await extCausalGraphHandler(c, const {});
      final actual = (env['data'] as Map<String, Object?>).keys.toSet();
      final documented = _documentedKeys(
          handlers['ext.sleuth.causalGraph'] as Map<String, Object?>);
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
          ]));
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
      final env =
          await extExplainHandler(c, const {'stableId': 'jank_detected'});
      // Some explanations may not exist in default config; if so, skip.
      if (env.containsKey('error')) {
        markTestSkipped('jank_detected unavailable in test config');
        return;
      }
      final actual = (env['data'] as Map<String, Object?>).keys.toSet();
      final documented = _documentedKeys(
          handlers['ext.sleuth.explain'] as Map<String, Object?>);
      expect(actual, equals(documented));
    });
  });

  group('schemaVersion contract', () {
    test('handler envelope schemaVersion matches doc-declared value', () {
      final docVersion = (((schema['envelope'] as Map)['ok']
          as Map)['schemaVersion'] as Map)['value'];
      expect(kMcpEnvelopeSchemaVersion, equals(docVersion),
          reason: 'kMcpEnvelopeSchemaVersion drifted from documented value');
    });

    test('ConnectionMode enum values match schema enum list (reflective)', () {
      // Drives mode-coverage statically: even if no test exercises a given
      // mode at runtime, this reflective check catches drift between the
      // enum and the doc.
      final actual = ConnectionMode.values.map((m) => m.name).toSet();
      final documented = (((schema['envelope'] as Map)['ok']
          as Map)['connectionMode'] as Map)['values'] as List;
      expect(actual, equals(documented.cast<String>().toSet()),
          reason: 'ConnectionMode enum drift: enum=$actual doc=$documented');
    });
  });

  group('mirrored doc parity', () {
    test('doc/mcp_schema.json byte-equal across sleuth + sleuth_mcp copies',
        () {
      final repoSchema = _resolveSchemaFile();
      final mirrored = File(
        '${repoSchema.parent.parent.path}/packages/sleuth_mcp/doc/mcp_schema.json',
      );
      expect(mirrored.existsSync(), isTrue,
          reason: 'sidecar mirror missing — pub archive will ship without it');
      expect(mirrored.readAsBytesSync(), equals(repoSchema.readAsBytesSync()),
          reason: 'mirror drift: re-copy doc/ into packages/sleuth_mcp/doc/');
    });

    test('doc/mcp_schema.md byte-equal across sleuth + sleuth_mcp copies', () {
      final repoSchema = _resolveSchemaFile();
      final repoMd = File('${repoSchema.parent.path}/mcp_schema.md');
      final mirrored = File(
        '${repoSchema.parent.parent.path}/packages/sleuth_mcp/doc/mcp_schema.md',
      );
      expect(repoMd.existsSync(), isTrue);
      expect(mirrored.existsSync(), isTrue,
          reason: 'sidecar mirror missing — pub archive will ship without it');
      expect(mirrored.readAsBytesSync(), equals(repoMd.readAsBytesSync()),
          reason: 'mirror drift: re-copy doc/ into packages/sleuth_mcp/doc/');
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
      final repoMd =
          File('${repoSchema.parent.path}/mcp_schema.md').readAsStringSync();
      final snapshotData = ((handlers['ext.sleuth.snapshot']
          as Map<String, Object?>)['data'] as Map<String, Object?>);
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
        expect(spec, isA<Map<String, Object?>>(),
            reason: 'audited field $field absent from JSON');
        final presence = (spec as Map<String, Object?>)['presence'] as String?;
        expect(presence, isNotNull,
            reason: '$field must declare a presence predicate in JSON');
        expect(repoMd, contains(presence!),
            reason: 'MD presence text for $field drifts from JSON predicate '
                '"$presence" — re-copy / re-derive doc/mcp_schema.md');
      }
    });
  });
}
