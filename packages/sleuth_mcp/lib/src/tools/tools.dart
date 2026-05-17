import 'dart:async';
import 'dart:io';

import 'package:synchronized/synchronized.dart';

import '../bridge/vm_bridge.dart';
import '../flutter_daemon/daemon_session.dart';
import '../mcp/mcp_server.dart';
import '../mcp/mcp_types.dart';
import '../util/device_filter.dart';
import '../util/version_lineage.dart';
import 'budgets.dart';
import 'compare_snapshots.dart';

final Lock _listDevicesLock = Lock();

// 3-second TTL cache for `flutter devices --machine` output. Bounds
// back-to-back agent calls that would otherwise each spend 4-5s in the
// subprocess and risk the 10s tool timeout on the second call.
List<Map<String, Object?>>? _devicesCache;
DateTime? _devicesCachedAt;
const Duration _devicesCacheTtl = Duration(seconds: 3);

Future<List<Map<String, Object?>>> _cachedListDevices() async {
  final at = _devicesCachedAt;
  final cached = _devicesCache;
  if (at != null &&
      cached != null &&
      DateTime.now().difference(at) < _devicesCacheTtl) {
    return cached;
  }
  final fresh = await DaemonSession.listDevices();
  _devicesCache = fresh;
  _devicesCachedAt = DateTime.now();
  return fresh;
}

class BuiltInTool {
  const BuiltInTool({
    required this.descriptor,
    required this.handler,
    this.bypassesGenericTimeout = false,
  });
  final Tool descriptor;
  final ToolHandler handler;

  /// Lifecycle tools (attach/detach/hot_reload/hot_restart) manage their
  /// own per-operation deadlines inside `DaemonSession` (attachTimeout,
  /// hotRestartTimeout, etc.) which legitimately exceed the dispatcher's
  /// generic `_toolTimeout`. Applying the generic timeout to them would
  /// time out an in-flight RPC, disconnect the bridge, and poison
  /// dispatch while the operation continues to completion — set this to
  /// true to skip both the generic timeout AND the post-timeout
  /// `bridge.disconnect()`.
  final bool bypassesGenericTimeout;
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

/// Builds the 6 attach-mode tools bound to [server]. Caller registers
/// them on the server alongside `builtInTools`.
///
/// Closure capture reads `server.daemonSession` lazily so tests can swap
/// the session via `setDaemonSession()` between calls.
Map<String, BuiltInTool> lifecycleTools(McpServer server) {
  ToolCallResult sessionMissing() => ToolCallResult.text(
        'internal: daemon session not initialized on this server',
        isError: true,
      );

  Future<Object> attachHandler(
      VmBridge bridge, Map<String, Object?> args) async {
    final session = server.daemonSession;
    if (session is! DaemonSession) return sessionMissing();
    final device = args['device'] as String?;
    final debugUrl = args['debugUrl'] as String?;
    try {
      final status = await session.attach(device: device, debugUrl: debugUrl);
      return status.toJson();
    } on StateError catch (e) {
      return ToolCallResult.text(e.message, isError: true);
    } on DaemonSessionException catch (e) {
      return ToolCallResult.text(e.message, isError: true);
    }
  }

  Future<Object> detachHandler(
      VmBridge bridge, Map<String, Object?> args) async {
    final session = server.daemonSession;
    if (session is! DaemonSession) return sessionMissing();
    await session.detach();
    return session.status.toJson();
  }

  Future<Object> statusHandler(
      VmBridge bridge, Map<String, Object?> args) async {
    final session = server.daemonSession;
    if (session is! DaemonSession) return sessionMissing();
    return session.status.toJson();
  }

  Future<Object> listDevicesHandler(
      VmBridge bridge, Map<String, Object?> args) async {
    final mobileOnly = args['mobileOnly'] != false;
    try {
      final devices = await _listDevicesLock.synchronized(_cachedListDevices);
      final filtered = mobileOnly
          ? devices.where(isMobileFlutterDevice).toList(growable: false)
          : devices;
      return <String, Object?>{
        'devices': filtered,
        'count': filtered.length,
        'filteredBy': mobileOnly ? 'mobile' : 'none',
      };
    } on DaemonSessionException catch (e) {
      return ToolCallResult.text(e.message, isError: true);
    } on ProcessException catch (e) {
      return ToolCallResult.text(
        'flutter not on PATH or failed to run: ${e.message}',
        isError: true,
      );
    }
  }

  Future<Object> hotReloadHandler(
      VmBridge bridge, Map<String, Object?> args) async {
    final session = server.daemonSession;
    if (session is! DaemonSession) return sessionMissing();
    try {
      final status = await session.hotReload();
      return status.toJson();
    } on StateError catch (e) {
      return ToolCallResult.text(e.message, isError: true);
    }
  }

  return {
    'attach_app': BuiltInTool(
      descriptor: const Tool(
        name: 'attach_app',
        description:
            'Attach to a running Flutter app via `flutter attach --machine`. '
            'Connects bridge to the app\'s VM service. Call before any '
            'diagnostic tools. Hot-restart after first attach is automatic.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'device': {
              'type': 'string',
              'description':
                  'Device id or name from list_devices. Required when more '
                      'than one device is connected.',
            },
            'debugUrl': {
              'type': 'string',
              'description':
                  'Escape hatch: connect directly to a known VM service '
                      'WebSocket URI, bypassing flutter daemon discovery. Takes '
                      'precedence over `device` if both are provided.',
            },
          },
          'required': <String>[],
        },
      ),
      handler: attachHandler,
      bypassesGenericTimeout: true,
    ),
    'detach_app': BuiltInTool(
      descriptor: const Tool(
        name: 'detach_app',
        description:
            'Detach from the current Flutter app and release the daemon '
            'child. Idempotent — safe to call when not attached.',
        inputSchema: _emptyObjectSchema,
      ),
      handler: detachHandler,
      bypassesGenericTimeout: true,
    ),
    'app_status': BuiltInTool(
      descriptor: const Tool(
        name: 'app_status',
        description:
            'Current attach state. Returns {attached, state, device, appId, '
            'sessionUuid, launchMode, mode, lastError}.',
        inputSchema: _emptyObjectSchema,
      ),
      handler: statusHandler,
    ),
    'list_devices': BuiltInTool(
      descriptor: const Tool(
        name: 'list_devices',
        description: 'List connected devices via `flutter devices --machine`. '
            'Defaults to mobile-category only (android + ios). Pass '
            '`mobileOnly: false` to include desktop/web/embedded.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'mobileOnly': {
              'type': 'boolean',
              'description':
                  'Filter to category=="mobile" (Android + iOS). Default true.',
            },
          },
          'required': <String>[],
        },
      ),
      handler: listDevicesHandler,
      bypassesGenericTimeout: true,
    ),
    'hot_reload': BuiltInTool(
      descriptor: const Tool(
        name: 'hot_reload',
        description:
            'Trigger flutter hot reload (`r`) on a daemon-spawn session. '
            'Preserves app state and sessionUuid. Not available on '
            'debugUrl sessions.',
        inputSchema: _emptyObjectSchema,
      ),
      handler: hotReloadHandler,
      bypassesGenericTimeout: true,
    ),
    // `hot_restart` deferred to v0.2.1: Android profile-mode VM service
    // does not re-register the main isolate within the bridge's
    // reconnect window after `app.restart`. Hot reload covers the common
    // dev-loop path; full restart users can `detach_app` + `attach_app`
    // manually until the underlying behavior is fully understood.
  };
}
