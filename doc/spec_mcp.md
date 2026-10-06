# MCP support implementation spec (M1 to M3)

This is the original design plan for milestones M1 to M3, kept as history; `packages/sleuth_mcp/README.md` and `packages/sleuth_mcp/doc/mcp_tool_schema.md` describe the current sidecar (0.8.0, built against sleuth 0.37.0).

The plan exposes sleuth's live runtime data to AI assistants through the
Model Context Protocol in three milestones. M1 and M2 shipped together in
sleuth 0.32.0 and `sleuth_mcp` 0.1.0. M3 followed in sleuth 0.33.0 and
`sleuth_mcp` 0.3.0.

## Goal

A developer running a Flutter app under `flutter run` points an MCP-aware
client (Claude Code, Cursor, Zed and others) at the `sleuth_mcp` sidecar
binary. The sidecar passes sleuth's in-process state (current issues,
route health, snapshot, causal graph, encyclopedia) to the AI assistant
over MCP stdio JSON-RPC, so the assistant can diagnose performance
regressions in conversation.

## Non-goals

- No MCP transport dependency in the main `sleuth` package. The app
  process only exposes `ext.sleuth.*` VM service extensions.
- No write side. M1 to M3 are read-only.
- No auto-discovery of running apps. Sleuth targets iOS and Android only.
  The app process runs inside the device sandbox while the sidecar runs
  on the developer's host machine, and they share no filesystem. The
  user passes the VM service URI by hand with `--uri`, copied from the
  `flutter run` output, the same way DevTools' "Open in Browser" link
  works. Sidecar 0.2.0 later added discovery through `attach_app`.
- No change in release mode. Service extensions follow the existing
  `kReleaseMode` guard.

## Architecture

```
┌─────────────────────────┐    WebSocket   ┌──────────────────────┐    stdio   ┌─────────────────┐
│ Flutter app             │  ◄────────►    │ sleuth_mcp sidecar   │  ◄──────►  │ MCP client      │
│ (debug or profile)      │   VM service   │ (Dart CLI on host)   │  JSON-RPC  │ (Claude Code,   │
│ ─ SleuthController      │                │ packages/sleuth_mcp/ │            │  Cursor, Zed)   │
│ ─ ext.sleuth.* handlers │                │                      │            │                 │
└─────────────────────────┘                └──────────────────────┘            └─────────────────┘
```

The user starts `flutter run` on the device of their choice, copies the
printed VM service URI (the one DevTools uses) and passes it to
`sleuth_mcp --uri <ws-uri>`. The MCP client spawns the sidecar as a
subprocess and speaks JSON-RPC over its stdin and stdout.

## M1: VM service extensions

M1 registers seven `ext.sleuth.*` extensions through
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
| `ext.sleuth.diagnose` | none | `{packageVersion, initializedAtMicros, vmConnected, captureMode, lastCaptureExportFailure, unboundExtensionNames, effectiveFrameRateHz, frameBudgetUs, frameRateSource, lastPoll{Rpc,Decode,Parse,Dispatch,Tail}Micros, lastPollDispatch{Detectors,Correlate,Aggregate,Other}Micros, lastPollTail{Memory,CpuSamples,AllocationProfile}Micros, lastPollEventCount, lastPollResponseChars, maxPoll{Rpc,Decode,Parse,Dispatch}Micros, pollDuplicatesDropped, pollWindowFallbacks}` |

### Envelope contract

Every response carries a four-field envelope:

```json
{
  "connectionMode": "correlated|full|basic|warmup|disconnected",
  "schemaVersion": 1,
  "sessionUuid": "<rfc4122-v4>",
  "data": { ... } 
}
```

On error the envelope replaces `data` with `error` (a string), plus an
optional `stack` and handler-specific extras. Handler `extra` cannot
override the reserved envelope keys (`connectionMode`, `schemaVersion`,
`sessionUuid`, `error`, `stack`); `envelopeError` filters them out.

When `connectionMode` is derived, warmup takes precedence over the
VM-fidelity classification. A fast VM connect during the configured
warmup window returns `warmup`, never `correlated`, `full` or `basic`.

### Wire format

`package:vm_service` inlines the content of the extension's
`ServiceExtensionResponse.result(jsonString)` into the JSON-RPC `result`
field. The sidecar's `VmBridge.callExtension` receives the parsed
envelope as `Response.json` directly, so it needs no second decode step.

### Registration lifecycle

`ServiceExtensionRegistry` is a process-wide singleton. The first
registry in an isolate calls `developer.registerExtension` for each
handler name. Later registries (after a hot restart, or in serial test
setUp and tearDown) only swap a static `WeakReference<SleuthController>`,
and the dispatcher reads the weak reference at call time. A per-name
`Set<String> _bound` lets a later `registerAll` retry only the names that
failed, for example when another package registered the same name and
was unloaded. `ext.sleuth.diagnose` reports the `unboundExtensionNames`
list so an MCP client can warn its operator when some extensions are
missing.

### File inventory

| File | Purpose |
|---|---|
| `lib/src/vm/service_extension_registry.dart` | Process-wide singleton + weak-ref dispatch |
| `lib/src/vm/service_extension_handlers.dart` | Seven pure handler functions + `envelopeOk` / `envelopeError` + cycle-safe sanitiser |
| `lib/src/vm/connection_mode.dart` | 5-state enum + `computeConnectionMode` |
| `lib/src/utils/session_uuid.dart` | `generateSessionUuid()` RFC 4122 v4 via `Random.secure()` |

### Modified files (M1)

- `lib/src/controller/sleuth_controller.dart`: a `sessionUuid` final field, an `initializedAt` getter with a setter for tests, `_extensionRegistry` constructed at the end of `initialize()` (debug and profile only), and `markDisposed()` called in `dispose()`.
- `lib/src/analyzer/causal_graph.dart`: `static List<Map<String, Object?>> get rulesJson` on `CausalGraphRule`.
- `lib/sleuth.dart`: the barrel exports `ConnectionMode` and `ServiceExtensionRegistry`.

### Reserved namespace

Sleuth reserves the `ext.sleuth.*` VM service extension namespace. Other
packages should choose a different prefix.

## M2: the `sleuth_mcp` sidecar package

M2 is a standalone Dart package at `packages/sleuth_mcp/`. It depends on
Dart only, not the Flutter SDK. The MCP stdio JSON-RPC server is written
by hand in about 150 lines, with no transport dependency.

### Discovery with `--uri` only

The user copies the VM service URI from the `flutter run` output (the
URI DevTools requires) and passes it to the sidecar:

```bash
sleuth_mcp --uri "ws://127.0.0.1:55555/<token>=/ws"
```

This is the only discovery mechanism in 0.1.0. Auto-discovery, by
parsing `flutter run --machine` output or through DevTools' service
registry, could follow if user feedback shows the manual copy step is a
real problem. Most MCP clients already ask for a VM service URI by hand,
so users know the step. Sidecar 0.2.0 shipped discovery: `attach_app`
runs `flutter attach --machine` and reads the URI from the daemon.

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

Tool names use the snake_case that MCP recommends. Every tool ships an
`inputSchema` JSON Schema with `type: "object"`, `properties` and a
`required` array. A missing required arg returns `isError: true`
content, not a JSON-RPC error.

| Tool | Args | Notes |
|---|---|---|
| `connect` | `uri` (required) | Establishes the bridge. Checks `packageVersion` against the sidecar's pin; emits `warning: "version_skew_minor"` or `error: "version_skew_major"` on drift. |
| `get_snapshot` | none | Pass-through of the `ext.sleuth.snapshot` envelope |
| `get_issues` | `route?`, `severityAtLeast?` | Client-side severity filter (case-insensitive) |
| `get_route_health` | `route?` | Pass-through |
| `explain_issue` | `stableId` (required) | Parametric stableIds resolve through `IssueExplanationBuilder.canonicalId` |
| `compare_snapshots` | `before` (object), `after` (object) | Pure client-side diff: added, removed and elevated issues, fpsDelta |
| `check_budgets` | `minFps`, `maxIssues`, `maxCriticalIssues` | Returns `{passed, violations, observed}` content. The CI exit-code path is the `sleuth_check` binary. |
| `diagnose` | none | Adds the sidecar version and pin to the app's diagnose payload |

### Resources

| URI | Content | Cached |
|---|---|---|
| `sleuth://encyclopedia` | `IssueExplanation` entries keyed by canonical id | Keyed by `sessionUuid` |
| `sleuth://causal-graph` | Full rule set | Keyed by `sessionUuid` |

The cache is dropped when the bridge's `sessionUuid` changes, which
happens on a hot restart of the target app. There is no polling. The
next tool call detects the change through the envelope's `sessionUuid`
field: the bridge throws `SessionChangedException`, and the server
returns it as `isError: true` content with
`session_changed baseline=X current=Y`.

### MCP protocol methods

- `initialize` reads `params.protocolVersion`, echoes the server's pin
  (`2024-11-05`) and logs a mismatch to stderr.
- `notifications/initialized` is accepted as a no-op.
- `tools/list` and `tools/call` cover eight tools.
- `resources/list` and `resources/read` cover two resources.
- `ping` returns an empty result.
- Any method other than `ping` before `initialize` returns JSON-RPC
  error `-32002`.
- An unknown method returns JSON-RPC error `-32601`.

### Per-tool timeout

Each `tools/call` times out after 10 seconds by default; `--tool-timeout
<seconds>` changes it. A timeout returns `isError: true` content
(`timeout_after_<n>ms`).

### CI gate with the `sleuth_check` binary

A separate one-shot binary serves CI. It exits 0 on a pass, 1 on a
violation and 2 on a connect or handler failure. Sample usage:

```bash
sleuth_check --uri "ws://..." --min-fps 55 --max-issues 10 --max-critical-issues 0 --json
```

The stdio sidecar's `check_budgets` tool returns the same report shape
as MCP content, with no exit code, so it suits AI conversation only.

## M3: schema doc and audit

M3 locks the response shapes of `ext.sleuth.*` and the eight MCP tools so
external clients can depend on stable JSON.

### Artefacts

1. `doc/mcp_schema.md`: a human-readable schema per extension and tool,
   with field names, types, nullability and the `connectionMode` that
   fills each field.
2. `test/validation/mcp_schema_audit_test.dart`: a fixture-driven
   guard. For each handler it builds a synthetic `SleuthController`,
   calls the handler and asserts that the response contains every
   documented field with the declared type. It catches renamed, retyped
   and dropped fields.

### Schema versioning

The root envelope field `schemaVersion` changes on any breaking change:
a field rename, a removal or a type change. New optional fields and new
extensions do not change it. At `connect` time the sidecar reads the
app's `packageVersion`, not `schemaVersion`, and warns on minor skew or
refuses on major skew.

### Audit enforcement

The audit test runs on every `fvm flutter test`. It uses fixtures only,
with no real app. It checks both directions: every documented field
appears in at least one handler output, and every key in a handler
output appears in the schema doc.

## Dependency graph

```
M1 (extensions in main package) ──► M2 (sidecar) ──► M3 (schema + audit)
```

M2 cannot ship before M1, and M3 must follow M2. M1 and M2 ship as one
release (sleuth 0.32.0 and sleuth_mcp 0.1.0). M3 follows soon after.

## Version targets

| Milestone | Sleuth | Sidecar |
|---|---|---|
| M1 + M2 | `0.32.0` | `0.1.0` |
| M3 | `0.33.0` | `0.3.0` |
| M4 | not shipped | not shipped |
| M5 | not shipped | not shipped |

## M4: hot-restart reconnect resilience (not shipped)

A hot restart can rebind the VM service on a new port. The attached
sidecar session then goes dead, and the agent must attach again by hand. M4
would recover on its own. On a `bridge.connect` drop (a socket close, or
a daemon `app.debugPort` with a changed port) it would resolve the VM
service again, through Bonjour on the iOS-direct route or the daemon
`app.debugPort` event on the daemon route, and reconnect while keeping
`sessionUuid` continuity. Retries would be bounded. It would return
`reconnect_failed`, or one of the existing `ios_vmservice_*` errors, when
it cannot recover.

- Sidecar only, with the library unchanged. It would touch
  `vm_bridge.dart` (the reconnect path) and `daemon_session.dart` (drop
  detection and the new resolve and attach).
- The plan targeted `sleuth_mcp` 0.7.0 pinned to sleuth 0.35.0. Not
  shipped: sidecar 0.7.0 added MCP prompts instead.

## M5: live issue stream (not shipped)

Agents poll `get_issues`. M5 would push issues as detectors emit them,
through MCP server-to-client notifications, so the agent can react. The
library would expose an emission stream through a new additive
`ext.sleuth.*` subscribe extension, or reuse the existing emission hook,
and the sidecar would relay each emission as an MCP notification. The
stream would be opt-in per session and bounded by backpressure, so a
noisy detector cannot flood the client.

- Library and sidecar. Additive, so the envelope `schemaVersion` stays
  `1`.
- The plan targeted sleuth 0.36.0 and `sleuth_mcp` 0.8.0. Not shipped:
  sidecar 0.8.0 pins sleuth 0.37.0 and has no issue stream.

## Risks

| Risk | Severity | Mitigation |
|---|---|---|
| `dart:developer.registerExtension` throws on a duplicate name after hot restart | Medium | Process-wide singleton + per-name `_bound` set; retry only unbound names |
| AI client misreads an empty `basic`-mode result as "no problems" | Medium | Every response carries `connectionMode`; the app reports `warmup` until the configured window elapses |
| Sidecar keeps a stale VM URI from a previous app | Medium | `sessionUuid` cross-check at every tool call; `SessionChangedException` returned inline |
| Schema drift between handler output and `mcp_schema.md` | Medium | The M3 audit checks both directions |
| Sidecar version skew with the main sleuth package | Medium | `connect` checks the version; emits `warning: version_skew_minor` or `error: version_skew_major` |
| Handler hang blocks the sidecar | Medium | Per-tool 10 s timeout returns `isError: true` content |
| Handler exception crashes the sidecar | High | A dispatcher try/catch wraps every handler call |
| `kSleuthPackageVersion` drifts from `pubspec.yaml` | Medium | `test/validation/package_version_audit_test.dart` enforces sync |
| Tight coupling between sleuth and sleuth_mcp | Medium | M3 schema audit + sidecar startup warning on version skew |

## Rollback notes

- M1: revert the registry construction in
  `SleuthController.initialize()` to turn it off. Existing callers are
  untouched.
- M2: ships as a separate `packages/sleuth_mcp/` publish. If it is
  yanked, the main sleuth package is unaffected.
- M3: a failing schema audit does not affect runtime. CI catches schema
  regressions, and reverting the offending handler change rolls them
  back.

## Out-of-scope follow-ups

- Auto-discovery by parsing `flutter run --machine` output, only if
  feedback shows the manual `--uri` step causes real friction. Shipped
  in `sleuth_mcp` 0.2.0 as `attach_app`, which runs
  `flutter attach --machine`.
- Write-side tools: toggle a detector, override thresholds, mute issues.
- HTTP transport for remote MCP clients.
- Aggregating several apps in one sidecar.
- A deep snapshot schema lock covering more of the payload shape, a
  higher priority because `get_snapshot` is the most-called tool.
  Shipped in sleuth 0.34.0.
- A tool-layer audit, of lower value because the tool tests already
  cover the transforms; it formalizes the contract. Shipped in
  `sleuth_mcp` 0.4.0.
