<p align="center">
  <img src="doc/logo.png" width="128" alt="Sleuth logo">
</p>

# Sleuth

[![Pub Version](https://img.shields.io/pub/v/sleuth)](https://pub.dev/packages/sleuth)
[![Flutter](https://img.shields.io/badge/Flutter-3.x-blue?logo=flutter)](https://flutter.dev)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](https://opensource.org/licenses/MIT)
[![Tests](https://img.shields.io/badge/tests-4%2C274_passing-brightgreen)]()
[![Analysis](https://img.shields.io/badge/analysis-0_issues-brightgreen)]()

Sleuth is an in-app performance diagnostics overlay for Flutter. It shows jank, memory leaks, slow network requests, GPU pressure and widget anti-patterns inside your app, and every issue comes with a fix hint.

<p align="center">
  <img src="doc/screenshots/overlay-dark.png" width="250" alt="Sleuth overlay, dark theme">
  &nbsp;&nbsp;
  <img src="doc/screenshots/overlay-light.png" width="250" alt="Sleuth overlay, light theme">
</p>

## Why Sleuth

Where Sleuth helps more than DevTools:

- **Always on.** There is no separate tool window or connection to set up. One line installs it, and it stays visible while you use the app.
- **20 detectors.** They include structural anti-patterns that DevTools does not flag: non-lazy lists, images decoded above display size, missing RepaintBoundary, intrinsic-height layout cost and retained stream subscriptions.
- **Inline Rebuild Stats.** In profile mode with `enableDeepDebugInstrumentation: true`, a live rebuild counter shows the top three widgets and links to the full list.
- **Confidence explanations.** Each issue's "About this detection" section names the evidence it is based on, explains why its confidence is confirmed, likely or possible, and says how to verify it.
- **Causal issue graph.** 41 rules link root causes to the issues they cause, so a card shows why an issue matters and not only that it exists.
- **Fix verification.** Capture a baseline, apply the fix, then compare. An issue counts as resolved after it stays absent for five scans, with a three-scan grace period after hot reload.
- **Historical trending.** Each issue's recurrence record shows whether it is worsening, improving, stable or intermittent across scan cycles.
- **Per-route health scores.** Sleuth detects routes without a NavigatorObserver and keeps per-route FPS, jank ratio, issues and a composite health score.
- **Network monitoring.** Sleuth flags slow requests, request floods, oversized responses, HTTP error spikes and bursts to one path (at least three GET, HEAD or OPTIONS requests to one endpoint within 500 ms). Frame verdicts note how many requests were pending and how long the slowest one had been waiting.
- **Heap trend monitoring.** Sleuth flags sustained heap growth, and process memory close to a budget you set (`DetectorThresholds.memoryBudgetBytes`), without heap snapshots.
- **CPU attribution on jank frames.** Sleuth requests the top five functions by CPU time for a jank frame, at most once every 10 s, with no manual profiling session.
- **Issue Encyclopedia.** The overlay has a searchable, cross-linked reference entry for every issue type the detectors emit. The encyclopedia labels entries for detectors removed in 0.20.0 as legacy.
- **Contextual AI chat.** Each issue has an AI assistant with streaming replies and starter questions. You bring your own provider.

What DevTools still does better:

- **Heap snapshots and the object graph.** DevTools can browse every object in the heap, inspect retention paths and track single allocations. Sleuth watches heap trends and GC pressure but cannot drill into specific objects.
- **Full flame chart and call tree.** DevTools has zoomable, interactive per-frame timelines with the complete call tree. Sleuth shows phase breakdowns with the top five functions for jank frames (at most one request every 10 s).

Use Sleuth to find a problem and its category inside the app, then use DevTools when you need to dig deeper.

## How it works

Sleuth runs four layers of analysis:

1. **Frame timing** (FrameTiming API). Sleuth reads per-frame build and raster duration, vsync overhead and cache stats. This works on every platform in debug and profile mode and is the primary signal.
2. **VM timeline** (vm_service). When Sleuth is connected to the VM service, it gets sub-phase breakdowns (buildScope, flushLayout, flushPaint, raster). Whether it can connect depends on the platform and how the app was launched. Sleuth polls every 500 ms and fetches only the events written since the previous poll, plus a 500 ms overlap that it deduplicates. It never clears the VM timeline, so DevTools keeps its view. `Sleuth.lastPollTimings` and `ext.sleuth.diagnose` report what each poll cost.
3. **Widget tree scan** (post-frame walk, once a second). The scan finds structural anti-patterns such as non-lazy lists, oversized images and missing RepaintBoundary.
4. **Network monitoring** (HttpOverrides). Sleuth intercepts HTTP traffic to detect slow requests, frequency spikes, oversized responses and HTTP error bursts, with no change to the app's networking code. It sees only `dart:io` `HttpClient` traffic; `cronet_http`, `cupertino_http` and platform-SDK networking are invisible to it.

## Quick start

```dart
import 'package:sleuth/sleuth.dart';

void main() => runApp(Sleuth.track(child: MyApp()));
```

The overlay appears in debug and profile mode. Release builds disable it completely.

Sleuth requires Flutter 3.32 or later (Dart 3.8 or later).

## Running

```bash
# Profile mode (recommended, accurate timing data)
flutter run --profile

# Debug mode (works, but timing is less representative)
flutter run
```

## MCP integration

You can drive Sleuth from your AI assistant. The
[`sleuth_mcp`](packages/sleuth_mcp) sidecar connects Sleuth's seven
`ext.sleuth.*` VM service extensions to MCP clients (Claude Code, Cursor,
Zed), so the assistant can query live issues, route health and snapshots
in conversation, with the same signals as the overlay. Every response
carries `connectionMode` (`correlated`, `full`, `basic`, `warmup` or
`disconnected`), so the assistant can tell a session without VM data from
a session without issues.

The sidecar is opt-in; most developers only need the in-app overlay.
Sleuth reserves the `ext.sleuth.*` namespace, so other packages should
choose a different prefix to avoid `dart:developer.registerExtension`
collisions.

For MCP-only sessions where the AI client is the only consumer, set
`SleuthConfig(showOverlay: false)`. It hides the trigger button and the
dashboard, and the detectors and the `ext.sleuth.*` extensions keep running.

## Debug vs profile mode

Both modes run the full overlay, all 20 detectors and the AI chat. They differ in **what data each mode can read** and **how accurate the timing is**.

| Capability | Debug | Profile | Release |
|------------|:-----:|:-------:|:-------:|
| Overlay and all detectors | Yes | Yes | Disabled |
| Frame timing accuracy | Inflated by debug overhead | Production-accurate | n/a |
| VM timeline (build, layout and paint durations) | Yes | Yes | n/a |
| Source location in issues (`file.dart:42`) | Yes | Yes, except iOS builds from `flutter build ios` or `ipa` | n/a |
| Per-widget rebuild and paint issues (`enableDebugCallbacks`) | Yes (opt-in) | No | n/a |
| Rebuild stats panel with per-widget rebuild counts (`enableDeepDebugInstrumentation`) | No | Yes (opt-in) | n/a |
| Widget dirty-state arguments on timeline events (`DebugInstrumentationConfig.timelineEnrichment`) | Yes (opt-in) | No | n/a |
| AI chat and Issue Encyclopedia | Yes | Yes | n/a |

### When to use which

- **Profile mode** is for performance investigation. Timing is real, with no debug overhead inflating the numbers, so trust these results.
- **Debug mode** is for finding the root cause. Opt-in debug callbacks give per-widget rebuild and paint counts. Verify timing fixes in profile mode afterwards.

### Opt-in deep instrumentation

These options add overhead and are off by default. Turn them on when you need per-widget attribution. `enableDebugCallbacks` works only in debug mode. `enableDeepDebugInstrumentation` also works in profile mode, where it feeds the Rebuild stats panel:

```dart
SleuthConfig(
  enableDebugCallbacks: true,        // debug: per-widget rebuild and paint counts (widgets your code creates)
  enableDeepDebugInstrumentation: true, // per-widget build timeline events; in profile mode, the Rebuild stats panel
)
```

## Platform support

| Platform | Frame timing | VM full mode | Notes |
|----------|:---:|:---:|-------|
| Android device | Yes | Best-effort | A background reconnect ladder retries after the cold-start port bind race |
| Android emulator | Yes | Best-effort | Same reconnect ladder as a device |
| iOS device | Yes | Good | Profile mode recommended |
| Desktop | Yes | Good | Strongest VM connectivity |

**Frame timing mode** is the cross-platform path and gives accurate build and raster timing in profile builds.

**VM full mode** adds the sub-phase breakdown (build, layout, paint and raster) but depends on VM service connectivity, which varies by platform. Sleuth falls back to frame timing mode when the VM is unavailable. On cold start, a background reconnect ladder (seven attempts, from 500 ms up to 30 s apart) upgrades Sleuth to full mode once the VM web server binds, with no manual action.

> **Prefer VM+ (full) mode for complete diagnostics.** In `basic` mode (no VM self-connect) the VM-only detectors (Shader Jank, Heavy Compute, Platform Channel, Memory Pressure, Stream Resource) stay silent, and so do the VM time-share issues `rebuild_activity` and `excessive_repaint`. Structural heuristics stay at `possible`, although measured structural signals still reach `likely` without a VM (`uncached_images`, for example, compares decoded and rendered image sizes). The issue list is real but **incomplete**. Do not read "no memory or repaint issues" as a clean result until the `connectionMode` field on an `ext.sleuth.*` response reads `full` or `correlated` (the `sleuth_mcp` `diagnose` tool shows it), or `Sleuth.diagnoseCaptureState().vmConnected` is `true` in the app. Run with `--no-dds` (below) to get there.

### Reaching full mode

`flutter run` starts **DDS** (Dart Development Service) by default, and DDS claims the device's VM service as its only client. That blocks Sleuth's in-process self-connect, so Sleuth stays in frame-timing mode for the session.

Skip DDS so Sleuth can self-connect on the first run, with no relaunch:

```bash
flutter run --profile --no-dds
```

The VM service then accepts several clients, so Sleuth connects alongside the tooling and the `connectionMode` field on `ext.sleuth.*` responses reads `full` (or `correlated`). Hot reload and hot restart still work. You lose the features only DDS provides (smoother multi-client DevTools, log history).

Full mode runs VM polling on the app isolate, and its cost grows with the number of timeline events the app writes. On an iPhone 12 (profile mode, 500 ms polls) an idle screen costs about 1.5 ms of UI-isolate time per poll. An FPS stress screen that writes about 10k events per poll costs about 32 ms per poll, mostly to decode the response (see [doc/internals.md](doc/internals.md)). To find what caused a stall, read `Sleuth.lastPollTimings` (`uiBlockingMicros` is the synchronous decode, parse and dispatch time) or the `lastPoll*` and `maxPoll*` keys of `ext.sleuth.diagnose`. On **emulators and simulators** (software rendering, weak CPU) polling can lower FPS. Measure frame rates on a real device, not an emulator.

When you need DDS, DevTools and Sleuth at once, launch the installed binary directly so no DDS attaches.

**Android:**
```bash
flutter run --profile -d <id>          # build + install once, then quit (q)
adb -s <id> shell am start -n com.example.example/.MainActivity
adb -s <id> logcat -d | grep "Dart VM service"
adb -s <id> forward tcp:<port> tcp:<port>   # for sleuth_mcp / external tooling
```

**iOS simulator:**
```bash
flutter run --profile -d <id>          # build + install once, then quit (q)
xcrun simctl launch booted com.example.example
# capture the URI: xcrun simctl spawn booted log stream | grep "Dart VM service"
```

On either path, the `connectionMode` field on every `ext.sleuth.*` response (shown by the `sleuth_mcp` `diagnose` tool) reads `full` or `correlated`, and in the app `Sleuth.diagnoseCaptureState().vmConnected` is `true`.

## FPS semantics

Sleuth reports two frame-rate metrics:

- **Actual FPS** is the number of frames presented in the last second, counted from `FrameTiming.rasterFinish` timestamps in a rolling window. It is what the device drew.
- **Throughput FPS** is a capacity estimate from the average frame duration (`1e6 / avg(frame_duration_us)`). It is what the engine could produce at the current per-frame cost.

The overlay shows **Throughput FPS** as the main number, coloured against `fpsTarget`. Idle screens read as smooth because Flutter repaints only on change; Actual FPS would drop to a few frames per second on a static screen even though rendering is healthy. Tap the info icon to show both metrics side by side (ACTUAL and TPUT). Session exports (`SessionSnapshot` schema v5) carry both metrics plus `actualFpsRaw`, the device rate capped at 240 Hz. It matters on 120 Hz ProMotion hardware, where the overlay clamps to `fpsTarget`.

**Frame budget.** Jank thresholds follow the frame rate the app actually renders at. Sleuth measures the vsync cadence from the fastest recent frames and uses it as the budget, bounded below by `fpsTarget` and above by the display's reported refresh rate. Sleuth judges a 120 Hz device rendering at 120 against 8.33 ms, and a ProMotion device rendering at 60 keeps 16.67 ms. iOS reports 120 Hz for ProMotion panels even while the app renders at 60, so the display rate alone never tightens the budget. When the budget tightens, the raster-dominance floor and the default heavy-compute threshold become half the budget. `fpsTarget` still caps the overlay FPS number and its colours. Set `autoFrameBudget: false` to always use `1000 / fpsTarget` ms; capture mode always does. `ext.sleuth.diagnose` reports `frameBudgetUs`, `effectiveFrameRateHz` and `frameRateSource`.

[Internals](https://github.com/Harrys76/sleuth/blob/main/doc/internals.md) covers the edge cases (ProMotion `fpsTarget` clamping, the warm-up placeholder, Impeller raster-cache zeros, batched-callback anchoring) and how Sleuth measures FrameTiming against vsync.

## Configuration

### Presets

For a first integration, start from a preset instead of reading all 40 field docs:

```dart
// Ten detectors: frame timing, rebuild, repaint and seven structural ones.
// No network monitoring, debug callbacks or AI chat.
Sleuth.track(
  child: MyApp(),
  config: SleuthConfig.minimal(),
);

// Structural detectors only, a 2 s scan interval and a 10-frame capture
// buffer, for low-overhead CI or profile runs.
Sleuth.track(
  child: MyApp(),
  config: SleuthConfig.performance(),
);
```

### Full configuration

```dart
Sleuth.track(
  child: MyApp(),
  config: SleuthConfig(
    fpsTarget: 60,                     // loosest frame budget + overlay FPS cap; the budget tightens to the measured rate
    autoFrameBudget: true,             // false: always judge frames against 1000 / fpsTarget ms
    rebuildThreshold: 10,              // per-widget rebuilds/sec (debug instrumentation)
    maxListChildren: 20,               // flag non-lazy lists with more children than this (default 50)
    platformChannelLimit: 20,          // flag more platform channel calls per second than this (default 20)
    treeScanInterval: Duration(seconds: 1), // base tree-scan cadence; ticks costing > 4 ms stretch it (≤ 5 s); deferred ≤ 3 × 250 ms while scrolling
    maxElementsPerScan: 0,             // > 0: skip one tick after a walk over this many elements (0 = unlimited)
    captureBufferCapacity: 50,        // max jank frames retained for export
    enableDebugCallbacks: false,       // opt-in: per-widget rebuild/repaint hooks (conflicts with DevTools)
    enableDeepDebugInstrumentation: false, // opt-in: heavy per-widget timeline events
    maxTrackedTypes: 200,              // cap on tracked widget types in debug callbacks
    enableNetworkMonitoring: true,     // HTTP interception via HttpOverrides
    slowRequestThresholdMs: 1000,         // warn on requests slower than this (default 1000 ms)
    criticalSlowRequestThresholdMs: 3000, // escalate to critical at this duration (must be > slow; default 3000 ms)
    requestFrequencyLimit: 30,         // max requests per 5s window
    largeResponseThresholdBytes: 1048576, // flag responses larger than 1MB
    adaptiveScanEnabled: true,         // after 3 clean scans, double the interval up to 2 s, never below the base (default true); the cost stretch above applies either way
    networkExcludePatterns: ['analytics.example.com'], // exclude URLs from monitoring
    enabledDetectors: {
      DetectorType.frameTiming,
      DetectorType.rebuild,
      DetectorType.imageMemory,
      // ... add only the detectors you need
    },
    suppressedIssues: {'non_lazy_list', 'rebuild_debug_*'}, // drop known issues by stableId (exact or trailing *) before ranking
    thresholds: DetectorThresholds(
      shaderJankMs: 50,              // shader compilation warning threshold
      heavyComputeGapMs: 8,          // BUILD-scope warning threshold, critical at 2×; omit for auto (8 ms at 60 Hz, half the frame budget above it)
      gpuPressureRatio: 1.5,         // raster/UI time ratio for GPU pressure
      buildTimePercentThreshold: 10, // rebuild_activity: % of UI-thread time in BUILD, critical at 3×
      paintTimePercentThreshold: 10, // excessive_repaint: % of UI-thread time in PAINT, critical at 3×
    ),
    customDetectors: [MyCustomDetector()], // plug in domain-specific detectors
    disabledCustomDetectorKeys: {'my_heavy_detector'}, // gate custom detectors by key
    triggerButtonAlignment: Alignment.bottomRight, // trigger corner until the user drags it
    triggerButtonOffset: Offset(16, 16),           // offset from that corner, inside the safe area
    showDebugModeBanner: true,         // dismissible debug-mode warning banner
    showOverlay: true,                 // false hides the trigger and dashboard; detectors and ext.sleuth.* keep running, for MCP-only sessions
    routeIgnorePatterns: {'/dialog*'}, // routes to exclude from tracking (exact or trailing *)
    routeHistoryCapacity: 20,          // max route sessions retained (FIFO)
    profilePlatformChannels: false,    // opt-in: profile platform-channel sends after the VM connects
    stateStore: null,                  // optional: persist overlay UI state across restarts (see below)
  ),
);
```

**Suppressing and hiding issues.** `suppressedIssues` removes matching issues before ranking, so they leave the overlay, `ext.sleuth.*`, snapshots and budgets alike, and the overlay footer counts them (`3 suppressed`). To move a card out of the way only while you work, expand it and tap **Hide**. The card leaves the overlay (with Undo for 4 s) and the footer shows `N hidden`; tap the footer to restore hidden cards (Restore all also offers Undo). A hide covers the card at the severity you hid it at, so a hidden warning shows again if the same card turns critical. Hiding affects only the overlay: `ext.sleuth.issues`, snapshots, MCP budgets, route sessions and recurrence still see the issue.

**Overlay state.** The trigger position, card position and size, window state, hidden cards, theme mode and the severity filter (the tappable counts in the summary bar) survive closing the dashboard and hot reload. To keep them across restarts, pass a `SleuthStateStore`. The package ships no persistent store, so it adds no storage dependency:

```dart
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sleuth/sleuth.dart';

class PrefsStateStore implements SleuthStateStore {
  @override
  Future<String?> read() async =>
      (await SharedPreferences.getInstance()).getString('sleuth_ui');

  @override
  Future<void> write(String json) async =>
      (await SharedPreferences.getInstance()).setString('sleuth_ui', json);
}

Sleuth.track(child: MyApp(), config: SleuthConfig(stateStore: PrefsStateStore()));
```

Sleuth reads the store once at startup. The trigger appears when the read finishes, after at most 2 s, and changes made in the meantime are kept. Sleuth writes after a trailing 500 ms debounce, with one write in flight at a time, and writes a pending change on dispose. A read that times out, throws, or returns state written by a newer release turns writes off for that session, so the stored value survives; the next change replaces contents that no release can read. Return `null` from `read` when nothing is stored yet. Sleuth gives up on a write that is still running after 5 s, and it writes a pending change when the app goes to the background. Failures never reach the UI. `InMemorySleuthStateStore` suits tests. The example app ships a file-backed store (`example/lib/file_state_store.dart`).

**System back.** With the dashboard open, the system back gesture or button closes the innermost overlay layer before the app's own navigation sees it: first a focused text field, then a full-screen page (encyclopedia, guide, AI chat, Hidden list), then the dashboard. With the dashboard closed, back goes to the app unchanged. On Android, Sleuth claims predictive back swipes while a layer is open, also after the app navigates underneath it (for example back to its root route). On Flutter versions that offer the swipe to every listener, an app route that can pop may pop as well. After the dashboard closes at the app's root route, Android's back-to-home preview returns once the app navigates; back itself still leaves the app.

**Platform channel profiling.** The Platform Channel detector sees calls only when the framework's `debugProfilePlatformChannels` flag is on. `profilePlatformChannels: true` sets it once the VM service connects and restores it on dispose. While the flag is on, the framework prints a "Platform Channel Stats" table to the console every second that channels are active, and it also profiles framework channels (TextInput, SystemChrome, clipboard). The option is off by default.

**Debug callbacks.** `enableDebugCallbacks` installs the `debugOnRebuildDirtyWidget` and `debugOnProfilePaint` hooks. These conflict with DevTools "Track Widget Rebuilds", and only one of them can be active at a time, so the default is `false` to avoid surprising DevTools users. Per-widget counts keep only widgets your code creates. A rebuild counts for the widget that started it, and its detail gives the number of widgets below it that its builds updated. A repaint card names the likely origin: the deepest widget marked as needing paint in its layer, mapped to the nearest widget your code creates. Widgets that only repaint because they share that layer get no card. The rate is the busiest instance's, not a sum over instances. Sleuth does not credit scrolling, framework control painters or Material ink splashes. `advanced: DebugInstrumentationConfig(userWidgetsOnly: false)` also counts framework widgets. A widget's card appears when one scan's rate reaches the threshold, and it stays until the rate over the last two scans falls below three quarters of the threshold, or until a scan sees no rebuild or paint of that widget. Sleuth's own overlay is never counted.

**Overlay theming.** The overlay follows the platform brightness and switches to a high-contrast preset when the platform asks for high contrast (iOS Increase Contrast). The header toggle cycles System, Light and Dark and remembers the choice (`OverlayUiState.themeMode`, persisted with the rest of the overlay state). The order of precedence, from highest, is the toggle's Light or Dark, then `Sleuth.updateTheme`, then `SleuthConfig.theme`, then automatic selection. Choosing Light or Dark shows the Sleuth preset (high-contrast when the platform asks for it) in place of an `updateTheme` or configured theme; System shows that theme again. Calling `Sleuth.updateTheme` with a theme sets the toggle to System.

```dart
// Static config at initialization
Sleuth.track(
  child: MyApp(),
  config: SleuthConfig(
    theme: SleuthThemeData.light().copyWith(
      cardBackground: Color(0xFFF5F5F5),
      spacingMd: 10, // adjust overlay density (default 8)
    ),
  ),
);

// Surfaces and text from your app's colour scheme (severity, category,
// confidence and source colours stay Sleuth's). Build it once: the overlay
// compares themes by identity.
final sleuthTheme = SleuthThemeData.fromColorScheme(Theme.of(context).colorScheme);
final seeded = SleuthThemeData.fromSeed(Colors.teal, brightness: Brightness.dark);

// Runtime override (from anywhere in your app)
Sleuth.updateTheme(const SleuthThemeData.light());             // force light
Sleuth.updateTheme(const SleuthThemeData.highContrastDark());  // e.g. on Android
Sleuth.updateTheme(null);                                       // back to config / auto
```

`fromColorScheme` checks the scheme's text candidates against every surface for 4.5:1 contrast. When they fail, the whole text group falls back to the Sleuth preset that matches the scheme's surface brightness. It then checks every text, check and chip pair the overlay draws against the scheme's surfaces, and a surface that its text still cannot clear (a mid-tone container from the `fidelity` or `content` variants, for example) falls back together with its text.

## Accessibility

The overlay is a developer tool drawn over a live app, and it works with the platform's accessibility settings turned on.

- **Screen readers.** Every control has a label. An issue card is one button named by its title (double tap expands it; long press or the Copy details action copies it; the screen reader announces the expanded state). While a full-screen page is open, it announces its name, hides the app below it from the screen reader, and takes keyboard focus from the app (typing, Tab, Enter and Space no longer reach it); the app gets focus back when the page closes. The floating card leaves the app reachable. Closing a page returns the list to where it was and moves screen-reader focus back to the card that opened it. Dragging has alternatives: the card header offers Move up / down / left / right and Move to top left, the resize grip offers Taller / Shorter / Wider / Narrower (48 px steps, normal window state only), and the trigger offers Move to left edge / right edge. The header and grip read the card size back, and the header also reads its position. Toasts are live regions and stay three times longer while a screen reader or other assistive service is on, and a toast with an action (Undo) then stays until it is used or dismissed. The trigger reads how many issues are critical. AI chat announces Thinking and each reply.
- **Text size.** Overlay text follows the system setting between 0.8× and 2.0×; the app below keeps its own scale. The chrome (card header, status row, summary bar, footer, badges, trigger) stops growing at 1.3× so the issue list stays visible; above that, issue titles take two lines and detail text wraps. Fixed heights grow with the chrome but never past the screen (on a landscape phone, for example), and the status row and banners scroll when they would squeeze the list. Moving or resizing the card, by touch or with a screen-reader action, keeps the whole card on screen above the keyboard. In AI chat the issue context gives way to the input and Send button when the keyboard is up. A card resized under large text returns to its own height at 1.0×. The smallest text is 10 px.
- **Touch targets.** Controls are at least 48 × 48 dp. The card header's compact controls (highlight, theme, minimize, maximize, restore) are 36 × 48 so that they fit the default 300 dp card, which is above the WCAG 2.5.8 minimum of 24 dp. Below 280 dp the minimize and maximize controls are hidden. Close is 48 × 48.
- **Contrast.** Text tokens meet WCAG AA (4.5:1) on every overlay surface in the dark, light and high-contrast themes. Badges draw primary text on a light tint of their colour, with a 1 px border in that colour.
- **High contrast.** `SleuthThemeData.highContrastDark()` and `highContrastLight()` raise secondary text, strengthen borders, make badge fills opaque and widen the source accent. Sleuth picks them when `MediaQuery.highContrastOf` is true (reported on iOS) and no theme is set, and for the toggle's Light or Dark. On other platforms, pass one to `Sleuth.updateTheme`. State cues (chip borders, chevrons, the pin) stay at full opacity.
- **Reduced motion.** Sleuth honours both the Android animator duration scale (`disableAnimations`) and iOS Reduce Motion (`AccessibilityFeatures.reduceMotion`). Page entrances, expand and collapse, scrolls to an entry, the toast fade, severity chips and the rebuild count change at once, and the Ask AI shimmer stops. An animation that is already running when the setting changes finishes at its old speed.
- **Keyboard.** Escape first unfocuses a focused overlay text field, then closes the open page, then the dashboard. A focused text field or an open dialog or sheet in your app keeps its Escape.

## AI chat

Tap "Ask AI" on any issue card to open a chat about that issue. The package builds the system prompt from the issue's metrics, its encyclopedia entry and the causal graph; your AI provider only needs to stream a response.

```dart
Sleuth.track(
  child: MyApp(),
  config: SleuthConfig(
    aiChat: AiChatAdapter.anthropic(apiKey: myKey),
    // Or: AiChatAdapter.openAi(apiKey: myKey)
    // Or: AiChatAdapter.google(apiKey: myKey)
  ),
);
```

Custom backend:

```dart
config: SleuthConfig(
  aiChat: AiChatAdapter(
    sendMessage: (request) async* {
      // request.systemPrompt: the issue context the package builds
      // request.history: the conversation so far
      yield* myBackend.stream(request);
    },
  ),
),
```

The built-in adapters exclude their provider URLs from network monitoring. When no adapter is configured, the "Ask AI" link is hidden.

**Replies.** While a reply is arriving, the send button becomes Stop. The input stays editable so you can draft the next question, and sending it shows a notice with Stop. Stop keeps the text received so far, marked "(stopped)", and so does closing the chat mid-reply. By default a reply times out after 30 s without a first token or 15 s between tokens; set `firstTokenTimeout` and `stallTimeout` on the adapter for slow local or reasoning models (null turns a timeout off). After 5 s the chat shows "Still waiting for a reply". A failed reply shows a short reason with **Retry** and **Copy error**. The reasons are API key rejected (HTTP 401 or 403), Rate limited (429), Provider error (5xx), Offline (the host lookup failed or the network is down), Can't reach the provider (another connection error, such as a refused or reset connection), No reply in 30 s (the first-token timeout) and Reply stalled (the stall timeout). Anything else, including a reply that ends without text, reads Reply failed. The error text never enters the conversation, so it is not sent back to the provider. A question left unanswered shows "Reply did not finish" with Retry when the chat reopens. A question asked after an unanswered one keeps its own bubble, and the request joins the two into one user turn, so no provider receives two user turns in a row. To report a failure, throw from your adapter's stream. An error whose text reads `returned 429` or `status 429` gets the reason for that code (Sleuth maps 401, 403, 429 and 5xx), and a `SocketException` reads Offline or Can't reach the provider, depending on its cause.

**What is sent.** The system prompt holds the issue (title, detail, fix hint, widget, route, ancestor chain, causes and effects), its encyclopedia entry, up to five other active issues by title, and a Session section. It never lists an issue you hid, and it names related issue ids only for issues it already lists. The Session section has the current route (without query or fragment), the whole-app frame rate while the overlay is open, the first line of the latest frame verdict with its phase timings, active issue counts by severity, the number of reported issues you hid (not their titles), the build mode (debug or profile), the connection mode and the platform. A caption above the input summarises it (`Context: /home · 58 FPS · 12 issues`), and once a message has been sent, Copy conversation ends with the context sent. Route names (without query or fragment), widget names and issue text go to your provider. If your route paths carry user data, use a custom adapter that redacts `request.systemPrompt`. A custom adapter can throw `AiProviderException(status)` to get the matching short reason.

## Custom detectors

You can add your own detectors alongside the 20 built-in ones. There are three shapes.

**Structural.** Inspect widgets during the tree walk with `SimpleStructuralDetector`:

```dart
class TooltipUsageDetector extends SimpleStructuralDetector {
  TooltipUsageDetector()
      : super(
          name: 'Tooltip Usage',
          description: 'Flags Tooltip widgets in the tree',
          key: 'tooltip_usage',
        );

  @override
  void inspect(Element element) {
    if (element.widget is Tooltip) {
      report(
        stableId: 'tooltip_usage',
        severity: IssueSeverity.warning,
        category: IssueCategory.build,
        title: 'Tooltip detected',
        detail: 'A Tooltip widget is in the build tree.',
        fixHint: 'Consider Semantics instead for accessibility.',
        element: element,
      );
    }
  }
}
```

**Runtime.** Observe app events (frame timings, route transitions) by extending `BaseDetector` directly with `DetectorLifecycle.runtime`.

**Hybrid.** Combine VM timeline data with tree inspection using `DetectorLifecycle.hybrid`.

A detector can override these hooks: `prepareScan`, `checkElement`, `afterElement` and `finalizeScan` (tree walk), `processTimelineData` (VM timeline polls), and `processFrame(FrameStats)` (every presented frame, on every tier, for every enabled detector; keep it cheap and emit from `finalizeScan`). All of them default to no-ops.

The three-file cookbook in [`example/lib/custom_detectors/`](example/lib/custom_detectors/) has complete examples of all three shapes.

Register custom detectors and optionally gate them by key:

```dart
Sleuth.track(
  child: MyApp(),
  config: SleuthConfig(
    customDetectors: [TooltipUsageDetector(), SlowFrameDetector()],
    disabledCustomDetectorKeys: {'slow_frame_detector'}, // disable by key
  ),
);
```

## Session export

Export captured jank data and current issues to share or compare them:

```dart
// JSON snapshot: frame stats, issues, causal edges, heat map
final snapshot = Sleuth.exportSnapshot();
final json = Sleuth.exportSnapshotJson();

// Markdown summary to paste into Slack or a PR description
final markdown = Sleuth.exportSummary(topN: 5);
```

The dashboard's Export button copies the JSON snapshot to the clipboard, and the "Copy conversation" button on the AI chat page copies the whole thread.

Exports include recurrence trends (whether each issue is worsening, improving, stable or intermittent), the widget heat map (the widgets with the highest cumulative ranking score) and per-route health data (FPS, jank ratio, issue counts, health scores).

These calls return `null` in release mode, before `track()` is called, or after the overlay is disposed.

## Route scoping

Sleuth detects route changes from the element tree, with no `NavigatorObserver`. Each route gets its own `RouteSession` with per-route FPS, jank ratio, issue snapshots and a composite health score from 0 to 100.

```dart
// Access route history programmatically
final history = Sleuth.routeHistory; // List<RouteSession>?
final score = Sleuth.routeHealthScore('/settings'); // int?
```

Both the JSON and the markdown exports include route health data. To configure route tracking:

```dart
SleuthConfig(
  routeIgnorePatterns: {'/dialog*', '/splash'}, // skip ephemeral routes
  routeHistoryCapacity: 50,                      // max sessions retained (FIFO)
)
```

**Per-tab sessions for tab shells.** Bottom-navigation apps that use `IndexedStack`, `StatefulShellRoute.indexedStack` or `CupertinoTabScaffold` share one `ModalRoute` across all tabs but give each tab its own `Scaffold`. Sleuth keys sessions on `(routeName, scaffoldHashKey)`, so each tab gets its own `RouteSession` instead of all tabs sharing one route name. `tabVisitIndex` (starting at 1) tells repeat visits to the same tab apart. `TabBar`, `TabBarView` and `PageView` swipes within one route stay inside the outer session. `PerformanceIssue.routeName` stays raw for group-by-route filtering; use `issue.routeDisplayName` for labels that people read (for example `"/home (tab-2)"` on the second visit).

## Confidence levels

Each issue has a confidence level that reflects the quality of its evidence:

| Level | Meaning | Example |
|-------|---------|---------|
| **Confirmed** | Directly observed runtime condition | Jank frame measured at 32 ms |
| **Likely** | Runtime signal plus structural evidence | Missing RepaintBoundary on a widget type that paints more than 10 times a second |
| **Possible** | Structural heuristic only | Non-lazy list with 60 children |

The ranker orders issues by evidence tier: confirmed critical, likely critical, confirmed warning, possible critical, likely warning, possible warning, ok. A structural guess ranks below a warning observed at runtime; frame impact and recurrence only order issues within a tier.

While the dashboard is open, the overlay holds the order of collapsed cards, so a card does not move under your finger. New issues enter at the top (below any expanded cards) with a wider accent for 2 s, a severity promotion moves a card up at once (never down), and other rank changes apply after 10 s of quiet while the list is scrolled to the top. Any touch, scroll or trackpad gesture on the list restarts the 10 s wait, and a list scrolled away from the top keeps the order until it is back at the top. Collapsing the last expanded card keeps the order on screen. Under a screen reader, held cards do not move on their own. Opening the dashboard, changing the severity filter, and hiding or restoring a card are then the only points that show the ranker's order, as they are without a screen reader, and a new issue enters at its rank position instead of the top. Exports, `ext.sleuth.*` and MCP always use the ranker's order.

Keep-alive issue ids name the scrollable (`excessive_keep_alive:PageView~1`, or `~k-feed` for a `ValueKey('feed')`). When the overlay state loads, it drops hides saved under the older positional ids (`excessive_keep_alive:3`).

The causal graph follows the same evidence rule: a `possible` issue is never shown as the cause of a `likely` or `confirmed` one. An effect with one cause collapses under it only when the cause is at least as severe; an effect with two or more causes always stays in the main list.

## Recurrence badge

Each issue card shows a `Seen X/Y · {label}` badge once Sleuth has observed the issue across at least two scan cycles. It tells you how often the issue comes back and whether it is getting better or worse.

- **X** is the number of scan cycles in which the issue fired (`presentCount`).
- **Y** is the total number of scan cycles in the ring buffer (capacity `60`, oldest evicted).

The label summarises the recent trend: `worsening`, `persistent`, `stable`, `improving` or `flaky`. [Internals](https://github.com/Harrys76/sleuth/blob/main/doc/internals.md#recurrence-badge) has the exact thresholds and notes on where the JSON and UI vocabularies differ (`flaky` and `intermittent`, `persistent`).

The `Seen N` badge and the trend show persistence; severity always comes from the detector. See [`RecurrenceTrend`](lib/src/models/recurrence_trend.dart) for the underlying thresholds.

## Startup tracing

Sleuth measures cold-start performance with `Sleuth.init()` and `Sleuth.markInteractive()`. Call `Sleuth.init()` as the first line of `main()`:

```dart
void main() {
  Sleuth.init();          // Dart-entry clock starts here
  runApp(Sleuth.track(child: const MyApp()));
}
```

Sleuth captures four metrics: `ttffMs` (Dart entry to first frame, the part Dart controls; default budget 1500 ms for a warning and 3000 ms for critical), `engineTtffMs` (matches `flutter run --trace-startup`), `preDartOverheadMs` (the native phase before Dart starts, outside Dart's control) and `frameworkInitMs`. [Internals](https://github.com/Harrys76/sleuth/blob/main/doc/internals.md#startup-tracing) has the per-metric windows and platform guidance.

The in-app Startup metrics page explains the method and breaks the startup down by phase.

## Detector matrix

There are 20 detectors across four lifecycle types:

- **Runtime** (always available): Frame Timing, Network Monitor, Tracked Resource.
- **VM-only** (need a VM connection): Shader Jank, Heavy Compute, Platform Channel, Memory Pressure, Stream Resource.
- **Hybrid** (VM and tree scan, with a fallback without the VM): Rebuild, GPU Pressure, Repaint. GPU Pressure also reads per-frame `FrameTiming` raster and UI time, so `raster_dominance` fires as `likely` without a VM and as `confirmed` with one.
- **Structural** (tree scan only): setState Scope, Layout Bottleneck, ListView, Image Memory, CustomPainter, Keep Alive, Font Loading, RepaintBoundary, Startup.

[Internals](https://github.com/Harrys76/sleuth/blob/main/doc/internals.md#detector-matrix) has the full matrix: signal source, what each detector can prove, confidence and known limitations.

## Validation ledger

Each detector carries a `DetectorMetadata` record that declares the strongest evidence behind its current thresholds and heuristics, on four ordered tiers: `unvalidated`, `reproducerOnly`, `runtimeVerified` and `externallyCited`. As of v0.37.0, **18 of 20 detectors ship at the `reproducerOnly` base tier and 2 of 20 at `runtimeVerified`**, with **15 effective `runtimeVerified` family-severity pairs across 12 unique stableIds** (`slow_request {warning + critical}`, `large_response.warning`, `request_frequency.warning`, `heap_growing.warning`, `platform_channel_traffic.warning`, `jank_detected.warning`, `rebuild_activity {warning + critical}`, `heavy_compute {warning + critical}`, `excessive_repaint.warning`, `stream_resource_growth.warning`, `tracked_resource_concurrent.warning`, `tracked_resource_long_lived.warning`). No detector is at `unvalidated`. The CI audit gate at `test/validation/detector_metadata_audit_test.dart` enforces the contract on every test run.

The per-detector ledger at [`doc/validation_ledger.md`](https://github.com/Harrys76/sleuth/blob/main/doc/validation_ledger.md) names each detector's current tier, links to its reproducer when one exists, and explains what would raise it. A tier raise lands its reproducer or capture evidence in the same PR.

## Unsupported claims

To set expectations:

- Sleuth **does not replace** DevTools heap snapshots or interactive flame charts. It covers breadth (20 detectors, encyclopedia, AI chat), not object-level inspection or zoomable timelines.
- **Widget attribution depends on the mode.** Debug mode gives exact per-widget rebuild and paint counts. Profile mode gives per-widget rebuild counts only in the Rebuild stats panel (with `enableDeepDebugInstrumentation`), and those counts include first builds. Its rebuild and repaint issues measure the share of UI-thread time spent in BUILD and PAINT, not single widgets. See [Debug vs profile mode](#debug-vs-profile-mode) for the full matrix.
- **VM full mode** depends on the runtime environment and is not guaranteed on every platform.
- **Memory pressure detection** watches GC frequency, heap growth trends (linear regression) and, when you set a budget, process memory (RSS) against it. When it detects growth, it adds per-class allocation deltas to the issue, but it does not track individual object leaks or retention paths.
- **CPU attribution** is statistical (about 1 kHz sampling), so functions that run for less than 1 ms may not appear. Use the DevTools CPU profiler for complete call trees.

## Tips and troubleshooting

iOS profile builds made with `flutter build ios` or `flutter build ipa` (and Xcode or `fastlane gym` archives that follow them) show issues without `file.dart:42` source locations, because those commands write `TRACK_WIDGET_CREATION=false` into `Generated.xcconfig`. `flutter run --profile` keeps them. [Internals](https://github.com/Harrys76/sleuth/blob/main/doc/internals.md#ios-builds-from-flutter-build-ios-lose-source-locations) has the build steps and a Fastfile patch that keep them.

## Example app

The example app has 24 demo screens and 9 capture-helper screens; most demos have a Before/After toggle and live metrics. See [`example/README.md`](example/README.md) for the full screen list and categories.

```bash
cd example && flutter run --profile
```

## License

MIT
