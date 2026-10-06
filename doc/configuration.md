# Configuration

`Sleuth.track(config: SleuthConfig(...))` takes every option on this page. For a first integration, start from a preset instead:

```dart
// Ten detectors: frame timing, rebuild, repaint and seven structural ones.
// No network monitoring, debug callbacks or AI chat.
Sleuth.track(child: MyApp(), config: SleuthConfig.minimal());

// Structural detectors only, a 2 s scan interval and a 10-frame capture
// buffer, for low-overhead CI or profile runs.
Sleuth.track(child: MyApp(), config: SleuthConfig.performance());
```

## All options

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

## Suppressing issues

`suppressedIssues` removes matching issues before ranking, so they leave the overlay, `ext.sleuth.*`, snapshots and budgets alike, and the overlay footer counts them (`3 suppressed`). To move a card out of the way only while you work, hide it in the overlay instead ([Using the overlay](overlay.md#hiding-cards)).

## Saving overlay state across restarts

The trigger position, card position and size, window state, hidden cards, theme mode and the severity filter survive closing the dashboard and hot reload. To keep them across restarts, pass a `SleuthStateStore`. The package ships no persistent store, so it adds no storage dependency:

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

## Platform channel profiling

The Platform Channel detector sees calls only when the framework's `debugProfilePlatformChannels` flag is on. `profilePlatformChannels: true` sets it once the VM service connects and restores it on dispose. While the flag is on, the framework prints a "Platform Channel Stats" table to the console every second that channels are active, and it also profiles framework channels (TextInput, SystemChrome, clipboard). The option is off by default.

## Debug callbacks

`enableDebugCallbacks` installs the `debugOnRebuildDirtyWidget` and `debugOnProfilePaint` hooks. These conflict with DevTools "Track Widget Rebuilds", and only one of them can be active at a time, so the default is `false` to avoid surprising DevTools users.

Per-widget counts keep only widgets your code creates. A rebuild counts for the widget that started it, and its detail gives the number of widgets below it that its builds updated. A repaint card names the likely origin: the deepest widget marked as needing paint in its layer, mapped to the nearest widget your code creates. Widgets that only repaint because they share that layer get no card. The rate is the busiest instance's, not a sum over instances. Sleuth does not credit scrolling, framework control painters or Material ink splashes. `advanced: DebugInstrumentationConfig(userWidgetsOnly: false)` also counts framework widgets.

A widget's card appears when one scan's rate reaches the threshold, and it stays until the rate over the last two scans falls below three quarters of the threshold, or until a scan sees no rebuild or paint of that widget. Sleuth's own overlay is never counted. [Internals](internals.md#debug-rebuild-and-paint-counts) has the full attribution rules.

## Overlay theming

The overlay follows the platform brightness and switches to a high-contrast preset when the platform asks for high contrast (iOS Increase Contrast). The header toggle cycles System, Light and Dark and remembers the choice (`OverlayUiState.themeMode`, persisted with the rest of the overlay state). The order of precedence, from highest, is the toggle's Light or Dark, then `Sleuth.updateTheme`, then `SleuthConfig.theme`, then automatic selection. Choosing Light or Dark shows the Sleuth preset (high-contrast when the platform asks for it) in place of an `updateTheme` or configured theme; System shows that theme again. Calling `Sleuth.updateTheme` with a theme sets the toggle to System.

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
