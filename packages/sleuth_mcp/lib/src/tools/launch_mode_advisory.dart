/// Maps a Sleuth `connectionMode` to an advisory string for MCP clients.
///
/// `connectionMode` is the app's frame verdict tier, not the state of the
/// sidecar's bridge. `basic` covers two states: Sleuth has no VM service link,
/// or it has one and no frame has received a VM-tier verdict yet (verdicts
/// are published for jank frames only, so a smooth session stays `basic`).
/// The app's own `vmConnected` flag tells them apart, so the `basic` advisory
/// needs it.
library;

/// stableIds Sleuth reports only with a VM service link: every issue of the
/// `vmOnly` detectors (memory, heavy compute, shader, platform channel,
/// stream resource) plus the VM timeline paths of the hybrid rebuild and
/// repaint detectors. `raster_dominance` is absent because its frame-timing
/// leg runs without a VM link.
const String vmOnlyStableIds =
    'heap_growing, gc_pressure, heap_near_capacity, native_memory_growing, '
    'heavy_compute, shader_compilation, platform_channel_traffic, '
    'stream_resource_growth, rebuild_activity, excessive_repaint';

/// Advisory for `connectionMode == 'basic'` when the app reports no VM
/// service link after the warmup window, so VM-only detectors stay silent.
const String launchAdvisoryBasic =
    'The session is degraded. Sleuth has no VM service link, so its '
    'VM-backed detectors ($vmOnlyStableIds) are off and it reports no '
    'memory, CPU or repaint issues. Kill and reopen the app, because a '
    'profile build connects again at launch. If the app was started with '
    '`flutter run` and this advisory stays, one possible cause is DDS '
    'holding the VM service. Relaunch with `flutter run --profile '
    '--no-dds`.';

/// Opening words of [launchAdvisoryWarmup], kept stable so a snapshot that
/// carries the warmup advisory can be recognised.
const String launchAdvisoryWarmupLead = 'Sleuth is still warming up';

/// Advisory for `connectionMode == 'warmup'`: the mode is not yet final, so
/// the issue list may be incomplete even on a healthy session.
const String launchAdvisoryWarmup =
    '$launchAdvisoryWarmupLead during its first few seconds, so the issue '
    'list may be incomplete. Run `diagnose` again in a few seconds. When it '
    'returns no launchModeAdvisory, the session is ready.';

/// Advisory for `connectionMode == 'disconnected'`: no live VM connection.
const String launchAdvisoryDisconnected =
    'The session is degraded. Sleuth has no live VM connection, so only '
    'the FrameTiming and structural detectors run, and it reports no '
    'memory, CPU or repaint issues. For full coverage, run the app with '
    '`flutter run --profile --no-dds`.';

/// Whether [advisory] is the warmup advisory, by its opening words.
bool isWarmupAdvisory(Object? advisory) =>
    advisory is String && advisory.startsWith(launchAdvisoryWarmupLead);

/// Advisory for [connectionMode], or null when none is warranted (`full` /
/// `correlated` / null / unrecognized).
///
/// [vmConnected] disambiguates `basic`, which a VM-connected session also
/// reports until a frame gets a VM-tier verdict. Its detectors then run and
/// no relaunch helps, so the basic advisory needs `vmConnected != true`; an
/// unknown flag (null) still gets it.
String? launchModeAdvisoryFor(String? connectionMode, {bool? vmConnected}) {
  switch (connectionMode) {
    case 'basic':
      return vmConnected == true ? null : launchAdvisoryBasic;
    case 'warmup':
      return launchAdvisoryWarmup;
    case 'disconnected':
      return launchAdvisoryDisconnected;
    default:
      return null;
  }
}

/// Computes the advisory from a full `ext.sleuth.*` [envelope], tolerating a
/// malformed or missing `connectionMode` / `data.vmConnected`. The advisory is
/// best-effort metadata, so a degraded payload must never throw: a
/// non-String mode gives no advisory and a non-bool flag counts as unknown,
/// rather than a `CastError`.
String? launchModeAdvisoryForEnvelope(Map<String, Object?> envelope) {
  final connectionMode = envelope['connectionMode'];
  final data = envelope['data'];
  // `diagnose` and `issues` (sleuth 0.37 and later) report `data.vmConnected`;
  // `snapshot` reports the same flag as `data.isVmConnected`. Accept either.
  final vmConnected = data is Map<String, Object?>
      ? (data['vmConnected'] ?? data['isVmConnected'])
      : null;
  return launchModeAdvisoryFor(
    connectionMode is String ? connectionMode : null,
    vmConnected: vmConnected is bool ? vmConnected : null,
  );
}
