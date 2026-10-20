## Unreleased

### Added

- Issues carry the number their detector reports with the detector's
  warning and critical lines: `PerformanceIssue.measurement`, a final
  class `IssueMeasurement` with `value`, `unit`, `warningAt`, `criticalAt`,
  `window`, `warningStrict` and `criticalStrict`. A value reaches a line at
  or above it, or only above it when that line is strict, and every
  measurement is higher-is-worse. A line that is absent or not finite has
  no flag. Issue JSON gains an optional `measurement` object; `windowMs`
  keeps microseconds as a fraction.
- Built-in detectors set the measurement on 43 issue families. Most titles
  show the value; `raster_dominance` titles show the raster-to-UI ratio and
  `heap_near_capacity` titles a percent of the budget instead. Six
  families report a pattern rather than an amount and leave it null
  (`always_repaint_painter`, `runtime_font_loading`, `expensive_gpu_nodes`,
  `layout_bottleneck`, `sliver_fill_remaining_scrollable`,
  `sliver_to_box_adapter_shrinkwrap`), as do `event_loop_stall` when the
  VM gave no stall length and `non_lazy_shrinkwrap` when the child count is
  unknown.
- The issue's severity is the detector's and can disagree with the
  severity the value reaches, in either direction. `rebuild_activity`,
  `excessive_repaint` and the debug rates hold a severity until the value
  stays low, and `heap_near_capacity` tolerates one sample under its line,
  so a value can sit below the line of the severity shown. The debug rates
  go critical only on the latest window while the value averages two, so a
  warning can also carry a value above the critical line.
- `jank_detected` and `sustained_jank` measure over the vsync span of the
  frames they judged. The 240-frame buffer can make it shorter than 10 s,
  capture mode judges the whole buffer, and frames without vsync times
  give no window, as in `raster_dominance`. `rebuild_activity` and
  `excessive_repaint` give the length of the VM window behind the share,
  1 to 1.5 s.
- `MeasurementUnit` is a class with constant instances instead of an enum,
  so a later release can add a unit without breaking a `switch`. Units
  compare by name, a custom detector can name its own, and a reader keeps
  a unit it does not know by name instead of dropping the measurement.
- `SimpleStructuralDetector.report` takes an optional `measurement`.
- Snapshots and `ext.sleuth.issues` carry `notUsefulMarks`, the issues
  marked Not useful in the overlay this session (oldest first, at most
  200), each with the issue's key, title, category, severity, confidence,
  measurement, route, `markedAt` and whether it is still reported
  (`live`). Like `suppressedCount` the key is metadata: written only when
  there is a mark, whatever the projection, and never a `SnapshotSection`.
  `SessionSnapshot.notUsefulMarks` and `NotUsefulMark` read it back.
  `doc/mcp_schema.{json,md}` document it and the issue `measurement`
  shape, and the sidecar lists it in `snapshotMetadataKeys`.
- `WidgetHighlight.occurrenceId`: the identity of the element a highlight
  was measured from, equal to the `occurrenceId` of its issue.
- `DebugSnapshot.forcedRebuildsOf` (debug callbacks): for each widget type
  a parent's build rebuilt, the types whose builds forced it, framework
  widgets included, and how often. `forcedTypesCapped` reports its caps.
- `SleuthThemeData.severityGraphicColor` and the optional
  `severityCriticalGraphic`, `severityWarningGraphic` and
  `severityOkGraphic` tokens: the colour of severity borders, icons and
  dots, which need 3:1 where text needs 4.5:1. The dark default uses the
  severity fills, brighter than its pale text shades; the light preset
  sets red-600, amber-600 and emerald-600, so its chips read red and
  orange instead of two dark browns; the high-contrast presets and
  `fromColorScheme` fall back to the severity text colours.
- `SleuthThemeData.cardDivider`, the line under the status row. It
  defaults to `0xFF4B5563` in dark and `0xFFB4BAC4` in light, `border` in
  the high-contrast presets and `outlineVariant` in `fromColorScheme`.

### Changed

- The card header shows a run label, such as "Debug · VM" or "Profile · no
  VM", in place of the VM+, FRAME and DBG badges. A narrow card drops the
  "Sleuth" name first, then "· VM", and at last keeps only the dot, which
  is filled with the VM and a ring without it. A screen reader always
  hears the full label.
- A More button replaces the theme button. Its menu holds Startup (TTFF),
  Rebuild stats (the route's count, opening the drilldown), Hidden issues
  (with a count, only when there are any), Encyclopedia, Guide, Copy
  snapshot and Theme (Auto, Light, Dark). It opens as a panel inside the
  card. Back, Escape, a tap on the scrim or a tap on the app closes it,
  and while it is open the app and the card body are hidden from screen
  readers. Opening it moves keyboard focus to the first row that can act
  and screen reader focus to the panel. More, the rows and the theme
  segments draw a 2 px `checkboxActive` outline while the keyboard has
  focus. A failed copy offers Try again.
- Tab and Shift+Tab move focus, and Enter and Space activate the focused
  control, inside the card and its pages. The overlay sits above the
  app's `WidgetsApp`, so the app's default shortcuts never reached it; a
  focused text field keeps Enter and Space.
- The footer, the startup banner, the rebuild stats banner, the confidence
  caption and the frame-rate detail row are gone. Hidden issues, Copy
  snapshot, startup and rebuild stats moved into the More menu.
- The severity chips lead the status row ("2 critical"), with a filled
  icon while on and an outlined one while off. The frame rate sits at the
  end of the row. "Showing X of Y" appears only while a severity is off,
  since the More menu counts hidden cards. A screen reader hears the line
  change, and Show all moves its focus to the first chip.
- The card is at least 320 px wide, or the screen less 16 px margins on
  a narrower screen, and stored narrower widths are raised. Its background
  is opaque.
- The resize grip works on a maximized card too: the first drag or resize
  step makes it a normal card at the size and place it has, then resizes
  that. The list ends with 48 px of padding, so the grip does not cover
  the last card.
- The overlay no longer uses `TweenAnimationBuilder`, so it is off the
  debug instrumentation's framework denylist and an app's own uses count.
- The collapsed issue card is flat, with no source bar on its left edge.
  A severity mark replaces the emoji: a disc or triangle filled with the
  severity colour, with a white or near-black mark inside at 3:1 or more
  against the fill; the discs carry a white ring. The title runs to 2
  lines (3 above 1.3x text), or in full while the card is expanded.
- One meta line under the title replaces the badges: category,
  confidence, "seen X of Y scans, label" and "N effects", led by the Jank
  and New tags. New shows for 2 seconds in place of the wider accent.
- A Debug timing tag replaces the confidence on a timing issue in a debug
  run: a time-based measurement (milliseconds, seconds, percent or
  frames) from the VM timeline or `FrameTiming`. The per-card "Debug mode
  result" note is gone.
- `jank_detected`, `sustained_jank` and `slow_startup_ttff` carry
  `observationSource: frameTiming`, the source of their times. Startup
  said `structural` before and the jank issues carried none.
- `wrap_layout_bottleneck`, `excessive_repaint_boundary` and issues from
  `SimpleStructuralDetector.report` carry the `widgetName` their highlight
  carries (`Wrap`, the scrollable's type, the reported widget's runtime
  type), so their cards keep the crosshair. Their overlay keys now
  include the name, so such a card hidden under an older release shows
  again.
- A crosshair replaces the highlight checkbox and shows only for an issue
  that names a widget, labelled "Show <widget> on screen" and read as on
  or off. Layout and paint cards without a widget name no longer offer a
  highlight that could not find anything. The card body and the
  crosshair draw the focus outline in keyboard mode.
- An expanded card no longer draws the pin icon. Its semantics hint
  reads "Pinned while expanded".
- An expanded card stays until it is collapsed, even when its issue stops
  being reported or folds under another card. A card whose issue is gone
  leads its meta line with "Not detected right now" and offers no
  crosshair, and the empty states wait until it is collapsed.
- A press on a card, a More menu row, a theme segment or the crosshair
  draws a light tint instead of the fallback theme's 40 % grey ripple.
- The overlay no longer uses `Checkbox`, so it is off the framework
  denylist and an app's own checkboxes count.
- The guide's legend describes the new card. The "Jank flash" card
  colour, which the overlay never drew, is gone from it.
- `badgeDbgBg` and `badgeDbgText` draw the Debug timing tag. The
  confidence colours, the source accents, `sourceAccentWidth`,
  `effectsBadge`, `disclaimerText` and `cardJankFlash` are unused by the
  overlay and kept for custom themes.
- The expanded card shows its details below a divider, at the full card
  width. An issue with a measurement opens with a Measured row: the value
  and what it is ("10.0 ms in one build on the UI thread", with the
  measurement's window where it has one), a gauge with
  the warning and critical lines, and a line when the severity is held
  above the value or judged on another reading. The issue's detail
  follows, with what the number does not say (failing URLs and status
  codes, for instance). The issues notifier fires when the Measured row's text or
  a gauge line changes, and not for a change the row rounds away.
- Labelled rows follow: Where (the widget, and its `file:line` with Copy
  when the run tracks widget creation), Route, When ("Last seen 2 s ago ·
  in 5 of the last 8 scans", with the interaction; the time is the
  card's own when cards share a stable id), Evidence (the
  detector's reason and the confidence) and Check in (the DevTools view).
  The labels stack above their values when large text makes the label
  column wider than a third of the card. "About this detection" is gone,
  with its profile-mode line that said timing "matches production", and
  so are the Ancestors, Widget, During and Source lines and the debug
  fidelity tags.
- Caused by and Effects rows open the related card: a card in the list
  expands, scrolls into view and takes focus; a hidden or filtered-out one
  shows a toast with Show, which keeps the open cards expanded; an effect
  folded under a card opens its detail and fix under its row. A related
  issue no longer reported stays as plain text. Rebuild and setState
  cards link to Rebuild stats once the screen has counted rebuilds, and
  the slow startup card links to Startup metrics.
- A tap on an expanded card's details no longer collapses it; the header
  does. Hide moves focus to the card that takes its place, scrolled into
  view, and hiding a card whose issue is gone offers no Undo.
- The fix opens with "Fix" and its effort ("Fix · medium effort"). Code
  lines after a line ending in a colon sit in a monospace block with Copy
  code; a code run is lines with brackets, `;` or `=>`, commands, comments
  and the indented lines of a call, and a bullet or a sentence ending in a
  full stop is prose. The effort badges, and the keyword guess for an
  issue without `fixEffort`, are gone.
- Labelled buttons replace the links and icons: Show on screen, Learn
  more, Ask AI, Copy details, Hide and Not useful, each a 48 px target.
  Not useful marks the issue for the session's exports and MCP output and
  says so; a second tap removes the mark. Ask AI's icon no longer
  shimmers, so `ShaderMask` and `AnimatedBuilder` are off the framework
  denylist and an app's own uses count.
- In a debug run with `enableDebugCallbacks`, rebuild and setState cards
  show Why it rebuilds: the rebuilds the widget started itself (a
  setState, a changed dependency or a listenable) and those its parents
  forced, naming the parent that forced the most and its share. The row
  reads only counts from the card's own screen (a card kept from another
  screen asks to open it), says when the debug counters left widget
  types out, and without the callbacks says how to turn them on.
- The effort colours, `aboutBackground`, `fixHintText` and the three
  `aiShimmer` colours are unused by the overlay and kept for custom
  themes. The guide describes the new expanded card and Not useful.

- `FrameVerdict.relatedIssues` lists only the issues that can explain the
  verdict's phase: the issues of the phase's category, `event_loop_stall`
  for a start delay, and none for a stall or an unknown phase. Jank
  symptoms are never listed, so exports carry fewer issues, and the
  reason's `Related:` line names an issue of the phase. The overlay's JANK
  tag shows only while `jank_detected` or `sustained_jank` is reported.
- Highlighting an issue outlines only its own widget: the element it was
  reported for, else the first widget with its name. Another widget of
  the same category is no longer outlined in its place. When the widget
  is not on screen the card unticks, and no outline appears later.
- Copying the snapshot from the overlay counts as Sleuth's own work, so
  it is left out of the next frame's start delay. A second tap during a
  copy is ignored.
- A dismissed debug-mode banner stays dismissed when the dashboard is
  closed and reopened.

## 0.38.0

More accurate detectors, a VM timeline read that no longer stalls the app,
a new event-loop stall detector, and twelve more `runtimeVerified` detector
and severity pairs (27 across 19 stable ids). The matching sidecar is
`sleuth_mcp` 0.9.0. The
[full release notes](https://github.com/Harrys76/sleuth/blob/main/doc/release_notes/0.38.0.md)
list every change.

### Breaking and behavior changes

- A frame is jank when it misses its deadline. Its build must end within
  the budget counted from vsync, and its raster must fit in the budget.
  The wait between build and raster no longer counts. A frame late only
  because of Sleuth's own work counts as Sleuth overhead
  (`FrameStats.isSleuthOverhead`, `FrameStatsSummary.sleuthOverheadFrames`)
  and stays out of the jank percentage and route health. Jank counts are
  not comparable with 0.37.
- `jank_detected` and `sustained_jank` judge the frames of the last 10 s
  outside capture mode, so their cards clear after the jank stops, and
  `jank_detected` needs at least 3 late frames.
- CPU attribution of jank verdicts is off by default
  (`SleuthConfig.cpuAttribution`). Each `getCpuSamples` request froze the
  UI isolate for 250 to 410 ms on an iPhone 12.
- Outside capture mode Sleuth reads the VM timeline from the `Timeline`
  stream instead of requesting it every 500 ms. The request held the
  raster thread up to 41 ms on a Galaxy A07.
- `raster_dominance` counts frames that missed their deadline on the
  raster thread. Three in one second warn and 10 are critical
  (`GpuPressureDetector.criticalRasterDominantFrames`). The VM timeline
  makes the issue `confirmed` instead of setting its severity.
- `gc_pressure` counts each collection once, not once per isolate, counts
  young-generation collections only, and
  `SleuthConfig.gcRateThresholdPerMin` defaults to 240.
- `heap_growing` decides from the heap left after the VM's idle full
  collections when it has fresh ones (`confirmed`), and from the
  heap-sample regression otherwise.
- `native_memory_growing` needs growth of both native memory and RSS that
  continues through the whole 30 s window and each half of it.
- On displays faster than `fpsTarget`, `heavy_compute` warns at three
  quarters of the frame budget, at most 8 ms.
- `http_error_spike` is critical at 10 errors, whatever their status.
- `platform_channel_traffic` counts calls by event time, in the busiest
  1 s span.

### Added

- New `event_loop_stall` detector (VM only, Flutter 3.35 and later). A
  timer that fires 100 ms or more late marks a stall, which is critical
  from 700 ms. The detector first takes off app pauses, debugger pauses,
  hot reloads and Sleuth's own work. A new causal rule leads from
  `event_loop_stall` to `sustained_jank`.
- `gc_pressure` reports the share of time spent in GC pauses
  (`gcPauseMs`, `gcPausePercent`, `MemoryPressureDetector.gcWindowStats`).
- Apps built on the `material_ui` and `cupertino_ui` packages get the same
  framework treatment as the SDK's Material and Cupertino libraries.
- Sleuth reads blur sigma from the filter's fields, so profile builds
  measure it, and a blur that a Cupertino bar or popup draws names its
  owner.
- `shader_compilation` detects Impeller OpenGL ES program links.
- New APIs: `Sleuth.startupDetector`, `Sleuth.setHeapGrowingLegsForCapture`,
  `Sleuth.holdAllocationProfileReads` /
  `releaseAllocationProfileReads`, `PlatformChannelCall.tid`, and
  `DetectorMetadata.effectiveTierFor(severity:)`.
  `Sleuth.suspendNonEssentialTimelineStreams` and
  `resumeAllTimelineStreams` return whether the VM accepted the list.
- `ext.sleuth.diagnose` adds `timelineSource`, `streamBlocks`,
  `streamEvents`, `streamEventsDropped`, `catchUpReads`,
  `lastStreamLagMs`, `eventLoopStallTimerStream`, `eventLoopStallExcused`
  and `eventLoopStallIgnored`.

### Fixed

- The VM timeline parser dropped raster frames after the engine's
  `SceneDisplayLag` events (a Galaxy A07 GPU demo parsed 2 of 76).
- The VM client decoded a `Flutter.Frame` Extension event on every frame
  it did not use.
- A disabled `BackdropFilter`, and a `CustomPaint` without painters such
  as Flutter 3.47's Android scroll stretch, are no longer reported.
- Only a client's first VM session reads the whole timeline buffer.

### Evidence

- `runtimeVerified` raises, each backed by iPhone 12 capture triads on
  Flutter 3.47.6: `http_error_spike` warning, `high_frequency_same_path`
  warning, `platform_channel_traffic` critical, `excessive_repaint`
  critical, `sustained_jank` critical, `gc_pressure` warning,
  `uncached_images` warning and critical, `slow_startup_ttff` warning and
  critical, and `raster_dominance` warning and critical.
- New Flutter 3.47.6 triads replace the `jank_detected` warning captures
  (recorded under the deadline rule), the `heap_growing` warning captures
  and the `platform_channel_traffic` warning captures.

## 0.37.0

Flutter 3.47 support, more accurate detectors, a cheaper VM poll loop, and a
reworked overlay with accessibility support. The matching sidecar is
`sleuth_mcp` 0.8.0. The
[full release notes](https://github.com/Harrys76/sleuth/blob/main/doc/release_notes/0.37.0.md)
list every change.

### Breaking and behavior changes

- The minimum versions are Dart `^3.8.0` and Flutter `>=3.32.0`, and
  `vm_service` widens to `>=14.0.0 <16.0.0`.
- `rebuild_activity` and `excessive_repaint` measure the share of UI-thread
  time spent building or painting per ~1 s window instead of counts. They warn
  above 10 % and go critical above 30 %
  (`DetectorThresholds.buildTimePercentThreshold` /
  `paintTimePercentThreshold`). `SleuthConfig.rebuildThreshold` and
  `RepaintDetector.paintFrequencyThreshold` now gate only the per-widget debug
  cards.
- Removed: `RebuildDetector.setBaseline`, `baselineRebuildRate`,
  `lastObservedRebuildRate`, `peakObservedRebuildRate`,
  `RepaintDetector.lastObservedPaintCount`, `peakObservedPaintCount` (replaced
  by `last`/`peakObservedBuildPercent` and `last`/`peakObservedPaintPercent`),
  and `CorrelatedFrameData.coverageRatio` (`FrameVerdict.correlationCoverage`
  reports the batch coverage). `FixHintBuilder.rebuildActivity` and
  `excessiveRepaintVm` take percentages.
- `heap_near_capacity` compares process memory (RSS) with the new opt-in
  `DetectorThresholds.memoryBudgetBytes` and stays off until you set it.
  `gc_pressure` fires above 180 GC/min (was 60).
- Issues rank by evidence tier, which combines severity and confidence, so a
  confirmed warning ranks above a possible critical. A warning no longer turns
  critical after 30 scans. Comparing a 0.36 snapshot with a 0.37 one can show
  severity changes from this alone.
- The jank budget follows the measured frame rate, between `fpsTarget` and the
  display's refresh rate (`autoFrameBudget: false` keeps it fixed). At 60 Hz a
  33 ms frame is jank but no longer severe.
- In the causal graph a `possible` cause no longer claims a `likely` or
  `confirmed` effect, and an effect collapses under a single cause only when
  that cause is at least as severe. The graph has 41 rules.
- Debug repaint cards name the likely origin of a layer's repaints, are titled
  "Likely Repaint Origin" and are `likely`. Per-widget debug counts cover only
  widgets your app creates (`DebugInstrumentationConfig.userWidgetsOnly`).
- Platform-channel profiling is opt-in (`SleuthConfig.profilePlatformChannels`),
  and `platform_channel_traffic` triggers on call count only.
- `excessive_keep_alive` ids name the scrollable
  (`excessive_keep_alive:PageView~1`). Hides saved under the old positional ids
  are dropped.
- Encyclopedia entries, fix hints, guides and some overlay titles are reworded
  to match what the detectors do.

### Added

- Overlay: system and predictive back close the innermost layer first; the
  overlay layout, hidden cards, filter and theme survive restarts with
  `SleuthConfig.stateStore`; Hide with Undo and a Hidden list; Copy details;
  severity filter chips; collapsed cards hold their order while the dashboard
  is open; `Sleuth.overlayUiState`.
- Accessibility: overlay text scales from 0.8 to 2.0×, screen-reader labels and
  actions replace dragging, most controls are 48 dp, text meets WCAG AA contrast,
  plus high-contrast presets, a System / Light / Dark toggle, reduced motion
  and Escape. `SleuthThemeData.fromColorScheme` and `fromSeed` build a theme
  from your app's colours.
- AI chat: Stop and Retry, short failure reasons with Copy error, first-token
  and stall timeouts (`AiChatAdapter.firstTokenTimeout` / `stallTimeout`), a
  Session section in the prompt, and conversations kept per card for the
  session. Custom adapters can throw `AiProviderException`.
- `raster_dominance` from per-frame `FrameTiming` without a VM link, and
  `BaseDetector.processFrame(FrameStats)` for custom detectors.
- `non_lazy_shrinkwrap` for shrink-wrapped lists inside a `Column` or `Row`.
- `Sleuth.lastPollTimings` and VM poll costs in `ext.sleuth.diagnose`, which
  also reports `effectiveFrameRateHz`, `frameBudgetUs` and `frameRateSource`.
- `ext.sleuth.issues` carries `vmConnected`.

### Fixed

- On Flutter 3.47, scans no longer abort in bottom-navigation apps
  (`IndexedStack`).
- Sleuth reads the VM timeline incrementally and never clears it, so DevTools
  keeps its view. In capture mode a poll on an idle iPhone 12 screen dropped
  from 117 ms to 6.6 ms. CPU-sample requests are spaced 10 s apart.
- `shader_compilation` reads Impeller Vulkan and Skia build events; it was
  silent on devices.
- Fewer false positives: framework painters, Material's own clips and
  framework-built intrinsics are skipped, `setstate_scope` needs observed
  rebuilds, keep-alive counts the innermost page view, sliver-added repaint
  boundaries are not counted, `uncached_images` measures real decode waste, and
  `large_response` skips images, video, audio and fonts.
- Rebuild and repaint cards no longer flicker at the threshold, and the
  overlay's own widgets are no longer counted as the app's.
- The VM connection survives a single failed poll and tries loopback first
  (wireless iOS), a scan on a quiet screen no longer waits for an unrelated
  repaint, jank is judged per route, and `heavy_compute` emits one issue per
  batch.
- Explanation placeholders are filled in the AI prompt and
  `ext.sleuth.explain`.

### Example and testing

- New Tabbed Shell and Shrink-wrapped Sections demos, an animated GPU demo,
  `ext.sleuthDemo.*` remote-drive extensions, capture screens that check
  provenance and bands before export, and capture triads re-recorded on
  Flutter 3.47.6.
- Wall-clock benchmarks carry the `benchmark` tag and run serially.

`kSleuthPackageVersion` is 0.37.0.

## 0.36.0

Companion package: `sleuth_mcp` is now available — an MCP stdio sidecar that
exposes the `ext.sleuth.*` VM service extensions to AI clients (Claude Code,
Cursor, Zed), so an assistant can query a running app's live performance data in
conversation. Opt-in and versioned independently (see
[`packages/sleuth_mcp/CHANGELOG.md`](packages/sleuth_mcp/CHANGELOG.md), current
0.7.2). The in-app overlay remains sleuth's primary UX.

This release also brings the MCP integration surface and snapshot controls
(consolidates 0.32.0–0.35.0; per-version detail in `CHANGELOG.archive.md`):

- Seven `ext.sleuth.*` extensions — `snapshot`, `issues`, `routeHealth`,
  `explain`, `encyclopedia`, `causalGraph`, `diagnose`. Debug/profile only
  (`kReleaseMode` no-op). Every response stamps `connectionMode`,
  `schemaVersion: 1`, and a per-session `sessionUuid`.
- Wire-shape lock — `doc/mcp_schema.{json,md}` codify the envelope and every
  handler's data shape (nested `recurrenceTrends` / `sessionSummary` /
  `routeSessions` included), audit-enforced.
- Snapshot projection + pagination — `sections` / `maxIssueCount` /
  `maxRouteCount` keep long sessions under the MCP client token cap;
  backward-compatible (no args = full payload).
- `SleuthConfig.showOverlay` (default `true`): set `false` to hide the in-app
  overlay (trigger button + dashboard) while detectors and `ext.sleuth.*` keep
  running — for MCP-only sessions where the AI client is the consumer.

`kSleuthPackageVersion` → 0.36.0; envelope `schemaVersion` stays `1`. Sidecar
`sleuth_mcp` (current 0.7.2) pins 0.36.0.

## 0.30.1

pub.dev README polish — no detector or distribution change.

- `doc/logo.png` now ships in the published archive (`.pubignore` whitelist) so the README hero image renders on pub.dev instead of falling back to the alt text.
- Tests-passing badge refreshed to the current count (3,001).

## 0.30.0

`TrackedResourceDetector.tracked_resource_long_lived.warning` raised to runtimeVerified via `additionalBrackets[0]`. Distribution: 15/20 effective runtimeVerified family-severity pairs across 12 unique stableIds.

- Long-lived bracket: threshold 300 (matches default `longLivedSeconds`), unit `seconds`, atTolerance 0.5 (at-band [300, 450]), aboveCeilingMultiplier 3.0 (ceiling 900). `observedAxisArgKey: 'oldestInstanceAgeSeconds'`, `requireUniqueDetectedAtMicros: true`. Three iPhone 12 / iOS 17.5 / Flutter 3.41.4 captures with real-time waits past the 300 s production threshold.
- Detector behaviour change: `_evaluateLongLived` overwrites `longLivedFirstCrossMicros = nowMicros` each sweep (was `??=` first-cross-only). A long-lived overshoot now produces an emission per sweep with monotonically-increasing age — captures get a real ascending-age series (`observedAxisReduction: 'max'` picks the leg-end value), and a lingering leak re-flags every sweep with the current elapsed retention. UI cards unchanged (same stableId, age refreshes).
- `captureTraceStableId: longLivedStableId` re-added to `_evaluateLongLived` so parametric `tracked_resource_long_lived:<name>` emissions route through the bare family for the bracket validator's byte-exact filter.
- New public API: `lastObservedAgeSecondsFor(name)` / `peakObservedAgeSecondsFor(name)` per-name age observables. `_sweep()` records each pass; `untrackAll(name)` drops entries; `resetCaptureState()` clears them.
- Capture screen long-lived legs: register 1 ref + real-time wait (250 / 380 / 600 s for below / at / above) at the production threshold. `dispose()` clears per-name override defensively via `Sleuth.setResourceThreshold(_kResourceName)` (both null = remove).

## 0.29.1

`IssueEncyclopediaPage` "Learn more" navigation now resolves to the correct entry for parametric stableIds (`tracked_resource_concurrent:<name>`, `excessive_keep_alive:<i>`, `excessive_global_keys:<i>`) and dynamic-suffix stableIds (`repaint_debug_<typeName>`, `rebuild_debug_<typeName>`). Previously the page used byte-exact `scrollToStableId` against `IssueExplanationBuilder.allExplanations` (bare-family keys), so parametric/dynamic variants never expanded or scrolled the target entry.

- New public `IssueExplanationBuilder.canonicalId(String)` — strips parametric `:<param>` and dynamic widget-type suffixes, mapping a `PerformanceIssue.stableId` to the encyclopedia key.
- `IssueEncyclopediaPage._scrollTargetKey` getter resolves `widget.scrollToStableId` through `canonicalId`; `initState` `containsKey` check, `_scrollToTarget`, and per-row `isScrollTarget` comparison all use the normalized key.

## 0.29.0

`TrackedResourceDetector.tracked_resource_concurrent.warning` raised to runtimeVerified via `perStableIdTier`. Distribution: 14/20 effective runtimeVerified family-severity pairs across 11 unique stableIds.

- Bracket: threshold 6 (smallest count > default `maxConcurrent` 5 that triggers emission), unit `instances`, atTolerance 0.5 (at-band [6, 9]), aboveCeilingMultiplier 3.0 (ceiling 18). `observedAxisArgKey: 'liveInstanceCount'`, `requireUniqueDetectedAtMicros: true`. Three iPhone 12 / iOS 17.5 / Flutter 3.41.4 captures.
- New `PerformanceIssue.captureTraceStableId` optional field. When set, `CaptureHelper.composeIssueEvent` uses it (instead of `stableId`) to compose the `sleuth.issue.<id>.<severity>` trace-event name. Parametric stableId detectors (`tracked_resource_concurrent:<name>`) route the trace event through the bare family so the bracket validator's byte-exact filter matches every member. UI cards still key on the parametric `stableId`; equality + hashCode unchanged.
- Detector capture plumbing: `flushConcurrentEvaluation()` (synchronous sweep, bypasses the 10 s sweep-timer); `untrackAll(name)` (drop bucket + detach Finalizers — leg isolation for capture screens); `resetCaptureState()` (clears per-name observables + every bucket's `concurrentFirstCrossMicros` / `longLivedFirstCrossMicros`, propagated from `SleuthController.resetCaptureState`); per-name getters `lastObservedLiveCountFor(name)` / `peakObservedLiveCountFor(name)` plus aggregate `lastObservedLiveCount` / `peakObservedLiveCount` for back-compat. Capture screens MUST use the per-name getter — the aggregate would track an unrelated bucket if another `Sleuth.trackResource(...)` registration is active.
- `tracked_resource_long_lived` family stays reproducerOnly — 300 s threshold exceeds an on-device scenario window. `_evaluateLongLived` does NOT set `captureTraceStableId`, so its emissions never land as bare-family `sleuth.issue.tracked_resource_long_lived.warning` events in capture mode (which would be unclaimed evidence: no bracket, no `coveredThresholds` entry).
- New `example/lib/demos/tracked_resource_capture_screen.dart`. Per-leg flow: `untrackAll` + clear strong-refs → `suspendNonEssentialTimelineStreams` → `markScenarioBegin` → synchronous allocate + register → `flushConcurrentEvaluation` → 3 × 32 ms frame yields → `flushTimelineNow` → read `peakObservedLiveCountFor(name)` → `markScenarioEnd` → 600 ms drain → `exportCaptureJson`.

## 0.28.0

New `Sleuth.setResourceThreshold(name, {int? maxConcurrent, int? longLivedSeconds})` per-name threshold override for `TrackedResourceDetector`. `trackResource` / `untrackResource` API unchanged.

- **Merge semantics**: omitted or invalid axis preserves the prior value for that axis. Explicit both-null clears the override. Subsequent calls update one axis without losing the other.
- Override is bucket-independent — survives empty-bucket sweep eviction, LRU bucket drops, and `isEnabled = false` toggle. `dispose()` clears.
- Per-axis validation: invalid values (`<= 0`) drop that axis (counted via `droppedOverridesCount`). Cap at 1000 distinct names — new-name overflow silently drops; updates to existing names always succeed. Runtime guard (release-safe).
- Issue `extraTraceArgs` always stamps `effectiveMaxConcurrent` / `effectiveLongLivedSeconds` + `thresholdSource` (`'override'` or `'global'`).
- Pre-init calls (before `Sleuth.init`) drop with a once-per-session debug warning.
- Cross-isolate / `kReleaseMode` no-op (matches `trackResource` shape).

## 0.27.0

New `TrackedResourceDetector` (runtime, opt-in) + public `Sleuth.trackResource` / `Sleuth.untrackResource` API. 19 → 20 detectors.

- `Sleuth.trackResource(name, resource)` registers; tracker keeps `WeakReference` + Finalizer token + first-seen timestamp per registration. Token is the registration identity (allocation-unique, collision-resistant); shared `Finalizer` dispatches release on GC reclaim. `Sleuth.untrackResource(name, resource)` is the optional explicit decrement.
- Two emission paths, both `confirmed`:
  - `tracked_resource_concurrent.warning` — live count under one name > `trackedResourceMaxConcurrent` (default 5).
  - `tracked_resource_long_lived.warning` — single instance alive past `trackedResourceLongLivedSeconds` (default 300 s).
- LRU cap (`trackedResourceMaxDistinctNames`, default 1000) bounds the in-memory bucket map; eviction detaches per-ref Finalizer entries so VM-side state stays bounded. Periodic sweep (`trackedResourceSweepIntervalSeconds`, default 10 s) drives evaluation.
- Pure Dart — no VM service dependency. Cross-isolate registration is a no-op (one controller per isolate).
- Primitive / record targets silently dropped via `droppedTargetsCount`.
- New `CausalGraphRule` edges `tracked_resource_concurrent → heap_growing` and `tracked_resource_long_lived → heap_growing`.
- Tier `reproducerOnly`.

## 0.26.0

`stream_resource_growth.warning` raised to runtimeVerified; `gc_pressure` default 30 → 60/min.

- `StreamResourceDetector`: `stream_resource_growth.warning` → runtimeVerified via `perStableIdTier`. Three iPhone 12 / iOS 17.5 / Flutter 3.41.4 captures bracket threshold 50 (unit `instances`) on `topGrowthDelta` axis; atTolerance 0.6, aboveCeilingMultiplier 3.0.
- BREAKING-ISH: magnitude gate switched from summed `netDelta` to dominant-class `top.delta` so the firing axis matches the bracketed axis. Multi-class growth (≥2 watchlist classes ascending) stays as a structural precondition. A balanced 25+25 multi-class workload no longer fires; a single 60-instance leak with any other grower still does.
- `MemoryPressureDetector.gcRateThresholdPerMin` default 30 → 60. Dart's `EventStreams.kGC` emits per young-gen scavenge; ~30/min is steady-state for a moderately allocating UI. Pre-v0.26.0 sensitivity available via `SleuthConfig(gcRateThresholdPerMin: 30)`.
- `StreamResourceCaptureScreen`: 1024 KB/sec byte pressure (256 KB × 4 Hz, 1024-entry rotating cap) reliably re-arms heap_growing inside scenario. Heap-growing readiness wait moved INSIDE scenario span (`markScenarioBegin → resetCaptureState` wipes the prior latch). Direct `flushStreamResourceEvaluation()` dropped — emissions route through `pollStreamResourceAllocationProfileNowWithCapture`. JSON post-process aligns `expectedMagnitude.observed` to detector-stamped `topGrowthDelta`.
- `'instances'` added to `ProfileCaptureSchema.approvedUnits`.

## 0.25.0 (BREAKING)

Multi-parent causal UI + removal of deprecated `rootCauseId` singular field.

**BREAKING** — `PerformanceIssue.rootCauseId` (deprecated since v0.24.2) and `effectiveRootCauseIds` getter removed. JSON `rootCauseId` key no longer read or emitted. Migration:
- `PerformanceIssue(rootCauseId: 'x')` → `rootCauseIds: ['x']` (also covers `copyWith`).
- `issue.rootCauseId` getter → `issue.rootCauseIds?.firstOrNull`.
- v0.24.x-or-earlier snapshots carrying only the singular key must re-export through v0.24.2 (singular → plural coercion) before importing on v0.25.0+. Debug builds emit a warning when fromJson sees the legacy key without the plural.

UI:
- `IssueCard.parentIssues` + `_causedBySection` widget (mirrors `_downstreamSection`; cap at 5 + "and N more"; "(+N suppressed)" annotation when resolved parents < `rootCauseIds.length`).
- `computeVisibleIssues`: ≥2 parents always visible (multi-parent badge); 1 parent collapses under visible parent or surfaces as orphan; 0 parents visible.
- `FloatingIssuesCard`: resolves `parentIssues` via `stableIdToIssue` map; counts unresolved parents.
- `AiContextBuilder` reads `rootCauseIds` directly.

Contract:
- `rootCauseIds` documented invariant: null or non-empty. `fromJson` coerces empty/all-non-string lists to null.
- `_resortRootCauseIdsByCurrentSeverity` keeps `rootCauseIds[0]` highest-severity post-escalation so the "Caused by" badge and AI-prompt cap-at-5 truncation stay accurate.

Tests: +9 (5 `_causedBySection` render + 4 fromJson normalization). Visibility-filter triad updated. ~10 sites migrated singular→plural; singular-only regression tests removed (now compile errors).

## 0.24.2

Multi-parent causal-graph annotation (metadata layer). `CausalGraphRule.apply` now claims every reaching root for each downstream effect, removing the v0.24.1 export-vs-UI asymmetry at the data model layer. Top-level UI rendering of multi-parent badges is deferred to v0.25.0+ — the visibility filter still collapses each downstream under any visible reaching root.

- `PerformanceIssue.rootCauseIds: List<String>?` (plural) joins the schema; singular `rootCauseId` is `@Deprecated` and removed in v0.25.0. Constructor accepts both for back-compat. `fromJson` reads `rootCauseIds` if present, falls back to a singleton-list coercion of `rootCauseId` for v0.24.1-and-earlier snapshots. `toJson` derives singular from `rootCauseIds.first` (post-v0.24.2 canonical) so v0.24.1 readers see the highest-severity root after re-export — eliminates singular/plural drift.
- `CausalGraphRule.apply()`: `downstreamOwners` is now `Map<int, Set<int>>` (multi-parent) instead of `Map<int, int>` (single-owner). BFS from each root accumulates every reach. Each downstream issue carries every reaching root, sorted severity desc then stableId asc. Confidence suppression skips the root's `downstreamIds` listing for a `possible` downstream when any reaching root is `confirmed` or `likely`. Intermediate nodes in multi-hop chains are not surfaced as parents — only originating roots are (matches BFS-from-roots model; surfacing intermediates ships in v0.25.0+).
- `FloatingIssuesCard`: precomputed `stableIdToIssue` map (O(1) downstream lookup, drops itemBuilder cost from O(n²) to O(n)). `computeVisibleIssues` filter extended for multi-parent semantics: a downstream is hidden from top-level when any reaching root is visible; surfaces standalone only when every parent is suppressed.
- `AiContextBuilder`: prompt section uses singular "Root cause issue" / plural "Root cause issues" label depending on `rootCauseIds.length`; caps the joined list at 5 with `(+N more)` suffix.
- Tests: +5 (multi-parent 3×3 fan-in pin, rule-ordering invariant under input-shuffle, multi-parent confidence suppression, full-pipeline integration via correlator, multi-parent visibility-filter triad). ~70 existing assertions migrated from `.rootCauseId` → `.rootCauseIds`.

## 0.24.1

Cross-detector polish for `stream_resource_growth`.

- `CausalGraphRule`: 3 new edges so retained-stream emissions surface as causes of co-firing memory issues. `stream_resource_growth → heap_growing`, `stream_resource_growth → heap_near_capacity`, `stream_resource_growth → gc_pressure`. Mirrors the `uncached_images` and `excessive_keep_alive:*` patterns.
- Edge enumeration is asymmetric across consumers: `CausalGraphRule.activeEdges` (Markdown export, session summaries) returns every distinct cause→effect pair, so a 3-cause × 3-effect memory co-fire surfaces all 9 edges. `CausalGraphRule.apply` (UI annotation) remains single-owner — each downstream gets one `rootCauseId` chosen by severity-then-index, and losing roots render as standalone cards. Multi-parent UI rendering is deferred to a future cut.
- Schema regression guard: `ProfileCaptureSchema.parseFile` round-trip test for the 4 detector-side `extraTraceArgs` keys (`topGrowthClass`, `topGrowthDelta`, `watchlistClassesGrowing`, `samplesInWindow`) so a future schema tightening with a key allowlist cannot silently disable the detector's trace args.
- Tests: +6 (4 `activeEdges` edge tests + 1 negative control, 1 `apply()` single-owner pin for the 3-cause memory fan-in, 1 schema round-trip).

## 0.24.0

New `StreamResourceDetector` (vmOnly) flags likely retained async resources via `getAllocationProfile` class-instance diff, gated on a recent `MemoryPressureDetector.heap_growing` emission. 18 → 19 detectors.

- `StreamResourceDetector`: polls allocation profile at most once per `streamResourceSampleSeconds` (default 10s); tracks `instancesCurrent` for a hardcoded watchlist of dart:async / dart:io / web_socket_channel suffixes (`StreamSubscription`, `_BroadcastSubscription`, `_ControllerSubscription`, `StreamController`, `_SyncBroadcastStreamController`, `_AsyncBroadcastStreamController`, `_WebSocketImpl`, `WebSocketChannel`) plus rxdart `PublishSubject` / `BehaviorSubject` / `ReplaySubject` when `classRef.library.uri` contains rxdart. Emits `stream_resource_growth.warning` only when (a) `MemoryPressureDetector.isHeapGrowingActive` returns true within the recency window (default 30s), (b) ≥2 watchlist classes show ≥3 of 3 ascending transitions across a K=4 sample window, (c) sum of per-class net deltas exceeds `streamResourceMinDelta` (default 50). Confidence `likely`. Tier `reproducerOnly`.
- Suffix-match (`endsWith`) shields against private-class renames across Flutter SDK versions. 20s warmup window suppresses cold-start subscription accumulation; window/warmup re-engage on `pause()` / `resume()` / `resetCaptureState()`. Re-entrancy guard (`_pollInFlight`) + 3-failure backoff (60s default). 3-cycle cooldown holds `dedupIdentityMicros` stable so the controller dedup composite key collapses successive fires to one trace record.
- `MemoryPressureDetector`: new public `bool isHeapGrowingActive([int? windowMicros])` getter backed by `_lastHeapGrowingEmittedAtMicros` stamp. Decoupled from `_issues.any(...)` retention so a long-resolved heap_growing cannot latch downstream gating. Cleared on `vmConnected=false` / `reset()` / `dispose()`.
- `Sleuth.streamResourceDetector` static accessor (kReleaseMode-guarded). `StreamResourceDetector` exported from the public barrel.
- 5 new `DetectorThresholds` fields: `streamResourceSampleSeconds`, `streamResourceMinDelta`, `streamResourceWarmupSeconds`, `streamResourceHeapGrowingRecencyMicros`, `streamResourcePollFailureBackoffSeconds`.
- New `FixHintBuilder.streamResourceGrowth` cross-references `heap_growing` / `native_memory_growing` as alternative memory-pressure causes.
- IssueEncyclopediaPage entry for `stream_resource_growth` in `issue_explanation_builder.dart`.
- Library-URI gate on core watchlist: `endsWith` matches only fire when `classRef.library.uri` is `dart:async`, `package:web_socket_channel`, or (for WebSocket only) `dart:io`. dart:io's `_HttpClientStreamSubscription` is explicitly excluded — it self-cancels on response completion and would otherwise produce false positives on every network-heavy app.
- Cooldown semantics: wall-clock deadline (`cooldownSeconds`, default 30 s) — survives VmService disconnect mid-cooldown without leaving a stale issue pinned to `_issues` until the next non-null poll arrives. Re-emit during cooldown refreshes `detectedAt` (so UI does not show a stale stamp) while preserving `dedupIdentityMicros` for controller composite-key dedup.
- Reset-generation guard: in-flight `_pollAllocationProfile` snapshots `_resetGeneration` at start; if `_clearRetainedState` runs between the `await` and the result handler, the result is discarded. Without this, leg-N-1 sample data could write into leg-N's freshly-cleared `_perClassWindow` and break capture-mode scenario isolation.
- `windowSize` constructor assertion: `assert(windowSize >= 2)` rules out the empty-list `RangeError` path in `_evaluateWindow` if a future caller passes 0 or 1.
- `_ingestProfile` per-poll aggregation: sums `instancesCurrent` across every class that maps to the same suffix bucket and appends exactly one sample per suffix per poll. For suffixes previously seen but absent from the current poll (the leak was fixed and GC reclaimed every instance), appends `0` so a stale ascending window ages out instead of re-firing every cooldown cycle. All-zero windows are dropped to bound map growth.
- `_matchWatchlist` longest-suffix-match: a class named `_SyncBroadcastStreamController` matches the specific suffix instead of being shadowed by the generic `StreamController` bucket. First-match would also collapse multiple distinct controller flavors into one window, corrupting the ascending-transitions check.
- `_dropEmissionState` helper consolidates clears across cooldown lapse + transient gate failure + window underflow paths, eliminating drift between code paths that previously cleared a subset of emission fields.
- `@visibleForTesting` annotation on `allocationProfileFetcherForTest` constructor parameter so production callers cannot inject a custom fetcher.
- Tests: +17 unit (warmup, sample-rate gate, single-class-no-emit, heap_growing-off-no-emit, sub-threshold-no-emit, co-fire emission, extraTraceArgs key set, cooldown stable identity within window, cooldown detectedAt refresh, wall-clock cooldown expiry, non-monotone-no-emit, null-fetcher backoff, rxdart library-URI gate × 2, `_HttpClientStreamSubscription` exclusion, resetCaptureState, disabled, vmConnected-false). +5 reproducer (deliberate-leak harness, heap_growing-off, flat-no-emit, rxdart, cooldown).

## 0.23.0

`GpuPressureDetector.raster_dominance` idle false-positive fixed; `HeavyComputeDetector` issues persist past one VM batch.

- `GpuPressureDetector`: ratio numerator uses MAX-of-frame raster gated by `maxFrameRasterFloorUs` (default 8000us). New ctor param tunable for 120Hz / Impeller / low-power-mode.
- `RenderPipelineAnalyzer`: raster admitted as `suspectedPhase` only when one frame crosses 8000us.
- `HeavyComputeDetector`: emissions persist `emissionPersistence` (default 10s) via monotonic `Stopwatch` — survives VM poll cadence + system clock jumps. Retained state clears on `isEnabled=false` / `vmConnected=false`.
- `PerformanceIssue.sourceRoute`: detectors that retain issues stamp the route at emission. Aggregator prefers `sourceRoute` over live route, so post-emission navigation cannot reattribute. Wired through `HeavyComputeDetector` + `PlatformChannelDetector` via `sourceRouteProvider`.
- CSV Import demo row choices `[50K, 200K, 500K]` + post-parse sort. 500K cap avoids OOM / iOS watchdog.
- Tests: +5 gpu_pressure (idle-suppression, floor-triad, spike+idle, 12ms critical); +7 persistence (heavy_compute Stopwatch TTL × 3, lifecycle clear × 2, route-during-TTL × 2; platform_channel route-during-cooldown × 2).
- Doc cleanup: 21 historical spec files + `HANDOFF.md` removed; example/README aligned with 18-detector + 500K demo cap; README logo path switched to relative (`doc/logo.png`) for pub.dev rendering against private repo. Added Fastlane `TRACK_WIDGET_CREATION` patch tip for iOS profile archives. README accuracy fixes: Repaint detector moved from VM-Only to Hybrid section (matches `DetectorLifecycle.hybrid`); `heavyComputeGapMs` config example corrected to 8 (was drift-stamped 200). Pubspec description sharpened — leads with in-app overlay differentiator, drops abstract layer names.
- `doc/validation_ledger.md` Non-Detector Components: dropped stale v0.16.7 promise; framework live, 0 components registered; tier raises deferred to next non-detector formula change (4 candidates listed: `IssueRanker`, `RouteSession.healthScore`, `RecurrenceTrend`, FPS formulas).
- Reference-device matrix slimmed to **iPhone 12 / iOS 17.5 only** (`approvedDevicePairs`). iPhone 13 mini + Pixel 7 removed — never used by real captures (only synthetic fixtures, swapped). Anchor fixture re-pinned (SHA-256 updated). Android coverage gap explicitly documented in `doc/reference_devices.md`. 5 device-mismatch tests skipped pending second approved device pair. `doc/validation_matrix.md` + `doc/capture_procedure.md` + `example/lib/custom_detectors/README.md` swept for stale 23-detector / iPhone 13 mini / Pixel 7 references.

2,883 tests; `fvm flutter analyze` clean.

## 0.22.0

`sustained_jank.critical` runtimeVerified raise withdrawn. Bracket axis (sliding 240-frame-window severeCount) cannot composably bracket against operator-claimed K — ambient severe frames accumulate in the same window. Future raise needs detector-level baseline subtraction (`RebuildDetector.setBaseline(int)` pattern).

- Removed: 3 `sustained_jank` capture JSONs, `frame_timing_sustained_jank_capture_screen.dart`, example-app tile, retainedOrphans manifest entries.
- Reproducer-tier coverage of `sustained_jank` retained in `test/validation/frame_timing_reproducer_test.dart`.
- Distribution unchanged (12 family-severity pairs across 9 stableIds).
- README distribution paragraph + frame_timing_detector source comment refreshed to current state.

## 0.21.0

`RepaintDetector.excessive_repaint.warning` raised to runtimeVerified via `perStableIdTier` on three iPhone 12 / iOS 17.5 / Flutter 3.41.4 captures. Base tier stays `reproducerOnly`; `excessive_repaint_debug` and parametric `repaint_debug_<typeName>` are not over-claimed.

- Capture-mode plumbing: `lastObservedPaintCount` + `peakObservedPaintCount` getters, `flushPaintEvaluation()` (refreshes only `lastObservedPaintCount`; never updates peak so the exported magnitude always matches an emitted `observedPaintCount` arg), `resetCaptureState()` (per-leg accumulator clear, also called from `SleuthController.resetCaptureState` for cross-detector parity). VM emission stamps `extraTraceArgs.observedPaintCount` + `dedupIdentityMicros`.
- Bracket: `threshold: 30 paints`, `bracketAtTolerance: 0.50` (at-band [30, 45]), `aboveCeilingMultiplier: 2.0` (above-band ceiling 60 sits strictly under the `> 60` critical-tier fire boundary). Capture screen mounts 32 distinct `CustomPaint` widget classes so the per-widget debug gate stays sub-threshold and emission flows through the VM aggregate path.
- `Sleuth.repaintDetector` static getter (capture-screen access). `Sleuth.lastCaptureExportFailure` surfaces the most-recent `exportCaptureJson` null-return reason in-app.
- 12 effective runtimeVerified family-severity pairs across 9 unique stableIds. Base distribution unchanged (16/18 reproducerOnly, 2/18 runtimeVerified).

2,870 tests passing; `fvm flutter analyze` clean.

## 0.20.2

Example-app polish. No detector logic, public API, or schema change.

- `example/lib/main.dart` tile subtitles trimmed to ≤40 chars so 360 dp phones render single-line without ellipsis. Combined-chat tile keeps `SetState` (drops `Image`) to advertise actual detector coverage.
- `example/lib/demos/heavy_compute_demo.dart` description drops the hard "300 ms" claim → "complete in under a few hundred ms on modern devices" so CPU-throttled devices don't break the promise.
- `example/lib/demos/network_stress_demo.dart` search builds URL via `Uri.parse(...).replace(queryParameters: {'q': query})` — RFC 3986 percent-encoding for special chars (`+`, `&`, `=`, `#`, unicode).

2,862 unit + integration tests passing; `fvm flutter analyze` clean.

## 0.20.1

`FrameTimingDetector` and `RebuildDetector` stamp `extraTraceArgs.lifecyclePhase: 'startup' | 'steady'` on each emission. README + dartdoc gain a "Measurement window" note: Sleuth reports frame total duration from `FrameTiming` (build-to-raster span), not vsync delivery cadence.

- New `DetectorThresholds.startupPhaseWindowSeconds` (default 5). Classification reads `Timeline.now` at emission time — emission-time semantics, not event-time. A startup-phase frame whose callback delivery is delayed past the window boundary tags `'steady'`. Differs from `ShaderJankDetector.shaderWarmupContext` (per-event timestamp); the two tags are related but not aligned at the boundary.
- Buffer-aggregated emissions (`sustained_jank` 60-frame, `rebuild_activity` 1-second, raster-cache 30+ frames) tag from emission-time `Timeline.now`. A buffer straddling the boundary tags `'steady'` once `Timeline.now` exceeds the threshold.
- Null `Sleuth.dartEntryMonotonicUs` (init not called) or negative delta omits the key rather than fabricating a value.
- `rebuild_activity` runtimeVerified bracket axis (`observedRebuildRate`) co-exists with the new key. Audit-gate `validateBracket` reads named keys directly; multi-key emissions remain extractable.
- The tag is observable in capture-mode trace records and audit-gate replay; not serialized into saved JSON snapshots.
- Both detectors expose `appStartMonotonicUsForTest` constructor parameter for deterministic tests.

2,862 unit + integration tests passing; `fvm flutter analyze` clean. No detector logic, public API, or schema-version change.

## 0.20.0

**BREAKING**: 5 low-value detectors removed. Distribution: 23 → 18 detectors.

### Removed

- `DetectorType.animatedBuilder` — subset of `rebuild_detector` (AnimatedBuilder misuse manifests as rebuild storms; covered upstream).
- `DetectorType.opacity` — symptom-of-symptom (`Opacity` → `saveLayer` → jank already caught by `frame_timing.jank_detected`).
- `DetectorType.shallowRebuildRisk` — predictive heuristic; real signal caught by `rebuild_detector` from VM-timeline evidence.
- `DetectorType.nestedScroll` — Flutter's own `Vertical viewport was given unbounded height` diagnostic is more authoritative.
- `DetectorType.globalKey` — correctness lint, not perf; framework throws on duplicate `GlobalKey`.

Orphaned config fields removed: `SleuthConfig.maxGlobalKeys`, `DetectorThresholds.shallowRebuildMaxDepth`, `DetectorThresholds.animatedBuilderMinSubtreeSize`.

### Migration

Drop the 5 removed `DetectorType` references from `enabledDetectors`. `rebuild_detector` + `frame_timing` still surface AnimatedBuilder, opacity-jank, and rebuild-storm patterns from runtime evidence.

```dart
// BEFORE (v0.19.x):
SleuthConfig(enabledDetectors: {
  DetectorType.opacity, DetectorType.rebuild, DetectorType.frameTiming,
});

// AFTER (v0.20.0):
SleuthConfig(enabledDetectors: {
  DetectorType.rebuild, DetectorType.frameTiming,
});
```

v0.19 snapshots remain readable in v0.20 — serialization is `stableId`-keyed; encyclopedia + causal-graph rules retain removed-stableId entries for replay context. Users pinned at `^0.19.x` will not auto-upgrade.

### Distribution

16/18 reproducerOnly base + 2/18 runtimeVerified base. 11 effective runtimeVerified family-severity pairs across 8 unique stableIds (unchanged — none of the 5 removed carried raises).

2,851 unit + integration tests passing; `fvm flutter analyze` clean. Benchmark thresholds in `test/benchmark/` are machine-load-sensitive and may flake on slower hardware.


---

Releases prior to v0.20.0 are archived in [`CHANGELOG.archive.md`](https://github.com/Harrys76/sleuth/blob/main/CHANGELOG.archive.md).
