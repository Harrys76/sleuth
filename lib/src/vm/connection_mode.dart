import '../controller/sleuth_controller.dart';

/// Five-state mode stamped on every `ext.sleuth.*` response. Lets a
/// consumer distinguish "no issues observed" from "warmup not elapsed"
/// or "we couldn't talk to the VM".
enum ConnectionMode {
  /// VM timeline matched per-frame.
  correlated,

  /// VM batch available, no per-frame correlation.
  full,

  /// FrameTiming only — no VM connection.
  basic,

  /// Initialised but warmup window not elapsed; detector emissions partial.
  warmup,

  /// Controller present, VM client disconnected.
  disconnected,
}

/// Derive the current mode. Warmup takes precedence over VM-fidelity
/// classification so a fast connect during the warmup window cannot
/// masquerade as `correlated`/`full`/`basic`.
ConnectionMode computeConnectionMode(SleuthController c) {
  final initAt = c.initializedAt;
  if (initAt == null) return ConnectionMode.disconnected;
  if (DateTime.now().difference(initAt) < c.config.frameTimingWarmupDuration) {
    return ConnectionMode.warmup;
  }
  if (!c.isVmConnected) return ConnectionMode.basic;
  final verdict = c.verdictNotifier.value;
  if (verdict?.isCorrelated == true) return ConnectionMode.correlated;
  if (verdict?.isFullMode == true) return ConnectionMode.full;
  return ConnectionMode.basic;
}
