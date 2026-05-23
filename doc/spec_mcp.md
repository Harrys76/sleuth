# MCP Support — Implementation Spec (M1+M2+M3)

Surface sleuth's live runtime data to AI assistants via Model Context
Protocol. Three milestones, all combined under sleuth v0.32.0 +
`sleuth_mcp` v0.1.0.

## Goal

A developer running a Flutter app under `flutter run` points an MCP-aware
client (Claude Code, Cursor, Zed, etc.) at the `sleuth_mcp` sidecar
binary. The sidecar proxies sleuth's in-process state — current issues,
route health, snapshot, causal graph, encyclopedia — to the AI assistant
over MCP stdio JSON-RPC, so the assistant can diagnose performance
regressions in conversation.

## Non-goals

- Bundled MCP transport dependency in the main `sleuth` package — the
  app process only exposes `ext.sleuth.*` VM service extensions.
- Write side. M1–M3 are read-only.
- Auto-discovery of running apps. Sleuth targets ios + android only —
  the app process runs inside the device sandbox while the sidecar runs
  on the developer's host machine. There is no shared filesystem. The
  user passes the VM service URI manually via `--uri` (copied from
  `flutter run` output, the same way DevTools' "Open in Browser" link
  works).
- No release-mode behaviour change. Service extensions follow the
  existing `kReleaseMode` guard.

## Architecture

```
┌─────────────────────────┐    WebSocket   ┌──────────────────────┐    stdio   ┌─────────────────┐
│ Flutter app             │  ◄────────►    │ sleuth_mcp sidecar   │  ◄──────►  │ MCP client      │
│ (debug or profile)      │   VM service   │ (Dart CLI on host)   │  JSON-RPC  │ (Claude Code,   │
│ ─ SleuthController      │                │ packages/sleuth_mcp/ │            │  Cursor, Zed)   │
│ ─ ext.sleuth.* handlers │                │                      │            │                 │
└─────────────────────────┘                └──────────────────────┘            └─────────────────┘
```

The user starts `flutter run` on the device of their choice. They copy
the printed VM service URI (the same one DevTools uses) and pass it to
`sleuth_mcp --uri <ws-uri>`. The MCP client spawns the sidecar as a
subprocess and speaks JSON-RPC over its stdin/stdout.

## M1 — VM Service Extensions

Registers seven `ext.sleuth.*` extensions via
`dart:developer.registerExtension`. Each handler returns a response
whose `result` is the inlined sleuth envelope JSON.

### Extensions

| Name | Args | `data` payload |
|---|---|---|
| `ext.sleuth.snapshot` | none | `SessionSnapshot.toJson()` |
| `ext.sleuth.issues` | optional `route` | `{issues: [...]}` filtered by route name or sourceRoute |
| `ext.sleuth.routeHealth` | optional `route` | `{routes: [...]}` or single matching session |
| `ext.sleuth.explain` | required `stableId` | `{stableId, canonical, explanation}` |
| `ext.sleuth.encyclopedia` | none | `{count, entries}` keyed by canonical stableId |
| `ext.sleuth.causalGraph` | none | `{count, rules: [{trigger, effect}]}` |
| `ext.sleuth.diagnose` | none | `{packageVersion, initializedAtMicros, vmConnected, captureMode, lastCaptureExportFailure, unboundExtensionNames}` |

### Envelope contract

Every response stamps a four-field envelope:

```json
{
  "connectionMode": "correlated|full|basic|warmup|disconnected",
  "schemaVersion": 1,
  "sessionUuid": "<rfc4122-v4>",
  "data": { ... } 
}
```

On error the envelope swaps `data` for `error` (a string) plus optional
`stack` and tool-specific extras. Reserved envelope keys
(`connectionMode`, `schemaVersion`, `sessionUuid`, `error`, `stack`)
cannot be overridden by handler `extra` — they're filtered in
`envelopeError`.

`connectionMode` derivation: warmup takes precedence over VM-fidelity
classification — a fast VM connect during the configured warmup window
returns `warmup`, never `correlated`/`full`/`basic`.

### Wire format

`package:vm_service` inlines the extension's `ServiceExtensionResponse.result(jsonString)`
content directly into the JSON-RPC `result` field. The sidecar's
`VmBridge.callExtension` receives the parsed envelope as
`Response.json` directly — no manual second-stage decode is needed.

### Registration lifecycle

`ServiceExtensionRegistry` is a process-wide singleton. The first
registry per isolate calls `developer.registerExtension` for each
handler name. Subsequent registries (hot-restart, serial test
setUp/tearDown) only swap a static `WeakReference<SleuthController>`;
the dispatcher reads the weak ref at call time. Partial-registration
recovery: per-name `Set<String> _bound` lets a later `registerAll`
retry only the names that failed (e.g. another package collided on a
name and was unloaded). `ext.sleuth.diagnose` surfaces the
`unboundExtensionNames` list so an MCP client can warn its operator
when the live surface is degraded.

### File inventory

| File | Purpose |
|---|---|
| `lib/src/vm/service_extension_registry.dart` | Process-wide singleton + weak-ref dispatch |
| `lib/src/vm/service_extension_handlers.dart` | Seven pure handler functions + `envelopeOk` / `envelopeError` + cycle-safe sanitiser |
| `lib/src/vm/connection_mode.dart` | 5-state enum + `computeConnectionMode` |
| `lib/src/utils/session_uuid.dart` | `generateSessionUuid()` RFC 4122 v4 via `Random.secure()` |

### Modified files (M1)

- `lib/src/controller/sleuth_controller.dart` — `sessionUuid` final field, `initializedAt` getter + setter for tests, `_extensionRegistry` constructed at the end of `initialize()` (debug/profile only), `markDisposed()` called in `dispose()`.
- `lib/src/analyzer/causal_graph.dart` — `static List<Map<String, Object?>> get rulesJson` on `CausalGraphRule`.
- `lib/sleuth.dart` — barrel exports `ConnectionMode` + `ServiceExtensionRegistry`.

### Reserved namespace

Sleuth reserves the `ext.sleuth.*` VM service extension namespace. Other
packages should choose a distinct prefix.

## M2 — `sleuth_mcp` Sidecar Package

Standalone Dart package at `packages/sleuth_mcp/`. Dart-only (no Flutter
SDK dep). MCP stdio JSON-RPC server hand-rolled in ~150 LOC, no
transport dependency.

### Discovery — `--uri` only

The user copies the VM service URI from `flutter run`'s output (the
same URI DevTools requires) and passes it to the sidecar:

```bash
sleuth_mcp --uri "ws://127.0.0.1:55555/<token>=/ws"
```

This is the only discovery mechanism in v0.1.0. Auto-discovery (via
`flutter run --machine` stdout parse, or DevTools' service registry) is
a possible future enhancement once shipped UX feedback identifies the
manual-copy step as a real friction point. Most MCP clients already
require manual URI input for VM service tools, so the friction is
familiar.

### Directory layout

```
packages/sleuth_mcp/
├── pubspec.yaml
├── analysis_options.yaml
├── CHANGELOG.md
├── README.md
├── bin/
│   ├── sleuth_mcp.dart          # stdio MCP server entry
│   └── sleuth_check.dart        # one-shot CI gate (exit code on budget violation)
├── lib/
│   ├── sleuth_mcp.dart          # public barrel
│   └── src/
│       ├── mcp/
│       │   ├── mcp_protocol.dart    # JSON-RPC 2.0 stdio codec
│       │   ├── mcp_server.dart      # initialize handshake + dispatcher
│       │   └── mcp_types.dart       # data classes
│       ├── bridge/
│       │   └── vm_bridge.dart       # VM service client + session-drift detection
│       ├── tools/
│       │   ├── tools.dart           # built-in tool registry
│       │   ├── budgets.dart         # check_budgets handler + reusable evaluator
│       │   └── compare_snapshots.dart
│       └── resources/
│           ├── encyclopedia.dart
│           └── causal_graph.dart
└── test/
    ├── mcp_protocol_test.dart
    ├── mcp_server_test.dart
    ├── bridge/vm_bridge_test.dart
    ├── tools/*_test.dart         # one per tool (8)
    ├── resources/*_test.dart
    ├── integration/wire_round_trip_test.dart   # real Service.controlWebServer
    ├── sleuth_mcp_smoke_test.dart              # spawns binary
    └── helpers/fake_vm_bridge.dart
```

### Tools

Names use MCP's recommended snake_case. Every tool ships an
`inputSchema` JSON Schema with `type: "object"`, `properties`, and
`required` arrays. Missing-required-arg fails return `isError: true`
content, not JSON-RPC errors.

| Tool | Args | Notes |
|---|---|---|
| `connect` | `uri` (required) | Establishes bridge. Cross-checks `packageVersion` against sidecar's pin; emits `warning: "version_skew_minor"` or `error: "version_skew_major"` on drift. |
| `get_snapshot` | none | Pass-through of `ext.sleuth.snapshot` envelope |
| `get_issues` | `route?`, `severityAtLeast?` | Client-side severity filter (case-insensitive) |
| `get_route_health` | `route?` | Pass-through |
| `explain_issue` | `stableId` (required) | Parametric stableIds resolve through `IssueExplanationBuilder.canonicalId` |
| `compare_snapshots` | `before` (object), `after` (object) | Pure client-side diff: added/removed/elevated issues, fpsDelta |
| `check_budgets` | `minFps`, `maxIssues`, `maxCriticalIssues` | Returns `{passed, violations, observed}` content. CI exit-code path is `sleuth_check` binary. |
| `diagnose` | none | Augments app's diagnose payload with sidecar version pin |

### Resources

| URI | Content | Cached |
|---|---|---|
| `sleuth://encyclopedia` | `IssueExplanation` entries keyed by canonical id | Keyed by `sessionUuid` |
| `sleuth://causal-graph` | Full rule set | Keyed by `sessionUuid` |

Cache invalidates inline when the bridge's `sessionUuid` changes (hot
restart of the target app). No polling — drift is detected on the next
tool call via the envelope's sessionUuid field; the bridge throws
`SessionChangedException` and the server surfaces it as `isError: true`
content with `session_changed baseline=X current=Y`.

### MCP protocol surface

- `initialize` — reads `params.protocolVersion`, echoes server's pin
  (`2024-11-05`), logs mismatch to stderr.
- `notifications/initialized` — accepted no-op.
- `tools/list`, `tools/call` — eight tools.
- `resources/list`, `resources/read` — two resources.
- `ping` — empty result.
- Non-`ping` methods before `initialize` return JSON-RPC error
  `-32002`.
- Unknown method → JSON-RPC error `-32601`.

### Per-tool timeout

Default 10 s per `tools/call`. Configurable via `--tool-timeout
<seconds>`. Timeout returns `isError: true` content
(`timeout_after_<n>ms`).

### CI gate — `sleuth_check` binary

Separate one-shot binary for CI integration. Exits 0 on pass, 1 on
violation, 2 on connect/handler failure. Sample usage:

```bash
sleuth_check --uri "ws://..." --min-fps 55 --max-issues 10 --max-critical-issues 0 --json
```

The stdio sidecar's `check_budgets` tool returns the same report shape
but as MCP content — no exit code, suitable for AI conversation only.

## M3 — Schema Doc + Audit

Locks the response shapes of `ext.sleuth.*` and the eight MCP tools so
external clients can depend on stable JSON.

### Artefacts

1. **`doc/mcp_schema.md`** — human-readable per-extension/tool schema
   with field names, types, nullability, which `connectionMode`
   populates each field.
2. **`test/validation/mcp_schema_audit_test.dart`** — fixture-driven
   programmatic guard. For each handler, builds a synthetic
   `SleuthController`, invokes the handler, asserts the response
   contains every documented field with the declared type. Catches
   field renames, type changes, drops.

### Schema versioning

`schemaVersion` (root envelope field) bumps on any breaking change:
field rename, removal, or type change. Adding optional fields or new
extensions does NOT bump. The sidecar reads the app's reported version
at `connect` time and warns on minor skew / errors on major skew.

### Audit enforcement

The audit test runs on every `fvm flutter test`. Pure fixtures — no
real app. Bidirectional check: every documented field appears in at
least one handler output, AND every handler output's keys appear in
the schema doc.

## Dependency graph

```
M1 (extensions in main package) ──► M2 (sidecar) ──► M3 (schema + audit)
```

M2 cannot ship before M1. M3 must follow M2. M1+M2 ship as one release
(sleuth v0.32.0 + sleuth_mcp v0.1.0). M3 follows as a fast-follow.

## Version targets

| Milestone | Sleuth | Sidecar |
|---|---|---|
| M1 + M2 | `0.32.0` | `0.1.0` |
| M3 | `0.33.0` | `0.1.1` |
| M4 (planned) | `0.35.0` (unchanged) | `0.7.0` |
| M5 (planned) | `0.36.0` | `0.8.0` |

## M4 — Hot-restart reconnect resilience (planned)

Hot restart/reload re-binds the VM service on a new port; the attached
sidecar session goes dead and the agent must re-attach by hand. M4
auto-recovers: on a `bridge.connect` drop (socket close, or a daemon
`app.debugPort` with a changed port), re-resolve the VM service — Bonjour
for the iOS-direct route, the daemon `app.debugPort` event for the daemon
route — and reconnect, preserving `sessionUuid` continuity. Bounded
retry; surfaces `reconnect_failed` (or the existing `ios_vmservice_*`)
when it can't recover.

- Sidecar-only (lib unchanged). Touches `vm_bridge.dart` (reconnect path)
  and `daemon_session.dart` (drop detection + re-resolve/re-attach).
- Target: `sleuth_mcp` v0.7.0, pins sleuth 0.35.0.

## M5 — Live issue stream (planned)

Agents poll `get_issues`. M5 pushes issues as detectors emit, via MCP
server→client notifications, turning the agent reactive. Lib exposes an
emit stream over a new additive `ext.sleuth.*` subscribe surface (or
reuses the existing emission hook); the sidecar relays each emission as
an MCP notification. Opt-in per session; backpressure-bounded so a noisy
detector can't flood the client.

- Lib + sidecar. Additive — envelope `schemaVersion` stays `1`.
- Target: sleuth v0.36.0 + `sleuth_mcp` v0.8.0.

## Risks

| Risk | Severity | Mitigation |
|---|---|---|
| `dart:developer.registerExtension` duplicate-name throw on hot-restart | Medium | Process-wide singleton + per-name `_bound` set; retry only unbound names |
| AI client misreads `basic`-mode empty result as "no problems" | Medium | Every response stamps `connectionMode`; sidecar emits `warmup` until the configured window elapses |
| Sidecar bundles a stale VM URI from a previous app | Medium | `sessionUuid` cross-check at every tool call; `SessionChangedException` surfaces inline |
| Schema drift between handler output and `mcp_schema.md` | Medium | M3 audit grep-checks both directions |
| Sidecar version skew with main sleuth package | Medium | `connect` tool cross-checks; emits `warning: version_skew_minor` or `error: version_skew_major` |
| Handler hang blocks sidecar | Medium | Per-tool 10 s timeout returns `isError: true` content |
| Handler exception crashes sidecar | High | Dispatcher try/catch wraps every handler invocation |
| `kSleuthPackageVersion` drifts from `pubspec.yaml` | Medium | `test/validation/package_version_audit_test.dart` enforces sync |
| Tight coupling sleuth ↔ sleuth_mcp | Medium | M3 schema audit + sidecar startup warning on version skew |

## Rollback notes

- M1 — feature-toggleable via reverting the registry construction in
  `SleuthController.initialize()`. Existing callers untouched.
- M2 — ships as a separate `packages/sleuth_mcp/` publish. If yanked,
  the main sleuth package is unaffected.
- M3 schema audit — failing it does not affect runtime. Schema
  regressions caught in CI roll back via reverting the offending
  handler change.

## Out-of-scope follow-ups

- Auto-discovery via `flutter run --machine` parse (only when manual
  `--uri` step proves consistently friction-causing in real-world
  feedback).
- Write-side tools (toggle detector enabled, override thresholds,
  mute issues).
- HTTP transport for remote MCP clients.
- Multi-app aggregation in a single sidecar.

- v0.34.0: deep snapshot schema. Bigger payload-shape lock. Higher priority since get_snapshot is the most-called tool.
- v0.4.0 (sleuth_mcp): tool-layer audit. Lower value because tool tests already cover transforms; this just formalizes the contract.