import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:synchronized/synchronized.dart';

import '../bridge/vm_bridge.dart';
import '../cli/attach_ios_command.dart' show IosTransport;
import '../cli/ios_attach_pipeline.dart'
    show IosAttachErrorKind, IosAttachException, IosAttachPhase;
import '../flutter_daemon/app_status.dart';
import '../flutter_daemon/daemon_session.dart';
import '../mcp/mcp_server.dart';
import '../mcp/mcp_types.dart';
import '../mcp/tool_call_context.dart';
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
      return 'version_skew_unknown: the diagnose envelope has a missing or '
          'malformed packageVersion$got, so the sidecar cannot verify the '
          'wire contract. The sidecar disconnected the bridge.';
    default:
      return 'version_skew_major: app=${appVersion ?? '<missing>'} '
          'sidecar-pin=$sleuthPackageVersionPin. The app\'s sleuth version '
          'is outside the lineages this sidecar accepts, so the sidecar '
          'refuses to serve it and disconnected the bridge. Align the '
          'app\'s sleuth dependency with the sidecar version.';
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
    'The default call leaves out these per-frame and raw sample sections '
    'to keep the response small. Pass full: true for every section, or '
    'name the ones you need in sections.';

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
      'projection_unsupported_by_app: the attached app runs a sleuth '
      'version older than 0.35, which has no snapshot projection. The app '
      'ignored the projection args, and its full payload would overflow '
      'the response. Request again with diskHandoff: true, or upgrade the '
      'app to sleuth 0.35 or later.',
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
  return writeSnapshotHandoff(snapshotDiskHandoff, out);
}

/// Writes [out] through [handoff] for `get_snapshot(diskHandoff: true)` and
/// returns the pointer, or a `disk_handoff_failed` error when nothing could
/// be written. A request the client already cancelled writes nothing.
@visibleForTesting
Future<Object> writeSnapshotHandoff(
  SnapshotDiskHandoff handoff,
  Map<String, Object?> out,
) async {
  if (ToolCallContext.current?.isCancelled ?? false) {
    // The client gave up on this request and never gets a response, so it
    // would never learn the path. Write nothing.
    return ToolCallResult.text(
      'cancelled: the client cancelled the request before the snapshot '
      'was written',
      isError: true,
    );
  }
  try {
    return await handoff.write(out);
  } on StateError catch (e) {
    // Fail-closed: handoff refused because it couldn't lock the temp
    // dir/file to owner-only perms, or the sidecar is shutting down.
    // Surface inline, no loose file.
    return ToolCallResult.text(
      'disk_handoff_failed: ${e.message}',
      isError: true,
    );
  } on FileSystemException catch (e) {
    return ToolCallResult.text(
      'disk_handoff_failed: the sidecar could not write the snapshot file: '
      '${e.message}${e.path == null ? '' : ' (${e.path})'}',
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
        'arg_invalid_int: maxIssueCount must be a non-negative integer. '
        '0 means no cap.',
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
          'the http URI that flutter run prints and the ws form. While an '
          'attach_app session is attached or attaching, connect refuses '
          'with attached_session; call detach_app first.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'uri': {
            'type': 'string',
            'description':
                'The VM service URI that flutter run or flutter attach '
                'prints, such as http://127.0.0.1:55555/<token>=/ or '
                'ws://127.0.0.1:55555/<token>=/ws.',
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
          'Returns a performance snapshot with the issues, a frame stats '
          'summary, the route history, a session summary and recurrence '
          'trends. To keep the response small, the default call leaves out '
          'the per-frame and raw sample sections (capturedFrames, '
          'recentFrames, recentRequests, heapSamples, phaseEvents, gcEvents, '
          'platformChannelEvents) and lists them in data._omittedSections. '
          'Pass full: true for every section, or sections to pick exactly '
          'the ones you need. maxIssueCount and maxRouteCount cap the issue '
          'and route lists. diskHandoff writes the snapshot to a temp file, '
          'with every section unless sections is set, and returns {path, '
          'sizeBytes, sha256} instead.',
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
                'Sections to include. The metadata keys always come back. '
                'Omit it for the default set, which leaves out the '
                'per-frame and raw sample sections.',
          },
          'full': <String, Object?>{
            'type': 'boolean',
            'default': false,
            'description':
                'Return every section, including per-frame and raw sample '
                'data. On a long session this can exceed a client\'s '
                'response budget, so prefer sections or diskHandoff. Do not '
                'combine it with sections.',
          },
          'maxIssueCount': <String, Object?>{
            'type': 'integer',
            'description':
                'Keep the first N issues in the app\'s ranked order.',
          },
          'maxRouteCount': <String, Object?>{
            'type': 'integer',
            'description': 'Keep the N routes with the latest startedAt.',
          },
          'diskHandoff': <String, Object?>{
            'type': 'boolean',
            'description':
                'Write the envelope to a temp file, with every section '
                'unless sections is set. The response is then {path, '
                'sizeBytes, sha256}, plus _projectedSections when the '
                'snapshot was projected.',
          },
          'verbose': <String, Object?>{
            'type': 'boolean',
            'default': false,
            'description':
                'Return every issue field. The default, false, trims each '
                'currentIssues entry to the actionable subset.',
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
          'Returns the performance issues the app currently reports. '
          'route and severityAtLeast filter the list. By default each issue '
          'keeps only its actionable fields, and the list stops at 50 '
          'issues. Pass verbose for every field, or maxIssueCount to change '
          'the cap.',
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
                'Keep the first N issues in the app\'s ranked order. '
                'Default 50, and 0 means no cap. The cap applies whether '
                'or not verbose is set.',
          },
          'verbose': {
            'type': 'boolean',
            'default': false,
            'description':
                'Return every issue field instead of the compact '
                'actionable subset. It changes the fields only, so the '
                'maxIssueCount cap still applies.',
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
      description:
          'Returns the health score, FPS and issue counts of each route. '
          'Pass route for one route.',
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
          'Returns the encyclopedia entry for a stableId. Parametric '
          'stableIds also resolve. On sleuth 0.37 and later, the app fills '
          'the route, widget and count text from the matching live issue, '
          'or uses neutral wording when none is live. Sleuth 0.36 apps '
          'return raw placeholders such as {widgetName} and {routeName}.',
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
          'Diffs two snapshots in the sidecar without calling the app. Use '
          'it to check whether a code change made performance worse. It '
          'groups issues per stableId and keeps the highest severity and '
          'the occurrence count. It refuses snapshots from different sleuth '
          'lineages, snapshots with different VM coverage, and snapshots '
          'taken during warmup.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'before': {
            'type': 'object',
            'description':
                'The `data` object of a snapshot envelope, not the whole '
                'envelope.',
          },
          'after': {
            'type': 'object',
            'description':
                'The `data` object of a snapshot envelope, not the whole '
                'envelope.',
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
          'Checks a live snapshot against FPS and issue-count budgets and '
          'returns {passed, violations}. It refuses with coverage_degraded '
          'when the app has no VM service link, because the VM-only '
          'detectors never ran. Every threshold is optional and defaults to '
          'the sleuth_check default: minFps 55, maxIssues 999999 (no '
          'practical limit) and maxCriticalIssues 0. For a CI gate that '
          'sets the exit code, use the one-shot `sleuth_check` binary '
          'instead.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'minFps': {
            'type': 'number',
            'default': defaultMinFps,
            'description': 'Lowest acceptable average FPS. Default 55.',
          },
          'maxIssues': {
            'type': 'integer',
            'default': defaultMaxIssues,
            'description':
                'Most issues allowed. Default 999999, which sets no '
                'practical limit.',
          },
          'maxCriticalIssues': {
            'type': 'integer',
            'default': defaultMaxCriticalIssues,
            'description': 'Most critical issues allowed. Default 0.',
          },
        },
        'required': <String>[],
      },
    ),
    handler: checkBudgetsHandler,
  ),
  'diagnose': BuiltInTool(
    descriptor: const Tool(
      name: 'diagnose',
      annotations: ToolAnnotations(readOnlyHint: true, openWorldHint: true),
      description:
          'Reports the app\'s operational health: the sleuth package '
          'version, the VM connection state and the names of unbound '
          'extensions. The sidecar adds its own version and the sleuth '
          'version it pins.',
      inputSchema: _emptyObjectSchema,
    ),
    handler: _diagnoseHandler,
  ),
};

/// Builds the attach-mode tools bound to [server]. Caller registers
/// them on the server alongside `builtInTools`.
///
/// It also builds the `connect` tool that the server serves: the built-in
/// one plus a refusal while an `attach_app` session owns the connection.
/// The server registers these tools after `builtInTools`, so this one
/// replaces the built-in `connect`.
///
/// Closure capture reads `server.daemonSession` lazily so tests can swap
/// the session via `setDaemonSession()` between calls.
Map<String, BuiltInTool> lifecycleTools(McpServer server) {
  ToolCallResult sessionMissing() => ToolCallResult.text(
    'internal: daemon session not initialized on this server',
    isError: true,
  );

  // Refusing is safer than detaching the attach first: a detach stops a
  // flutter attach child or an iOS tunnel the user may still want, can take
  // up to seven seconds, and connect runs under the generic tool timeout,
  // which would answer while that detach still ran. The refusal names the
  // explicit step instead.
  Future<Object> connectHandler(
    VmBridge bridge,
    Map<String, Object?> args,
  ) async {
    final session = server.daemonSession;
    if (session is DaemonSession && session.ownsConnection) {
      final status = session.status;
      final via = status.connectedVia;
      return _typedErrorEnvelope(
        'attached_session',
        'an attach_app session owns the connection (state=${status.state}'
            '${via == null ? '' : ', connectedVia=$via'}). connect would '
            'point the bridge at another app while that session keeps '
            'running, so hot_reload would reload one app while the other '
            'tools read another. Call detach_app first, then connect.',
        data: <String, Object?>{
          'remedy': 'Call detach_app, then connect(uri).',
          'status': status.toJson(),
        },
      );
    }
    return _connectHandler(bridge, args);
  }

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

    // Progress and cancellation from the `tools/call` request, when the
    // handler runs inside one.
    final context = ToolCallContext.current;
    final cancelSignal = context?.cancelled.asStream();
    void progress(String message) => context?.reportProgress(message);

    // iOS-direct path: drive the full attach-ios pipeline.
    if (udid != null && udid.isNotEmpty) {
      if ((device != null && device.isNotEmpty) ||
          (debugUrl != null && debugUrl.isNotEmpty)) {
        return _typedErrorEnvelope(
          'ios_ambiguous_args',
          '`udid` cannot be combined with `device` or `debugUrl`. Pick '
              'one routing mode.',
        );
      }
      if (bundle == null || bundle.isEmpty) {
        return _typedErrorEnvelope(
          'ios_missing_bundle',
          '`udid` requires `bundle`, the iOS bundle identifier, such as '
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
          return _typedErrorEnvelope(
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
          onProgress: (phase, {data}) =>
              progress(_iosPhaseMessage(phase, data)),
          cancelSignal: cancelSignal,
        );
        return await _finishAttach(session, bridge, status, context);
      } on IosAttachException catch (e) {
        return _typedErrorEnvelope(
          _iosErrorKindToTypedName(e.kind),
          e.message,
          data: e.data,
        );
      } on StateError catch (e) {
        // `attach_in_progress` from the concurrency mutex gets the same
        // typed-envelope treatment as the other iOS-typed errors so MCP
        // clients introspecting `structured.error` see it uniformly.
        if (e.message.startsWith('attach_in_progress:')) {
          return _typedErrorEnvelope('attach_in_progress', e.message);
        }
        return ToolCallResult.text(e.message, isError: true);
      }
    }

    try {
      final status = await session.attach(
        device: device,
        debugUrl: debugUrl,
        onProgress: progress,
        cancelSignal: cancelSignal,
      );
      return await _finishAttach(session, bridge, status, context);
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
    try {
      await session.detach();
    } finally {
      snapshotDiskHandoff.deleteFiles();
    }
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
    final before = session.status;
    // iOS-direct sessions bypass the flutter daemon, so the daemon's
    // `app.restart` RPC isn't reachable. Surface a typed error with a
    // remedy rather than a confusing StateError from the daemon path.
    if (before.launchMode == 'ios-direct') {
      return _typedErrorEnvelope(
        'hot_reload_unsupported',
        'hot_reload is not available on iOS-direct sessions '
            '(`attach_app(udid: ...)`). Re-attach via the flutter daemon '
            'using `attach_app(device: <name>)` to enable hot reload.',
        data: const <String, Object?>{
          'remedy':
              'Call detach_app, then attach_app(device: <device-name>). '
              'The daemon path supports hot_reload.',
        },
      );
    }
    // debugUrl and connect sessions have no flutter daemon either. Their
    // connection keeps working, so refuse without touching the session.
    final via = before.connectedVia;
    if (via == ConnectedVia.attachDebugUrl ||
        (via == ConnectedVia.connect &&
            before.state == AppSessionState.idle.name)) {
      return _hotReloadUnsupported(
        via == ConnectedVia.attachDebugUrl
            ? 'attach_app(debugUrl:)'
            : 'connect',
      );
    }
    try {
      final after = await session.hotReload();
      if (after.state != AppSessionState.ready.name) {
        return _typedErrorEnvelope(
          'hot_reload_failed',
          after.lastError ?? 'hot reload did not finish (state=${after.state})',
          data: <String, Object?>{'status': after.toJson()},
        );
      }
      return after.toJson();
    } on StateError catch (e) {
      if (e.message.startsWith('hot_reload_unsupported:')) {
        return _hotReloadUnsupported('attach_app without a flutter daemon');
      }
      return ToolCallResult.text(e.message, isError: true);
    } on DaemonSessionException catch (e) {
      return _typedErrorEnvelope(
        'hot_reload_failed',
        e.message,
        data: <String, Object?>{'status': session.status.toJson()},
      );
    }
  }

  Future<Object> getLogsHandler(
    VmBridge bridge,
    Map<String, Object?> args,
  ) async {
    final session = server.daemonSession;
    if (session is! DaemonSession) return sessionMissing();
    final logs = session.appLogs;
    var maxLines = _defaultLogLines;
    final rawMaxLines = args['maxLines'];
    if (rawMaxLines != null) {
      final parsed = _asInt(rawMaxLines);
      if (parsed == null || parsed < 1) {
        return ToolCallResult.text(
          'arg_invalid_int: maxLines must be a positive integer',
          isError: true,
        );
      }
      maxLines = parsed < logs.capacity ? parsed : logs.capacity;
    }
    final filter = args['filter'];
    final result = logs.query(
      maxLines: maxLines,
      filter: filter is String ? filter : null,
    );
    return <String, Object?>{
      'lines': [for (final line in result.lines) line.toJson()],
      'count': result.lines.length,
      'matchedCount': result.matched,
      'bufferedCount': logs.length,
      'droppedCount': logs.droppedCount,
      'capturing': session.logCapture,
    };
  }

  final builtInConnect = builtInTools['connect']!;
  return {
    'connect': BuiltInTool(
      descriptor: builtInConnect.descriptor,
      handler: connectHandler,
      bypassesGenericTimeout: builtInConnect.bypassesGenericTimeout,
    ),
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
            'Attach to a running Flutter app and connect the bridge to its '
            'VM service. Call it before the diagnostic tools. The arguments '
            'pick one of three routing modes. `udid`, an iOS device UDID, '
            'needs `bundle`. With it, the sidecar runs the devicectl launch, '
            'the Bonjour lookup and the iproxy tunnel itself, so one call '
            'does the work of the standalone `sleuth_mcp attach-ios` CLI. '
            '`debugUrl` is a VM service WebSocket URI. The sidecar connects '
            'to it directly and skips both the flutter daemon and the iOS '
            'pipeline. `device`, a name or id from list_devices, attaches '
            'through the flutter daemon with `flutter attach --machine`, on '
            'Android and iOS. A failed attach returns isError with code '
            'attach_failed. When the request carries a progressToken, each '
            'stage sends notifications/progress, and notifications/cancelled '
            'stops the attach and releases what it started.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'device': {
              'type': 'string',
              'description':
                  'A device id or name from list_devices. The attach goes '
                  'through the flutter daemon. Required when more than one '
                  'device is connected and neither `udid` nor `debugUrl` is '
                  'set.',
            },
            'debugUrl': {
              'type': 'string',
              'description':
                  'A VM service WebSocket URI you already know. The '
                  'sidecar connects to it directly and skips flutter '
                  'daemon discovery.',
            },
            'udid': {
              'type': 'string',
              'description':
                  'An iOS device UDID. When it is set, the sidecar runs the '
                  'iOS attach pipeline itself, without the flutter daemon. '
                  'It requires `bundle` and cannot be combined with '
                  '`device` or `debugUrl`. It works on macOS only.',
            },
            'bundle': {
              'type': 'string',
              'description':
                  'The iOS bundle identifier, such as `com.example.app`. '
                  'Required with `udid`.',
            },
            'transport': {
              'type': 'string',
              'enum': ['auto', 'usb', 'wireless'],
              'description':
                  'Overrides iOS transport detection. `usb` forces the '
                  'iproxy tunnel. `wireless` connects straight to the '
                  '`.local` host. `auto`, the default, reads `xcrun '
                  'devicectl list devices`.',
            },
            'authOverride': {
              'type': 'string',
              'description':
                  'iOS only. Pins the Bonjour authCode when more than one '
                  'pairing is announced. See the `ios_ambiguous_pairings` '
                  'error.',
            },
            'forceRelaunch': {
              'type': 'boolean',
              'default': false,
              'description':
                  'iOS only. Skips the Bonjour probe and runs a fresh '
                  '`xcrun devicectl process launch`. Use it when a stale '
                  'mDNS cache points at a dead VM service port '
                  '(`ios_vmservice_busy` or `ios_vmservice_unreachable`). '
                  'It recovers without a sidecar restart.',
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
            'Ends the session. It stops the flutter attach child or the '
            'iproxy tunnel, disconnects the bridge (including one opened '
            'with connect), clears the get_logs buffer and deletes '
            'disk-handoff files. It is idempotent, so calling it when '
            'nothing is attached is safe.',
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
            'Reports the current attach and connection state. It returns '
            '{attached, state, connected, connectedVia, device, appId, '
            'sessionUuid, '
            'launchMode, mode, lastError}, plus transportMode and wsUri on '
            'iOS-direct sessions. attached is true only for an attach_app '
            'session in state ready whose bridge is still connected. '
            'connected and connectedVia also report a connection opened '
            'with connect.',
        inputSchema: _emptyObjectSchema,
      ),
      handler: statusHandler,
    ),
    'list_devices': BuiltInTool(
      descriptor: const Tool(
        name: 'list_devices',
        annotations: ToolAnnotations(readOnlyHint: true, openWorldHint: true),
        description:
            'Lists connected devices from `flutter devices --machine`. By '
            'default it returns only mobile devices (Android and iOS). Pass '
            '`mobileOnly: false` to include desktop, web and embedded '
            'devices.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'mobileOnly': {
              'type': 'boolean',
              'default': true,
              'description':
                  'Keep only devices whose category is "mobile" (Android '
                  'and iOS). Default true.',
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
            'Trigger flutter hot reload (`r`) on a session attached with '
            'attach_app(device:). It keeps the app state and sessionUuid. '
            'debugUrl, iOS-direct and connect sessions have no flutter '
            'daemon and return hot_reload_unsupported. A rejected or '
            'failed reload returns isError with code hot_reload_failed.',
        inputSchema: _emptyObjectSchema,
      ),
      handler: hotReloadHandler,
      bypassesGenericTimeout: true,
    ),
    // There is no `hot_restart` tool: in Android profile mode the new main
    // isolate does not register again within the bridge's reconnect window
    // after `app.restart`. Use `detach_app` and then `attach_app`.
    'get_logs': BuiltInTool(
      descriptor: const Tool(
        name: 'get_logs',
        annotations: ToolAnnotations(readOnlyHint: true, openWorldHint: false),
        description:
            'Returns recent output of the connected app: print and stderr '
            'lines and dart:developer log records from the VM service, or '
            'flutter daemon app.log lines while those streams are not '
            'available. It gives the newest maxLines lines (default 100), '
            'oldest first. filter keeps lines containing the text, ignoring '
            'case. The sidecar keeps the last 500 lines, and droppedCount '
            'says how many older lines it evicted.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'maxLines': {
              'type': 'integer',
              'default': _defaultLogLines,
              'minimum': 1,
              'description':
                  'Most lines to return, newest kept. Default 100; values '
                  'above the 500-line buffer return the whole buffer.',
            },
            'filter': {
              'type': 'string',
              'description':
                  'Keep only lines whose text contains this text, ignoring '
                  'case.',
            },
          },
          'required': <String>[],
        },
      ),
      handler: getLogsHandler,
    ),
  };
}

/// `get_logs` default for `maxLines`.
const int _defaultLogLines = 100;

/// Shared tail of `attach_app`: turns a non-attached status into an error,
/// runs the version check, and undoes an attach whose request the client
/// cancelled while the check ran.
Future<Object> _finishAttach(
  DaemonSession session,
  VmBridge bridge,
  AppStatusPayload status,
  ToolCallContext? context,
) async {
  final generation = session.generation;
  if (!status.attached) {
    // Bridge-layer refusal flows through the session's connect catch,
    // which wraps `version_skew_…` into `lastError`. Surface it with the
    // same text `connect` uses, so clients can tell a contract refusal
    // from other attach failures.
    final lastError = status.lastError ?? '';
    if (lastError.contains('version_skew_')) {
      return ToolCallResult.text(lastError, isError: true);
    }
    if (lastError.startsWith('ios_vmservice_busy:')) {
      return _typedErrorEnvelope(
        'ios_vmservice_busy',
        lastError,
        data: const <String, Object?>{
          'remedy':
              'Swipe the app off the device home screen and rerun '
              'attach_app, or rebuild the profile binary.',
        },
      );
    }
    if (lastError.startsWith('ios_vmservice_unreachable:')) {
      return _typedErrorEnvelope(
        'ios_vmservice_unreachable',
        lastError,
        data: const <String, Object?>{
          'remedy':
              'Wait about 30 s for the mDNS cache to clear, or swipe the '
              'app off the device and rerun attach_app.',
        },
      );
    }
    return _attachFailed(status);
  }
  // Attach reaches `ready` only when `bridge.connect()` succeeded — run the
  // same skew check `connect` runs. Redundant when
  // `defaultVersionSkewValidator` is wired into the bridge; covers fakes /
  // future bridges that skip wiring.
  final result = await _enforceVersionSkew(bridge);
  if (result.refusal != null) {
    await session.detach();
    return result.refusal!;
  }
  if (context != null && context.isCancelled) {
    // The client gave up on this request, so it will never learn about the
    // session. Do not leave one running.
    await session.detachIfCurrent(generation);
    return _attachFailed(session.status, reason: 'the client cancelled it');
  }
  return _withAttachStamps(status.toJson(), result.diagnose);
}

/// `attach_failed` envelope for an attach that ended without a session.
ToolCallResult _attachFailed(AppStatusPayload status, {String? reason}) {
  final message =
      reason ??
      status.lastError ??
      (status.state == AppSessionState.idle.name
          ? 'the attach stopped before it finished, because detach_app ran '
                'or the client cancelled it'
          : 'the attach did not reach ready (state=${status.state})');
  return _typedErrorEnvelope(
    'attach_failed',
    message,
    data: <String, Object?>{'status': status.toJson()},
  );
}

/// `hot_reload_unsupported` envelope for a session without a flutter daemon.
ToolCallResult _hotReloadUnsupported(String openedWith) => _typedErrorEnvelope(
  'hot_reload_unsupported',
  'hot_reload needs a session attached with attach_app(device:), which runs '
      'flutter attach. This session was opened with $openedWith and has no '
      'flutter daemon; its connection still works.',
  data: const <String, Object?>{
    'remedy':
        'Call detach_app, then attach_app(device: <device id or name>) to '
        'get a session that supports hot_reload.',
  },
);

/// Progress message for one stage of the iOS-direct pipeline.
String _iosPhaseMessage(IosAttachPhase phase, Map<String, Object?>? data) {
  switch (phase) {
    case IosAttachPhase.detectingTransport:
      return 'Detecting whether the device is on USB or wireless';
    case IosAttachPhase.resolvingBonjour:
      return 'Looking for the app VM service over Bonjour';
    case IosAttachPhase.launchingApp:
      return 'Launching the app with xcrun devicectl';
    case IosAttachPhase.announcementsCollected:
      final count = (data?['announcements'] as List?)?.length;
      return count == null
          ? 'Found the VM service announcement'
          : 'Found $count VM service announcement(s)';
    case IosAttachPhase.selectingAnnouncement:
      return 'Selecting the VM service to connect to';
    case IosAttachPhase.reclaimingStalePidfile:
      return 'Checking for a leftover iproxy tunnel';
    case IosAttachPhase.spawningIproxy:
      return 'Starting the iproxy USB tunnel';
    case IosAttachPhase.iproxyReady:
      return 'The iproxy tunnel is up';
    case IosAttachPhase.attachComplete:
      return 'Connecting to the app VM service';
  }
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

/// Construct a typed error envelope. The text content carries the typed
/// name + message so clients without structured-error parsing still see
/// a useful string; the second text block carries a JSON object with the
/// error name and supplemental info (remedy, allowed values, the session
/// status, etc.) for clients that introspect.
ToolCallResult _typedErrorEnvelope(
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
      {'type': 'text', 'text': _encodeTypedErrorData(payload)},
    ],
  );
}

String _encodeTypedErrorData(Map<String, Object?> payload) {
  try {
    return _typedErrorJsonEncoder.convert(payload);
  } catch (_) {
    return '{"error":"${payload['error']}"}';
  }
}

final _typedErrorJsonEncoder = JsonEncoder();
