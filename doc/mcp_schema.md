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

Full `SessionSnapshot.toJson()`. No args. Underlying shape in `lib/src/models/session_snapshot.dart`.

| `data` key | Type | Required | Presence |
|---|---|---|---|
| `schemaVersion` | int | yes | always |
| `exportedAt` | String (ISO-8601) | yes | always |
| `packageVersion` | String | yes | always |
| `isVmConnected` | bool | yes | always |
| `isDebugMode` | bool | yes | always |
| `frameStatsSummary` | Map | yes | always |
| `capturedFrames` | List\<Map\> | yes | always |
| `currentIssues` | List\<Map\> | yes | always |
| `suppressedCount` | int | no | only when > 0 |
| `recentRequests` | List\<Map\> | no | when NetworkMonitorDetector is enabled and the request ring buffer is non-empty |
| `heapSamples` | List\<Map\> | no | when MemoryPressureDetector has at least one sample buffered |
| `phaseEvents` | List\<Map\> | no | when the controller's rolling timeline-event buffer is non-empty |
| `gcEvents` | List\<Map\> | no | when GC events have been observed on the timeline stream |
| `platformChannelEvents` | List\<Map\> | no | when platform-channel events have been observed on the timeline stream |
| `recentFrames` | List\<Map\> | no | when the frame-stats buffer is non-empty |
| `widgetHeatMap` | List\<Map\> | no | when at least one issue has been ranked (heat-map is derived from ranked issues) |
| `recurrenceTrends` | Map | no | when populated |
| `sessionSummary` | Map | no | when populated |
| `startupMetrics` | Map | no | when `Sleuth.init` captured first-frame data |
| `routeSessions` | List\<Map\> | no | when route history non-empty |

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
| `routes` | List\<Map\> | only when `route` arg absent — item shape = `RouteSession.toJson()` |
| `route` | Map | only when `route` arg matches a session — shape = `RouteSession.toJson()` |

**Errors:** `unknown_route` (extra: `{route: String}`) when the `route`
arg has no matching session.

Underlying shape: `RouteSession.toJson()` in `lib/src/models/route_session.dart`.

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
**sidecar-tool-layer responsibility** and will be schema-locked in
`sleuth_mcp` v0.4.0 alongside the `packages/sleuth_mcp/test/schema/`
audit. Until that release lands, consumers can rely on the following
shapes as a stable best-effort contract:

- `connect` — `{connected: bool, vmServiceUri: String, sessionUuid: String,
  connectionMode: String, sidecarVersion: String, appPackageVersion: String,
  warning?: 'version_skew_minor'}`. Major lineage skew returns an error
  `ToolCallResult` with text prefix `version_skew_major:`.
- `attach_app`, `detach_app`, `app_status`, `hot_reload` — JSON-encoded
  `AppStatusPayload.toJson()` (`packages/sleuth_mcp/lib/src/flutter_daemon/app_status.dart`).
- `list_devices` — `{devices: List, count: int, filteredBy: String}`.
- `get_snapshot`, `get_issues`, `get_route_health`, `explain_issue` — pass
  through the corresponding `ext.sleuth.*` envelope verbatim (or with a
  documented filter overlay, e.g. `get_issues` adds `severityAtLeast`).
- `diagnose` — wraps `ext.sleuth.diagnose` and augments `data` with
  `sidecarVersion` + `sidecarBuiltAgainstSleuth`.
- `compare_snapshots`, `check_budgets` — pure client-side, no app call;
  return shapes documented in `packages/sleuth_mcp/lib/src/tools/`.

The v0.4.0 audit will lock these shapes byte-for-byte. Adopt the above
shapes today knowing that breaking changes (renames, removals, type
changes) will bump the sidecar minor version before they ship.

## Deferred to follow-up releases

- Deeper schema for `snapshot` + `routeHealth` (currently delegated to model `toJson()` source).
- MCP tool-layer audit (sidecar tool transforms over these envelopes). Lands with `packages/sleuth_mcp/test/schema/` audit.
- Initial v0.33.0 schema authored from current handler source. Future drift is caught by the audit, but v0.32.0-era implementation quirks (if any) are locked in. v0.34.0 will rebase from captured real-device output to break this tautology.
- Snapshot fields `recurrenceTrends`, `sessionSummary`, `routeSessions` are documented as opaque containers — nested shape unconstrained.
