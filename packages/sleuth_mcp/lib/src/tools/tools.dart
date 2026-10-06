import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:synchronized/synchronized.dart';

import '../bridge/vm_bridge.dart';
import '../cli/attach_ios_command.dart' show IosTransport;
import '../cli/ios_attach_pipeline.dart'
    show IosAttachErrorKind, IosAttachException;
import '../flutter_daemon/daemon_session.dart';
import '../mcp/mcp_server.dart';
import '../mcp/mcp_types.dart';
import '../util/device_filter.dart';
import '../util/version_lineage.dart';
import 'budgets.dart';
import 'compare_snapshots.dart';
import 'issue_projection.dart';
import 'launch_mode_advisory.dart';
import 'snapshot_disk_handoff.dart';
import 'snapshot_sections.dart';

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

  /// `packageVersion` was missing, non-String, or not a semver
  /// `major.minor.patch`. Cannot prove wire-shape compatibility — fail
  /// closed.
  unknown,
}

_SkewClass _classifySkew(Map<String, Object?>? diagnoseEnvelope) {
  if (diagnoseEnvelope == null) return _SkewClass.unknown;
  final data = diagnoseEnvelope['data'];
  if (data is! Map<String, Object?>) return _SkewClass.unknown;
  final raw = data['packageVersion'];
  if (raw is! String) return _SkewClass.unknown;
  final appLineage = versionLineage(raw);
  if (appLineage == null) return _SkewClass.unknown;
  if (raw == sleuthPackageVersionPin) return _SkewClass.exact;
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
      final got = appVersion == null ? '' : ' (got "$appVersion")';
      return 'version_skew_unknown: diagnose envelope missing or malformed '
          'packageVersion stamp$got — cannot verify wire contract. Bridge '
          'disconnected.';
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
  final diag =
      bridge.lastDiagnoseEnvelope ??
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

/// Picks the warning string the `connect` and `attach_app` tools stamp on
/// their response. Returns null when no warning is appropriate.
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
  VmBridge bridge,
  Map<String, Object?> args,
) async {
  final uri = args['uri'];
  if (uri is! String || uri.isEmpty) {
    return ToolCallResult.text('missing_required_arg: uri', isError: true);
  }
  // `flutter run` prints an http URI; the bridge needs the ws form.
  Uri parsed;
  try {
    parsed = normalizeVmServiceUri(Uri.parse(uri.trim()));
  } on FormatException catch (e) {
    return ToolCallResult.text(
      'invalid_uri: ${e.message}. Pass the VM service URI that flutter run '
      'prints, such as http://127.0.0.1:50000/AbCd=/ or '
      'ws://127.0.0.1:50000/AbCd=/ws.',
      isError: true,
    );
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
  bool? vmConnected;
  if (data is Map<String, Object?>) {
    final v = data['packageVersion'];
    if (v is String) appVersion = v;
    final flag = data['vmConnected'];
    if (flag is bool) vmConnected = flag;
  }
  final connectResult = <String, Object?>{
    'connected': true,
    'vmServiceUri': parsed.toString(),
    'sessionUuid': diag['sessionUuid'],
    'connectionMode': diag['connectionMode'],
    // `basic` also covers a healthy VM-connected session, so pass the app's
    // own flag beside it.
    'vmConnected': vmConnected,
    'sidecarVersion': sleuthMcpVersion,
    'appPackageVersion': appVersion,
  };
  final warning = _connectWarningFor(_classifySkew(diag));
  if (warning != null) {
    connectResult['warning'] = warning;
  }
  final advisory = launchModeAdvisoryForEnvelope(diag);
  if (advisory != null) {
    connectResult['launchModeAdvisory'] = advisory;
  }
  return connectResult;
}

/// Disk-handoff store, shared across `get_snapshot` calls. Cleaned up on
/// `detach_app` and sidecar shutdown.
final snapshotDiskHandoff = SnapshotDiskHandoff();

/// `data._omittedSectionsHint` on a default `get_snapshot` result.
const String _omittedSectionsHint =
    'These sections are left out by default to keep the response small: '
    'per-frame data and raw sample buffers. Pass full: true for every '
    'section, or name the ones you need in sections.';

Future<Object> _getSnapshotHandler(
  VmBridge bridge,
  Map<String, Object?> args,
) async {
  final extArgs = <String, dynamic>{};

  // An empty list or a blank string names no sections, so the call gets
  // the default set, as if `sections` were absent.
  final rawSections = args['sections'];
  String? requestedSections;
  if (rawSections is List && rawSections.isNotEmpty) {
    requestedSections = rawSections.map((e) => '$e').join(',');
  } else if (rawSections is String && rawSections.trim().isNotEmpty) {
    requestedSections = rawSections;
  }
  final full = args['full'] == true;
  if (full && requestedSections != null) {
    return ToolCallResult.text(
      'arg_conflict: full: true returns every section, so it cannot be '
      'combined with sections. Pass full: true, or list the sections you '
      'need.',
      isError: true,
    );
  }
  final diskHandoff = args['diskHandoff'] == true;
  // An inline call that names no sections gets the default set, which
  // leaves out the per-frame and raw sample sections so the response fits
  // a client's budget. A disk handoff has no such budget, so it writes
  // every section unless `sections` is set.
  final defaultProjection = requestedSections == null && !full && !diskHandoff;
  if (requestedSections != null) {
    extArgs['sections'] = requestedSections;
  } else if (defaultProjection) {
    extArgs['sections'] = defaultSnapshotSections.join(',');
  }
  final maxIssueCount = args['maxIssueCount'];
  if (maxIssueCount != null) extArgs['maxIssueCount'] = '$maxIssueCount';
  final maxRouteCount = args['maxRouteCount'];
  if (maxRouteCount != null) extArgs['maxRouteCount'] = '$maxRouteCount';

  final projectionRequested = extArgs.isNotEmpty;
  final callerProjection =
      requestedSections != null ||
      maxIssueCount != null ||
      maxRouteCount != null;
  final envelope = await bridge.callExtension(
    'ext.sleuth.snapshot',
    args: extArgs,
  );

  // App errors carry a top-level `error` key — surface inline, never
  // disk-hand-off (would hide the error behind a file pointer).
  if (envelope.containsKey('error')) return envelope;

  final rawData = envelope['data'];
  final isFallback =
      projectionRequested &&
      rawData is Map<String, Object?> &&
      !rawData.containsKey('_projectedSections') &&
      !rawData.containsKey('_projectionApplied');

  if (isFallback && !diskHandoff && callerProjection) {
    // Pre-0.35 app ignored the projection args and returned the full
    // payload; inline it would overflow the response cap projection
    // exists to avoid. Refuse with guidance instead.
    return ToolCallResult.text(
      'projection_unsupported_by_app: the attached app predates snapshot '
      'projection (sleuth < 0.35), so projection args were ignored and the '
      'full payload would overflow the response. Re-request with '
      'diskHandoff: true, or upgrade the app to sleuth 0.35+.',
      isError: true,
    );
  }

  // Stamp fallback provenance so the payload is detectable as projected by
  // the sidecar, not the app. Build a fresh map and never change the
  // envelope the bridge returned (the fake bridge shares its instance
  // across calls).
  var out = envelope;
  if (isFallback) {
    out = <String, Object?>{
      ...envelope,
      'data': defaultProjection
          // The default set was the sidecar's own choice, so apply it here.
          ? _projectLocally(rawData, defaultSnapshotSections)
          : <String, Object?>{
              ...rawData,
              '_projectionApplied': 'by_sidecar_fallback',
            },
    };
  }

  if (defaultProjection) {
    final data = out['data'];
    if (data is Map<String, Object?>) {
      out = <String, Object?>{
        ...out,
        'data': <String, Object?>{
          ...data,
          '_omittedSections': heavySnapshotSections,
          '_omittedSectionsHint': _omittedSectionsHint,
        },
      };
    }
  }

  // Compact each currentIssue unless verbose. Fresh map (never mutate the
  // bridge envelope); runs before both the inline return and the disk write.
  if (args['verbose'] != true) {
    final data = out['data'];
    if (data is Map<String, Object?> && data['currentIssues'] is List) {
      out = <String, Object?>{
        ...out,
        'data': <String, Object?>{
          ...data,
          'currentIssues': [
            for (final i in data['currentIssues'] as List)
              if (i is Map<String, Object?>) compactIssue(i) else i,
          ],
        },
      };
    }
  }

  // Degraded-session nudge in `data`: a client reading get_snapshot (not just
  // connect/diagnose) is told VM-only detectors are suppressed.
  final advisory = launchModeAdvisoryForEnvelope(out);
  final outData = out['data'];
  if (advisory != null && outData is Map<String, Object?>) {
    out = <String, Object?>{
      ...out,
      'data': <String, Object?>{...outData, 'launchModeAdvisory': advisory},
    };
  }

  if (!diskHandoff) return out;
  try {
    return await snapshotDiskHandoff.write(out);
  } on StateError catch (e) {
    // Fail-closed: handoff refused because it couldn't lock the temp
    // dir/file to owner-only perms. Surface inline, no loose file.
    return ToolCallResult.text(
      'disk_handoff_failed: ${e.message}',
      isError: true,
    );
  }
}

/// [data] cut down to [sections] plus the metadata keys, stamped the way
/// the app stamps a projection, with `_projectionApplied:
/// by_sidecar_fallback`. Used when an app ignored the default projection.
Map<String, Object?> _projectLocally(
  Map<String, Object?> data,
  List<String> sections,
) {
  final keep = sections.toSet();
  return <String, Object?>{
    for (final entry in data.entries)
      if (keep.contains(entry.key) || !snapshotSectionKeys.contains(entry.key))
        entry.key: entry.value,
    '_projectedSections': List<String>.of(sections)..sort(),
    '_projectionApplied': 'by_sidecar_fallback',
  };
}

Future<Object> _getIssuesHandler(
  VmBridge bridge,
  Map<String, Object?> args,
) async {
  // `0` is the only unbounded sentinel; reject negatives here since
  // projectIssues is lenient on <=0. Validate before the round-trip.
  final int maxCount;
  final rawMaxCount = args['maxIssueCount'];
  if (rawMaxCount == null) {
    maxCount = 50;
  } else {
    final parsed = _asInt(rawMaxCount);
    if (parsed == null || parsed < 0) {
      return ToolCallResult.text(
        'arg_invalid_int: maxIssueCount must be a non-negative integer '
        '(0 = unbounded)',
        isError: true,
      );
    }
    maxCount = parsed;
  }

  final extArgs = <String, dynamic>{};
  final route = args['route'];
  if (route is String && route.isNotEmpty) {
    extArgs['route'] = route;
  }
  // An app older than sleuth 0.37 has no `vmConnected` in the issues payload,
  // and `basic` alone cannot tell a session without a VM link from a
  // connected one that has not janked since connect. For such an app read the
  // flag from diagnose first. The issues call runs last and outside the
  // fallback's catch, so a session rotation between the two calls fails the
  // issues call instead of being swallowed as a missing advisory.
  final fallbackDiagnose = _issuesPayloadHasVmConnected(bridge)
      ? null
      : await _diagnoseForIssuesAdvisory(bridge);
  final envelope = await bridge.callExtension(
    'ext.sleuth.issues',
    args: extArgs,
  );
  final data = envelope['data'];
  if (data is! Map<String, Object?>) return envelope;
  final rawIssues = data['issues'];
  if (rawIssues is! List) return envelope;

  // Optional severity gate: `warning` includes `critical`; `ok` / absent =
  // no gate.
  final severityAtLeast = args['severityAtLeast'];
  final lower = severityAtLeast is String
      ? severityAtLeast.toLowerCase()
      : null;
  bool included(Object? severity) {
    if (lower == null || lower == 'ok') return true;
    if (severity is! String) return false;
    final s = severity.toLowerCase();
    if (lower == 'critical') return s == 'critical';
    if (lower == 'warning') return s == 'warning' || s == 'critical';
    return true;
  }

  final filtered = rawIssues
      .whereType<Map<String, Object?>>()
      .where((i) => included(i['severity']))
      .toList();

  // Compact by default + cap to the top-N of the app's already-ranked order.
  // `verbose` keeps full fields; `maxIssueCount: 0` disables the cap.
  final verbose = args['verbose'] == true;
  final projected = projectIssues(
    filtered,
    verbose: verbose,
    maxCount: maxCount,
  );

  final newData = Map<String, Object?>.from(data)
    ..['issues'] = projected.issues;
  if (lower != null) newData['severityAtLeast'] = lower;
  if (projected.truncated) {
    newData['_truncated'] = true;
    newData['_totalCount'] = projected.total;
  }
  final advisory = _issuesAdvisory(envelope, fallbackDiagnose);
  if (advisory != null) newData['launchModeAdvisory'] = advisory;
  return Map<String, Object?>.from(envelope)..['data'] = newData;
}

/// Upper bound on the diagnose read behind the get_issues advisory, kept
/// well inside the generic tool timeout so a slow read costs the advisory
/// and not the issue list.
const Duration _issuesAdvisoryDiagnoseTimeout = Duration(seconds: 2);

/// Whether the connected app stamps `vmConnected` on `ext.sleuth.issues`,
/// which sleuth 0.37.0 added. Reads the bridge's last diagnose envelope; an
/// unreadable version counts as an older app.
bool _issuesPayloadHasVmConnected(VmBridge bridge) {
  final data = bridge.lastDiagnoseEnvelope?['data'];
  if (data is! Map<String, Object?>) return false;
  final version = data['packageVersion'];
  final lineage = version is String ? versionLineage(version) : null;
  if (lineage == null) return false;
  final parts = lineage.split('.').map(int.parse).toList();
  return parts[0] > 0 || parts[1] >= 37;
}

/// Reads `ext.sleuth.diagnose` for the get_issues advisory. An ordinary
/// bridge failure or a read slower than [_issuesAdvisoryDiagnoseTimeout]
/// returns null, which drops the advisory. [SessionChangedException] and a
/// version refusal (`version_skew_*`) propagate so the client sees them.
Future<Map<String, Object?>?> _diagnoseForIssuesAdvisory(
  VmBridge bridge,
) async {
  try {
    return await bridge
        .callExtension('ext.sleuth.diagnose')
        .timeout(_issuesAdvisoryDiagnoseTimeout);
  } on TimeoutException {
    return null;
  } on VmBridgeException catch (e) {
    if (e.message.startsWith('version_skew_')) rethrow;
    return null;
  }
}

/// Advisory for a get_issues [issues] envelope. The VM flag comes from the
/// payload, else from [diagnose] read on the same session. `basic` with no
/// readable flag gets no advisory, because the session may be healthy.
String? _issuesAdvisory(
  Map<String, Object?> issues,
  Map<String, Object?>? diagnose,
) {
  final mode = issues['connectionMode'];
  if (mode is! String) return null;
  final data = issues['data'];
  final payloadFlag = data is Map<String, Object?> ? data['vmConnected'] : null;
  if (payloadFlag is bool || mode != 'basic') {
    return launchModeAdvisoryFor(
      mode,
      vmConnected: payloadFlag is bool ? payloadFlag : null,
    );
  }
  if (diagnose == null) return null;
  final issuesUuid = issues['sessionUuid'];
  final diagnoseUuid = diagnose['sessionUuid'];
  if (issuesUuid is! String || diagnoseUuid is! String) return null;
  if (issuesUuid != diagnoseUuid) {
    // Never pair one session's VM flag with another session's issues.
    throw SessionChangedException(baseline: diagnoseUuid, current: issuesUuid);
  }
  final diagnoseData = diagnose['data'];
  final flag = diagnoseData is Map<String, Object?>
      ? diagnoseData['vmConnected']
      : null;
  if (flag is! bool) return null;
  return launchModeAdvisoryFor(mode, vmConnected: flag);
}

int? _asInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

Future<Object> _getRouteHealthHandler(
  VmBridge bridge,
  Map<String, Object?> args,
) async {
  // Every accepted lineage emits the `{route: <session>}` wrapper for a
  // single-route match, so the envelope passes through unmodified.
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
    return ToolCallResult.text('missing_required_arg: stableId', isError: true);
  }
  return _passThrough(bridge, 'ext.sleuth.explain', {'stableId': stableId});
}

Future<Object> _diagnoseHandler(
  VmBridge bridge,
  Map<String, Object?> args,
) async {
  final envelope = await bridge.callExtension('ext.sleuth.diagnose');
  final advisory = launchModeAdvisoryForEnvelope(envelope);
  final data = envelope['data'];
  if (data is! Map<String, Object?>) {
    // No `data` block (e.g. the disposed-controller `disconnected` envelope).
    // Still surface the advisory in its documented `data` location.
    if (advisory == null) return envelope;
    return Map<String, Object?>.from(envelope)
      ..['data'] = <String, Object?>{'launchModeAdvisory': advisory};
  }
  final augmented = Map<String, Object?>.from(data)
    ..['sidecarVersion'] = sleuthMcpVersion
    ..['sidecarBuiltAgainstSleuth'] = sleuthPackageVersionPin;
  if (advisory != null) {
    augmented['launchModeAdvisory'] = advisory;
  }
  return Map<String, Object?>.from(envelope)..['data'] = augmented;
}

/// Stamps an attach `status.toJson()` map from the post-attach diagnose
/// envelope: the same version-skew `warning` the `connect` tool returns
/// (`version_skew_minor` / `version_skew_prior_lineage`), and
/// `launchModeAdvisory` when `connectionMode` is degraded. [diag] is null on
/// the non-attached path, which yields neither.
Map<String, Object?> _withAttachStamps(
  Map<String, Object?> status,
  Map<String, Object?>? diag,
) {
  if (diag == null) return status;
  final warning = _connectWarningFor(_classifySkew(diag));
  if (warning != null) {
    status['warning'] = warning;
  }
  final advisory = launchModeAdvisoryForEnvelope(diag);
  if (advisory != null) {
    status['launchModeAdvisory'] = advisory;
  }
  return status;
}

final Map<String, BuiltInTool> builtInTools = {
  'connect': BuiltInTool(
    descriptor: const Tool(
      name: 'connect',
      annotations: ToolAnnotations(
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: true,
      ),
      description:
          'Connect to a running Flutter app by its VM service URI, when you '
          'already have the URI. attach_app also connects and can find the '
          'app by device, so use either one before the other tools. Accepts '
          'the http URI that flutter run prints and the ws form.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'uri': {
            'type': 'string',
            'description':
                'VM service URI from flutter run or flutter attach output, '
                'e.g. http://127.0.0.1:55555/<token>=/ or '
                'ws://127.0.0.1:55555/<token>=/ws',
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
      annotations: ToolAnnotations(readOnlyHint: true, openWorldHint: true),
      description:
          'Performance snapshot: issues, frame stats summary, route history, '
          'session summary and recurrence trends. By default the per-frame '
          'and raw sample sections (capturedFrames, recentFrames, '
          'recentRequests, heapSamples, phaseEvents, gcEvents, '
          'platformChannelEvents) are left out to keep the response small, '
          'and data._omittedSections lists them. Pass full: true for every '
          'section, or sections to pick exactly the ones you need. '
          'maxIssueCount and maxRouteCount cap those lists. diskHandoff '
          'writes the snapshot (every section unless sections is set) to a '
          'temp file and returns {path, sizeBytes, sha256} instead.',
      inputSchema: <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'sections': <String, Object?>{
            'type': 'array',
            'items': <String, Object?>{
              'type': 'string',
              'enum': snapshotSectionKeys,
            },
            'description':
                'Sections to include; metadata always returns. Omit for '
                'the default set, which leaves out the per-frame and raw '
                'sample sections.',
          },
          'full': <String, Object?>{
            'type': 'boolean',
            'default': false,
            'description':
                'Return every section, including per-frame and raw sample '
                'data. On a long session this can exceed a client\'s '
                'response budget; prefer sections, or diskHandoff. Cannot '
                'be combined with sections.',
          },
          'maxIssueCount': <String, Object?>{
            'type': 'integer',
            'description': 'Keep top-N already-ranked issues.',
          },
          'maxRouteCount': <String, Object?>{
            'type': 'integer',
            'description': 'Keep N most-recent routes by startedAt.',
          },
          'diskHandoff': <String, Object?>{
            'type': 'boolean',
            'description':
                'Write the envelope to a temp file, with every section '
                'unless sections is set; the response becomes {path, '
                'sizeBytes, sha256, _projectedSections?}.',
          },
          'verbose': <String, Object?>{
            'type': 'boolean',
            'default': false,
            'description':
                'Return full issue fields. Default false trims each '
                'currentIssue to the actionable subset.',
          },
        },
        'required': <String>[],
      },
    ),
    handler: _getSnapshotHandler,
  ),
  'get_issues': BuiltInTool(
    descriptor: const Tool(
      name: 'get_issues',
      annotations: ToolAnnotations(readOnlyHint: true, openWorldHint: true),
      description:
          'Currently-aggregated performance issues. Optional route + severity '
          'filter. Compact by default (actionable fields only, capped at 50); '
          'pass verbose for full fields, maxIssueCount to change the cap.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'route': {'type': 'string'},
          'severityAtLeast': {
            'type': 'string',
            'enum': ['ok', 'warning', 'critical'],
          },
          'maxIssueCount': {
            'type': 'integer',
            'default': 50,
            'description':
                'Keep top-N already-ranked issues. Default 50; '
                '0 means unbounded. Applies whether or not verbose is set.',
          },
          'verbose': {
            'type': 'boolean',
            'default': false,
            'description':
                'Return full issue fields instead of the compact '
                'actionable subset. Field shape only — the maxIssueCount cap '
                'still applies.',
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
      annotations: ToolAnnotations(readOnlyHint: true, openWorldHint: true),
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
      annotations: ToolAnnotations(readOnlyHint: true, openWorldHint: true),
      description:
          'Encyclopedia entry for a stableId (parametric variants resolve). '
          'On sleuth 0.37+ apps the route, widget and count text is filled '
          'from the matching live issue (neutral wording when none is '
          'live); sleuth 0.36 apps return raw placeholders such as '
          '{widgetName} and {routeName}.',
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
      annotations: ToolAnnotations(readOnlyHint: true, openWorldHint: false),
      description:
          'Pure client-side diff of two snapshots. No app call. Use for AI '
          'conversation context: did this code change regress performance? '
          'Issues aggregate per stableId (highest severity + count). Refuses '
          'snapshots from different sleuth lineages, with different VM '
          'coverage, or taken during warmup.',
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
      annotations: ToolAnnotations(readOnlyHint: true, openWorldHint: true),
      description:
          'Compare live snapshot against FPS / issue-count budgets. Returns '
          '{passed, violations}; refuses with coverage_degraded when the app '
          'has no VM service link (VM-only detectors never ran). For CI '
          'exit-code gating, use the `sleuth_check` one-shot binary instead.',
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
      annotations: ToolAnnotations(readOnlyHint: true, openWorldHint: true),
      description:
          'Operational health — package version, VM connection state, '
          'unbound extension names. Adds sidecar version + pin.',
      inputSchema: _emptyObjectSchema,
    ),
    handler: _diagnoseHandler,
  ),
};

/// Builds the 5 attach-mode tools bound to [server]. Caller registers
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
    VmBridge bridge,
    Map<String, Object?> args,
  ) async {
    final session = server.daemonSession;
    if (session is! DaemonSession) return sessionMissing();
    // Trim at boundary so whitespace-only values (`udid: ' '`) don't
    // pass `.isNotEmpty` and slip into iOS-direct routing.
    final device = (args['device'] as String?)?.trim();
    final debugUrl = (args['debugUrl'] as String?)?.trim();
    final udid = (args['udid'] as String?)?.trim();
    final bundle = (args['bundle'] as String?)?.trim();
    final transportRaw = (args['transport'] as String?)?.trim();
    final authOverride = (args['authOverride'] as String?)?.trim();
    final forceRelaunch = args['forceRelaunch'] == true;

    // iOS-direct path: drive the full attach-ios pipeline.
    if (udid != null && udid.isNotEmpty) {
      if ((device != null && device.isNotEmpty) ||
          (debugUrl != null && debugUrl.isNotEmpty)) {
        return _iosErrorEnvelope(
          'ios_ambiguous_args',
          '`udid` cannot be combined with `device` or `debugUrl`. Pick '
              'one routing mode.',
        );
      }
      if (bundle == null || bundle.isEmpty) {
        return _iosErrorEnvelope(
          'ios_missing_bundle',
          '`udid` requires `bundle` (iOS bundle identifier). Example: '
              '`com.example.app`.',
        );
      }
      IosTransport? transportOverride;
      switch (transportRaw) {
        case null:
        case '':
        case 'auto':
          transportOverride = null;
          break;
        case 'usb':
          transportOverride = IosTransport.wired;
          break;
        case 'wireless':
          transportOverride = IosTransport.wireless;
          break;
        default:
          return _iosErrorEnvelope(
            'ios_invalid_transport',
            '`transport` must be one of: auto, usb, wireless. Got '
                '`$transportRaw`.',
            data: const <String, Object?>{
              'allowed': ['auto', 'usb', 'wireless'],
            },
          );
      }
      try {
        final status = await session.attachViaIos(
          udid: udid,
          bundle: bundle,
          authOverride: authOverride,
          transportOverride: transportOverride,
          forceRelaunch: forceRelaunch,
        );
        Map<String, Object?>? diag;
        if (status.attached) {
          final result = await _enforceVersionSkew(bridge);
          if (result.refusal != null) {
            await session.detach();
            return result.refusal!;
          }
          diag = result.diagnose;
        } else {
          final lastError = status.lastError ?? '';
          if (lastError.contains('version_skew_')) {
            return ToolCallResult.text(lastError, isError: true);
          }
          if (lastError.startsWith('ios_vmservice_busy:')) {
            return _iosErrorEnvelope(
              'ios_vmservice_busy',
              lastError,
              data: const <String, Object?>{
                'remedy':
                    'swipe the app off the device home screen and '
                    'rerun attach_app; or rebuild the profile binary',
              },
            );
          }
          if (lastError.startsWith('ios_vmservice_unreachable:')) {
            return _iosErrorEnvelope(
              'ios_vmservice_unreachable',
              lastError,
              data: const <String, Object?>{
                'remedy':
                    'wait ~30s for mDNS cache to clear, or swipe '
                    'the app off the device and rerun attach_app',
              },
            );
          }
        }
        return _withAttachStamps(status.toJson(), diag);
      } on IosAttachException catch (e) {
        return _iosErrorEnvelope(
          _iosErrorKindToTypedName(e.kind),
          e.message,
          data: e.data,
        );
      } on StateError catch (e) {
        // `attach_in_progress` from the concurrency mutex gets the same
        // typed-envelope treatment as the other iOS-typed errors so MCP
        // clients introspecting `structured.error` see it uniformly.
        if (e.message.startsWith('attach_in_progress:')) {
          return _iosErrorEnvelope('attach_in_progress', e.message);
        }
        return ToolCallResult.text(e.message, isError: true);
      }
    }

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
      Map<String, Object?>? diag;
      if (status.attached) {
        final result = await _enforceVersionSkew(bridge);
        if (result.refusal != null) {
          await session.detach();
          return result.refusal!;
        }
        diag = result.diagnose;
      }
      return _withAttachStamps(status.toJson(), diag);
    } on StateError catch (e) {
      return ToolCallResult.text(e.message, isError: true);
    } on DaemonSessionException catch (e) {
      return ToolCallResult.text(e.message, isError: true);
    }
  }

  Future<Object> detachHandler(
    VmBridge bridge,
    Map<String, Object?> args,
  ) async {
    final session = server.daemonSession;
    if (session is! DaemonSession) return sessionMissing();
    await session.detach();
    snapshotDiskHandoff.cleanupAll();
    return session.status.toJson();
  }

  Future<Object> statusHandler(
    VmBridge bridge,
    Map<String, Object?> args,
  ) async {
    final session = server.daemonSession;
    if (session is! DaemonSession) return sessionMissing();
    return session.status.toJson();
  }

  Future<Object> listDevicesHandler(
    VmBridge bridge,
    Map<String, Object?> args,
  ) async {
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
    VmBridge bridge,
    Map<String, Object?> args,
  ) async {
    final session = server.daemonSession;
    if (session is! DaemonSession) return sessionMissing();
    // iOS-direct sessions bypass the flutter daemon, so the daemon's
    // `app.restart` RPC isn't reachable. Surface a typed error with a
    // remedy rather than a confusing StateError from the daemon path.
    if (session.status.launchMode == 'ios-direct') {
      return _iosErrorEnvelope(
        'hot_reload_unsupported',
        'hot_reload is not available on iOS-direct sessions '
            '(`attach_app(udid: ...)`). Re-attach via the flutter daemon '
            'using `attach_app(device: <name>)` to enable hot reload.',
        data: const <String, Object?>{
          'remedy':
              'detach_app then attach_app(device: <device-name>); the '
              'daemon path supports hot_reload',
        },
      );
    }
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
        annotations: ToolAnnotations(
          readOnlyHint: false,
          destructiveHint: false,
          idempotentHint: false,
          openWorldHint: true,
        ),
        description:
            'Attach to a running Flutter app. Three routing modes:\n'
            '  • `udid` (iOS UDID) — drives devicectl launch + Bonjour '
            'resolve + iproxy tunnel internally; one round-trip replaces '
            'the standalone `sleuth_mcp attach-ios` CLI. Requires `bundle`.\n'
            '  • `debugUrl` — direct WebSocket URI; bypasses both daemon '
            'and the iOS pipeline.\n'
            '  • `device` (name or id from list_devices) — routes via '
            '`flutter attach --machine` daemon (Android + iOS daemon path).\n'
            'Connects bridge to the app\'s VM service. Call before any '
            'diagnostic tools.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'device': {
              'type': 'string',
              'description':
                  'Device id or name from list_devices. Routes via flutter '
                  'daemon. Required when more than one device is connected '
                  'AND neither `udid` nor `debugUrl` is set.',
            },
            'debugUrl': {
              'type': 'string',
              'description':
                  'Escape hatch: connect directly to a known VM service '
                  'WebSocket URI, bypassing flutter daemon discovery.',
            },
            'udid': {
              'type': 'string',
              'description':
                  'iOS device UDID. When set, drives the iOS attach '
                  'pipeline directly (no flutter daemon). Requires `bundle`. '
                  'Mutually exclusive with `device` / `debugUrl`.',
            },
            'bundle': {
              'type': 'string',
              'description':
                  'iOS bundle identifier (required with `udid`). Example: '
                  '`com.example.app`.',
            },
            'transport': {
              'type': 'string',
              'enum': ['auto', 'usb', 'wireless'],
              'description':
                  'Override iOS transport auto-detection. `usb` forces '
                  'iproxy tunnel; `wireless` connects directly to '
                  '`.local` host; `auto` (default) inspects `xcrun '
                  'devicectl list devices`.',
            },
            'authOverride': {
              'type': 'string',
              'description':
                  'iOS only: pin the Bonjour authCode (used when more '
                  'than one pairing is announced — see error '
                  '`ios_ambiguous_pairings`).',
            },
            'forceRelaunch': {
              'type': 'boolean',
              'default': false,
              'description':
                  'iOS only: skip the Bonjour probe and drive a fresh '
                  '`xcrun devicectl process launch`. Recovers from a '
                  'stale mDNS cache pinning a dead VM service port '
                  '(`ios_vmservice_busy` / `ios_vmservice_unreachable`) '
                  'without a sidecar restart.',
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
        annotations: ToolAnnotations(
          readOnlyHint: false,
          destructiveHint: true,
          idempotentHint: true,
          openWorldHint: true,
        ),
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
        annotations: ToolAnnotations(readOnlyHint: true, openWorldHint: false),
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
        annotations: ToolAnnotations(readOnlyHint: true, openWorldHint: true),
        description:
            'List connected devices via `flutter devices --machine`. '
            'Defaults to mobile-category only (android + ios). Pass '
            '`mobileOnly: false` to include desktop/web/embedded.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'mobileOnly': {
              'type': 'boolean',
              'default': true,
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
        annotations: ToolAnnotations(
          readOnlyHint: false,
          destructiveHint: false,
          idempotentHint: false,
          openWorldHint: true,
        ),
        description:
            'Trigger flutter hot reload (`r`) on a daemon-spawn session. '
            'Preserves app state and sessionUuid. Not available on '
            'debugUrl sessions.',
        inputSchema: _emptyObjectSchema,
      ),
      handler: hotReloadHandler,
      bypassesGenericTimeout: true,
    ),
    // There is no `hot_restart` tool: in Android profile mode the new main
    // isolate does not register again within the bridge's reconnect window
    // after `app.restart`. Use `detach_app` and then `attach_app`.
  };
}

/// Map [IosAttachErrorKind] to a stable typed-error name surfaced over
/// the MCP envelope. The names are part of the tool contract — bump
/// the `mcp_tool_schema.json` lock when adding or renaming.
String _iosErrorKindToTypedName(IosAttachErrorKind kind) {
  switch (kind) {
    case IosAttachErrorKind.missingTool:
      return 'ios_missing_tool';
    case IosAttachErrorKind.launchFailed:
      return 'ios_launch_failed';
    case IosAttachErrorKind.bonjourTimeout:
      return 'ios_bonjour_timeout';
    case IosAttachErrorKind.ambiguousPairings:
      return 'ios_ambiguous_pairings';
    case IosAttachErrorKind.noMatchingAuth:
      return 'ios_no_matching_auth';
    case IosAttachErrorKind.iproxyFailedSpawn:
      return 'ios_iproxy_failed';
    case IosAttachErrorKind.iproxyReadinessFailed:
      return 'ios_iproxy_failed';
    case IosAttachErrorKind.cancelled:
      return 'ios_cancelled';
  }
}

/// Construct an iOS-typed error envelope. The text content carries
/// the typed name + message so clients without structured-error
/// parsing still see a useful string; the structured `data` block
/// carries the error name + supplemental info (remedy, allowed
/// values, etc.) for clients that introspect.
ToolCallResult _iosErrorEnvelope(
  String errorName,
  String message, {
  Map<String, Object?>? data,
}) {
  final payload = <String, Object?>{
    'error': errorName,
    'message': message,
    ...?data,
  };
  // Serialise as text content (MCP standard for error envelopes is
  // text-with-isError); embed JSON so structured consumers can parse.
  // See doc/mcp_tool_schema.md → attach_app errors.
  return ToolCallResult(
    isError: true,
    content: [
      {'type': 'text', 'text': '$errorName: $message'},
      {'type': 'text', 'text': _encodeIosErrorData(payload)},
    ],
  );
}

String _encodeIosErrorData(Map<String, Object?> payload) {
  try {
    return _iosErrorJsonEncoder.convert(payload);
  } catch (_) {
    return '{"error":"${payload['error']}"}';
  }
}

final _iosErrorJsonEncoder = JsonEncoder();
