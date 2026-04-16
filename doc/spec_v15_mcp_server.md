# Sleuth MCP Server — v0.15.0

## Context

Sleuth has 23 detectors, 47 encyclopedia entries, 44 causal graph rules, per-route health scores, and structured export data. All of this runs **in-process** inside the Flutter app. There's no way for external tools (AI assistants, CI scripts) to query this data programmatically while the app is running.

The goal: expose Sleuth's runtime data and diagnostic knowledge to AI assistants (Claude Code, Cursor, etc.) via MCP (Model Context Protocol). A developer running their app can ask their AI assistant "check my app's performance" and get analysis grounded in **real live data** — not generic Flutter advice.

**The bridge**: `dart:developer.registerExtension()` registers custom service extensions on the VM service. These work in both debug AND profile mode. The MCP server (separate Dart process on the host) connects to the same VM service WebSocket URI and calls these extensions. This is the exact pattern Flutter/DevTools uses (`ext.flutter.inspector.*`).

## Two-Part Delivery

**Part 1 (v0.15.0)**: Service extensions registered inside the Sleuth package. Useful independently — any VM service client can call them.

**Part 2 (v0.15.0)**: `sleuth_mcp` Dart CLI package at `packages/sleuth_mcp/` that bridges VM service extensions to the MCP stdio protocol.

## Scope Discipline

Two items were cut and one was redesigned after internal review:

- **CUT: Static grep-based release-mode guard test** — asserted a literal string exists in a source file, which doesn't prove the guard works. The runtime `kReleaseMode` guard is tree-shaken in release builds and protected by the **numbered M7a manual release-mode smoke test**. Re-adding meta-tests to protect the guard is belt-and-suspenders-on-suspenders.
- **CUT: 24 h stale-file reaper** — non-developer-facing hygiene. Reboot clears stale `~/.sleuth/` entries naturally; the MCP liveness probe (identity-verifying, see M4) skips dead/stale entries at query time.
- **REDESIGN: `compare_snapshots` takes JSON objects, not file paths** — the MCP *client* (Claude Code, Cursor) already has filesystem access through its own tools. Accepting pre-parsed JSON objects keeps the developer value (structured diff between two snapshots) while removing the entire filesystem attack surface from the MCP server.

Developer-facing value stays intact: all 7 tools ship, all 2 resources ship.

## Files to Modify/Create

### Part 1: Service Extensions (in Sleuth package)

| File | Change |
|------|--------|
| **NEW** `lib/src/vm/service_extension_registry.dart` | Registry class wrapping `registerExtension()` — 8 handlers, tri-state bypass, rate limiter, fixed-capacity buffer invariant + 5 MiB wire-size cap (superseded the 500 ms wall-clock design per F1), canonical JSON-encode helper |
| **NEW** `lib/src/vm/project_root_resolver.dart` | Project root + package name detection for `ext.sleuth.ping` handshake (walk-up `pubspec.yaml` search with 16-level cap, `SleuthConfig(projectRoot:)` override, graceful null fallback — added per F2; resolved **lazily on the first `ext.sleuth.ping` call** rather than at init time to keep Sleuth's own startup I/O out of the TTFF measurement window — see TR1) |
| **NEW** `lib/src/vm/discovery_file.dart` | Write VM service URI to `~/.sleuth/vm_service_uri_<pid>` (atomic rename, Windows-aware, symlink/perms guards) |
| `lib/src/controller/sleuth_controller.dart` | Call `ServiceExtensionRegistry.register()` after init (specific ordering) |
| `lib/src/vm/vm_service_client.dart` | Write discovery file on connect, clean up on dispose |
| `lib/src/analyzer/causal_graph.dart` | Add package-internal `rulesJsonV1` static getter — NOT exported through `lib/sleuth.dart` |

`lib/sleuth.dart` exports are unchanged for this release — service extensions communicate with MCP via `dart:developer`, not through new Dart-level public API.

### Part 2: MCP Server (new package)

| File | Purpose |
|------|---------|
| `packages/sleuth_mcp/pubspec.yaml` | Dependencies: `vm_service`, `args` |
| `packages/sleuth_mcp/bin/sleuth_mcp.dart` | CLI entry point |
| `packages/sleuth_mcp/lib/src/mcp_server.dart` | MCP stdio JSON-RPC server |
| `packages/sleuth_mcp/lib/src/mcp_protocol.dart` | MCP protocol types |
| `packages/sleuth_mcp/lib/src/vm_bridge.dart` | VM service connection + `ext.sleuth.*` calls + identity-verifying liveness probe |
| `packages/sleuth_mcp/lib/src/tools/*.dart` | 7 tool implementations |
| `packages/sleuth_mcp/lib/src/resources/*.dart` | 2 resource implementations |

## Steps

### M0: Workspace Scaffolding Smoketest (gating)

Before writing any production code, confirm the multi-package layout works with the team's toolchain.

**Decision:** Dart 3.5+ **pub workspaces** (`resolution: workspace` in child pubspec, `workspace:` list in root). First-party, no external tool.

**Smoketest:**
1. Add a throwaway `packages/sleuth_mcp/` with minimal `pubspec.yaml` (`resolution: workspace`) and a single `bin/hello.dart` that prints a string.
2. Add `workspace: [packages/sleuth_mcp]` to the root `pubspec.yaml`.
3. Run, from repo root: `fvm flutter pub get`, `fvm flutter test`, `fvm flutter analyze`, **`fvm flutter pub publish --dry-run`** (verifies the main `sleuth` package still ships as a clean single-package tarball — Scope #11 coverage), `cd packages/sleuth_mcp && dart run bin/hello.dart`, `dart test` (empty suite), `dart analyze`.
4. All commands must succeed. Any regression against existing tests / analyze / `publish --dry-run` is a blocker.

**Fallback (if workspaces break Flutter tooling):** document the regression, revert workspace wiring, adopt `melos`.

**Exit criteria:** root-level and subpackage commands all succeed on macOS (dev). `pub publish --dry-run` reports no warnings/errors. No change to existing test count.

---

### M1: Service Extension Registry

Create `lib/src/vm/service_extension_registry.dart` — a class that registers **8** `dart:developer` service extensions (one new `ping` added for MCP identity verification).

**Extensions:** (exact response JSON shapes locked in the *Response Schemas* appendix)
- `ext.sleuth.ping` — cheap identity probe: returns `{"sleuthOk": true, "sleuthVersion": "0.15.0", "projectRoot": "/abs/path/to/project", "packageName": "my_app", "pid": 12345}` (no controller access beyond reading cached handshake fields; registers but never throttled). The `projectRoot` + `packageName` fields enable correct VM selection when multiple Flutter apps are running at once — see M4 discovery algorithm. **Resolution happens lazily on the first `ext.sleuth.ping` invocation** per registry instance and the result is cached for the lifetime of the isolate, so the first `ping` absorbs the one-shot resolver cost (typically sub-millisecond) and every subsequent `ping` is constant-time. Resolving lazily — rather than at `SleuthController.initialize()` — keeps Sleuth's own filesystem I/O out of the TTFF measurement window so the `slow_startup_ttff` detector does not false-fire on Sleuth's own cold-start work. See **TR1** below for the full rationale.
- `ext.sleuth.getSnapshot`
- `ext.sleuth.getIssues` (optional `route` param filter)
- `ext.sleuth.getFrameStats`
- `ext.sleuth.getRouteHealth` (optional `route` param)
- `ext.sleuth.getEncyclopedia`
- `ext.sleuth.explainIssue` (`stableId` required)
- `ext.sleuth.getCausalGraph`

**Design:**
- Handlers receive `(String method, Map<String, String> params)`, return `ServiceExtensionResponse`.
- All handlers catch exceptions → return `ServiceExtensionResponse.error` with a non-PII message.
- Idempotent `_registered` flag prevents double-registration on hot restart.

- **Two-layer release-mode guard:** controller's `kReleaseMode` guard in `initialize()` + explicit `if (kReleaseMode) return;` at the top of `ServiceExtensionRegistry.register()`. Both are free (`kReleaseMode` is a compile-time constant) and protect end-user production devices.

- **Tri-state test-mode bypass** (fixes adversarial H6):
  ```dart
  /// null  → use env heuristic (FLUTTER_TEST → skip)
  /// true  → always skip (forced)
  /// false → always register (forced — needed for integration_test)
  @visibleForTesting
  static bool? debugServiceExtensionRegistrationOverride;

  static void register(SleuthController c) {
    if (kReleaseMode) return;
    final override = debugServiceExtensionRegistrationOverride;
    if (override == true) return;
    if (override == null && Platform.environment.containsKey('FLUTTER_TEST')) return;
    if (_registered) return;
    _registered = true;
    ...
  }
  ```
  The tri-state is load-bearing: `false` (force-register) lets integration tests exercise end-to-end behavior even under `FLUTTER_TEST`, which an unconditional env check would block.

- **Canonical JSON-encode helper** (fixes adversarial C3): `ServiceExtensionResponse.result()` requires a **String**, not a Map. Define `_safeJsonEncode(Map<String, Object?> data)` that walks the map and converts non-JSON-encodable values before `jsonEncode`:
  ```dart
  // Conversions: Duration → int (ms), DateTime → int (epoch ms),
  // Enum → enum.name (String), any other non-encodable → String via toString().
  ```
  Every handler calls this helper as the final step. Test with deliberately "dirty" maps containing each type.

- **Bounded handler work via fixed-capacity buffers + wire-size cap** (fixes adversarial H8, revised after F1 in the 2026-04-14 investigation):

  The original plan wrapped every handler in a 500 ms `Future.any`-style wall-clock timeout. That design is unenforceable in Dart: `exportSnapshot()` is **fully synchronous** (see `sleuth_controller.dart:1050-1140` — no `await` anywhere in the body), so once a handler enters its body the event loop is owned by that work until it returns. A racing `Future.delayed(500ms)` cannot preempt it. The "timeout" would only fire on handlers that had already voluntarily yielded — i.e., not the ones that could actually blow the budget.

  Replacement strategy — bound the work at the source and cap the wire size on the way out:

  1. **Input invariant: every source buffer is fixed-capacity.** The controller already enforces this, and M1 depends on it being true. Audit in M1 that each buffer has a hard cap and document the contract in `ServiceExtensionRegistry` dartdoc so future buffer additions inherit the rule:

     | Buffer | Class (file) | Capacity |
     |---|---|---|
     | Jank frame captures | `JankCaptureBuffer` (`models/capture_buffer.dart`) | 50 |
     | Frame stats ring | `FrameStatsBuffer` (`models/frame_stats.dart`) | 60 |
     | Phase events | `_phaseEventBuffer` (sleuth_controller.dart) | 100 |
     | GC events | `_gcEventBuffer` (sleuth_controller.dart) | 50 |
     | Platform channel events | `_platformChannelBuffer` (sleuth_controller.dart) | 50 |
     | Route history | `_routeHistory` (sleuth_controller.dart), `SleuthConfig.routeHistoryCapacity` | 50 (default) |
     | HTTP request records | `NetworkMonitorDetector` internal | 100 |

     The live issue list is bounded by the detector registry (≤ 50 types × typical issue count per scan). `widgetHeatMap` / `recurrenceTrends` / `sessionSummary` are all computed from these same bounded inputs. No new unbounded state may be introduced by M1.

  2. **Bounded-time serialization benchmark (M1 gate).** Since buffer caps bound the *work*, the gate becomes a wall-clock benchmark, not a runtime timeout. In `test/vm/service_extension_registry_test.dart`:
     - Drive a real `SleuthController` against a widget tree until all buffers are saturated (fill JankCaptureBuffer to 50, run ≥ 120 frames to saturate FrameStatsBuffer, trigger ≥ 100 phase events, register ≥ 20 issues of varied types).
     - Call each handler 10× and record the p95 wall-clock.
     - **Assert p95 < 50 ms** for every handler. Fails the build if the budget is blown, which forces the regression to be fixed at source (buffer cap, serializer, detector) rather than papered over with a runtime check.

  3. **Output cap: 5 MiB wire-size truncation (two-stage drop).** Apply *after* `_safeJsonEncode` produces the string. If `utf8.encode(encoded).lengthInBytes > 5 * 1024 * 1024`, rebuild the response as:
     ```json
     {
       "truncated": true,
       "truncatedReason": "payload_exceeds_5mib",
       "truncatedFields": ["recentFrames", "phaseEvents", "widgetHeatMap"],
       "partialData": { /* snapshot with the listed fields dropped */ }
     }
     ```

     **Stage 1 — primary drop (largest-first, most-reconstructible-first).** Drop optional fields one by one in this order, re-encoding and re-checking after each: `recentFrames` → `phaseEvents` → `gcEvents` → `platformChannelEvents` → `widgetHeatMap` → `heapSamples` → `recentRequests`. Stop as soon as the encoded payload fits under 5 MiB and emit `truncatedFields` listing exactly what was dropped. The minimum kept set after stage 1 is `{schemaVersion, packageVersion, exportedAt, frameStatsSummary, currentIssues, sessionSummary}` — these are the fields a downstream consumer cannot reconstruct from a separate call.

     **Stage 2 — secondary trim within the minimum kept set.** Stage 1 alone is insufficient: a saturated `currentIssues` (≥ 50 issue types × allocations / heatmap entries) plus a per-route `sessionSummary` with dozens of `routeSessions` can exceed 5 MiB on its own. Stage 2 trims **inside** the minimum set rather than aborting:
     1. Truncate `currentIssues` to the top 50 by `rankingScore` descending (ties broken by `severity` then `stableId`). Add `"currentIssuesTruncatedTo": 50` and append `"currentIssues_topN"` to `truncatedFields`. Re-encode.
     2. If still over budget, truncate `sessionSummary.routeSessions` (when present) to the **last 10 by `endedAt`** (most recent). Add `"routeSessionsTruncatedTo": 10` and append `"sessionSummary.routeSessions_lastN"` to `truncatedFields`. Re-encode.
     3. If still over budget, truncate `sessionSummary.topIssues` to the first 20 entries and `sessionSummary.detectorHitRates` to the 20 highest-rate detectors. Append the corresponding `truncatedFields` entries. Re-encode.

     **Stage 3 — final fallback (minimum set still exceeds cap).** Only reached for pathological state. Replace the response with:
     ```json
     {
       "truncated": true,
       "truncatedReason": "minimum_set_exceeds_cap",
       "minimumSetBytes": 5421337,
       "partialData": {
         "schemaVersion": 4,
         "packageVersion": "0.15.0",
         "exportedAt": "2026-04-14T12:34:56.789Z",
         "frameStatsSummary": { /* full */ },
         "currentIssues": [ /* first 5 by rankingScore desc */ ]
       }
     }
     ```
     This shape is **always** under 5 MiB by construction (5 issue bodies + a small frame summary < 50 KiB worst case). The `partialData.currentIssues[0..4]` slice gives the AI assistant enough to surface the most severe live problems even when the full export is unsendable.

     `ping` / `getFrameStats` / `getRouteHealth` are too small to ever trip stage 1; the gate is primarily for `getSnapshot` and `getIssues` on highly-saturated sessions.

  4. **`ping` is exempt** — always constant-time, no buffers touched.

  Renames from the prior draft: `reason: "handler_timeout"` → `truncatedReason: "payload_exceeds_5mib"`; new `truncatedFields` array replaces the previous `partialData: {...}` shape that never specified what was dropped.

- **Rate limiter — app-side state** (fixes adversarial H7): per-extension minimum interval of 100 ms between invocations, state stored on the `ServiceExtensionRegistry` instance. This is the app side, so all VM service clients (multiple MCP processes probing the same app) share the same limiter. Explicitly tested by launching two concurrent `VmService` clients that both call `getSnapshot` and asserting they hit the limit. `ping` is not rate-limited (needed for fast identity checks).

- **Param validation:** reject values > 1 KiB, reject unknown keys, validate `stableId` against known prefix set, reject non-string values.

**Modify `sleuth_controller.dart` — explicit ordering:** inside `initialize()`:
```dart
Future<void> initialize() async {
  if (kReleaseMode) return;
  if (_initialized) return;
  _setupState();                             // 1. synchronous construction
  await _vmServiceClient.connect();          // 2. async setup
  _initialized = true;                       // 3. mark live BEFORE register
  ServiceExtensionRegistry.register(this);   // 4. register LAST
}
```

**Modify `causal_graph.dart`:** Add `static Map<String, Object?> get rulesJsonV1` returning `{"schemaVersion": 1, "rules": [{"cause": String, "effect": String}, ...]}`. v1 contract locked — future rule fields require `schemaVersion` bump. Not exported through `lib/sleuth.dart`.

**Create `lib/src/vm/project_root_resolver.dart`** (fixes adversarial F2): resolves the project root + package name for the `ping` handshake. API:
```dart
class ProjectRootResolver {
  /// Resolves (projectRoot, packageName) for the `ext.sleuth.ping` handshake.
  ///
  /// Called **lazily on the first `ext.sleuth.ping` invocation**, not at
  /// Sleuth.init()/Sleuth.track() time — this keeps sync filesystem I/O
  /// out of the TTFF measurement window (TR1 below).
  ///
  /// Both fields may be null if detection failed or no override was
  /// provided — the handshake still works and the M4 selector treats a
  /// null entry as tier 3 (degraded).
  static ({String? projectRoot, String? packageName}) resolve({String? override}) { ... }
}
```

**Entry-point placement — TR1, the C1 / C2 / H2 fix from the 2026-04-14 third-pass review.**

The prior draft of this section said "resolved at `Sleuth.init()` time" and proposed adding a `projectRoot` parameter to `Sleuth.init()`. Both claims were wrong on inspection of the live source:

- `Sleuth.init()` (`lib/sleuth.dart:196`) is the **optional startup-metrics helper** that measures TTFF. It is not the main entry point. Users who never call it — the typical case, per the README and example app — would have `projectRoot` permanently null, which silently collapses F2's 5-tier selection back to an mtime tie-break in its motivating "two apps running" scenario.
- The real main entry is `Sleuth.track({required Widget child, SleuthConfig? config})` at `lib/sleuth.dart:405`, which instantiates a `SleuthController` and mounts `SleuthOverlay`. `SleuthOverlay.initState` synchronously calls `SleuthController.initialize()` (`sleuth_controller.dart:494`), which is where M1's `ServiceExtensionRegistry.register(this)` call lives. Both `track()`-path and `init()`-path users hit `initialize()` — it is the one guaranteed entry point.
- Even so, running `ProjectRootResolver.resolve()` synchronously inside `initialize()` would block the first build and inflate TTFF. The `slow_startup_ttff` detector (v0.13.0, calibrated for the portion Dart code can actually move) would false-fire on Sleuth's own cold-start I/O — Sleuth accusing itself. The README's v0.13.0 section explicitly promises this window is "the portion Dart code can actually move"; poisoning it with Sleuth's own I/O is a correctness regression.

**The fix — lazy on first `ping`:**

1. `SleuthConfig` gains a new optional `String? projectRoot` named parameter on its constructor and matching entry in `copyWith`. Default is `null` (auto-detect). `Sleuth.init()` is **not modified** — the optional-parameter design on `init()` was based on a wrong premise and is dropped.
2. `ServiceExtensionRegistry` holds a nullable `({String? projectRoot, String? packageName})? _cachedHandshake` field. At construction the field is null; `register()` does not touch the filesystem.
3. On the **first** call to `ext.sleuth.ping`, the handler checks the cache. If unset, it calls `ProjectRootResolver.resolve(override: controller.config.projectRoot)`, stores the result on the instance, and returns it. Subsequent pings read the cache; zero repeat I/O. First ping absorbs the one-shot cost (typically sub-millisecond — walk-up `existsSync` + one small file read).
4. This is non-breaking in both directions: the `SleuthConfig` constructor gains an optional parameter (source-compatible), and existing callers of `Sleuth.init()` / `Sleuth.track()` / `Sleuth(config: ...)` continue to work unchanged. The `ServiceExtensionRegistry._handlePing` body reads from `_cachedHandshake` and includes `projectRoot`, `packageName`, and `pid` (from `io.pid`) in the response.

**Algorithm** (executed lazily on the first `ping`, at most once per registry instance):
1. If `override != null` — stat it. If the directory exists and contains `pubspec.yaml`, use it. Otherwise, log a one-shot `[Sleuth] projectRoot override "<override>" does not contain pubspec.yaml — falling back to auto-detection.` and continue to step 2.
2. Start at `Directory.current.absolute.path`. Walk upward (`Directory.parent`) looking for a child named `pubspec.yaml`. Cap the walk at 16 levels (defence against symlink loops or very deep trees). Each level is one `existsSync` — no read, no size check.
3. On match, enforce **256 KiB size cap** via `File(path).lengthSync() > 256 * 1024 → reject as detection failure`. Then read the file synchronously with `readAsStringSync()`. There is **no wall-clock read budget** — F1's own lesson is that Dart cannot preempt synchronous I/O, and the spec's prior "1-second read budget" language was unenforceable. If the disk is slow enough that `readAsStringSync` blocks for seconds, the caller has bigger problems; the 256 KiB pre-check rejects pathologically large files before the read even starts.
4. Scan line-by-line for a tightened regex: `^name:\s*["']?([a-z_][a-z0-9_]*)["']?\s*$` (tightened from the prior `^name:\s*(\S+)` per H4 — the old regex captured surrounding quotes into `packageName`, yielding invalid Dart identifiers like `"my_app"` with quotes for pubspec files that used quoted names). The captured group alone becomes `packageName`; the directory containing `pubspec.yaml` becomes `projectRoot`.
5. Canonicalise `projectRoot` via `Directory(path).resolveSymbolicLinksSync()`. Absorb any `FileSystemException` (treat as detection failure). Note: `resolveSymbolicLinksSync` is itself blocking I/O, but runs at most once per registry instance via the lazy-cache design.
6. On any failure (no pubspec within 16 levels, unreadable, size-cap exceeded, malformed `name:` line, filesystem exception, symlink loop), return `(projectRoot: null, packageName: null)`. Never throw. The handshake still works; M4 treats the entry as tier 3.
7. Cache the result on the `ServiceExtensionRegistry` instance (not a static field, since multiple test controllers need independent caches). The cache is reset when the registry is re-created on hot restart; hot reload preserves it (same instance).

**Root-isolate guard** (M2 finding): `registerExtension` only succeeds on the root isolate. If `SleuthController.initialize()` is somehow called from a spawned isolate (e.g. a background worker set up via `Isolate.spawn` with its own Flutter bindings — rare but possible on desktop), `registerExtension` throws `UnsupportedError`. Wrap the call site in a single try/catch: on failure, log one-shot `[Sleuth] service extension registration skipped: not on root isolate`, swallow the exception, and leave `_registered = false`. MCP discovery for that isolate degrades gracefully to "no live Sleuth app found"; the main isolate's registry (if any) is unaffected.

**Tests (`test/vm/service_extension_registry_test.dart`):**
- Handler unit tests as pure functions (mocked controller, fast edge-case coverage).
- **At least one real-controller integration test per extension** (fixes adversarial H10): construct a real `SleuthController`, set `debugServiceExtensionRegistrationOverride = false` (force-register), run the scan loop against a test widget tree for N frames, then invoke each handler and assert the response shape matches the Response Schemas appendix. Prevents fixture-tautology where mocks agree with handler expectations.
- **Schema-conformance test per extension** (fixes adversarial C1, C2): for each of the 8 extensions, load the JSON example from `test/fixtures/response_schemas/<extension>.json` (copied from the spec's *Response Schemas* appendix and checked into the repo). Assert live handler output **structurally matches** the fixture: every `required` field present, every field type matches, no disallowed extra fields. This replaces the infeasible "round-trip through deserializers" test — no deserializers need exist. When the handler output changes shape, this test fails and the fixture must be updated alongside the appendix in the same PR.
- **JSON-encode helper test:** map containing `Duration`, `DateTime`, `Enum`, and a custom object → encoded output is valid JSON with expected conversions.
- **Rate limiter:** 101 calls in < 100 ms → 100 throttle responses + 1 success. Two concurrent `VmService` clients share the limit.
- **Bounded-handler benchmark:** saturate all fixed-capacity buffers (Jank=50, FrameStats=60, phase=100, gc=50, platformChannel=50, route=50, issues ≥ 20); invoke each handler 10×; assert p95 < 50 ms per handler. Regression gate — fails the build if serialization slows past budget.
- **Wire-size cap — stage 1 (primary drop):** construct a handler response whose encoded size exceeds 5 MiB by stuffing `recentFrames`/`phaseEvents`/`widgetHeatMap` beyond ordinary caps via a test-only hook; assert the response becomes `{truncated: true, truncatedReason: "payload_exceeds_5mib", truncatedFields: [...]}` with the drop order documented in M1 (largest-first, most-reconstructible-first). Assert that drops stop as soon as the payload fits — `truncatedFields` should not list fields that weren't needed. Assert the minimum kept set (`schemaVersion`, `packageVersion`, `exportedAt`, `frameStatsSummary`, `currentIssues`, `sessionSummary`) survives unchanged when stage 1 alone is sufficient.
- **Wire-size cap — stage 2 (secondary trim):** fabricate a snapshot where `currentIssues` alone exceeds 5 MiB (e.g. 200 issues each with a deep `topAllocators` array). Stage 1 drops every optional field but the response is still over budget. Assert the response now includes `currentIssuesTruncatedTo: 50`, `truncatedFields` contains `"currentIssues_topN"`, and the surviving 50 issues are the **highest-`rankingScore`** entries (verifying tie-breaks). Cover the further trim where `sessionSummary.routeSessions` also has to be cut to last 10 by `endedAt`. Assert `sessionSummary.topIssues` and `sessionSummary.detectorHitRates` truncations fire only when needed.
- **Wire-size cap — stage 3 (final fallback):** fabricate a `sessionSummary` so large that even after stage 2 trims the payload remains over 5 MiB. Assert the response collapses to `{truncated: true, truncatedReason: "minimum_set_exceeds_cap", minimumSetBytes: N, partialData: {schemaVersion, packageVersion, exportedAt, frameStatsSummary, currentIssues[0..4]}}` and is **always** under 5 MiB by construction. Assert exactly 5 issues are returned, ranked by `rankingScore` desc with severity/stableId tie-breaks. Assert that `truncatedReason` is the new sentinel `"minimum_set_exceeds_cap"` (not `"snapshot_too_large"` from the prior draft — that key is removed).
- **Buffer-cap contract test:** grep-based assertion (or reflection-based if feasible) that each buffer listed in the M1 buffer table has its documented capacity, so a future PR that raises `routeHistoryCapacity` default or introduces an unbounded buffer breaks this test and forces the spec's benchmark to be re-validated.
- **ProjectRootResolver auto-detection** (`test/vm/project_root_resolver_test.dart`): temp directory fixture with a `pubspec.yaml` containing `name: fixture_app`; run `ProjectRootResolver.resolve()` from nested subdirectories → returns `(projectRoot: <canonical tempdir>, packageName: 'fixture_app')`. Cover:
  - (a) cwd at root,
  - (b) cwd 3 levels deep,
  - (c) cwd 17 levels deep → returns null (16-level cap),
  - (d) no pubspec anywhere → returns null,
  - (e) malformed `name:` line → returns `(projectRoot: path, packageName: null)`,
  - (f) symlink in path → canonicalised via `resolveSymbolicLinksSync`,
  - (g) unreadable pubspec → returns null without throwing,
  - (h) **double-quoted `name: "foo"`** (H4 fix) → `packageName == 'foo'` (no surrounding quotes captured),
  - (i) **single-quoted `name: 'foo'`** → `packageName == 'foo'`,
  - (j) `name:` with leading whitespace and trailing comment `name:  my_app  # main` → `packageName == 'my_app'`,
  - (k) **256 KiB size cap** (H1 fix): pubspec written as 300 KiB of valid YAML → `lengthSync()` pre-check rejects, returns null without ever reading the body. There is **no** "1-second read budget" test — the prior draft's `Future`-based timeout was unenforceable in synchronous code (F1 lesson) and the size cap replaces it.
  - (l) **lazy-resolution caching** (TR1 fix): construct a `ServiceExtensionRegistry` against a real controller, assert `_cachedHandshake` is null at construction time, call `ext.sleuth.ping` once, assert the cache is populated and a second `ping` call does **not** re-walk the filesystem (use a counting test double of `File.lengthSync`/`readAsStringSync` injected via the resolver's seam, or assert via mtime that the pubspec was touched exactly once across N pings).
- **ProjectRootResolver override:** pass `override: validPath` (with `pubspec.yaml` inside) → short-circuits detection; pass `override: nonexistent` → emits the one-shot warning log and falls through to auto-detection; pass `override: validPath` to a directory whose `pubspec.yaml` is missing → same warning + fall-through. Cover the `SleuthConfig(projectRoot: ...)` path end-to-end by constructing a controller with the override and asserting the first `ping` returns it.
- **ping handshake schema:** call `ext.sleuth.ping` against a controller whose `ProjectRootResolver` resolved to `(projectRoot: '/abs/a', packageName: 'foo')` on first call → response matches the schema-appendix example including `pid` (from `io.pid`). Cover the null-fields case (detection failed) → response still well-formed, just with `projectRoot: null`, `packageName: null`. Cover the **constant-time second call** path: assert the second `ping` response is byte-identical to the first.
- **Root-isolate guard** (M2 fix): construct a `ServiceExtensionRegistry` and stub `developer.registerExtension` to throw `UnsupportedError("must be called from the main isolate")`. Call `register()` → assert it returns without throwing, `_registered` remains `false`, and the one-shot log `[Sleuth] service extension registration skipped: not on root isolate` is emitted exactly once across multiple `register()` calls.
- **Tri-state bypass precedence:**
  - `override = null` + `FLUTTER_TEST` set → skip.
  - `override = true` + `FLUTTER_TEST` unset → skip.
  - `override = false` + `FLUTTER_TEST` set → register (force-register path).
- **Concurrent handler execution:** 50 concurrent invocations while `issuesNotifier` mutates; assert no `ConcurrentModificationError`, every response is a valid snapshot or structured error.
- Param validation: missing required, oversized values, unknown keys, malformed `stableId`.

---

### M2: VM Service URI Discovery File

Create `lib/src/vm/discovery_file.dart` — utility to write/clean up `~/.sleuth/vm_service_uri_<pid>`.

**Modify `vm_service_client.dart`:** After `_connected = true`, call `DiscoveryFile.write(wsUri)`. In `_cleanup()`, call `DiscoveryFile.delete()`.

**Design:**
- Fire-and-forget (async, non-blocking).
- try/catch everything (filesystem errors must not crash the app).
- Guard with `!kIsWeb` and `!kReleaseMode`.
- **One-shot debug log on failure** (fixes adversarial M14): on write failure, emit a single `debugPrint`:
  ```
  [Sleuth] MCP discovery file write failed: <error>. AI assistant auto-discovery may not work; pass --uri manually.
  ```
  Guarded by a static `_warningEmitted` flag so it appears once per session. No throw, no retry.
- File contains the WebSocket URI string only, UTF-8, no trailing newline.
- **Atomic write:** write to `~/.sleuth/vm_service_uri_<pid>.tmp` in the **same directory** as the target, then `rename()` onto the final path.
- **Windows path handling:** `Platform.environment['USERPROFILE']` on Windows vs `HOME` on POSIX; build via `path.join`.
- **`$HOME` / `$USERPROFILE` validation** (fixes adversarial E2): resolve the home value at startup and validate it starts with a known-safe prefix:
  - macOS: `/Users/` or `/var/` (for sandboxed / CI contexts).
  - Linux: `/home/` or `/root/` or `/tmp/` (CI runners).
  - Windows: `C:\Users\` or an alternate drive under `\Users\`.
  If resolution doesn't match any prefix, abort write with a one-shot warning log.
- **Directory must be a regular directory, not a symlink** (fixes adversarial E1): before first write, stat `~/.sleuth/`. If it exists and `statSync().type != FileSystemEntityType.directory` (i.e. it's a symlink or other type), abort with a log message instructing the user to remove the symlink. Prevents redirection into `~/.ssh/` or other sensitive directories.
- **Symlink guard on final path:** before `rename()`, `resolveSymbolicLinks` on the resolved `~/.sleuth/`. If it escapes the validated home prefix, abort.
- **Directory perms:** create `~/.sleuth/` with `0700` on POSIX. If it already exists with different perms, log once and continue (do not chown).
- On reconnect, overwrite. On dispose, delete (best-effort).

**Tests (`test/vm/discovery_file_test.dart`):**
- Temp directory harness: write/overwrite/delete.
- `HOME` / `USERPROFILE` missing → graceful failure, one-shot log.
- `HOME` pointing outside validated prefixes → abort + log.
- `~/.sleuth/` is a symlink → abort + log (no write).
- Target path is a symlink escaping `~/.sleuth/` → write aborts.
- Tmp-rename atomicity: crash between tmp-write and rename → no partial file at final path.
- Windows path composition (mock `Platform.environment`).
- Pre-existing `~/.sleuth/` with `0777` → warns once, does not throw.
- Repeated write failures emit the debug log once (not per-attempt).

---

### M3: Barrel Exports, Version Bump, Docs

- **No new exports** through `lib/sleuth.dart` — `rulesJsonV1` stays package-internal.
- Update `CLAUDE.md` with v0.15.0 description **using v0.14.0's entry as a style template** (elaborate prose + adversarial-review fix callouts).
- Update `CHANGELOG.md` with v0.15.0 section.
- Bump `pubspec.yaml` to `0.15.0`.
- Update `README.md` with "MCP Server" section (setup, tools, Claude Code config example, reference to Response Schemas, list of deferred MCP methods, note on `truncated: true` responses).
- Update test count on completion (estimate ~2,091; re-validate against actual post-implementation count).

**Depends on:** M1, M2.

---

### M4: MCP Server Package Scaffold

Create `packages/sleuth_mcp/` with:

**`pubspec.yaml`:**
```yaml
name: sleuth_mcp
version: 0.1.0
description: MCP server for Sleuth — query live Flutter performance data from AI assistants
environment:
  sdk: '>=3.5.0 <4.0.0'
resolution: workspace
dependencies:
  vm_service: ^14.0.0
  args: ^2.0.0
```

**`bin/sleuth_mcp.dart`:** CLI entry. Parses `--uri` argument. Starts MCP server on stdio.

**`lib/src/mcp_server.dart`:** MCP stdio JSON-RPC 2.0 server. Methods implemented:
- `initialize` / `initialized`
- `ping`
- `tools/list` / `tools/call`
- `resources/list` / `resources/read`

**Deferred** (documented in README): `prompts/*`, `completion/*`, `logging/*`, `$/progress`, `$/cancelRequest`. Any such request returns `{"error": {"code": -32601, "message": "method not implemented"}}`.

**`lib/src/mcp_protocol.dart`:** Request/response/error types. Validate:
- `jsonrpc == "2.0"` (reject otherwise with `-32600`).
- `id` is `string | number | null` (reject object / array).
- Payload size cap: 10 MiB inbound; warn + truncate outbound snapshots > 5 MiB with `{truncated: true, originalSize: N}`.

**`lib/src/vm_bridge.dart`:** Connects to VM service, calls `callServiceExtension('ext.sleuth.*')`, exponential backoff reconnect (1 s → 2 s → 4 s → 8 s → 30 s cap).
- **Connect timeout:** individual attempt 10 s; whole reconnect ladder 5 min cap, then structured error.

- **Identity-verifying liveness probe** (fixes adversarial C5): `scanDiscoveryFiles()` returns `(pid, uri, mtime)` tuples. For each, MCP:
  1. Opens a `VmService` connection (2 s timeout).
  2. Calls `ext.sleuth.ping` (1 s timeout).
  3. Verifies response contains `sleuthOk: true` and a matching `sleuthVersion` shape. Captures `projectRoot` and `packageName` from the handshake for use in selection (both may be null on detection failure — see M1 ping schema).

  Outcomes:
  - **Live-Sleuth** (ping succeeds with `sleuthOk: true`) → eligible for selection. Annotated with `{pid, uri, mtime, projectRoot, packageName}`.
  - **Live-not-Sleuth** (connection opens but ping fails or returns malformed data — e.g. a Flutter app without Sleuth, or a different Sleuth version on port-reuse) → skip; log `{"warning": "vm service at <uri> is not a Sleuth app"}`.
  - **Unresponsive** (connection timeout) → skip; include in diagnostic error.
  - **Dead** (connection refused / reset) → skip.

- **Project-root-aware selection algorithm** (fixes adversarial F2 in the 2026-04-14 investigation):

  The naive "most-recent mtime wins" strategy is broken when the developer is running two Flutter apps at once — e.g. the Sleuth example app in one terminal and their own app in another. Whichever was hot-reloaded most recently claims the MCP session, even if the user invoked the MCP server from inside the *other* project's directory. The fix is to prefer entries whose declared `projectRoot` matches the MCP client's current working directory before falling back to mtime.

  Let `cwd = MCP client's Directory.current (absolute, canonicalised, trailing separator stripped)`. For each live-Sleuth entry compute `matchTier`:

  | Tier | Condition | Meaning |
  |---|---|---|
  | 0 | `entry.projectRoot == cwd` | Exact match — the MCP client is running from the app's project root |
  | 1 | `cwd` is a descendant of `entry.projectRoot` (`cwd.startsWith(entry.projectRoot + separator)`) | Match — MCP invoked from a subdirectory of the project (e.g. `packages/foo`) |
  | 2 | `entry.projectRoot` is a descendant of `cwd` | Match — MCP invoked from a parent directory (e.g. workspace root running the MCP in a subpackage) |
  | 3 | `entry.projectRoot == null` | Degraded handshake — project root unknown |
  | 4 | `entry.projectRoot` is a non-null absolute path that doesn't overlap `cwd` in either direction | Explicit mismatch — different project |

  Selection order:
  1. Partition live-Sleuth entries into the five tiers.
  2. Pick the lowest non-empty tier.
  3. Within the chosen tier, rank by mtime descending and pick the most recent.
  4. If the selected tier is `4` (explicit mismatch only, no `null` entries), log a warning: `"no live Sleuth app matches cwd <path>; connecting to <uri> from project <projectRoot>. Pass --uri to override or invoke from within the target project's directory."`

  Tie-breaks within a tier use mtime. If multiple entries in tier 0 share mtime (< 100 ms apart), break by highest `pid` (arbitrary but deterministic).

  If no live-Sleuth entries exist at all: return `{"error": "no live Sleuth app found", "diagnostics": {"unresponsive": [<uris>], "dead": [<uris>], "not_sleuth": [<uris>]}}` so the user can manually retry or pass `--uri`.

  **Path canonicalisation** — both `cwd` and each `entry.projectRoot` must be passed through `Directory(path).resolveSymbolicLinksSync()` before comparison, so `/private/var/...` vs `/var/...` on macOS doesn't defeat the match. Absorb `FileSystemException` during resolution (treat that entry as tier 3).

  **Case sensitivity** — Linux/Android default filesystems (ext4, f2fs) are case-sensitive; macOS APFS and Windows NTFS are case-insensitive by default. Naive `String.startsWith` compares byte-for-byte, so on macOS the entry `/Users/Alice/proj` against cwd `/users/alice/proj` would miss its own tier-0 match. The fix is small but load-bearing: on macOS/Windows, **lowercase both operands before the `startsWith` check**:
  ```dart
  bool _pathStartsWith(String parent, String child) {
    final p = (Platform.isMacOS || Platform.isWindows) ? parent.toLowerCase() : parent;
    final c = (Platform.isMacOS || Platform.isWindows) ? child.toLowerCase() : child;
    return c == p || c.startsWith(p.endsWith(Platform.pathSeparator) ? p : '$p${Platform.pathSeparator}');
  }
  ```
  (`Platform.pathSeparator` so the trailing-separator guard works on Windows backslashes too.) The same helper handles tier-0 exact match and tier-1/tier-2 descendant checks. Tests cover both case-sensitive (Linux) and case-insensitive (macOS/Windows) branches with an explicit `/A/B` vs `/a/b` fixture per platform.

  **Why tier 2 exists** — a user running `dart run packages/sleuth_mcp/bin/sleuth_mcp.dart` from the workspace root of a monorepo should still be able to auto-discover a Sleuth app whose `projectRoot` is a subpackage beneath them. Tier 2 is strictly lower priority than tier 0/1 so that a subpackage-rooted MCP invocation prefers its own subpackage over a sibling when both are running.

  **Diagnostic logging** — in all cases, log one line per candidate at debug level: `"candidate: uri=<uri> pid=<pid> projectRoot=<path|null> tier=<n> mtime=<iso>"`. Final selection logs `"selected: uri=<uri> projectRoot=<path|null> reason=<tier X, latest mtime>"`. Makes multi-app diagnosis a 5-second grep instead of a guessing game.

  **Logging primitive — H5 fix.** Use the `assert(() { ... return true; }())` idiom rather than a raw `print` or `debugPrint`. The `sleuth_mcp` CLI is a plain Dart console binary and is intended to be quiet by default — every `print` it emits is interleaved with the JSON-RPC response stream on `stdout` and can corrupt MCP framing for buggy clients. The assert-block is stripped by the AOT compiler in `dart compile exe` release output, so production users see no logging while developers running `dart run` (asserts enabled by default) get the full diagnostic trail. Concrete pattern:
  ```dart
  void _logCandidate(String line) {
    assert(() {
      stderr.writeln('[sleuth_mcp] $line');
      return true;
    }());
  }
  ```
  Note the use of `stderr` not `stdout` — `stdout` is reserved for the JSON-RPC wire protocol; `stderr` is the convention every MCP client tolerates for sideband diagnostics.

- **MCP bridge cache flush on disconnect:** when the VmService connection drops, flush all resource caches (see M6).

**Tests:** `test/mcp_protocol_test.dart` (JSON-RPC parsing, size caps, bad `id` types), `test/vm_bridge_test.dart` (mock VmService — connect, backoff, identity probe distinguishing Sleuth from non-Sleuth, port-reuse simulation, timeout, cache flush on disconnect), `test/discovery_selection_test.dart` covering the tier algorithm:
- **Tier 0 exact match:** one entry at `/a/b`, cwd `/a/b` → selected.
- **Tier 1 descendant cwd:** entry `/a/b`, cwd `/a/b/c/d` → selected.
- **Tier 2 ancestor cwd:** entry `/a/b/c`, cwd `/a/b` → selected (monorepo invocation).
- **Tier 2 collision (M3 fix):** two tier-2 entries `/a/b/c` and `/a/b/d` both descended from cwd `/a/b`, mtimes 50 ms apart → selection is non-deterministic by design at the tier level (both equally valid candidates), but the tie-breaker still produces a stable winner: most recent mtime, then highest pid. Test asserts (a) selection succeeds without erroring, (b) the warning log `"multiple tier-2 candidates under cwd <cwd>: [<uri1>, <uri2>]; selected <chosenUri> by mtime — pass --uri or cd into a specific subpackage to disambiguate"` is emitted naming **both** candidate URIs and pids, (c) the selected entry is the one with the more recent mtime (or higher pid on mtime tie). Documents the expected user remediation: `cd packages/foo` and re-invoke, or pass `--uri` explicitly.
- **Tier 0 beats tier 1:** entries `/a/b` (mtime older) and `/a` (mtime newer), cwd `/a/b` → `/a/b` wins despite older mtime.
- **Tier 1 beats tier 3:** entries `/a/b` (null projectRoot, newest mtime) and `/a` (with projectRoot, older mtime), cwd `/a/b/c` → `/a` wins.
- **Tier 3 beats tier 4:** entries with null projectRoot vs entries with mismatching projectRoot → null wins.
- **Tier 4 warning:** only mismatched entries → select most-recent and log the documented warning.
- **Same-tier mtime tie-break:** two tier-0 entries 50 ms apart → pick higher pid for determinism.
- **Case sensitivity:** Linux test with `/A/B` vs `/a/b` → no match; macOS test with same paths → match.
- **Symlink canonicalisation:** entry projectRoot `/private/var/project` vs cwd `/var/project` → tier 0 match after `resolveSymbolicLinksSync`.
- **No live-Sleuth entries:** structured error with diagnostics dict.

---

### M5: MCP Tools

Implement 7 tools in `packages/sleuth_mcp/lib/src/tools/`:

| Tool | Input | Calls | Returns |
|------|-------|-------|---------|
| `connect` | `uri?: string` | Auto-discover (identity probe) or connect to URI | `{connected: bool, extensions: [string], uri: string}` |
| `get_snapshot` | — | `ext.sleuth.getSnapshot` | Full snapshot JSON (may include `truncated: true`) |
| `get_issues` | `route?: string` | `ext.sleuth.getIssues` | Issues array |
| `get_route_health` | `route?: string` | `ext.sleuth.getRouteHealth` | Route health array |
| `explain_issue` | `stableId: string` | `ext.sleuth.explainIssue` | Encyclopedia + causal chain |
| `compare_snapshots` | `before: object, after: object` | **Pure diff** (no file I/O) | Diff structure |
| `check_budgets` | `min_fps?: number, max_critical?: number, max_warning?: number` | `getIssues` + `getFrameStats` | Pass/fail per budget |

**`compare_snapshots` input validation:**
- Reject non-object inputs (arrays, scalars, null) with `{"error": "before/after must be snapshot objects"}`.
- Reject objects missing required top-level fields (`schemaVersion`, `sleuthVersion`, `issues`, `fps`). Minimal fingerprint check — don't deep-validate.
- **Per-argument size cap of 5 MiB** (fixes adversarial M16) — enforced before diffing. Reject with `{"error": "snapshot exceeds 5 MiB; capture smaller window"}`. Keeps peak memory bounded.
- **Nesting-depth cap of 32** (fixes adversarial M11) — reject with `{"error": "input exceeds max nesting depth"}`. Prevents stack overflow on adversarial recursive input.
- `schemaVersion` mismatch between `before` and `after` → warn in result (`{"warning": "schema version mismatch: before=3, after=4"}`), do not error. The diff proceeds field-by-field with best effort.
- **Output:** `{fpsDelta: number, newIssues: [...], resolvedIssues: [...], persistentIssues: [...], schemaVersionMatch: bool}`.

**Other tool input validation:**
- `explain_issue` with unknown `stableId` → `{"known": false, "stableId": "..."}`.
- `check_budgets` with negative / NaN / string thresholds → `{"error": "invalid threshold", "field": "min_fps"}`.
- `get_issues` with route pattern that throws in filter → catch, return unfiltered with `{"filterError": "..."}`.
- Tool call before `connect` succeeded → `{"error": "not connected; call connect first"}`.

**Tests:** one test file per tool with mocked VmBridge. For `compare_snapshots`: object-shape validation, non-object inputs, missing fields, schema version mismatch warning, oversized objects, deeply nested input rejection, plus a **golden-file test** that diffs two real snapshot JSON files captured from the example app.

---

### M6: MCP Resources

Implement 2 resources in `packages/sleuth_mcp/lib/src/resources/`:

| Resource URI | Calls | Cache |
|-------------|-------|-------|
| `sleuth://encyclopedia` | `ext.sleuth.getEncyclopedia` | TTL 10 min + flush on disconnect |
| `sleuth://causal-graph` | `ext.sleuth.getCausalGraph` | TTL 10 min + flush on disconnect |

**Cache invalidation:** flush both caches when `VmBridge` emits `onDisconnect`. Prevents serving stale data after hot restart brings up a different Sleuth version.

**Tests:** caching, TTL expiry, explicit invalidation on disconnect, error when not connected.

---

### M7: Integration Test & Documentation

- `packages/sleuth_mcp/README.md` — setup, tool reference, Claude Code config example, list of deferred MCP methods, Response Schemas reference, note on `truncated: true` handling, optional-field table.
- Manual integration test script: start example app → connect MCP → send tool calls → validate.
- `packages/sleuth_mcp/example/claude_code_config.json`:

```json
{
  "mcpServers": {
    "sleuth": {
      "command": "dart",
      "args": ["run", "packages/sleuth_mcp/bin/sleuth_mcp.dart"]
    }
  }
}
```

**Depends on:** M4, M5, M6.

---

### M7a: Release-Mode Smoke Test (numbered gate)

Promoted from a M7 bullet to its own numbered milestone so it can't be skipped (fixes adversarial M12).

1. Build the example app in release mode: `cd example && fvm flutter build apk --release` (or equivalent per target platform).
2. Launch the built binary.
3. Verify on the host machine:
   - **No `~/.sleuth/` directory was created** (or if it already existed, no new `vm_service_uri_*` file was added).
   - Running `dart run packages/sleuth_mcp/bin/sleuth_mcp.dart` with no `--uri` returns `{"error": "no live Sleuth app found"}` (AOT release binary has no VM service).
4. Document the result in the PR description.

**Exit criteria:** all three checks pass. This is the load-bearing release-mode verification; the two in-code `kReleaseMode` guards are backed by this observational test, not by a source-file grep.

**Depends on:** M7.

---

### M8: Invoke `/adversarial-review` on the completed implementation

**Effort:** Medium | **Theme:** Quality gate | **Impact:** P0 — work is not done until this passes.

**This is the ONLY `/adversarial-review` invocation during implementation.** The plan itself was already reviewed during planning (see the Plan Review Pass section — those were authoring-time reviews, already complete, NOT to be re-run during implementation). The Adversarial Review Scope section below is the **scope for this single M8 invocation**, not a separate action.

This milestone is a tool invocation, not a code change. It runs automatically after M7a — do not wait for user approval, do not present a final summary first.

- After M0–M7a pass (`fvm flutter test`, `fvm flutter analyze`, `cd packages/sleuth_mcp && dart test && dart analyze` all clean; M7a release smoke passes), invoke the `/adversarial-review` Skill tool **once**, passing the scope defined in "Adversarial Review Scope" below.
- Fix every Critical/High finding immediately using `/flutter-expert`. Fix Medium findings by default unless cost is high. Re-run tests after fixes.
- Attack the fixes themselves for second-order regressions.
- Only after all Medium+ findings are resolved is v0.15.0 considered complete and ready for a release summary.

## Response Schemas (locked contracts)

All schemas committed as v0.15.0 contracts. Each response carries an independent `schemaVersion` (fixes adversarial M17) — the export envelope's version and `getCausalGraph`'s rule-set version bump independently.

**Field optionality legend** (fixes adversarial H9):
- **required** — always present in well-formed responses
- **optional** — may be absent (e.g. feature not instrumented, empty window)
- **nullable** — present but value may be `null` (e.g. insufficient data)

Enforcement: each schema has a fixture at `test/fixtures/response_schemas/<extension>.json` (or `packages/sleuth_mcp/test/fixtures/...` for tool responses) and a conformance test (M1) asserts live output matches.

### Service extension responses

#### `ext.sleuth.ping`
```jsonc
{
  "sleuthOk": true,                      // required, always true when Sleuth is active
  "sleuthVersion": "0.15.0",             // required
  "pid": 12345,                          // required — `pid` matches the discovery-file filename suffix
  "projectRoot": "/Users/h/code/myapp",  // nullable — absolute path to the directory containing pubspec.yaml. null if auto-detection failed AND no override was provided via SleuthConfig(projectRoot: ...)
  "packageName": "my_app"                // nullable — value of `name:` in pubspec.yaml. null on detection failure
}
```

**Handshake resolution** (happens **lazily on the first `ext.sleuth.ping` invocation** per registry instance — see TR1 in M1; the result is cached on the registry instance for the lifetime of the isolate, so subsequent pings are constant-time):

1. If the user passed `SleuthConfig(projectRoot: '/abs/path')` explicitly (and that config was passed into `Sleuth.track()` / `SleuthController(config:)`), use that path verbatim. Validate it exists and contains `pubspec.yaml`; if not, log a one-shot warning and fall through to auto-detection.
2. Auto-detect: start at `Directory.current` and walk upward looking for a `pubspec.yaml`. Stop at the first match, at the filesystem root, or after 16 levels (safety cap against symlink loops).
3. If `pubspec.yaml` is found, enforce a 256 KiB size cap via `lengthSync()` first (rejects pathological files before any read), then read with `readAsStringSync()` and scan line-by-line for the regex `^name:\s*["']?([a-z_][a-z0-9_]*)["']?\s*$` (the optional `["']?` handles legal-but-uncommon quoted names like `name: "my_app"`). Populate `projectRoot` (canonicalised absolute path of the directory via `resolveSymbolicLinksSync`) and `packageName` (the regex capture group, **without** quotes).
4. On any failure (no `pubspec.yaml` within 16 levels, unreadable file, size-cap exceeded, malformed `name:`, symlink loop, filesystem exception), both fields are set to `null`. The handshake never throws — a degraded handshake still lets M4's selection algorithm route the entry to tier 3.

**Why lazy-on-first-ping not `Sleuth.init()`:** `Sleuth.init()` is the optional TTFF helper, not the main entry, and the typical user path through `Sleuth.track()` skips it entirely. Resolving at init time would also block synchronously inside `SleuthController.initialize()` and inflate the very TTFF window the `slow_startup_ttff` detector calibrates against — Sleuth accusing itself of slow startup. The first `ping` already happens after the app is interactive (MCP discovery only fires once a developer asks for it), so the resolver runs once on a thread that is not on the cold-start critical path.

**Why `ping` not `getSnapshot`:** selection happens before any tool call, so the handshake must be cheap. Adding these two strings to `ping` (after the lazy first-call resolution) is constant-work for every subsequent call; requiring the MCP bridge to call `getSnapshot` just to learn the project root would defeat the point.

#### `ext.sleuth.getSnapshot`

**Literal mirror of `SessionSnapshot.toJson()`** — field names, nesting, and types match `lib/src/models/session_snapshot.dart`'s `toJson()` method byte-for-byte. Any future change to `SessionSnapshot.toJson()` is a breaking change to this extension and MUST bump `schemaVersion`. Fixtures (see M1) are **generated** by running `exportSnapshot().toJsonString()` on a test controller, not hand-authored — this guarantees that schema-conformance tests cannot drift from the real exporter.

Rationale: the prior draft of this schema invented field names (`sleuthVersion`, `capturedAtMs`, `issues`, `fps.*`, `frameStats.shaderCompileFrames`) that do not exist in `SessionSnapshot.toJson()`, flattened fields that live inside `sessionSummary`, and omitted ~11 real fields. A "mirror" that does not mirror is worse than no contract — it forces MCP handlers to hand-map between two schemas, and any mapping table is a source of silent drift. The rule is now: **if the handler returns anything other than `jsonEncode(exportSnapshot().toJson())` plus the `truncated` flag described below, it is a bug.**

```jsonc
{
  "schemaVersion": 4,                           // required — matches SessionSnapshot.schemaVersion
  "exportedAt": "2026-04-14T12:34:56.789Z",     // required — ISO-8601 UTC string
  "packageVersion": "0.15.0",                   // required — Sleuth package version
  "isVmConnected": true,                        // required
  "isDebugMode": true,                          // required
  "frameStatsSummary": {                        // required
    "totalFrames": 1204,                        // required
    "jankFrames": 18,                           // required
    "averageFps": 58.2,                         // required (1 decimal, clamped to config.fpsTarget)
    "worstFrameTimeUs": 34567,                  // required
    "fpsPercentiles": {                         // optional — absent when live buffer has < 2 frames
      "p50": 60.0,                              //   required when present (NOTE: p95 not p90)
      "p95": 52.1,                              //   required when present
      "p99": 31.4                               //   required when present
    }
  },
  "capturedFrames": [                           // required (empty array if none; bounded at JankCaptureBuffer.capacity = 50)
    {                                           // Each entry mirrors CaptureEntry.toJson()
      "frameStats":   { /* FrameStats.toJson()       */ },
      "verdict":      { /* FrameVerdict.toJson() minus relatedIssues */ },
      "relatedIssues": [ /* PerformanceIssue[] — see getIssues issue shape */ ],
      "capturedAt":   "2026-04-14T12:34:55.678Z"
    }
  ],
  "currentIssues": [ /* PerformanceIssue[] — see getIssues issue shape */ ],  // required

  // All fields below are **optional** — `SessionSnapshot.toJson()` uses `if (x != null && x.isNotEmpty)`
  // guards so a cold-start or lightly-instrumented app legitimately omits them.
  "recentRequests":        [ /* RequestRecord.toJson()         */ ],  // optional — absent if network monitor disabled or no records
  "heapSamples":           [ /* HeapSample.toJson()            */ ],  // optional — absent if VM not connected (bounded at MemoryPressureDetector window)
  "suppressedCount":       0,                                          // optional — emitted only when > 0
  "phaseEvents":           [ /* PhaseEvent.toJson()            */ ],  // optional — bounded at 100
  "gcEvents":              [ /* GcEventSummary.toJson()        */ ],  // optional — bounded at 50
  "platformChannelEvents": [ /* PlatformChannelSummary.toJson()*/ ],  // optional — bounded at 50
  "recentFrames":          [ /* FrameStats.toJson()            */ ],  // optional — bounded at FrameStatsBuffer.capacity = 60
  "widgetHeatMap":         [ /* WidgetHeatMapEntry.toJson()    */ ],  // optional — bounded by issue list size
  "recurrenceTrends": {                                                // optional — map keyed by stableId
    "<stableId>": { /* per-id trend summary map from RecurrenceTrend.toJson() */ }
  },
  "sessionSummary": {                                                  // optional — pre-computed summary (v3+)
    "topIssues":          ["widget_rebuild_storm:MyPage:123"],         //   NOTE: nested, NOT top-level
    "causalEdges":        [{"cause": "layout_bottleneck", "effect": "sustained_jank"}],
    "frameHistogram":     {"0-16": 1102, "16-33": 84, "33-50": 15, "50+": 3},
    "detectorHitRates":   {"widget_rebuild_storm": 0.42},
    "memoryTrendSummary": {"samples": 240, "peakMb": 312.4, "trend": "stable"}
  },
  "startupMetrics": { /* StartupMetrics.toJson() — see appendix */ },  // optional — absent when Sleuth.init() was not called
  "routeSessions": [ /* RouteSession.toJson()[] — see getRouteHealth */ ],  // optional — absent when _routeHistory is empty

  // MCP-only envelope fields — see "Bounded handler work" in M1.
  "truncated":       false,                        // optional — present iff payload exceeded the 5 MiB wire cap
  "truncatedReason": "payload_exceeds_5mib",       // optional — present iff truncated=true
  "truncatedFields": ["capturedFrames","recentFrames","heapSamples"]  // optional — present iff truncated=true; names of lists trimmed to fit under cap
}
```

**Legacy (removed) field → real-field mapping** for reviewers cross-checking the prior draft:

| Prior draft | Real `toJson()` | Notes |
|---|---|---|
| `sleuthVersion` | `packageVersion` | Same value, corrected name |
| `capturedAtMs` (epoch ms int) | `exportedAt` (ISO-8601 string) | |
| `issues` | `currentIssues` | |
| `fps.current`, `fps.target` | — | Not emitted by `SessionSnapshot.toJson()`. Use `ext.sleuth.getFrameStats` for FPS-only queries. |
| `fps.p50`, `fps.p90`, `fps.p99` | `frameStatsSummary.fpsPercentiles.{p50, p95, p99}` | Real field uses **p95**, not p90 |
| `frameStats.totalFrames/jankFrames` | `frameStatsSummary.totalFrames/jankFrames` | Nested under `frameStatsSummary` |
| `frameStats.shaderCompileFrames` | — | **Never existed** — `FrameStats` does not track this. Removed. |
| top-level `topIssues` | `sessionSummary.topIssues` | Nested under `sessionSummary`, not top-level |
| top-level `causalEdges` | `sessionSummary.causalEdges` | Nested |
| top-level `frameHistogram` | `sessionSummary.frameHistogram` | Nested |
| top-level `detectorHitRates` | `sessionSummary.detectorHitRates` | Nested |
| top-level `memoryTrendSummary` | `sessionSummary.memoryTrendSummary` | Nested |
| — | `isVmConnected`, `isDebugMode`, `recentRequests`, `heapSamples`, `suppressedCount`, `phaseEvents`, `gcEvents`, `platformChannelEvents`, `recentFrames`, `widgetHeatMap`, `recurrenceTrends` | **11 real fields** the prior draft silently dropped |

#### `ext.sleuth.getIssues`

**Literal mirror of `PerformanceIssue.toJson()`** per entry — every field, every enum value, every optionality match `lib/src/models/performance_issue.dart`'s `toJson()` method. Fixtures are generated from live `exportSnapshot().currentIssues`, not hand-authored.

**Optional `route` param.** When provided, filters the `issues` array to entries whose **raw `routeName` equals `route`** (string equality, no `(tab-N)` suffix stripping — raw is authoritative). To filter a specific tab visit, combine with the optional `scaffoldHashKey` and `tabVisitIndex` params described below.

**Optional `scaffoldHashKey` param** (int, only meaningful when `route` is also set). Filters to issues stamped with this exact `scaffoldHashKey`, disambiguating tabs in IndexedStack / StatefulShellRoute.indexedStack / CupertinoTabScaffold shells.

**Optional `tabVisitIndex` param** (int, only meaningful when `route` + `scaffoldHashKey` are both set). Filters to issues from that specific visit ordinal. Without this param, all visits to the same `(route, scaffoldHashKey)` pair are returned merged.

Display labels (including `(tab-N)` suffix for 2nd+ visits) are derived client-side via `PerformanceIssue.routeDisplayName`'s rule: `tabVisitIndex > 1 ? "$routeName (tab-$tabVisitIndex)" : routeName`. The extension never bakes the suffix into `routeName` — matching `performance_issue.dart:200`.

```jsonc
{
  "issues": [                                   // required (empty array if none)
    {
      // --- Required fields (always present in PerformanceIssue.toJson()) ---
      "severity":  "warning",                   // required — enum: "ok" | "warning" | "critical"
      "category":  "build",                     // required — enum: "build" | "layout" | "paint" | "raster" | "memory" | "channel" | "font" | "network" | "startup" (9 values, matches IssueCategory)
      "confidence":"likely",                    // required — enum: "confirmed" | "likely" | "possible"
      "title":     "MyPage rebuilt 47 times in 2s",  // required — short human-readable title
      "detail":    "Observed 47 rebuilds in the last 2 s, dominated by setState in MyPage.build.",  // required — long description
      "fixHint":   "Wrap the counter in a ValueListenableBuilder …",  // required
      "debugModeDisclaimer": true,              // required — whether this detection's accuracy is reduced in debug mode

      // --- Optional identity / provenance fields (present when available) ---
      "stableId":  "rebuild_debug_MyPage",      // optional — stable across scan cycles; missing for custom detectors with no stableId
      "widgetName":"MyPage",                    // optional
      "routeName": "/home",                     // optional — RAW route name; use routeDisplayName on the client for display
      "observationSource":  "debugCallbackAndStructural",  // optional — enum: "structural" | "vmTimeline" | "debugCallback" | "debugCallbackAndStructural"
      "interactionContext": "scrolling",        // optional — enum: "idle" | "scrolling" | "navigating" | "typing" | "appLifecycle"
      "detectedAt": "2026-04-14T12:34:56.789Z", // optional — ISO-8601 UTC
      "ancestorChain": "ListView > Column > Row > Text",  // optional — widget ancestor chain
      "fixEffort": "quick",                     // optional — enum: "quick" | "medium" | "involved"
      "topAllocators": [ /* AllocationEntry[] */ ],  // optional — present only for heap issues with allocation profile
      "rankingScore":    78,                    // optional — populated at export time by IssueRanker
      "rankingBreakdown":{"severity": 40, "frameImpact": 20, "confidence": 10, "recurrence": 8},  // optional — matches rankingScore presence
      "rootCauseId":     "layout_bottleneck",   // optional — set by CausalGraphRule when this issue is downstream
      "downstreamIds":   ["sustained_jank"],    // optional — set by CausalGraphRule when this issue is a root
      "confidenceReason":"Debug callback data confirmed structural finding", // optional — human-readable reason for confidence level
      "packageName":     "my_app",              // optional — extracted from leaf element's source location

      // --- Per-tab disambiguation (v0.14.1+, populated when route tracking is active) ---
      "scaffoldHashKey": 483920,                // optional — identityHashCode of innermost visible Scaffold Element
      "tabVisitIndex":   2                      // optional — 1-indexed ordinal for repeat visits to the same (routeName, scaffoldHashKey)
    }
  ],
  "truncated": false                            // optional — see "Bounded handler work" in M1
}
```

**Category enum correction.** The prior draft's enum (`build|paint|raster|network|memory|startup|structural`) was wrong in three ways — it invented `structural` (which is an `ObservationSource`, not an `IssueCategory`), and omitted `layout`, `channel`, and `font`. The real enum from `lib/src/models/performance_issue.dart:7-17` is: `build, layout, paint, raster, memory, channel, font, network, startup` (9 values). Conformance tests MUST `IssueCategory.values.byName(...)` against these exactly.

**Fields dropped from the prior draft:**

| Prior draft | Real `toJson()` | Notes |
|---|---|---|
| `message` (single string) | `title` (required) + `detail` (required) | Two separate strings, not one |
| `route` | `routeName` | |
| `sourceLocation: {file, line, packageName}` | `ancestorChain: String?` + top-level `packageName: String?` | No nested `sourceLocation` object; no per-issue `file`/`line` |
| `recurrence: {count, firstSeenMs, lastSeenMs}` | — | Not a per-issue field. Per-stableId recurrence lives at the snapshot level under `recurrenceTrends`, keyed by `stableId`, emitted by `RecurrenceTrend.toJson()`. |
| — (missing from prior draft) | `widgetName`, `observationSource`, `interactionContext`, `debugModeDisclaimer`, `detectedAt`, `ancestorChain`, `fixEffort`, `topAllocators`, `rankingScore`, `rankingBreakdown`, `rootCauseId`, `downstreamIds`, `packageName`, `scaffoldHashKey`, `tabVisitIndex` | **15 real fields** the prior draft silently dropped, including all v0.14.1 per-tab fields |

#### `ext.sleuth.getFrameStats`

Hand-authored **read-only view** derived from `FrameStatsBuffer` + `SleuthConfig.fpsTarget`. This is the one schema that does **not** mirror a real `toJson()` method — it is a lightweight convenience endpoint for MCP clients that want FPS without fetching a full snapshot. Handler constructs the response from the live frame buffer directly and returns it via `_safeJsonEncode`.

```jsonc
{
  "fps": {                                // required
    "averageFps": 58.2,                   // required — matches FrameStatsBuffer.averageFps (clamped to 120)
    "p50": 60.0,                          // nullable — null when buffer has < 2 frames (FpsPercentiles unavailable)
    "p95": 52.1,                          // nullable — **p95, not p90** (matches FpsPercentiles.p95 at frame_stats.dart:256)
    "p99": 31.4,                          // nullable
    "target": 60                          // required — SleuthConfig.fpsTarget
  },
  "totalFrames":     1204,                // required — FrameStatsBuffer.length
  "jankFrames":      18,                  // required — FrameStatsBuffer.jankCount
  "bufferCapacity":  60,                  // required — FrameStatsBuffer.capacity; MCP clients can use this to judge sample window without needing a timestamp math
  "frameBudgetMs":   16                   // required — derived from fpsTarget (60 fps → 16)
}
```

**Drifts corrected from prior draft:** (a) `fps.current` renamed to `fps.averageFps` to match the real `FrameStatsBuffer.averageFps` getter name; (b) `fps.p90` replaced with `fps.p95` — `FpsPercentiles` tracks p50/p95/p99, never p90; (c) `shaderCompileFrames` **removed** — `FrameStats` / `FrameStatsBuffer` do not track this (shader jank is handled by a separate `ShaderJankDetector` that surfaces issues, not a frame count); (d) `sampleWindowMs` replaced with `bufferCapacity` + `frameBudgetMs`, which are directly derivable from the real buffer.

#### `ext.sleuth.getRouteHealth`

**Literal mirror of `RouteSession.toJson()`** from `lib/src/models/route_session.dart:130-175`. Each entry in `routes[]` is the output of that method verbatim. Fixtures are generated from `controller.routeHistoryForTest` after driving a multi-tab test widget, not hand-authored.

Optional `route` param filters entries to those whose RAW `routeName` equals `route` (string equality; display-name suffix is NOT matched). Optional `scaffoldHashKey` param narrows further to a single tab identity.

```jsonc
{
  "routes": [                                // required (empty array if no routes tracked)
    {
      "routeName":       "/home",            // required — RAW route name; use (routeName, tabVisitIndex) to build display label
      "scaffoldHashKey": 483920,             // optional — identityHashCode of innermost visible Scaffold; absent for scaffold-free scans
      "tabVisitIndex":   1,                  // required — 1-indexed ordinal of repeat visits to the same (routeName, scaffoldHashKey) pair
      "hotReloadGeneration": 0,              // optional — debug-only; absent/0 in release/profile (emitted only when > 0)
      "startedAt":       "2026-04-14T12:34:00.000Z",  // required — ISO-8601 UTC
      "endedAt":         "2026-04-14T12:34:12.400Z",  // optional — absent while the session is still active
      "healthScore":     87,                 // required — 0-100 composite from FPS + jank + issues (see route_session.dart:93 for formula)
      "durationSeconds": 12,                 // required — integer seconds (NOT ms — matches Duration.inSeconds)
      "scanCycles":      40,                 // required — number of scan cycles completed while this route was active
      "frameStats": {                        // required
        "totalFrames": 720,                  // required — per-route FrameStatsBuffer.length
        "jankFrames":  4,                    // required
        "averageFps":  58.1,                 // required — clamped to config.fpsTarget
        "p50":         60.0,                 // optional — only present when frameStats.length >= 2
        "p95":         52.1,                 // optional — same condition
        "p99":         31.4                  // optional — same condition
      },
      "issueCount":    2,                    // required — unique stableIds observed while this route was active
      "criticalCount": 1,                    // required
      "warningCount":  1,                    // required
      "issues": ["layout_bottleneck", "sustained_jank"]  // required — stableIds only (full issue bodies live in getIssues / getSnapshot.currentIssues)
    }
  ]
}
```

**Client-side display rule** (from `performance_issue.dart:200`): if `tabVisitIndex > 1`, render as `"$routeName (tab-$tabVisitIndex)"`; otherwise render `routeName` as-is. The extension never bakes the suffix into `routeName` — baked suffixes would poison group-by-route filters and make a route literally named `"/x (tab-2)"` indistinguishable from a disambiguated tab-2 of `"/x"`.

**Per-tab semantics.** In apps using `IndexedStack`, `StatefulShellRoute.indexedStack`, or `CupertinoTabScaffold`, every tab shares one `ModalRoute` but owns its own `Scaffold` Element. Sleuth keys each `RouteSession` on the compound `(routeName, scaffoldHashKey)` pair, so each tab produces a distinct entry in `routes[]`. Inline `TabBar` / `TabBarView` / `PageView` swipes within a single route do NOT create new entries — they stay inside the outer route's session (controller visitor filters these widgets out of the scaffold boundary walk, see `sleuth_controller.dart` scan visitor).

**Drifts corrected from prior draft:**

| Prior draft | Real `RouteSession.toJson()` | Notes |
|---|---|---|
| `route` | `routeName` | |
| `durationMs` (ms int) | `durationSeconds` (seconds int) | Real field is `duration.inSeconds` |
| `startedAtMs` (epoch ms int) | `startedAt` (ISO-8601 string) | |
| top-level `fpsAverage` | `frameStats.averageFps` | Nested under `frameStats` |
| top-level `jankFrames` | `frameStats.jankFrames` | Nested |
| — | `endedAt`, `scanCycles`, `frameStats.totalFrames`, `frameStats.{p50,p95,p99}`, `criticalCount`, `warningCount`, `issues[]` | **7 real fields** the prior draft silently dropped |

#### `ext.sleuth.getEncyclopedia`

**Literal mirror of the `IssueExplanation` record** from `lib/src/utils/issue_explanation_builder.dart:4-13`. Fixtures are generated by walking `IssueExplanationBuilder.allExplanations` on the controller, not hand-authored.

Each entry uses the four-way content split that the real encyclopedia surfaces in-app (guide page, issue card shimmer, AI chat context substitution): `whatItIs` / `whyItMatters` / `howToFix` / `whenToIgnore`. The prior draft collapsed this into a single `description` string and replaced `howToFix` with a `fixSteps[]` array — both of which are misleading (the real field is a prose string, not a list, and `whenToIgnore` is a distinct field that false-positive-sensitive clients must surface independently).

```jsonc
{
  "entries": [                                  // required
    {
      "id":             "widget_rebuild_storm", // required — base stableId (dynamic suffixes stripped)
      "displayName":    "Widget Rebuild Storm", // required — matches IssueExplanation.displayName
      "category":       "build",                // required — same 9-value IssueCategory enum as getIssues
      "whatItIs":       "…",                    // required — non-empty prose describing the condition
      "readingTheData": "…",                    // optional — nullable in IssueExplanation; emitted only when non-null
      "whyItMatters":   "…",                    // required — non-empty prose describing user/performance impact
      "howToFix":       "…",                    // required — prose string (may contain newlines / bullet markers); NOT an array
      "whenToIgnore":   "…",                    // optional — nullable; present only for entries with documented false-positive guidance
      "relatedIssues":  ["shallow_rebuild_risk"]// optional — nullable in IssueExplanation; emitted only when non-null (may be empty array)
    }
  ]
}
```

**Drifts corrected from prior draft:**

| Prior draft | Real `IssueExplanation` | Notes |
|---|---|---|
| `title` | `displayName` | Rename |
| `description` (single required string) | `whatItIs` (required) + `whyItMatters` (required) + `whenToIgnore` (nullable) | Three separate fields — consumers show them in different UI slots |
| `fixSteps: string[]` (required) | `howToFix: String` (required prose) | **Type mismatch fixed** — the real field is a single prose string, not an array. A spec-conformant client iterating `fixSteps` would crash. |
| `readingTheData` required | `readingTheData: String?` (nullable) | Optionality corrected |
| `relatedIssues` required | `relatedIssues: List<String>?` (nullable) | Optionality corrected |
| — | `whenToIgnore` | **Real field dropped** from the prior draft entirely — false-positive guidance was invisible to MCP consumers |

#### `ext.sleuth.explainIssue`
```json
{
  "known": true,                         // required
  "stableId": "widget_rebuild_storm:MyPage:123",  // required
  "encyclopediaEntry": { /* full entry, see above */ },  // required if known=true, absent if known=false
  "activeCausalEdges": [                 // required (empty array if no active edges)
    { "cause": "shallow_rebuild_risk", "effect": "widget_rebuild_storm" }
  ]
}
```

#### `ext.sleuth.getCausalGraph`
```json
{
  "schemaVersion": 1,                    // required
  "rules": [                             // required
    { "cause": "layout_bottleneck", "effect": "jank_runtime" }
    // Rule shape locked at v1: exactly {cause: string, effect: string}.
    // Adding fields requires schemaVersion: 2.
  ]
}
```

### Tool responses

MCP tool responses wrap extension responses in the standard MCP envelope:
```json
{"content": [{"type": "text", "text": "<JSON-stringified>"}], "isError": false}
```

Special tool-level shapes:
- `connect` → `{"connected": true, "extensions": ["ext.sleuth.getSnapshot", ...], "uri": "ws://127.0.0.1:12345/abc/ws"}`
- `compare_snapshots` → `{"fpsDelta": 2.4, "newIssues": [...], "resolvedIssues": [...], "persistentIssues": [...], "schemaVersionMatch": true}`
- `check_budgets` → `{"pass": false, "violations": [{"budget": "min_fps", "threshold": 55, "actual": 52.1}]}`

### Resource responses
MCP resources return the extension response JSON as the resource body, `mimeType: "application/json"`.

## Milestone Dependency Graph

```
M0 (Workspace Scaffold) ──► M4 (MCP Scaffold)     [HARD]
M0 ──► all other milestones                        [SOFT — build sanity]

M1 (Service Extensions) ──► M3 (Exports + Docs)
M2 (Discovery File)    ───►

M4 (MCP Scaffold) ──► M5 (Tools)     ──┐
                  ──► M6 (Resources) ──┤
                                        ├──► M7 (Integration + Docs) ──► M7a (Release Smoke) ──► M8 (/adversarial-review)
```

M1 and M2 are structurally independent of M0 (they only modify the main package) but share M0's build-sanity precondition. M4 hard-depends on M0 (workspace wiring). M5/M6 depend on M4. M7a is a gate that must pass before M8.

**Recommended sequence:** M0 → M1 → M2 → M3 → M4 → M5 → M6 → M7 → M7a → M8.

## Adversarial Review Scope

> **This section defines the scope for M8's single post-implementation `/adversarial-review` invocation — it is NOT a separate invocation.** Each bullet is an attack surface the M8 review must probe; fix all Medium+ findings before declaring v0.15.0 done.

1. **Service extension safety** — unhandled exceptions in any of the 8 handlers; release-mode leakage; double-registration on hot restart; handler latency p95 exceeding the 50 ms serialization budget on a saturated controller (the replacement for the abandoned 500 ms wall-clock design — see F1); unbounded growth of any new buffer breaking the fixed-capacity invariant; **two-stage 5 MiB wire-size cap drop-order correctness — stage 1 primary drop, stage 2 within-minimum-set trim (`currentIssues → top 50`, `routeSessions → last 10`), stage 3 final fallback (`{partialData: currentIssues[0..4]}`)**; param parsing on malformed input; rate-limiter bypass via parallel invocations; tri-state bypass precedence (explicit flag vs env); JSON-encode helper correctness on edge-case types (null, deeply nested, circular references); **`ProjectRootResolver` lazy-on-first-ping caching (TR1) — verify the resolver is NOT invoked during `SleuthController.initialize()` and that TTFF is unaffected, verify the cache is populated exactly once per registry instance, verify subsequent pings touch zero filesystem syscalls**; **root-isolate guard (M2) — verify `registerExtension` failure on a spawned isolate is swallowed with a one-shot log and the main isolate's registry is unaffected**; `ProjectRootResolver` auto-detection edge cases (16-level cap, 256 KiB size cap, malformed pubspec, quoted/unquoted name regex, unreadable file, symlink loops, override validation, `SleuthConfig.projectRoot` plumbing through `copyWith`).
2. **Discovery file** — symlink attacks, stale PID files, race between app write and MCP scan, permission errors, iOS sandbox behavior, concurrent writes from multiple isolates, filesystem full, `$HOME`/`$USERPROFILE` injection, torn reads, Windows path separator bugs, `~/.sleuth/` pre-existing as a symlink.
3. **VM service client lifecycle** — discovery file written but WebSocket drops; hot restart overwrite ordering; dispose-during-connect race; `_cleanup` not called on SIGKILL; reconnect ladder duplicate files; corpse PID + port reuse serving a non-Sleuth app (identity probe must catch this).
4. **MCP protocol layer** — malformed JSON-RPC, oversized payloads, stdin close mid-request, concurrent `tools/call` on single VmService connection, reconnect backoff starvation, stdout buffering deadlock, head-of-line blocking.
5. **Tool input validation** — `compare_snapshots` with non-object inputs, missing fields, 5 MiB per-arg cap, 32-level nesting cap, schema-version mismatch; `explain_issue` with unknown `stableId`; `check_budgets` with invalid thresholds; `get_issues` with filter that throws; tool call before `connect`.
6. **Multi-app collisions** — two apps writing PID files simultaneously; MCP auto-discovery picking wrong app despite identity probe; URI change after hot restart not reflected in bridge cache; liveness probe false positives / negatives including the live-not-Sleuth case; `port reuse` regression across test iterations; **5-tier selection algorithm correctness** (F2) — tier 0 beats tier 1, tier 1 beats tier 3, tier 3 beats tier 4, **case-insensitive `_pathStartsWith` implementation correctness on macOS/Windows (lowercase both operands) vs raw `startsWith` on Linux (H3 fix)**, **trailing-separator handling so `/a/b` does not falsely match `/a/banana`**, symlink canonicalisation (`/private/var/*` on macOS), tier-4 warning log present, same-tier mtime tie-breaks, **tier-2 collision (M3 fix) — two subpackage entries under the same cwd both qualify; warning log must name both candidate URIs/pids and recommend `cd <subpackage>` or `--uri`**, **assert-block stderr logging (H5 fix) — verify `dart compile exe` strips the assert and AOT release builds emit no diagnostic noise on stdout**.
7. **Data staleness & consistency** — MCP returns cached encyclopedia after hot reload; route history cleared between calls; `rulesJsonV1` static cache consistency; cache flush on disconnect actually fires.
8. **Release mode end-to-end** — M7a manual smoke covers the happy path; review should probe adjacent concerns like partial AOT builds, `flutter run --release` on desktop (where VM service might still run), and release builds that accidentally still import `dart:developer`.
9. **Causal graph v1 contract** — every rule round-trips through `{cause, effect}`; rules with extra fields violate v1.
10. **Schema conformance enforcement** — fixture files match live output; missing/extra fields vs appendix; optionality annotations match reality (e.g., `memoryTrendSummary` actually is nullable in practice).
11. **Workspace tooling regression** — `fvm flutter pub publish --dry-run` still produces clean output; `dart pub get` at root picks up workspace child; `pubspec.lock` semantics unchanged.
12. **Wire-size truncation UX** — truncated responses (`truncated: true, truncatedReason: "payload_exceeds_5mib", truncatedFields: [...]`) don't accidentally ship as "success" to the AI; documentation makes truncation visible; the MCP bridge surfaces `truncatedFields` in tool responses so the caller knows what's missing.

## Key Design Decisions

1. **`registerExtension` on `dart:developer`** — root isolate only (documented invariant). Works in debug AND profile mode.
2. **MCP protocol from scratch** — no external Dart MCP dependency. Methods listed in M4; deferred methods documented in README.
3. **`packages/sleuth_mcp/` with pub workspaces** — shares no Dart code with main package (VM service RPC only), same repo for coordinated releases.
4. **Discovery file with PID + identity-verifying liveness probe** — `~/.sleuth/vm_service_uri_<pid>`, each probed with `ext.sleuth.ping` to verify it's actually a Sleuth app.
5. **Handlers are pure functions + canonical JSON-encode helper** — testable without `dart:developer`; `Duration`/`DateTime`/`Enum` conversion centralized.
6. **`rulesJsonV1` stays package-internal** — MCP JSON is the only external contract.
7. **`compare_snapshots` takes JSON objects, not paths** — the client already has filesystem access; zero file I/O in the MCP server.
8. **Tri-state test-mode bypass** — `debugServiceExtensionRegistrationOverride` with `null`/`true`/`false` states enables integration tests to force-register.
9. **Bounded handler work via fixed-capacity buffers + 5 MiB wire-size cap** (revised from the original 500 ms wall-clock design per F1). Dart is non-preemptive and `exportSnapshot()` is synchronous, so a racing timeout cannot interrupt work in progress. Instead, every input buffer is fixed-capacity (Jank=50, FrameStats=60, phase=100, gc=50, platformChannel=50, route=50, issues bounded by detector count), and an M1 benchmark enforces handler p95 < 50 ms on a saturated controller. After serialization, responses > 5 MiB are trimmed field-by-field in a documented drop order with `truncatedReason: "payload_exceeds_5mib"`.
10. **Response schemas committed upfront with optionality annotations** — conformance tests (M1) + fixture files enforce the contract at CI time.
11. **Release-mode verification via M7a numbered smoke test** — no source-file grep meta-test; observational verification only.

## Open Questions (resolved with defaults — confirm or override)

1. **Workspace tooling**: pub workspaces (recommended) vs melos. **Default:** pub workspaces. Fall back only if M0 smoketest fails.
2. **Snapshot size cap**: warn + truncate outbound at 5 MiB, hard reject inbound at 10 MiB. **Default:** ship as written.
3. **Example app MCP demo**: dedicated `example/scripts/mcp_demo.sh`? **Default:** defer to v0.15.1. Verification step 8 acknowledges the friction.
4. **Test count**: estimated delta +35–45 tests (reduced from prior +40 estimate after cutting grep/reaper tests and adding conformance/bypass/timeout tests). Final total ~2,086–2,096. **Default:** accept; update CLAUDE.md to actual count on completion.
5. **`compare_snapshots` caps**: 5 MiB per-arg, 32-level nesting depth. **Default:** ship as written.
6. **Handler bounded-work strategy** (revised per F1): fixed-capacity buffers + M1 p95 < 50 ms benchmark + 5 MiB wire-size cap with `{truncated: true, truncatedReason: "payload_exceeds_5mib", truncatedFields: [...]}`. **Default:** ship as written; revisit if real-world apps routinely trip the wire-size cap on `getSnapshot` (suggests a buffer needs a smaller cap or a field needs summary-only encoding).

## Plan Review Pass

> **Historical record of planning-phase reviews — already complete. Do NOT re-run during implementation.** The only implementation-phase review is M8.

During plan authoring, `/adversarial-review` was invoked twice on successive drafts of this document (first pass: 21 findings, all folded in; second pass: the C1–L20 / E1–E2 findings tabled below, also folded in). A third planning-phase check — `/adversarial-investigation` in grill mode on 2026-04-14 — interrogated an independent Codex verdict against this spec and surfaced five additional findings (F1–F5) rooted in schema drift and non-preemptive Dart execution. Those were folded into the spec before implementation began. All three reviews happened in the planning conversation, not during implementation. The findings are recorded here for audit trail and to explain why specific design choices exist.

| # | Severity | Finding | Where it landed |
|---|----------|---------|-----------------|
| C1 | Critical | M1 pipeline round-trip test infeasible — no deserializers exist in the codebase | Reframed as **schema-conformance test** loading `test/fixtures/response_schemas/*.json` and asserting structural match; no deserializers needed |
| C2 | Critical | Response Schemas appendix had no enforcement — silent contract rot possible | One conformance test per extension (M1) + committed fixture files + PR expectation that schema edits update fixtures atomically |
| C3 | Critical | `ServiceExtensionResponse.result()` takes String not Map — handlers with `Duration`/`DateTime`/`Enum` would throw at `jsonEncode` | **`_safeJsonEncode` helper** specified in M1 with explicit type conversions + dirty-map test |
| C4 | Critical | Plan Review Pass section was a placeholder, violating the feedback memory's structural requirement | This table, populated with real findings from the second-pass review |
| C5 | Critical | Corpse PID + port reuse could connect MCP to a non-Sleuth or wrong-version Sleuth app; 2 s `getVM` probe doesn't verify identity | **New `ext.sleuth.ping` extension** (bringing total to 8) + identity-verifying liveness probe in M4 distinguishing live-Sleuth / live-not-Sleuth / unresponsive / dead |
| H6 | High | Binary `debugSkipServiceExtensionRegistration` couldn't force-register under `FLUTTER_TEST`, blocking integration_test end-to-end exercise | Upgraded to **tri-state `debugServiceExtensionRegistrationOverride`** (`null`/`true`/`false`) with explicit precedence tests |
| H7 | High | Rate-limiter scope ambiguous — per-client vs per-app state unspecified | M1 explicitly states app-side state + concurrent-client test |
| H8 | High | No per-call wall-clock timeout; a single long `getSnapshot` could freeze the UI for seconds | Original: **500 ms per-handler budget** with `{truncated: true, reason: "handler_timeout"}`. **Superseded by F1** in the 2026-04-14 investigation — see the F-row for the current design. |
| H9 | High | Response schemas didn't mark required vs optional vs nullable; consumers would crash on cold-app absent fields | **Optionality legend + per-field annotations** across every schema in the appendix |
| H10 | High | Handler unit tests all use mocked controllers — classic fixture tautology where mocks agree with implementer assumptions | M1 mandates **at least one real-controller integration test per extension** driven by actual scan loop |
| M11 | Medium | Deep-nested JSON could stack-overflow `compare_snapshots` diff | 32-level nesting cap added to M5 input validation |
| M12 | Medium | Release-mode smoke was an ad-hoc bullet inside M7 and easy to skip | **Promoted to numbered M7a milestone** with explicit exit criteria |
| M13 | Medium | Dependency graph drew M0 → M1 as a hard dependency but M1 doesn't structurally need workspace wiring | Graph redrawn: M0 → M4 HARD, M0 → all others SOFT (build sanity only) |
| M14 | Medium | Discovery file write failed silently → developer had no signal why MCP couldn't find their app | One-shot `debugPrint` on write failure, guarded by static flag |
| M15 | Medium | Plan distinguished "unresponsive" from "dead" PIDs but didn't say what MCP does with each | M4 spells out: unresponsive/dead/live-not-Sleuth all skipped for selection; diagnostics surfaced in error response |
| M16 | Medium | 10 MiB total inbound cap was too coarse for `compare_snapshots` (two 5 MiB args + 10 MiB diff output possible) | 5 MiB per-argument cap added to M5 |
| M17 | Medium | Two versioning schemes (`getSnapshot.schemaVersion`, `getCausalGraph.schemaVersion`) could drift without documentation | Appendix intro explicitly documents each response carries an independent `schemaVersion` |
| E1 | Exploit | `~/.sleuth/` could be a symlink redirecting writes to `~/.ssh/` | M2 adds regular-directory check before any write |
| E2 | Exploit | `$HOME` / `$USERPROFILE` injection could redirect discovery files outside the user's home | M2 validates home resolves to a known-safe prefix per platform |
| — | Gap | M0 smoketest didn't verify `flutter pub publish --dry-run` despite Scope #11 claiming coverage | Added `pub publish --dry-run` to M0 exit criteria |
| L18–L20 | Low | Test count stale, CLAUDE.md style unguided, Verification step 8 friction unacknowledged | Test count re-estimated at +35–45; M3 references v0.14.0 style; Open Question #3 acknowledges friction |

### Third-pass findings — 2026-04-14 adversarial investigation (grill mode on Codex verdict)

The /loop carried an independent Codex verdict that claimed this spec had five design flaws (two Critical, three High). `/adversarial-investigation` in grill mode interrogated each finding against the actual repo (`sleuth_controller.dart`, `session_snapshot.dart`, `performance_issue.dart`, `issue_explanation_builder.dart`, `route_session.dart`, `frame_stats.dart`, `causal_graph.dart`, `startup_metrics.dart`) and confirmed 4 of 5 in full plus the core of the 5th. Each confirmed finding was folded into the spec before implementation began.

| # | Severity | Finding | Where it landed |
|---|----------|---------|-----------------|
| F1 | Critical | M1 **per-handler 500 ms wall-clock timeout** (H8) is unenforceable. `exportSnapshot()` is fully synchronous (no `await` in `sleuth_controller.dart:1050-1140`), so a racing `Future.delayed(500ms)` cannot preempt it — Dart is non-preemptive. The "timeout" would only fire on handlers that had already voluntarily yielded, which is not the failure mode being defended against. | M1 bounded-handler section rewritten: **fixed-capacity buffers** (Jank=50, FrameStats=60, phase=100, gc=50, platformChannel=50, route=50) bound the work at source; **p95 < 50 ms serialization benchmark** enforces the budget at M1 gate time; **5 MiB wire-size cap** with `truncatedReason: "payload_exceeds_5mib"` + ordered-drop list trims response only after serialization. H8 row in this table marked **superseded by F1**. |
| F2 | Critical | M4 **most-recent-mtime discovery selection** breaks under realistic multi-app development — developer runs Sleuth example app + their own app, whichever was hot-reloaded last wins regardless of which project directory the MCP client was invoked from. Discovery files contain only `(pid, mtime, uri)`; nothing in the `ext.sleuth.ping` response identifies the project, so selection has no ground truth. | `ext.sleuth.ping` response gains `projectRoot`, `packageName`, and `pid` fields; new `ProjectRootResolver` class auto-detects via walk-up `pubspec.yaml` search (16-level cap), with an override seam that **the original draft put on `Sleuth.init(projectRoot: ...)`** — corrected by **TR-C1/TR-C2/TR-H2 below** to live on `SleuthConfig.projectRoot` and resolve **lazily on the first `ext.sleuth.ping`** instead of at init time, so TTFF is unaffected. Gracefully degrades to null fields on failure. M4 selection algorithm replaced with a **5-tier match algorithm** (exact / cwd-descendant / cwd-ancestor / null / explicit mismatch) with mtime as intra-tier tiebreak; canonicalisation via `resolveSymbolicLinksSync`; per-candidate debug logging for diagnosis. |
| F3 | Critical | `ext.sleuth.getSnapshot` schema in the appendix claims to "mirror `exportSnapshot().toJson()`" but invents ~5 field names (`sleuthVersion`, `capturedAtMs`, `truncated`) that don't exist in `session_snapshot.dart`, omits 11 real fields (`isVmConnected`, `isDebugMode`, `recentRequests`, `heapSamples`, `suppressedCount`, `phaseEvents`, `gcEvents`, `platformChannelEvents`, `recentFrames`, `widgetHeatMap`, `recurrenceTrends`), flattens the `sessionSummary` nesting, uses `p90` instead of `p95`. Schema-conformance test (C1) would catch it at implementation time, but silently produces a garbage contract. | Appendix `getSnapshot` schema **replaced with a literal mirror of `SessionSnapshot.toJson()` at `models/session_snapshot.dart:120-152`**. Drift table (renamed / dropped / added) included so contract-consumers understand why the appendix changed. `sessionSummary` is a nested object. Percentiles use `p50/p95/p99` matching `FpsPercentiles`. |
| F4 | High | `ext.sleuth.getRouteHealth` and `ext.sleuth.getFrameStats` schemas drift from the real types. `getRouteHealth` invented a flat shape using `route`/`durationMs`/`fpsAverage`/`startedAtMs` while `RouteSession.toJson()` uses `routeName`/`durationSeconds`/`frameStats.averageFps`/`startedAt` (ISO-8601) and emits 7 additional fields (`endedAt`, `scanCycles`, `frameStats.{totalFrames,p50,p95,p99}`, `criticalCount`, `warningCount`, `issues[]`). `getFrameStats` invented `shaderCompileFrames` (no such field anywhere) and used `p90` (real API is `p95`). | Both schemas **replaced with literal mirrors** of `route_session.dart:130-175` and `FrameStatsBuffer` / `FpsPercentiles`. Drift tables document the corrections. `shaderCompileFrames` removed; `bufferCapacity` + `frameBudgetMs` replace the nonexistent `sampleWindowMs`. |
| F5 | High | Three cascading schema drifts: **(a)** `getIssues` used a 5-value `IssueCategory` enum (`build|layout|rendering|memory|network|other|structural`) but the real enum has **9 values** (`build|layout|paint|raster|memory|channel|font|network|startup`) — `structural` is an `ObservationSource`, not a category. Spec also invented a `sourceLocation: {file, line}` nested struct and a per-issue `recurrence` field that aren't in `PerformanceIssue.toJson()`, and used `message`/`route` instead of `title`+`detail`/`routeName`. **(b)** `getRouteHealth` drifts as per F4. **(c)** `getEncyclopedia` used `title`/`description`/`fixSteps[]` but the real `IssueExplanation` record uses `displayName`, splits into `whatItIs`+`whyItMatters`+optional `whenToIgnore`, and `howToFix` is a **`String`** not a `List<String>` — a type mismatch that every consumer would miss until runtime. | All three schemas **replaced with literal mirrors** of their respective real types. `PerformanceIssue.toJson()` mirror includes all 15 previously-missing fields (stableId, confidenceReason, packageName, ancestorChain, topAllocators, rankingScore/Breakdown, rootCauseId, downstreamIds, scaffoldHashKey, tabVisitIndex, etc.). `IssueExplanation` mirror corrects the `fixSteps[]→howToFix: String` type bug, splits description, and marks `readingTheData` / `relatedIssues` as optional-nullable per the record definition. Each response section has an appended drift table for audit. |

**Self-critique on F4 (partial confirmation)**: the grill-mode verdict originally wrote that `getRouteHealth` was "fine as-is" after a cursory review. A second pass against `route_session.dart:130-175` caught the 5 renamed fields and 7 dropped fields — the "fine as-is" claim was premature. This is exactly the failure mode `/adversarial-investigation` is meant to catch in its own output, and the correction was made before any edit was committed. The lesson is worth preserving: when auditing "schema drift" findings, always diff the real `toJson()` byte-for-byte, not just skim the high-level fields.

**Re-attacking the F-row fixes** (Tactic 8):
- *F1 bounded-handler benchmark*: the benchmark is only as strong as the saturation harness. Mitigation — M1 specifies the exact buffer counts to saturate, and a buffer-cap contract test guards against future capacity drift going unnoticed.
- *F2 5-tier selection*: case-sensitivity and symlink canonicalisation are easy to get wrong per-platform. Mitigation — tests explicitly cover Linux case-sensitivity and macOS `/private/var/*` canonicalisation. Tier 4 ("explicit mismatch only") is allowed to select with a warning rather than erroring, to preserve the single-project ergonomics users have today.
- *F3/F4/F5 schema mirrors*: mirrors frozen in 2026-04-14 can drift if the real `toJson()` methods change. Mitigation — the M1 schema-conformance test loads the appendix fixtures and asserts live output matches, so any field-rename in `session_snapshot.dart` or friends fails the test and forces a synchronized update.

**Re-attacking the fixes** (Tactic 8):
- *Schema-conformance fixtures (C1/C2)*: the fixtures themselves could be wrong. Mitigation: fixtures are captured from live handler output once, checked in, and reviewed alongside the spec. PRs that change both handler AND fixture get scrutinized. Not airtight, but substantially better than prose.
- *`_safeJsonEncode` (C3)*: could miss an obscure type (e.g., `BigInt`). Mitigation: fallback to `toString()` for unknown types rather than throwing — `_safeJsonEncode` never crashes, only degrades.
- *Identity-verifying liveness probe (C5)*: adds a round-trip to every discovery scan. Mitigation: probe is parallelized across candidate URIs (up to 5 concurrent), bounded at 1 s each. Worst-case added latency is ~2 s (connection + ping).
- *Tri-state bypass (H6)*: introduces new state combinations. Mitigation: three explicit tests cover each non-null value; `null` case is the default path with full env coverage.
- *Handler timeout (H8)*: clients must check `truncated: true`. Mitigation: README documents this; MCP tools could also auto-log a warning when they pass a truncated response to the AI.

### Fourth-pass findings — 2026-04-14 adversarial review on revised draft

After applying F1–F5, an explicit `/adversarial-review` invocation was run against the revised spec. The reviewer cross-checked every spec claim against live source: `lib/sleuth.dart:196` (`Sleuth.init` is `static void`, not `Future`), `lib/sleuth.dart:405` (`Sleuth.track` is the real main entry), `sleuth_controller.dart:494` (`SleuthController.initialize`), `sleuth_controller.dart:3092` (`SleuthConfig` constructor), `sleuth_controller.dart:3672` (`SleuthConfig.copyWith`). The review surfaced 11 findings (3 Critical, 5 High, 3 Medium) which were folded into the spec **before** any implementation began. Each row below points at the spec section it landed in.

| # | Severity | Finding | Where it landed |
|---|----------|---------|-----------------|
| TR-C1 | Critical | F2's "resolved at `Sleuth.init()` time" was a wrong premise. `Sleuth.init()` (`lib/sleuth.dart:196`) is the optional TTFF helper, not the main entry — most users hit `Sleuth.track()` and never call `init()`. The proposed `init(projectRoot:)` parameter would ship dead for the common case, silently collapsing F2's 5-tier selection back to a mtime tie-break in its motivating "two apps running" scenario. | M1 **TR1 subsection** added. `Sleuth.init()` is **not modified**; `SleuthConfig` gains an optional `projectRoot` parameter on its constructor + `copyWith` instead. The override flows through whatever entry point the user actually uses (`Sleuth.track(config: ...)` / `SleuthController(config: ...)`). |
| TR-C2 | Critical | Even moving the override to `SleuthConfig`, calling `ProjectRootResolver.resolve()` synchronously inside `SleuthController.initialize()` would block the first build and inflate TTFF. The `slow_startup_ttff` detector (v0.13.0, calibrated for "the portion Dart code can move") would false-fire on Sleuth's own cold-start I/O — Sleuth accusing itself of slow startup. | TR1 specifies **lazy-on-first-ping** resolution: `ServiceExtensionRegistry` holds a nullable `_cachedHandshake` field, populated on the first `ext.sleuth.ping` call (which only fires once a developer asks for it, never on the cold-start critical path). Subsequent pings read the cache; zero repeat I/O; `initialize()` does no filesystem work. |
| TR-C3 | Critical | M1's wire-size cap had a single drop stage and aborted with `{"error": "snapshot_too_large"}` if the minimum kept set exceeded 5 MiB. A pathologically saturated `currentIssues` array (200 issues with deep `topAllocators`) plus a per-route `sessionSummary` could legitimately push the minimum set over the cap, making the entire tool useless on the apps that need it most. | M1 wire-size section rewritten as **two-stage drop with stage-3 fallback**. Stage 1 = primary-drop list as before. Stage 2 = within-minimum-set trim (`currentIssues → top 50` by `rankingScore`, `sessionSummary.routeSessions → last 10` by `endedAt`, `topIssues → first 20`, `detectorHitRates → top 20`). Stage 3 = always-fits fallback `{truncated: true, truncatedReason: "minimum_set_exceeds_cap", partialData: {schemaVersion, packageVersion, exportedAt, frameStatsSummary, currentIssues[0..4]}}`. New tests cover each branch. |
| TR-H1 | High | Prior draft of `ProjectRootResolver` allowed a "1-second read budget" for `pubspec.yaml`. F1's whole lesson is that Dart cannot preempt synchronous I/O — `File.readAsStringSync()` takes no timeout. The wall-clock budget was unenforceable in exactly the same way the H8 handler timeout was. | TR1 step 3 replaces the read budget with a **256 KiB `lengthSync()` pre-check** that rejects pathologically large files before any read even starts. Test (k) in the ProjectRootResolver test list covers the size cap explicitly. The "1-second read budget" language is removed everywhere. |
| TR-H2 | High | The spec claimed "non-breaking addition" for the `Sleuth.init(projectRoot:)` parameter, but `Sleuth.init` is `static void init()` — it has no `config` parameter today, so the only way to add `projectRoot` would be either a new positional parameter (source-incompatible if anyone uses positional args) or a free-standing named parameter on a now-misleading "TTFF helper" API. Either path is worse than not modifying `init()` at all. | TR1 explicitly states `Sleuth.init()` is **not modified**. The override lives on `SleuthConfig`, which is the existing config-injection seam used by both `Sleuth.track(config:)` and the bare `SleuthController(config:)` constructor. Genuinely non-breaking in both directions. |
| TR-H3 | High | M4's `_pathStartsWith` paragraph said "use `compareCaseInsensitive` on macOS/Windows" but didn't specify the implementation. A naive `String.startsWith` is byte-for-byte and would silently fail tier-0/tier-1 matches on case-insensitive filesystems — users with `/Users/Alice/proj` running MCP from `/users/alice/proj` would land in tier 4 (mismatch). | M4 path canonicalisation block now ships a **concrete `_pathStartsWith` helper** that lowercases both operands on `Platform.isMacOS || Platform.isWindows`, plus an explicit trailing-separator guard so `/a/b` does not falsely match `/a/banana`. Tests cover both case-sensitive (Linux) and case-insensitive (macOS/Windows) branches. |
| TR-H4 | High | The pubspec name regex was `^name:\s*(\S+)`, which captures surrounding quotes for legal-but-uncommon quoted YAML names like `name: "my_app"`. The result `packageName == '"my_app"'` is not a valid Dart identifier and would defeat the M4 selection algorithm's exact-match logic. | TR1 step 4 tightens the regex to `^name:\s*["']?([a-z_][a-z0-9_]*)["']?\s*$`. The optional `["']?` strips quotes, the character-class restriction enforces valid Dart identifiers. ProjectRootResolver tests (h)/(i)/(j) cover double-quoted, single-quoted, and trailing-comment forms. |
| TR-H5 | High | M4's "Diagnostic logging" said "log one line per candidate at debug level" but didn't specify the logging primitive. A raw `print` to `stdout` would interleave with the JSON-RPC response stream and corrupt MCP framing for buggy clients; a raw `print` would also leak diagnostic noise into AOT release builds. | M4 logging block now mandates the **`assert(() { stderr.writeln(...); return true; }())` idiom**, with the explicit rationale that `dart compile exe` strips assert blocks (so AOT release output is silent) and `stderr` is the conventional sideband that every MCP client tolerates. |
| TR-M1 | Medium | The M1 test list inherited the "1-second read budget" test from the prior draft and lacked any test for the lazy-resolution caching contract — a future refactor could move the resolver back into `initialize()` and the only failing signal would be a TTFF regression detected weeks later. | M1 ProjectRootResolver test list adds (k) **256 KiB size-cap test**, (l) **lazy-resolution cache test** (assert resolver is NOT invoked at construction time, assert filesystem is touched exactly once across N pings), and **explicitly removes** the "1-second read budget" test. |
| TR-M2 | Medium | `developer.registerExtension` only succeeds on the root isolate and throws `UnsupportedError` otherwise. Spec didn't address the spawned-isolate case — rare but possible on desktop apps that spin up worker isolates with their own Flutter bindings. An unhandled throw inside `register()` would propagate out of `initialize()` and break Sleuth setup for the whole app. | M1 adds a **root-isolate guard** paragraph: wrap the `register()` call site in a single try/catch, swallow `UnsupportedError`, emit a one-shot log, leave `_registered = false`. Test added to the M1 test list that stubs `registerExtension` to throw and asserts the log fires exactly once across multiple `register()` calls. |
| TR-M3 | Medium | M4's tier-2 monorepo path was tested with a single entry, but the realistic case has **two** subpackages running simultaneously under the same workspace root. With both at tier 2, mtime tie-break picks one arbitrarily and the user has no signal that there was a collision. | M4 test list adds the **"Tier 2 collision"** case: two tier-2 entries with mtimes 50 ms apart, asserts a warning log naming both candidate URIs/pids, asserts the documented user remediation (`cd packages/foo` or pass `--uri`). The selection itself is still deterministic (mtime + pid tie-break) but the warning makes the collision visible. |

**Self-critique on the fourth pass:** The reviewer almost shipped a fix that moved `projectRoot` into `Sleuth.init()` as a Future-typed async helper before re-reading `lib/sleuth.dart:196` and discovering `init` is `static void`. This is exactly the symptom the spec author had been warned about repeatedly: don't trust prior-draft language describing methods you haven't byte-checked. The recovery was to grep the entry point first (`grep -rn "static.*init" lib/sleuth.dart`), then verify the real main entry (`Sleuth.track`), then design the override around the actually-used config injection point. Two minutes of grep prevented a four-hour implementation dead-end.

**Re-attacking the TR-row fixes** (Tactic 8):
- *TR-C1/TR-C2 lazy-on-first-ping*: a malicious or pathological user could call `ext.sleuth.ping` against a controller whose `Directory.current` has been changed to `/` since startup, producing a different `projectRoot` than expected. Mitigation: `Directory.current` is captured **at the moment of the first `ping`**, not at `initialize()` — this is the documented contract, and the cache-once-then-freeze design means subsequent pings always return the captured value. Tests assert determinism across multiple pings.
- *TR-C3 stage-2/3 trim*: a consumer relying on full `currentIssues` would silently get only 50 entries with no way to ask for more. Mitigation: `currentIssuesTruncatedTo` is in the response envelope so the consumer can detect truncation and re-request via `getIssues` (which has its own truncation but no cross-field interference). Stage 3 is documented as a worst-case fallback that never silently fails.
- *TR-H1 256 KiB size cap*: a project with a legitimately huge `pubspec.yaml` (e.g. 500 KiB of `dependencies:` from a monorepo aggregator) would fail detection. Mitigation: 256 KiB is an order of magnitude above realistic pubspecs — the median is ~1–4 KiB and even Flutter's own pubspec is < 10 KiB. The cap is a safety rail, not a functional limit. The fall-through is graceful (`projectRoot: null, packageName: null`), which routes to tier 3 in M4 — degraded but functional.
- *TR-H4 tightened regex*: a pubspec with a name containing a digit-leading character (e.g. `name: 2gis`) would be rejected by the `[a-z_]` first-char class. Mitigation: this is **correct** — Dart package names cannot start with a digit (pub.dev rejects them). The regex enforces the same constraint pub does, and rejection routes to `packageName: null` which is graceful.
- *TR-H5 assert-block stderr logging*: `dart run` enables asserts by default, so developers always see the diagnostic stream. `dart compile exe` (release) strips them. But what about `dart compile exe --enable-asserts`? Mitigation: that flag is an opt-in for release builds with assertions enabled — the user explicitly chose to keep them. The pattern degrades gracefully in every direction.

## Verification

After M0–M3 (Part 1 complete):
1. `fvm flutter test` — all tests pass, including schema-conformance tests, tri-state precedence, concurrent-client limiter, bounded-handler p95 < 50 ms benchmark, two-stage wire-size cap (stage 1 primary drop, stage 2 within-set trim, stage 3 minimum-set fallback), `_safeJsonEncode` helper, ProjectRootResolver auto-detect/override/quoted-name/256 KiB cap/lazy-cache, root-isolate guard, symlink/home-prefix guards.
2. `fvm flutter analyze` — 0 issues.
3. `fvm flutter pub publish --dry-run` — 0 warnings.
4. Run example app in profile mode → connect via `dart run` script that calls `ext.sleuth.ping` and `ext.sleuth.getSnapshot` → verify responses match Response Schemas appendix.

After M4–M7 (Part 2 complete):
5. `cd packages/sleuth_mcp && dart test` — all tests pass.
6. `cd packages/sleuth_mcp && dart analyze` — 0 issues.
7. Manual E2E: start example app → start MCP server → `connect` → auto-discovery with identity probe succeeds → send `tools/call` for each of 7 tools → verify responses match tool schemas.

After M7a (release smoke):
8. Build example app in release mode, launch. Verify: no `~/.sleuth/` directory created on host, MCP `connect` returns `{"error": "no live Sleuth app found"}`. This is the load-bearing release-mode verification.

After M8 (`/adversarial-review`):
9. Configure in Claude Code → ask "check my app's performance" → verify AI gets real data. **Note:** without the deferred v0.15.1 example-app demo, this verification requires manually adding `Sleuth.init()` to a non-trivial test app and configuring MCP — friction acknowledged per Open Question #3.
10. All Critical/High findings from post-implementation adversarial review resolved; Medium findings resolved unless explicitly deferred with reasoning.
