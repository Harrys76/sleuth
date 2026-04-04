## v7 Roadmap: Performance & Accuracy

### v7.1: HeavyComputeDetector — Two-Tier Severity ✅ Shipped

**Problem:** `HeavyComputeDetector` (line 48) compares `ms > lagThresholdMs * 2` (effective threshold: 16ms when default is 8ms). The severity check at line 74 (`ms >= 16 ? critical : warning`) is dead code — since detection requires `>16`, `>=16` is always true, so every detected issue is `critical`. The `warning` tier is unreachable. Documentation says "8ms gaps" but code triggers at >16ms.

**Fix:** Two-tier detection — warning at `> lagThresholdMs` (>8ms), critical at `> lagThresholdMs * 2` (>16ms). Both threshold and severity become meaningful.

**Files:** `lib/src/detectors/heavy_compute_detector.dart` lines 48, 56, 74, 95.

**Risk:** Low. May surface more warnings for 8–16ms compute gaps. Default thresholds unchanged — just honoring them correctly.

**Post-Implementation Notes:**
- Detection threshold lowered from `> lagThresholdMs * 2` (>16ms) to `> lagThresholdMs` (>8ms)
- Severity now threshold-relative: `ms > lagThresholdMs * 2 ? critical : warning` (not hardcoded to 16)
- Follows ShaderJankDetector convention (detect at 1× threshold, critical at 2× threshold)
- 5 existing tests updated for new threshold, 7 new boundary/warning tests added (24 total)
- No UI or FixHint changes needed — existing severity display handles both tiers generically

---

### v7.2: NetworkMonitorDetector — Inclusive Threshold Comparison ✅ Shipped

**Problem:** `network_monitor_detector.dart` line 139 uses `r.durationMs > slowThresholdMs` (strict greater-than). A request at exactly the threshold (e.g., 2000ms when threshold is 2000ms) is not flagged as slow.

**Fix:** Change `>` to `>=`.

**Files:** `lib/src/detectors/network_monitor_detector.dart` line 139.

**Risk:** None. Off-by-one fix.

**Post-Implementation Notes:**
- Scope expanded from spec's single line (139) to also fix line 178 (`r.responseBytes > largeResponseBytes` → `>=`) for consistency — same off-by-one pattern in large response detection.
- Full audit of all 6 comparison operators in the detector: frequency check (line 219, `<=`) and critical severity check (line 144, `>=`) were already correct — left unchanged.
- Title display strings at lines 164 and 200 left as `>` — human-readable approximation, not formal spec. Changing to `>=` or `≥` would be ugly for negligible accuracy gain.
- 3 new boundary tests added: slow request at exactly 2000ms (warning), critical at exactly 5000ms (critical), large response at exactly 1048576 bytes (warning).
- Total test count: 1,303 (was 1,300).

---

### v7.3: Detector Threshold Tuning Pass ✅ Shipped

**Problem:** Several detector thresholds produce excessive false positives or miss real issues based on code review against typical Flutter app behavior.

**Changes:**

| Detector | Field | Current | New | Rationale |
|----------|-------|---------|-----|-----------|
| AnimatedBuilder | `minSubtreeSize` | 20 (line 16) | 50 | 20 flags small animations; 50+ subtree is genuinely expensive |
| GlobalKey | `threshold` | 10 (line 14) | 20 | 10 is too aggressive — forms, state restoration, and Slivers commonly use 10+ keys |
| RepaintBoundary | `maxAncestorDepth` | 3 (line 19) | 5 | Material widgets naturally add 2–3 render layers; depth 3 catches framework wrapping, not app issues |
| GpuPressure | `rasterMultiplierThreshold` | 1.5 (line 15) | 2.0 | 1.5× raster ratio is normal for charts and animations; 2.0× indicates real GPU pressure |
| FrameTiming | cache thrashing | no minimum count (line 253) | minimum pictureCacheCount > 5 | Variation of 20% on small counts (2→3 = 50%) fires incorrectly |

**Files:** 5 detector files, ~1 line each.

**Risk:** Low. All changes tighten detection (fewer false positives). Default values through `DetectorThresholds` config remain available for consumers who want different sensitivity.

**Post-Implementation Notes:**
- Scope expanded beyond "5 detector files, ~1 line each" — also updated: `detector_thresholds.dart` (2 defaults), `watchdog_controller.dart` (`maxGlobalKeys` 10→20), and 2 hardcoded description strings (GlobalKey ">10"→">20", GpuPressure "1.5"→"2.0").
- `detector_thresholds.dart` doc comment example updated (`gpuPressureRatio: 2.0` → `3.0` with corrected default label).
- FrameTiming cache thrashing: both guards updated (`previous.pictureCacheCount > 0` → `> 5` at line 253, and `latest.pictureCacheCount > 0` → `> 5` at line 262 for zero-to-nonzero jump detection).
- AnimatedBuilder test widget `TestAnimatedApp` increased from `List.generate(25)` to `List.generate(51)` (subtree 52 > 50 threshold).
- RepaintBoundary test increased from depth 4 to depth 6 (beyond new maxAncestorDepth=5).
- GpuPressure: 7 tests updated with higher ratios (rasterUs 20000→25000 for warning, 40000→50000 for critical). Custom threshold tests changed from 2.0 to 3.0 (since 2.0 is now default). Test names updated ("1.5"→"2.0", "3.0"→"4.0").
- DetectorThresholds test: defaults test updated for new gpuPressureRatio (2.0) and animatedBuilderMinSubtreeSize (50). Custom values test updated to use non-default values.
- 1 new test added: FrameTiming "no thrashing when cache count <= 5 despite high variation".
- Total test count: 1,304 (was 1,303).

---

### v7.4: FrameEventCorrelator — Raise Coverage Threshold ✅ Shipped

**Problem:** `frame_event_correlator.dart` line 35: `isTrustworthy` requires only `coverageRatio >= 0.2` (20% of events matched to frames). A verdict based on 20% coverage has 80% unattributed events — unreliable for frame-level attribution.

**Fix:** Raise threshold from 0.2 to 0.5 (50%). Verdicts with <50% coverage fall back to batch mode (which is already designed for this case).

**Files:** `lib/src/analyzer/frame_event_correlator.dart` line 35.

**Risk:** Medium. More verdicts will fall back to batch mode. This is correct behavior — batch mode is designed for low-correlation scenarios. May reduce "correlated" verdict frequency on platforms with sparse timeline data.

**Post-Implementation Notes:**
- Single source line changed: `coverageRatio >= 0.2` → `>= 0.5` in `CorrelatedFrameData.isTrustworthy`.
- `render_pipeline_analyzer.dart` line 234 already used `coverageRatio >= 0.5` for confidence-dependent wording — now aligned with `isTrustworthy`. The "Partial correlation" else-branch becomes unreachable for trustworthy verdicts (filtered by `watchdog_controller.dart` line 836) but is harmless as a safety net.
- 2 tests updated (boundary test values/names for new 0.5 threshold), 1 stale comment fixed (`< 0.2` → `< 0.5`), 1 new test added (coverage=0.3 between old/new threshold, expects false).
- Total test count: 1,305 (was 1,304).

---

### v7.5: RebuildDetector — VM Fallback on Zero Debug Counts ✅ Shipped

**Problem:** `rebuild_detector.dart` line 257: `if (debugSnapshot.totalRebuilds > 0)` gates the debug evaluation path. If debug callbacks are active but return zero counts (timing issue, sporadic enable/disable), the VM-backed data path is never reached. Real rebuild activity visible in VM timeline is ignored.

**Fix:** After debug path produces zero issues AND debug snapshot has zero counts, fall back to VM-backed evaluation instead of skipping.

**Files:** `lib/src/detectors/rebuild_detector.dart` lines 257–269.

**Risk:** Low. Only changes behavior when debug callback returns empty data. VM path is already well-tested as the default non-debug code path.

**Post-Implementation Notes:**
- Added nested `else if (hasFreshVm)` fallback inside the `hasFreshDebug` branch of `_evaluate()`. When debug snapshot has `totalRebuilds == 0` and VM data is available, falls back to `_evaluateVmData` instead of producing no issues.
- Fallback correctly consumes `_pendingVmWindowCount` to prevent double-fire on the next evaluation cycle.
- `enrichedNames` local variable (captured before `_stagedEnrichedNames` cleared) correctly passes enriched timeline names to the fallback VM path.
- 2 new tests: "zero debug snapshot falls back to VM data when both present" (the bug scenario), "zero debug snapshot with zero VM data produces no issues" (no false positive).
- All existing tests unaffected — L245 "fresh debug snapshot with 0 rebuilds clears stale issues" still passes because `hasFreshVm=false` in that scenario (VM data was consumed in prior evaluateNow).
- Total test count: 1,307 (was 1,305).

---

### v7.6: MemoryPressureDetector — Reduce Warmup Window ✅ Shipped

**Problem:** `memory_pressure_detector.dart` line 15: `warmupDurationMs = 5000` suppresses all heap trend alerts for 5 seconds after first sample. Apps that allocate heavily on startup (large images, database hydration) have their first 5 seconds of memory growth masked.

**Fix:** Reduce default warmup from 5000ms to 3000ms. Apps are typically past startup allocation by 3 seconds. Consumers can still override via constructor.

**Files:** `lib/src/detectors/memory_pressure_detector.dart` line 15, `lib/src/controller/watchdog_controller.dart` line 1409.

**Risk:** Very low. May surface startup allocation patterns as `possible` confidence earlier. Configurable — consumers can set `warmupDurationMs` higher if needed.

**Post-Implementation Notes:**
- Two defaults changed in lockstep: `memory_pressure_detector.dart` line 15 (`warmupDurationMs = 5000` → `3000`) and `watchdog_controller.dart` line 1409 (`memoryWarmupDurationMs = 5000` → `3000`).
- No tests affected — all 6 warmup tests pass explicit `warmupDurationMs: 5000` in constructors, never rely on the default. Main setUp uses `warmupDurationMs: 0` (disabled).
- No user-facing strings reference the warmup duration value.
- `warmupDurationMs` is NOT exposed in `DetectorThresholds` — only in `WatchdogConfig.memoryWarmupDurationMs` and the detector constructor directly.
- Total test count: 1,307 (unchanged).

---

### v7.7: Ring Buffer — Replace List.removeAt(0) with Queue ✅ Shipped

**Problem:** `watchdog_controller.dart` lines 903, 909, 921 use `List.removeAt(0)` for three bounded event buffers (phase events capacity 100, GC events capacity 50, platform channels capacity 50). `removeAt(0)` is O(n) because it shifts all remaining elements. Called on every VM timeline poll (500ms) when buffers are full.

**Fix:** Replace `List<T>` with `Queue<T>` (from `dart:collection`) and use `removeFirst()` which is O(1). Read access patterns (iteration, `.toList()`) are identical.

**Files:** `lib/src/controller/watchdog_controller.dart` lines 100–108 (declarations), 903, 909, 921 (removeAt calls).

**Risk:** None. Drop-in replacement. Queue supports the same iteration, `.toList()`, `.length`, `.add()` APIs.

**Post-Implementation Notes:**
- Added `import 'dart:collection'` to watchdog_controller.dart.
- Three buffer declarations changed from `List<T>` to `Queue<T>`: `_phaseEventBuffer`, `_gcEventBuffer`, `_platformChannelBuffer`.
- Three `removeAt(0)` calls replaced with `removeFirst()` — O(n) → O(1).
- `List.unmodifiable(queue)` works unchanged — constructor accepts `Iterable<T>`, Queue implements Iterable. Test getters and export snapshots unaffected.
- Matches existing codebase pattern: `FrameStatsBuffer` in `frame_stats.dart` already uses `Queue<FrameStats>` with identical `.removeFirst()` / `.add()` pattern.
- Total test count: 1,307 (unchanged).

---

### v7.8: FrameEventCorrelator — Cache Sorted Frame Lists ✅ Shipped

**Problem:** `frame_event_correlator.dart` lines 70–73 sort the frame list twice (by `buildStartUs` and `rasterStartUs`) on every timeline poll (500ms). With a 60-frame buffer, this is 2× O(60 log 60) = ~720 comparisons per poll. Frame data rarely changes between consecutive polls.

**Fix:** Cache the two sorted lists as fields. Invalidate only when new frames are added to the buffer. Binary search phase (already O(E log F)) remains unchanged.

**Files:** `lib/src/analyzer/frame_event_correlator.dart` lines 70–73, plus new cache fields.

**Risk:** Low. Cache invalidation tied to frame buffer mutations. Small memory overhead (two extra list references).

**Post-Implementation Notes:**
- Removed `const` from `FrameEventCorrelator` constructor — caching requires mutable state.
- Added 4 cache fields: `_cachedUiSorted`, `_cachedRasterSorted`, `_cachedEligibleCount`, `_cachedLastFrame`.
- Cache key uses `(count, identical(lastFrame))` — object identity via `identical()` detects when the same `FrameStats` instances are passed again (they persist in the buffer across polls).
- Initial plan used `(count, lastFrameNumber)` as cache key, but this caused a false cache hit in tests where two consecutive test cases used `frameNumber=1` with different timestamps. Switched to object identity which is both correct and zero-cost (`identical()` is a pointer comparison).
- Controller updated: `const FrameEventCorrelator()` → `FrameEventCorrelator()` at line 83.
- Test updated: `const correlator` → `final correlator` at line 7. Shared instance across tests is safe — different `FrameStats` objects between tests cause cache miss via `identical()`.
- Total test count: 1,307 (unchanged).

---

### v7.9: Unified Structural Tree Walk ✅ Shipped

**Problem:** 16 tree-walking detectors (12 structural + 4 hybrid) each walk the full widget tree independently via `visitChildElements`. With the pre-scan `_findVisiblePageContext()` walk, this totals ~17 full tree traversals per scan cycle (every 1 second). On a typical Material page with 200–500 elements, this is ~8,500 visitor calls per scan.

**Fix:** Single unified tree walk that visits each element once and dispatches to all enabled detectors. O(16 × N) → O(N).

**Design — 4 new BaseDetector lifecycle methods:**
```dart
void prepareScan(BuildContext context) {}   // Called once before walk
void checkElement(Element element) {}       // Called per element
void afterElement(Element element) {}       // Called after children visited
void finalizeScan()                         // Called once after walk
```

`scanTree` becomes a convenience wrapper (calls all 4 methods with try-catch). Tests call `scanTree` directly → identical behavior. Controller bypasses it for the unified path. Custom detectors (`DetectorType.custom`) fall back to `scanTree` via legacy path.

**Controller unified walk:**
```dart
void _runStructuralScans(BuildContext scanContext) {
  final unified = <BaseDetector>[];
  final legacy = <BaseDetector>[];
  for (final d in _detectors) {
    if (!d.isEnabled || !d.requiresTreeScan) continue;
    if (d.type == DetectorType.custom) { legacy.add(d); }
    else { unified.add(d); }
  }
  for (final d in unified) d.prepareScan(scanContext);
  void visitor(Element element) {
    for (final d in unified) d.checkElement(element);
    element.visitChildren(visitor);
    for (final d in unified) d.afterElement(element);
  }
  try { scanContext.visitChildElements(visitor); } catch (_) {}
  for (final d in unified) d.finalizeScan();
  for (final d in legacy) d.scanTree(scanContext);
}
```

**Migration patterns:**
- **Pattern A (flat check, 8 detectors):** LayoutBottleneck, FontLoading, Opacity, CustomPainter, ImageMemory, RepaintBoundary, Repaint (hybrid), Rebuild (hybrid). `prepareScan` clears state, `checkElement` inspects widget/render type, `finalizeScan` creates issues.
- **Pattern B (local nested walk, 5 detectors):** Listview, AnimatedBuilder, KeepAlive, GlobalKey, GpuPressure (hybrid). Same as A, but `checkElement` does local `visitChildren` for child/subtree counting.
- **Pattern C (depth/nesting tracking, 2 detectors):** NestedScroll uses `List<Axis?> _scrollAxisStack` (push on `checkElement`, pop on `afterElement`). ShallowRebuildRisk uses `int _depth` counter.
- **Pattern D (multi-pass merge, 1 detector):** SetStateScopeDetector merged `_detectRebuilds` (separate tree walk) into `checkElement`. Safe because rebuild evidence is cumulative (5-second window).

**Files:** `lib/src/models/base_detector.dart`, `lib/src/controller/watchdog_controller.dart`, all 16 detector files in `lib/src/detectors/`. **0 test files changed** — `scanTree` wrapper preserves test contract.

**Post-Implementation Notes:**
- All 1,307 tests pass, 0 analysis issues
- No `scanTree` overrides remain in any built-in detector (verified by grep)
- `afterElement` overhead is negligible: 16 × N calls but only 2 detectors do work (NestedScroll, ShallowRebuildRisk); 14 are empty no-ops
- Custom detector backward compatibility preserved via `DetectorType.custom` check in controller

---

### v7.10: VM Reconnect — Pause Polling During Backoff ✅ Shipped

**Problem:** `vm_service_client.dart` `_pollTimeline()` catch block: timer cancellation depended on `reconnect()` → `_cleanup()` — indirect. If `onConnectionChanged` callback (consumer code) threw before `reconnect()`, the 500ms poll timer survived, creating a tight error loop that never recovered.

**Fix:** Cancel `_pollTimer` directly in the catch block, **before** `onConnectionChanged` and `reconnect()`. Timer is now stopped as the first action on error. `_cleanup()` in `reconnect()` still works (timer cancel is idempotent).

**Files:** `lib/src/vm/vm_service_client.dart` (2 lines added in catch block), `test/vm/vm_service_client_test.dart` (3 new tests for poll error path).

**Post-Implementation Notes:**
- 1,310 tests pass (3 new poll error tests), 0 analysis issues
- Added `getVMTimelineThrows` to test mock for error path coverage
- Timer cancel is idempotent — `_cleanup()` finds timer already null, no-op

---

### v7 Implementation Order

| Priority | Milestone | Effort | Theme | Dependencies |
|----------|-----------|--------|-------|--------------|
| 1 | v7.1: HeavyCompute Two-Tier | Very Low | Accuracy | Shipped ✅ |
| 2 | v7.2: NetworkMonitor >= | Very Low | Accuracy | Shipped ✅ |
| 3 | v7.3: Threshold Tuning Pass | Low | Accuracy | Shipped ✅ |
| 4 | v7.4: Correlator Coverage | Very Low | Accuracy | Shipped ✅ |
| 5 | v7.5: Rebuild VM Fallback | Low | Accuracy | Shipped ✅ |
| 6 | v7.6: MemoryPressure Warmup | Very Low | Accuracy | Shipped ✅ |
| 7 | v7.7: Ring Buffers | Very Low | Performance | Shipped ✅ |
| 8 | v7.8: Correlator Sort Cache | Low | Performance | Shipped ✅ |
| 9 | v7.9: Unified Tree Walk | Medium | Performance | Shipped ✅ |
| 10 | v7.10: VM Reconnect Polling | Very Low | Performance | Shipped ✅ |

**Grouping suggestion:** Milestones can be batched into 3 releases:
- **v0.8.1** (accuracy): v7.1–v7.6 — threshold corrections and detection logic fixes
- **v0.8.2** (performance): v7.7–v7.8, v7.10 — buffer optimization, sort caching, polling fix
- **v0.9.0** (architecture): v7.9 — unified tree walk (breaking internal change, warrants minor bump)

---

