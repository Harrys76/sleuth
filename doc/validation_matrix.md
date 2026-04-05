# Sleuth Validation Matrix

## Purpose

This document is the release-readiness checklist required by the implementation spec (lines 64-98).
Release readiness is evaluated against this written matrix, not ad hoc spot checks.

## How to Use

### Setup

1. Build and install the example app on each target platform:
   ```bash
   cd example

   # Debug mode
   fvm flutter run --debug

   # Profile mode
   fvm flutter run --profile
   ```

2. For each platform/mode combination, work through the validation grid below.

3. Record results directly in this document (or a copy). Each cell should contain one of:
   - **PASS** — checkpoint met as expected
   - **FAIL** — checkpoint not met (describe in Notes)
   - **N/A** — not applicable for this combination
   - **DEGRADED** — works but with reduced capability (expected on some platforms)

### Test Procedure Per Combination

1. Launch the example app. Verify it boots without crash.
2. Tap the dog button. Verify the dashboard opens and is interactive.
3. Navigate to the "Live" tab. Verify frame bars appear and FPS counter updates.
4. Check the mode badge in the dashboard header (VM+ or FRAME).
5. Navigate to the "Issues" tab. Note which issues appear (structural detectors should always fire).
6. Open a jank-producing demo (e.g., "Heavy Compute"). Return to the dashboard and check verdict.
7. If in debug mode and enableDebugCallbacks is true, verify "DBG" badge appears.
8. Record all results in the grid.

---

## Expected Behavior by Platform

| Target | Mode | VM Expected | Debug Callbacks | FrameTiming | Structural Scan | Notes |
|--------|------|-------------|-----------------|-------------|-----------------|-------|
| Android device | debug | Best-effort (often fails) | Available if enabled | Always | Always | Primary target — VM uses adb forwarding which may be unreachable |
| Android device | profile | Best-effort (often fails) | Not available | Always | Always | Primary target — recommended for real perf data |
| Android emulator | debug | Best-effort | Available if enabled | Always | Always | Faster iteration for dev testing |
| Android emulator | profile | Best-effort | Not available | Always | Always | |
| iOS device | debug | Good | Available if enabled | Always | Always | Physical device needed |
| iOS device | profile | Good | Not available | Always | Always | Recommended production validation mode |
| Desktop (macOS) | debug | Good | Available if enabled | Always | Always | Secondary — strongest VM connectivity |
| Desktop (macOS) | profile | Good | Not available | Always | Always | Secondary target |

**Key:**
- "Best-effort" = VM may or may not connect; package falls back to FRAME mode gracefully
- "Good" = VM connects reliably in practice
- "Available if enabled" = debug callbacks work if `SleuthConfig(enableDebugCallbacks: true)`
- "Not available" = debug callbacks are debug-only; not available in profile mode
- "Always" = works regardless of VM connectivity

---

## Validation Grids

### Android Real Device

| # | Checkpoint | Debug | Profile | Notes |
|---|------------|-------|---------|-------|
| 1 | App boots with package enabled | | | |
| 2 | Overlay renders (dog button visible) | | | |
| 3 | Dashboard opens and is interactive | | | |
| 4 | FrameTiming produces frame data (bars in Live tab) | | | |
| 5 | VM connection status | | | Record: VM+ or FRAME |
| 6 | Structural detector issues appear | | | Open Issues tab after navigating demos |
| 7 | VM-backed issues appear (if VM connected) | | | ShaderJank, HeavyCompute, etc. |
| 8 | Mode badge matches connection state | | | VM+ (green) or FRAME (blue) |
| 9 | Debug mode warning shown (debug only) | | N/A | Yellow "debug mode" banner |
| 10 | Verdict appears on jank frame | | | Open Heavy Compute demo, trigger jank |
| 11 | Confidence wording matches mode | | | Confirmed/Likely with VM, Possible without |

**Device:** _________________ **OS:** __________ **Flutter:** __________ **Date:** __________

### Android Emulator

| # | Checkpoint | Debug | Profile | Notes |
|---|------------|-------|---------|-------|
| 1 | App boots with package enabled | | | |
| 2 | Overlay renders (dog button visible) | | | |
| 3 | Dashboard opens and is interactive | | | |
| 4 | FrameTiming produces frame data | | | |
| 5 | VM connection status | | | Record: VM+ or FRAME |
| 6 | Structural detector issues appear | | | |
| 7 | VM-backed issues appear (if VM connected) | | | |
| 8 | Mode badge matches connection state | | | |
| 9 | Debug mode warning shown (debug only) | | N/A | |
| 10 | Verdict appears on jank frame | | | |
| 11 | Confidence wording matches mode | | | |

**Emulator:** _________________ **API Level:** __________ **Flutter:** __________ **Date:** __________

### iOS Real Device

| # | Checkpoint | Debug | Profile | Notes |
|---|------------|-------|---------|-------|
| 1 | App boots with package enabled | | | |
| 2 | Overlay renders (dog button visible) | | | |
| 3 | Dashboard opens and is interactive | | | |
| 4 | FrameTiming produces frame data | | | |
| 5 | VM connection status | | | Expect: VM+ |
| 6 | Structural detector issues appear | | | |
| 7 | VM-backed issues appear | | | Expect: yes (VM should connect) |
| 8 | Mode badge matches connection state | | | Expect: VM+ (green) |
| 9 | Debug mode warning shown (debug only) | | N/A | |
| 10 | Verdict appears on jank frame | | | |
| 11 | Confidence wording matches mode | | | Expect: Confirmed/Likely verdicts |

**Device:** _________________ **iOS:** __________ **Flutter:** __________ **Date:** __________

### Desktop (Secondary)

| # | Checkpoint | Debug | Profile | Notes |
|---|------------|-------|---------|-------|
| 1 | App boots with package enabled | | | |
| 2 | Overlay renders (dog button visible) | | | |
| 3 | Dashboard opens and is interactive | | | |
| 4 | FrameTiming produces frame data | | | |
| 5 | VM connection status | | | Expect: VM+ |
| 6 | Structural detector issues appear | | | |
| 7 | VM-backed issues appear | | | Expect: yes |
| 8 | Mode badge matches connection state | | | Expect: VM+ (green) |
| 9 | Debug mode warning shown (debug only) | | N/A | |
| 10 | Verdict appears on jank frame | | | |
| 11 | Confidence wording matches mode | | | |

**Platform:** _________________ **OS:** __________ **Flutter:** __________ **Date:** __________

---

## Degradation Verification

These checks verify the degradation contract (spec lines 100-117).
Best tested on **desktop debug mode** where VM connects reliably, then observing behavior change.

### Forced Degradation Test

On a platform where VM+ connects:

| # | Check | Result | Notes |
|---|-------|--------|-------|
| 1 | With VM+ active, issues tab shows VM-backed issues (e.g., rebuild count, repaint data) | | |
| 2 | Structural issues (ListView, Opacity, etc.) are always present regardless of VM | | |
| 3 | Verdict includes phase breakdown (build/layout/paint/raster) in VM+ mode | | |
| 4 | Mode badge shows "VM+" in green | | |

### Natural Degradation (Android without VM)

On Android where VM fails to connect:

| # | Check | Result | Notes |
|---|-------|--------|-------|
| 1 | Mode badge shows "FRAME" in blue | | |
| 2 | FrameTiming data still flows (frame bars update) | | |
| 3 | Structural issues appear (navigate to demos, check Issues tab) | | |
| 4 | No VM-backed issues present (no shader jank, no heavy compute, no memory pressure) | | |
| 5 | Verdict is basic mode (no phase breakdown, just "UI thread" or "Raster thread") | | |
| 6 | No detector claims "Confirmed" confidence for VM-dependent signals | | |
| 7 | Package does not crash or hang waiting for VM | | App boots within normal time |

---

## Detector Coverage Checklist

Navigate to each demo screen and verify the expected detector fires in the Issues tab.

| Detector | Demo Screen | Expected Issue | Verified |
|----------|------------|----------------|----------|
| Rebuild | High-Level setState | "High rebuild activity" or similar | |
| SetStateScope | High-Level setState | "Large setState scope" or similar | |
| ListView | Non-Lazy ListView | "Non-lazy list" with child count | |
| LayoutBottleneck | IntrinsicHeight Abuse | "IntrinsicHeight" or layout issue | |
| CustomPainter | Always-Repaint CustomPainter | "shouldRepaint returns true" | |
| ImageMemory | Uncached Images | "Uncached image" or memory issue | |
| GlobalKey | GlobalKey Overuse | "GlobalKey count exceeds threshold" | |
| NestedScroll | Nested Scroll | "Nested scrollable" detected | |
| HeavyCompute | Heavy Compute (VM+ only) | "Heavy computation" on main thread | |
| KeepAlive | KeepAlive Overuse | "KeepAlive" overuse detected | |
| Opacity | Opacity Zero | "Opacity 0.0" or invisible widget | |
| AnimatedBuilder | AnimatedBuilder No Child | "AnimatedBuilder without child" | |
| ShallowRebuildRisk | Shallow Rebuild Risk | "Shallow rebuild risk" at depth ≤3 | |
| FontLoading | Font Loading Stress | "Custom font families" count | |
| Repaint | Repaint Stress (VM+/debug) | "High repaint activity" | |
| ShaderJank | (natural, first run) | Shader compilation detected (VM+ only) | |
| MemoryPressure | (natural, under GC pressure) | GC pressure detected (VM+ only) | |
| PlatformChannel | (not demoed) | Platform channel spikes (VM+ only) | |
| GpuPressure | CustomPainter (partial) | Raster dominance detected (VM+ only) | |
| FrameTiming | Heavy Compute | Frame exceeded budget | |

---

## Self-Overhead Checks

Verified automatically by `test/benchmark/` suite (29 tests). Run before release:

```bash
fvm flutter test test/benchmark/
```

| Check | Budget | Automated |
|-------|--------|-----------|
| Per-detector scan < 5ms (1000 elements) | 5ms | Yes |
| Full scan < 80ms (1000 elements) | 80ms | Yes |
| Scaling ratio (1000/500) < 2.5 | 2.5x | Yes |
| Timeline processing < 20ms (500 events) | 20ms | Yes |
| Buffer bounds enforced | Capacity | Yes |
| Issue/highlight counts bounded | <50/<100 | Yes |

---

## Sign-Off

| Role | Name | Date | Notes |
|------|------|------|-------|
| Validator | | | |
| Reviewer | | | |

**Package Version:** 0.2.0
**Flutter Version:** _______________
**All automated tests pass:** [ ] Yes / [ ] No (_________ failures)
**All primary platform/mode grids complete:** [ ] Yes / [ ] No
**Degradation contract verified:** [ ] Yes / [ ] No
**Release approved:** [ ] Yes / [ ] No
