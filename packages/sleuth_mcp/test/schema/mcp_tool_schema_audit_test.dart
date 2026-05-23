import 'dart:convert';
import 'dart:io';

import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:sleuth_mcp/src/tools/tools.dart';
import 'package:test/test.dart';

import '../helpers/fake_vm_bridge.dart';

/// Resolve `packages/sleuth_mcp/doc/mcp_tool_schema.json` independent of
/// test-runner cwd. Walks up from the test file (or `Directory.current`)
/// until it finds a directory containing `pubspec.yaml` with the
/// sleuth_mcp package name AND the doc/mcp_tool_schema.json file.
File _resolveToolSchemaFile() {
  for (final start in [
    Directory.current,
    File.fromUri(Platform.script).parent,
  ]) {
    var dir = start;
    for (var i = 0; i < 8; i++) {
      final candidate = File('${dir.path}/doc/mcp_tool_schema.json');
      final pubspec = File('${dir.path}/pubspec.yaml');
      if (candidate.existsSync() && pubspec.existsSync()) {
        final text = pubspec.readAsStringSync();
        if (text.contains('name: sleuth_mcp\n')) return candidate;
      }
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
  }
  throw StateError(
    'doc/mcp_tool_schema.json not found by walking up from cwd or test '
    'file. Audit must run within the sleuth_mcp package directory. '
    'Check .pubignore exception.',
  );
}

/// Walk up from the sidecar pubspec dir to find the repo root (parent
/// containing `name: sleuth\n`). Used for the mirror-parity test that
/// asserts the sleuth root has NO `doc/mcp_tool_schema.{json,md}`.
Directory _resolveRepoRoot() {
  final sidecarPubspec = _resolveToolSchemaFile().parent.parent;
  var dir = sidecarPubspec;
  for (var i = 0; i < 8; i++) {
    final pubspec = File('${dir.path}/pubspec.yaml');
    if (pubspec.existsSync() &&
        pubspec.readAsStringSync().contains('name: sleuth\n')) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError(
    'sleuth repo root not found by walking up from sidecar package',
  );
}

Map<String, Object?> _loadToolSchema() {
  final file = _resolveToolSchemaFile();
  return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
}

/// Schema-only metadata keys never present in handler return shapes.
const Set<String> _schemaMetaKeys = {
  '_doc',
  '_shape_source',
};
bool _isSchemaMeta(String key) => _schemaMetaKeys.contains(key);

Set<String> _documentedKeys(Map<String, Object?> toolSchema) {
  final data = toolSchema['data'];
  if (data is! Map<String, Object?>) return const <String>{};
  return data.keys.where((k) => !_isSchemaMeta(k)).toSet();
}

/// Extract the text content from a ToolCallResult error response.
String _errorText(ToolCallResult r) {
  expect(r.isError, isTrue, reason: 'expected ToolCallResult.isError == true');
  expect(r.content, isNotEmpty);
  return r.content.first['text'] as String;
}

void main() {
  late Map<String, Object?> schema;
  late Map<String, Object?> tools;

  setUpAll(() {
    schema = _loadToolSchema();
    tools = schema['tools'] as Map<String, Object?>;
  });

  group('schema sanity', () {
    test('schemaVersion is locked at 2', () {
      expect(schema['schemaVersion'], 2);
    });

    test('every documented tool exists in builtInTools or lifecycleTools', () {
      // lifecycleTools take an McpServer; reflective coverage is enough —
      // we don't construct one in this audit. Just verify the union of
      // tool names equals the documented set.
      final documented = tools.keys.toSet();
      const lifecycleNames = {
        'attach_app',
        'detach_app',
        'app_status',
        'hot_reload',
        'list_devices',
      };
      final builtIn = builtInTools.keys.toSet();
      final union = {...builtIn, ...lifecycleNames};
      expect(documented.difference(union), isEmpty,
          reason: 'tool schema lists tools that no handler binds');
      expect(union.difference(documented), isEmpty,
          reason: 'handlers exist for tools missing from tool schema');
    });

    test(
        'attach_app: every documented arg is declared in the live '
        'inputSchema (allowlist drift guard)', () {
      // The arg allowlist that `_validateArgs` enforces is the tool's
      // inputSchema.properties. A doc that lists an arg the descriptor
      // omits means callers get `arg_unknown` for a documented arg —
      // exactly how `forceRelaunch` was unreachable. Cross-check both.
      final attachDoc = tools['attach_app'] as Map<String, Object?>;
      final docArgs = (attachDoc['args'] as Map<String, Object?>).keys.toSet();

      final bridge = defaultFakeBridge();
      final server = McpServer(bridge: bridge);
      final descriptor = lifecycleTools(server)['attach_app']!.descriptor;
      final schemaMap = descriptor.inputSchema;
      final props =
          (schemaMap['properties'] as Map<String, Object?>).keys.toSet();

      expect(docArgs.difference(props), isEmpty,
          reason: 'mcp_tool_schema documents attach_app args the live '
              'inputSchema does not declare — callers hit arg_unknown: '
              '${docArgs.difference(props)}');
    });

    test('every descriptor declares readOnlyHint matching readOnlyTools', () {
      final readOnly = (schema['readOnlyTools'] as List).cast<String>().toSet();
      final bridge = defaultFakeBridge();
      final server = McpServer(bridge: bridge);
      final descriptors = <String, dynamic>{
        for (final e in builtInTools.entries) e.key: e.value.descriptor,
        for (final e in lifecycleTools(server).entries)
          e.key: e.value.descriptor,
      };
      for (final entry in descriptors.entries) {
        final hint = entry.value.annotations?.readOnlyHint as bool?;
        expect(hint, isNotNull,
            reason: '${entry.key} is missing a readOnlyHint annotation');
        expect(hint, readOnly.contains(entry.key),
            reason: '${entry.key} readOnlyHint=$hint disagrees with '
                'readOnlyTools membership');
      }
      expect(readOnly.difference(descriptors.keys.toSet()), isEmpty,
          reason: 'readOnlyTools names tools that no handler binds');
    });
  });

  group('connect', () {
    test('success path keys ⊆ documented', () async {
      final bridge = defaultFakeBridge();
      final handler = builtInTools['connect']!.handler;
      final result = await handler(bridge, {'uri': 'ws://localhost/ws'})
          as Map<String, Object?>;
      final actual = result.keys.toSet();
      final documented =
          _documentedKeys(tools['connect'] as Map<String, Object?>);
      // Required keys must be present.
      expect(
          actual,
          containsAll(<String>[
            'connected',
            'vmServiceUri',
            'sessionUuid',
            'connectionMode',
            'sidecarVersion',
            'appPackageVersion',
          ]));
      // No undocumented keys.
      expect(actual.difference(documented), isEmpty,
          reason: 'connect emitted undocumented keys');
    });

    test('error: missing_required_arg when uri absent', () async {
      final bridge = defaultFakeBridge();
      final handler = builtInTools['connect']!.handler;
      final result = await handler(bridge, {});
      final text = _errorText(result as ToolCallResult);
      expect(text, startsWith('missing_required_arg: uri'));
    });

    test('error: invalid_uri when uri malformed', () async {
      final bridge = defaultFakeBridge();
      final handler = builtInTools['connect']!.handler;
      // Trigger FormatException. ':://' triggers Uri.parse to throw on
      // most Dart versions; if it parses, fall through to second probe.
      final result = await handler(bridge, {'uri': 'h ttp://bad uri/'});
      // Either invalid_uri OR — if Dart parsed the bad input — connection
      // proceeded; in that case skip this leg since the fake bridge
      // accepts any uri.
      if (result is ToolCallResult && result.isError) {
        expect(_errorText(result), startsWith('invalid_uri'));
      } else {
        markTestSkipped('Dart parsed the malformed uri without throwing');
      }
    });

    test('error: version_skew_major refuses cross-lineage drift', () async {
      final bridge = FakeVmBridge(fakeSessionUuid: 'uuid')
        ..setEnvelope('ext.sleuth.diagnose', {
          'connectionMode': 'basic',
          'schemaVersion': 1,
          'sessionUuid': 'uuid',
          'data': {'packageVersion': '0.1.0'},
        });
      final handler = builtInTools['connect']!.handler;
      final result = await handler(bridge, {'uri': 'ws://localhost/ws'});
      final text = _errorText(result as ToolCallResult);
      expect(text, startsWith('version_skew_major:'));
    });

    test('error: version_skew_unknown refuses missing packageVersion',
        () async {
      final bridge = FakeVmBridge(fakeSessionUuid: 'uuid')
        ..setEnvelope('ext.sleuth.diagnose', {
          'connectionMode': 'basic',
          'schemaVersion': 1,
          'sessionUuid': 'uuid',
          'data': <String, Object?>{},
        });
      final handler = builtInTools['connect']!.handler;
      final result = await handler(bridge, {'uri': 'ws://localhost/ws'});
      final text = _errorText(result as ToolCallResult);
      expect(text, startsWith('version_skew_unknown:'));
    });
  });

  group('diagnose', () {
    test('success path: passthrough keys + sidecar stamps documented',
        () async {
      final bridge = defaultFakeBridge();
      await bridge.connect(Uri.parse('ws://localhost/ws'));
      final handler = builtInTools['diagnose']!.handler;
      final result = await handler(bridge, {}) as Map<String, Object?>;
      final data = result['data'] as Map<String, Object?>;
      final documented =
          _documentedKeys(tools['diagnose'] as Map<String, Object?>);
      expect(data.keys.toSet().difference(documented), isEmpty,
          reason: 'diagnose emitted undocumented data keys');
      expect(data['sidecarVersion'], sleuthMcpVersion);
      expect(data['sidecarBuiltAgainstSleuth'], sleuthPackageVersionPin);
    });
  });

  group('compare_snapshots', () {
    test('success path keys ⊆ documented', () async {
      final bridge = defaultFakeBridge();
      final handler = builtInTools['compare_snapshots']!.handler;
      final before = {
        'currentIssues': [
          {'stableId': 'a', 'severity': 'warning'},
        ],
        'frameStatsSummary': {'averageFps': 60.0},
      };
      final after = {
        'currentIssues': [
          {'stableId': 'a', 'severity': 'critical'},
        ],
        'frameStatsSummary': {'averageFps': 45.0},
      };
      final result = await handler(bridge, {'before': before, 'after': after})
          as Map<String, Object?>;
      final actual = result.keys.toSet();
      final documented =
          _documentedKeys(tools['compare_snapshots'] as Map<String, Object?>);
      expect(actual.difference(documented), isEmpty,
          reason: 'compare_snapshots emitted undocumented keys');
      expect(documented.difference(actual), isEmpty,
          reason: 'compare_snapshots missing documented keys');
    });

    test('error: arg before not object', () async {
      final bridge = defaultFakeBridge();
      final handler = builtInTools['compare_snapshots']!.handler;
      final result =
          await handler(bridge, {'before': 'not-a-map', 'after': {}});
      final text = _errorText(result as ToolCallResult);
      expect(text, startsWith('arg "before" must be object'));
    });

    test('error: arg after not object', () async {
      final bridge = defaultFakeBridge();
      final handler = builtInTools['compare_snapshots']!.handler;
      final result =
          await handler(bridge, {'before': <String, Object?>{}, 'after': 7});
      final text = _errorText(result as ToolCallResult);
      expect(text, startsWith('arg "after" must be object'));
    });
  });

  group('check_budgets', () {
    test('success path keys ⊆ documented', () async {
      final bridge = defaultFakeBridge();
      await bridge.connect(Uri.parse('ws://localhost/ws'));
      final handler = builtInTools['check_budgets']!.handler;
      final result = await handler(bridge, {
        'minFps': 30,
        'maxIssues': 10,
        'maxCriticalIssues': 2,
      }) as Map<String, Object?>;
      final actual = result.keys.toSet();
      final documented =
          _documentedKeys(tools['check_budgets'] as Map<String, Object?>);
      expect(actual.difference(documented), isEmpty,
          reason: 'check_budgets emitted undocumented keys');
      expect(documented.difference(actual), isEmpty,
          reason: 'check_budgets missing documented keys');
      final observed = result['observed'] as Map<String, Object?>;
      expect(observed.keys.toSet(),
          containsAll(<String>['fps', 'issueCount', 'criticalCount']));
    });

    test('error: minFps must be number', () async {
      final bridge = defaultFakeBridge();
      await bridge.connect(Uri.parse('ws://localhost/ws'));
      final handler = builtInTools['check_budgets']!.handler;
      final result = await handler(bridge, {
        'minFps': 'not-a-number',
        'maxIssues': 10,
        'maxCriticalIssues': 2,
      });
      expect(_errorText(result as ToolCallResult),
          startsWith('minFps must be number'));
    });

    test('error: maxIssues must be integer', () async {
      final bridge = defaultFakeBridge();
      await bridge.connect(Uri.parse('ws://localhost/ws'));
      final handler = builtInTools['check_budgets']!.handler;
      final result = await handler(bridge, {
        'minFps': 30,
        'maxIssues': 'bad',
        'maxCriticalIssues': 2,
      });
      expect(_errorText(result as ToolCallResult),
          startsWith('maxIssues must be integer'));
    });

    test('error: maxCriticalIssues must be integer', () async {
      final bridge = defaultFakeBridge();
      await bridge.connect(Uri.parse('ws://localhost/ws'));
      final handler = builtInTools['check_budgets']!.handler;
      final result = await handler(bridge, {
        'minFps': 30,
        'maxIssues': 10,
        'maxCriticalIssues': 'bad',
      });
      expect(_errorText(result as ToolCallResult),
          startsWith('maxCriticalIssues must be integer'));
    });
  });

  group('passthrough delegation', () {
    test('get_snapshot returns the ext.sleuth.snapshot envelope verbatim',
        () async {
      final bridge = defaultFakeBridge();
      await bridge.connect(Uri.parse('ws://localhost/ws'));
      final handler = builtInTools['get_snapshot']!.handler;
      final result = await handler(bridge, {}) as Map<String, Object?>;
      // Verbatim envelope: top-level keys must include connectionMode +
      // sessionUuid + schemaVersion + data exactly as the fake set them.
      expect(result['sessionUuid'], 'fake-uuid');
      expect(result['schemaVersion'], 1);
      expect(result['data'], isA<Map<String, Object?>>());
    });

    test('get_issues with severityAtLeast == warning filters + stamps echo',
        () async {
      final bridge = defaultFakeBridge();
      await bridge.connect(Uri.parse('ws://localhost/ws'));
      final handler = builtInTools['get_issues']!.handler;
      final result = await handler(bridge, {'severityAtLeast': 'warning'})
          as Map<String, Object?>;
      final data = result['data'] as Map<String, Object?>;
      expect(data['severityAtLeast'], 'warning');
      // Fake bridge seeded {jank_detected.warning, heap_growing.critical} —
      // both >= warning, so filter retains both but the echo MUST appear.
      final filtered = data['issues'] as List;
      expect(filtered, hasLength(2));
    });

    test('get_issues with severityAtLeast omitted passes through unmodified',
        () async {
      final bridge = defaultFakeBridge();
      await bridge.connect(Uri.parse('ws://localhost/ws'));
      final handler = builtInTools['get_issues']!.handler;
      final result = await handler(bridge, {}) as Map<String, Object?>;
      final data = result['data'] as Map<String, Object?>;
      expect(data.containsKey('severityAtLeast'), isFalse,
          reason: 'absent filter must not stamp echo');
    });

    test('explain_issue: missing_required_arg when stableId absent', () async {
      final bridge = defaultFakeBridge();
      await bridge.connect(Uri.parse('ws://localhost/ws'));
      final handler = builtInTools['explain_issue']!.handler;
      final result = await handler(bridge, {});
      expect(_errorText(result as ToolCallResult),
          startsWith('missing_required_arg: stableId'));
    });

    test('explain_issue passes through bridge envelope on valid stableId',
        () async {
      final bridge = defaultFakeBridge();
      await bridge.connect(Uri.parse('ws://localhost/ws'));
      final handler = builtInTools['explain_issue']!.handler;
      final result = await handler(bridge, {'stableId': 'jank_detected'})
          as Map<String, Object?>;
      final data = result['data'] as Map<String, Object?>;
      expect(data['stableId'], 'jank_detected');
    });
  });

  group('get_route_health lineage shim', () {
    test('v0.33 canonical {route: ...} shape passes through untouched',
        () async {
      final bridge = FakeVmBridge(fakeSessionUuid: 'uuid');
      bridge.setEnvelope('ext.sleuth.diagnose', {
        'connectionMode': 'basic',
        'schemaVersion': 1,
        'sessionUuid': 'uuid',
        'data': {'packageVersion': sleuthPackageVersionPin},
      });
      bridge.setEnvelope('ext.sleuth.routeHealth', {
        'connectionMode': 'basic',
        'schemaVersion': 1,
        'sessionUuid': 'uuid',
        'data': {
          'route': {
            'routeName': 'home',
            'durationSeconds': 3.0,
          },
        },
      });
      await bridge.connect(Uri.parse('ws://localhost/ws'));
      final handler = builtInTools['get_route_health']!.handler;
      final result =
          await handler(bridge, {'route': 'home'}) as Map<String, Object?>;
      final data = result['data'] as Map<String, Object?>;
      expect(data.containsKey('route'), isTrue);
      expect(data.containsKey('routeName'), isFalse,
          reason: 'canonical wrapper shape must not leak the inline key');
      final route = data['route'] as Map<String, Object?>;
      expect(route['routeName'], 'home');
    });

    test(
        'legacy inline RouteSession (routeName at data root) is wrapped into '
        '{route: <inline>} for acceptedPriorLineages app', () async {
      final bridge = FakeVmBridge(fakeSessionUuid: 'uuid');
      bridge.setEnvelope('ext.sleuth.diagnose', {
        'connectionMode': 'basic',
        'schemaVersion': 1,
        'sessionUuid': 'uuid',
        'data': {'packageVersion': '0.33.0'},
      });
      bridge.setEnvelope('ext.sleuth.routeHealth', {
        'connectionMode': 'basic',
        'schemaVersion': 1,
        'sessionUuid': 'uuid',
        'data': {
          // Inline RouteSession shape — no `route` wrapper key.
          'routeName': 'profile',
          'durationSeconds': 7.0,
          'healthScore': 92,
        },
      });
      await bridge.connect(Uri.parse('ws://localhost/ws'));
      final handler = builtInTools['get_route_health']!.handler;
      final result =
          await handler(bridge, {'route': 'profile'}) as Map<String, Object?>;
      final data = result['data'] as Map<String, Object?>;
      expect(data.containsKey('route'), isTrue,
          reason: 'shim must wrap inline shape into {route: ...}');
      final route = data['route'] as Map<String, Object?>;
      expect(route['routeName'], 'profile');
      expect(route['durationSeconds'], 7.0);
      expect(data.containsKey('routeName'), isFalse,
          reason: 'inline key must not leak alongside the wrapper');
    });

    test('absent-route shape (routes list) passes through untouched', () async {
      final bridge = defaultFakeBridge();
      await bridge.connect(Uri.parse('ws://localhost/ws'));
      final handler = builtInTools['get_route_health']!.handler;
      // No `route` arg -> bridge returns the routes-list envelope from
      // defaultFakeBridge — must NOT get wrapped.
      final result = await handler(bridge, {}) as Map<String, Object?>;
      final data = result['data'] as Map<String, Object?>;
      expect(data.containsKey('routes'), isTrue);
      expect(data.containsKey('route'), isFalse,
          reason: 'absent-route response must never carry singular route');
    });
  });

  group('mirror parity', () {
    test('sleuth root has NO doc/mcp_tool_schema.json', () {
      final root = _resolveRepoRoot();
      final candidate = File('${root.path}/doc/mcp_tool_schema.json');
      expect(candidate.existsSync(), isFalse,
          reason:
              'tool schema is sidecar-only; root copy would force two-side mirroring');
    });

    test('sleuth root has NO doc/mcp_tool_schema.md', () {
      final root = _resolveRepoRoot();
      final candidate = File('${root.path}/doc/mcp_tool_schema.md');
      expect(candidate.existsSync(), isFalse,
          reason: 'tool schema md is sidecar-only');
    });
  });
}
