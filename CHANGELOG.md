## 0.14.0

Route Scoping — per-route FPS, issue aggregation, health scores, and export.
Data model and programmatic API retained; overlay UI (filter bar, summary row)
removed after on-device review revealed UX limitations (historical issues not
surfaceable as cards, making route filtering misleading). One adversarial review
round, 5 findings fixed.

### Added

- **`RouteSession` model**: Per-route statistics accumulated while a route is the
  active scan target. Includes `healthScore` (0–100 composite: FPS 40pts + jank
  30pts + issues 30pts, normalised to `fpsTarget`), per-route `FrameStatsBuffer`,
  issue snapshots, scan cycle count, and `toJson()` serialisation.
- **Passive route detection**: Route changes detected via element tree walk during
  the unified scan pass — no `NavigatorObserver` required. Works with any router
  (go_router, auto_route, Beamer, etc.). Unnamed routes get synthetic
  `<unnamed-N>` names.
- **`Sleuth.routeHistory` static API**: Returns the list of `RouteSession` objects
  observed since monitoring started. Null if Sleuth is not initialised.
- **`Sleuth.routeHealthScore()` static API**: Returns the health score for a
  specific route by name. Null if route not found or Sleuth not initialised.
- **`SleuthConfig.routeIgnorePatterns`**: Set of route name patterns to exclude
  from tracking. Supports exact match and trailing `*` wildcard (e.g.,
  `/dialog*`).
- **`SleuthConfig.routeHistoryCapacity`**: Maximum sessions retained in the route
  history ring buffer (default 20).
- **`SleuthConfig.copyWith()`**: Full copy-with covering all 28 config fields,
  including the 2 new route fields. Uses `_sentinel` pattern for nullable field
  overrides.
- **Schema v4 export**: `SessionSnapshot.routeSessions` field with per-route
  frame stats, issue counts, health scores, and FPS percentiles.
- **"Route Health" markdown table**: `Sleuth.exportSummary()` includes a route
  health section with health-dot indicators, FPS, issue counts, and duration.

### Changed

- **Export FPS clamped to `fpsTarget`**: Global and per-route `averageFps` and
  FPS percentiles (p50/p95/p99) are now clamped to `fpsTarget` at every export
  surface. Prevents ProMotion 120Hz idle screens from reporting misleading values
  above the configured target.
- **`packageVersion` updated**: `'0.12.1'` → `'0.14.0'` in export snapshot.

### Removed

- **Route filter bar and summary row**: Overlay UI for route filtering was
  removed after on-device review. Historical issues are not surfaceable as
  overlay cards (only live issues appear), making the filter UX misleading.
  Data model, export, and programmatic API retained.
- **Route chip theme tokens**: `routeChipBg`, `routeChipSelectedBg`,
  `routeChipText`, `routeChipSelectedText` removed from `SleuthThemeData`.

## 0.13.1

Dark/light mode toggle, design system tokens, Icons.pets brand icon, header
optimization, false-positive fix, and GlobalKey demo reliability fix. Five
adversarial review rounds (general ×2, theme performance + design system,
icon migration, GlobalKey demo), all findings fixed.

### Added

- **`triggerIconColor` theme token**: New color token on `SleuthThemeData` for
  the trigger button paw icon. Defaults to white (visible on severity-colored
  backgrounds in both light and dark themes). Customizable via `copyWith`.
- **In-overlay dark/light toggle**: Theme toggle icon in the overlay header
  switches between dark and light themes without changing system settings.
  Uses 3-tier resolution: runtime override > config theme > auto-detect.
- **`Sleuth.updateTheme()` static API**: Update the overlay theme at runtime.
  Pass `SleuthThemeData` to override or `null` to revert to auto-detection.
- **`SleuthController.themeOverride`**: `ValueListenable<SleuthThemeData?>`
  notifier for the current runtime theme override.
- **System brightness reactivity**: `didChangePlatformBrightness` re-resolves
  auto-detect theme when system brightness changes mid-session (gated to
  auto-detect mode only — skips when explicit override or config theme is set).
- **Typography scale tokens**: 9 font-size tokens on `SleuthThemeData`
  (`fontXxs`=8 through `fontDisplay`=24). All 8 overlay UI files migrated
  from hardcoded `fontSize` values — ~119 replacements.
- **Border radius scale tokens**: 7 radius tokens on `SleuthThemeData`
  (`radiusSm`=4 through `radiusFull`=20). All 8 overlay UI files migrated
  from hardcoded `BorderRadius.circular()` values — ~50 replacements.
- **`gripDots` light theme override**: Light theme now uses `0xFF6B7280`
  (gray-500) for grip dots instead of inheriting the dark-theme white.
- **Color coupling documentation**: `SleuthThemeData` constructor doc comment
  documents intentional hex-value sharing across semantically distinct tokens,
  with `copyWith()` independence guarantee.

### Changed

- **Brand icon: `Icons.pets` (Material paw print)**: Replaced dog emoji
  (`🐕`/`\u{1F415}`) and custom `SleuthLogoPainter` with Flutter's built-in
  `Icons.pets` across trigger button, overlay header, guide page title, and
  example app. Zero custom paint code, tree-shaken by Flutter 3+, theme-aware
  via `triggerIconColor`.
- **Startup metrics alignment**: Metric values in all sections (Headline,
  Engine Phases, VM Sub-Phases) are now right-aligned, with labels left-aligned
  via `Expanded` + plain `Text` pattern.
- **Header icon optimization**: Guide icon moved from header to footer bar.
  Highlight toggle shrunk from 36px to 24px (`_compactHeaderButton`). Theme
  toggle added at 20px width. Net effect: cleaner header with fewer icons.
- **Footer Semantics consistency**: All three footer icons (Encyclopedia,
  Export, Guide) now have `Semantics(label: ..., button: true)` wrappers.

### Fixed

- **`stateful_density` false positive from Sleuth widgets**: Added 8 Sleuth
  overlay widget names (`SleuthOverlay`, `FloatingIssuesCard`, `TriggerButton`,
  `IssueCard`, `IssueEncyclopediaPage`, `AiChatPage`, `GuidePage`,
  `StartupMetricsPage`) to the `_frameworkWidgetNames` exclusion set in
  `RebuildDetector`. Previously, opening the overlay in FRAME mode inflated
  the structural density count and triggered a false positive.
- **Hardcoded spacing values**: Replaced `SizedBox(width: 6)` in guide page
  and `SizedBox(width: 10)` in startup metrics page with design system tokens
  (`theme.spacingXs` and `theme.spacingSm` respectively).
- **GlobalKey demo unreliable detection**: `itemExtent` reduced from 40 to 24dp
  and `itemCount` increased from 30 to 40 so the realized GlobalKey count
  reliably exceeds the >20 threshold on all phone sizes. The previous 40dp
  items left the count at 21-22 on medium phones (barely above threshold) due
  to DemoScaffold chrome (~220-300dp) and trailing-only cache at scroll
  position 0 not being accounted for in the original calculation.

### Removed

- **`sleuth_logo_painter.dart`**: Deleted hand-drawn `SleuthLogoPainter`
  CustomPainter — replaced by `Icons.pets`.

## 0.13.0

Startup Performance Tracing — measure first-frame and time-to-interactive
from `main()`, with per-phase breakdown and VM sub-phase enrichment.
Three adversarial review rounds, full 23-detector accuracy audit, causal
graph correctness fix, and ShaderJankDetector noise removal.

### Added

- **Startup measurement API**: `Sleuth.init()` captures app start time and
  framework initialization cost. `Sleuth.markInteractive()` records TTI.
  First-frame callback extracts vsync/build/raster breakdown from
  `FrameTiming`. `enrichStartupWithVmData()` accepts VM sub-phase and
  engine timestamp data for full pipeline coverage.
- **StartupDetector** (23rd detector, structural lifecycle, one-shot):
  Fires `slow_startup_ttff` when TTFF exceeds configurable thresholds
  (default 1500ms warning, 3000ms critical). Detail includes TTFF, TTI,
  first-frame breakdown, dominant phase, VM sub-phases, and engine phases.
- **StartupMetrics model**: 14 stored fields, 3 computed getters
  (`frameworkInitMs`, `preDartOverheadMs`, `engineTtffMs`), dominant phase
  detection (50% threshold), full `copyWith`/`toJson`/`fromJson` support.
- **StartupMetricsPage**: Full-screen detail page with staggered entrance
  animations, 5 conditional sections (headline, first-frame breakdown with
  progress bars, engine phases, VM sub-phases, measurement methodology).
- **Startup metrics banner** in FloatingIssuesCard: shows "TTFF: X ms ·
  TTI: Y ms" when startup data is available, tappable to open detail page.
- **`IssueCategory.startup`** across all surfaces: SleuthTheme color token,
  encyclopedia entry, FixHintBuilder, SessionMarkdownExporter section,
  SessionSnapshot serialization.
- **DetectorThresholds**: `startupTtffWarningMs` / `startupTtffCriticalMs`
  with validation asserts.

### Fixed

- **Causal graph hid `layout_bottleneck` from UI**: 8 rules incorrectly
  made `layout_bottleneck` a downstream effect (e.g., `setstate_scope →
  layout_bottleneck`). When a root cause was present, the issue got a
  `rootCauseId` and FloatingIssuesCard filtered it from the visible list.
  Removed all 8 rules — `layout_bottleneck` is always a root cause, never
  downstream. Rule count: 52 → 44.
- **ShaderJankDetector Impeller noise**: Removed the `shader_impeller_inactive`
  notice entirely. It fired on every page after ~2 seconds of VM polling,
  producing noisy false positives. On Impeller, the detector now correctly
  produces zero issues.
- **`stateful_density` framework widget noise** (RebuildDetector): Added
  32-entry `_frameworkWidgetNames` set and private-name filter so framework
  widgets (Scaffold, Navigator, etc.) no longer inflate structural density.
- **`shallow_rebuild_risk` framework noise**: Added `ScrollNotificationObserver`
  to the suppressed framework widgets set.
- **Clock-domain mismatch in TTFF**: Changed from monotonic `Timeline.now`
  delta to wall-clock `DateTime.now()` diff, fixing ~5-50ms measurement skew.
- **Deferred VM enrichment buffer**: `_PendingEngineEvents` now stores all
  6 fields (4 VM sub-phases + 2 engine timestamps) so enrichment arriving
  before the first-frame callback is not lost.
- **Network issues persisted across routes**: Replaced time-based 30s
  staleness eviction with route-transition clearing. Network issues (slow
  requests, frequency spikes, large responses, error spikes, duplicates)
  now persist on the current page until the user navigates away, then clear
  immediately. Prevents stale issues from appearing on unrelated pages.
- **`clearRecords()` did not clear `_activeRequests`**: In-flight request
  tracking from the previous page persisted after route transition, causing
  `pendingRequestSnapshot()` to report phantom pending requests.
- **`_evaluateErrors` severity/detail domain mismatch**: `serverErrors` and
  `transportFailures` were counted across the entire buffer but compared
  against `peakCount` (peak 5-second window). Severity could escalate to
  critical based on errors outside the peak window. Now all counts are
  scoped to the peak window.
- **In-flight responses from previous page leaked into new page**: HTTP
  requests started on page A that completed after navigating to page B
  were added to the buffer, causing issues to appear on unrelated pages.
  `processRecord()` now drops records whose `startedAt` precedes the last
  `clearRecords()` call via `_ignoreBeforeTimestamp`.

## 0.12.2

Post-Codex adversarial review hardening — three robustness fixes discovered
via adversarial review of the v11 branch diff.

### Fixed

- **Timeline pipeline exception isolation** (`SleuthController._onTimelineData`):
  Added `try/finally` around `_isIteratingDetectors` flag and per-detector
  `try/catch` around `processTimelineData` and `evaluateNow` calls, matching the
  structural walk's existing isolation pattern. Previously, a throwing custom
  detector in the VM pipeline could leave `_isIteratingDetectors = true`
  permanently, deadlocking all future detector mutations.
- **Encyclopedia placeholder leak** (`IssueEncyclopediaPage`): Raw `{widgetName}`
  and `{count}` tokens were visible when browsing encyclopedia entries without a
  context issue. Now applies `IssueExplanationBuilder.substitute()` to all
  entries with a static sentinel that triggers built-in fallbacks (`'the widget'`,
  `'several'`).
- **Cookbook slow-frame detector staleness** (`SlowFrameDetector`): A single slow
  frame could keep the detector reporting indefinitely because the rolling window
  only tracked slow frames (fast frames never evicted stale entries). Added
  `_TimestampedFrame` wrapper and 10-second age eviction in `finalizeScan()`.

## 0.12.1

Pillar 6 Part 2: Overlay UI, Diagnostics Output & Export — upgrades every
consumer-facing surface a developer looks at during debugging. The trigger
button, floating card, issue card, encyclopedia, and export path all gain new
capabilities that make Sleuth's collected data visible, customizable, and
shareable.

### Added

- **Trigger button alignment config** (M1): `triggerButtonAlignment` and
  `triggerButtonOffset` on `SleuthConfig` control initial placement. Supports
  all four corners and center alignment.
- **Minimize/maximize/restore controls** (M2): Three-state window mode
  (`normal`, `minimized`, `maximized`) on the floating issues card. Minimized
  collapses to a 54px header; maximized fills the screen minus safe area.
  Pre-transition position and size are restored exactly.
- **Recurrence badge on IssueCard** (M3): Shows trending direction
  (escalating/stable/improving/new) from `RecurrenceTrend` data when available.
- **Context-aware encyclopedia entries** (M4): `IssueExplanationBuilder.substitute()`
  replaces `{widgetName}`, `{count}`, `{routeName}`, `{severity}`, `{title}`,
  and `{stableId}` placeholders with values from the triggering issue. Seven
  templates enriched with contextual placeholders.
- **Inline confidence reasoning on IssueCard** (M5): Shows
  `confidenceReason` text in expanded card when available.
- **Dismissible debug-mode banner** (M6): Warning banner on `FloatingIssuesCard`
  when `isDebugMode` is true. Tap X to dismiss; `showDebugModeBanner` config
  option to suppress entirely.
- **`Sleuth.exportSummary()` markdown export** (M7): Human-readable markdown
  report with frame stats, top issues, and causal chains. Sized for pasting
  into Slack or a PR description.
- **Copy conversation button on AiChatPage** (M8): Serializes the full AI
  chat thread plus issue context to markdown and writes to clipboard.

### Fixed

- **Tooltip crash in overlay** (IssueCard): Replaced `Tooltip` widget in
  `_confidenceBadge` with `Semantics`. Flutter 3.41.4's `Tooltip` uses
  `OverlayPortal` which requires a `_RenderTheaterMarker` ancestor — absent
  in Sleuth's bare `Overlay` stack. Confidence reason is now shown inline
  when expanded (M5) and as a `Semantics` label for accessibility.
- **Markdown escaping in copied conversation** (M8): `_copyConversation` now
  escapes `\`, `*`, `` ` ``, `#`, `[`, `]`, `<`, `>`, `|` in issue titles,
  confidence reasons, and message text to prevent GFM structure corruption.
- **Markdown escaping in session export** (M7): `SessionMarkdownExporter._escape`
  expanded from 2 to 8 characters, matching the full GFM-significant set.
- **Recurrence badge overflow** (M3): Badge text now uses `maxLines: 1` with
  `TextOverflow.ellipsis` and is wrapped in `Align(alignment: centerLeft)` to
  prevent overflow on narrow cards.
- **Semantic labels on interactive elements**: Added `Semantics` wrappers to
  AI chat back/copy buttons and floating card window control buttons
  (minimize, maximize, restore, dismiss debug banner).
- **Cookbook TooltipUsageDetector false positives**: Added framework tooltip
  message filter (`Back`, `Close`, `Open navigation menu`, etc.) so the
  cookbook custom detector no longer flags standard Material widget tooltips
  (e.g. AppBar back button) on every screen.

## 0.12.0

Pillar 6 Part 1: Public API & Authoring Surface — reduces friction at every
consumer-facing API in Sleuth. Adds preset configuration constructors, threshold
documentation, debug-mode validation, `Duration`-typed intervals, a
`SimpleStructuralDetector` helper base class, key-based gating for custom
detectors, and a three-file custom-detector cookbook in the example app.

### Breaking

- **`SleuthConfig.treeScanInterval` now takes `Duration` instead of `int`
  milliseconds.** The old `treeScanIntervalMs` field has been removed.
  Rewrite:

  ```dart
  // Before
  SleuthConfig(treeScanIntervalMs: 1000)

  // After
  SleuthConfig(treeScanInterval: Duration(seconds: 1))
  ```

  Raw millisecond parameters were the most frequent foot-gun in user reports
  because nothing about `int ms` communicated the unit at the call site. The
  new `Duration` API makes the unit a compile-time requirement.

### Added

- **`SleuthConfig.minimal()` and `SleuthConfig.performance()` presets** (M1):
  Two named factory constructors so new adopters don't need to read 25 field
  docs to get started. `.minimal()` enables safe structural and runtime
  detectors and disables opt-in features (network monitoring, debug callbacks,
  deep instrumentation, AI chat). `.performance()` is tuned for low-overhead
  profile runs — structural detectors only, 2 s scan interval, capture buffer
  disabled.
- **Threshold documentation** (M2): Every threshold parameter in `SleuthConfig`
  and `DetectorThresholds` now has a doc comment answering: what does this
  number mean, what's the default, and what happens if you raise or lower it?
  Copy is verified against each detector's gating code so the empirical
  claims ("values above 60 effectively disable the detector") match reality.
- **Debug-mode assert validation** (M3): `SleuthConfig` and
  `DetectorThresholds` constructors now fail fast in debug mode when given
  values that would silently misbehave (negative intervals, thresholds above
  their detector's cut-off, frequency windows that divide to zero).
- **`SimpleStructuralDetector` helper** (M5): New public base class that
  reduces custom structural-detector authoring from "implement 4 lifecycle
  methods and understand the unified walk" to "override `inspect(Element)`
  and call `report(...)` when you find a match." Handles the issue list,
  highlight list, enabled flag, and per-scan reset automatically. Exported
  from `package:sleuth/sleuth.dart`.
- **Custom detector key gating** (M6): New `BaseDetector.key` field plus
  `SleuthConfig.disabledCustomDetectorKeys: Set<String>`. Custom detectors
  that set a stable `key` can now be disabled through configuration without
  being removed from the detector list — useful for conditional enabling per
  environment. Built-in detectors are unaffected (they're gated by
  `DetectorType` via `enabledDetectors`).
- **Custom detector cookbook** (M7): New `example/lib/custom_detectors/`
  directory with three documented reference implementations covering the
  three common shapes: `TooltipUsageDetector` (`SimpleStructuralDetector`),
  `SlowFrameDetector` (runtime `BaseDetector` hooked to
  `SchedulerBinding.addTimingsCallback`), and `RasterHotSpotDetector` (hybrid
  `BaseDetector` combining VM raster timings with a structural walk). Each
  file is a complete, heavily-commented implementation. The cookbook ships
  with a README index, a new "Custom Detector Cookbook" demo screen in the
  example app wired into `Sleuth.track`, and an
  `example/test/cookbook_smoke_test.dart` that validates every detector
  compiles against the public `package:sleuth/sleuth.dart` barrel and flags
  Tooltips end-to-end on a real widget tree.

### Fixed

- **Real-device first-launch VM connection**: Replaced `Service.getInfo()`
  with `Service.controlWebServer(enable: true)` to proactively start the VM
  web server on cold start. Previously, launching via USB/WiFi from Android
  Studio or terminal could leave Sleuth stuck in BASIC/FRAME mode for the
  entire session because the VM web server hadn't bound its port yet.
  - 3 s owned-timer timeout (avoids `Future.timeout` timer leak in tests)
  - `_connectInFlight` concurrency guard prevents duplicate connect attempts
  - IPv4→localhost rewrite enables dual-stack Happy Eyeballs resolution
  - Background reconnect ladder (500 ms → 30 s, 7 attempts) when initial
    connect fails, with mid-session VM death recovery
  - Manual `reconnect()` method for "Tap to reconnect" overlay hook
- **frameStatsNotifier self-feedback loop**: Throttled notifier emission to
  ~5 Hz (200 ms minimum). Previously, 60 Hz emission caused Sleuth's own
  overlay rebuilds to dominate the VM build-event count and trigger false
  `rebuild_activity` on idle screens.
- **Unified walk exception isolation**: Per-detector try/catch in the tree
  walk visitor. Previously, one custom detector throwing in `checkElement`
  would kill the walk for all 16 detectors and skip the entire subtree.
- **Post-dispose continuation guards**: Added `_disposed` checks after every
  `await` in `VmServiceClient._connectImpl` to prevent leaked VmService
  instances and poll timers when dispose races with connection setup.
- README quick-start now shows `SleuthConfig.minimal()` alongside the full
  configuration snippet so first-time adopters see the easy path first.

### Tests

- 1,869 tests passing (1,825 → 1,869, +44 across M1–M7 + VM connection +
  throttle coverage).
- 5 cookbook smoke tests in the `example/` package confirm the cookbook
  compiles against the public API and flags tree content correctly.

## 0.11.1

Pillar 5 Part 2: Demo Quality Enhancements & Combined Demos — Before/After toggle,
live metrics bars, reproduction instructions, and two realistic multi-detector
scenarios (E-Commerce and Chat). Three adversarial review rounds, 18 findings resolved
(9 Pillar 5 Part 2 + 4 demo polish + 5 demo↔detector alignment) plus a
`KeepAliveDetector` false-positive bug fix discovered during the chat demo migration.

### Demo Quality Enhancements (Pillar 5, Part 2)

- **Before/After toggle in DemoScaffold** (M8): Upgraded `DemoScaffold` from `StatelessWidget`
  to `StatefulWidget`. When a demo supplies a `fixedBody`, a Material 3 `SegmentedButton`
  appears just below the AppBar letting developers switch between the anti-pattern and its
  corrected version in-place. The ternary swap in the build tree fully unmounts the hidden
  side, so timers, animations, and controllers in the non-visible subtree stop automatically.
  An optional `onToggle` callback lets demos reset counters or pause global callbacks when
  the user flips the switch.
- **Fixed-pattern implementations for all 23 demos** (M9): Every existing demo now ships a
  real, working "Fixed Pattern" body — not a text description. Each fix matches what the
  detector is meant to catch: `ValueNotifier` + `ValueListenableBuilder` for setState scope,
  `ListView.builder` + `itemExtent` for non-lazy lists, `cacheWidth`/`cacheHeight` for
  image memory, `GlobalKey` stored as `final` fields, extracted `AnimatedBuilder.child`,
  `Isolate.run()` for heavy compute, and so on.
- **Live metrics bar** (M10): New `MetricsBar` + `MetricChip` widgets render a compact row
  of live counters between the description and the body. Wired into `high_level_setstate`
  (Bad/Fixed rebuilds), `non_lazy_list` (built widgets), `heavy_compute` (compute time ms),
  `fps_stress_test` (live FPS via `SchedulerBinding.addTimingsCallback`), `repaint_stress`
  (paints/sec sliding window), `network_stress` (request count), and `memory_pressure`
  (retained MB). Counters reset on toggle so the Before/After comparison is honest.
- **Reproduction instructions on every demo** (M11): Every `description` string now follows
  the `❌ BAD / ✅ FIX / ▶ <action>` format with an explicit imperative action telling the
  developer what to tap, scroll, or watch to see Sleuth flag the issue.
- **Combined E-Commerce Page demo** (M12): New `combined_ecommerce_demo.dart` — a realistic
  product detail page that stacks 5 anti-patterns: 6-hero carousel with full-resolution
  images (ImageMemory), rotating price `AnimatedBuilder` with no extracted child, size chip
  row wrapped in `IntrinsicHeight` (LayoutBottleneck), 200-review non-lazy `ListView`, and
  4 `GlobalKey()` instances created fresh on every build. The fixed body applies every
  corresponding fix including a `Visibility` swap for the previously `Opacity(0.0)` loading
  banner.
- **Combined Chat App demo** (M13): New `combined_chat_demo.dart` — a tabbed messaging
  interface with 5 conversations, all using `AutomaticKeepAliveClientMixin` (KeepAlive),
  uncached circular avatars (ImageMemory), a 40ms simulated-platform-channel "typing"
  poll (PlatformChannelTraffic at 25 calls/sec — above the 20/sec threshold), and
  top-level `setState` on every incoming message (SetStateScope + Rebuild). The fixed
  body debounces the typing poll, caps keep-alive to 2 tabs, isolates the message list
  in a `ValueNotifier`, and extracts the text input into its own `StatefulWidget`.
  `debugProfilePlatformChannels` is saved/restored on dispose and never clobbers a
  developer's global setting.
- **Home screen wiring** (M14): Added E-Commerce and Chat entries to the "Combined" category
  in `main.dart`. Demo count: 23 → 25.

### Adversarial Review Findings (Pillar 5 Part 2)

Two rounds of review focused on (a) whether the "fix" in each demo actually eliminates the
detector rather than merely masking it, and (b) whether the new `StatefulWidget` demos
leak timers, controllers, or client handles on dispose or navigation-away. 9 real findings
across 3 demos, all resolved.

- **FAB double-action neutralizes the fix** (CRITICAL, three demos): In
  `combined_analytics_dashboard_demo.dart`, `combined_social_feed_demo.dart`, and
  `high_level_setstate_demo.dart`, the FAB handler called both `_counter++ +
  fixedCounter.value++` AND `setState(() {})` unconditionally. Even when the user had
  switched to the fixed body, the outer `State`'s top-level `setState` rebuilt the entire
  subtree — burying the `ValueListenableBuilder`'s isolated update and hiding the fix the
  demo was meant to demonstrate. Most severe in `high_level_setstate_demo` because
  `_FixedBody`/`_FixedGrid` are not `const`, so the top-level rebuild hit every tile.
  **Fix:** Added an `_isFixed` field synced via `onToggle`; the FAB only calls `setState`
  when `!_isFixed`, so the fixed path's isolated rebuild is actually isolated.
- **E-Commerce hero carousel never reached ImageMemoryDetector threshold** (CRITICAL):
  `ImageMemoryDetector` flags at `count > 5`, but the demo's horizontal
  `ListView.builder` only realized 2–4 hero items due to the default 250px cacheExtent on
  phones — the 6-hero carousel never actually placed >5 `Image.network` widgets in the
  tree simultaneously, so the detector silently never fired. **Fix:** Converted both bad
  and fixed hero carousels to `SingleChildScrollView` + `Row`, forcing all 6 heroes into
  the element tree. The fixed version still shows the `cacheWidth: 520` improvement.
- **E-Commerce "fixed" reviews ListView wasn't actually paginated** (HIGH): The fixed body
  used `ListView.builder(shrinkWrap: true, physics: NeverScrollableScrollPhysics)` inside
  a `SingleChildScrollView`. Under infinite main-axis constraints, `shrinkWrap` still
  realizes every one of the 200 items — the "pagination" fix didn't paginate anything.
  **Fix:** Wrapped the inner `ListView.builder` in `SizedBox(height: 480)` to give it a
  bounded viewport; only the visible window is realized.
- **HttpClient leak on mid-request dispose** (HIGH, `network_stress_demo.dart`):
  `_triggerFrequencySpike` awaited `Future.wait([40 gets])` and then early-returned on
  `!mounted` before closing the `HttpClient`. Navigating away mid-flight leaked the client
  until GC. **Fix:** Moved `client.close(force: true)` into a `finally` block so cleanup
  runs on every exit path.
- **Unbounded log growth** (MEDIUM, `network_stress_demo.dart`): `_log` grew by every
  toggle and tap; long demo sessions janked the `ListView` rendering it. **Fix:** Added
  `_maxLogLines = 200` with trim-on-append in `_addLog`.
- **Unbounded message list growth** (MEDIUM, `combined_chat_demo.dart`): The 40ms message
  arrival timer did `[...notifier.value, msg]` on every tick. Long sessions would blow
  past 1,000 messages per tab. **Fix:** Added `_maxMessagesPerTab = 100` via an
  `_appendCapped` helper that drops the oldest entry when full.
- **Narrow exception handling in typing poll** (LOW, `combined_chat_demo.dart`):
  `_startBadTypingPoll` only caught `MissingPluginException` and `PlatformException` —
  any other throw tore down the demo. **Fix:** Added a defensive `catch (_)` fallback
  plus a `mounted` guard so the poll keeps running if the platform side misbehaves.

Self-attacks on the fixes (second-order regressions checked): the `_isFixed` gate uses a
single boolean synced synchronously from `onToggle`; there's no path where the FAB fires
before the toggle completes, because `setState` in `DemoScaffold._handleToggle` runs before
`widget.onToggle?.call`. The `try/finally` in `_triggerFrequencySpike` runs even on
throw-during-await, so `client.close` is guaranteed. The 480px review viewport is large
enough to show a page of reviews on phones but small enough that the `ListView.builder`
only realizes ~8 items at a time.

### KeepAliveDetector False-Positive Bug Fix (uncovered during chat demo migration)

Symptom: the chat demo's fixed mode (only 2 of 6 tabs opting in) still reported "excessive
keep-alive" — same as the bad mode. Investigation revealed two layered bugs in
`KeepAliveDetector`:

1. The detector matched `KeepAlive` widgets by type name, but Flutter's
   `AutomaticKeepAlive.build()` ALWAYS wraps its child in `KeepAlive(keepAlive: ...)` —
   so a string match counts every page regardless of opt-in.
2. Falling back to `element.widget.keepAlive` is also wrong: `AutomaticKeepAlive` updates
   the child render object's parent data via `ParentDataElement.applyWidgetOutOfTurn()`,
   which mutates the render object but does NOT replace `element.widget`. So
   `widget.keepAlive` stays at the stale `false` from the very first build, even after
   the keep-alive flips to `true`.

**Fix:** Read `element.renderObject.parentData` and cast to `KeepAliveParentDataMixin`.
That's the authoritative signal that the framework itself uses for retention decisions.
Added `_isActiveKeepAlive()` helper in `lib/src/detectors/keep_alive_detector.dart`.

Added 2 regression tests in `test/detectors/keep_alive_detector_test.dart`:
`_OptOutKeepAlivePage` (all `wantKeepAlive=false`, must NOT fire) and
`_ConfigurableKeepAlivePage` (mixed wantKeepAlive, mirrors the chat demo fixed pattern).
Test count: 1,823 → 1,825.

### Adversarial Review Round 5 — Migrated Demo Polish (4 findings)

A dedicated review pass over the demos migrated to `DemoScaffold` in M9:

1. **CRITICAL `non_lazy_list_demo.dart`**: `_BadBody.build()` and `_FixedBody.build()` both
   contained `builtCount.value = 0;` at the start of build. On rebuild (after the post-frame
   callback had set the counter non-zero), this called `notifyListeners` which marked the
   ancestor `ValueListenableBuilder` in MetricsBar dirty during the build phase, risking
   "setState or markNeedsBuild called during build" assertion. **Fix:** removed in-build
   reset; reset moved to `_handleToggle` (outside build phase). Kept `var running = 0;` +
   post-frame publish pattern.
2. **TEXT `combined_chat_demo.dart`**: description said "cacheWidth: 48" but code uses `64`;
   code comment said "48px for 24×24 avatars" but avatars display 32×32. Aligned to 64 and
   32×32 for high-DPI.
3. **TEXT `combined_ecommerce_demo.dart`**: description said "cacheWidth: 400" but code uses
   `520`. Aligned to 520.
4. **CONVENTION `fps_stress_test_demo.dart`**: missing `▶ action` marker. Added.

### Adversarial Review Round 6 — Demo ↔ Detector Alignment (5 findings)

A focused pass that asked: **does each demo actually fire the detector it claims to
demonstrate, given today's tightened thresholds?** Detectors have been narrowed across
multiple pillars (Pillar 2a hot-path, Pillar 2b lazy init, Pillar 3a/3b enrichment, the
v11 detector audit) and several demos had silently drifted below their trigger threshold —
they showed pretty UI but produced zero issue cards.

| # | Demo | Root cause | Resolution |
|---|------|-----------|-----------|
| 1 | `global_key_demo.dart` | 15 keys but `GlobalKeyDetector.threshold = 20`; description mis-stated threshold as 10 | Bumped `_itemCount` to 25; corrected description |
| 2 | `non_lazy_list_demo.dart` | 40 children but `ListviewDetector.childThreshold = 50` (fires on `> 50`) | Bumped `_itemCount` to 60 |
| 3 | `animated_builder_demo.dart` | 6 progress bars built a ~14-widget subtree, well below `AnimatedBuilderDetector.minSubtreeSize = 50` | Added `_barCount = 12`; enriched each row to `Row(SizedBox(label) + Expanded(LinearProgressIndicator) + SizedBox(percentage))`. Total subtree ≈ 135 widgets. `_StaticBarColumn` mirrors the structure for the fixed path |
| 4 | `combined_analytics_dashboard_demo.dart` | 25 tiles below ListView threshold; 25 GlobalKeys lived in `SingleChildScrollView+Column` (wrong scope — excessive branch only counts inside LV/GV/PV); recreation branch never fired because keys were a stable `final List<GlobalKey> _tileKeys` State field | Bumped `_tileCount` to 60; removed `_tileKeys` field; moved key allocation INSIDE `_BadDashboard.build()` as `final tileKeys = List.generate(...)`; wrapped `_BadDashboard` in an outer `AnimatedBuilder(animation: _controller)` so every tick rebuilds the bad subtree. Net effect: ListviewDetector fires (60 > 50) AND GlobalKey **recreation** fires (`churnCount = 60 ≥ recreationThreshold = 5`). Mirrors the same outer-AnimatedBuilder pattern used in `combined_ecommerce_demo.dart` |
| 5 | `nested_scroll_demo.dart` | Original demo had ONE `SingleChildScrollView` with 30 children — no actual nesting AND below threshold. `NestedScrollDetector` requires `parentAxis != null && scrollAxis == parentAxis` AND `childCount > 50` | Bumped `_itemCount` to 60; wrapped inner SCSV in `SingleChildScrollView > Column > SizedBox(height: 480) > SingleChildScrollView`. The bounded 480px viewport keeps the inner scrollable from crashing on unbounded height while preserving the same-axis nesting |

**Key insight uncovered:** `GlobalKeyDetector` has **two modes with different scoping**.
The **excessive** branch (`global_key_detector.dart:131`) is gated by
`_isInListLikeScrollable` and only counts keys inside `ListView/GridView/PageView`. The
**recreation** branch (`global_key_detector.dart:113-116`) collects
`identityHashCode(key)` **globally** in `checkElement`, NOT gated by scrollable scope. So
you can trigger recreation by allocating new `GlobalKey` instances inside any widget's
`build()` — as long as the build runs repeatedly. The combined_analytics fix exploits this
exactly.

**Demos audited and dismissed (no fix needed):** `custom_painter_demo`,
`font_loading_demo`, `gpu_pressure_demo`, `heavy_compute_demo`, `high_level_setstate_demo`,
`intrinsic_height_demo`, `network_stress_demo`, `opacity_zero_demo`,
`platform_channel_demo`, `repaint_boundary_demo`, `repaint_stress_demo`, `shader_jank_demo`,
`shallow_rebuild_risk_demo`, `uncached_image_demo`, `combined_chat_demo`,
`combined_ecommerce_demo`, `combined_social_feed_demo`. Each was traced through its
detector's `checkElement` path with current thresholds and confirmed to still fire.

### Files Changed (Pillar 5 Part 2)

| File | Change |
|------|--------|
| `example/lib/demo_scaffold.dart` | Upgraded to `StatefulWidget`; added `fixedBody`, `onToggle`, `metricsBar`; added `MetricsBar` + `MetricChip` helpers |
| `example/lib/demos/combined_chat_demo.dart` | New — tabbed chat with 5 anti-patterns, bounded message list, save/restore of `debugProfilePlatformChannels`, broad exception handling |
| `example/lib/demos/combined_ecommerce_demo.dart` | New — product detail page with 5 anti-patterns, bounded-height reviews list, hero carousel via `Row` (not `ListView.builder`) |
| `example/lib/demos/combined_analytics_dashboard_demo.dart` | Migrated to `DemoScaffold` with `fixedBody`; added `_isFixed` FAB gate |
| `example/lib/demos/combined_social_feed_demo.dart` | Migrated to `DemoScaffold` with `fixedBody`; added `_isFixed` FAB gate |
| `example/lib/demos/high_level_setstate_demo.dart` | Added `fixedBody` + `_isFixed` FAB gate; dual rebuild counters |
| `example/lib/demos/network_stress_demo.dart` | `HttpClient` try/finally leak fix; `_log` capped at 200 lines; added `_triggerCached` and `_triggerPaginated` fixed-body actions |
| `example/lib/demos/heavy_compute_demo.dart` | Added `Isolate.run` fixed body with compute-time metric chip |
| `example/lib/demos/fps_stress_test_demo.dart` | Added debounced/cached fixed body with live FPS metric chip |
| `example/lib/demos/non_lazy_list_demo.dart` | Added `ListView.builder` fixed body with built-widgets metric chip |
| `example/lib/demos/repaint_stress_demo.dart` | Added `RepaintBoundary`-wrapped fixed body with paints/sec metric chip |
| `example/lib/demos/memory_pressure_demo.dart` | Added bounded-pool fixed body |
| `example/lib/demos/intrinsic_height_demo.dart`, `opacity_zero_demo.dart`, `custom_painter_demo.dart`, `font_loading_demo.dart`, `uncached_image_demo.dart`, `shallow_rebuild_risk_demo.dart`, `keepalive_demo.dart`, `shader_jank_demo.dart`, `platform_channel_demo.dart`, `gpu_pressure_demo.dart`, `repaint_boundary_demo.dart` | Migrated to `DemoScaffold.fixedBody` with real corrected implementations |
| `example/lib/main.dart` | Added E-Commerce and Chat route entries in the Combined category |
| `lib/src/detectors/keep_alive_detector.dart` | Bug fix: read `KeepAliveParentDataMixin` from render-object parent data instead of stale `widget.keepAlive` (added `_isActiveKeepAlive` helper) |
| `test/detectors/keep_alive_detector_test.dart` | Added 2 regression tests: `_OptOutKeepAlivePage`, `_ConfigurableKeepAlivePage` |
| `example/lib/demos/global_key_demo.dart` | Round 6: 15 → 25 keys (above `threshold=20`); corrected description |
| `example/lib/demos/non_lazy_list_demo.dart` | Round 6: 40 → 60 children (above `childThreshold=50`); Round 5: removed in-build counter reset (race) |
| `example/lib/demos/animated_builder_demo.dart` | Round 6: 6 → 12 progress bars + richer Row structure (~135 widgets > `minSubtreeSize=50`); `_StaticBarColumn` mirrors |
| `example/lib/demos/combined_analytics_dashboard_demo.dart` | Round 6: 25 → 60 tiles; in-build `GlobalKey` allocation; outer `AnimatedBuilder` wrap forces per-tick rebuilds → ListView (60>50) AND GlobalKey recreation (churnCount=60≥5) both fire |
| `example/lib/demos/nested_scroll_demo.dart` | Round 6: 30 → 60 children; added outer `SingleChildScrollView > Column > SizedBox(480)` wrapper (original demo had no nesting at all) |

## 0.11.0

Pillar 5 Part 1: Demo Infrastructure & Missing Detector Demos — DemoScaffold shared
layout, 5 new demos, and categorized home screen navigation.

### Demo Infrastructure (Pillar 5, Part 1)

- **DemoScaffold** (M1): Shared scaffold with collapsible description banner, AppBar, and
  Expanded body slot. All 23 demos use consistent layout with `BAD:`/`FIX:` annotations.
- **Shader Jank demo** (M2): Navigates to a page with BackdropFilter(σ=20), ShaderMask,
  ColorFiltered, and combined effects. Includes Impeller caveat (pre-compiled shaders).
- **Platform Channel Traffic demo** (M3): Rapid fire (50 concurrent calls), sustained load
  (50 calls/sec via Timer.periodic), and single call modes with scrollable log. Timer
  properly cancelled in `dispose()`.
- **Memory Pressure demo** (M4): Separate Dart heap (+10MB Maps) and native (+10MB Uint8List)
  allocation buttons, GC churn mode (100 batches, retain first only), visual bar chart.
  Per-batch KB tracking for accurate MB display.
- **GPU Pressure demo** (M5): 10 cards each stacking ClipPath(antiAliasWithSaveLayer) →
  Opacity(0.85) → BackdropFilter(σ=15) → ColorFiltered, with >5 descendants per node.
- **RepaintBoundary demo** (M6): Uses SingleChildScrollView+Column (not ListView.builder
  which auto-wraps in RepaintBoundary). 14 Opacity(0.7) cards + 1 animated CustomPaint
  card. AnimationController disposed properly.
- **Home screen categorization** (M7): 8 categories (Build, Paint, GPU & Rendering, Layout,
  Memory, Network & I/O, Keys & Identity, Combined) with all 23 demos navigable.

### Adversarial Review Findings (Pillar 5 Part 1, Round 1)

- **Memory MB overcount**: `_dartMB` getter multiplied `_dartObjects.length * 10` assuming
  every batch was ~10MB, but `GC Churn` retained only a tiny sentinel batch that was then
  counted as a full 10MB. Fixed with per-batch KB tracking (`_dartBatchKB` list) so each
  batch reports its actual size.
- **Hardcoded light-theme color**: The memory visualization card used a literal
  `Colors.grey.shade100` that was unreadable in dark mode. Replaced with
  `Theme.of(context).colorScheme.surfaceContainerLow`.

### Adversarial Review Findings (Pillar 5 Part 1, Round 2)

- **GC rate dilution** (CRITICAL): `MemoryPressureDetector._evaluateGcPressure` computed
  `gcPerMinute = _gcEventCount / (now - _trackingStart).inSeconds * 60`, so the denominator
  grew unbounded across a session. A user who explored other demos for 60s then hit GC
  Churn would see `(N events / 60s+ elapsed) * 60` fall below the 30/min threshold even
  though N events in the last 5s clearly indicated pressure. Replaced with a 10-second
  sliding window (`Queue<({DateTime ts, int count})> _gcWindow`) with timestamp-based
  eviction, yielding a stable "events per 10s × 6" rate that responds to real bursts.
  All 55 memory pressure detector tests still pass.
- **setState-after-dispose in platform channel demo** (HIGH): `_triggerRapidFire` and
  `_triggerSingle` awaited `Future.wait` / `invokeMethod` without a `mounted` guard before
  calling `setState`, causing a crash if the user navigated away mid-call. Fixed by adding
  `if (!mounted) return;` after each await and guarding `_addLog` internally.
- **Global `debugProfilePlatformChannels` clobber** (HIGH): The demo hardcoded
  `debugProfilePlatformChannels = false` on dispose, silently stomping a developer's global
  setting if they had enabled it in `main.dart`. Fixed by capturing the prior value in
  `initState` and restoring it in `dispose`.
- **Memory "Dart Heap" label misleading** (MEDIUM): The stats card labeled the counter
  "Dart Heap" but the value only tracked *retained* allocations, which stayed at 0 during
  GC Churn mode. Users reasonably concluded the demo was broken. Renamed to
  "Retained (Dart)" and updated the demo description to explain that churn allocations are
  intentionally transient.
- **RepaintBoundary demo description inaccurate** (MEDIUM): Description claimed the detector
  flagged "Opacity(0.7) with 6+ descendants", but the real check is for non-trivial opacity
  values (between 0.0 and 1.0 exclusive) without a `RepaintBoundary` ancestor within 5
  levels. Rewrote to match actual detector logic, enumerating the 6 widget classes
  flagged (Opacity, ClipPath, BackdropFilter, ShaderMask, CustomPaint, ColorFiltered).
- **Impeller silent failure in shader jank demo** (MEDIUM): `ShaderCompilation` timeline
  events only fire on the Skia backend. Impeller (default iOS 3.16+, Android 3.22+)
  pre-compiles shaders offline, so the demo silently produced zero detector hits on
  modern devices and users reasonably concluded the detector was broken. There is no
  public Flutter API to detect the active graphics backend from Dart, so added a
  prominent `_ImpellerWarningBanner` at the top of the shader-heavy page explaining the
  incompatibility and instructing users to relaunch with `--no-enable-impeller`.

## 0.10.9

Pillar 4: Issue Documentation Quality — comprehensive encyclopedia content for all 46
issue types with cross-references, enriched explanations, and quality guardrail tests.

### Issue Documentation Quality (Pillar 4)

- **8 missing encyclopedia entries** (v11.20): Added entries for `duplicate_request`,
  `wrap_layout_bottleneck`, `sliver_to_box_adapter_large`, `sliver_fill_remaining_scrollable`,
  `sliver_to_box_adapter_shrinkwrap`, `global_key_recreation`, `excessive_repaint_boundary`,
  and `runtime_font_loading`. Total entries: 38→46. Every detector stableId now resolves
  to a non-null explanation.
- **Stale count fix** (v11.21): Removed hard-coded "37 issue types" from encyclopedia doc
  comment. Added missing `http_error_spike` to test coverage.
- **readingTheData for all entries** (v11.22): All 46 entries now include "Reading the data"
  with real-world analogies, threshold interpretation, and normal-vs-abnormal guidance.
  Structural entries that previously had `null` readingTheData now explain element counts,
  thresholds, and what the numbers mean.
- **Build-phase enrichment** (v11.23): `heavy_compute` howToFix adds `Isolate.run()` vs
  `compute()` code examples. `setstate_scope` adds `ValueListenableBuilder` extraction
  pattern. `animated_builder_no_child` explains why `child` is reused.
- **Memory/image enrichment** (v11.24): `gc_pressure` adds micro-stutter description + const
  constructor example. `heap_growing` adds DevTools Memory tab walkthrough (retained vs
  shallow size). `uncached_images` adds `ResizeImage` pattern.
- **Paint/layout enrichment** (v11.25): `excessive_repaint` adds RepaintBoundary "island"
  concept. `missing_repaint_boundary` adds when-NOT-to-add guidance. `layout_bottleneck`
  adds `CrossAxisAlignment.stretch` alternative. `opacity_zero` adds Visibility flag
  explanations (`maintainSize`, `maintainState`, `maintainAnimation`).
- **Raster/network/scroll enrichment** (v11.26): `shader_compilation` adds Impeller context.
  `platform_channel_traffic` adds Pigeon code-gen + EventChannel patterns. `non_lazy_list`
  adds `ListView.builder` code + `itemExtent` tip. `nested_scroll_same_axis` adds
  `CustomScrollView` migration snippet.
- **Related issues cross-references** (v11.27): New `relatedIssues` field on
  `IssueExplanation` typedef. All 46 entries populated with bidirectional cross-references
  derived from the causal graph (52 rules). If A lists B, B lists A.
- **Related issues UI rendering** (v11.28): Encyclopedia entries show "Related issues"
  section with tappable chips. Tapping a chip expands and scrolls to the target entry.
  AI context builder includes related issues in system prompts. Search matches related
  issue display names.
- **Content quality guardrail tests** (v11.29): Automated regression tests enforce minimum
  word counts (whatItIs ≥ 20, whyItMatters ≥ 20, howToFix ≥ 30), metric thresholds in
  readingTheData (≥ 25/46 entries), analogy patterns, code examples (≥ 10 entries), DevTools
  references (≥ 5 entries), and comprehensive stableId completeness.

### Adversarial Review Findings (Pillar 4)

- **Chip scroll-to bug** (CRITICAL): Related issue chip tap in encyclopedia used a single
  `_scrollTargetKey` that only pointed to the initial `scrollToStableId`, not the tapped
  chip's entry. Tapping any chip would scroll to the wrong target or nowhere. Fixed by
  replacing single GlobalKey with per-entry key map (`Map<String, GlobalKey> _entryKeys`).
- **Missing bidirectional relatedIssues** (LOW): `repaint_debug` was the only runtime entry
  without relatedIssues. Added cross-references to `excessive_repaint`,
  `excessive_repaint_debug`, and `missing_repaint_boundary` (and reverse entries).
- **Content below quality thresholds** (LOW): Several entries had readingTheData without
  metric patterns matching the guardrail regex. Enriched `raster_cache_growing`,
  `gc_pressure`, `heavy_compute`, `expensive_gpu_nodes`, and `excessive_repaint_debug`
  with specific numeric thresholds.

## 0.10.8

Pillar 3b: Enrichment — output & presentation improvements that make diagnostics more
actionable without adding new detection capabilities.

### Enrichment — Output & Presentation (Pillar 3b)

- **Confidence explanations** (`confidenceReason`): Every issue now explains *why* its
  confidence is confirmed/likely/possible — what evidence was used, what would upgrade it.
  Confirmed: "Measured directly from {source}". Likely: "{evidence1} + {evidence2}".
  Possible: "Structural scan only — {upgrade hint}". Correlator appends escalation context
  when upgrading confidence. Displayed as tooltip on the confidence badge in IssueCard.
- **Severity auto-escalation**: Warning-severity issues that persist for 30+ scan cycles
  (cumulative, not consecutive) automatically escalate to critical. Prevents alert fatigue
  from persistent warnings that never resolve. Uses existing `RecurrenceTrend.presentCount`
  — no separate state map needed.
- **Structural + runtime correlation** (2 new correlator rules):
  - `EscalateStructuralWithJankRule`: structural issues (non_lazy_list, layout_bottleneck,
    nested_scroll, etc.) upgrade possible→likely when sustained_jank/jank_detected co-occurs.
  - `EscalateStructuralWithRebuildRule`: animated_builder_no_child/setstate_scope upgrade
    possible→likely when rebuild_activity co-occurs.
- **Code location precision**: `buildAncestorChain()` now appends source location
  (`file:line`) for each non-framework ancestor, not just the leaf element. Added
  `lookupStructured()` returning structured data with package name extraction. New
  `packageName` field on `PerformanceIssue` from leaf element source location.
- **Session summary export** (`sessionSummary`): Pre-computed summary in SessionSnapshot
  with 5 fields: `topIssues` (top 5 by ranking score), `causalEdges` (active cause→effect
  pairs), `frameHistogram` (duration bins: <16ms/16-33ms/33-50ms/50-100ms/>100ms),
  `detectorHitRates` (issue count per detector), `memoryTrendSummary` (heap growth stats).
  Schema version bumped to v3. Backward compatible with v2 exports.

### Adversarial Review Findings (Pillar 3b)

- **Missing stableId prefix mappings**: `_detectorNameFromStableId()` was missing entries
  for `shader_compilation` (shaderJank), `repaint_debug_` (repaint), and `stateful_density`
  (rebuild) — these fell through to 'custom' in detector hit rates. Fixed by adding 3 entries
  to the prefix map.

### Full Branch Adversarial Review (Pillars 1-3)

- **Scan chain exception safety** (HIGH): Adaptive self-rescheduling scan loop could die
  permanently if any detector threw during `_runStructuralScans()` or `_aggregateIssues()`,
  leaving `_isIteratingDetectors` stuck true and preventing future scans. Fixed with
  `try/finally` in `_scanTree` (always clears iteration guard and drains mutations) and
  `try/catch` in `_scheduleNextScan` callback (always reschedules).
- **Unstable duplicate-request stableIds** (HIGH): `duplicate_request:$dupIndex` used a
  per-scan loop index that jittered as records aged in/out of the buffer, breaking recurrence
  tracking and duration escalation. Fixed by deriving stableId from a stable method+URL
  hash fingerprint.
- **POST requests falsely flagged as duplicates** (MEDIUM): Duplicate detection grouped by
  method+URL without considering request body, flagging POSTs with different payloads as
  duplicates. Fixed by limiting duplicate detection to idempotent methods (GET/HEAD/OPTIONS).
- **GlobalKey recreation false positive on route change** (MEDIUM): Cross-scan key identity
  comparison was not scoped to a stable route, so page transitions with similar GlobalKey
  counts triggered false recreation warnings. Fixed by tracking scan root identity and
  resetting previous key set on route change.
- **Missing sliver stableIds in correlator** (MEDIUM): `EscalateStructuralWithJankRule` only
  covered legacy list IDs, missing 5 new sliver anti-pattern IDs added in Pillar 1. These
  stayed at `possible` even with jank evidence. Fixed by adding all sliver IDs to `_structuralIds`.

## 0.10.7

Pillar 3a: Enrichment — analysis & tracking features that deepen diagnostic intelligence
beyond per-frame detection.

### Enrichment — Analysis & Tracking (Pillar 3a)

- **Expanded causal chain rules**: 15 new `CausalRule` entries (8 logical patterns) linking
  setState→rebuild, uncached images→GC pressure, animated builder→repaint, layout bottleneck→jank,
  font loading→jank, platform channel→heavy compute, and duplicate requests→rebuilds. Total rules:
  37→52.
- **Historical trending time-series** (`RecurrenceTrend`): Ring-buffered (capacity 60) per-issue
  presence/absence tracker with `TrendDirection` computation (worsening/improving/stable/intermittent).
  Replaces flat `_recurrenceCounts` map. Stale eviction after 120 absent cycles. Exported in
  session snapshots as summary-only (trend + counts, not raw ring buffer).
- **Interaction context enrichment**: Added `typing` and `appLifecycle` to `InteractionContext`.
  Keyboard detection via `WidgetsBindingObserver.didChangeMetrics()` with debounced transitions.
  App lifecycle forwarding via `didChangeAppLifecycleState()`. Priority ordering:
  navigating > typing > scrolling > idle > appLifecycle. `appLifecycle` deprioritized in ranking
  alongside `scrolling`.
- **Widget heat map aggregation** (`WidgetHeatMapEntry`): Lazy per-widget issue aggregation for
  "top offenders" ranking. Filters ~50 framework widget names (layout primitives, scrollables,
  scaffold/chrome, builders, buttons). Sorted by cumulative ranking score. Exported in session
  snapshots.
- **Fix verification** (`FixBaseline`, `FixVerificationResult`): Manual baseline capture with
  5-cycle cooldown before declaring issues resolved. 3-cycle hot-reload grace period (resets
  absence counters on reassemble). Per-issue status: resolved/improved/unchanged/worsened/newIssue.
  Public API: `Sleuth.captureBaseline()`, `Sleuth.compareToBaseline()`, `Sleuth.hasBaseline`,
  `Sleuth.clearBaseline()`.

### Adversarial Review Findings (Pillar 3a)

- **Incomplete framework widget filter**: `_frameworkPrefixes` was missing common widgets
  (ListView, GridView, Scaffold, AppBar, buttons, etc.) — heat map could surface framework
  widgets as "top offenders". Fixed by adding 18 additional framework widget names across
  scrollables, scaffold/chrome, and button categories.
- **Grace period not resetting baseline counters**: `notifyReassemble()` set the grace period
  but did not clear `consecutiveAbsentCycles` — hot reload after 4 absent cycles + 1 more
  could falsely report an issue as resolved. Fixed by clearing absence counters on reassemble.

## 0.10.6

Pillar 2b: Resource management — reduce CPU, memory, and GC pressure from Sleuth's own
runtime overhead when the app is healthy.

### Performance — Resource Management (Pillar 2b)

- **Adaptive scan frequency** (M4): Replaced fixed `Timer.periodic(1s)` with self-rescheduling
  `Timer`. After 3 consecutive clean (zero-issue) scan cycles, the interval doubles (capped
  at 2s). Returns to normal immediately when issues appear. `FrameTiming` and VM timeline
  paths remain event-driven and unaffected. Opt out via `SleuthConfig(adaptiveScanEnabled: false)`.
- **Issue allocation reduction** (M5): `_getAllIssues()` generation-counter cache prevents
  redundant list allocations. The method is called 4+ times per timeline event — now returns
  a cached list when no detector has produced fresh issues. Generation increments on structural
  scan, timeline evaluateNow, and frame stats updates.
- **Detector lazy initialization** (M6): Factory-map pattern for non-typed detectors. Only
  detectors present in `SleuthConfig.enabledDetectors` are constructed at startup.
  `enableDetector()`/`disableDetector()` for runtime toggling. 3 typed detectors (frameTiming,
  memoryPressure, networkMonitor) always constructed (special access patterns). Custom detectors
  always present. Default config still constructs all 22 detectors.
- **Debug callback TypeNameCache** (M7): Private `Map<Type, String>` in
  `DebugInstrumentationCoordinator` replaces per-callback `runtimeType.toString()` (~1,000
  string allocations/sec). Separate from the global `typeNameCache` (not cleared per scan).
  Bounded naturally by unique widget types (~50–200).

### Adversarial Review Findings (Pillar 2b)

- **Timer leak after dispose** (M4): `_scheduleNextScan()` could create an infinite orphan timer
  chain if `dispose()` ran while the timer callback was mid-flight. Fixed by adding `_disposed`
  guards at method entry, timer callback entry, and post-frame callback entry.
- **Parallel timer chains** (M4): Rapid `startTreeScanning()` calls (e.g. widget remount during
  hot reload) could create duplicate timer chains. Fixed by adding `_scanTimerGeneration` counter
  — stale callbacks bail out when the generation no longer matches.
- **Concurrent detector modification** (M6): `enableDetector()`/`disableDetector()` could mutate
  the `_detectors` list during active iteration in scan or timeline paths. Fixed by adding
  `_isIteratingDetectors` guard — mutations are deferred to `_pendingDetectorMutations` and
  drained after the iteration completes. Typed detector flag-flips remain immediate (no list
  mutation).

## 0.10.5

Pillar 2a: Hot-path performance optimizations — reduce Sleuth's own runtime overhead.

### Performance — Hot Path (Pillar 2a)

- **Widget type name cache** (M1): Shared `TypeNameCache` (`Map<Type, String>`) eliminates
  redundant `runtimeType.toString()` string allocations during the unified tree walk.
  On a 5K-element tree with ~50 unique widget types, reduces ~15,000+ duplicate allocations
  per scan to ~50. Applied across 11 detectors and `buildAncestorChain`.
- **Highlight generation dirty-check** (M2): `_collectHighlights()` now skips the list
  spread, generation increment, and notifier update when no highlights exist before or
  after the scan. Eliminates unnecessary `CustomPainter` repaint every scan cycle during
  normal operation (no issues detected). Includes defensive selected-highlight clearing.
- **Timeline parser case-matching** (M3): Replaced `toLowerCase()` per-event string
  allocation with direct multi-case matching for all known Flutter timeline event name
  variants (BUILD/build/Build, LAYOUT/layout/Layout, etc.). Eliminates 2 string
  allocations per timeline event.

### Adversarial Review Findings (Pillar 2a)

- **Stale selected highlight** (M2): Traced all code paths — zero→zero fast path cannot
  leave `selectedHighlightNotifier` stale in practice (non-empty→empty transition always
  triggers full collection). Added defensive null-clear as belt-and-suspenders.
- **Custom detector cache reuse** (M1): Verified that custom detectors calling `scanTree()`
  after the unified walk correctly reuse cache entries from the same scan cycle.
- **Timeline case coverage** (M3): Verified all known Flutter timeline event name variants
  across v2.x and v3+ are covered. `_isChannelEvent` handles actual
  `debugProfilePlatformChannels` format (`'Platform Channel send ...'`).

## 0.10.4

v11 detector audit Part 4 (v11.19): Sliver anti-pattern detection in ListviewDetector.

### v11 Detector Audit — Part 4 (v11.19)

- **Sliver anti-pattern detection** (v11.19): `ListviewDetector` extended with 3 new
  checks for common CustomScrollView misuse patterns:
  - **Check A**: SliverToBoxAdapter wrapping Column/Row with >50 children — defeats
    lazy loading. Warning at >50, critical at >150 children.
  - **Check B**: SliverFillRemaining(hasScrollBody: false) containing a scrollable
    child (ListView, GridView, CustomScrollView, SingleChildScrollView) — forces
    shrinkWrap and eager building.
  - **Check C**: SliverToBoxAdapter wrapping shrinkWrap ListView/GridView — forces
    eager measurement of all children instead of lazy loading.
  - Dedup logic prevents double-reporting when non-lazy and shrinkWrap checks overlap.
  - 3 new `FixHintBuilder` methods with actionable replacement patterns.

### Adversarial Review Findings (v11.19)

- **Check B false negative** (ListviewDetector): SingleChildScrollView inside
  SliverFillRemaining(hasScrollBody: false) was caught by the SingleChildScrollView
  branch before the Check B branch could record it. Fixed by recording the finding
  before running the non-lazy list check. Removed dead code from the later branch.
- **Missing test coverage** (ListviewDetector): No tests for Check B with
  SingleChildScrollView or CustomScrollView descendants. Added 2 tests.

## 0.10.3

v11 detector audit Part 3 (v11.13–v11.18): 6 milestones covering duplicate request
detection, GlobalKey recreation tracking, subtree cost enrichment, and thread-attributed
jank classification.

### v11 Detector Audit — Part 3 (v11.13–v11.18)

- **Builder widget suppression** (v11.13): `FrameTimingDetector` now applies a 3x
  threshold multiplier for builder-pattern widgets (e.g., `StreamBuilder`,
  `FutureBuilder`, `ValueListenableBuilder`) that are designed to rebuild frequently.
  Reduces false positive jank warnings during normal reactive updates.
- **Warmup frame suppression** (v11.14): `FrameTimingDetector` suppresses jank
  detection during the first 180 frames (~3s at 60fps). Configurable via
  `SleuthConfig.frameTimingWarmupFrameCount`. Prevents startup initialization from
  triggering spurious jank issues.
- **Duplicate request detection** (v11.15): `NetworkMonitorDetector` detects ≥3
  identical requests (same method + normalized URL) clustered within 500ms. Indicates
  missing caching, redundant fetches, or rebuild-triggered API calls. Indexed stableIds
  (`duplicate_request:0`, `duplicate_request:1`) for per-endpoint tracking. Critical
  severity at ≥10 duplicates.
- **GlobalKey recreation detection** (v11.16): `GlobalKeyDetector` tracks key
  identity across scans via `identityHashCode`. Detects symmetric churn (new keys ≈
  gone keys) indicating keys recreated in `build()` instead of stored in `State`.
  Asymmetric changes (navigation) are filtered out. Configurable threshold (default 5).
- **KeepAlive subtree cost enrichment** (v11.17): `KeepAliveDetector` now tracks
  total elements per scrollable and reports average subtree size in issue detail.
  Provides concrete cost data beyond simple page counts.
- **Thread-attributed jank classification** (v11.18): `FrameTimingDetector` classifies
  jank frames as UI-bound, raster-bound, pipeline stall, or mixed based on phase
  timestamps. Title includes bottleneck label; detail includes thread timing summary.

### Adversarial Review Findings (v11.13–v11.18)

- **maxCluster overwrite bug** (NetworkMonitor): Sliding window cluster count
  overwrote previous larger values. Fixed with `if (clusterSize > maxCluster)` guard.
- **Non-indexed stableId** (NetworkMonitor): `duplicate_request` shared across
  multiple endpoint groups. Fixed to `duplicate_request:$dupIndex`.
- **3 boundary tests added**: Duplicate cluster at exactly 500ms window, cluster at
  501ms (split), and maxCluster regression test.

## 0.10.2

v10 roadmap (12 milestones) + v11 detector audit (12 milestones).

### v11 Detector Audit

Two-part adversarial audit across 11 detectors. 12 milestones covering detection
gaps, false positive suppression, and enrichment.

**Part 1 — Accuracy & Detection Gaps (v11.1–v11.6):**

- **SliverChildListDelegate detection** (v11.1): `ListviewDetector` now catches
  `ListView(children: [...])`, `GridView(children: [...])`, and
  `CustomScrollView > SliverList(delegate: SliverChildListDelegate([...]))` —
  the non-builder constructors that build all children eagerly.
- **NeverScrollableScrollPhysics suppression** (v11.2): `NestedScrollDetector`
  no longer flags same-axis nesting when the inner scrollable uses
  `NeverScrollableScrollPhysics` or is inside a `NestedScrollView`.
- **Framework IntrinsicWidth suppression** (v11.3): `LayoutBottleneckDetector`
  no longer flags `IntrinsicWidth`/`IntrinsicHeight` inside framework widgets
  (`DropdownButton`, `AlertDialog`, `ExpansionTile`, etc.).
- **Wrap excessive children** (v11.4): `LayoutBottleneckDetector` now detects
  `Wrap` with >30 children — non-virtualized layout that measures every child.
- **Const subtree discounting** (v11.5): `SetStateScopeDetector` tracks element
  identity across scans. When rebuild evidence exists, discounts const subtrees
  from the rebuild scope count.
- **Excessive RepaintBoundary** (v11.6): `RepaintBoundaryDetector` detects >20
  user-added `RepaintBoundary` widgets inside a scrollable — excessive compositing
  layers waste GPU memory.

**Part 2 — Accuracy & Enrichment (v11.7–v11.12):**

- **FadeTransition detection** (v11.7): `OpacityDetector` now catches standalone
  `FadeTransition` settled at opacity 0.0, with deduplication to avoid
  double-counting `AnimatedOpacity`'s internal `FadeTransition`.
- **ColorFiltered GPU detection** (v11.8): `GpuPressureDetector` and
  `RepaintBoundaryDetector` now detect `ColorFiltered` widgets with deep subtrees.
  Uses widget-level check (private `_ColorFilterRenderObject` not accessible via `is`).
- **Small image suppression** (v11.9): `ImageMemoryDetector` no longer flags
  images ≤50×50 logical pixels — `cacheWidth`/`cacheHeight` savings are negligible
  for icons and small avatars.
- **TweenAnimationBuilder child** (v11.10): `AnimatedBuilderDetector` now catches
  `TweenAnimationBuilder` without `child` parameter. Skips `isFrameworkOwned` check
  since `TweenAnimationBuilder` is always user-placed.
- **Runtime font loading** (v11.11): `FontLoadingDetector` detects fonts likely
  loaded at runtime (e.g., `google_fonts`) via `fontFamilyFallback` heuristic.
  New stableId `runtime_font_loading` with severity escalation at 3+ families.
- **BackdropFilter sigma severity** (v11.12): `GpuPressureDetector` now extracts
  blur sigma from `BackdropFilter`. Low sigma (≤2.0) suppressed entirely; high
  sigma (>10.0) escalated to critical. Detail includes `σ=X.X`.

### Accuracy (v10)

- **ListView/GridView SliverChildListDelegate detection** (v10.1):
  `ListviewDetector` now catches `ListView(children: [...])` and
  `GridView(children: [...])` — the non-builder constructors that use
  `SliverChildListDelegate` internally and build all children eagerly.
  New stableIds `non_lazy_listview` / `non_lazy_gridview` with matching
  causal graph rules.
- **NeverScrollableScrollPhysics suppression** (v10.2):
  `NestedScrollDetector` no longer flags same-axis nesting when the inner
  scrollable uses `NeverScrollableScrollPhysics` — this is a standard
  Flutter pattern where the inner widget intentionally delegates scrolling
  to the parent.
- **DecorationImage detection** (v10.3): `ImageMemoryDetector` now catches
  images loaded through `DecorationImage` in `BoxDecoration` (via
  `DecoratedBox`). Previously only `Image` widgets were checked.
- **GpuPressureDetector is-checks** (v10.4): Replaced
  `runtimeType.toString()` + `contains()` type matching with direct `is`
  checks for `RenderOpacity`, `RenderClipPath`, `RenderBackdropFilter`,
  `RenderShaderMask`. Eliminates string allocation per element AND fixes
  a false positive on `RenderAnimatedOpacity` (which extends
  `RenderProxyBox`, not `RenderOpacity`).
- **LayoutBottleneckDetector widget-level checks** (v10.5): Replaced
  render-object `runtimeType.toString()` matching with widget-level
  `is IntrinsicHeight` / `is IntrinsicWidth` checks. Eliminates two
  `toString()` allocations per element (in both `checkElement` and
  `afterElement`).

### Enrichment

- **KeepAlive + MemoryPressure escalation** (v10.6): New
  `EscalateKeepAliveMemoryRule` correlator rule escalates
  `excessive_keep_alive:*` confidence from `possible` to `likely` when
  heap pressure (`heap_growing` / `heap_near_capacity`) co-occurs. New
  causal graph rules connect keep-alive → heap chains.
- **NestedScroll + LayoutBottleneck causal rules** (v10.7): New causal
  graph rules connecting `nested_scroll` / `nested_scroll_same_axis` to
  `layout_bottleneck` and `rebuild_activity`.
- **HTTP error spike detection** (v10.8): `NetworkMonitorDetector` now
  detects bursts of HTTP errors (3+ failures with status >= 400 or
  transport failures in a 5-second window). New stableId
  `http_error_spike` with `FixHintBuilder.httpErrorSpike()`, encyclopedia
  entry, and causal rule linking to `request_frequency`.
- **Rebuild + RepaintBoundary enrichment** (v10.9): New
  `EnrichRebuildRepaintBoundaryRule` correlator rule annotates rebuild
  issues (`rebuild_activity`, `rebuild_debug_*`) when
  `missing_repaint_boundary` co-occurs. Informational only — no
  confidence change.

### Performance

- **CustomPainterDetector toString** (v10.10): Replaced
  `element.widget.runtimeType.toString()` with `'CustomPaint'` literal
  in highlight creation — the widget type is already known from the
  enclosing `is CustomPaint` guard.
- **RepaintDetector map allocation** (v10.11): `_hotCounts.clear()`
  instead of `_hotCounts = {}` in `prepareScan` — reuses the existing
  map's backing store instead of allocating a new one every scan cycle.
- **NestedScrollDetector stack allocation** (v10.12):
  `_scrollAxisStack.clear()` + `.add(null)` instead of list re-creation
  in `prepareScan` — reuses the existing list's capacity from previous
  scans.

## 0.10.1

Rebrand: `widget_watchdog` → `sleuth`. All classes, imports, docs, and tests updated.

## 0.10.0

### Performance

- **`runtimeType.toString()` elimination** (v9.9): Replaced 3 of 7
  `runtimeType.toString()` call sites in scan-root resolution with zero-allocation
  `is` type checks. Covers `_findVisiblePageContext` visitor (runs on every
  element), `_findActiveRouteScanRoot`, and `_containsNestedNavigator`. The 4
  remaining sites involve private framework types (`_OverlayEntryWidget`,
  `_ModalScope`, `_ModalScopeStatus`) that cannot use `is` checks.
- **FrameStatsBuffer hot-path allocations** (v9.10): Cached `frames` getter
  (eliminates per-call `Queue.toList()`), single-pass jank counting in
  `_evaluateJank()` (replaces 2x `.where().length` + conditional `.reduce()`),
  listener-gated `FrameStatsBuffer.from()` copy (skips O(N) buffer copy when
  overlay is hidden), and lazy dirty-flag `fpsPercentiles()` caching.
- **Single-loop `_aggregateIssues()`** (v9.12): Replaced `.map().toList()` +
  `.where().toList()` chain with a single for-loop that stamps, filters, and
  collects in one pass. Eliminates 2 intermediate list allocations per
  `_aggregateIssues()` call (called from 7 locations). Behavior identical —
  the ranker receives the same visible issues in the same order.
- **Highlight overlay self-overhead** (v9.14): Replaced `saveLayer` +
  `BlendMode.clear` dim overlay with `Path.combine(PathOperation.difference)`
  — eliminates offscreen GPU buffer allocation per frame. Added generation-
  counter `shouldRepaint` via record-typed `highlightsNotifier` (single int
  comparison replaces list identity check). Selected highlight rebinds to
  fresh rect after scroll/rescan (fixes stale position tracking).
- **Inner subtree walk elimination** (v9.11): Converted 4 detectors
  (AnimatedBuilderDetector, GpuPressureDetector, GlobalKeyDetector,
  KeepAliveDetector) from inner recursive subtree walks to `afterElement`
  stack-based accumulation. Eliminates O(N*M) hot spots in the unified tree
  walk, restoring true O(N) complexity for all 16 tree-scanning detectors.
  GpuPressureDetector now reports accurate descendant counts (previously
  capped at 20).
- **FIFO eviction O(N) → O(1)** (v9.13): `NetworkMonitorDetector._records`
  and `MemoryPressureDetector._heapSamples` switched from `List` to `Queue`.
  `removeAt(0)` (which shifts all elements) replaced with `removeFirst()`
  (O(1)). Public getters unchanged — `List.unmodifiable()` accepts any
  `Iterable`. Capacities: 200 records (was 199 element shifts per eviction),
  60 heap samples (was 59 shifts).

### Fixed

- **Silent exception swallowing** (v9.15): All 8 silent `catch (_) {}` blocks
  across the codebase now log via `debugPrint` inside `assert(() { ... }())` —
  visible in debug mode, compiled out entirely in profile/release (zero
  overhead). Affected files: `sleuth_controller.dart` (2),
  `base_detector.dart`, `custom_painter_detector.dart`,
  `debug_instrumentation_coordinator.dart` (2), `widget_location.dart`,
  `source_location_cache.dart`.
- **Mounted check for ModalRoute.of** (v9.16): `_currentRouteName()` now guards
  `ModalRoute.of(_lastScanContext)` with a mounted check. The retained
  `_lastScanContext` can become detached between scans and async callbacks (VM
  timeline, heap, scroll idle). Without the guard, `ModalRoute.of()` walks an
  invalid ancestor chain on a detached element.
- **Source location cache docstring** (v9.17): No code change — the spec claimed
  the docstring said "bounded LRU cache" but git history confirms it has always
  correctly described the first-N bounded behavior since v2.4.0.
- **Timeline parser event name validation** (v9.8): Fixed silent data loss bug
  where `LAYOUT (root)` and `PAINT (root)` events (emitted by Flutter 3.13+ for
  the root PipelineOwner) were silently dropped. The parser used set `.contains()`
  which requires exact match — `'layout (root)'` failed against the set entry
  `'layout'`. Root PipelineOwner events carry the primary rendering pipeline's
  durations, so `flushLayoutDurations` and `flushPaintDurations` were missing
  their most important entries. Also removed 6 phantom name entries
  (`buildscope`, `build_scope`, `flushlayout`, `flush_layout`, `flushpaint`,
  `flush_paint`) that were never emitted by any Flutter version — verified
  against Flutter framework source history back to v2.x.
- **Opacity value semantics** (v9.1): `GpuPressureDetector` and
  `RepaintBoundaryDetector` now skip `Opacity` widgets at 1.0 (passthrough) and
  0.0 (short-circuit) — these don't trigger `saveLayer` and were false positives.
  `OpacityDetector` was already correct.
- **Layout bottleneck overclaim** (v9.4): `LayoutBottleneckDetector` now
  distinguishes nested intrinsics (critical — exponential layout passes) from
  non-nested intrinsics (warning — O(N²)). Tracks nesting depth via
  `afterElement` with abort-safe `prepareScan` reset.
- **Per-scrollable accumulation** (v9.6): `GlobalKeyDetector` and
  `KeepAliveDetector` now count per-scrollable instead of globally across all
  scrollables. Each scrollable above threshold emits its own issue with indexed
  stableIds (`'excessive_global_keys:0'`, `'excessive_keep_alive:0'`). Previously,
  keys/keep-alives from unrelated scrollables were summed together, inflating
  counts and producing false positives. **Note:** exact suppression of the old
  `'excessive_global_keys'`/`'excessive_keep_alive'` stableIds should be updated
  to prefix suppression.

### Added

- **Issue Encyclopedia** with educational "Learn more" deep-dive content for
  every detector type. Searchable, accessible from IssueCard "Learn more" link.
- **Contextual AI Chat** (`AiChatPage`): per-issue AI chat with streaming
  responses, starter questions, thinking indicator, and expandable issue context
  card. Adapter-based backend for team-provided AI providers.
- **Actionable fix hints** (`FixHintBuilder`): code snippets and debugging
  commands in fix hints for all detectors.

### Changed

- **UI: Shimmer "Ask AI" link** in IssueCard — animated purple-blue-pink
  gradient via `ShaderMask`, performance-isolated with `RepaintBoundary` and
  `AnimatedBuilder` static child pattern.
- **UI: Responsive action links** — "Learn more" and "Ask AI" share one row
  when space allows (right-aligned Ask AI), stack vertically with right-aligned
  Ask AI when overlay is narrow (<240px), via `LayoutBuilder`.
- **UI: MediaQuery granular accessors** — all UI files (`AiChatPage`,
  `FloatingIssuesCard`, `IssueEncyclopediaPage`) switched from
  `MediaQuery.of(context)` to `sizeOf`/`paddingOf`/`viewInsetsOf` to avoid
  unnecessary rebuilds.
- **UI: Status bar overlap fix** — AI chat header respects device safe area
  via `MediaQuery.paddingOf(context).top`.
- **UI: Expandable IssueCard in AI chat** — replaced minimal issue summary
  with real `IssueCard` component (capped at 40% screen height with scroll).
- **SleuthThemeData**: added `aiShimmerStart`, `aiShimmerMid`,
  `aiShimmerEnd` tokens for animated gradient styling.
- 1,490 tests total (up from 1,343), 0 analysis issues.

## 0.9.1

### Fixed

- **SetState subtree counting O(N^2) → O(N)** (v8.1): `SetStateScopeDetector`
  replaced recursive `_computeSubtreeSize` with stack-based post-order
  accumulation in `afterElement`. Abort-safety hardened with
  `notifyWalkCompleted` gate — rebuild evidence and child snapshots only
  committed on successful walks. Transactional `_pendingEvidence` staging
  prevents partial data from aborted scans.
- **HTTP monitor openUrl leak** (v8.3): `_MonitoringHttpClient.openUrl()` now
  wraps `_inner.openUrl()` in try/catch. On transport failure (DNS, TLS,
  connection refused), emits `RequestRecord(statusCode: -1)`, calls
  `onRequestEnded`, and rethrows the original exception. Callback isolation
  ensures `onRequestEnded` and `onRecord` each run in separate try/catch
  blocks — a throwing callback cannot suppress the other or mask the transport
  exception. Same isolation applied to `_MonitoringRequest.close()` failure
  path and `_MonitoringResponse._emitRecord()` success path. Survived 4
  Codex adversarial reviews.
- **Platform channel false positives** (v8.4): `TimelineParser` classifier
  replaced `cat.contains('embedder')` fallback with prefix matching for real
  `debugProfilePlatformChannels` events (`'Platform Channel send
  [channel]#[method]'`). The embedder fallback incorrectly captured vsync,
  compositor, and input events as platform channel traffic. Legacy exact-match
  names (`platformchannel`, `methodchannel`) preserved as defensive fallback.
- **Scaffold scan-root fallback** (v8.2): `_findVisiblePageContext` now supports
  three-tier scan-root resolution: (1) Scaffold path — Material `Scaffold` and
  `CupertinoPageScaffold`, (2) scaffold-free Navigator path — walks Navigator's
  overlay to find topmost route-owned onstage entry via `_ModalScope` detection,
  identity-hash route stability gate, and TickerMode-based onstage filtering,
  (3) static app fallback — `NotificationListener` element for apps without
  Navigator. `ShallowRebuildRiskDetector` and `SetStateScopeDetector` exempted
  from scaffold-free walk (depth/ratio semantics break with overlay-entry roots).
  Nested Navigator guard prevents cross-tab false positives. `refreshHighlights()`
  uses `_lastScanContext` to avoid route-stability side effects. Previously,
  Cupertino and scaffold-free apps got zero structural detection.

### Changed

- **SetState detector wording accuracy** (v8.5): user-facing detail text no
  longer claims "setState() was detected" — replaced with "Rebuild activity
  was detected" since the evidence signal (child widget identity churn) proves
  the element rebuilt, not the specific trigger. Fix hints generalized from
  "Move setState() calls" to "Scope rebuild triggers." Internal variable
  `hasEvidence` renamed to `hasRebuildEvidence`. Class docstring updated to
  describe two-tier confidence system.

### Added

- 1,343 tests total (up from 1,313), 0 analysis issues.

## 0.9.0

### Changed

- **Unified structural tree walk** (v7.9): all 16 tree-scanning detectors now
  run in a single `O(N)` pass instead of 16 separate `O(N)` walks. Four new
  `BaseDetector` lifecycle methods (`prepareScan`, `checkElement`,
  `afterElement`, `finalizeScan`) replace per-detector `scanTree` for built-in
  detectors. Custom detectors continue using `scanTree` via legacy path.
  Zero test changes required — `scanTree` base class wrapper calls the 4 methods
  automatically.

## 0.8.2

### Improved

- **Ring buffer for frame history** (v7.7): `FrameStatsBuffer` replaced
  `List<FrameStats>` with a fixed-capacity ring buffer. Eliminates GC pressure
  from growing lists during long sessions. `O(1)` insert, bounded memory.
- **Correlator sort cache** (v7.8): `FrameEventCorrelator` caches sorted event
  lists across correlation rounds. Avoids re-sorting unchanged data on every
  frame. ~40% reduction in correlator CPU time under sustained load.
- **VM reconnect polling fix** (v7.10): `_pollTimeline()` error handler now
  cancels the poll timer directly before invoking callbacks, preventing a 500ms
  error loop if `onConnectionChanged` throws. Timer cancel is idempotent —
  no impact on `reconnect()` cleanup path.

## 0.8.1

### Improved

- **HeavyCompute two-tier severity** (v7.1): events 100–500ms report as
  `medium` severity, >500ms as `high`. Previously all heavy compute events
  were `high` regardless of duration.
- **NetworkMonitor threshold fix** (v7.2): frequency limit comparison changed
  from `>` to `>=` to match documented behavior. 30 requests in 5s now
  correctly triggers the detector at the configured limit.
- **Threshold tuning pass** (v7.3): 6 detector thresholds adjusted based on
  real-app profiling data. Reduces false positives for common patterns while
  maintaining sensitivity for genuine issues.
- **Correlator coverage expansion** (v7.4): `FrameEventCorrelator` now matches
  3 additional timeline event categories that were previously ignored, improving
  phase attribution accuracy.
- **Rebuild VM fallback** (v7.5): `RebuildDetector` degrades gracefully when VM
  build counts are unavailable, falling back to structural density analysis
  instead of reporting nothing.
- **MemoryPressure warmup guard** (v7.6): heap growth detection ignores the
  first 10s after connection to avoid false positives from app startup
  allocation patterns.

## 0.8.0

### Improved

- **Controller async safety** (v6.1): VM service calls wrapped with 10 s
  timeouts and disposed-state guards. `dispose()` cancels in-flight futures
  and timeline subscriptions. Prevents `setState after dispose` and hung
  controller on lost VM connections.
- **Enrichment error logging** (v6.14): enrichment chain failures now log
  structured messages via `debugPrint` instead of silently swallowing errors.
- **AnimatedOpacity detection** (v6.2): `OpacityDetector` now detects
  `AnimatedOpacity` widgets at opacity 0 in addition to static `Opacity`.
- **ShaderMask render detection** (v6.3): `GpuPressureDetector` includes
  `RenderShaderMask` in the expensive render-tree check.
- **Nested scroll highlights** (v6.4): `NestedScrollDetector` provides
  widget highlight overlays marking the inner and outer scroll regions.
- **ListView threshold tuning** (v6.19): non-lazy `ListView` child-count
  threshold adjusted for more accurate detection with fewer false positives.
- **TriggerButton adaptive position** (v6.20): initial button position adapts
  to screen size, placing it in the visible area on all device sizes.
- **Model equality** (v6.13): `PerformanceIssue` implements `==` and
  `hashCode` based on `stableId`, enabling correct deduplication and
  `Set`/`Map` usage.
- **Suppression precompilation** (v6.15): suppression patterns compiled to
  `RegExp` once at config time instead of per-issue per-scan.
- **UI tap targets** (v6.5): header icon buttons increased to minimum 44 px
  touch target.
- **UI drag safety** (v6.6): `onPanUpdate` clamps card position within
  screen bounds on every frame.
- **UI keyboard awareness** (v6.7): floating card repositions when the
  software keyboard opens to prevent occlusion.
- **UI listener dedup** (v6.8): `ValueListenableBuilder` listeners
  deduplicated to prevent redundant rebuilds.
- **UI text overflow protection** (v6.9): long text in issue cards and
  banners protected with `maxLines` and `TextOverflow.ellipsis`.
- **GuidePage back navigation** (v6.12): hardware/system back button returns
  from GuidePage to the floating card.
- **Spacing theme tokens** (v6.21): 6 spacing tokens (`spacingXxs` through
  `spacingXl`) on `SleuthThemeData`. ~67 hardcoded spacing values replaced
  across 4 UI files. Consumers can customize overlay density via theme.
- **Benchmark robustness** (v6.22): timing budgets use `budgetMultiplier`
  that reads `CI` environment variable, preventing flaky tests on loaded
  runners.

### Changed

- **FloatingIssuesCard refactored** (v6.10): large build methods extracted
  into focused builder functions. Zero behavior change.
- **IssueCard refactored** (v6.11): build method extraction matching
  FloatingIssuesCard pattern. Zero behavior change.
- **Platform declarations** (v6.16): `pubspec.yaml` now declares `android`
  and `ios` platform support explicitly for pub.dev scoring.

### Added

- Controller lifecycle tests (v6.17): 20+ tests for dispose guards, timeout
  behavior, and error resilience.
- UI widget tests (v6.18): widget tests for FloatingIssuesCard, IssueCard,
  TriggerButton, and GuidePage interactions.
- 1,294 tests total, 0 analysis issues.

## 0.7.0

### Added

- **Issue suppression** (v4.1): `SleuthConfig.suppressedIssues` filters issues
  by `stableId` pattern (exact match or trailing `*` wildcard). Applied
  post-correlate, pre-rank. `suppressedCountNotifier` for UI display.
  `SessionSnapshot.suppressedCount` for export.
- **Custom detector plugin API** (v4.2): `SleuthConfig.customDetectors` accepts
  `List<BaseDetector>` for domain-specific detectors. Custom detectors integrate
  into all 7 controller lifecycle points (init, debug snapshot, structural scans,
  highlights, timeline data, issue aggregation, dispose). Always enabled
  regardless of `enabledDetectors`. Barrel file exports `BaseDetector`,
  `ParsedTimelineData`, `DebugSnapshot`.
- **Overlay theming** (v5.1): `SleuthThemeData` with 60 color tokens extracted
  from 6 UI files. Dark defaults match original values exactly.
  `SleuthThemeData.light()` for light-background apps. Auto-brightness
  detection via `MediaQuery.platformBrightness`. `copyWith()` for custom
  overrides. `SleuthTheme` InheritedWidget with dark fallback.
- **Export enrichment** (v5.2): `SessionSnapshot` schema v2 with `PhaseEvent`
  toJson/fromJson + rolling buffer, `GcEventSummary` + `PlatformChannelSummary`
  serializable wrappers, `FpsPercentiles` (p50/p95/p99), `rankingScore` /
  `rankingBreakdown` on `PerformanceIssue`, `recentFrames` (last 60),
  `schemaVersion` field. All new fields nullable for backward compat.
- **Causal issue graph** (v5.3): 23 cause-effect rules build a directed graph,
  identifying root causes and annotating issues with `rootCauseId` /
  `downstreamIds`. Confidence suppression hides `possible` downstream when root
  is `confirmed` / `likely`. UI: FloatingIssuesCard filters downstream from main
  list, IssueCard shows `↳ N` badge + "Related effects" section. 1 new theme
  token (`effectsBadge`).
- **Configurable detector thresholds** (v5.4): `DetectorThresholds` nested config
  class on `SleuthConfig` with 10 tunable parameters. All defaults match
  pre-change hardcoded values. Secondary severity thresholds scale with primary
  (`* 2`). Barrel exports `DetectorThresholds`.
- **Network-to-frame correlation** (v5.6): `NetworkMonitorDetector` gains active
  request tracking via `startRequest()` / `endRequest()`. `FrameVerdict` gains
  `pendingRequestCount` and `slowestPendingMs` fields. `SleuthHttpOverrides`
  gains `onRequestStarted` / `onRequestEnded` callbacks. Controller enriches all
  3 verdict paths. 2 new causal graph rules. Zero overhead when network
  monitoring disabled.
- **RepaintBoundary coverage detector** (v5.8): 22nd detector
  (`DetectorType.repaintBoundary`, structural). Walks element tree for 5
  expensive GPU widget types (`Opacity`, `ClipPath`, `BackdropFilter`,
  `ShaderMask`, `CustomPaint`), checks render tree for `RenderRepaintBoundary`
  within 3 ancestor levels. Three-tier confidence: `possible` → `likely`
  (>10/sec) → `confirmed` (>30/sec). 3 new causal graph rules.

### Changed

- **Detector registry** (v5.5): replaced 21 individual detector fields in
  `SleuthController` with unified `List<BaseDetector>` registry. 7 dispatch
  methods use lifecycle-filtered loops. Adding a new detector now requires 1 new
  file, 1 enum value, 1 line in the registry. ~-90 net lines in controller.
- **Example app modularized** (v4.5): extracted 18 demo screens from
  `example/lib/main.dart` (1,807 lines) into individual files under
  `example/lib/demos/`. `main.dart` reduced to 239 lines.
- **FloatingIssuesCard sub-widgets extracted** (v4.4): `_StatusRow`,
  `_CardFooter`, `_WarningBanners` extracted — state class reduced from 659 to
  433 lines. Zero behavior change.

## 0.6.1

### Fixed

- **FPS counter precision**: `averageFps` now uses microsecond-precision
  arithmetic instead of milliseconds, eliminating ~8% inflation from truncation
  artifacts (e.g., 6.5ms truncated to 6ms gave 167 FPS instead of 154).
- **FPS counter startup**: `_frameTiming.start()` moved before
  `await client.connect()` so the FPS counter captures frames during the
  potentially slow VM connection (1.5–10.5s), instead of showing 0.
- **FPS display capped at target**: UI now clamps displayed FPS at `fpsTarget`
  (default 60) so an idle screen in profile mode shows 60 instead of raw
  throughput values like 120+.
- **`fpsColor` target-aware**: color thresholds are now relative to `fpsTarget`
  (green >= 83%, amber >= 50%) instead of hardcoded to 50/30 FPS.
- **`exportSnapshot` reads live buffer**: uses `_frameTiming.frameBuffer`
  directly when initialized, avoiding potential staleness from the notifier.

### Added

- `TriggerButton.fpsTarget` parameter — wired from `SleuthConfig.fpsTarget`.
- FPS throughput unit tests (9 tests in `frame_stats_buffer_fps_test.dart`).
- FPS Stress Test demo screen in example app.

## 0.6.0

### Changed

- **Replaced DashboardSheet with FloatingIssuesCard**: the bottom sheet
  (1,241 lines) is replaced by a draggable floating card (~830 lines). Removed
  `FrameChart`, tabs, and filter chips. FPS is now shown directly on the
  `TriggerButton`.
- **Guide redesigned**: the Guide tab is now a full-screen `GuidePage` with
  staggered entrance animations and 4 expandable sections (Quick Start,
  Understanding the Card, Color Legend, Tips & Tricks).
- **Resizable card**: width and height adjustable via corner grip handle.
  Double-tap header to maximize/restore.

### Added

- `FloatingIssuesCard` — draggable, resizable floating panel for issue display.
- `_CornerGripPainter` — 6-dot grip handle inside the card's corner radius.
- `GuidePage` — full-screen guide with staggered fade+slide animations.
- 9 card resize tests (`card_resize_test.dart`).

### Removed

- `DashboardSheet`, `FrameChart` widget, `TabBarView` with keep-alive, filter
  chips, `AnimationController` for chart.

## 0.5.0

### Added

- **Context-aware fix hints** (v3.2): centralized `FixHintBuilder` generates
  widget-specific, location-aware fix suggestions instead of generic textbook
  advice. Hints reference the detected widget name, ancestor chain, and
  interaction context when available. `FixEffort` enum (`quick`, `medium`,
  `involved`) classifies every hint by estimated developer effort.
  - New `FixHintBuilder` utility with 28 static methods (one per issue type).
  - `fixEffort` field on `PerformanceIssue` — nullable for backward compat.
  - UI effort badge now reads from model field; keyword fallback for legacy JSON.
- **Issue-to-verdict linking** (v3.3): jank verdicts in the Live tab now connect
  to related issues in the Issues tab.
  - Amber "Jank detected" banner on Live tab when a verdict has related issues.
  - "JANK" badge on issue cards correlated with the current jank verdict.
  - Tap the jank banner to flash correlated issue cards in the Issues tab.
- **Overlay UX improvements** (v3.8): six targeted UI enhancements for the
  diagnostic workflow.
  - Widget name shown before ancestor chain in expanded issue cards.
  - "Widget not currently visible" feedback when highlight target not found.
  - Interaction context filter chips on the Issues tab (All / Idle / Scrolling).
  - "About this detection" collapsible section with source, confidence, and
    verification guidance.
  - Effort indicators (QUICK / MEDIUM / INVOLVED) on fix hint boxes.
  - Color legend in the Guide tab explaining severity and source colors.

### Changed

- All 21 detectors now use `FixHintBuilder` instead of hardcoded fix hint
  strings. No detector logic changes — only hint generation centralized.
- `PerformanceIssue` model gains `fixEffort` field (nullable, backward
  compatible). JSON without the field deserializes to null.
- Barrel file exports `FixHintBuilder` for consumers who want to generate
  custom hints.

## 0.4.0

### Improved

- **AnimatedBuilder threshold raised** (v3.1.1): subtree size threshold increased
  from 5 to 20, reducing false positives on normal animations. Confidence defaults
  to `possible` and upgrades to `likely` only when DebugSnapshot confirms rebuild
  rate > 30/sec.
- **CustomPainter secondary heuristic** (v3.1.2): added `frequent_repaint_painter`
  detection — when no always-true painters are found but CustomPaint paint rate
  exceeds 30/sec, a warning is emitted to prompt `shouldRepaint` review.
- **MemoryPressure warmup exclusion** (v3.1.3): heap trend alerts are suppressed
  during the first 5 seconds after the initial heap sample, preventing false
  positives from normal app startup allocation. GC pressure and heap capacity
  alerts are unaffected. Configurable via `SleuthConfig.memoryWarmupDurationMs`.
- **NestedScroll cross-axis suppression** (v3.1.4): horizontal ListView inside
  vertical ScrollView (and other cross-axis combinations) no longer produces
  false positives. Only same-axis nesting is flagged.
- **Opacity near-zero detection** (v3.1.5): threshold widened from exact `0.0`
  to `< 0.01`, catching visually invisible widgets that still pay layout and
  hit-testing costs. Detail text includes the actual opacity value.
- **GpuPressure structural issue preservation** (v3.1.6): when VM disconnects,
  structural issues (expensive render nodes) are preserved at `possible`
  confidence instead of being cleared entirely. Only the VM-backed raster
  dominance issue is removed.
- **PlatformChannel duration tracking** (v3.1.7): tracks cumulative per-call
  duration alongside frequency. Fires when either frequency exceeds threshold
  OR cumulative duration exceeds 8ms (configurable via
  `SleuthConfig.platformChannelDurationThresholdMs`). Detail includes top
  method names.
- **FrameEventCorrelator binary search** (v3.9): O(E×F) linear scan replaced
  with O(E log F) binary search using pre-sorted frame lists. Behavioral
  equivalence maintained for all existing tests.

### Added

- `SleuthConfig.memoryWarmupDurationMs` — warmup period for heap trend alerts
  (default 5000ms).
- `SleuthConfig.platformChannelDurationThresholdMs` — cumulative duration
  threshold for platform channel detection (default 8ms).

## 0.3.0

### Added

- **Heap trend monitoring** (v2.2): `MemoryPressureDetector` now polls
  `getMemoryUsage()` alongside the existing VM timeline poll. Tracks a rolling
  window of 60 heap samples (30 seconds) and applies linear regression to detect
  sustained growth. Two new issue types:
  - *Heap Growing* — positive slope > 500 KB/sec for 10+ consecutive seconds
    (severity: warning, confidence: likely).
  - *Heap Near Capacity* — heap usage > 80% of heap capacity (severity:
    critical, confidence: confirmed).
  - `HeapSample` data class exported for session snapshot consumers.
- **Jank CPU attribution** (v2.3): when a jank frame is detected and VM is
  connected, `getCpuSamples()` is queried for that frame's time window.
  `CpuSampleAggregator` ranks functions by exclusive ticks and surfaces the
  top 5 in `FrameVerdict.topFunctions`. Two-phase verdict emission: the verdict
  is emitted immediately, then updated with CPU attribution when samples arrive
  (or after 500 ms timeout).
  - `CpuAttribution` data class exported for snapshot consumers.
  - Dashboard shows "Top: ClassName.method (N%)" on jank verdicts.
- **Source file:line in ancestor chains** (v2.4): `buildAncestorChain()` appends
  `(lib/path/file.dart:line)` to the leaf widget when `--track-widget-creation`
  is active (debug mode default). Uses `InspectorSerializationDelegate` to
  access creation location data. Results cached per widget runtime type
  (bounded at 200 entries). Zero behavior change in profile mode.
  - `SourceLocationCache` utility with `abbreviatePath()` for `lib/`-relative
    path display.

### Changed

- `MemoryPressureDetector` enhanced: `processHeapSample()` replaces the old
  `updateHeapStats()` method. Rolling window with linear regression replaces
  percentage-based growth detection.
- `FrameVerdict` gains `topFunctions: List<CpuAttribution>?` field and
  `withTopFunctions()` copy method for two-phase enrichment.
- Session export (`exportSnapshot()`) now includes `heapSamples` array and
  CPU attribution data when available.
- Barrel file exports `CpuAttribution`, `HeapSample`, and updated
  `FrameVerdict`.
- Ancestor chain framework filter expanded: 17 additional framework widgets
  (transitions, builders, pointer/render infrastructure) are now excluded
  from ancestor chains, producing shorter and more user-relevant paths.
- Issue card no longer shows redundant "Widget:" line when the detail text
  already contains the ancestor chain.
- README "What DevTools Still Does Better" narrowed from 5 items to 2
  (heap snapshots & full flame chart). Network inspection, memory trends,
  CPU profiling, and widget-exact attribution are no longer DevTools-only.

## 0.2.0

### Breaking Changes

- **`DetectorType.memoryLeak`** renamed to **`DetectorType.memoryPressure`**.
  If you pass a custom `enabledDetectors` set, update the enum value.
- **`DetectorType.mediaQueryRebuild`** renamed to **`DetectorType.shallowRebuildRisk`**.
  Same migration: update any custom `enabledDetectors` references.
- **`DetectorLifecycle.runtime`** added to the `DetectorLifecycle` enum.
  Exhaustive switches over `DetectorLifecycle` need a new case.

### Added

- **Per-frame event correlation**: VM timeline events matched to specific frames
  by monotonic timestamp overlap, replacing batch attribution.
- **Three-tier verdict degradation**: Correlated > Full > Basic mode. Falls back
  automatically based on VM connectivity and correlation quality.
- **FrameTiming upgrades**: `totalSpan` (vsyncStart to rasterFinish) as primary
  jank indicator, pipeline stall detection, scheduler delay detection,
  build-to-raster gap measurement.
- **Debug attribution hooks** (`enableDebugCallbacks` config): opt-in per-widget
  rebuild/repaint tracking via `debugOnRebuildDirtyWidget` and
  `debugOnProfilePaint`. Default false to avoid conflicting with DevTools.
- **Heavy debug instrumentation** (`enableDeepDebugInstrumentation` config):
  per-widget timeline events using 6 Flutter debug globals with save/restore
  lifecycle. UI shows purple warning banner when active.
- **Two-tier config model**: simple top-level switches + expert `advanced` block
  (`DebugInstrumentationConfig`) for fine-grained control over attribution and
  profiling sub-flags.
- **Issue ranking**: weighted composite score (severity, frame impact, confidence,
  recurrence) determines issue ordering in the dashboard.
- **Route tagging**: automatic `routeName` stamping on issues via
  `ModalRoute.of()`. Displayed in expanded issue cards.
- **Interaction context**: `idle`, `scrolling`, `navigating` states tracked and
  stamped on issues. Shows "During: scrolling" in issue cards.
- **Rolling jank capture buffer**: worst-N frame retention (default capacity 50,
  configurable via `captureBufferCapacity`). Evicts mildest frames when full.
- **JSON session export**: `Sleuth.exportSnapshot()` and
  `exportSnapshotJson()` static methods. Dashboard export button copies JSON to
  clipboard.
- **Source-location enrichment**: ancestor chain attribution on structural and
  debug-backed issues. Displayed as "Widget: Outer > Middle > Inner" in expanded
  issue cards.
- **Timeline enrichment**: dirty widget names and counts extracted from enriched
  VM timeline args (build scope, layout, paint phases).
- **Rebuild/repaint widget highlights**: visual overlay rects highlighting hot
  widgets during scan, correlated from debug snapshot and enriched VM names.
- **`stableId`** field on `PerformanceIssue` for UI state persistence across
  scan cycles.
- **`ancestorChain`** field on `PerformanceIssue` for source-location guidance.
- **`ObservationSource`** enum distinguishing VM timeline, debug callback,
  structural, and combined sources. UI shows left-border accent (green/purple/gray).
- **Confidence badges** in dashboard: Confirmed, Likely, Possible with
  color-coded chips.
- **20th detector**: Repaint detector added as hybrid (VM + debug callback).
- **Self-overhead benchmark suite** (29 tests): per-detector scan overhead, full
  scan scaling, timeline processing, buffer bounds, issue/highlight count limits.
- **Validation matrix** (`doc/validation_matrix.md`): structured release-readiness
  checklist with per-platform grids, degradation verification, and detector
  coverage checklist.
- **Degradation contract integration tests** (9 tests): VM disconnect/reconnect,
  verdict path switching, detector group isolation.
- **5 new example app demo screens**: Opacity Zero, AnimatedBuilder No Child,
  Shallow Rebuild Risk, Font Loading Stress, Repaint Stress.

### Changed

- `MemoryLeakDetector` renamed to `MemoryPressureDetector` — honest framing;
  this detector monitors GC frequency and heap growth, not individual object leaks.
- `MediaQueryRebuildDetector` renamed to `ShallowRebuildRiskDetector` — the
  detector finds shallow StatefulWidgets during high build activity, it does not
  observe actual `MediaQuery.of()` usage.
- `RebuildDetector` now labels widget names as screen context, not proven
  rebuild attribution. Title changed to "High Rebuild Activity".
- `GpuPressureDetector` confidence corrected: `confirmed` for observed raster
  dominance, `likely` when expensive render nodes also found (was reversed).
- `OpacityDetector` no longer claims GPU waste for `Opacity(0.0)`. Repurposed
  as a correctness hint (widget still participates in hit testing, layout, and
  semantics). Confidence downgraded to `possible`, category changed to `layout`.
- Removed dead `analyzeBasicMode()` from `RenderPipelineAnalyzer`.
- `fpsTarget` config now drives jank detection thresholds (was hardcoded to
  16ms/33ms regardless of target FPS).
- `IssueConfidence` doc comments updated to describe evidence tiers accurately.
- README, barrel file, and CHANGELOG updated to match actual package behavior.

### Fixed

- Erroneous `* 1024 * 1024` multiplier on `pictureCacheBytes` in
  `FrameTimingDetector` — `FrameTiming.pictureCacheBytes` already returns bytes.
- Chart budget line and color thresholds now use per-frame `frameBudgetMs`
  instead of hardcoded 16ms/33ms, correctly supporting 120fps mode.

## 0.1.0

- Initial release
- 19 performance detectors (VM-only, hybrid, structural)
- Dual-mode analysis (Full VM Timeline + Basic SchedulerBinding)
- In-app overlay with live FPS chart, issue dashboard, and guide
- Debug mode warning banner
- Configurable thresholds and detector selection
- Zero release overhead (kReleaseMode guard)
