/// Advanced sub-flag configuration for debug instrumentation.
///
/// Fields express **profiler intent** rather than raw Flutter globals.
/// Sub-flags only take effect when their parent top-level switch is enabled
/// on [SleuthConfig]:
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
    this.layoutProfiling = false,
    this.paintProfiling = false,
    this.timelineEnrichment = false,
    this.userWidgetsOnly = true,
  });

  /// Track per-widget rebuild counts via `debugOnRebuildDirtyWidget`.
  final bool rebuildAttribution;

  /// Track per-widget paint counts via `debugOnProfilePaint`.
  final bool paintAttribution;

  /// Enable `debugProfileBuildsEnabledUserWidgets` for per-widget build
  /// timeline events. This is what produces the `FlutterTimeline.startSync`
  /// scopes the profile-mode drain consumes to populate the Rebuild Stats
  /// drilldown.
  final bool widgetBuildProfiling;

  /// Enable `debugProfileLayoutsEnabled` for per-widget layout timeline
  /// events.
  ///
  /// **Disabled by default.** No Sleuth detector consumes layout-phase
  /// timeline events, so turning this on only dumps every
  /// `RenderObject.layout()` call (`RenderPadding`, `RenderFlex`,
  /// `RenderConstrainedBox`, etc.) into the same `FlutterTimeline` buffer
  /// the Rebuild Stats drilldown reads — burying the user-widget names
  /// beneath thousands of framework render-tree scopes. Leave `false`
  /// unless you are profiling layout in an external tool that reads
  /// Flutter's own timeline.
  final bool layoutProfiling;

  /// Enable `debugProfilePaintsEnabled` for per-widget paint timeline events.
  ///
  /// **Disabled by default.** Paint attribution for Sleuth's detectors goes
  /// through the `debugOnProfilePaint` callback ([paintAttribution]), not
  /// the timeline buffer. Enabling this flag only feeds
  /// `RenderObject.paint()` runtime-type strings into the same buffer the
  /// Rebuild Stats drilldown reads, polluting it with names like
  /// `RenderSemanticsAnnotations`/`RenderRepaintBoundary` that are not
  /// user-facing widget rebuilds. Leave `false` unless you need paint
  /// scopes for an external timeline consumer.
  final bool paintProfiling;

  /// Enable `debugEnhance*TimelineArguments` flags for richer timeline data.
  /// Highest overhead — disabled by default.
  final bool timelineEnrichment;

  /// Count only widgets your code creates in the per-widget debug rebuild
  /// and paint counts ([rebuildAttribution], [paintAttribution]).
  ///
  /// A widget counts when the framework's creation tracking (on in debug
  /// builds) places it outside the Flutter SDK, which includes widgets
  /// other packages create; once DevTools has set the project's root
  /// directories, only widgets created in the project count. Without
  /// creation tracking every widget counts.
  ///
  /// A paint is counted for the widget that created the painting render
  /// object. Your `CustomPaint`, `Padding`, `DecoratedBox` or `Row` count
  /// as themselves; `Text`, `Icon` and `Image` paint through render
  /// objects the framework creates (`RichText`, `RawImage`), so they get
  /// no per-widget paint count, and framework widgets such as
  /// `_InkFeatures` are left out. Their paints stay in the aggregate
  /// count. Set false to count framework widgets too.
  final bool userWidgetsOnly;
}
