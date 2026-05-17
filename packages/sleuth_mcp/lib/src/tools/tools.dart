import 'dart:async';

import '../bridge/vm_bridge.dart';
import '../mcp/mcp_server.dart';
import '../mcp/mcp_types.dart';
import '../util/version_lineage.dart';
import 'budgets.dart';
import 'compare_snapshots.dart';

class BuiltInTool {
  const BuiltInTool({required this.descriptor, required this.handler});
  final Tool descriptor;
  final ToolHandler handler;
}

const _emptyObjectSchema = <String, Object?>{
  'type': 'object',
  'properties': <String, Object?>{},
  'required': <String>[],
};

Future<Object> _passThrough(
  VmBridge bridge,
  String method, [
  Map<String, dynamic> args = const <String, dynamic>{},
]) async {
  final envelope = await bridge.callExtension(method, args: args);
  return envelope;
}

Future<Object> _connectHandler(
    VmBridge bridge, Map<String, Object?> args) async {
  final uri = args['uri'];
  if (uri is! String || uri.isEmpty) {
    return ToolCallResult.text('missing_required_arg: uri', isError: true);
  }
  Uri parsed;
  try {
    parsed = Uri.parse(uri);
  } on FormatException catch (e) {
    return ToolCallResult.text('invalid_uri: $e', isError: true);
  }
  await bridge.connect(parsed);
  // Reuse the bridge's connect-time diagnose envelope to avoid a second
  // round-trip.
  final diag = bridge.lastDiagnoseEnvelope ??
      await bridge.callExtension('ext.sleuth.diagnose');
  final data = diag['data'];
  String? appVersion;
  if (data is Map<String, Object?>) {
    final v = data['packageVersion'];
    if (v is String) appVersion = v;
  }
  if (appVersion != null && appVersion != sleuthPackageVersionPin) {
    final lineageMismatch =
        versionLineage(appVersion) != versionLineage(sleuthPackageVersionPin);
    if (lineageMismatch) {
      // Envelope shape may differ across lineage boundary — refuse and
      // drop the bridge so later tools don't hit an incompatible app.
      await bridge.disconnect();
      return ToolCallResult.text(
        'version_skew_major: app=$appVersion sidecar-pin=$sleuthPackageVersionPin — '
        'refusing to serve; align sleuth dep with sidecar version. Bridge disconnected.',
        isError: true,
      );
    }
  }
  final connectResult = <String, Object?>{
    'connected': true,
    'vmServiceUri': uri,
    'sessionUuid': diag['sessionUuid'],
    'connectionMode': diag['connectionMode'],
    'sidecarVersion': sleuthMcpVersion,
    'appPackageVersion': appVersion,
  };
  if (appVersion != null && appVersion != sleuthPackageVersionPin) {
    connectResult['warning'] = 'version_skew_minor';
  }
  return connectResult;
}

Future<Object> _getSnapshotHandler(
  VmBridge bridge,
  Map<String, Object?> args,
) async {
  return _passThrough(bridge, 'ext.sleuth.snapshot');
}

Future<Object> _getIssuesHandler(
  VmBridge bridge,
  Map<String, Object?> args,
) async {
  final extArgs = <String, dynamic>{};
  final route = args['route'];
  if (route is String && route.isNotEmpty) {
    extArgs['route'] = route;
  }
  final envelope = await bridge.callExtension(
    'ext.sleuth.issues',
    args: extArgs,
  );
  final severityAtLeast = args['severityAtLeast'];
  if (severityAtLeast is! String) return envelope;
  final lower = severityAtLeast.toLowerCase();
  if (lower == 'ok') return envelope;
  final data = envelope['data'];
  if (data is! Map<String, Object?>) return envelope;
  final rawIssues = data['issues'];
  if (rawIssues is! List) return envelope;
  bool include(Object? severity) {
    if (severity is! String) return false;
    final s = severity.toLowerCase();
    if (lower == 'critical') return s == 'critical';
    if (lower == 'warning') return s == 'warning' || s == 'critical';
    return true;
  }

  final filtered = rawIssues
      .whereType<Map<String, Object?>>()
      .where((i) => include(i['severity']))
      .toList();
  final filteredData = Map<String, Object?>.from(data)
    ..['issues'] = filtered
    ..['severityAtLeast'] = lower;
  return Map<String, Object?>.from(envelope)..['data'] = filteredData;
}

Future<Object> _getRouteHealthHandler(
  VmBridge bridge,
  Map<String, Object?> args,
) async {
  final extArgs = <String, dynamic>{};
  final route = args['route'];
  if (route is String && route.isNotEmpty) extArgs['route'] = route;
  return _passThrough(bridge, 'ext.sleuth.routeHealth', extArgs);
}

Future<Object> _explainIssueHandler(
  VmBridge bridge,
  Map<String, Object?> args,
) async {
  final stableId = args['stableId'];
  if (stableId is! String || stableId.isEmpty) {
    return ToolCallResult.text(
      'missing_required_arg: stableId',
      isError: true,
    );
  }
  return _passThrough(bridge, 'ext.sleuth.explain', {'stableId': stableId});
}

Future<Object> _diagnoseHandler(
  VmBridge bridge,
  Map<String, Object?> args,
) async {
  final envelope = await bridge.callExtension('ext.sleuth.diagnose');
  final data = envelope['data'];
  if (data is! Map<String, Object?>) return envelope;
  final augmented = Map<String, Object?>.from(data)
    ..['sidecarVersion'] = sleuthMcpVersion
    ..['sidecarBuiltAgainstSleuth'] = sleuthPackageVersionPin;
  return Map<String, Object?>.from(envelope)..['data'] = augmented;
}

final Map<String, BuiltInTool> builtInTools = {
  'connect': BuiltInTool(
    descriptor: const Tool(
      name: 'connect',
      description:
          'Attach to a running Flutter app via its VM service WebSocket URI. '
          'Must be called before other tools.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'uri': {
            'type': 'string',
            'description':
                'WebSocket URI from flutter run output, e.g. ws://127.0.0.1:55555/<token>=/ws',
          },
        },
        'required': ['uri'],
      },
    ),
    handler: _connectHandler,
  ),
  'get_snapshot': BuiltInTool(
    descriptor: const Tool(
      name: 'get_snapshot',
      description:
          'Full performance snapshot — issues, frame stats, route history.',
      inputSchema: _emptyObjectSchema,
    ),
    handler: _getSnapshotHandler,
  ),
  'get_issues': BuiltInTool(
    descriptor: const Tool(
      name: 'get_issues',
      description:
          'Currently-aggregated performance issues. Optional route + severity filter.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'route': {'type': 'string'},
          'severityAtLeast': {
            'type': 'string',
            'enum': ['ok', 'warning', 'critical'],
          },
        },
        'required': <String>[],
      },
    ),
    handler: _getIssuesHandler,
  ),
  'get_route_health': BuiltInTool(
    descriptor: const Tool(
      name: 'get_route_health',
      description: 'Per-route health score + FPS + issue counts.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'route': {'type': 'string'},
        },
        'required': <String>[],
      },
    ),
    handler: _getRouteHealthHandler,
  ),
  'explain_issue': BuiltInTool(
    descriptor: const Tool(
      name: 'explain_issue',
      description:
          'Encyclopedia entry for a stableId (parametric variants resolve).',
      inputSchema: {
        'type': 'object',
        'properties': {
          'stableId': {'type': 'string', 'minLength': 1},
        },
        'required': ['stableId'],
      },
    ),
    handler: _explainIssueHandler,
  ),
  'compare_snapshots': BuiltInTool(
    descriptor: const Tool(
      name: 'compare_snapshots',
      description:
          'Pure client-side diff of two snapshots. No app call. Use for AI '
          'conversation context: did this code change regress performance?',
      inputSchema: {
        'type': 'object',
        'properties': {
          'before': {
            'type': 'object',
            'description': 'Snapshot envelope `data` (not the full envelope).',
          },
          'after': {
            'type': 'object',
            'description': 'Snapshot envelope `data` (not the full envelope).',
          },
        },
        'required': ['before', 'after'],
      },
    ),
    handler: compareSnapshotsHandler,
  ),
  'check_budgets': BuiltInTool(
    descriptor: const Tool(
      name: 'check_budgets',
      description:
          'Compare live snapshot against FPS / issue-count budgets. Returns '
          '{passed, violations}. For CI exit-code gating, use the `sleuth_check` '
          'one-shot binary instead.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'minFps': {'type': 'number'},
          'maxIssues': {'type': 'integer'},
          'maxCriticalIssues': {'type': 'integer'},
        },
        'required': ['minFps', 'maxIssues', 'maxCriticalIssues'],
      },
    ),
    handler: checkBudgetsHandler,
  ),
  'diagnose': BuiltInTool(
    descriptor: const Tool(
      name: 'diagnose',
      description: 'Operational health — package version, VM connection state, '
          'unbound extension names. Adds sidecar version + pin.',
      inputSchema: _emptyObjectSchema,
    ),
    handler: _diagnoseHandler,
  ),
};
