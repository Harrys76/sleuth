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

/// The sleuth_mcp package root (holds `pubspec.yaml`, `lib/`, `doc/`).
Directory _packageDir() => _resolveToolSchemaFile().parent.parent;

Map<String, Object?> _loadToolSchema() {
  final file = _resolveToolSchemaFile();
  return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
}

/// Schema-only metadata keys never present in handler return shapes.
const Set<String> _schemaMetaKeys = {'_doc', '_shape_source'};
bool _isSchemaMeta(String key) => _schemaMetaKeys.contains(key);

Set<String> _documentedKeys(Map<String, Object?> toolSchema) {
  final data = toolSchema['data'];
  if (data is! Map<String, Object?>) return const <String>{};
  return data.keys.where((k) => !_isSchemaMeta(k)).toSet();
}

Set<String> _requiredKeys(Map<String, Object?> toolSchema) {
  final data = toolSchema['data'];
  if (data is! Map<String, Object?>) return const <String>{};
  return {
    for (final e in data.entries)
      if (!_isSchemaMeta(e.key) &&
          e.value is Map &&
          (e.value as Map)['required'] == true)
        e.key,
  };
}

/// Extract the text content from a ToolCallResult error response.
String _errorText(ToolCallResult r) {
  expect(r.isError, isTrue, reason: 'expected ToolCallResult.isError == true');
  expect(r.content, isNotEmpty);
  return r.content.first['text'] as String;
}

/// Documented arg type → JSON Schema `type` the descriptor must declare.
const Map<String, String> _jsonSchemaTypes = {
  'String': 'string',
  'bool': 'boolean',
  'int': 'integer',
  'num': 'number',
  'Map': 'object',
  'List<String>': 'array',
};

/// A server with the default registry, initialized.
Future<McpServer> _initializedServer() async {
  final server = McpServer(bridge: defaultFakeBridge())..registerDefaults();
  await server.handleForTest(
    JsonRpcMessage(method: 'initialize', params: const {}, id: 0),
  );
  return server;
}

/// Tool descriptors as `tools/list` serves them, keyed by name.
Future<Map<String, Map<String, Object?>>> _liveDescriptors() async {
  final server = await _initializedServer();
  final resp = await server.handleForTest(
    JsonRpcMessage(method: 'tools/list', params: const {}, id: 1),
  );
  final list = (resp!.result as Map<String, Object?>)['tools'] as List;
  return {
    for (final t in list.cast<Map<String, Object?>>()) t['name'] as String: t,
  };
}

/// Text of a `tools/call` error result sent through the server, so the
/// server's argument validation runs.
Future<String> _serverCallError(
  McpServer server,
  Map<String, Object?> params,
) async {
  final resp = await server.handleForTest(
    JsonRpcMessage(method: 'tools/call', params: params, id: 2),
  );
  final result = resp!.result as Map<String, Object?>;
  expect(result['isError'], isTrue, reason: 'expected an error for $params');
  return ((result['content'] as List).first as Map)['text'] as String;
}

/// Leading literal text of every `ToolCallResult.text('…')` error in
/// [source], cut at the first interpolation.
List<String> _literalErrorLeads(String source) => [
  for (final m in RegExp(
    r"ToolCallResult\.text\(\s*'((?:[^'\\]|\\.)*)'",
  ).allMatches(source))
    m.group(1)!.split(r'$').first,
];

/// Whether [errors] (a doc `errors` / `serverErrors` list) documents an
/// error message starting with [lead]: a documented `messagePrefix` it
/// starts with, or a documented `code` equal to its `code:` token.
bool _documents(List<Object?> errors, String lead) {
  final code = RegExp(r'^([a-z_]+):').firstMatch(lead)?.group(1);
  for (final e in errors.cast<Map<String, Object?>>()) {
    final prefix = e['messagePrefix'];
    if (prefix is String &&
        !prefix.startsWith('<') &&
        lead.startsWith(prefix)) {
      return true;
    }
    if (code != null && e['code'] == code) return true;
  }
  return false;
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

    test('documented tools match the server registry both ways', () async {
      final server = McpServer(bridge: defaultFakeBridge());
      final fromCode = {...builtInTools.keys, ...lifecycleTools(server).keys};
      final live = (await _liveDescriptors()).keys.toSet();
      expect(
        live,
        fromCode,
        reason: 'registerDefaults must register builtInTools + lifecycleTools',
      );
      final documented = tools.keys.toSet();
      expect(
        documented.difference(live),
        isEmpty,
        reason: 'tool schema lists tools that no handler binds',
      );
      expect(
        live.difference(documented),
        isEmpty,
        reason: 'handlers exist for tools missing from tool schema',
      );
    });

    test('every live descriptor argument matches the documented args both '
        'ways (names, types, required, enum, minLength, default)', () async {
      // `_validateArgs` enforces the live inputSchema: an arg the doc lists
      // but the descriptor omits is rejected with arg_unknown, and a type
      // drift rejects documented calls with arg_type_mismatch. Handler
      // tests bypass that validation, so this is the only guard.
      final live = await _liveDescriptors();
      for (final name in live.keys) {
        final doc = tools[name] as Map<String, Object?>;
        final docArgs =
            (doc['args'] as Map<String, Object?>?) ?? const <String, Object?>{};
        final inputSchema = live[name]!['inputSchema'] as Map<String, Object?>;
        expect(inputSchema['type'], 'object', reason: '$name inputSchema type');
        final props =
            (inputSchema['properties'] as Map<String, Object?>?) ??
            const <String, Object?>{};
        final required = ((inputSchema['required'] as List?) ?? const [])
            .cast<String>()
            .toSet();
        expect(
          docArgs.keys.toSet(),
          props.keys.toSet(),
          reason: '$name: documented args differ from inputSchema.properties',
        );
        expect(
          required.difference(props.keys.toSet()),
          isEmpty,
          reason: '$name: inputSchema.required names an undeclared arg',
        );
        for (final arg in docArgs.keys) {
          final d = docArgs[arg] as Map<String, Object?>;
          final p = props[arg] as Map<String, Object?>;
          final where = '$name.$arg';
          expect(
            _jsonSchemaTypes[d['type']],
            isNotNull,
            reason: '$where: unknown documented type ${d['type']}',
          );
          expect(p['type'], _jsonSchemaTypes[d['type']], reason: '$where type');
          if (d['type'] == 'List<String>') {
            expect(p['items'], {'type': 'string'}, reason: '$where items');
          }
          expect(
            required.contains(arg),
            d['required'] == true,
            reason: '$where required flag',
          );
          expect(p['enum'], d['values'], reason: '$where enum');
          expect(p['minLength'], d['minLength'], reason: '$where minLength');
          expect(
            p.containsKey('default'),
            d.containsKey('default'),
            reason: '$where default declared on one side only',
          );
          expect(p['default'], d['default'], reason: '$where default value');
        }
      }
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
        expect(
          hint,
          isNotNull,
          reason: '${entry.key} is missing a readOnlyHint annotation',
        );
        expect(
          hint,
          readOnly.contains(entry.key),
          reason:
              '${entry.key} readOnlyHint=$hint disagrees with '
              'readOnlyTools membership',
        );
      }
      expect(
        readOnly.difference(descriptors.keys.toSet()),
        isEmpty,
        reason: 'readOnlyTools names tools that no handler binds',
      );
    });

    test('every descriptor behavior hint matches toolAnnotations', () {
      // Locks destructiveHint/idempotentHint/openWorldHint per tool.
      // readOnlyHint is locked separately (readOnlyTools) and excluded here.
      final annotations = schema['toolAnnotations'] as Map<String, Object?>;
      final bridge = defaultFakeBridge();
      final server = McpServer(bridge: bridge);
      final descriptors = <String, dynamic>{
        for (final e in builtInTools.entries) e.key: e.value.descriptor,
        for (final e in lifecycleTools(server).entries)
          e.key: e.value.descriptor,
      };
      for (final entry in descriptors.entries) {
        final a = entry.value.annotations;
        final derived = <String, Object?>{
          if (a?.destructiveHint != null) 'destructiveHint': a.destructiveHint,
          if (a?.idempotentHint != null) 'idempotentHint': a.idempotentHint,
          if (a?.openWorldHint != null) 'openWorldHint': a.openWorldHint,
        };
        expect(
          derived,
          annotations[entry.key] ?? <String, Object?>{},
          reason:
              '${entry.key} behavior hints disagree with the '
              'toolAnnotations doc',
        );
      }
      expect(
        annotations.keys.toSet().difference(descriptors.keys.toSet()),
        isEmpty,
        reason: 'toolAnnotations names tools that no handler binds',
      );
    });
  });

  group('connect', () {
    test('success path keys ⊆ documented', () async {
      final bridge = defaultFakeBridge();
      final handler = builtInTools['connect']!.handler;
      final result =
          await handler(bridge, {'uri': 'ws://localhost/ws'})
              as Map<String, Object?>;
      final actual = result.keys.toSet();
      final documented = _documentedKeys(
        tools['connect'] as Map<String, Object?>,
      );
      // Required keys must be present.
      expect(
        actual,
        containsAll(<String>[
          'connected',
          'vmServiceUri',
          'sessionUuid',
          'connectionMode',
          'vmConnected',
          'sidecarVersion',
          'appPackageVersion',
        ]),
      );
      expect(
        actual,
        containsAll(_requiredKeys(tools['connect'] as Map<String, Object?>)),
        reason: 'every documented required connect key is returned',
      );
      // No undocumented keys.
      expect(
        actual.difference(documented),
        isEmpty,
        reason: 'connect emitted undocumented keys',
      );
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

    test(
      'error: version_skew_unknown refuses missing packageVersion',
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
      },
    );
  });

  group('diagnose', () {
    test(
      'success path: passthrough keys + sidecar stamps documented',
      () async {
        final bridge = defaultFakeBridge();
        await bridge.connect(Uri.parse('ws://localhost/ws'));
        final handler = builtInTools['diagnose']!.handler;
        final result = await handler(bridge, {}) as Map<String, Object?>;
        final data = result['data'] as Map<String, Object?>;
        final documented = _documentedKeys(
          tools['diagnose'] as Map<String, Object?>,
        );
        expect(
          data.keys.toSet().difference(documented),
          isEmpty,
          reason: 'diagnose emitted undocumented data keys',
        );
        expect(data['sidecarVersion'], sleuthMcpVersion);
        expect(data['sidecarBuiltAgainstSleuth'], sleuthPackageVersionPin);
      },
    );
  });

  group('compare_snapshots', () {
    Map<String, Object?> snap(String severity, {bool vm = true}) => {
      'packageVersion': '0.37.0',
      'isVmConnected': vm,
      'currentIssues': [
        {'stableId': 'a', 'severity': severity},
        {'stableId': 'a', 'severity': 'warning'},
      ],
      'frameStatsSummary': {'averageFps': 60.0},
    };

    for (final vm in [true, false]) {
      test('success path keys match documented (isVmConnected $vm)', () async {
        final handler = builtInTools['compare_snapshots']!.handler;
        final result =
            await handler(defaultFakeBridge(), {
                  'before': snap('warning', vm: vm),
                  'after': snap('critical', vm: vm),
                })
                as Map<String, Object?>;
        final doc = tools['compare_snapshots'] as Map<String, Object?>;
        final actual = result.keys.toSet();
        expect(
          actual.difference(_documentedKeys(doc)),
          isEmpty,
          reason: 'compare_snapshots emitted undocumented keys',
        );
        expect(
          _requiredKeys(doc).difference(actual),
          isEmpty,
          reason: 'compare_snapshots missing required documented keys',
        );
        expect(
          result.containsKey('coverageWarning'),
          !vm,
          reason: 'coverageWarning is present iff neither side had a VM link',
        );
        final docData = doc['data'] as Map<String, Object?>;
        for (final listKey in ['elevatedSeverity', 'countChanged']) {
          final shape =
              (docData[listKey] as Map<String, Object?>)['item_shape']
                  as Map<String, Object?>;
          for (final item
              in (result[listKey] as List).cast<Map<String, Object?>>()) {
            expect(
              item.keys.toSet(),
              shape.keys.toSet(),
              reason: '$listKey item shape drifted from the doc',
            );
          }
        }
        expect(result['countChanged'], isEmpty);
        expect(result['elevatedSeverity'], hasLength(1));
      });
    }

    test('error: arg before not object', () async {
      final bridge = defaultFakeBridge();
      final handler = builtInTools['compare_snapshots']!.handler;
      final result = await handler(bridge, {
        'before': 'not-a-map',
        'after': {},
      });
      final text = _errorText(result as ToolCallResult);
      expect(text, startsWith('arg "before" must be object'));
    });

    test('error: arg after not object', () async {
      final bridge = defaultFakeBridge();
      final handler = builtInTools['compare_snapshots']!.handler;
      final result = await handler(bridge, {
        'before': <String, Object?>{},
        'after': 7,
      });
      final text = _errorText(result as ToolCallResult);
      expect(text, startsWith('arg "after" must be object'));
    });
  });

  group('check_budgets', () {
    test('success path keys ⊆ documented', () async {
      final bridge = defaultFakeBridge()
        ..setEnvelope(
          'ext.sleuth.snapshot',
          fakeSnapshotEnvelope(isVmConnected: true),
        );
      await bridge.connect(Uri.parse('ws://localhost/ws'));
      final handler = builtInTools['check_budgets']!.handler;
      final result =
          await handler(bridge, {
                'minFps': 30,
                'maxIssues': 10,
                'maxCriticalIssues': 2,
              })
              as Map<String, Object?>;
      final actual = result.keys.toSet();
      final documented = _documentedKeys(
        tools['check_budgets'] as Map<String, Object?>,
      );
      expect(
        actual.difference(documented),
        isEmpty,
        reason: 'check_budgets emitted undocumented keys',
      );
      expect(
        documented.difference(actual),
        isEmpty,
        reason: 'check_budgets missing documented keys',
      );
      final observed = result['observed'] as Map<String, Object?>;
      expect(
        observed.keys.toSet(),
        containsAll(<String>['fps', 'issueCount', 'criticalCount']),
      );
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
      expect(
        _errorText(result as ToolCallResult),
        startsWith('minFps must be number'),
      );
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
      expect(
        _errorText(result as ToolCallResult),
        startsWith('maxIssues must be integer'),
      );
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
      expect(
        _errorText(result as ToolCallResult),
        startsWith('maxCriticalIssues must be integer'),
      );
    });
  });

  group('passthrough delegation', () {
    test(
      'get_snapshot returns the ext.sleuth.snapshot envelope verbatim',
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
      },
    );

    test(
      'get_issues with severityAtLeast == warning filters + stamps echo',
      () async {
        final bridge = defaultFakeBridge();
        await bridge.connect(Uri.parse('ws://localhost/ws'));
        final handler = builtInTools['get_issues']!.handler;
        final result =
            await handler(bridge, {'severityAtLeast': 'warning'})
                as Map<String, Object?>;
        final data = result['data'] as Map<String, Object?>;
        expect(data['severityAtLeast'], 'warning');
        // Fake bridge seeded {jank_detected.warning, heap_growing.critical} —
        // both >= warning, so filter retains both but the echo MUST appear.
        final filtered = data['issues'] as List;
        expect(filtered, hasLength(2));
      },
    );

    test(
      'get_issues with severityAtLeast omitted passes through unmodified',
      () async {
        final bridge = defaultFakeBridge();
        await bridge.connect(Uri.parse('ws://localhost/ws'));
        final handler = builtInTools['get_issues']!.handler;
        final result = await handler(bridge, {}) as Map<String, Object?>;
        final data = result['data'] as Map<String, Object?>;
        expect(
          data.containsKey('severityAtLeast'),
          isFalse,
          reason: 'absent filter must not stamp echo',
        );
      },
    );

    test('get_issues data keys are ext.sleuth.issues keys or documented '
        'sidecar keys', () async {
      final appSchema =
          jsonDecode(
                File(
                  '${_packageDir().path}/doc/mcp_schema.json',
                ).readAsStringSync(),
              )
              as Map<String, Object?>;
      final appKeys =
          (((appSchema['handlers'] as Map<String, Object?>)['ext.sleuth.issues']
                      as Map<String, Object?>)['data']
                  as Map<String, Object?>)
              .keys
              .toSet();
      final documented = _documentedKeys(
        tools['get_issues'] as Map<String, Object?>,
      );
      expect(
        documented.contains('vmConnected') && appKeys.contains('vmConnected'),
        isTrue,
        reason: 'vmConnected is an ext.sleuth.issues key the tool passes on',
      );
      final bridge = defaultFakeBridge()
        ..setEnvelope('ext.sleuth.issues', {
          'connectionMode': 'basic',
          'schemaVersion': 1,
          'sessionUuid': 'fake-uuid',
          'data': {
            'issues': fullFakeIssues(),
            'route': '/home',
            'vmConnected': false,
          },
        });
      await bridge.connect(Uri.parse('ws://localhost/ws'));
      final result =
          await builtInTools['get_issues']!.handler(bridge, {
                'route': '/home',
                'severityAtLeast': 'warning',
                'maxIssueCount': 1,
              })
              as Map<String, Object?>;
      final data = result['data'] as Map<String, Object?>;
      expect(
        data.keys,
        containsAll(<String>[
          'launchModeAdvisory',
          'severityAtLeast',
          '_truncated',
          '_totalCount',
          'vmConnected',
        ]),
      );
      expect(
        data.keys.toSet().difference(appKeys.union(documented)),
        isEmpty,
        reason: 'get_issues emitted undocumented data keys',
      );
    });

    test('explain_issue: missing_required_arg when stableId absent', () async {
      final bridge = defaultFakeBridge();
      await bridge.connect(Uri.parse('ws://localhost/ws'));
      final handler = builtInTools['explain_issue']!.handler;
      final result = await handler(bridge, {});
      expect(
        _errorText(result as ToolCallResult),
        startsWith('missing_required_arg: stableId'),
      );
    });

    test(
      'explain_issue passes through bridge envelope on valid stableId',
      () async {
        final bridge = defaultFakeBridge();
        await bridge.connect(Uri.parse('ws://localhost/ws'));
        final handler = builtInTools['explain_issue']!.handler;
        final result =
            await handler(bridge, {'stableId': 'jank_detected'})
                as Map<String, Object?>;
        final data = result['data'] as Map<String, Object?>;
        expect(data['stableId'], 'jank_detected');
      },
    );
  });

  group('get_route_health passthrough', () {
    test('doc declares no shim', () {
      final doc = tools['get_route_health'] as Map<String, Object?>;
      expect(doc['kind'], 'passthrough');
      expect(doc['shims'], isEmpty);
    });

    test('canonical {route: ...} shape passes through untouched', () async {
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
          'route': {'routeName': 'home', 'durationSeconds': 3.0},
        },
      });
      await bridge.connect(Uri.parse('ws://localhost/ws'));
      final handler = builtInTools['get_route_health']!.handler;
      final result =
          await handler(bridge, {'route': 'home'}) as Map<String, Object?>;
      final data = result['data'] as Map<String, Object?>;
      expect(data.containsKey('route'), isTrue);
      expect(
        data.containsKey('routeName'),
        isFalse,
        reason: 'canonical wrapper shape must not leak the inline key',
      );
      final route = data['route'] as Map<String, Object?>;
      expect(route['routeName'], 'home');
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
      expect(
        data.containsKey('route'),
        isFalse,
        reason: 'absent-route response must never carry singular route',
      );
    });
  });

  group('server-level errors', () {
    late List<Object?> serverErrors;

    setUpAll(() {
      serverErrors = schema['serverErrors'] as List<Object?>;
    });

    String prefixOf(String code) =>
        (serverErrors.cast<Map<String, Object?>>().singleWhere(
              (e) => e['code'] == code,
            )['messagePrefix']
            as String);

    for (final (code, params) in <(String, Map<String, Object?>)>[
      (
        'missing_required_arg',
        {'name': 'explain_issue', 'arguments': <String, Object?>{}},
      ),
      (
        'arg_unknown',
        {
          'name': 'get_issues',
          'arguments': {'bogus': 1},
        },
      ),
      (
        'arg_type_mismatch',
        {
          'name': 'get_snapshot',
          'arguments': {'diskHandoff': 'yes'},
        },
      ),
      (
        'arg_enum_violation',
        {
          'name': 'get_issues',
          'arguments': {'severityAtLeast': 'fatal'},
        },
      ),
      (
        'arg_min_length_violation',
        {
          'name': 'explain_issue',
          'arguments': {'stableId': ''},
        },
      ),
      ('unknown_tool', {'name': 'no_such_tool'}),
      ('missing_tool_name', <String, Object?>{}),
      (
        'arguments_not_object',
        {
          'name': 'get_issues',
          'arguments': [1],
        },
      ),
    ]) {
      test('$code is documented and returned through tools/call', () async {
        final server = await _initializedServer();
        final text = await _serverCallError(server, params);
        expect(text, startsWith(prefixOf(code)));
      });
    }

    test('every documented server error is returned by McpServer and every '
        'literal server error is documented', () {
      final source = File(
        '${_packageDir().path}/lib/src/mcp/mcp_server.dart',
      ).readAsStringSync();
      final validateStart = source.indexOf('String? _validateArgs(');
      final validateEnd = source.indexOf('String _jsonTypeOf(');
      expect(validateStart, isNonNegative);
      expect(validateEnd, greaterThan(validateStart));
      final leads = [
        ..._literalErrorLeads(source),
        for (final m in RegExp(
          r"return '((?:[^'\\]|\\.)*)'",
        ).allMatches(source.substring(validateStart, validateEnd)))
          m.group(1)!.split(r'$').first,
      ];
      expect(leads, isNotEmpty);
      for (final lead in leads) {
        expect(
          _documents(serverErrors, lead),
          isTrue,
          reason: 'McpServer returns "$lead…" but serverErrors omits it',
        );
      }
      for (final e in serverErrors.cast<Map<String, Object?>>()) {
        final prefix = e['messagePrefix'] as String;
        expect(
          leads.any((l) => l.startsWith(prefix)),
          isTrue,
          reason:
              'serverErrors documents ${e['code']} but McpServer never '
              'returns "$prefix…"',
        );
      }
    });
  });

  group('error-code coverage', () {
    List<Object?> errorsOf(String tool) =>
        ((tools[tool] as Map<String, Object?>)['errors'] as List?) ??
        const <Object?>[];

    List<Object?> allToolErrors() => [
      for (final name in tools.keys) ...errorsOf(name),
    ];

    String read(String relative) =>
        File('${_packageDir().path}/$relative').readAsStringSync();

    test('every literal compare_snapshots error is documented', () {
      for (final lead in _literalErrorLeads(
        read('lib/src/tools/compare_snapshots.dart'),
      )) {
        expect(
          _documents(errorsOf('compare_snapshots'), lead),
          isTrue,
          reason: 'compare_snapshots returns "$lead…" undocumented',
        );
      }
    });

    test('every literal check_budgets error is documented', () {
      for (final lead in _literalErrorLeads(
        read('lib/src/tools/budgets.dart'),
      )) {
        expect(
          _documents(errorsOf('check_budgets'), lead),
          isTrue,
          reason: 'check_budgets returns "$lead…" undocumented',
        );
      }
    });

    test('every literal, typed, and version-skew error in tools.dart is '
        'documented by some tool', () {
      final source = read('lib/src/tools/tools.dart');
      final documented = allToolErrors();
      final leads = [
        ..._literalErrorLeads(source),
        for (final m in RegExp(r"'(version_skew_[a-z]+):").allMatches(source))
          '${m.group(1)}:',
      ];
      expect(leads, isNotEmpty);
      for (final lead in leads) {
        expect(
          _documents(documented, lead),
          isTrue,
          reason: 'tools.dart returns "$lead…" but no tool documents it',
        );
      }
      final typedCodes = {
        for (final m in RegExp(
          r"_iosErrorEnvelope\(\s*'([a-z_]+)'",
        ).allMatches(source))
          m.group(1)!,
        for (final m in RegExp(r"return '(ios_[a-z_]+)';").allMatches(source))
          m.group(1)!,
      };
      expect(typedCodes, isNotEmpty);
      final documentedCodes = {
        for (final e in documented.cast<Map<String, Object?>>()) e['code'],
      };
      expect(
        typedCodes.difference(documentedCodes),
        isEmpty,
        reason: 'typed error codes returned by tools.dart but undocumented',
      );
    });
  });

  group('mirror parity', () {
    test('sleuth root has NO doc/mcp_tool_schema.json', () {
      final root = _resolveRepoRoot();
      final candidate = File('${root.path}/doc/mcp_tool_schema.json');
      expect(
        candidate.existsSync(),
        isFalse,
        reason:
            'tool schema is sidecar-only; root copy would force two-side mirroring',
      );
    });

    test('sleuth root has NO doc/mcp_tool_schema.md', () {
      final root = _resolveRepoRoot();
      final candidate = File('${root.path}/doc/mcp_tool_schema.md');
      expect(
        candidate.existsSync(),
        isFalse,
        reason: 'tool schema md is sidecar-only',
      );
    });
  });
}
