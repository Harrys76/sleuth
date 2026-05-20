import 'dart:convert';
import 'dart:io';

import 'package:sleuth/sleuth.dart';
import 'package:flutter_test/flutter_test.dart';

/// Resolve `doc/mcp_schema.json` from cwd (repo root when `flutter test`
/// runs) — mirrors the resolution used by the schema audit.
File _schemaFile() {
  for (final p in [
    'doc/mcp_schema.json',
    '../doc/mcp_schema.json',
  ]) {
    final f = File(p);
    if (f.existsSync()) return f;
  }
  throw StateError(
      'doc/mcp_schema.json not found from ${Directory.current.path}');
}

void main() {
  group('SnapshotSection', () {
    test('fromString is case-insensitive + whitespace-tolerant', () {
      expect(SnapshotSection.fromString('currentIssues'),
          SnapshotSection.currentIssues);
      expect(SnapshotSection.fromString('  CURRENTISSUES '),
          SnapshotSection.currentIssues);
      expect(SnapshotSection.fromString('routesessions'),
          SnapshotSection.routeSessions);
      expect(SnapshotSection.fromString('bogus'), isNull);
      expect(SnapshotSection.fromString(''), isNull);
      expect(SnapshotSection.fromString('   '), isNull);
    });

    test('jsonKey is unique + non-empty', () {
      final keys = SnapshotSection.values.map((s) => s.jsonKey).toList();
      expect(keys.toSet().length, keys.length, reason: 'duplicate jsonKey');
      expect(keys.every((k) => k.isNotEmpty), isTrue);
    });

    test('enum jsonKeys match the projectable section keys in mcp_schema.json',
        () {
      // Bidirectional drift guard against the schema doc, which is itself
      // validated against the live handler by mcp_schema_audit_test. A
      // section added to toJson + schema but not the enum (or vice versa)
      // trips here.
      final schema =
          jsonDecode(_schemaFile().readAsStringSync()) as Map<String, Object?>;
      final handlers = schema['handlers'] as Map<String, Object?>;
      final snapshot = handlers['ext.sleuth.snapshot'] as Map<String, Object?>;
      final data = snapshot['data'] as Map<String, Object?>;

      // Documented payload keys = data keys that are real specs (Map),
      // minus always-on metadata, minus `_`-prefixed projection/meta.
      final documentedPayload = <String>{
        for (final entry in data.entries)
          if (entry.value is Map &&
              !entry.key.startsWith('_') &&
              !SnapshotSection.alwaysOnKeys.contains(entry.key))
            entry.key,
      };
      final enumKeys = SnapshotSection.values.map((s) => s.jsonKey).toSet();
      expect(enumKeys, equals(documentedPayload),
          reason: 'SnapshotSection enum drifted from mcp_schema.json '
              'ext.sleuth.snapshot payload keys.\n'
              'enum-only: ${enumKeys.difference(documentedPayload)}\n'
              'schema-only: ${documentedPayload.difference(enumKeys)}');
    });

    test('projection: include omits unlisted payload sections', () {
      final json = _snapshot().toJson(include: {SnapshotSection.currentIssues});
      expect(json.containsKey('currentIssues'), isTrue);
      expect(json.containsKey('frameStatsSummary'), isFalse);
      expect(json.containsKey('schemaVersion'), isTrue); // metadata always
      expect(json['_projectedSections'], equals(['currentIssues']));
      expect(json['_projectionApplied'], 'by_app');
    });

    test('maxRouteCount keeps N most-recent by startedAt', () {
      final json = _snapshot().toJson(
        include: {SnapshotSection.routeSessions},
        maxRouteCount: 2,
      );
      final routes = json['routeSessions'] as List;
      expect(routes.length, 2);
      expect((routes[0] as Map)['routeName'], 'r3'); // newest first
      expect((routes[1] as Map)['routeName'], 'r2');
      expect((json['_projectionLimits'] as Map)['maxRouteCount'], 2);
    });

    test('no projection args ⇒ no metadata stamps', () {
      final json = _snapshot().toJson();
      expect(json.containsKey('_projectedSections'), isFalse);
      expect(json.containsKey('_projectionLimits'), isFalse);
      expect(json.containsKey('_projectionApplied'), isFalse);
    });
  });
}

SessionSnapshot _snapshot() {
  DateTime at(int min) => DateTime(2026, 1, 1, 0, min);
  return SessionSnapshot(
    exportedAt: at(0),
    capturedFrames: const [],
    currentIssues: const [],
    frameStatsSummary: const FrameStatsSummary(
      totalFrames: 10,
      jankFrames: 1,
      averageFps: 60,
      worstFrameTimeUs: 1000,
    ),
    routeSessions: [
      {'routeName': 'r1', 'startedAt': at(1).toIso8601String()},
      {'routeName': 'r2', 'startedAt': at(2).toIso8601String()},
      {'routeName': 'r3', 'startedAt': at(3).toIso8601String()},
    ],
  );
}
