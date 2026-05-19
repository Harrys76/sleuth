# MCP Schema Derivation

How the nested snapshot shapes in `mcp_schema.json` were derived, and how
to regenerate them when fields change.

## Source captures

The snapshot nested-shape entries (`recurrenceTrends`, `sessionSummary`,
`routeSessions`, the `routes` list inside `routeHealth`) are derived from
six on-device snapshots under `test/validation/captures/mcp_snapshots/`:

- `snapshot_idle.json` — fresh launch, no exercised workload
- `snapshot_repaint.json` — `RepaintDetector` workload route
- `snapshot_heavy_compute.json` — `HeavyComputeDetector` workload route
- `snapshot_recurrence.json` — repeated cycles producing recurrence
  trends across multiple stableIds
- `snapshot_routes.json` — multi-route navigation producing multiple
  `RouteSession` entries
- `snapshot_memory.json` — memory-pressure workload exercising the
  `memoryTrendSummary` shape

Each capture is the raw `ext.sleuth.snapshot.data` payload (the contents
of the OK envelope's `data` field).

## Source device

Captures collected on a real iPhone (iOS 17.5) running the example app
in profile mode under `SLEUTH_CAPTURE_MODE=true`, attached over USB via
`iproxy` (libimobiledevice). The runtimeVerified reproducer-tier ledger
targets the same iOS 17.5 lineage; nested-shape derivation here aligns
with that ledger.

Magnitudes inside `frameStatsSummary`, `memoryTrendSummary`, etc. are
device-runtime artefacts and should not be cross-referenced against
the runtime-verified bracket thresholds — those operate on
per-detector axes captured under separate scenarios.

## Per-container observed keys

`recurrenceTrends.<stableId>` (Map<String, Map>):

- `trend` — String, required, values seen: `stable`
- `totalOccurrences` — int, required
- `totalObserved` — int, required
- `lastSeenCycle` — int, required
- `severityStats` — Map, optional. Only emitted when at least one
  present observation exists. Shape: `{min: int, max: int}` (1 = ok,
  2 = warning, 3 = critical). Seen in idle + repaint captures; omitted
  from heavy-compute + recurrence + routes + memory when the trend's
  observed entries are all absent.

`sessionSummary` (Map):

- `topIssues` — List<Map>, required. Item shape:
  `{stableId, title, severity, confidence, confidenceReason, rankingScore}`
- `frameHistogram` — Map<String, int>, required. Fixed bucket keys:
  `<16ms`, `16-33ms`, `33-50ms`, `50-100ms`, `>100ms`
- `detectorHitRates` — Map<String, int>, required
- `memoryTrendSummary` — Map, optional. Shape:
  `{startBytes, endBytes, peakBytes, growthRatePerSec, sampleCount}`
- `causalEdges` — List<Map>, optional. Present in repaint + recurrence;
  absent in idle + heavy-compute + routes + memory captures. Item
  shape: `{cause: String, effect: String}`

`routeSessions[]` (List<Map>):

Required across every capture:

- `routeName` — String
- `scaffoldHashKey` — int
- `tabVisitIndex` — int
- `startedAt` — String (ISO-8601)
- `healthScore` — num
- `durationSeconds` — num
- `scanCycles` — int
- `frameStats` — Map (see below)
- `issueCount` — int
- `criticalCount` — int
- `warningCount` — int
- `issues` — List<String> (stableIds, not full issue maps)

Optional (presence varies by capture):

- `endedAt` — String, present once the session is closed. Idle capture's
  active session omits it.
- `rebuildCountsByType` — Map<String, int>, optional. Not present in any
  of the six captures, but emitted when `RebuildDetector` accumulates
  per-type counts during the session.
- `totalRebuilds` — int, optional. Same conditional path as
  `rebuildCountsByType`.

`routeSessions[].frameStats` nested shape:

- `totalFrames` — int, required
- `jankFrames` — int, required
- `averageFps` — num, required
- `p50` / `p95` / `p99` — int, required (microseconds; emitted as
  top-level keys on the per-route frame-stats summary, not nested under
  a `fpsPercentiles` sub-map)

`widgetHeatMap` (top-level): List<Map>, optional. Present in 5 of 6
captures (every capture except `snapshot_idle.json`). Documented as
opaque-list — nested item shape deferred since no documented consumer
relies on the item keys today.

## Required / optional / nullable rules

- A nested key is `required: true` only when it appears in **every**
  capture's container instance.
- A key is `required: false` (optional) when at least one capture omits
  it. Each optional key carries a `presence` predicate naming the
  condition.
- `nullable: true` is reserved for keys whose value is explicitly `null`
  in at least one capture. None of the snapshot nested fields are
  nullable today; every observed value is non-null when the key is
  present.

## How to regenerate captures

1. Run the example app against a real iPhone (iOS 17.5 to match the
   shipped captures; emulator regens are NOT supported because the
   captures inform the runtimeVerified ledger which targets the real
   iOS 17.5 lineage — see *Source device* above). Exercise the
   relevant workload; see `README.md` § *Reaching full mode* for the
   steps that drive `connectionMode: full` / `correlated`.
2. From an MCP client (Claude Desktop, Inspector) connected through the
   `sleuth_mcp` sidecar, call `get_snapshot` once the workload has
   reached the desired state.
3. Save the response's `data` block (NOT the full envelope) to
   `test/validation/captures/mcp_snapshots/snapshot_<scenario>.json`
   (the dedicated subdirectory keeps these raw snapshot exports
   separate from detector-reproducer captures, which are
   shape-validated by a different audit).
4. Re-run the audit: `fvm flutter test test/validation/mcp_schema_audit_test.dart`.
   The `checkSnapshotCapturesMatchSchema` invariant cross-checks every
   documented `required: true` snapshot key — at the top level AND at
   every nested depth where the schema defines a `shape` / `item_shape`
   / `value_shape` Map — against every capture.

## Schema DSL

`doc/mcp_schema.json` describes each field with a small set of keys:

- `type`, `required`, `nullable` — the basic per-field contract.
- `presence` — free-text predicate naming when an optional key appears.
- `values` — enum list for string-valued fields.
- `shape` — inline `Map<String, FieldSpec>` describing required-key
  structure for a Map-typed field. The capture audit recurses into
  this branch.
- `item_shape` — for `List<...>` fields. If a Map, applied to each item
  (the audit recurses into the items). If a String (e.g.
  `"PerformanceIssue.toJson()"`, `"see ext.sleuth.snapshot..."`), the
  shape is an opaque reference — the audit records the path under
  *opaque skips* in test output and does not descend.
- `value_shape` — same as `item_shape` but for `Map<*, *>` fields,
  applied to each map value.
- `opaque: true` — explicit marker that the field is intentionally
  not validated below the container level. `_opaque_reason` documents
  why. Currently only `widgetHeatMap` carries this — its item shape
  is deferred until a documented consumer exists.

The schema-meta keys (`_doc`, `_shape_source`, `_modes`,
`_opaque_reason`) are skipped by the audit; they exist as in-schema
documentation.

## Limitations

- The audit walks `shape` / `item_shape` (Map) / `value_shape` (Map)
  branches. String-valued `item_shape` / `value_shape` references
  (e.g. `"see ext.sleuth.snapshot.data.routeSessions item_shape"`)
  remain opaque — the audit surfaces them as *skipped* entries so the
  coverage gap is visible.
- The shape contract describes the **MCP wire** as observed; the
  underlying Dart model classes may carry additional fields stripped
  by their `toJson()` methods.
