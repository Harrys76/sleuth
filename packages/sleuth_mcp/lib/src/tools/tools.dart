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

/// Outcome of inspecting a connect-time `ext.sleuth.diagnose` envelope
/// against [sleuthPackageVersionPin]. Drives both the bridge-layer
/// validator (refusal collapses the connection in place) and the tool
/// layer's warning-stamping branch for the connect tool's return shape.
enum _SkewClass {
  /// `packageVersion` exactly matches the sidecar pin.
  exact,

  /// Same major.minor lineage as the pin, differing patch — wire
  /// contract holds; emit `version_skew_minor` as advisory.
  sameLineagePatch,

  /// Cross-lineage drift that [acceptedPriorLineages] explicitly
  /// permits — emit `version_skew_prior_lineage` so an upgrading user
  /// knows the transition fallback is what kept the connection alive.
  toleratedCrossLineage,

  /// Lineage drift outside the accepted set — refuse to serve.
  refused,

  /// `packageVersion` was missing or non-String. Cannot prove
  /// wire-shape compatibility — fail closed.
  unknown,
}

_SkewClass _classifySkew(Map<String, Object?>? diagnoseEnvelope) {
  if (diagnoseEnvelope == null) return _SkewClass.unknown;
  final data = diagnoseEnvelope['data'];
  if (data is! Map<String, Object?>) return _SkewClass.unknown;
  final raw = data['packageVersion'];
  if (raw is! String || raw.isEmpty) return _SkewClass.unknown;
  if (raw == sleuthPackageVersionPin) return _SkewClass.exact;
  final appLineage = versionLineage(raw);
  final pinLineage = versionLineage(sleuthPackageVersionPin);
  if (appLineage == pinLineage) return _SkewClass.sameLineagePatch;
  if (acceptedPriorLineages.contains(appLineage)) {
    return _SkewClass.toleratedCrossLineage;
  }
  return _SkewClass.refused;
}

String _skewRefusalMessage(Map<String, Object?>? diag, String reason) {
  final data = diag?['data'];
  String? appVersion;
  if (data is Map<String, Object?>) {
    final v = data['packageVersion'];
    if (v is String) appVersion = v;
  }
  switch (reason) {
    case 'version_skew_unknown':
      return 'version_skew_unknown: diagnose envelope missing packageVersion '
          'stamp — cannot verify wire contract. Bridge disconnected.';
    default:
      return 'version_skew_major: app=${appVersion ?? '<missing>'} '
          'sidecar-pin=$sleuthPackageVersionPin — refusing to serve; align '
          'sleuth dep with sidecar version. Bridge disconnected.';
  }
}

/// Bridge-layer validator. Returns a refusal string when the diagnose
/// envelope reports a packageVersion the sidecar refuses to talk to;
/// returns null on exact, same-lineage patch, or accepted-prior-lineage
/// drift (warning surfacing is the tool layer's job).
///
/// The validator is the canonical chokepoint — bridge `_connectUnlocked`
/// invokes it after every successful connect/reconnect and disconnects
/// the bridge in place on non-null return.
Future<String?> defaultVersionSkewValidator(
  Map<String, Object?> diagnoseEnvelope,
) async {
  final clazz = _classifySkew(diagnoseEnvelope);
  switch (clazz) {
    case _SkewClass.exact:
    case _SkewClass.sameLineagePatch:
    case _SkewClass.toleratedCrossLineage:
      return null;
    case _SkewClass.unknown:
      return _skewRefusalMessage(diagnoseEnvelope, 'version_skew_unknown');
    case _SkewClass.refused:
      return _skewRefusalMessage(diagnoseEnvelope, 'version_skew_major');
  }
}

/// Tool-layer mirror of [defaultVersionSkewValidator]. Production
/// `RealVmBridge` wires the validator at the bridge layer (cannot be
/// bypassed by reconnect, debugUrl, or daemon-spawn). This helper still
/// runs at the tool layer so `FakeVmBridge` tests without a wired
/// validator get the same refusal, and so a future bridge that forgets
/// to wire the validator is still caught before a tool call dispatches.
/// Refusal messages MUST match [defaultVersionSkewValidator] exactly so
/// `connect` / `attach_app` catch paths handle both sources uniformly.
///
/// Returns the cached/fetched diagnose envelope on OK / minor /
/// accepted-prior lineage drift, or a [ToolCallResult] error after
/// disconnecting the bridge on major skew / missing packageVersion.
Future<({Map<String, Object?>? diagnose, ToolCallResult? refusal})>
    _enforceVersionSkew(VmBridge bridge) async {
  final diag = bridge.lastDiagnoseEnvelope ??
      await bridge.callExtension('ext.sleuth.diagnose');
  final clazz = _classifySkew(diag);
  switch (clazz) {
    case _SkewClass.exact:
    case _SkewClass.sameLineagePatch:
    case _SkewClass.toleratedCrossLineage:
      return (diagnose: diag, refusal: null);
    case _SkewClass.unknown:
      await bridge.disconnect();
      return (
        diagnose: null,
        refusal: ToolCallResult.text(
          _skewRefusalMessage(diag, 'version_skew_unknown'),
          isError: true,
        ),
      );
    case _SkewClass.refused:
      await bridge.disconnect();
      return (
        diagnose: null,
        refusal: ToolCallResult.text(
          _skewRefusalMessage(diag, 'version_skew_major'),
          isError: true,
        ),
      );
  }
}

/// Picks the warning string the connect tool should stamp on the response.
/// Returns null when no warning is appropriate.
String? _connectWarningFor(_SkewClass clazz) {
  switch (clazz) {
    case _SkewClass.sameLineagePatch:
      return 'version_skew_minor';
    case _SkewClass.toleratedCrossLineage:
      return 'version_skew_prior_lineage';
    case _SkewClass.exact:
    case _SkewClass.unknown:
    case _SkewClass.refused:
      return null;
  }
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
  try {
    await bridge.connect(parsed);
  } on VmBridgeException catch (e) {
    // Bridge-layer validator refused — surface as a tool-level error.
    // Fakes without a wired validator fall through to the tool-layer
    // `_enforceVersionSkew` below.
    if (e.message.startsWith('version_skew_')) {
      return ToolCallResult.text(e.message, isError: true);
    }
    rethrow;
  }
  final result = await _enforceVersionSkew(bridge);
  if (result.refusal != null) return result.refusal!;
  final diag = result.diagnose!;
  final data = diag['data'];
  String? appVersion;
  if (data is Map<String, Object?>) {
    final v = data['packageVersion'];
    if (v is String) appVersion = v;
  }
  final connectResult = <String, Object?>{
    'connected': true,
    'vmServiceUri': uri,
    'sessionUuid': diag['sessionUuid'],
    'connectionMode': diag['connectionMode'],
    'sidecarVersion': sleuthMcpVersion,
    'appPackageVersion': appVersion,
  };
  final warning = _connectWarningFor(_classifySkew(diag));
  if (warning != null) {
    connectResult['warning'] = warning;
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
  final hasRouteArg = route is String && route.isNotEmpty;
  if (hasRouteArg) extArgs['route'] = route;
  final envelope =
      await bridge.callExtension('ext.sleuth.routeHealth', args: extArgs);
  // Passthrough untouched for:
  //   - error envelopes (no `data` block);
  //   - absent-route shape (caller asked for the full route list and the
  //     wrapper logic only applies to single-match responses).
  if (!hasRouteArg) return envelope;
  if (envelope['error'] != null) return envelope;
  final data = envelope['data'];
  if (data is! Map<String, Object?>) return envelope;
  final hasRouteKey = data.containsKey('route');
  final hasRouteNameKey = data.containsKey('routeName');
  if (hasRouteKey && hasRouteNameKey) {
    // Defensive: under either the canonical v0.33 wrapper or the inline
    // v0.32 shape this state is impossible. Surface via the bridge logger
    // when available; never double-wrap.
    return envelope;
  }
  if (hasRouteKey) {
    // Canonical v0.33 shape — already wrapped, leave alone.
    return envelope;
  }
  if (hasRouteNameKey) {
    // v0.32 inline shape from an `acceptedPriorLineages` app. Wrap so the
    // sidecar's downstream consumers always see the canonical
    // `{route: <session>}` shape regardless of which lineage the app
    // speaks.
    final wrapped = Map<String, Object?>.from(data);
    final rewritten = Map<String, Object?>.from(envelope)
      ..['data'] = <String, Object?>{'route': wrapped};
    return rewritten;
  }
  // Ambiguous / empty match — return untouched.
  return envelope;
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
      // Bridge-layer refusal flows through `DaemonSession.attach`'s
      // `on VmBridgeException` catch, which wraps `version_skew_…` into
      // `lastError` as `'bridge connect failed: version_skew_…'`.
      // Surface that as `isError` so clients distinguish contract
      // refusal from generic attach failures (timeout, app.stop, etc.)
      // that share the same non-attached `status.toJson()` return path.
      if (!status.attached) {
        final lastError = status.lastError ?? '';
        if (lastError.contains('version_skew_')) {
          return ToolCallResult.text(lastError, isError: true);
        }
      }
      // Attach reaches `state: ready` only when `bridge.connect()`
      // succeeded — run the same skew check `connect` runs. Redundant
      // when `defaultVersionSkewValidator` is wired into the bridge;
      // covers fakes / future bridges that skip wiring.
      if (status.attached) {
        final result = await _enforceVersionSkew(bridge);
        if (result.refusal != null) {
          await session.detach();
          return result.refusal!;
        }
      }
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
