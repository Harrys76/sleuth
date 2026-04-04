## Advanced Profiling: Frame Correlation ✅

**Implemented.** Per-frame event correlation matches VM timeline events to specific
frames using monotonic timestamp overlap, solving the batch attribution error where
500ms of events were attributed to a single frame.

Key components:
- `PhaseEvent` model with absolute timestamps from VM timeline
- `FrameEventCorrelator` matches events to frames via build/raster time windows
- `analyzeCorrelatedMode()` produces per-frame verdicts with confidence wording
- Three-tier degradation: Correlated → Legacy full → Basic
- Fallback to legacy `analyzeFullMode()` when correlation fails or is untrustworthy

Implementation outline:

- Capture raw per-frame timing boundaries from `FrameTiming`.
- Retain raw VM timeline events with timestamps, not only aggregated batch totals.
- Correlate timeline events to frame windows by timestamp overlap.
- Only use stronger wording when correlation coverage is good enough.

Files:

- `lib/src/detectors/frame_timing_detector.dart`
- `lib/src/vm/timeline_parser.dart`
- `lib/src/vm/vm_service_client.dart`
- `lib/src/controller/watchdog_controller.dart`
- `lib/src/analyzer/render_pipeline_analyzer.dart`

Acceptance criteria:

- A verdict is attached to a specific frame by correlated timestamps, not just recent batch timing.
- The analyzer can downgrade confidence when event coverage is incomplete.
- The README may then say "precise per-frame phase attribution in full mode".

Testing:

- Add synthetic frame/timeline correlation tests with exact expected attribution.

## Advanced Profiling: Debug Instrumentation Strategy (implemented)

Goal:

- Make debug mode genuinely useful for attribution without pretending it reflects real runtime cost.
- Use lightweight debug callbacks by default in debug mode.
- Put heavier profiling flags behind an explicit opt-in toggle.

### Debug callback installation — opt-in (revised)

**Original plan**: Enable lightweight hooks (`debugOnRebuildDirtyWidget`, `debugOnProfilePaint`) automatically when `kDebugMode` is true.

**Revised design**: Callbacks are **opt-in** via `WatchdogConfig.enableDebugCallbacks` (default `false`).

**Reason**: Flutter's `WidgetInspectorService` asserts debug callback globals are `null` before installing its own handlers (verified at `widget_inspector.dart:1114`). Auto-enabling would prevent DevTools "Track Widget Rebuilds" / "Track Repaint Widgets" from working. The service extension handler's try-catch prevents app crashes, but DevTools features fail silently.

**Installation policy**: Each callback slot is checked independently. If one is already occupied (e.g. by DevTools), it is skipped with a log warning; the other can still be installed.

**Paint attribution scope**: `debugOnProfilePaint` provides a `RenderObject`. Per-widget paint attribution is extracted via `renderObject.debugCreator` → `DebugCreator.element.widget.runtimeType`, the same technique DevTools uses. The `DebugSnapshot.paintCounts` map provides per-type paint counts alongside the aggregate `totalPaintCount`.

Expected behavior:

- Keep `FrameTiming` as the baseline runtime signal.
- Use `debugOnRebuildDirtyWidget` to improve per-widget-type rebuild attribution and explanation quality.
- Use `debugOnProfilePaint` for aggregate repaint activity detection only.
- Label debug-derived evidence clearly in the UI via `ObservationSource` enum on `PerformanceIssue`.

UI wording requirement:

- Distinguish observation sources: `structural scan`, `VM timeline`, `debug callback`, `debug callback + structural`.

SDK verification requirement:

- Verify callback availability and signature against the package's minimum supported Flutter SDK (`>=3.24.0`) before committing to this milestone.
- Current official API docs show:
  - `RebuildDirtyWidgetCallback = void Function(Element e, bool builtOnce)`
  - `ProfilePaintCallback = void Function(RenderObject renderObject)`
- If either callback is not available or stable in Flutter `3.24.0`, bump the minimum Flutter SDK constraint.
- Do not add runtime capability checks for these globals. This should be resolved through the declared Flutter SDK range.

### Heavy profiling flags

Expose a clearly labeled opt-in toggle for heavier debug instrumentation, for example:

- `Deep Debug Instrumentation`
- `Inspection Mode`

This toggle should only be available in debug mode.

Recommended initial flag order:

1. `debugProfileBuildsEnabledUserWidgets`
2. `debugProfileLayoutsEnabled`
3. `debugProfilePaintsEnabled`

Optional later enrichments:

- `debugEnhanceBuildTimelineArguments`
- `debugEnhanceLayoutTimelineArguments`
- `debugEnhancePaintTimelineArguments`

### Rules for heavy instrumentation

- Heavy flags are off by default.
- Enabling them must show a clear warning in the UI.
- When heavy flags are enabled:
  - attribution claims may become stronger
  - timing claims must become weaker

Required warning text concept:

- Widget/layout/paint instrumentation is enabled.
- Counts and traces are useful for attribution.
- Timings are not representative of real performance because instrumentation adds overhead.

### Detector behavior under heavy instrumentation

- Rebuild-related detectors may use instrumented widget rebuild counts.
- Paint-related detectors may use instrumented paint callbacks/events.
- The package must not present instrumented timings as profile-equivalent performance measurements.

### Performance constraints for debug callbacks

- `debugOnRebuildDirtyWidget` can fire for every dirty widget rebuild in debug mode.
- `debugOnProfilePaint` can fire for every painted `RenderObject`.
- Aggregation must be allocation-light and O(1) per callback:
  - increment counters in existing maps keyed by widget/render-object type
  - avoid per-callback object allocation where possible
  - avoid storing full element/render-object histories unless explicitly sampled
- Callback handlers must not trigger additional tree walks.
- Any rolling history built from these callbacks should use bounded ring buffers.

### Config model

Use a two-tier config model:

- simple top-level switches for the common path
- a structured expert `advanced` block for profiler-framework users

Recommended shape:

- top-level:
  - `enableDebugCallbacks` (opt-in, default false — see revised installation policy above)
  - `enableDeepDebugInstrumentation`
  - `maxTrackedTypes`
- expert refinement under an `advanced` block, expressed as profiler intent rather than raw Flutter globals

Examples of expert controls:

- rebuild attribution
- paint attribution
- widget build profiling
- layout profiling
- paint profiling
- timeline enrichment

Design rules:

- The primary API should not read like a direct passthrough of Flutter debug globals.
- Advanced controls are for power users and should be documented with overhead and fidelity tradeoffs.
- The top-level switches are the authoritative controls.
- Advanced sub-flags only refine behavior when their parent switch is enabled.

Parent-switch precedence:

- If `enableDebugCallbacks` is `false`, attribution-related advanced flags are ignored.
- If `enableDeepDebugInstrumentation` is `false`, deep instrumentation advanced flags are ignored.
- Contradictory config states must resolve in favor of the parent top-level switch.

Acceptance criteria:

- When lightweight callbacks are enabled, debug mode becomes more useful through per-widget attribution without additional user effort.
- Heavy instrumentation is explicit, opt-in, and clearly explained.
- UI distinguishes attribution quality from timing fidelity.
- Debug callback aggregation is implemented efficiently enough to avoid making debug mode noticeably worse through avoidable package overhead.
- The config model supports both simple adoption and expert refinement without exposing raw framework internals as the primary API.
- Parent top-level switches always take precedence over advanced sub-flags.

### Implementation summary

**Config model** (`lib/src/debug/debug_instrumentation_config.dart`): New `DebugInstrumentationConfig` class with 6 sub-flags (`rebuildAttribution`, `paintAttribution`, `widgetBuildProfiling`, `layoutProfiling`, `paintProfiling`, `timelineEnrichment`). Exposed as `WatchdogConfig.advanced`. Barrel-exported from `lib/widget_watchdog.dart`.

**Selective install** (`lib/src/debug/debug_instrumentation_coordinator.dart`): Added `installRebuild` and `installPaint` constructor params. `install()` checks these before attempting slot installation, allowing partial install (e.g. paint-only when rebuild attribution sub-flag is off).

**Two independent parent switches** (`lib/src/controller/watchdog_controller.dart`): `enableDebugCallbacks` and `enableDeepDebugInstrumentation` are evaluated in separate `if` blocks inside `_installDebugInstrumentation()`, fixing a pre-existing bug where deep instrumentation was nested inside the callbacks check and silently did nothing without callbacks enabled. Both `initialize()` and `initializeDetectorsForTest()` call the shared `_installDebugInstrumentation()` method, closing a test-path discrepancy where the test path silently skipped heavy flags.

**Heavy flag save/restore**: `_installHeavyFlags()` saves and overrides 6 Flutter debug globals (`debugProfileBuildsEnabledUserWidgets`, `debugProfileLayoutsEnabled`, `debugProfilePaintsEnabled`, `debugEnhanceBuildTimelineArguments`, `debugEnhanceLayoutTimelineArguments`, `debugEnhancePaintTimelineArguments`). `_restoreHeavyFlags()` restores originals on dispose. All wrapped in assert blocks.

**Resolved state getter**: `isDeepInstrumentationActive` checks actual `_prev*` fields (not raw config), so `enableDeepDebugInstrumentation=true` with all sub-flags off correctly returns `false`.

**UI surface** (`lib/src/ui/dashboard_sheet.dart`, `lib/src/ui/issue_card.dart`): Purple instrumentation warning banner when `isDeepInstrumentationActive`. Fidelity annotation on `IssueCard` ("Attribution: high fidelity" + "Timing: overhead present") when deep instrumentation is active and the issue's `observationSource` is `debugCallback` or `debugCallbackAndStructural`.

**ObservationSource tagging**: All 12 structural and VM-timeline detectors now set `observationSource` on every `PerformanceIssue` constructor (8 structural, 4 vmTimeline). The 4 debug-callback-aware detectors (RepaintDetector, ShallowRebuildRiskDetector, AnimatedBuilderDetector, CustomPainterDetector) already set source dynamically from expansion #2.

**Tests**: 42 new tests/assertions across 4 new test files (`debug_instrumentation_config_test.dart`, `instrumentation_warning_test.dart`) and updates to existing test files (coordinator, wiring, 12 detector test files). Total suite: 480 tests, 0 analysis issues.

Testing:

- Add debug-only tests for instrumentation-enabled detector behavior where practical.
- Add unit tests for toggle/config behavior and warning-state propagation.
- Add dedicated chaining/restore tests for debug globals:
  - user callback installed -> coordinator installed -> both fire
  - coordinator disposed -> user callback still works
- Add restore-order tests for nested installs to guard against lifecycle corruption in tests/hot reload scenarios.

