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
    'VM-only detectors (heap_growing, heavy_compute, excessive_repaint, '
    'gc_pressure, stream_resource) are suppressed: Sleuth could not '
    'self-connect to the VM service. If you launched with default DDS '
    '(plain `flutter run`), relaunch with `flutter run --profile --no-dds` '
    'for full detector coverage.';

/// Advisory for `connectionMode == 'warmup'`: the mode is not yet final, so
/// the issue list may be incomplete even on a healthy session.
const String launchAdvisoryWarmup =
    'Sleuth is still warming up; connectionMode is not yet final. Re-run '
    '`diagnose` in a few seconds to confirm full mode before trusting the '
    'issue list.';

/// Advisory for `connectionMode == 'disconnected'`: no live VM connection.
const String launchAdvisoryDisconnected =
    'Sleuth reports no live VM connection (connectionMode: disconnected); '
    'only FrameTiming and structural detectors run. Reach full mode with '
    '`flutter run --profile --no-dds`.';

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
