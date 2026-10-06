import '../controller/sleuth_controller.dart';

/// Five-state mode stamped on every `ext.sleuth.*` response. Lets a
/// consumer distinguish "no issues observed" from "warmup not elapsed"
/// or "no VM-tier frame verdict yet".
///
/// The mode describes the best frame verdict so far, not the VM link: a
/// connected session reports [basic] until a frame gets a VM-tier verdict.
/// `ext.sleuth.diagnose` and `ext.sleuth.issues` report the link itself as
/// `vmConnected`.
enum ConnectionMode {
  /// VM timeline matched per-frame.
  correlated,

  /// VM batch available, no per-frame correlation.
  full,

  /// No VM-tier frame verdict yet. Either Sleuth has no VM connection, or it
  /// has one and no frame has received a correlated or full verdict since it
  /// connected. Verdicts are published for jank frames only, so a smooth
  /// session with a live VM link stays here while its VM-backed detectors
  /// run.
  basic,

  /// Initialised but warmup window not elapsed; detector emissions partial.
  warmup,

  /// Sleuth has not initialized. After the controller is disposed the
  /// extensions report this mode without a `sessionUuid`.
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
