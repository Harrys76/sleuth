/// Maps a Sleuth `connectionMode` to an advisory string for MCP clients.
///
/// `connectionMode` reflects whether Sleuth's *in-app* VM self-connect
/// succeeded, independent of the sidecar's own bridge transport — so it (not
/// anything the sidecar infers from its connection) is the authoritative
/// signal for whether VM-only detectors are live.
library;

/// Advisory for `connectionMode == 'basic'`: self-connect failed after the
/// warmup window, so VM-only detectors stay silent.
const String launchAdvisoryBasic =
    'Degraded session: Sleuth could not connect to the VM service, so its '
    'VM-backed detectors are OFF (heap_growing, heavy_compute, '
    'excessive_repaint, gc_pressure, stream_resource) — memory, CPU, and '
    'repaint issues will not be reported and the issue list is incomplete. '
    'First, kill and reopen the app: a profile build re-attempts the connect '
    'on launch and usually recovers. If it stays basic AND the app was '
    'started with `flutter run`, DDS is holding the VM service — relaunch '
    'with `flutter run --profile --no-dds`.';

/// Advisory for `connectionMode == 'warmup'`: the mode is not yet final, so
/// the issue list may be incomplete even on a healthy session.
const String launchAdvisoryWarmup =
    'Sleuth is still warming up (first few seconds), so the connection tier '
    'is not final yet and the issue list may be incomplete. Re-run '
    '`diagnose` shortly to confirm full mode before trusting it.';

/// Advisory for `connectionMode == 'disconnected'`: no live VM connection.
const String launchAdvisoryDisconnected =
    'Degraded session: no live VM connection, so only FrameTiming and '
    'structural detectors run — memory/CPU/repaint issues are not reported. '
    'Reach full coverage with `flutter run --profile --no-dds`.';

/// Advisory for [connectionMode], or null when none is warranted (`full` /
/// `correlated` / null / unrecognized).
///
/// [vmConnected] disambiguates `basic`: it is also reported when the VM *is*
/// connected but the verdict hasn't warmed, where detectors still fire and no
/// relaunch helps — so the basic advisory is gated on `vmConnected != true`.
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
/// best-effort metadata, so a degraded payload must never throw — non-String /
/// non-bool values degrade to "no advisory" rather than a `CastError`.
String? launchModeAdvisoryForEnvelope(Map<String, Object?> envelope) {
  final connectionMode = envelope['connectionMode'];
  final data = envelope['data'];
  // `diagnose` reports `data.vmConnected`; `snapshot` reports the same flag as
  // `data.isVmConnected`. Accept either.
  final vmConnected = data is Map<String, Object?>
      ? (data['vmConnected'] ?? data['isVmConnected'])
      : null;
  return launchModeAdvisoryFor(
    connectionMode is String ? connectionMode : null,
    vmConnected: vmConnected is bool ? vmConnected : null,
  );
}
