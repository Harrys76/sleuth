# MCP schema for the ext.sleuth.* extensions

This file describes the envelopes of the seven `ext.sleuth.*` VM service extensions. The sleuth_mcp sidecar and other MCP clients can rely on these shapes within `schemaVersion: 1`.

[`mcp_schema.json`](mcp_schema.json) is the source of truth, and the audit test parses it. This markdown is a readable copy.

**schemaVersion policy.** `schemaVersion` changes on a breaking change: a field rename, a removal or a type change. New optional fields and new handlers do not change it. The sidecar does not read `schemaVersion`. It checks `packageVersion` from `ext.sleuth.diagnose` instead. A different version in its pinned lineage connects with `version_skew_minor`, and the accepted prior lineage connects with `version_skew_prior_lineage`. Any other lineage is refused with `version_skew_major`, and a value that is not semver is refused with `version_skew_unknown`.

## Envelope

Every handler returns one of the envelope shapes below.

### OK envelope

| Field | Type | Required | Nullable | Notes |
|---|---|---|---|---|
| `connectionMode` | String | yes | no | one of `disconnected` / `warmup` / `basic` / `full` / `correlated` |
| `schemaVersion` | int | yes | no | `1` for this contract |
| `sessionUuid` | String | yes | no | changes when sleuth initializes, for example after a hot restart |
| `data` | Map | yes | no | per-handler shape below |

`connectionMode` is the best frame verdict so far, not the state of the VM link. `warmup` covers the first seconds after sleuth initializes. `basic` means no frame has a VM-tier verdict yet: either sleuth has no VM service link, or it has one and no frame has received a verdict since it connected. Sleuth publishes verdicts for jank frames only, so a smooth session with a live VM link stays `basic` while its VM-backed detectors run. `ext.sleuth.diagnose` and `ext.sleuth.issues` report the link itself as `data.vmConnected`, and `ext.sleuth.snapshot` reports it as `data.isVmConnected`.

### Error envelope

| Field | Type | Required | Nullable | Notes |
|---|---|---|---|---|
| `connectionMode` | String | yes | no | same values as the OK envelope |
| `schemaVersion` | int | yes | no | `1` |
| `sessionUuid` | String | yes | no | |
| `error` | String | yes | no | machine-readable error code |
| `stack` | String | no | no | present only when the handler caught an exception |
| _extra_ | _various_ | no | varies | handler-specific keys, such as `route` for `unknown_route` |

### Disposed controller

After the app's `SleuthController` is disposed, every handler returns `{connectionMode: "disconnected", schemaVersion: 1, disposed: true, method}`, with no `sessionUuid` and no `data`. If a handler throws while the controller is being disposed, the same shape also carries `error`.

## Handlers

### `ext.sleuth.diagnose`

Operational health. No args.

| `data` key | Type | Required | Nullable |
|---|---|---|---|
| `packageVersion` | String | yes | no |
| `initializedAtMicros` | int | yes | yes |
| `vmConnected` | bool | yes | no |
| `captureMode` | bool | yes | no |
| `lastCaptureExportFailure` | String | yes | yes |
| `unboundExtensionNames` | List\<String\> | yes | no |
| `effectiveFrameRateHz` | num | yes | no |
| `frameBudgetUs` | int | yes | no |
| `frameRateSource` | String (`fixed` / `display` / `measured`) | yes | no |
| `lastPollRpcMicros` | int | yes | yes |
| `lastPollDecodeMicros` | int | yes | yes |
| `lastPollParseMicros` | int | yes | yes |
| `lastPollDispatchMicros` | int | yes | yes |
| `lastPollDispatchDetectorsMicros` | int | yes | yes |
| `lastPollDispatchCorrelateMicros` | int | yes | yes |
| `lastPollDispatchAggregateMicros` | int | yes | yes |
| `lastPollDispatchOtherMicros` | int | yes | yes |
| `lastPollTailMicros` | int | yes | yes |
| `lastPollTailMemoryMicros` | int | yes | yes |
| `lastPollTailCpuSamplesMicros` | int | yes | yes |
| `lastPollTailAllocationProfileMicros` | int | yes | yes |
| `lastPollEventCount` | int | yes | yes |
| `lastPollResponseChars` | int | yes | yes |
| `maxPollRpcMicros` | int | yes | yes |
| `maxPollDecodeMicros` | int | yes | yes |
| `maxPollParseMicros` | int | yes | yes |
| `maxPollDispatchMicros` | int | yes | yes |
| `pollDuplicatesDropped` | int | yes | yes |
| `pollWindowFallbacks` | int | yes | yes |

The `*Poll*` keys describe the VM timeline poll loop. They are null until the first poll of the current VM session.

- `lastPoll*Micros` split the most recent poll into segments. `Rpc` is the `getVMTimeline` await in wall time, including the work in the VM and the transport. `Decode` is the part of `Rpc` after the raw response arrived, spent on the UI isolate decoding the JSON and building the `Timeline`. It is null when the response could not be matched to the request, even after the first poll. `Parse` is the timeline parse and the stale-begin sweep. `Dispatch` is the detector callback. `Tail` is the remaining RPCs, in wall time.
- `Decode`, `Parse` and `Dispatch` block the UI isolate. The rest of `Rpc`, and `Tail`, are awaits.
- `lastPollDispatch{Detectors,Correlate,Aggregate,Other}Micros` split `Dispatch` into the detector feed and evaluation, frame correlation and the verdict, issue aggregation and ranking, and everything else. They sum to `Dispatch`.
- `lastPollTailMemoryMicros` is the `getMemoryUsage` await inside `Tail`. `lastPollTail{CpuSamples,AllocationProfile}Micros` are the parts of `Tail` during which a `getCpuSamples` or `getAllocationProfile` request was in flight. They overlap each other and the memory await.
- `lastPollEventCount` is the raw event count. `lastPollResponseChars` is the raw response length, or null when the response could not be matched.
- `maxPoll*Micros` are maxima over the last 32 polls. `maxPollDecodeMicros` is null when none of those polls was matched.
- `pollDuplicatesDropped` sums the events skipped as already processed. `pollWindowFallbacks` counts the polls that read the whole timeline buffer because the timeline clock could not bound a fetch window.

### `ext.sleuth.snapshot`

`SessionSnapshot.toJson()`, defined in `lib/src/models/session_snapshot.dart`.

**Args.** All args are optional. With none, the handler returns the full payload, as it did before projection existed.

| arg | Type | Notes |
|---|---|---|
| `sections` | String | comma-separated `SnapshotSection` keys, matched without regard to case or surrounding whitespace. Only the listed payload sections serialize; metadata keys always do. An unknown name returns `arg_invalid_section`. |
| `maxIssueCount` | String (int) | keeps the top N already-ranked `currentIssues`. A negative or non-numeric value returns `arg_invalid_int`. Setting it while `sections` leaves out `currentIssues` returns `arg_pagination_unused`. |
| `maxRouteCount` | String (int) | keeps the N most recent `routeSessions` by `startedAt`. Errors as for `maxIssueCount`, with `routeSessions` in place of `currentIssues`. |

When any projection arg is set, a payload field is present only if its section is in `_projectedSections`. A cap without `sections` lists every section there. Metadata keys (`schemaVersion`, `exportedAt`, `packageVersion`, `isVmConnected`, `isDebugMode`, `suppressedCount`) always serialize.

| `data` key | Type | Required | Presence |
|---|---|---|---|
| `_projectedSections` | List\<String\> | no | when any projection arg was set; the included section keys, sorted alphabetically |
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
| `widgetHeatMap` | List\<Map\> | no | when at least one issue has been ranked (heat-map is derived from ranked issues). Opaque: the item shape stays undocumented until a sidecar consumer relies on its keys. |
| `recurrenceTrends` | Map\<String, Map\> | no | when populated |
| `sessionSummary` | Map | no | when at least one of its keys is present (an issue is ranked, the frame-stats buffer is non-empty, or at least two heap samples are buffered); every key inside is conditional |
| `startupMetrics` | Map | no | when `Sleuth.init` captured first-frame data |
| `routeSessions` | List\<Map\> | no | when the route history is not empty |

#### `recurrenceTrends.<stableId>` sub-shape

| Key | Type | Required | Presence |
|---|---|---|---|
| `trend` | String | yes | one of `stable` / `worsening` / `improving` / `intermittent` |
| `totalOccurrences` | int | yes | always |
| `totalObserved` | int | yes | always |
| `lastSeenCycle` | int | yes | always; null when the buffer is empty |
| `severityStats` | Map | no | when the trend has at least one present observation. Shape: `{min: int, max: int}` |

#### `sessionSummary` sub-shape

Every key is conditional. A session with frames and no ranked issue carries only `frameHistogram`.

| Key | Type | Required | Presence |
|---|---|---|---|
| `topIssues` | List\<Map\> | no | when at least one issue is ranked; the top 5 ranked issues. Item shape below. |
| `frameHistogram` | Map\<String, int\> | no | when the frame-stats buffer is non-empty (same condition as recentFrames); all five buckets always present. Buckets: `<16ms`, `16-33ms`, `33-50ms`, `50-100ms`, `>100ms` |
| `detectorHitRates` | Map\<String, int\> | no | when at least one issue is ranked (same condition as topIssues); counts every ranked issue by detector name |
| `memoryTrendSummary` | Map | no | when MemoryPressureDetector has at least two heap samples buffered. Shape: `{startBytes, endBytes, peakBytes, growthRatePerSec, sampleCount}` |
| `causalEdges` | List\<Map\> | no | when at least two issues are ranked and CausalGraphRule.activeEdges finds at least one edge between them. Item shape: `{cause, effect}` |

`topIssues[]` item shape:

| Key | Type | Required | Nullable | Presence |
|---|---|---|---|---|
| `stableId` | String | yes | yes | always; null for an issue without a stableId (custom detectors) |
| `title` | String | yes | no | always |
| `severity` | String | yes | no | `ok` / `warning` / `critical` |
| `confidence` | String | yes | no | `confirmed` / `likely` / `possible` |
| `confidenceReason` | String | no | no | when the issue carries a confidence reason |
| `rankingScore` | int | yes | no | always |
| `widgetName` | String | no | no | when the issue names a widget |

#### `routeSessions[]` item shape

| Key | Type | Required | Presence |
|---|---|---|---|
| `routeName` | String | yes | always |
| `scaffoldHashKey` | int | no | when the session was created from an Element subtree carrying a visible Scaffold (always true for real-device captures; absent for scaffold-free overlay sessions) |
| `tabVisitIndex` | int | yes | always |
| `hotReloadGeneration` | int | no | only when > 0, that is, when the session was created after at least one hot reload |
| `startedAt` | String (ISO-8601) | yes | always |
| `endedAt` | String (ISO-8601) | no | once the session has been closed |
| `healthScore` | num | yes | always |
| `durationSeconds` | num | yes | always |
| `scanCycles` | int | yes | always |
| `frameStats` | Map | yes | shape `{totalFrames, jankFrames, averageFps, p50?, p95?, p99?}`. The p-values are FPS percentiles, present only when `frameStats.length >= 2`. |
| `issueCount` | int | yes | always; distinct issue keys retained for the session (at most 256) |
| `criticalCount` | int | yes | always; critical issues among the retained keys |
| `warningCount` | int | yes | always; warning issues among the retained keys |
| `issues` | List\<String\> | yes | the retained keys (stableId, else the issue title) in first-seen order, not full issue maps |
| `rebuildCountsByType` | Map\<String, int\> | no | when RebuildDetector accumulated per-type counts during the session; at most 256 widget types |
| `totalRebuilds` | int | no | when RebuildDetector accumulated per-type counts during the session; sums the retained types only |

A session keeps at most 256 issue keys and 256 widget types. On overflow it evicts the oldest-inserted key first. `issueCount`, `criticalCount`, `warningCount` and `issues` describe the retained keys, and `totalRebuilds` sums only the retained `rebuildCountsByType` entries, so a session that crossed either cap undercounts.

`doc/mcp_schema_derivation.md` in the sleuth repository describes how these nested shapes were derived and where the captures came from.

### `ext.sleuth.issues`

The current aggregated issues. Args: `route` (String, optional). With a non-empty `route`, the handler keeps the issues whose `routeName` or `sourceRoute` equals it.

| `data` key | Type | Required | Presence |
|---|---|---|---|
| `issues` | List\<Map\> | yes | always; item shape = `PerformanceIssue.toJson()` |
| `route` | String | no | only when the route arg was non-empty |
| `vmConnected` | bool | yes | always; the same flag as `ext.sleuth.diagnose` `data.vmConnected`, which tells a VM-connected `basic` session from one without a VM link |

### `ext.sleuth.routeHealth`

Health per route. Args: `route` (String, optional).

The OK envelope's `data` carries exactly one of `routes` (a list) or `route` (one session), so a consumer can branch on the key instead of the value's type.

| `data` key | Type | Presence |
|---|---|---|
| `routes` | List\<Map\> | only when the `route` arg is absent; the item shape is the same as `snapshot.data.routeSessions[]` above |
| `route` | Map | only when the `route` arg matches a session, which is then the last matching session in the route history; same shape as a `routes` item |

**Errors:** `unknown_route`, with extra `{route: String}`, when no session matches the `route` arg.

The underlying shape is `RouteSession.toJson()` in `lib/src/models/route_session.dart`. The `snapshot.data.routeSessions[]` table above documents the wire shape of an item.

### `ext.sleuth.explain`

The encyclopedia entry for a stableId. Args: `stableId` (String, required, `minLength: 1`).

Sleuth 0.37 and later fill the placeholders (`{routeName}`, `{widgetName}`, `{count}`, `{severity}`, `{title}`, `{stableId}`) from the live issue with the exact `stableId`. A canonical (bare) id with no exact match uses the first live issue of that family. Everything else gets neutral wording. An occurrence id, for example `excessive_keep_alive:PageView~k-home`, with no exact live match gets neutral wording and never another occurrence's values. `encyclopedia` entries always use neutral wording. Apps on sleuth 0.36 return the raw templates, with the `{placeholder}` tokens in place, from both `explain` and `encyclopedia`.

| `data` key | Type | Required | Notes |
|---|---|---|---|
| `stableId` | String | yes | as passed |
| `canonical` | String | yes | resolved with `IssueExplanationBuilder.canonicalId` |
| `explanation` | Map | yes | shape below |

**`explanation` sub-shape:**

| Key | Type | Required | Nullable | Notes |
|---|---|---|---|---|
| `displayName` | String | yes | no | |
| `category` | String | yes | no | `build` / `layout` / `paint` / `raster` / `memory` / `channel` / `font` / `network` / `startup` |
| `whatItIs` | String | yes | no | |
| `readingTheData` | String | yes | no | |
| `whyItMatters` | String | yes | no | |
| `howToFix` | String | yes | no | |
| `whenToIgnore` | String | yes | yes | null when the entry has no ignore guidance, for example `heavy_compute` |
| `relatedIssues` | List\<String\> | yes | no | |

**Errors:** `missing_required_arg` (extra `{arg: 'stableId'}`) and `unknown_stable_id` (extra `{stableId, canonical}`).

### `ext.sleuth.encyclopedia`

Every available explanation. No args.

| `data` key | Type | Required | Notes |
|---|---|---|---|
| `count` | int | yes | `entries.length` |
| `entries` | Map\<String, Map\> | yes | key = canonical stableId; value = same shape as `explain.data.explanation` |

### `ext.sleuth.causalGraph`

The rules that link trigger stableIds to their downstream effects. No args.

| `data` key | Type | Required | Notes |
|---|---|---|---|
| `count` | int | yes | `rules.length` |
| `rules` | List\<Map\> | yes | each item is `{trigger: String, effect: String}` |

## Sidecar tool layer

The `sleuth_mcp` sidecar exposes 13 MCP tools that wrap or transform the
envelopes above. In the sleuth repository,
`packages/sleuth_mcp/doc/mcp_tool_schema.json` locks the tool return
shapes, `packages/sleuth_mcp/doc/mcp_tool_schema.md` renders them, and
`packages/sleuth_mcp/test/schema/mcp_tool_schema_audit_test.dart` checks
them. Those files exist only in the sidecar package. The sleuth root has
no `mcp_tool_schema.{json,md}`, and the audit checks that it does not.

`get_route_health` and `explain_issue` return the envelopes above
unchanged. `get_snapshot` and `get_issues` trim each issue to a compact
key set unless the client passes `verbose: true`, and `get_issues` also
filters by severity and keeps the top 50 issues by default. Both add
`launchModeAdvisory` to `data` on a degraded session.

## Notes

- The nested snapshot shapes come from on-device captures in `test/validation/captures/mcp_snapshots/`. `doc/mcp_schema_derivation.md` describes the procedure and the limits of the device context.
- The MCP tool-layer schema ships only in the sidecar archive. The root sleuth package does not ship `mcp_tool_schema.{json,md}`.
