# Sleuth validation matrix

## Purpose

This document is the release-readiness checklist. Judge a release
against this written matrix, not against ad hoc spot checks.

## How to use

### Setup

1. Build and install the example app on each target platform:
   ```bash
   cd example

   # Debug mode
   fvm flutter run --debug --no-dds

   # Profile mode
   fvm flutter run --profile --no-dds
   ```
   Without `--no-dds`, `flutter run` starts DDS, which takes the VM
   service as its only client. Sleuth then cannot connect and stays in
   FRAME mode on every platform. Run without `--no-dds` only when you
   want FRAME mode, as in the degradation checks below.

2. For each platform and mode combination, work through the validation
   grid below.

3. Record results in this document or a copy. Each cell holds one of:
   - **PASS**: the checkpoint is met.
   - **FAIL**: the checkpoint is not met (describe it in Notes).
   - **N/A**: the checkpoint does not apply to this combination.
   - **DEGRADED**: it works with reduced capability, as expected on
     some platforms.

### Test procedure per combination

1. Launch the example app. Check that it boots without a crash.
2. Tap the dog button. Check that the dashboard opens and responds.
3. Check that the FPS value in the dashboard status row updates.
4. Check the mode badge next to the FPS value (VM+ or FRAME).
5. Read the issue list in the dashboard. Note which issues appear;
   structural detectors should always fire.
6. Open a jank-producing demo (for example, "CSV Import"). Return to
   the dashboard and check the verdict: issue cards linked to the jank
   frame carry a JANK badge.
7. In debug mode with `enableDebugCallbacks` on, check that the "DBG"
   badge appears.
8. Record all results in the grid.

---

## Expected behavior by platform

| Target | Mode | VM Expected | Debug Callbacks | FrameTiming | Structural Scan | Notes |
|--------|------|-------------|-----------------|-------------|-----------------|-------|
| Android device | debug | Best-effort (often fails) | Available if enabled | Always | Always | Primary target |
| Android device | profile | Best-effort (often fails) | Not available | Always | Always | Primary target; use it for real performance data |
| Android emulator | debug | Best-effort | Available if enabled | Always | Always | Faster iteration for development testing |
| Android emulator | profile | Best-effort | Not available | Always | Always | |
| iOS device | debug | Good | Available if enabled | Always | Always | Needs a physical device |
| iOS device | profile | Good | Not available | Always | Always | Recommended mode for production validation |
| Desktop (macOS) | debug | Good | Available if enabled | Always | Always | Secondary target; strongest VM connectivity |
| Desktop (macOS) | profile | Good | Not available | Always | Always | Secondary target |

**Key:**
- "Best-effort": the VM may or may not connect. When it does not, the
  package falls back to FRAME mode.
- "Good": the VM connects reliably in practice when the app runs with
  `--no-dds`.
- "Available if enabled": debug callbacks work with
  `SleuthConfig(enableDebugCallbacks: true)`.
- "Not available": debug callbacks exist only in debug mode, not in
  profile mode.
- "Always": works whether or not the VM connects.

---

## Validation grids

### Android real device

| # | Checkpoint | Debug | Profile | Notes |
|---|------------|-------|---------|-------|
| 1 | App boots with package enabled | | | |
| 2 | Overlay renders (dog button visible) | | | |
| 3 | Dashboard opens and responds | | | |
| 4 | FrameTiming produces frame data (FPS value updates) | | | |
| 5 | VM connection status | | | Record: VM+ or FRAME |
| 6 | Structural detector issues appear | | | Read the issue list after visiting demos |
| 7 | VM-backed issues appear (if VM connected) | | | ShaderJank, HeavyCompute, etc. |
| 8 | Mode badge matches connection state | | | VM+ (green) or FRAME (blue) |
| 9 | Debug mode warning shown (debug only) | | N/A | Yellow "Debug mode" banner |
| 10 | Verdict appears on jank frame | | | Open the CSV Import demo and trigger jank |
| 11 | Confidence wording matches mode | | | Confirmed/Likely with VM, Possible without |

**Device:** _________________ **OS:** __________ **Flutter:** __________ **Date:** __________

### Android emulator

| # | Checkpoint | Debug | Profile | Notes |
|---|------------|-------|---------|-------|
| 1 | App boots with package enabled | | | |
| 2 | Overlay renders (dog button visible) | | | |
| 3 | Dashboard opens and responds | | | |
| 4 | FrameTiming produces frame data | | | |
| 5 | VM connection status | | | Record: VM+ or FRAME |
| 6 | Structural detector issues appear | | | |
| 7 | VM-backed issues appear (if VM connected) | | | |
| 8 | Mode badge matches connection state | | | |
| 9 | Debug mode warning shown (debug only) | | N/A | |
| 10 | Verdict appears on jank frame | | | |
| 11 | Confidence wording matches mode | | | |

**Emulator:** _________________ **API Level:** __________ **Flutter:** __________ **Date:** __________

### iOS real device

| # | Checkpoint | Debug | Profile | Notes |
|---|------------|-------|---------|-------|
| 1 | App boots with package enabled | | | |
| 2 | Overlay renders (dog button visible) | | | |
| 3 | Dashboard opens and responds | | | |
| 4 | FrameTiming produces frame data | | | |
| 5 | VM connection status | | | Expect: VM+ |
| 6 | Structural detector issues appear | | | |
| 7 | VM-backed issues appear | | | Expect: yes (VM should connect) |
| 8 | Mode badge matches connection state | | | Expect: VM+ (green) |
| 9 | Debug mode warning shown (debug only) | | N/A | |
| 10 | Verdict appears on jank frame | | | |
| 11 | Confidence wording matches mode | | | Expect: Confirmed/Likely verdicts |

**Device:** _________________ **iOS:** __________ **Flutter:** __________ **Date:** __________

### Desktop (secondary)

| # | Checkpoint | Debug | Profile | Notes |
|---|------------|-------|---------|-------|
| 1 | App boots with package enabled | | | |
| 2 | Overlay renders (dog button visible) | | | |
| 3 | Dashboard opens and responds | | | |
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

## Degradation verification

These checks cover how the package behaves without a VM connection.
Desktop debug mode is the best place to test them, because the VM
connects reliably there and you can watch the behavior change. Running
without `--no-dds` gives FRAME mode on any platform.

### Forced degradation test

On a platform where VM+ connects:

| # | Check | Result | Notes |
|---|-------|--------|-------|
| 1 | With VM+ active, the issue list shows VM-backed issues (e.g., build or paint share of UI time) | | |
| 2 | Structural issues (ListView, RepaintBoundary, etc.) are always present regardless of VM | | |
| 3 | Verdict includes phase breakdown (build/layout/paint/raster) in VM+ mode | | |
| 4 | Mode badge shows "VM+" in green | | |

### Natural degradation (Android without VM)

On Android where the VM fails to connect:

| # | Check | Result | Notes |
|---|-------|--------|-------|
| 1 | Mode badge shows "FRAME" in blue | | |
| 2 | FrameTiming data still flows (FPS value updates) | | |
| 3 | Structural issues appear (visit demos, read the issue list) | | |
| 4 | No VM-backed issues present (no shader jank, no heavy compute, no memory pressure) | | |
| 5 | Verdict is basic mode (no phase breakdown, just "UI thread" or "Raster thread") | | |
| 6 | No detector claims "Confirmed" confidence for VM-dependent signals | | |
| 7 | Package does not crash or hang waiting for VM | | App boots within normal time |

---

## Detector coverage checklist

Open each demo screen and check that the expected detector fires in the
issue list.

| Detector | Demo Screen | Expected Issue | Verified |
|----------|------------|----------------|----------|
| Rebuild | High-Level setState | "Rebuild Activity: build phase N% of UI time" (VM+) or `rebuild_debug_*` (debug) | |
| SetStateScope | High-Level setState | "Wide setState Scope" | |
| ListView | Non-Lazy ListView | "Non-lazy ListView" with child count | |
| LayoutBottleneck | IntrinsicHeight Abuse | "Layout Bottleneck: N intrinsic nodes" | |
| CustomPainter | Always-Repaint CustomPainter | "Always-Repaint CustomPainter" | |
| ImageMemory | Uncached Images | "Oversized Images" with decoded vs shown size | |
| HeavyCompute | CSV Import (VM+ only) | "Heavy Build" or "Heavy Computation" on the main thread | |
| KeepAlive | KeepAlive Overuse | "Excessive Keep-Alive" | |
| FontLoading | Font Loading Stress | "Multiple Custom Fonts" with family count | |
| RepaintBoundary | Missing RepaintBoundary | "Missing RepaintBoundary: N expensive widgets unprotected" | |
| Repaint | Live Waveform (VM+/debug) | `repaint_debug_*` / `excessive_repaint_debug` (debug); "Excessive Repainting: paint phase N% of UI time" only above 10 % (VM+) | |
| ShaderJank | Shader Jank (first run) | "Shader Compilation" (VM+ only) | |
| MemoryPressure | Memory Pressure | "Heap Growing" or "High GC Pressure" (VM+ only) | |
| PlatformChannel | Platform Channel Traffic | "High Platform Channel Traffic" (VM+ only) | |
| GpuPressure | GPU Pressure | "Raster Dominance" (FrameTiming leg `likely`, VM+ leg `confirmed`) | |
| FrameTiming | CSV Import | "Jank Detected" with the share of frames over budget | |
| NetworkMonitor | Search + Gallery | "Slow Request", "Large Response" or "Request Frequency Spike" | |
| StreamResource | Stream Resource Leaks (VM+ only) | "Stream Resources Growing" | |
| TrackedResource | Tracked Resource Leaks | "Tracked Resource Concurrent" or "Tracked Resource Long-Lived" | |
| Startup | (any cold launch) | "Slow Startup" when time to first frame passes the warning threshold | |

---

## Self-overhead checks

41 tests under `test/benchmark/` check these automatically: 37 tagged
`benchmark`, plus the 4 untagged memory footprint tests. 3 more
`benchmark`-tagged tests sit beside the code they time, for 40
wall-clock benchmarks in all. Run before release:

```bash
fvm flutter test --tags benchmark --concurrency=1
fvm flutter test test/benchmark/memory_footprint_test.dart
```

Wall-clock budgets double on CI (`budgetMultiplier` in
`test/helpers/benchmark_helpers.dart`).

| Check | Budget | Automated |
|-------|--------|-----------|
| Per-detector scan (1000 elements) | 210 to 1,100 µs, set per detector | Yes |
| Full scan (1000 elements) | 4,100 µs | Yes |
| Scaling ratio (1000/500) < 2.5 | 2.5x | Yes |
| Timeline processing (500 events) | 260 µs | Yes |
| Buffer bounds enforced | Capacity | Yes |
| Issue/highlight counts bounded | <50/<100 | Yes |
| Dispatch of an 1,800-event batch (device capture replay) | 1,000 µs | Yes |
| Parse re-read of 5,000 already-seen events vs. a fresh parse | < 30 % | Yes |
| Debug paint attribution, cached vs. uncached (1,000 paints) | < 10 % | Yes |

---

## Sign-off

| Role | Name | Date | Notes |
|------|------|------|-------|
| Validator | | | |
| Reviewer | | | |

**Package Version:** _______________
**Flutter Version:** _______________
**All automated tests pass:** [ ] Yes / [ ] No (_________ failures)
**All primary platform/mode grids complete:** [ ] Yes / [ ] No
**Degradation contract verified:** [ ] Yes / [ ] No
**Release approved:** [ ] Yes / [ ] No
