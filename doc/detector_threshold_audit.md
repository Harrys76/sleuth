# Detector threshold audit

This audit covers every numeric, duration and ratio threshold in `lib/src/detectors/` of Sleuth v0.15.2, which had 23 detectors. On 2026-04-14 each threshold was compared with 2025 to 2026 sources on Flutter performance, Android Vitals, Impeller and mobile APIs. On 2026-04-15 the verdicts were checked against the detector source; section 7 lists what that check changed. The verdicts are the audit's. The threshold column and the status notes give the code as of v0.37.0.

Five audited detectors were removed in v0.20.0: AnimatedBuilder, Opacity, ShallowRebuildRisk, NestedScroll and GlobalKey. StreamResource (v0.24.0) and TrackedResource (v0.27.0) came later and are not covered here; [`validation_ledger.md`](validation_ledger.md) holds their thresholds and evidence.

Context: the defaults target 60 FPS, the frame warmup is about 3 s, and release builds turn Sleuth off entirely. Sleuth is a diagnostic aid, not a production throttle. A false positive costs users' trust in every detector, while a false negative misses one bug, so the verdicts weigh false positives more heavily.

Reading the source confirmed the three largest tuning recommendations: the FrameTiming warmup, the NetworkMonitor slow threshold and the ListView child threshold. It also settled four of the five open Investigate items as Keep. The audit's largest error was grouping RepaintDetector and RebuildDetector under one missing-animation-filter concern: only RepaintDetector lacked a filter, while RebuildDetector already used a 3× threshold for builder widgets. An animation filter for RepaintDetector became the most useful single fix and shipped in v0.15.3.

---

## 1. Verdict summary

Verdicts are Keep (survives scrutiny), Tune (a specific change recommended), Investigate (unverified, needs a falsification run) and Stale (needs a rethink for the Impeller era). "Was X" marks a verdict the source check changed.

| # | Detector | Key threshold(s) | Verdict | One-line rationale |
|---|---|---|---|---|
| 1 | FrameTimingDetector | Budget `1e6 / fpsTarget` µs, or the measured cadence clamped to `[fpsTarget, display rate]` since v0.37.0; severe above 2× budget; warmup 3 s; `jank_detected` above 15 %; `sustained_jank` at 3 or more severe frames in the 240-frame buffer | Tune; shipped v0.16.0 | The warmup counted 180 frames (`frame_timing_detector.dart:49` at audit time), which is 1.5 s at 120 Hz instead of the intended 3 s. v0.16.0 made it a 3 s duration; the frame count now defaults to 0. The severe-frame rule, then 3 in the last 60 frames, had no inline rationale. |
| 2 | RepaintDetector | VM: paint time above 10 % of UI-thread time warns, above 30 % is critical (`paintTimePercentThreshold`); debug per-widget 30/s or more warns, above 60/s is critical, held across scans | Tune (was Investigate); shipped v0.15.3 and v0.37.0 | The source had no animation or Ticker filter; the animation-owner filter shipped in v0.15.3. Since v0.37.0 the VM axis measures cost, the share of UI-thread time inside PAINT scopes per ~1 s window, instead of a paint count, so a 60 Hz spinner (well under 1 % of UI time) no longer reaches it. The debug per-widget gates keep the 30/s count. |
| 3 | RepaintBoundaryDetector | `maxAncestorDepth` 5; more than 20 boundaries per scrollable | Tune; scope fix shipped v0.37.0 | Depth 5 has no cited rationale, and 20 per scrollable collides with normal `ListView.builder` use. The source check did not cover this detector. Since v0.37.0 default `SliverList` and `SliverGrid` delegates push a `-1` frame keyed by their owner element, so framework per-child boundaries never count, and framework painters (name plus owner within a measured hop budget) and Material's own transparency `ClipPath` are skipped. The thresholds are unchanged. |
| 4 | CustomPainterDetector | `cpRate > 10` raises `always_repaint_painter` to likely; `cpRate > 30` fires `frequent_repaint_painter` (warning) | Keep (was Investigate) | The primary check is structural, the `painter.shouldRepaint(painter)` self-test, so the detector catches every always-true painter at any paint rate. The rate only raises confidence or drives the secondary branch; the audit's worry about missing low-rate painters was backwards. Since v0.37.0 framework painters (Material shape borders, TabBar indicator, progress indicators, ...) are skipped by class name plus owner widget within a measured hop budget. |
| 5 | ListviewDetector | `childThreshold` 50, critical above 150 (3×); shrink-wrapped list in a Flex above 20 children, critical above 100 | Tune; not applied | Flutter docs recommend a builder from 20 items. The detector matches only eager `SliverChildListDelegate` lists (`children: [...]`), not `.builder()`, so most modern code is unaffected and the false-positive risk is lower than first thought. Since v0.37.0 `non_lazy_shrinkwrap` covers `ListView` and `GridView` with `shrinkWrap: true` inside a `Column` or `Row`, builders included. |
| 6 | NestedScrollDetector | `childThreshold` 50 (shared) | Tune; removed in v0.20.0 | Same as #5. |
| 7 | LayoutBottleneckDetector | Wrap above 30 children, critical above 60; one intrinsic warning, nested intrinsics critical | Keep | Conservative but defensible; the real risk, nested intrinsics, is handled structurally. |
| 8 | ShallowRebuildRiskDetector | Depth 3 or less; build count above 20 | Keep (was Tune); removed in v0.20.0 | A 13-entry framework filter at `shallow_rebuild_risk_detector.dart:91-105` (Scaffold, Material, Navigator, Overlay, `_ModalScope`, the Focus widgets, ...) covered the MaterialApp, Navigator, Home case the audit worried about. |
| 9 | HeavyComputeDetector | BUILD pass above 8 ms warns, above 16 ms is critical at the `fpsTarget` budget; half the resolved budget when the measured frame rate is higher (v0.37.0) | Tune; shipped v0.37.0 | Scaling with the frame rate was right, but the first reasoning was wrong: the threshold applies to the duration of a BUILD pass, not to the gap between frames (section 7). |
| 10 | FontLoadingDetector | `maxFamilies` 3 | Keep | Matches the 2025 Flutter guidance to use 2 to 3 fonts. |
| 11 | KeepAliveDetector | More than 5 pages warns, more than 10 is critical | Keep | Matches the rule of thumb that 5 complex kept-alive pages cost 50 to 200 MB. |
| 12 | GpuPressureDetector | Raster above 2.0× UI per frame (3 frames in 1 s, FrameTiming) or worst raster frame against the UI total (VM, critical above 4.0×); blur sigma above 10 gives a critical highlight; subtree above 5 | Investigate | The 2.0 ratio was calibrated in the Skia era, and Impeller's raster and UI timings differ. The frame leg inherits the ratio and stays `likely`. It needs a re-baseline on Impeller traces. The source check did not cover this detector. |
| 13 | ShaderJankDetector | Build 100 ms or more warns, 200 ms or more is critical | Stale; partly addressed in v0.37.0 | Impeller is the default on both platforms as of 2025, so the Skia shader-compile signal it was built for is rare; the threshold itself is fine. Since v0.37.0 it also detects Impeller Vulkan pipeline builds (`PipelineVK::Create`, `CreateComputePipeline`); Impeller Metal precompiles pipelines and stays silent. |
| 14 | OpacityDetector | Exactly `0.0` | Keep; removed in v0.20.0 | A boolean structural rule; the engine's 0.0 short-circuit justifies the narrow scope. |
| 15 | MemoryPressureDetector | Growth above 512 000 B/s; RSS at 80 % or more of the opt-in `memoryBudgetBytes` (off by default); GC above 180/min; native growth above 1 MB/s; warmup 3 s; sustained 10 s | Tune (was Keep); shipped v0.26.0 and v0.37.0 | v0.26.0 raised the GC default from 30 to 60 per minute. `EventStreams.kGC` emits one event per young-gen scavenge, a moderately allocating UI sat near 30 per minute (5 events in the 10 s window times 6), and the old default fired on routine animation rebuilds. v0.37.0 raised it to 180 per minute (an idle app with Sleuth's polling measured 66 to 138 per minute on an iPhone 12, while churn runs in the thousands) and stamps the scavenge and old-gen split. `heap_near_capacity` now compares RSS with an app-supplied budget instead of Dart's self-growing heap capacity, whose ratio sits at 0.85 to 0.97 at steady state. `SleuthConfig(gcRateThresholdPerMin: 30)` restores the oldest sensitivity. |
| 16 | NetworkMonitorDetector | Slow 1000 ms, critical 3000 ms; more than 30 requests in 5 s; large 1 MiB; 3 or more duplicates in 500 ms | Tune; shipped v0.15.4 | The old 2000 ms "slow" was 2 to 10 times more lenient than mobile-API guidance (300 to 1000 ms). v0.15.4 changed slow from 2000 to 1000 ms and critical from 5000 to 3000 ms, added the `criticalSlowThresholdMs` constructor parameter and `SleuthConfig.criticalSlowRequestThresholdMs`, and asserts that critical is greater than slow. |
| 17 | SetStateScopeDetector | Dirty ratio above 0.5 of the tree; minimum subtree 50 | Keep (was Investigate) | The detector does far more than a threshold check: a framework filter, an animation-scope filter, a const-element discount, a 5 s rebuild-evidence window and `minSubtreeSize` 50. The 0.5 ratio holds up. Since v0.37.0 it emits only on observed rebuilds. |
| 18 | PlatformChannelDetector | More than 20 calls/s warns, more than 40 is critical | Keep | 20 per second is defensible. The audit also kept an 8 ms cumulative-duration trigger anchored on the 60 FPS budget; v0.37.0 removed that trigger, and per-call durations are now recorded on the issue without triggering it. |
| 19 | GlobalKeyDetector | More than 20 keys in a scrollable; churn of 5 or more | Keep; removed in v0.20.0 | Conservative; matches the guidance that GlobalKey is expensive and should be used sparingly. |
| 20 | RebuildDetector | VM: build time above 10 % of UI-thread time warns, above 30 % is critical (`buildTimePercentThreshold`); debug per-widget 10/s or more warns, above 30/s is critical, builders 3×, held across scans | Tune; shipped v0.37.0 | The source already had a builder filter: `_builderWidgetTypes`, 7 types with a 3× threshold. Since v0.37.0 `rebuild_activity` measures cost, the share of UI-thread time inside BUILD scopes per ~1 s window, instead of BUILD scopes per second, which fired on every 60 fps animated screen; a small animated subtree measures well under 1 %. The per-widget debug gates keep the 10/s count, so non-builder animation widgets still count on the debug path. |
| 21 | ImageMemoryDetector | Decode at 1.5× or more of the needed pixels (smaller axis); total waste 1 MiB or more, critical at 16 MiB or more | Tune (was Investigate); shipped v0.37.0 | The detector checked for a `ResizeImage` wrapper, not the ratio of decoded to displayed size. Since v0.37.0 it compares the decoded `ui.Image` size from the paired `RawImage` with the render size times the device pixel ratio; the 50×50 skip and the `count > 5` critical are gone. |
| 22 | StartupDetector | TTFF warning 1500 ms, critical 3000 ms | Keep | Slightly stricter than Android Vitals' TTID and TTFD targets (2 s and 4 s); defensible. |
| 23 | AnimatedBuilderDetector | `minSubtreeSize` 50; `abRate > 30/s` (confidence) | Keep; removed in v0.20.0 | An arbitrary but defensible floor for a "large subtree". |

---

## 2. Cross-cutting concerns

These themes came up across several detectors and deserved attention before any single-detector tune.

### Frame-count warmup instead of a duration

This affected FrameTimingDetector, and in principle any detector that waits a number of ticks before firing. The warmup was `frameTimingWarmupFrameCount = 180`, commented as about 3 s at 60 FPS. On a 120 Hz device, common on 2025 to 2026 flagships, 180 frames last 1.5 s, under Android Vitals' TTID target of 2 s, so the detector evaluated frames that still belonged to startup and blamed the app for startup jank. The evidence was strong: it is a unit error. The audit recommended a duration (`Duration(seconds: 3)`) or a frame count derived from `fpsTarget`, matching StartupDetector's duration-based TTFF thresholds. v0.16.0 shipped this: `warmupDuration` defaults to 3 s, measured on vsync timestamps, and the frame count defaults to 0.

### Thresholds tied to 60 FPS

This affected HeavyComputeDetector (8 ms), RepaintDetector (30/s), RebuildDetector (10/s), CustomPainterDetector (30/s) and AnimatedBuilderDetector (30/s). On 120 Hz hardware a widget that paints 30 times a second paints once every 4 frames, a smaller share of the frame budget than at 60 Hz. A rate gate that does not scale with `fpsTarget` over-fires on 60 FPS apps or under-fires on 120 Hz apps, depending on which target its author calibrated against. The audit suggested a `rateThresholdForFps()` helper that expresses thresholds as a fraction of `fpsTarget`, for example "50 % or more of frames contain a paint of this type". It would not fix these detectors at once but would remove the hidden miscalibration. Status: v0.37.0 scales HeavyCompute with the resolved frame budget and moved the Rebuild and Repaint VM axes to time shares, which do not depend on the frame rate. The debug per-widget gates (10/s and 30/s) and CustomPainter's 30/s are still fixed rates.

### Impeller-era recalibration

This affected GpuPressureDetector (the raster/UI ratio), ShaderJankDetector (the whole detector) and FrameTimingDetector (the raster-cache windows). The rule that raster above 2× UI means GPU-bound comes from Skia. Impeller's raster thread behaves differently: it is faster in the common case and spikes on some paths, such as complex blurs and first paint, so the 2.0 ratio may be calibrated for the wrong renderer. An earlier release had already removed ShaderJankDetector's Impeller notice, but the raster ratio was never re-validated. The audit recommended collecting raster and UI traces on Impeller-only devices before tuning: the number is unsafe to change without data and unsafe to trust as it is. Status: the 2.0 ratio is unchanged. FrameTiming suppresses the cache-family warnings when Impeller reports zero cache metrics, and ShaderJank detects Impeller Vulkan pipeline builds since v0.37.0.

### Rate-based detectors without an animation filter

This affected RepaintDetector, RebuildDetector, CustomPainterDetector and possibly AnimatedBuilderDetector. A `CircularProgressIndicator` paints at the `fpsTarget` rate by design, and a Ticker-driven game loop rebuilds every frame. The audit did not find an ancestor filter for `Ticker`, `AnimationController`, `Animated*` or `TransitionBuilder` in the threshold inventory. If a spinner in an app bar reported "repaint rate 60/s" every session, users would turn the detector off or drop Sleuth, and that kind of false positive erodes trust in every detector. The audit ranked confirming this from source as the first thing to do before any tune. The source check found the filter missing only in RepaintDetector; the fix shipped in v0.15.3 (section 7).

### Critical at twice the threshold

Most detectors use `threshold`, `2 × threshold` and `3 × threshold` as the warning, critical and escalated-critical ladder. Severity should follow cost and confidence, not doubling. Jank at 17 ms (a missed frame) and at 34 ms (a visibly dropped frame) differ physically, while native growth of 1.5 MB/s against 2 MB/s is a factor of the count, not of user impact. The convention is convenient rather than justified. The audit rated this low priority, since the convention works in most cases, and noted that individual detectors may deviate. Today the VM time-share axes, the per-widget rebuild rate, ListView and NetworkMonitor use 3× for critical.

---

## 3. Per-detector analyses

These detectors held up less well, and the full reasoning follows. Detectors not listed here earned a Keep in section 1.

### FrameTimingDetector: tune the warmup

At audit time the values were `warningThresholdMs = 1000/fpsTarget`, `criticalThresholdMs = 2 × warning`, `warmupFrameCount = 180`, `jankPercent > 15`, `severeCount >= 3` in the last 60 frames, `thrashingWindowFrames = 15` and `growthWindowFrames = 30`. The leading hypothesis was that the warmup must be a duration, not a frame count, and that the other thresholds are defensible. The strong evidence: a frame-count warmup lasts 1.5 s at 120 Hz, under the TTID target. Medium evidence: `jankPercent > 15` is stricter than Android Vitals' "excessive slow frames" (typically 25 %), which is the conservative direction. Weak evidence: `severeCount >= 3` in 60 frames has no citation and can fire on one bad GC event among smooth frames. A falsification test was proposed and not run: a synthetic 120 Hz trace with 2.5 s of startup jank followed by smooth frames. The verdict was Tune: switch the warmup to a duration or an `fpsTarget`-derived count, and document the severe-frame rule.

Status: the duration warmup shipped in v0.16.0. The severe-frame rule now counts frames since the route epoch, within a 240-frame buffer.

### ListviewDetector and NestedScrollDetector: tune the child threshold

At audit time `childThreshold` was 50, escalated at 100 and 150. The hypothesis was that the threshold is 2.5 times more lenient than Flutter guidance: the Flutter docs and several 2025 performance guides cite 20 or more items as the point where a non-lazy list stops being acceptable. Against it, a lower threshold adds warnings on legacy code, and a Column of 30 small text rows is not a real performance bug. The deciding question is whether the detector reports a structural anti-pattern (then 20 is right) or observable scroll-jank risk (then 50 may be defensible); the wording of its fix hint decides. The verdict was Tune to about 25 with escalations at 50 and 100, or a soft warning at 20 and a critical at 50; keeping 50 leaves the miscalibration in place.

Status: not applied. The threshold is still 50, critical is above 150 (3×), and the same threshold feeds four detection paths (section 7). NestedScrollDetector was removed in v0.20.0.

### ShallowRebuildRiskDetector: tune the depth

At audit time `depthThreshold` was 3. The hypothesis was a false positive on the MaterialApp, Navigator, Home stack: Flutter's standard root puts the first user-written StatefulWidget at depth 3 to 5, under `MaterialApp`, `Overlay`, `Navigator`, `Focus`, `Semantics` and others. Against it, a framework-name filter might already exempt those widgets. The verdict was Investigate before tuning, and Keep if the filter exists.

Status: the source check found the filter and graded it Keep. The detector was removed in v0.20.0.

### HeavyComputeDetector: scale with the frame rate

At audit time `lagThresholdMs` was 8, with critical at 16. The first hypothesis was that 8 ms is the 120 Hz frame budget and normal half-frame work at 60 FPS, so the detector would fire on every frame, unless it measured gaps between frame work. The source check showed the threshold applies to BUILD pass durations, so that reasoning was wrong. The correct reasoning: at 60 Hz an 8 ms build uses half the frame budget, a defensible warning; at 120 Hz it uses the whole budget, so the warning comes too late. The verdict stayed Tune: scale with the frame rate.

Status: shipped in v0.37.0. Without an explicit `heavyComputeGapMs`, the threshold is 8 ms at the `fpsTarget` budget and half the resolved frame budget when the measured rate is higher, 4.2 ms at 120 Hz.

### NetworkMonitorDetector: tune the slow threshold (shipped v0.15.4)

Before v0.15.4 the values were `slowThresholdMs = 2000` and a hard-coded `_criticalSlowThresholdMs = 5000`. The hypothesis was that 2 s was 2 to 10 times more lenient than current mobile-API guidance. The 2026 guidance the audit found: 100 to 300 ms is ideal; 500 to 800 ms is acceptable for aggregated endpoints; 1 s is a noticeable slowdown; every cited source calls more than 1 s slow; more than 2 s, what the old threshold caught, is very slow; and one source ties 100 ms of latency to a 1 % drop in conversion. Against it, Sleuth is a developer diagnostic, not a UX alarm, and 2 s may have been chosen to flag only clear bugs. The audit recommended a warning at 1000 ms and a critical at 3000 ms, or keeping the old values with their position on the scale documented.

v0.15.4 shipped symmetric configuration: slow from 2000 to 1000 ms and critical from 5000 to 3000 ms, both as constructor parameters and `SleuthConfig` fields (`slowRequestThresholdMs`, `criticalSlowRequestThresholdMs`). A debug-mode `assert(criticalSlowThresholdMs > slowThresholdMs)` runs in both constructors, including `copyWith`, so the critical tier is always reachable. The change was a non-breaking patch: both parameters are optional with defaults, and `SleuthConfig(slowRequestThresholdMs: 2000, criticalSlowRequestThresholdMs: 5000)` restores the old stance. See CHANGELOG 0.15.4.

### MemoryPressureDetector: GC-rate semantics (resolved v0.26.0, retuned v0.37.0)

The current default fires `gc_pressure` above 180 cycles per minute, measured over a 10 s window (`_gcWindowDuration`) and configurable through `SleuthConfig.gcRateThresholdPerMin`.

v0.26.0 confirmed that `EventStreams.kGC` emits one event per completed GC cycle, new-space scavenges and old-space collections alike. A moderately allocating UI scavenges about 30 times a minute at steady state, so the previous 30 per minute default fired on routine animation rebuilds and incremental scrolling. The default doubled to 60 per minute. Filtering `kGC` to old-space cycles was the alternative; a threshold change was chosen because apps can still opt into the old sensitivity.

v0.37.0 raised the default from 60 to 180. With Sleuth attached, an idle app runs 1 to 2 scavenges a second from the VM-service poll traffic (66 to 138 per minute measured on an iPhone 12), while allocation churn and the stress demos measured 2,000 to 3,100 per minute. Each emission stamps `scavengeCount` and `oldGenCount`, read from the event's raw `gcType`, so a later tune can separate young-gen churn from old-gen collections without changing the rule.

### SetStateScopeDetector: investigate the dirty ratio

At audit time `dirtyRatioThreshold` was 0.5. The hypothesis was that 50 % of the tree owned by one State is far too lenient. Flutter's guidance says a stateful widget would ideally create a single widget, a RenderObjectWidget, and the detector fires at 50 times that. On the other side, 30 % or 25 % would catch most real offenders but also flag legitimate layouts, such as a top-level Scaffold that owns most of the tree, and in an `IndexedStack` app the tab shell owns about 100 % of the visible tree. The verdict was Investigate whether the detector exempts the route-scaffold or tab-shell case before lowering the ratio; the per-tab session tracking added in v0.14.1 suggested it did.

Status: the source check graded it Keep (section 7). Since v0.37.0 it emits only when it observes rebuilds.

### ImageMemoryDetector: measurement semantics (resolved v0.37.0)

At audit time the detector used `_smallImageThreshold = 50.0` and called `count > 5` critical. The hypothesis was that a missing `cacheWidth` or `cacheHeight` is only a proxy for the real problem, the ratio of decoded size to displayed size. Flutter's own memory example shows a 4K image rendered at 384×216 using 100 times the memory it needs without `cacheWidth`; a 500×500 image shown at 500×500 without `cacheWidth` is not a bug. The audit expected the ratio to need `ImageInfo`, which the element tree might not expose. The verdict was Investigate, as a correctness question rather than a threshold tune.

Status: v0.37.0 reaches the decoded image without `ImageInfo` listeners. Each `Image` builds a `RawImage` whose public `image` holds the decoded `ui.Image`. The detector pairs them during the walk, compares the decoded size with the render box times the device pixel ratio on the smaller axis (1.5× or more qualifies), and emits on total wasted bytes (1 MiB or more, critical at 16 MiB or more) as `likely`. `BoxFit.none`, `centerSlice`, `repeat` and `ResizeImage` are skipped.

---

## 4. Detectors that held up

- StartupDetector (TTFF 1500 and 3000 ms) is slightly stricter than Android Vitals' TTID under 2000 ms and TTFD under 4000 ms, which is defensible.
- FontLoadingDetector (3 families) matches the 2025 Flutter guidance exactly.
- KeepAliveDetector (5 and 10 pages) matches the memory-overhead rule of thumb, and no source contradicts it.
- LayoutBottleneckDetector (Wrap above 30, nested intrinsics escalate) follows the O(N²) IntrinsicHeight warning in Flutter's API docs.
- PlatformChannelDetector (20 calls per second) uses a reasonably high bar. Its 8 ms cumulative trigger, anchored on the 60 FPS budget, was removed in v0.37.0.
- GlobalKeyDetector (20, critical at 60) followed the Flutter docs' advice to use GlobalKey sparingly. Removed in v0.20.0.
- OpacityDetector (exactly 0.0) was a narrow structural rule justified by the engine's 0.0 short-circuit. Removed in v0.20.0.
- AnimatedBuilderDetector (minimum subtree 50) used an arbitrary floor consistent with the "large subtree" intent in Flutter's docs. Removed in v0.20.0.

---

## 5. Top five action items

The document review first ranked five threshold changes; the source check reordered them. It demoted the ListView child threshold, which only catches eager construction, and promoted the RepaintDetector animation filter, the only finding with a concrete, named false-positive case.

1. RepaintDetector animation filter, shipped in v0.15.3. `repaint_detector.dart` had no animation-aware filter, so any widget at 30 or more paints per second fired `excessive_repaint`, and a `CircularProgressIndicator` spinning at 60 Hz in an app bar fired on every session. The fix checks ownership per paint against a shared owner set in `lib/src/utils/animation_owner_names.dart`, through three legs: the chain regex, a typed ancestor walk and a typed descendant walk. Checking per paint, in `_handleProfilePaint`, means two widgets with one type name (a `CustomPaint` inside an `AnimatedBuilder` and one driven by `setState`) are judged separately. See CHANGELOG 0.15.3 and section 7.
2. FrameTimingDetector warmup as a duration, shipped in v0.16.0. `frame_timing_detector.dart:49` had `180; // ~3s at 60fps`, which is 1.5 s at 120 Hz.
3. NetworkMonitorDetector slow threshold at 1000 ms and critical at 3000 ms, shipped in v0.15.4. The 2 s value (`network_monitor_detector.dart:24,49` at audit time) was far more lenient than every 2025 to 2026 source. See section 3 and CHANGELOG 0.15.4.
4. ImageMemoryDetector ratio of displayed to decoded size instead of the presence of `ResizeImage`, shipped in v0.37.0. The source check confirmed a measurement gap, not a threshold to tune: the detector flagged any `Image` not wrapped in `ResizeImage` and not 50×50 or smaller, which produced false positives on correctly sized network images. The audit expected the fix to need an `ImageStreamListener`; v0.37.0 reads the decoded image from the paired `RawImage` instead.
5. HeavyComputeDetector scaling with the frame rate, shipped in v0.37.0. The threshold gates BUILD pass duration, not an inter-frame gap. At 60 Hz an 8 ms build uses half the budget; at 120 Hz it uses all of it. The audit proposed `lagThresholdMs = max(8, (1000 ~/ fpsTarget) ~/ 2)`; the shipped rule uses half the resolved frame budget when the measured rate is above `fpsTarget`, 4.2 ms at 120 Hz.

Demoted from the first list:

- The ListView child threshold at 25 is still defensible but matters less than first claimed, because the detector only catches eager `children: [...]` construction, not `.builder()`, which modern code mostly uses.
- "Confirm that rate-based detectors exempt animations" became the concrete RepaintDetector fix above. RebuildDetector's filter already existed, and CustomPainterDetector does not need one, because its primary check is structural.

Added from the source check:

- MemoryPressureDetector GC threshold, shipped in v0.26.0: the `gcRateThresholdPerMin` default went from 30 to 60, and to 180 in v0.37.0, above the idle rate Sleuth's own polling produces. Dart's young-gen scavenges, about 30 per minute on a moderately allocating UI, had fired the old default on routine animation rebuilds. Filtering `kGC` to old-space cycles was the alternative; a threshold change was chosen so apps can still opt into the older sensitivity with `SleuthConfig(gcRateThresholdPerMin: 30)`.

---

## 6. Limits of this audit

- The document review searched the open web, the Flutter docs and Android Vitals. It did not search Flutter engine benchmarks, Google Play data, or other performance packages such as `flutter_lints` and `dart_code_metrics`, any of which could contradict a best-practice value.
- Evidence strength was graded for the top items only. Most Keep verdicts mean "no evidence against", not "strong evidence for".
- Falsification tests were named for most Tune recommendations and none were run, so each Tune verdict was likely, not confirmed. No recommendation was checked with a failing-then-passing reproduction.
- The document review did not check what each threshold does; some are confidence gates rather than firing gates, so a few items may have been ranked too high.
- The source check read 9 of the 23 detectors, chosen where audit errors were expected; the other 14 were not re-read. It read only `lib/src/detectors/`, not the controller, the suppression rules in `SleuthConfig`, the `IssueRanker`, or the overlay and AI chat that consume issues, any of which could weaken or strengthen a finding before the user sees it. It read the source but did not trigger any detector, for example by mounting a 100×100 network image in a 100×100 box, and it did not list alternative readings of each detector's purpose, such as an intentionally pessimistic `ResizeImage` rule.
- The audit compared the current thresholds with documented practice. It does not give one correct value per threshold: many detectors have no published canonical number (rebuilds per second, subtree size), and the best verdict for them is "arbitrary but defensible".

---

## 7. Source verification (2026-04-15)

The document review was then checked against the detector source, including the Investigate items it had left open. Line numbers refer to v0.15.2.

### 7.1 Verdict changes

| Document verdict | Detector | Source check | Source evidence |
|---|---|---|---|
| Tune the warmup | FrameTimingDetector | Holds | `frame_timing_detector.dart:49`: `_defaultWarmupFrameCount = 180; // ~3s at 60fps`. A unit error, as claimed. Shipped in v0.16.0. |
| Investigate | RepaintDetector | Tune, stronger | `repaint_detector.dart:24-303` had no animation, Ticker or builder filter; the whole gate was `paintsPerSecond >= 30`. `_evaluateDebugDataPerWidget` (line 266) iterated every type in `snapshot.paintCounts` with no exemption. Shipped in v0.15.3. |
| Tune | RebuildDetector | Tune, with a correction | `rebuild_detector.dart:45-56`: `_builderWidgetTypes = {StreamBuilder, FutureBuilder, ValueListenableBuilder, AnimatedBuilder, ListenableBuilder, TweenAnimationBuilder, StreamBuilderBase}` with `_builderThresholdMultiplier = 3`, which the document review missed. The remaining gap: animation StatefulWidgets such as `CircularProgressIndicator` and `RotationTransition` were not in the set and fired at 10 per second. |
| Tune the child threshold | ListviewDetector | Tune, narrower scope | `listview_detector.dart:103-104,144`: `childThreshold = 50` with a `>` comparison. The detector matches only `SliverChildListDelegate` (the eager `children: [...]` form); `SliverChildBuilderDelegate` (the lazy `builder:` form) is exempt, so modern code mostly avoids it. |
| Tune the depth | ShallowRebuildRiskDetector | Keep | `shallow_rebuild_risk_detector.dart:91-105`: a 13-entry framework filter: `Scaffold, CupertinoPageScaffold, ScaffoldMessenger, AppBar, Material, AnimatedTheme, ScrollConfiguration, ScrollNotificationObserver, _ModalScope, Navigator, Overlay, FocusScope, FocusTraversalGroup`. The document review had said to keep it if such a filter existed. |
| Tune | HeavyComputeDetector | Tune, with corrected reasoning | `heavy_compute_detector.dart:38-61`: the threshold applies to `event.durationUs / 1000` of BUILD phase events, not to an inter-frame gap. At 60 Hz an 8 ms BUILD uses half the frame budget, a defensible warning; at 120 Hz it uses all of it, so the warning fires too late. Shipped in v0.37.0. |
| Tune | NetworkMonitorDetector | Holds | `network_monitor_detector.dart:24,49`: `slowThresholdMs = 2000`, `_criticalSlowThresholdMs = 5000`. Industry guidance agreed. Shipped in v0.15.4 with symmetric configuration: defaults 1000 and 3000 ms, a `criticalSlowThresholdMs` constructor parameter, `SleuthConfig.criticalSlowRequestThresholdMs`, and a strictly-greater assert in both constructors. |
| Investigate | MemoryPressureDetector GC rate | Tune | `memory_pressure_detector.dart`: `gcPerMinute = (windowEvents / 10s) * 60`. `EventStreams.kGC` emits "exactly one event per completed GC cycle", new-space scavenges and old-space alike. Shipped in v0.26.0 (30 to 60 per minute) and v0.37.0 (180 per minute). |
| Investigate | SetStateScopeDetector | Keep | `setstate_scope_detector.dart:152-319`: a framework filter (`isFrameworkWidget`), an animation-scope filter (`_containsAnimationScope`), a const-element discount (`mutableSubtreeSize = subtreeSize − stableCount`), a 5 s rebuild-evidence window (`_evidenceWindowSeconds = 5`), a `minSubtreeSize = 50` floor, and separate paths for `hasRebuildEvidence` and for `!hasRebuildEvidence && !hasAnimScope`. |
| Investigate | CustomPainterDetector | Keep; the concern was backwards | `custom_painter_detector.dart:66-93`: the primary check is structural, `painter.shouldRepaint(painter)`. The detector fires at any paint rate, and the rate only raises confidence (lines 104-110: `cpRate > 10` turns possible into likely). The worry that it missed low-rate always-true painters was backwards. The 30 per second rate gates the secondary branch, which catches painters that pass the self-comparison but repaint through new instances. |
| Investigate | ImageMemoryDetector | Tune | `image_memory_detector.dart:74-87`: the detector flagged any `Image` not wrapped in `ResizeImage` (and not 50×50 or smaller) and did not measure decoded against displayed size. False positives: a 100×100 network image shown at 100×100, or an icon asset of 50×50 or less shown at 60×60. Missed cases: an image wrapped in `ResizeImage` at the wrong size passed. A measurement gap, not a threshold to tune. Shipped in v0.37.0. |

### 7.2 Findings the document review missed

#### The animation filter differed between Repaint and Rebuild (shipped v0.15.3)

The document review grouped RepaintDetector and RebuildDetector under one missing-animation-filter concern, but the source showed they differed. RebuildDetector had the `_builderWidgetTypes` set with a 3× threshold, so an `AnimatedBuilder` ticking at 60 per second fired only above 30 per second, not 10. RepaintDetector had no filter, so any widget type at 30 or more paints per second fired. The false positives were therefore much more common on the repaint side, which also had no cover for the widgets RebuildDetector partly exempted: a `CircularProgressIndicator` rotating at 60 Hz in an app bar raised `excessive_repaint` and `repaint_debug_CircularProgressIndicator` in every session, on every page that mounted it. The two options were to share the builder set between the detectors, a one-constant change, or to suppress widgets whose State is driven by a `Ticker` or `AnimationController` through an ancestor walk, which is more correct and costs more.

v0.15.3 shipped a refined form of the second option. RepaintDetector got a 7-entry owner set (4 Material and Cupertino indicators and 3 generic builders) and an owner regex with `\b` word boundaries, smaller than RebuildDetector's set because `widget_location.dart` strips most transition widgets from the chain before the check sees it. Three gates used the filter: the per-widget gate skipped a type whose cached ancestor chain matched the regex, and fired when no chain was cached; the VM fallback was suppressed when every non-zero entry in `paintCounts` was animation-owned; and the debug aggregate subtracted owned paints from `totalPaintCount`, suppressed the issue when the residual rate fell under the threshold, and otherwise added "Excludes N animation-owned paints" to the detail.

The difference from RebuildDetector is deliberate: a full exemption for repaints and a 3× multiplier for rebuilds. A `CircularProgressIndicator` is meant to paint at the device refresh rate, so no paint rate is too high for it. A high rebuild rate on the same widget is ambiguous, because a parent may be re-mounting it 60 times a second by mistake.

A follow-up in the same release fixed five problems with one root cause: ownership was read from a cached chain string keyed on `runtimeType`, which is built to show source locations to people and is too shallow, too lossy and too collision-prone for an ownership filter. Ownership moved to a typed walk per paint, at paint-callback time, against the live `Element`.

- The coordinator cached one chain per type name, so two `CustomPaint` widgets, one inside an `AnimatedBuilder` and one driven by `setState`, were suppressed together or fired together. `_handleProfilePaint` now calls `isAnimationOwnedPaint(element, chain)` on the live element, and `DebugSnapshot` carries `animationOwnedPaintCounts` and `totalAnimationOwnedPaintCount`, which the detector reads instead of judging the chain. Mixed ownership under one type name is now counted correctly.
- The 7 owners missed the implicit `Animated*` widgets (12 at the time) as well as `Hero` and `RefreshIndicator`, each of which runs an `AnimationController` to tween between values; every implicit animation raised a false `repaint_debug_*`. The set grew to 21 entries (22 today) and moved to `lib/src/utils/animation_owner_names.dart`, shared by the coordinator and the detector.
- A `CircularProgressIndicator` without its own `RepaintBoundary` marks the nearest layer-owning ancestor, often `Center` or `Stack`, for repaint. The chain walks up from that ancestor, so the indicator is a descendant of the painted element and the chain check misses it. `isAnimationOwnedPaint` added a bounded descendant walk (`hasAnimationOwnerDescendant`, at most 32 visits and 4 levels) with a typed runtime-type match.
- `element.visitAncestorElements` can throw while a widget deactivates ("Looking up a deactivated widget's ancestor is unsafe"), and the exception crashed the instrumentation through `_handleProfilePaint`. Chain capture in `debug_instrumentation_coordinator.dart` is now wrapped in try/catch: the paint still counts, and only that event's chain is skipped.
- Only `CircularProgressIndicator` had a real-widget test; the other owners and the two cases above relied on fixtures that mirrored the filter's own assumptions. `test/detectors/repaint_animation_owners_real_widget_test.dart` added 8 real-widget tests: LinearProgressIndicator, RefreshProgressIndicator, TweenAnimationBuilder, AnimatedBuilder, ValueListenableBuilder, AnimatedContainer, a mixed-ownership scene and a bare indicator without a RepaintBoundary. The TweenAnimationBuilder and ValueListenableBuilder tests found a bug at once: `hasAnimationOwnerDescendant` looked up `'TweenAnimationBuilder<double>'` in a set that holds `'TweenAnimationBuilder'`. The walk now strips the generic suffix with one `indexOf('<')` before the lookup, with no allocation for non-generic types.

`RefreshProgressIndicator` exposed one more gap. Its painted `CustomPaint` sits about 13 ancestors below the wrapping `AnimatedBuilder` because of Material's internal decoration stack, while `buildAncestorChain` stops at `maxDepth: 6` to keep the chain readable, and the owner is above the painted element, so the descendant walk misses it too. `isAnimationOwnedPaint` now has three legs, checked cheapest first: the chain regex, a typed ancestor walk (16 levels, independent of the chain's depth), and the typed descendant walk. The fixture tests for the gate logic in `test/detectors/repaint_detector_test.dart` and the real-widget `CircularProgressIndicator` test in `test/detectors/repaint_animation_filter_real_widget_test.dart` remain.

The gates today, described in [`internals.md`](internals.md#debug-rebuild-and-paint-counts):

- `repaint_debug_<type>` compares the busiest instance's likely-origin rate with the threshold, and `RateHysteresis` holds the result across scans. The origin is the deepest render object marked as needing paint in its layer, mapped to the nearest widget the app creates, with animation-owned origins left out. Widgets that only repaint because they share the layer are not counted.
- The VM share, `excessive_repaint`, is hidden while every paint in the window, framework paints included, was animation-owned.
- `excessive_repaint_debug` subtracts owned paints from the total, stays silent when the residual rate is under the threshold, adds "Excludes N animation-owned paints" otherwise, and shows only without a VM connection.
- The owners that animate by rebuilding (`AnimatedBuilder`, `ValueListenableBuilder`, `TweenAnimationBuilder`, and six implicit `Animated*` widgets) own paints only in frames where they rebuilt, so an idle one next to a repainting widget does not hide it.

The implementation spans `lib/src/detectors/repaint_detector.dart`, `lib/src/utils/animation_owner_names.dart`, `lib/src/debug/debug_instrumentation_coordinator.dart` and `lib/src/debug/debug_snapshot.dart`.

#### RebuildDetector's framework filter covers only `stateful_density`

At audit time (`rebuild_detector.dart:456-501`) the `_frameworkWidgetNames` set had 49 entries, including the 9 Sleuth overlay widgets added in v0.13.1 and `TweenAnimationBuilder` added in v0.15.2. Only the structural fallback (`_evaluateStructuralOnly`, line 419) read it, not the per-type rebuild path, so with a debug snapshot a rebuild attributed to `Scaffold` could still surface as `rebuild_debug_Scaffold`.

Status: the set has 42 entries and still serves only `stateful_density`. The per-type path no longer needs it, because debug counts keep only widgets the app creates (`DebugInstrumentationConfig.userWidgetsOnly`) and a rebuild counts for the widget that started it.

#### The severe-frame rule was undocumented but not arbitrary

At audit time (`frame_timing_detector.dart:191-220`) `sustained_jank` checked whether 3 of the last 60 frames, 5 % of that buffer, were severe jank (above 33 ms at 60 Hz). That is a noise floor tied to the buffer size, not to the frame rate. The rule was defensible, but it had no inline rationale, which made this a low-priority documentation fix rather than a tune.

Status: the rule now counts 3 severe frames among the frames since the route epoch, within a 240-frame buffer.

#### ListviewDetector reuses `childThreshold` across paths

At audit time (`listview_detector.dart:80,144` and `_checkForNonLazyList`) the same `childThreshold = 50` fed three detection paths: a non-lazy ListView or GridView, a non-lazy sliver, and a `SingleChildScrollView` with a `Column`. Lowering it to 25 changes all of them at once. That is probably still right, but one constant affects more than the document review implied.

Status: it now feeds four paths; `sliver_to_box_adapter_large` also reads it.

### 7.3 Open questions and their answers

1. Does the IssueRanker suppress `repaint_debug_CircularProgressIndicator` in practice? The audit expected not: the debug callback measures it as `confirmed`, at warning severity, and the weighted score would not discount it. Answer: the ranker has no name-based suppression; it scores every issue as `tier × 100 + frameImpact × 8 + recurrence × 2`. The case no longer arises, because the indicator's paints are animation-owned and a framework widget has no per-widget count.
2. Did the author intend `ImageMemoryDetector` as a structural lint or a runtime cost gate? The audit expected a structural lint, because the `_smallImageThreshold = 50` skip looks like a shortcut for obviously cheap images rather than a cost decision. Answer: v0.37.0 rebuilt it as a cost gate that measures decoded against needed pixels.
3. Does `MemoryPressureDetector.recordGcCycle` receive every `kGC` stream event, or only old-space cycles? The audit expected every event, per the comment "exactly one event per completed GC cycle", but did not read `_onGcEvent`. Answer: `SleuthController._onGcEvent` forwards every `kGC` event without filtering and passes the raw `gcType`, which the detector uses to split scavenges from old-gen collections.

---

## 8. Sources

Jank, frame budget, FPS:
- [Flutter performance profiling](https://docs.flutter.dev/perf/ui-performance)
- [Flutter App Performance: Profiling, Fixing Jank, and Optimization Tips (2026)](https://startup-house.com/blog/flutter-app-performance)
- [Flutter performance: how to diagnose jank and FPS drops (2026)](https://chdr.tech/en/2026/03/05/flutter-performance-diagnose-jank-fps/)
- [Use the Performance view (DevTools)](https://docs.flutter.dev/tools/devtools/performance)

Startup (TTFF, TTID, TTFD):
- [App startup time | Android Developers](https://developer.android.com/topic/performance/vitals/launch-time)
- [How to Reduce App Startup Time on Android, iOS & Flutter (2026 guide)](https://www.digia.tech/post/app-startup-time-performance-guide)
- [Load sequence, performance, and memory (Flutter docs)](https://docs.flutter.dev/add-to-app/performance)

Impeller, shaders, GPU pressure:
- [How Impeller Is Transforming Flutter UI Rendering in 2026](https://dev.to/eira-wexford/how-impeller-is-transforming-flutter-ui-rendering-in-2026-3dpd)
- [Impeller rendering engine (Flutter docs)](https://docs.flutter.dev/perf/impeller)
- [Shader compilation jank (Flutter docs)](https://docs.flutter.dev/perf/shader)
- [Mitigate OOM Crashes by Exposing Impeller GPU Memory Stats #178264](https://github.com/flutter/flutter/issues/178264)

RepaintBoundary, rebuilds:
- [RepaintBoundary (Flutter API docs)](https://api.flutter.dev/flutter/widgets/RepaintBoundary-class.html)
- [Flutter 2025 Performance Best Practices: What Has Changed & What Still Works](https://flutterexperts.com/flutter-2025-performance-best-practices-what-has-changed-what-still-works/)
- [Stop Unnecessary Widget Rebuilds in Flutter (2026)](https://medium.com/@developer.hub/stop-unnecessary-widget-rebuilds-in-flutter-d75aef758bbe)

Lists, layout:
- [Performance best practices (Flutter docs)](https://docs.flutter.dev/perf/best-practices)
- [Why ListView Can Hurt Your App's Performance](https://dev.to/bestaoui_aymen/why-listview-can-hurt-your-apps-performance-and-what-to-use-instead-1dbc)
- [IntrinsicHeight (Flutter API docs)](https://api.flutter.dev/flutter/widgets/IntrinsicHeight-class.html)
- [Intrinsic Widget Alternatives for Enhancing Flutter Performance](https://www.logique.co.id/blog/en/2025/03/25/intrinsic-widget-alternatives/)

AnimatedBuilder, Opacity, CustomPainter:
- [AnimatedBuilder (Flutter API docs)](https://api.flutter.dev/flutter/widgets/AnimatedBuilder-class.html)
- [Why do TweenAnimationBuilder and AnimatedBuilder have a child argument?](https://codewithandrea.com/articles/flutter-animated-builder-child-widget-argument/)
- [Opacity (Flutter API docs)](https://api.flutter.dev/flutter/widgets/Opacity-class.html)
- [Optimizing Flutter Apps: Avoid Opacity and Clipping](https://www.logique.co.id/blog/en/2025/04/23/optimizing-flutter-apps/)
- [CustomPainter.shouldRepaint (Flutter API docs)](https://api.flutter.dev/flutter/rendering/CustomPainter/shouldRepaint.html)

Memory, images, GC:
- [Use the Memory view (DevTools)](https://docs.flutter.dev/tools/devtools/memory)
- [How We Reduced Flutter Memory Usage by 375mb: Image Optimization Strategies](https://saropa-contacts.medium.com/how-we-reduced-flutter-memory-usage-by-375mb-image-optimization-strategies-5a097246ee0c)
- [How Dart's Garbage Collector Works](https://medium.com/@punithsuppar7795/how-darts-garbage-collector-works-and-when-it-fails-you-2e0c3c75928d)

Network, API response time:
- [API Response Time Standards: What's Good, Bad, and Unacceptable](https://odown.com/blog/api-response-time-standards/)
- [What's a good API response time? Benchmarks to beat in 2025](https://myfix.it.com/what-s-a-good-api-response-time-benchmarks-to-beat-in-2025/)
- [How to Optimize API Response Times for Mobile Apps](https://technori.com/news/optimize-api-response-times-mobile-apps/)
- [10 REST API Payload Size Best Practices](https://climbtheladder.com/10-rest-api-payload-size-best-practices/)

Platform channels, isolates, GlobalKey, fonts, KeepAlive:
- [Improving Platform Channel Performance in Flutter](https://medium.com/flutter/improving-platform-channel-performance-in-flutter-e5b4e5df04af)
- [Concurrency and isolates (Flutter docs)](https://docs.flutter.dev/perf/isolates)
- [Elements, Keys and Flutter's performance](https://medium.com/flutter-community/elements-keys-and-flutters-performance-3ef15c90f607)
- [Optimizing Font Usage in Flutter for Better Performance and UX](https://medium.com/@balaeon/optimizing-font-usage-in-flutter-for-better-performance-and-ux-a448875ba693)
- [Mastering Flutter List Performance With AutomaticKeepAlive](https://vibe-studio.ai/insights/mastering-flutter-list-performance-with-automatickeepalive)
- [AutomaticKeepAlive (Flutter API docs)](https://api.flutter.dev/flutter/widgets/AutomaticKeepAlive-class.html)
