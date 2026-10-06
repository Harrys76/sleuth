# Sleuth example

A demo app organized by category. 24 demo screens trigger specific
detectors, and 9 capture-helper screens drive `runtimeVerified` capture
brackets.

## Running

```bash
# Profile mode (recommended, accurate timing)
cd example && flutter run --profile

# Debug mode (per-widget rebuild and paint counts, timing less representative)
cd example && flutter run
```

## Demo screens

| # | Screen | Detectors triggered | Category |
|---|--------|--------------------|----------|
| 1 | High-Level setState | SetStateScope; Rebuild in debug builds at 10 or more taps a second | Build |
| 2 | Rebuild Hotspot (Dashboard) | Rebuild Stats banner (profile); Rebuild (debug) | Build |
| 3 | Non-Lazy ListView | ListView | Build |
| 4 | Shrink-wrapped Sections | ListView (two cards, one per list) | Build |
| 5 | CSV Import | HeavyCompute | Build |
| 6 | Live Waveform | Repaint | Paint |
| 7 | Always-Repaint CustomPainter | CustomPainter | Paint |
| 8 | Missing RepaintBoundary | RepaintBoundary | Paint |
| 9 | GPU Pressure | GpuPressure | GPU & Rendering |
| 10 | Shader Jank | ShaderJank | GPU & Rendering |
| 11 | FPS Stress Test (~20 FPS) | HeavyCompute, GpuPressure | GPU & Rendering |
| 12 | IntrinsicHeight Abuse | LayoutBottleneck | Layout |
| 13 | Uncached Images | ImageMemory | Memory |
| 14 | Memory Pressure | MemoryPressure | Memory |
| 15 | KeepAlive Overuse | KeepAlive | Memory |
| 16 | Stream Resource Leaks | StreamResource | Memory |
| 17 | Tracked Resource Leaks | TrackedResource | Memory |
| 18 | Search + Gallery | NetworkMonitor | Network & I/O |
| 19 | Platform Channel Traffic | PlatformChannel | Network & I/O |
| 20 | Font Loading Stress | FontLoading | Network & I/O |
| 21 | Tabbed Shell | ListView, ImageMemory, LayoutBottleneck (visible tab only) | Navigation |
| 22 | Custom Detector Cookbook | Custom (Tooltip / Slow Frame / Raster) | Custom Detectors |
| 23 | Combined: Social Feed | Image, Layout, setState, Correlator | Combined |
| 24 | Combined: Chat App | SetState, KeepAlive, Channel | Combined |

### Capture helpers (`runtimeVerified` brackets)

These screens record on-device capture brackets for the audit gate.

| Screen | Bracket |
|--------|---------|
| HeavyCompute | `heavy_compute` warning + critical |
| RebuildActivity | `rebuild_activity` warning + critical (build-time share; legs via `ext.sleuthDemo.captureLeg`) |
| FrameTiming (jank_detected) | `jank_detected` warning (60Hz) |
| MemoryPressure | `heap_growing` warning |
| NetworkMonitor | `slow_request` warning + critical |
| PlatformChannel | `platform_channel_traffic` warning |
| Repaint | `excessive_repaint` warning (paint-time share; legs via `ext.sleuthDemo.captureLeg`) |
| StreamResource | `stream_resource_growth` warning |
| TrackedResource | `tracked_resource_concurrent` warning + `tracked_resource_long_lived` warning |

The RebuildActivity and Repaint screens calibrate their workload before
each leg, record a 6 s scenario, and publish results through
`ext.sleuthDemo.captureResult`. See the "RebuildActivity + Repaint
time-share captures" section of `doc/capture_procedure.md`.

Most demos explain the anti-pattern and its fix in `Bad:` and `Fix:`
lines.

## AI chat

Ask AI talks to a local [Ollama](https://ollama.com) server through its
OpenAI-compatible API (`llama3.2`). On a device, `localhost` is the device
itself, so point the app at the machine that runs Ollama:

```bash
cd example && flutter run --dart-define=SLEUTH_AI_BASE_URL=http://192.168.1.20:11434
```

To check the chat without a model, `--dart-define=SLEUTH_AI_FAKE=<mode>`
swaps in a scripted adapter (`lib/fake_ai_adapter.dart`):

| Mode | Reply |
|------|-------|
| `ok` | Three sentences, then done |
| `fail` | HTTP 503 after 300 ms (Provider error, Retry, Copy error) |
| `stall` | One token, then nothing (Reply stalled after 15 s) |
| `partial` | Two tokens, then an error (partial text kept on screen, Reply failed) |
| `slow` | First token after 8 s ("Still waiting for a reply" from 5 s), then as `ok` |
| `empty` | Ends without a token (Reply failed) |

## Overlay state and remote drive

The app passes `FileSleuthStateStore` (`lib/file_state_store.dart`) as
`SleuthConfig.stateStore`, so the trigger edge, card geometry, hidden
issues and severity filter survive restarts. The file lives in the system
temp directory, which the OS may clear.

The app registers service extensions for driving it from a VM service
client in debug and profile builds. Each one returns JSON, and a failure
returns `{error, ...}`. Lookups by text or label consider only what is on
screen: the current route, the selected tab, and an overlay page in front
of the app.

| Extension | Effect |
|-----------|--------|
| `ext.sleuthDemo.open` | `demo` = a demo title as a slug (`gpu_pressure`); pushes that demo |
| `ext.sleuthDemo.pop` | Pops the app's top route; returns `{popped}` |
| `ext.sleuthDemo.back` | Sends a system back (as the Android back button does) and returns `{handled}`; with nothing open in the overlay or the app, Android leaves the app |
| `ext.sleuthDemo.tap` | `text` (substring of a Text), `label` (semantics label) or both `x` and `y` (logical px); scrolls the target into view (gives up after 2 s with `reveal_timeout`) and taps its centre, or returns `obscured` when something else is on top of it |
| `ext.sleuthDemo.type` | `text`, optional `submit=true`; types into the focused field, else the last field on screen |
| `ext.sleuthDemo.scroll` | Scrolls by `pixels` (default 600) over `ms` (default 600; `0` jumps), `axis=horizontal` for a horizontal list; picks the largest on-screen scrollable outside the demo's instructions; returns `{from, to}`, or `{error: timeout}` with `at` when the scroll does not finish |
| `ext.sleuthDemo.fling` | `dx`, `dy` (logical px), optional `ms`; drags and releases on that scrollable |
| `ext.sleuthDemo.orientation` | `value` = `portrait` \| `landscape` \| `all`; waits for the view to change and returns its size with `settled` |
| `ext.sleuthDemo.theme` | `mode` = `system` \| `light` \| `dark`; sets the overlay's theme mode |
| `ext.sleuthDemo.overlay` | `action` = `open` \| `close` \| `hide` (first visible card; returns its key) \| `undo` (most recently hidden key) \| `restoreAll` \| `toggleSeverity` (`severity` = `critical` \| `warning` \| `ok`) \| `setTheme` (`preset` = `hc_dark` \| `hc_light` \| `seed:<argb>` \| `none`); returns the state below |
| `ext.sleuthDemo.overlayState` | Persisted overlay state plus `dashboardOpen`, `uiStateReady` and `visibleIssueCount` |
| `ext.sleuthDemo.clipboard` | Returns `{text}`, the current clipboard text |
| `ext.sleuthDemo.a11y` | Platform accessibility settings, the overlay's text scale, overflow reports and the labelled semantics nodes |
| `ext.sleuthDemo.screenshot` | `{png}` (base64) of the whole screen, overlay included |
| `ext.sleuthDemo.captureLeg`, `captureResult`, `vmAxes` | Hands-free capture legs for the time-share brackets; see `doc/capture_procedure.md` |

The overlay extensions return `{error: no_controller}` before Sleuth is
initialised. While the app is in the background no frame is drawn, so
`screenshot` and `a11y` return `{error: unavailable}`, and the others stop
waiting for a frame after 2 s.

## Before/After toggle

Most demos use the shared `DemoScaffold`, which has a **Before/After
toggle** and a **live metrics bar**. Tabbed Shell, the resource-leak
screens and the Custom Detector Cookbook have their own layouts. Flip
between the anti-pattern and the fix in place, and watch Sleuth's issue
appear and disappear.

The fixed side of the toggle is a working screen, not a description, so
the comparison is real. Some examples:

- Top-level `setState`, fixed with `ValueNotifier` and `ValueListenableBuilder`.
- `ListView(children: List.generate(...))`, fixed with `ListView.builder` and `itemExtent`.
- An `IntrinsicHeight` row, fixed with `CrossAxisAlignment.stretch` (this needs a bounded cross axis, such as a fixed-height parent).
- `Image.network` without `cacheWidth`, fixed with `cacheWidth` and `cacheHeight`.
- CSV parsing on the main isolate, fixed with `Isolate.run()`.
- A search request on every keystroke and 1.1 MiB gallery pages, fixed with a 300 ms debounce and 200 KB pages loaded from a button.

The live metric chips show these values: High-Level setState (bad and
fixed rebuild counts), Non-Lazy ListView (widgets built), CSV Import
(parse time on the main isolate and in an isolate), FPS Stress Test
(live FPS from `addTimingsCallback`), Live Waveform (paint count),
Search + Gallery (request count) and Memory Pressure (retained Dart and
native MB).

## Combined multi-detector demos

Each of these demos stacks several anti-patterns in one realistic
screen, and its fixed side applies every fix together:

- **Chat App** has tabbed conversations with `AutomaticKeepAliveClientMixin`, uncached avatars, a 40 ms platform-channel typing poll and a top-level `setState` when a message arrives.
- **Social Feed** has cards with uncached post images, an `IntrinsicHeight` header row and a top-level `setState` on Like.

Both descriptions use the same format: a Bad line, a Fix line and a
step that reproduces the issue.

## What to look for

1. Tap the dog button to open the dashboard.
2. Open a demo screen and interact with it.
3. Open the dashboard again; the demo's issue cards appear in the list.
4. In debug mode the example sets `enableDebugCallbacks: true`, so rebuild and repaint widget highlights are visible.
5. Frame timing data is most accurate in profile mode.
