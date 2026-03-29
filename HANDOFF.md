# Widget Watchdog — Session Handoff

**Date:** 2026-03-29
**Version:** 0.3.0 (published tag pushed)
**Tests:** 828 passing, 0 analysis issues

---

## Current State

v0.3.0 is released. All v2 features (v2.1–v2.4) are implemented, tested, and documented. A comprehensive post-implementation audit was completed and written into the spec.

### What's shipped

| Feature | Version | Status |
|---------|---------|--------|
| v2.1 Network Monitoring | 0.2.0 | Shipped (21st detector) |
| v2.2 Heap Trend Monitoring | 0.3.0 | Shipped (enhances MemoryPressureDetector) |
| v2.3 Jank CPU Attribution | 0.3.0 | Shipped (two-phase verdict enrichment) |
| v2.4 Source Location Enrichment | 0.3.0 | Shipped (file:line in ancestor chains) |

### Git state

- All changes committed and pushed
- `v0.3.0` tag created and pushed
- Working tree is clean

---

## Files Changed This Session

| File | What changed |
|------|-------------|
| `pubspec.yaml` | Version bump 0.2.0 → 0.3.0 |
| `CHANGELOG.md` | Prepended 0.3.0 section (v2.2–v2.4 features); fixed framework widget count 16→17 |
| `README.md` | Updated detector matrix, "Better Than DevTools" (+3 bullets), "DevTools Still Better" (narrowed to 2), "Unsupported Claims" (updated for new capabilities) |
| `example/pubspec.yaml` | Detector count 19→21 |
| `example/README.md` | Replaced Flutter boilerplate with proper demo app docs |
| `lib/src/utils/widget_location.dart` | Added 17 framework widgets to `_frameworkNames` filter |
| `lib/src/ui/issue_card.dart` | Added deduplication guard (suppress redundant "Widget:" line) |
| `doc/implementation_spec.md` | Fixed framework widget count 16→17; added "Actual order" to implementation order section; appended ~250-line "v2 Post-Implementation Audit" section |

---

## CLAUDE.md

Updated to reflect v0.3.0, ~828 tests, v2 roadmap complete.

---

## Audit Gaps — All Resolved

All 6 test gaps from the v2 post-implementation audit have been addressed:

| Gap | Status | Test File | Tests Added |
|-----|--------|-----------|-------------|
| 1. Controller integration | **Done** | `test/controller/v2_integration_test.dart` | 40 tests |
| 2. VmServiceClient units | **Done** | `test/vm/vm_service_client_test.dart` | 21 tests |
| 3. v2 benchmarks | **Done** | `test/benchmark/v2_overhead_test.dart` | 3 tests |
| 4. URL exclusion behavior | **Done** | `test/network/http_monitor_test.dart` | 4 tests |
| 5. CaptureEntry fromJson topFunctions | **Done** | `test/models/serialization_test.dart` | 3 tests |
| 6. CPU attribution timeout | **Done** | `test/vm/vm_service_client_test.dart` | (included in Gap 2) |

### Source changes for testability

- `lib/src/vm/vm_service_client.dart` — added two `@visibleForTesting` methods:
  - `setServiceForTest(VmService, {String? isolateId})` — inject mock VmService
  - `pollTimelineForTest()` — trigger one poll cycle without periodic timer

---

## Key Architecture Context

- **VmServiceClient** (`lib/src/vm/vm_service_client.dart`) — polls VM timeline every 500ms, piggybacks heap memory polling. Has `getCpuSamples()` for on-demand CPU attribution. No unit tests exist (most complex untested class).

- **WatchdogController** (`lib/src/controller/watchdog_controller.dart`) — orchestrates everything. v2 wiring:
  - Line 270-278: network override install
  - Line 283-287: VM client callback registration (onHeapSample, onTimelineData, etc.)
  - Line 855-857: heap sample pass-through
  - Line 870-896: CPU attribution enrichment (fire-and-forget async)

- **Two-phase verdict** (v2.3): verdict emitted immediately without CPU data (phase 1), then re-emitted with `topFunctions` when `getCpuSamples()` returns (phase 2). `verdictNotifier` fires twice for jank frames.

- **SourceLocationCache** (`lib/src/utils/source_location_cache.dart`) — bounded at 200 entries, caches by widget runtime type. Uses `InspectorSerializationDelegate` (not `getCreationLocation` which is private).

---

## How to Continue

```bash
# Verify clean state
cd "/Users/harryslala/Desktop/performance detective/widget_watchdog"
git status && fvm flutter test && fvm flutter analyze

# Read the audit for full context
# doc/implementation_spec.md — search for "v2 Post-Implementation Audit"

# Start with Gap 1 (controller integration tests)
# Create: test/controller/v2_integration_test.dart
# Mock VmServiceClient for heap + CPU paths
# Mock HttpOverrides for network path
```
