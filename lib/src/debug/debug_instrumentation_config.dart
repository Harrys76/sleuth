/// Advanced sub-flag configuration for debug instrumentation.
///
/// Fields express **profiler intent** rather than raw Flutter globals.
/// Sub-flags only take effect when their parent top-level switch is enabled
/// on [WatchdogConfig]:
///
/// - [rebuildAttribution] and [paintAttribution] are gated by
///   `enableDebugCallbacks`.
/// - [widgetBuildProfiling], [layoutProfiling], [paintProfiling], and
///   [timelineEnrichment] are gated by `enableDeepDebugInstrumentation`.
class DebugInstrumentationConfig {
  const DebugInstrumentationConfig({
    this.rebuildAttribution = true,
    this.paintAttribution = true,
    this.widgetBuildProfiling = true,
    this.layoutProfiling = true,
    this.paintProfiling = true,
    this.timelineEnrichment = false,
  });

  /// Track per-widget rebuild counts via `debugOnRebuildDirtyWidget`.
  final bool rebuildAttribution;

  /// Track per-widget paint counts via `debugOnProfilePaint`.
  final bool paintAttribution;

  /// Enable `debugProfileBuildsEnabledUserWidgets` for per-widget build
  /// timeline events.
  final bool widgetBuildProfiling;

  /// Enable `debugProfileLayoutsEnabled` for per-widget layout timeline
  /// events.
  final bool layoutProfiling;

  /// Enable `debugProfilePaintsEnabled` for per-widget paint timeline events.
  final bool paintProfiling;

  /// Enable `debugEnhance*TimelineArguments` flags for richer timeline data.
  /// Highest overhead — disabled by default.
  final bool timelineEnrichment;
}
