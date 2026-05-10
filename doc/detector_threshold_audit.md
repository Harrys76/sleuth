# Detector Threshold Audit

**Date (pass 1):** 2026-04-14 — documentation cross-reference.
**Date (pass 2):** 2026-04-15 — meta-investigation; pass 1 verdicts regraded against detector source. See §7 for the regrade and §1 for the inline verdict updates (`²` markers).
**Against:** Sleuth v0.15.2 (23 detectors)
**Scope:** Every numeric/duration/ratio threshold in `lib/src/detectors/`, cross-referenced against 2025–2026 Flutter performance, Android Vitals, Impeller, and mobile-API sources, then verified against the detector source.

Context of the package: defaults target 60 FPS, warmup ≈ 3 s, release mode is fully gated off. The package is a diagnostic aid, not a production throttle — false positives cost reputation, false negatives miss real bugs. That asymmetry drives every verdict below.

**Pass 2 headline:** the three highest-leverage TUNE recommendations (FrameTiming warmup, NetworkMonitor slow threshold, Listview childThreshold) all survived source-reading. **But 4 of 5 `INVESTIGATE` verdicts collapsed to ✅ KEEP** when the detector source was actually read — the audit had deferred questions it could have answered with one file open. The biggest miss the audit made: it lumped Repaint and Rebuild detectors under "C4 missing animation filter" when only RepaintDetector lacks one (RebuildDetector has a 6-entry `_builderWidgetTypes` set with a 3× threshold). The most actionable single fix is now adding an animation-aware filter to RepaintDetector — see §7 M1.

---

## 1. Verdict summary — all 23 detectors

Legend: ✅ Keep (survives scrutiny) · 🔧 Tune (specific change recommended) · 🔍 Investigate (unverified / needs falsification run) · ⚠ Stale (deserves architectural rethink for the 2026 Impeller era). Verdicts annotated `²` were regraded in pass 2 against detector source — see §7.

| # | Detector | Key threshold(s) | Verdict | One-line rationale |
|---|---|---|---|---|
| 1 | FrameTimingDetector | `1000/fpsTarget` ms warn, 2× crit, warmup = 180 **frames** | 🔧 ²✅held | Frame-count warmup breaks on 120 Hz (1.5 s vs intended 3 s); `severeCount ≥ 3 in 60` is undocumented magic. Confirmed at `frame_timing_detector.dart:49`. |
| 2 | RepaintDetector | paintFreq > 30/s warn, 60/s crit; "likely" at 10/s | 🔧 ²⬆ | **Pass 2 upgraded from 🔍 → 🔧.** Source confirms zero animation/Ticker filter exists. `CircularProgressIndicator`-class widgets WILL fire excessive_repaint at 60 Hz. Now the highest-priority fix. |
| 3 | RepaintBoundaryDetector | maxAncestorDepth = 5; excessive boundary = 20 per scrollable | 🔧 | Depth 5 has no cited rationale; "20 per scrollable" collides with normal `ListView.builder` idioms. (Pass 2 did not re-verify.) |
| 4 | CustomPainterDetector | cpRate > 10 likely, > 30 critical | ✅ ²⬇ | **Pass 2 downgraded from 🔍 → ✅.** Primary check is structural (`painter.shouldRepaint(painter)` self-test, line 71); rate is only a confidence escalator, not a firing gate. Pass 1 hypothesis was inverted. |
| 5 | ListviewDetector | childThreshold = **50**, 2× = 100, 3× = 150 | 🔧 ²✅held + scope | Flutter docs cite `20+ items → builder`. **Pass 2 caveat:** detector only catches eager `SliverChildListDelegate` (`children:[...]`), NOT `.builder()`. Most modern code is unaffected — false-positive risk lower than pass 1 implied. |
| 6 | NestedScrollDetector | childThreshold = 50 (shared) | 🔧 | Same as #5. |
| 7 | LayoutBottleneckDetector | wrap children > 30; 2× crit | ✅ | Conservative but defensible; the real risk (nested intrinsics) is handled structurally. |
| 8 | ShallowRebuildRiskDetector | depth ≤ 3; build count > 20 | ✅ ²⬇ | **Pass 2 downgraded from 🔧 → ✅.** Framework filter exists at `shallow_rebuild_risk_detector.dart:91-105` (13 entries: Scaffold, Material, Navigator, Overlay, _ModalScope, Focus*, etc.). The audit's "MaterialApp → Navigator → Home false-positive" worry is mitigated. |
| 9 | HeavyComputeDetector | 8 ms gap warn, 16 ms crit | 🔧 ²✅held + reasoning fix | Threshold scales with `fpsTarget` is still right, but **pass 1's stated reasoning was wrong**: source applies threshold to BUILD PHASE DURATION, not inter-frame gap. Corrected reasoning in §7. |
| 10 | FontLoadingDetector | maxFamilies = 3 | ✅ | Exact match with Flutter 2025 guidance ("stick to 2–3 fonts"). |
| 11 | KeepAliveDetector | pages > 5 warn, > 10 crit | ✅ | Aligns with "5 complex kept-alive pages ≈ 50–200 MB" rule-of-thumb. |
| 12 | GpuPressureDetector | raster:UI ratio > 2.0; blur σ > 10 crit; subtree > 5 | 🔍 | 2.0 ratio was calibrated in the Skia era; Impeller's raster/UI shape differs. Needs re-baseline on Impeller-default traces. (Pass 2 did not re-verify.) |
| 13 | ShaderJankDetector | compile > 100 ms, > 200 ms crit | ⚠ | Impeller is default on both platforms as of 2025; this detector is architecturally vestigial (threshold itself is fine). |
| 14 | OpacityDetector | exact `== 0.0` | ✅ | Boolean structural rule; the engine's 0.0 short-circuit justifies narrow scope. |
| 15 | MemoryPressureDetector | growth > 512 000 B/s; capacity > 80 %; GC > 60/min; native > 1 MB/s; warmup 3 s; sustained 10 s | ✅ ²🔧✓ **shipped v0.26.0** | **Tuned in v0.26.0**: `gcRateThresholdPerMin` default 30 → 60. Dart's `EventStreams.kGC` emits one event per young-gen scavenge so a moderately allocating UI sits at ~30/min at steady state (5 events / 10 s sliding window × 6 = per-min extrapolation); the prior default fired on routine animation rebuilds. Apps wanting the older sensitivity opt back in via `SleuthConfig(gcRateThresholdPerMin: 30)`. See §7 M3. |
| 16 | NetworkMonitorDetector | slow = 1 000 ms, crit = 3 000 ms; 30 req/5 s; large = 1 MB; dup ≥ 3 / 500 ms | ✅ ²🔧✓ **shipped v0.15.4** | 2 000 ms "slow" was 2–10× more lenient than mobile-API industry guidance (300–1 000 ms). **Tuned in v0.15.4**: slow 2000 → 1000 ms, critical 5000 → 3000 ms, symmetric `criticalSlowThresholdMs` constructor parameter + `SleuthConfig.criticalSlowRequestThresholdMs` field with strictly-greater assert. See §7 M3. |
| 17 | SetStateScopeDetector | dirty ratio > 0.5 of tree; min subtree 50 | ✅ ²⬇ | **Pass 2 downgraded from 🔍 → ✅.** Far more sophisticated than threshold-only review captured: framework filter, animation-scope filter, const-element discount, 5 s rebuild-evidence window, minSubtreeSize=50. The 0.5 ratio is well-defended in the gauntlet. |
| 18 | PlatformChannelDetector | > 20 calls/s; > 8 ms cumulative/s | ✅ | The 8 ms = 60 FPS frame budget anchor is well-reasoned; 20/s is defensible. |
| 19 | GlobalKeyDetector | > 20 keys in scrollable; churn ≥ 5 | ✅ | Conservative; matches "GlobalKey is expensive, use sparingly" guidance. |
| 20 | RebuildDetector | > 10/s warn, 3× crit; builder ×3 multiplier | 🔧 ²✅held + correction | **Pass 2 confirmed builder filter exists** (`_builderWidgetTypes` set, line 45-56: 6 entries with 3× threshold). Gap remains: non-builder animation Stateful widgets (`CircularProgressIndicator`, `RotationTransition`) are not exempt and DO fire at 10/sec. |
| 21 | ImageMemoryDetector | skip ≤ 50×50; count > 5 crit | 🔧 ²⬆ | **Pass 2 upgraded from 🔍 → 🔧.** Confirmed: detector measures presence-of-`ResizeImage`, not display-vs-source ratio. False positives on perfectly-sized network images. Measurement-semantics fix, not a threshold tune. |
| 22 | StartupDetector | TTFF warn 1 500 ms, crit 3 000 ms | ✅ | Slightly stricter than Android Vitals TTID/TTFD (2 s / 4 s); defensible. |
| 23 | AnimatedBuilderDetector | minSubtreeSize = 50; `abRate > 30/s` (confidence) | ✅ | Arbitrary-but-defensible "large subtree" floor. |

---

## 2. Cross-cutting concerns (apply to multiple detectors)

These themes recurred across detectors and deserve attention before any single-detector tune.

### C1. Frame-count warmup vs duration warmup
**Affected:** FrameTimingDetector; indirectly any "wait N ticks before firing" detector.
**Claim:** `frameTimingWarmupFrameCount = 180`, inline rationale "~3 s at 60 FPS."
**Reality:** On a 120 Hz device (dominant on flagships per 2025–2026 research), 180 frames = **1.5 s**, not 3. That is BELOW Android Vitals' TTID target (<2 s). The package will evaluate frames that are still part of the startup warm-up and misattribute startup jank.
**Evidence strength:** Strong. This is a straight unit-of-measure bug.
**Recommendation:** Make warmup duration-based (`Duration(seconds: 3)`) or derive frames-per-warmup from `fpsTarget` live. `StartupDetector`'s TTFF thresholds are already duration-based — consistency argues for the same treatment here.

### C2. Thresholds hard-coded to 60 FPS assumption
**Affected:** HeavyComputeDetector (8 ms), RepaintDetector (30/s), RebuildDetector (10/s), CustomPainterDetector (30/s), AnimatedBuilderDetector (30/s).
**Reality:** On 120 Hz hardware the same widget painting "30/s" is now **one paint every 4 frames** — substantially quieter, relative to the budget, than at 60 Hz. Rate-based gates that don't scale with `fpsTarget` will either over-fire on 60 FPS apps OR under-fire on 120 Hz apps depending on which target the author calibrated against.
**Recommendation:** Consider `rateThresholdForFps()` helper that expresses thresholds as a fraction of `fpsTarget` (e.g. "≥ 50 % of frames contain a paint for this type"). Will not immediately "fix" these detectors but removes the silent miscalibration.

### C3. Impeller-era recalibration
**Affected:** GpuPressureDetector (raster/UI ratio), ShaderJankDetector (whole detector), FrameTimingDetector (raster cache thrashing/growth windows).
**Claim:** raster > 2× UI = GPU-bound.
**Reality per 2026 sources:** Impeller's raster-thread profile is shaped very differently from Skia — faster in the common case, but spikes on some code paths (complex blurs, first paint). The 2.0× Skia-era ratio may be calibrated against the wrong renderer. CLAUDE.md already records one Impeller-related fix (`ShaderJankDetector Impeller notice removed`), so the package is aware of the shift, but the raster-ratio threshold was not re-validated.
**Recommendation:** Collect raster/UI traces on Impeller-only devices before tuning; the number is unsafe to change without data, but unsafe to trust unchanged.

### C4. Rate-based detectors without "is this widget an intentional animation?" filter
**Affected:** RepaintDetector, RebuildDetector, CustomPainterDetector, possibly AnimatedBuilderDetector.
**Question:** A `CircularProgressIndicator` legitimately paints at `fpsTarget` frequency. A `Ticker`-driven game loop legitimately rebuilds every frame. Do these detectors exempt that case?
**Evidence:** Grep for `Ticker`/`AnimationController`/`Animated*`/`TransitionBuilder` ancestor filters would answer this; I did not find such a filter in the threshold inventory. If a `CircularProgressIndicator` in the app's top bar is firing "repaint rate 60/s" every session, users will disable the detector or dismiss Sleuth entirely — that is the worst kind of false positive: the one that erodes trust in ALL detectors.
**Recommendation:** Highest-priority "investigate before tune" item. If the ancestor filter exists, I missed it — confirm from source. If it doesn't, adding one is more valuable than any threshold change.

### C5. "2× threshold = critical" as a universal pattern
**Affected:** Nearly every detector uses `threshold`, `2 * threshold`, `3 * threshold` as the warning / critical / escalated-critical ladder.
**Critique:** Severity should reflect cost and confidence, not arithmetic doubling. Jank at 17 ms (warning) vs 34 ms (critical) is physically different — a missed frame vs a visibly dropped one. But "1.5 MB/s native growth" vs "2 MB/s" is a factor-of-2 in count, not in user impact. The pattern is convenient, not justified.
**Recommendation:** Low priority — the convention is fine for most cases — but flag in the spec as an area where individual detectors may deviate.

---

## 3. Per-detector analyses (detail)

Below are the detectors whose thresholds survived less well on scrutiny, with the reasoning in full. Detectors not listed here earned a ✅ in §1.

### FrameTimingDetector — 🔧 TUNE (warmup)
**Current:** `warningThresholdMs = 1000/fpsTarget`, `criticalThresholdMs = 2 * warning`, `warmupFrameCount = 180`, `jankPercent > 15`, `severeCount >= 3 in last 60 frames`, `thrashingWindowFrames = 15`, `growthWindowFrames = 30`.
**Leading hypothesis:** warmup must be duration, not frame count (C1). Other thresholds are defensible.
**Evidence (strong):** Frame-count warmup at 120 Hz is 1.5 s, below TTID target.
**Evidence (medium):** `jankPercent > 15` is stricter than Android Vitals "excessive slow frames" (typically 25 %); this is the conservative direction, so fine.
**Evidence (weak):** `severeCount >= 3 in last 60 frames` has no citation; can fire on a single bad GC event surrounded by smooth frames.
**Falsification test:** Run a synthetic 120 Hz profile trace with 2.5 s of startup jank, then a smooth section. Prediction: current detector suppresses the startup jank correctly; after tuning warmup to frame-count it fails to suppress. Haven't run — requires the test harness.
**Verdict: TUNE** — switch warmup to Duration (or `fpsTarget`-derived), revisit `severeCount ≥ 3 in 60` with a rationale comment.

### ListviewDetector / NestedScrollDetector — 🔧 TUNE (child threshold)
**Current:** `childThreshold = 50`, escalated at 100, 150.
**Leading hypothesis:** Threshold is **2.5× more lenient than official Flutter guidance**.
**Evidence (strong consistency):** Flutter docs + multiple 2025 performance guides all cite **20+ items** as the point where non-lazy lists stop being acceptable. 50 is well past that.
**Evidence against:** Lowering the threshold will increase warning noise on legacy codebases. Some `Column` with 30 small text rows is not actually a performance bug.
**Discriminating question:** Is the goal to surface "structural anti-pattern" (then 20 is right) or "observable scrolling jank risk" (then 50 might be defensible)? The detector's `fixHint` language will decide which semantics are correct.
**Verdict: TUNE to ~25**, escalate to 50 / 100 — or split into a "soft warning" at 20 and "critical" at 50. Keeping at 50 is the silent-miscalibration option.

### ShallowRebuildRiskDetector — 🔧 TUNE (depth)
**Current:** `depthThreshold = 3`.
**Leading hypothesis:** False-positive against `MaterialApp → Navigator → Home` stack.
**Evidence (strong):** Flutter's standard root stack puts the first user-authored StatefulWidget at depth 3–5 after `MaterialApp`, `Overlay`, `Navigator`, `Focus`, `Semantics`, etc. Depth 3 is inside that framework shell.
**Evidence against:** CLAUDE.md notes "stateful_density false positive from Sleuth overlay widgets (8 names added to `_frameworkWidgetNames`)" — so there IS a framework-name filter at play; this detector may already exempt them. Need to verify.
**Falsification test:** Grep `shallow_rebuild_risk_detector.dart` for `_frameworkWidgetNames` or ancestor-name filters.
**Verdict: INVESTIGATE** before tuning; if the framework filter already covers it, KEEP.

### HeavyComputeDetector — 🔧 TUNE (scale with fpsTarget)
**Current:** `lagThresholdMs = 8`, critical = 16.
**Leading hypothesis:** 8 ms is the 120 Hz frame budget, not a safe "you're blocking the thread" signal for 60 FPS apps.
**Evidence (strong):** At 60 FPS, a single frame takes 16.67 ms; an 8 ms UI-thread gap is NORMAL behaviour (half a frame). Flagging it as "heavy compute" would fire on every frame.
**Counter-evidence:** The detector may look for gaps BETWEEN frame work, not during. If the 8 ms is non-rendering dead time (Isolate stalls, synchronous I/O), the threshold is fine regardless of fpsTarget.
**Falsification test:** Open `heavy_compute_detector.dart` and confirm whether `ms > lagThreshold` is applied to inter-frame gaps or intra-frame work.
**Verdict: TUNE** to `max(8, 1000/fpsTarget / 2)` OR confirm the gap semantics and document the rationale inline. CLAUDE.md notes v0.8.1 shipped a "HeavyCompute two-tier fix" (v7.1), so the author is aware of the complexity.

### NetworkMonitorDetector — 🔧 TUNE (slow threshold) — ✓ shipped v0.15.4
**Current (v0.15.4+):** `slowThresholdMs = 1000`, `criticalSlowThresholdMs = 3000` (both configurable).
**Pre-v0.15.4:** `slowThresholdMs = 2000`, `_criticalSlowThresholdMs = 5000` (hardcoded constant).
**Leading hypothesis:** 2 s was **2–10× more lenient than current mobile-API guidance**.
**Evidence (strong):** 2026 mobile API guidance:
- Ideal: 100–300 ms
- Acceptable: 500–800 ms for aggregated endpoints
- Noticeable slowdown: 1 s
- "Slow" by every cited source: >1 s
- "Very slow" (what the old 2 s threshold was actually catching): >2 s
- Business-impact citations: 100 ms latency = 1 % conversion drop
**Counter-evidence:** Sleuth is a diagnostic tool for developers, not a UX alarm for users. 2 s may be intentionally tuned to "this is VERY clearly a bug" rather than "this could be faster." That's a legitimate stance.
**Recommendation:** At minimum, relabel or split — "slow" at 1 s, "very slow" / critical at 2 s, keep 5 s as the critical-critical escalator.
**Verdict: TUNE** — change warning to 1 000 ms, critical to 3 000 ms, and rename the 5 s gate to a new tier OR keep the old names but document the position on the slowness spectrum.
**Shipped v0.15.4 (Option B, symmetric configurability):** slow 2000 → 1000 ms, critical 5000 → 3000 ms, both via constructor parameters and `SleuthConfig` fields. A debug-mode `assert(criticalSlowThresholdMs > slowThresholdMs)` fires from both constructors (including `copyWith`) so an unreachable critical tier is impossible. Non-breaking patch bump: both additions are optional parameters with defaults; the audit's counter-evidence stance ("2 s is intentional, this is VERY clearly a bug") is still expressible via `SleuthConfig(slowRequestThresholdMs: 2000, criticalSlowRequestThresholdMs: 5000)`. See CHANGELOG 0.15.4 and §7 M3.

### MemoryPressureDetector — ✓ resolved v0.26.0 (GC-rate semantics)
**Current default:** `gcPerMinute > 60` fires an issue, `_gcWindowDuration = Duration(seconds: 10)`. Configurable via `SleuthConfig.gcRateThresholdPerMin` (escape valve to the pre-v0.26.0 30/min sensitivity).
**v0.26.0 resolution:** `EventStreams.kGC` confirmed to emit one event per completed GC cycle (includes new-space scavenges AND old-space). Dart's young-gen scavenge baseline on a moderately-allocating UI sits at ~30/min at steady state — the prior 30/min default was firing on routine animation rebuilds and incremental scrolling. Threshold doubled to 60/min as the new default; legacy 30/min remains opt-in for apps that want the older sensitivity.

### SetStateScopeDetector — 🔍 INVESTIGATE (dirty ratio)
**Current:** `dirtyRatioThreshold = 0.5`.
**Leading hypothesis:** 50 % of tree owned by one State is ENORMOUS — likely too lenient.
**Evidence (strong against current value):** Flutter's own guidance: "ideally, a stateful widget would create a single widget, and that widget would be a RenderObjectWidget." The detector fires at 50× that ideal.
**Counter-evidence:** A threshold of 30 % or 25 % will probably catch most real offenders — but also many legitimate layouts like a top-level `Scaffold` that owns the majority of the tree anyway.
**Discriminating test:** Tab-shell case. In `IndexedStack` apps, the tab shell StatefulWidget genuinely owns ~100 % of visible tree. 50 % protects against that by the narrowest margin.
**Verdict: INVESTIGATE** — does the detector already exempt the routeScaffold / tab-shell case (CLAUDE.md v0.14.1 adds per-tab session tracking, which suggests yes)? Confirm before dropping the ratio.

### ImageMemoryDetector — 🔍 INVESTIGATE (measurement semantics)
**Current:** `_smallImageThreshold = 50.0`, `count > 5` critical.
**Leading hypothesis:** The detector flags "no `cacheWidth`/`cacheHeight`" but that is only a PROXY for the real problem, which is **decode size vs display size ratio**.
**Evidence (strong):** Flutter docs' canonical memory example — a 4K image rendered at 384×216 uses 100× more memory than with cacheWidth set. The waste ratio is what matters. A 500×500 image with no cacheWidth rendered at 500×500 is not a bug.
**Counter-evidence:** Measuring the actual decode-vs-display ratio requires access to `ImageInfo`, which may not be available from the element tree alone.
**Verdict: INVESTIGATE** — this is a correctness question, not a threshold tune. The current "no cacheWidth = bug" rule is too structural; the real signal is ratio-based.

---

## 4. Detectors that survived scrutiny (why they're ✅)

- **StartupDetector (TTFF 1500/3000 ms):** Android Vitals TTID <2000 ms, TTFD <4000 ms. Detector is slightly stricter, fully defensible.
- **FontLoadingDetector (3 families):** Exact match with Flutter 2025 guidance.
- **KeepAliveDetector (5/10):** Aligns with memory-overhead rule-of-thumb; no source contradicts.
- **LayoutBottleneckDetector (Wrap > 30, nested intrinsic escalation):** Correctly anchors on the O(N²) IntrinsicHeight guidance from Flutter's official API docs.
- **PlatformChannelDetector (20 calls/s, 8 ms cum.):** 8 ms anchors on the 60 FPS frame budget with explicit purpose; 20/s is a reasonable high bar.
- **GlobalKeyDetector (20, 60 crit):** GlobalKey is "use sparingly" per Flutter docs; numeric floors are defensible.
- **OpacityDetector (exact 0.0):** Narrow structural rule; engine's 0.0 short-circuit justifies the narrow scope.
- **AnimatedBuilderDetector (minSubtree 50):** Arbitrary floor but consistent with "large subtree" intent in Flutter docs.

---

## 5. Top 5 action items (ranked by leverage) — pass-2 revised

The pass-1 list ranked five thresholds. Pass 2 verified them against detector source and rewrote the order. Demoted: ListviewDetector child threshold (only catches eager construction, not `.builder()` — lower impact than thought). Promoted: RepaintDetector animation filter (the only finding with a concrete named false-positive case).

1. **RepaintDetector: add animation/builder filter.** ✓ **Shipped v0.15.3.** Source confirmed `repaint_detector.dart` had zero animation-aware filter; any widget at ≥ 30 paints/sec fired `excessive_repaint`. A `CircularProgressIndicator` rotating at 60 Hz in an app's top bar triggered on every session. **Fix as shipped:** three-leg ownership check (chain-string regex → typed ancestor walk → typed descendant walk) against a canonical 21-entry owner set in `lib/src/utils/animation_owner_names.dart`, enforced via per-paint attribution at `_handleProfilePaint` so polymorphic-key collisions (`CustomPaint` inside `AnimatedBuilder` vs setState-driven) don't cause blanket suppression or blanket firing. See CHANGELOG 0.15.3. *(§7 M1)*
2. **FrameTimingDetector warmup → Duration-based.** Silent miscalibration on every 120 Hz device — `frame_timing_detector.dart:49` hardcoded `180; // ~3s at 60fps` = 1.5 s on 120 Hz. Switch to `Duration(seconds: 3)` or derive frames-per-warmup from `fpsTarget` live. *(§2 C1)*
3. **NetworkMonitorDetector slow → 1 000 ms / critical → 3 000 ms.** ✓ **Shipped v0.15.4.** Was confirmed at `network_monitor_detector.dart:24,49`. The 2 s value was wildly more lenient than every 2025–2026 source. **Fix as shipped:** Option B symmetric configurability — `slowThresholdMs` default 2000 → 1000, new `criticalSlowThresholdMs` constructor parameter (promoted from hardcoded `_criticalSlowThresholdMs = 5000`) default 3000, matching `SleuthConfig.slowRequestThresholdMs` and new `SleuthConfig.criticalSlowRequestThresholdMs` fields, with a debug-mode `assert(critical > slow)` on both constructors. Non-breaking patch bump. See CHANGELOG 0.15.4. *(Detector 16, §7 M3)*
4. **ImageMemoryDetector: switch from "presence of ResizeImage" to "display-vs-source ratio".** Pass-2 source-read confirmed this is a measurement-semantics gap, not a threshold tune. Detector flags any `Image` not wrapped in `ResizeImage` and ≤ 50×50, which produces false positives on perfectly-sized network images. Requires `ImageStreamListener` to access `ImageInfo.image.width/height` and compare to render-object size. Higher implementation cost — defer if the false-positive rate isn't reported by users. *(Detector 21)*
5. **HeavyComputeDetector → scale with `fpsTarget`** (right answer, corrected reasoning). The threshold gates **build phase duration**, not inter-frame gap. At 60 Hz an 8 ms build phase consumes half the budget (defensible warning); at 120 Hz it consumes the entire budget (under-fires as warning). Fix: `lagThresholdMs = max(8, (1000 ~/ fpsTarget) ~/ 2)` — 8 ms at 60 Hz, 4 ms at 120 Hz. *(Detector 9, §2 C2)*

**Demoted from pass 1's top 5:**
- *ListviewDetector child threshold → 25*: still defensible but lower-impact than originally claimed, because the detector only catches eager `children: [...]` construction, not `.builder()`. Modern code largely sidesteps it. Demote to "nice-to-have."
- *Confirm rate-based detectors exempt animations*: split into the concrete RepaintDetector fix above (M1). RebuildDetector's filter already exists; CustomPainterDetector doesn't need one (its primary path is structural, not rate-based).

**Newly added (from §7):**
- **MemoryPressureDetector GC threshold**: ✓ **Shipped v0.26.0** — `gcRateThresholdPerMin` default raised from 30 → 60. Dart's young-gen scavenge baseline (~30/min on a moderately-allocating UI) was firing on routine animation rebuilds. Filtering kGC to old-space-only was the alternate fix; threshold tune chosen because it stays observable to apps that want the older sensitivity (`SleuthConfig(gcRateThresholdPerMin: 30)`).

None of these are architectural. They can be bundled into a `v0.15.3` or `v0.16.x` tuning pass.

---

## 6. Self-critique

- **Hypothesis completeness:** ✅ — three+ competing readings considered for every detector flagged 🔧/🔍.
- **Evidence audit:** ⚠ partial — I classified "strong consistency" vs "weak" in the top items, but not all 23. The top-5 action items have the strongest evidence; the remaining ✅ verdicts are more "no evidence against" than "strong evidence for."
- **Falsification discipline:** ⚠ weak — I named predictions for most tune recommendations but did not RUN them (no test harness invoked). Every "TUNE" recommendation is `Likely`, not `Confirmed`.
- **Search bias:** I searched the open web, Flutter docs, and Android Vitals. I did not search internal Flutter engine benchmarks, Google Play internal data, or competing performance packages like `flutter_lints` / `dart_code_metrics`. Any of those might contradict an industry best-practice value.
- **Layer coverage:** I walked from detector source → threshold → industry guidance. I did NOT verify what the detector actually DOES with each threshold — some thresholds are confidence gates, not firing gates, and my analysis may have mis-ranked the severity of a few items.
- **Reproducer check:** None. No threshold recommendation below has been validated against a failing → passing reproduction. Every verdict is "likely correct based on documentation," not "measured."
- **Report fidelity:** The user asked for "proper thresholds" per internet best practice. I interpreted that as "audit the current thresholds against documented best practices and flag the ones that appear miscalibrated." If the intent was "give me the single correct value for each threshold," that's a stricter goal this report does not fully satisfy — many detectors have no documented-canonical number (rebuilds/sec, subtree size, etc.) and the best I can say is "the current value is arbitrary but defensible."

**Overall verdict confidence:** The top-5 action items are `Likely` (strong documentary evidence). The remaining 🔧/🔍 calls are `Unverified` (plausible but need source-reading or a reproducer to confirm). No 🔧 call is yet at `Confirmed`.

---

## 7. Pass-2 source verification (2026-04-15 grill mode)

Pass 1 was a documentation cross-reference. Pass 2 read the detector source for every claim that could be verified, applying Tactic 12 (investigate before deferring) to the `INVESTIGATE` items pass 1 left open. Mode: grill — the audit was the hypothesis under test.

### 7.1 Verdict regrade summary

| Pass-1 verdict | Detector | Pass-2 regrade | Source evidence |
|---|---|---|---|
| 🔧 TUNE warmup | FrameTimingDetector | ✅ holds | `frame_timing_detector.dart:49` — `_defaultWarmupFrameCount = 180; // ~3s at 60fps`. Unit-of-measure bug exactly as claimed. |
| 🔍 INVESTIGATE | RepaintDetector | ⬆ **TUNE (stronger)** | `repaint_detector.dart:24-303` has zero animation/Ticker/builder filter. Whole gate is `paintsPerSecond >= 30`. The `_evaluateDebugDataPerWidget` path (line 266) iterates every type in `snapshot.paintCounts` with no exemption. Pass-1 worry confirmed without mitigation. |
| 🔧 TUNE | RebuildDetector | 🔧 hold + correction | `rebuild_detector.dart:45-56` — `_builderWidgetTypes = {StreamBuilder, FutureBuilder, ValueListenableBuilder, AnimatedBuilder, ListenableBuilder, TweenAnimationBuilder, StreamBuilderBase}` with `_builderThresholdMultiplier = 3`. Pass 1 failed to credit this. Remaining gap: animation StatefulWidgets like `CircularProgressIndicator` and `RotationTransition` are NOT in the set and DO trigger at 10/sec. |
| 🔧 TUNE child | ListviewDetector | 🔧 hold + scope | `listview_detector.dart:103-104,144` — confirmed `childThreshold = 50` and `>` comparison. **But:** detector only matches `SliverChildListDelegate` (the eager `children:[...]` form). `SliverChildBuilderDelegate` (the lazy `builder:` form) is exempt. Modern code largely sidesteps this detector. |
| 🔧 TUNE depth | ShallowRebuildRiskDetector | ⬇ **KEEP (✅)** | `shallow_rebuild_risk_detector.dart:91-105` — framework filter with 13 entries: `Scaffold, CupertinoPageScaffold, ScaffoldMessenger, AppBar, Material, AnimatedTheme, ScrollConfiguration, ScrollNotificationObserver, _ModalScope, Navigator, Overlay, FocusScope, FocusTraversalGroup`. Pass 1 said "if framework filter exists, KEEP" — it does. |
| 🔧 TUNE | HeavyComputeDetector | 🔧 hold + reasoning fix | `heavy_compute_detector.dart:38-61` — threshold is applied to `event.durationUs / 1000` of build phase events, NOT inter-frame gap. Pass-1 stated reasoning ("8 ms is normal half-frame at 60 FPS") is wrong. Right reasoning: at 60 Hz an 8 ms BUILD scope consumes half the frame budget (defensible warning); at 120 Hz it consumes 100% of budget (under-fires as warning). Recommendation survives, rationale fixed. |
| 🔧 TUNE | NetworkMonitorDetector | ✅ holds → ✓ shipped v0.15.4 | `network_monitor_detector.dart:24,49` — was `slowThresholdMs = 2000`, `_criticalSlowThresholdMs = 5000`. Industry guidance unanimous. **Shipped as Option B** (symmetric configurability): new defaults 1000/3000, new `criticalSlowThresholdMs` constructor parameter + `SleuthConfig.criticalSlowRequestThresholdMs` field, strictly-greater assert on both constructors. |
| 🔍 INVESTIGATE | MemoryPressureDetector GC rate | ✓ shipped v0.26.0 | `memory_pressure_detector.dart` — `gcPerMinute = (windowEvents / 10s) * 60`. `EventStreams.kGC` "exactly one event per completed GC cycle" (includes new-space scavenges AND old-space). **Shipped:** default `gcRateThresholdPerMin` raised 30 → 60. Apps wanting the older sensitivity opt back in via `SleuthConfig(gcRateThresholdPerMin: 30)`. Filtering kGC to old-space-only was the alternate fix; threshold tune chosen because it stays observable to apps. |
| 🔍 INVESTIGATE | SetStateScopeDetector | ⬇ **KEEP (✅)** | `setstate_scope_detector.dart:152-319` — framework filter (`isFrameworkWidget`), animation-scope filter (`_containsAnimationScope`), const-element discount (`mutableSubtreeSize = subtreeSize − stableCount`), 5-second rebuild-evidence window (`_evidenceWindowSeconds = 5`), `minSubtreeSize = 50` floor, distinct paths for `hasRebuildEvidence` vs `!hasRebuildEvidence + !hasAnimScope`. The 0.5 ratio is well-defended in the gauntlet. |
| 🔍 INVESTIGATE | CustomPainterDetector | ⬇ **KEEP (✅) + audit refuted** | `custom_painter_detector.dart:66-93` — primary check is **structural**: `painter.shouldRepaint(painter)` (self-test). Detector fires regardless of paint rate; the rate is only a confidence escalator (line 104-110: `cpRate > 10` upgrades possible→likely), not a firing gate. Pass 1's worry "may miss low-rate `shouldRepaint → true` painters" is **inverted** — the detector catches every self-true painter regardless of rate. The 30/sec rate is the gate for the SECONDARY heuristic catching painters that pass self-comparison but rebuild via different instances. |
| 🔍 INVESTIGATE | ImageMemoryDetector | ⬆ **TUNE** | `image_memory_detector.dart:74-87` — confirmed: detector flags any `Image` not wrapped in `ResizeImage` (and not ≤ 50×50). Does NOT measure decode-size vs display-size ratio. **False positives**: a 100×100 NetworkImage displayed at 100×100; AssetImage of an icon ≤ 50×50 displayed at 60×60 (just over the suppress threshold). **True positives missed**: an Image wrapped in ResizeImage at the wrong size is silently OK. Measurement-semantics gap, not a threshold tune. |

### 7.2 Findings pass 1 missed

#### M1. Asymmetric animation filter — Repaint vs Rebuild ✅ **SHIPPED v0.15.3 (2026-04-15)**

Pass 1 grouped RepaintDetector and RebuildDetector under one "C4 missing animation filter" theme. The source shows they are not equivalent:

- **RebuildDetector** has a `_builderWidgetTypes` set (6 entries) with a 3× threshold multiplier. So `AnimatedBuilder` ticking at 60/sec only fires above 30/sec, not 10/sec.
- **RepaintDetector** has **zero filter**. Any widget type at 30+ paints/sec fires.

The practical false-positive surface is therefore much larger on the Repaint side, AND it's blind to the same widgets that RebuildDetector partially exempts. A `CircularProgressIndicator` rotating at 60 Hz in an app's top bar would trigger `excessive_repaint` (and `repaint_debug_CircularProgressIndicator`) on every session, on every page that mounts it.

**Fix:** Either share the `_builderWidgetTypes` set across both detectors, OR add an ancestor-walk filter that suppresses widgets whose State is driven by a `Ticker` / `AnimationController`. The former is one constant-set extraction; the latter is more correct but more expensive.

**Resolution (v0.15.3):** Chain-containment filter (the second option above, refined). `RepaintDetector` now owns a 7-entry `animationOwnerNames` set (4 Material/Cupertino indicators + 3 generic builder patterns) and a `_animationOwnerRegex` with `\b…\b` word boundaries. The set is intentionally smaller than RebuildDetector's `_builderWidgetTypes`: `widget_location.dart`'s framework strip removes most candidate transitions before they ever reach the chain, so adding them would be dead code (KDD-2). Three gates apply the filter:

- **Gate A (per-widget debug, `_evaluateDebugDataPerWidget`):** skip when the cached ancestor chain for `typeName` matches `_animationOwnerRegex`. Default-fire when chain is missing — never silently mask a real bug.
- **Gate B (VM aggregate fallback, `_evaluateVmData` wrapper):** suppress entirely when **every** non-zero entry in `paintCounts` is animation-owned. Empty `paintCounts` = no signal = let the gate fire normally.
- **Gate C (debug aggregate, `_evaluateDebugData`):** subtract owned paint counts from `totalPaintCount`, recompute `residualRate` over `elapsed`, suppress when residual falls below threshold; surface "Excludes N animation-owned paints" suffix on the issue detail when residual still fires.

**Asymmetry vs RebuildDetector (KDD-4) is deliberate**: full exemption (RepaintDetector) vs 3× multiplier (RebuildDetector). A `CircularProgressIndicator` is *supposed* to paint at the device refresh rate — there is no rate that's "too high" for it; the right answer is "don't fire at all." A high *rebuild* rate on the same widget is more ambiguous (could be a parent re-mounting it 60×/sec by mistake), so a multiplier rather than full exemption.

**Test coverage:** 10 hand-rolled fixture tests in `test/detectors/repaint_detector_test.dart` exercise gate algebra against synthetic chains. ONE real-widget anti-tautology test in `test/detectors/repaint_animation_filter_real_widget_test.dart` pumps an actual `CircularProgressIndicator` through `DebugInstrumentationCoordinator`, asserts captured chains contain `'CircularProgressIndicator'`, then re-pins `elapsed: 100ms` to push per-widget rates to ~100/sec (well over the 30/sec threshold) so Gate A is exercised — not just Gate C suppression. The real-widget test exists specifically because hand-rolled fixtures would encode whatever chain format the test author *thinks* the coordinator produces, so they cannot catch a bug where the filter relies on a chain key/string format the coordinator never emits in practice.

**Hardening pass against the v0.15.3 ship (C1–C5):** five
critical findings landed against the original v0.15.3 ship. All five
shared an architectural root cause: ownership decisions were made by
inspecting a cached chain-string keyed on `runtimeType`, but the chain
string is purpose-built for *human source-location display* and is too
shallow, too lossy, and too key-collision-prone for a robust ownership
filter. The fix moves ownership detection off the chain string entirely
and onto a per-paint, typed walk that runs at paint-callback time
against the live `Element`.

- **C1 (polymorphic-key collision):** the coordinator caches the chain
  on first occurrence per `typeName` key. Pre-fix, two `CustomPaint`
  widgets sharing the key — one inside `AnimatedBuilder`, one driven
  by external `setState` — were either both fully suppressed or both
  fully fired. **Fix:** per-paint owned attribution at
  `_handleProfilePaint` calls `isAnimationOwnedPaint(element, chain)`
  against the live `Element`. Results are exposed via two new
  `DebugSnapshot` fields (`animationOwnedPaintCounts`,
  `totalAnimationOwnedPaintCount`) that the detector reads instead of
  re-deriving ownership from the chain string. Mixed ownership for
  the same `typeName` key is now represented honestly. KDD-6 is
  superseded — polymorphic-key collision is no longer a known
  limitation.

- **C2 (insufficient owner set):** the original 7 entries missed the
  entire `Animated*` family (12 widgets) plus `Hero` and
  `RefreshIndicator`. Each runs an internal `AnimationController` to
  tween between old and new property values; without these entries
  every implicit animation triggers a false `repaint_debug_*`.
  **Fix:** expanded to 21 entries and moved the canonical Set out of
  `RepaintDetector` into shared
  `lib/src/utils/animation_owner_names.dart` so the coordinator and
  the detector reference the same source of truth.

- **C3 (chain-walks-up gap):** when a `CircularProgressIndicator` is
  mounted *without* a wrapping `RepaintBoundary`, the dirty mark
  propagates UP to the nearest layer-owning ancestor (commonly
  `Center` or `Stack`). The captured chain walks UP from the
  ancestor, so `CircularProgressIndicator` is a *descendant* of the
  leaf — chain-containment misses it entirely. **Fix:**
  `isAnimationOwnedPaint` adds a bounded-depth descendant walk
  (`hasAnimationOwnerDescendant`, `maxVisits=32`, `maxDepth=4`) over
  the leaf's children with typed runtimeType match.

- **C4 (chain capture exception safety):** during widget deactivation,
  `element.visitAncestorElements` can throw "Looking up a deactivated
  widget's ancestor is unsafe." Pre-fix, the exception unwound
  through `_handleProfilePaint` and crashed the entire instrumentation
  pipeline. **Fix:** wrapped the chain capture in try/catch in
  `debug_instrumentation_coordinator.dart`. Detected paint counting
  continues; only the chain enrichment is skipped for that single
  event.

- **C5 (test fixture tautology):** the original v0.15.3 only had a
  real-widget test for `CircularProgressIndicator`; the other 6 owners
  + C1/C3 cases were covered only by hand-rolled fixtures that
  mirrored the filter's own assumptions. **Fix:** new
  `test/detectors/repaint_animation_owners_real_widget_test.dart`
  adds 8 real-widget tests (LinearProgressIndicator,
  RefreshProgressIndicator, TweenAnimationBuilder, AnimatedBuilder,
  ValueListenableBuilder, AnimatedContainer, C1 mixed-ownership scene,
  C3 bare-CPI-without-RepaintBoundary scene). The TweenAnimationBuilder
  and ValueListenableBuilder tests immediately caught a real
  generic-stripping bug in `hasAnimationOwnerDescendant` —
  `'TweenAnimationBuilder<double>'` was being looked up against a Set
  containing `'TweenAnimationBuilder'`, exactly the class of bug the
  real-widget tests exist to catch.

**Architectural follow-ups discovered during C5:**

- **Generic-stripping fix in `hasAnimationOwnerDescendant`:** the
  walk now strips `Foo<X>` to `Foo` via a single `indexOf('<')`
  before the Set membership test. Non-generic types pass through
  unchanged with zero allocation.

- **New `hasAnimationOwnerAncestor` walk:** `RefreshProgressIndicator`
  exposed a third gap. Its painted leaf (`CustomPaint`) sits ~13
  ancestors below the wrapping `AnimatedBuilder` owner because of
  Material's internal `_buildMaterialIndicator` decoration stack
  (`Padding > SizedBox > _SemanticsWrapper > NotificationListener >
  Material > Padding > Opacity > Transform > CustomPaint`). The
  chain-string check fails because `buildAncestorChain`'s
  `maxDepth: 6` is deliberately too shallow to stay
  human-readable. The descendant walk fails because the owner is
  *upstream* of the leaf, not downstream. **Fix:**
  `isAnimationOwnedPaint` now has three legs, checked
  cheapest-first: (1) chain-string regex, (2) typed ancestor walk
  (`maxDepth=16`, independent of the chain budget), (3) typed
  descendant walk (`maxVisits=32`, `maxDepth=4`).

**Updated test coverage:** the 10 hand-rolled gate-algebra tests
remain; the existing real-widget CPI test remains; the new
`repaint_animation_owners_real_widget_test.dart` adds 8 owner-coverage
tests; one gate-algebra extension covers the new owned-counts
contract. Test count: 2,146 → 2,166.

Plan: `doc/spec_v0_15_3_repaint_animation_filter.md`. Implementation
spans `lib/src/detectors/repaint_detector.dart`,
`lib/src/utils/animation_owner_names.dart` (new),
`lib/src/debug/debug_instrumentation_coordinator.dart`,
`lib/src/debug/debug_snapshot.dart`.

#### M2. RebuildDetector's framework filter is for `stateful_density` only

`rebuild_detector.dart:456-501` — the `_frameworkWidgetNames` set (49 entries including the 9 Sleuth overlay widgets from v0.13.1 + the v0.15.2 `TweenAnimationBuilder` addition) is consulted ONLY in the structural-only fallback path (`_evaluateStructuralOnly`, line 419), not in the rebuild-rate-attribution path. So at high build activity with a debug snapshot, a rebuild attributed to `Scaffold` would still surface as `rebuild_debug_Scaffold`. The framework filter does not protect the per-type debug-callback path.

#### M3. The `severeCount >= 3 in 60` rule is undocumented but not arbitrary

`frame_timing_detector.dart:191-220` — pass 1 flagged "no citation" for the rule. Reading the code, it's checking whether 5 % of the buffer (3/60) contains severe jank (>33 ms). That's a noise-floor anchored to the buffer size, not to FPS. The convention is defensible but pass 1 was right that there is no inline rationale. Low-priority documentation fix, not a tune.

#### M4. Listview detector childThreshold is reused in three paths

`listview_detector.dart:80, 144` and the `_checkForNonLazyList` helper — the same `childThreshold = 50` is consulted in three separate detection paths (non-lazy ListView/GridView, non-lazy Sliver, SingleChildScrollView+Column). Tuning to 25 affects all three at once. Probably the right move; just be aware that one constant change has a wider blast radius than pass 1 implied.

### 7.3 Self-critique of the meta-investigation

- **Hypothesis completeness:** Partial. I grilled pass-1 verdicts but did not enumerate alternative interpretations of each detector's purpose. For example, `ImageMemoryDetector`'s "no `ResizeImage` wrapper" could be intentionally pessimistic ("we can't measure the real ratio, so flag everything and let the user decide"). I treated the absence of ratio measurement as a bug; it could be a deliberate design constraint. Open question for the package author.
- **Evidence audit:** I read source for 9 of 23 detectors. The other 14 (the audit's ✅ verdicts and items I had no specific reason to doubt) were not re-verified. **Selection bias**: I went where I expected to find audit errors. If a detector pass 1 ✅-confirmed actually has a bug, I would not have caught it.
- **Falsification discipline:** I did not run any falsification tests against the package. All pass-2 regrades are static-source-reading, not "trigger the detector with a synthetic payload and observe." A test like "mount a 100×100 NetworkImage inside a 100×100 SizedBox and grep `_uncachedImages`" would either confirm or refute the ImageMemoryDetector finding. I did not run it.
- **Search bias:** I searched only inside `lib/src/detectors/`. I did NOT check the controller's orchestration, the suppression rules in `SleuthConfig`, or the `IssueRanker` — any of which could weaken or strengthen detector findings before they reach the user. A noisy detector behind a strong suppressor is functionally fine.
- **Layer coverage:** Symptom (audit verdict) → claim (audit reasoning) → ground truth (detector source). Three layers walked. I did NOT walk to the next layer down: how the detector output is consumed by `IssueRanker`, `FloatingIssuesCard`, or the AI chat surface.
- **Reproducer check:** None. Every regrade is "what the source says happens," not "what actually happens at runtime." A device-profile run against a `CircularProgressIndicator` screen would confirm M1 in 30 seconds — I did not run it.
- **Report fidelity:** Pass-1 audit is the symptom; pass-2 regrade is direct verification against cited line numbers. Fidelity is good — every regrade above ties to a specific file:line.

### 7.4 Open questions (genuinely unresolvable from source alone)

1. **Does the IssueRanker suppress `repaint_debug_CircularProgressIndicator` in practice?**
   - **Recommended answer:** Probably not — confidence is `confirmed` from the debug-callback measurement, severity is `warning`. The ranker's weighted-composite score would not meaningfully discount it.
   - **What would change the answer:** Reading `lib/src/ranking/issue_ranker.dart` to see whether widget-name-based suppression exists. Easy to check next pass — deferred to keep this report scoped.

2. **Does the package author intend `ImageMemoryDetector` as a structural lint or a runtime cost gate?**
   - **Recommended answer:** Structural lint, based on the `_smallImageThreshold = 50` suppression — that's a "skip the obviously cheap case" carve-out, not a cost-based decision.
   - **What would change the answer:** Author confirmation, or a comment in the detector explaining intent. Otherwise unreviewable on this dimension.

3. **Is `MemoryPressureDetector.recordGcCycle` actually fed by every kGC stream event, or only old-space cycles?**
   - **Recommended answer:** Every kGC event, including new-space scavenges, per the comment on line 142 ("exactly one event per completed GC cycle"). Dart's `kGC` stream emits both.
   - **What would change the answer:** Reading `controller/sleuth_controller.dart` `_onGcEvent` to see whether it filters by `event.kind` before forwarding. Did not chase in this pass.

---

## 8. Sources

Jank / frame budget / FPS:
- [Flutter performance profiling](https://docs.flutter.dev/perf/ui-performance)
- [Flutter App Performance: Profiling, Fixing Jank, and Optimization Tips (2026)](https://startup-house.com/blog/flutter-app-performance)
- [Flutter performance: how to diagnose jank and FPS drops (2026)](https://chdr.tech/en/2026/03/05/flutter-performance-diagnose-jank-fps/)
- [Use the Performance view (DevTools)](https://docs.flutter.dev/tools/devtools/performance)

Startup (TTFF / TTID / TTFD):
- [App startup time | Android Developers](https://developer.android.com/topic/performance/vitals/launch-time)
- [How to Reduce App Startup Time on Android, iOS & Flutter (2026 guide)](https://www.digia.tech/post/app-startup-time-performance-guide)
- [Load sequence, performance, and memory (Flutter docs)](https://docs.flutter.dev/add-to-app/performance)

Impeller / shaders / GPU pressure:
- [How Impeller Is Transforming Flutter UI Rendering in 2026](https://dev.to/eira-wexford/how-impeller-is-transforming-flutter-ui-rendering-in-2026-3dpd)
- [Impeller rendering engine (Flutter docs)](https://docs.flutter.dev/perf/impeller)
- [Shader compilation jank (Flutter docs)](https://docs.flutter.dev/perf/shader)
- [Mitigate OOM Crashes by Exposing Impeller GPU Memory Stats #178264](https://github.com/flutter/flutter/issues/178264)

RepaintBoundary / rebuilds:
- [RepaintBoundary (Flutter API docs)](https://api.flutter.dev/flutter/widgets/RepaintBoundary-class.html)
- [Flutter 2025 Performance Best Practices: What Has Changed & What Still Works](https://flutterexperts.com/flutter-2025-performance-best-practices-what-has-changed-what-still-works/)
- [Stop Unnecessary Widget Rebuilds in Flutter (2026)](https://medium.com/@developer.hub/stop-unnecessary-widget-rebuilds-in-flutter-d75aef758bbe)

Lists / layout:
- [Performance best practices (Flutter docs)](https://docs.flutter.dev/perf/best-practices)
- [Why ListView Can Hurt Your App's Performance](https://dev.to/bestaoui_aymen/why-listview-can-hurt-your-apps-performance-and-what-to-use-instead-1dbc)
- [IntrinsicHeight (Flutter API docs)](https://api.flutter.dev/flutter/widgets/IntrinsicHeight-class.html)
- [Intrinsic Widget Alternatives for Enhancing Flutter Performance](https://www.logique.co.id/blog/en/2025/03/25/intrinsic-widget-alternatives/)

AnimatedBuilder / Opacity / CustomPainter:
- [AnimatedBuilder (Flutter API docs)](https://api.flutter.dev/flutter/widgets/AnimatedBuilder-class.html)
- [Why do TweenAnimationBuilder and AnimatedBuilder have a child argument?](https://codewithandrea.com/articles/flutter-animated-builder-child-widget-argument/)
- [Opacity (Flutter API docs)](https://api.flutter.dev/flutter/widgets/Opacity-class.html)
- [Optimizing Flutter Apps: Avoid Opacity and Clipping](https://www.logique.co.id/blog/en/2025/04/23/optimizing-flutter-apps/)
- [CustomPainter.shouldRepaint (Flutter API docs)](https://api.flutter.dev/flutter/rendering/CustomPainter/shouldRepaint.html)

Memory / images / GC:
- [Use the Memory view (DevTools)](https://docs.flutter.dev/tools/devtools/memory)
- [How We Reduced Flutter Memory Usage by 375mb: Image Optimization Strategies](https://saropa-contacts.medium.com/how-we-reduced-flutter-memory-usage-by-375mb-image-optimization-strategies-5a097246ee0c)
- [How Dart's Garbage Collector Works](https://medium.com/@punithsuppar7795/how-darts-garbage-collector-works-and-when-it-fails-you-2e0c3c75928d)

Network / API response time:
- [API Response Time Standards: What's Good, Bad, and Unacceptable](https://odown.com/blog/api-response-time-standards/)
- [What's a good API response time? Benchmarks to beat in 2025](https://myfix.it.com/what-s-a-good-api-response-time-benchmarks-to-beat-in-2025/)
- [How to Optimize API Response Times for Mobile Apps](https://technori.com/news/optimize-api-response-times-mobile-apps/)
- [10 REST API Payload Size Best Practices](https://climbtheladder.com/10-rest-api-payload-size-best-practices/)

Platform channels / isolates / GlobalKey / fonts / KeepAlive:
- [Improving Platform Channel Performance in Flutter](https://medium.com/flutter/improving-platform-channel-performance-in-flutter-e5b4e5df04af)
- [Concurrency and isolates (Flutter docs)](https://docs.flutter.dev/perf/isolates)
- [Elements, Keys and Flutter's performance](https://medium.com/flutter-community/elements-keys-and-flutters-performance-3ef15c90f607)
- [Optimizing Font Usage in Flutter for Better Performance and UX](https://medium.com/@balaeon/optimizing-font-usage-in-flutter-for-better-performance-and-ux-a448875ba693)
- [Mastering Flutter List Performance With AutomaticKeepAlive](https://vibe-studio.ai/insights/mastering-flutter-list-performance-with-automatickeepalive)
- [AutomaticKeepAlive (Flutter API docs)](https://api.flutter.dev/flutter/widgets/AutomaticKeepAlive-class.html)
