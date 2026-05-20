# MCP Schema — ext.sleuth.* wire contract

Locked wire shapes for the 7 `ext.sleuth.*` VM service extensions. Consumers (sleuth_mcp sidecar, third-party MCP clients) can rely on these envelope shapes within `schemaVersion: 1`.

Structured source-of-truth: [`mcp_schema.json`](mcp_schema.json) — that file is what the audit test parses. This markdown is human-readable rendering only.

**schemaVersion policy.** Bumps on breaking change (field rename, removal, type change). Adding optional fields or new handlers does NOT bump. The sidecar's `connect` tool warns on `version_skew_minor` and refuses on `version_skew_major`.

## Envelope

Every handler returns one of two envelope shapes.

### OK envelope

| Field | Type | Required | Nullable | Notes |
|---|---|---|---|---|
| `connectionMode` | String | yes | no | one of `disconnected` / `warmup` / `basic` / `full` / `correlated` |
| `schemaVersion` | int | yes | no | `1` for this contract |
| `sessionUuid` | String | yes | no | rotates on sleuth init (hot restart) |
| `data` | Map | yes | no | per-handler shape below |

### Error envelope

| Field | Type | Required | Nullable | Notes |
|---|---|---|---|---|
| `connectionMode` | String | yes | no | same enum as OK |
| `schemaVersion` | int | yes | no | `1` |
| `sessionUuid` | String | yes | no | |
| `error` | String | yes | no | machine-readable error code |
| `stack` | String | no | no | only present when an exception was caught |
| _extra_ | _various_ | no | varies | handler-specific keys (e.g. `route` for `unknown_route`) |

## Handlers

### `ext.sleuth.diagnose`

Operational health snapshot. No args.

| `data` key | Type | Required | Nullable |
|---|---|---|---|
| `packageVersion` | String | yes | no |
| `initializedAtMicros` | int | yes | yes |
| `vmConnected` | bool | yes | no |
| `captureMode` | bool | yes | no |
| `lastCaptureExportFailure` | String | yes | yes |
| `unboundExtensionNames` | List\<String\> | yes | no |

### `ext.sleuth.snapshot`

`SessionSnapshot.toJson()`. Underlying shape in `lib/src/models/session_snapshot.dart`.

**Args** (all optional; absent = full payload, backward-compatible):

| arg | Type | Notes |
|---|---|---|
| `sections` | String | comma-separated `SnapshotSection` keys (case-insensitive, whitespace-tolerant). Only listed payload sections serialize; metadata keys always do. Unknown name → `arg_invalid_section`. |
| `maxIssueCount` | String (int) | keep top-N already-ranked `currentIssues`. Non-negative integer; non-numeric → `arg_invalid_int`; set without `currentIssues` in `sections` → `arg_pagination_unused`. |
| `maxRouteCount` | String (int) | keep N most-recent `routeSessions` by `startedAt`. Same error semantics as `maxIssueCount`. |

When any projection arg is set, payload-bearing fields are present only if their section is in `_projectedSections`. Metadata keys (`schemaVersion`, `exportedAt`, `packageVersion`, `isVmConnected`, `isDebugMode`, `suppressedCount`) always serialize.

| `data` key | Type | Required | Presence |
|---|---|---|---|
| `_projectedSections` | List\<String\> | no | when any projection arg was set; alphabetically sorted included section keys |
| `_projectionLimits` | Map | no | when `maxIssueCount` or `maxRouteCount` was set |
| `_projectionApplied` | String | no | when any projection arg was set; `by_app` or `by_sidecar_fallback` |
| `schemaVersion` | int | yes | always |
| `exportedAt` | String (ISO-8601) | yes | always |
| `packageVersion` | String | yes | always |
| `isVmConnected` | bool | yes | always |
| `isDebugMode` | bool | yes | always |
| `frameStatsSummary` | Map | yes | always, unless projected out via sections |
| `capturedFrames` | List\<Map\> | yes | always, unless projected out via sections |
| `currentIssues` | List\<Map\> | yes | always, unless projected out via sections |
| `suppressedCount` | int | no | only when > 0 |
| `recentRequests` | List\<Map\> | no | when NetworkMonitorDetector is enabled and the request ring buffer is non-empty |
| `heapSamples` | List\<Map\> | no | when MemoryPressureDetector has at least one sample buffered |
| `phaseEvents` | List\<Map\> | no | when the controller's rolling timeline-event buffer is non-empty |
| `gcEvents` | List\<Map\> | no | when GC events have been observed on the timeline stream |
| `platformChannelEvents` | List\<Map\> | no | when platform-channel events have been observed on the timeline stream |
| `recentFrames` | List\<Map\> | no | when the frame-stats buffer is non-empty |
| `widgetHeatMap` | List\<Map\> | no | when at least one issue has been ranked (heat-map is derived from ranked issues) — **opaque** (item-shape intentionally undocumented pending a sidecar consumer) |
| `recurrenceTrends` | Map\<String, Map\> | no | when populated |
| `sessionSummary` | Map | no | when populated |
| `startupMetrics` | Map | no | when `Sleuth.init` captured first-frame data |
| `routeSessions` | List\<Map\> | no | when route history non-empty |

#### `recurrenceTrends.<stableId>` sub-shape

| Key | Type | Required | Presence |
|---|---|---|---|
| `trend` | String | yes | one of `stable` / `worsening` / `improving` / `intermittent` |
| `totalOccurrences` | int | yes | always |
| `totalObserved` | int | yes | always |
| `lastSeenCycle` | int | yes | always (nullable when the buffer is empty) |
| `severityStats` | Map | no | when the trend has at least one present observation — shape `{min: int, max: int}` |

#### `sessionSummary` sub-shape

| Key | Type | Required | Presence |
|---|---|---|---|
| `topIssues` | List\<Map\> | yes | always; item shape `{stableId, title, severity, confidence, confidenceReason, rankingScore}` |
| `frameHistogram` | Map\<String, int\> | yes | fixed buckets `<16ms`, `16-33ms`, `33-50ms`, `50-100ms`, `>100ms` |
| `detectorHitRates` | Map\<String, int\> | yes | always |
| `memoryTrendSummary` | Map | no | when MemoryPressureDetector has accumulated at least one sample — shape `{startBytes, endBytes, peakBytes, growthRatePerSec, sampleCount}` |
| `causalEdges` | List\<Map\> | no | when CausalGraphRule.apply produced at least one active edge — item shape `{cause, effect}` |

#### `routeSessions[]` item shape

| Key | Type | Required | Presence |
|---|---|---|---|
| `routeName` | String | yes | always |
| `scaffoldHashKey` | int | no | when the session was created from an Element subtree carrying a visible Scaffold (always true for real-device captures; absent for scaffold-free overlay sessions) |
| `tabVisitIndex` | int | yes | always |
| `hotReloadGeneration` | int | no | only when > 0 (i.e. session created after at least one hot reload) |
| `startedAt` | String (ISO-8601) | yes | always |
| `endedAt` | String (ISO-8601) | no | once the session has been closed |
| `healthScore` | num | yes | always |
| `durationSeconds` | num | yes | always |
| `scanCycles` | int | yes | always |
| `frameStats` | Map | yes | shape `{totalFrames, jankFrames, averageFps, p50?, p95?, p99?}` — p-values present only when `frameStats.length >= 2` |
| `issueCount` | int | yes | always |
| `criticalCount` | int | yes | always |
| `warningCount` | int | yes | always |
| `issues` | List\<String\> | yes | stableIds only — not full issue maps |
| `rebuildCountsByType` | Map\<String, int\> | no | when RebuildDetector accumulated per-type counts during the session |
| `totalRebuilds` | int | no | when RebuildDetector accumulated per-type counts during the session |

Derivation procedure + capture provenance: [`mcp_schema_derivation.md`](mcp_schema_derivation.md).

### `ext.sleuth.issues`

Currently-aggregated issues. Args: `route` (String, optional — filter by `routeName` or `sourceRoute`).

| `data` key | Type | Required | Presence |
|---|---|---|---|
| `issues` | List\<Map\> | yes | always; item shape = `PerformanceIssue.toJson()` |
| `route` | String | no | only when route arg was non-empty |

### `ext.sleuth.routeHealth`

Per-route health rollup. Args: `route` (String, optional).

OK envelope data carries exactly one of `routes` (list) or `route`
(single) — consumers branch on the key, never on the value's runtime
shape.

| `data` key | Type | Presence |
|---|---|---|
| `routes` | List\<Map\> | only when `route` arg absent — item shape mirrors `snapshot.data.routeSessions[]` above |
| `route` | Map | only when `route` arg matches a session — same shape as the `routes` item above |

**Errors:** `unknown_route` (extra: `{route: String}`) when the `route`
arg has no matching session.

Underlying shape: `RouteSession.toJson()` in `lib/src/models/route_session.dart`. Wire item shape is documented in the `snapshot.data.routeSessions[]` table above.

### `ext.sleuth.explain`

Encyclopedia entry for a stableId. Args: `stableId` (String, **required**, `minLength: 1`).

| `data` key | Type | Required | Notes |
|---|---|---|---|
| `stableId` | String | yes | as-passed |
| `canonical` | String | yes | resolved via `IssueExplanationBuilder.canonicalId` |
| `explanation` | Map | yes | shape below |

**`explanation` sub-shape:**

| Key | Type | Required |
|---|---|---|
| `displayName` | String | yes |
| `category` | String | yes |
| `whatItIs` | String | yes |
| `readingTheData` | String | yes |
| `whyItMatters` | String | yes |
| `howToFix` | String | yes |
| `whenToIgnore` | String | yes |
| `relatedIssues` | List\<String\> | yes |

**Errors:** `missing_required_arg` (extra: `{arg: 'stableId'}`), `unknown_stable_id` (extra: `{stableId, canonical}`).

### `ext.sleuth.encyclopedia`

Every available explanation. No args.

| `data` key | Type | Required | Notes |
|---|---|---|---|
| `count` | int | yes | `entries.length` |
| `entries` | Map\<String, Map\> | yes | key = canonical stableId; value = same shape as `explain.data.explanation` |

### `ext.sleuth.causalGraph`

Rule set linking trigger stableIds to downstream effects. No args.

| `data` key | Type | Required | Notes |
|---|---|---|---|
| `count` | int | yes | `rules.length` |
| `rules` | List\<Map\> | yes | each: `{trigger: String, effect: String}` |

## Sidecar tool layer

The `sleuth_mcp` sidecar exposes 13 MCP tools that wrap (or transform)
the `ext.sleuth.*` envelopes above. Tool-call return shapes are
schema-locked in [`packages/sleuth_mcp/doc/mcp_tool_schema.json`](../packages/sleuth_mcp/doc/mcp_tool_schema.json)
(human-readable render at [`mcp_tool_schema.md`](../packages/sleuth_mcp/doc/mcp_tool_schema.md))
and audited by `packages/sleuth_mcp/test/schema/mcp_tool_schema_audit_test.dart`.
That file is sidecar-only — the sleuth root carries no parallel
`mcp_tool_schema.{json,md}` and the parity audit asserts the absence.

Passthrough tools (`get_snapshot`, `get_issues`, `get_route_health`,
`explain_issue`) preserve the wire envelopes above verbatim, with one
documented shim: `get_route_health` normalizes the legacy v0.32 inline
`RouteSession` shape into the v0.33 `{route: <session>}` wrapper when an
`acceptedPriorLineages` app is connected.

## Notes

- Snapshot nested shapes derived from on-device captures in `test/validation/captures/`. See [`mcp_schema_derivation.md`](mcp_schema_derivation.md) for the procedure and device-context limitations.
- The MCP tool-layer schema lives in the sidecar archive only; the root sleuth package does not ship `mcp_tool_schema.{json,md}`.
