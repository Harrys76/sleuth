# MCP schema derivation

This note explains how the nested snapshot shapes in `mcp_schema.json`
were derived and how to regenerate them when fields change.

## Source captures

The nested-shape entries (`recurrenceTrends`, `sessionSummary`,
`routeSessions` and the `routes` list inside `routeHealth`) come from six
on-device snapshots in `test/validation/captures/mcp_snapshots/`:

- `snapshot_idle.json`: a fresh launch with no workload.
- `snapshot_repaint.json`: the `RepaintDetector` workload route.
- `snapshot_heavy_compute.json`: the `HeavyComputeDetector` workload route.
- `snapshot_recurrence.json`: repeated cycles that produce recurrence
  trends for several stableIds.
- `snapshot_routes.json`: navigation across several routes, which
  produces several `RouteSession` entries.
- `snapshot_memory.json`: a memory-pressure workload for the
  `memoryTrendSummary` shape.

Each capture is the raw `ext.sleuth.snapshot.data` payload, that is, the
contents of the OK envelope's `data` field. All six report
`packageVersion: "0.34.0"`, `isDebugMode: false` and
`isVmConnected: true`.

## Source device

The captures were collected on a real iPhone (iOS 17.5) running the
example app in profile mode with `SLEUTH_CAPTURE_MODE=true`, attached
over USB through `iproxy` (libimobiledevice). These snapshots check
payload shape only. The detector-capture audits skip `mcp_snapshots/`, so
the files do not feed the validation ledger.

Magnitudes inside `frameStatsSummary`, `memoryTrendSummary` and similar
maps come from that device run. Do not compare them with the
runtime-verified bracket thresholds, which use per-detector axes captured
under separate scenarios.

## Keys observed per container

`recurrenceTrends.<stableId>` (Map<String, Map>):

- `trend`: String, required. Values seen: `stable` in every capture, and
  `worsening` in the repaint capture.
- `totalOccurrences`: int, required.
- `totalObserved`: int, required.
- `lastSeenCycle`: int, required. No capture has a null value. The schema
  marks it nullable because the code emits null when the buffer is empty.
- `severityStats`: Map, optional. Emitted only when the trend has at
  least one present observation. Shape: `{min: int, max: int}`, where 1
  is ok, 2 is warning and 3 is critical. Every capture has trends with it
  and trends without it.

`sessionSummary` (Map):

- `topIssues`: List<Map>, present in all six captures. Item keys seen:
  `stableId`, `title`, `severity`, `confidence`, `confidenceReason` and
  `rankingScore` in every capture, and `widgetName` in every capture
  except the idle one.
- `frameHistogram`: Map<String, int>, present in all six captures. Its
  bucket keys are fixed: `<16ms`, `16-33ms`, `33-50ms`, `50-100ms`,
  `>100ms`.
- `detectorHitRates`: Map<String, int>, present in all six captures.
- `memoryTrendSummary`: Map, present in all six captures. Shape:
  `{startBytes, endBytes, peakBytes, growthRatePerSec, sampleCount}`.
- `causalEdges`: List<Map>, present in the repaint and recurrence
  captures and absent from the other four. Item shape:
  `{cause: String, effect: String}`.

Every capture had ranked issues, recorded frames and at least two heap
samples, so the first four keys looked required. The code omits
`topIssues` and `detectorHitRates` when no issue is ranked,
`frameHistogram` before the first frame, and `memoryTrendSummary` with
fewer than two heap samples. A top issue can also carry a null
`stableId`. `doc/mcp_schema.json` states these conditions, and the schema
audit checks live handler output as well as the captures.

`routeSessions[]` (List<Map>):

Present in every session of every capture:

- `routeName`: String
- `scaffoldHashKey`: int
- `tabVisitIndex`: int
- `startedAt`: String (ISO-8601)
- `healthScore`: num
- `durationSeconds`: num
- `scanCycles`: int
- `frameStats`: Map (see below)
- `issueCount`: int
- `criticalCount`: int
- `warningCount`: int
- `issues`: List<String>, the retained issue keys rather than full issue
  maps

The schema still marks `scaffoldHashKey` optional, because the code
omits it for a session created without a visible Scaffold. The captures
contain no such session.

Present in some sessions only, or in none of the captures:

- `endedAt`: String, present once the session is closed. The idle
  capture's only session is still open and omits it.
- `rebuildCountsByType`: Map<String, int>. No capture has it. The code
  emits it when `RebuildDetector` accumulates per-type counts during the
  session.
- `totalRebuilds`: int. Emitted under the same condition as
  `rebuildCountsByType`.
- `hotReloadGeneration`: int. No capture has it. The code emits it only
  for a session created after a hot reload.

`routeSessions[].frameStats` nested shape:

- `totalFrames`: int, required.
- `jankFrames`: int, required.
- `averageFps`: num, required.
- `p50`, `p95`, `p99`: num, the FPS percentiles clamped to the FPS
  target. They sit directly in `frameStats`, not under a
  `fpsPercentiles` map. Every session in the captures has them. The
  schema marks them optional because the code emits them only when the
  session holds at least two frames.

`widgetHeatMap` (top level): List<Map>, optional. It is present in five
of the six captures, all except `snapshot_idle.json`. The schema marks it
opaque and leaves the item shape undocumented, because no documented
consumer relies on its keys yet.

## Required, optional and nullable rules

- A nested key is `required: true` only when it appears in every
  capture's container. A key that every capture had can still be
  optional when the code omits it under some condition, as for the
  `sessionSummary` keys and `scaffoldHashKey` above.
- A key is `required: false` when at least one capture omits it. Each
  optional key has a `presence` predicate that names the condition.
- `nullable: true` marks a key whose value can be null. Two nested keys
  are nullable: `recurrenceTrends.<stableId>.lastSeenCycle` and
  `sessionSummary.topIssues[].stableId`. No capture has a null nested
  value, so both rules come from the code.

## How to regenerate captures

1. Run the example app on a real iPhone, not an emulator. Use iOS 17.5 to
   match the shipped captures. Exercise the workload you want, and reach
   `connectionMode: full` or `correlated` with the steps in the
   *Reaching full mode* section of the root `README.md`. On a degraded
   session the sidecar adds `launchModeAdvisory` to `data`, and the audit
   rejects that undocumented key.
2. From an MCP client (Claude Desktop, Inspector) connected through the
   `sleuth_mcp` sidecar, call `get_snapshot` with `verbose: true` once
   the workload has reached the state you want. Without `verbose: true`
   the sidecar trims every entry in `currentIssues`.
3. Save the response's `data` block, not the full envelope, to
   `test/validation/captures/mcp_snapshots/snapshot_<scenario>.json`. The
   separate directory keeps these raw snapshot exports apart from the
   detector-reproducer captures, which a different audit checks.
4. Run the audit again with
   `fvm flutter test test/validation/mcp_schema_audit_test.dart`. Its
   `checkSnapshotCapturesMatchSchema` test checks every capture against
   the documented snapshot shape, at the top level and at every depth
   where the schema defines a `shape`, `item_shape` or `value_shape` map.
   Required keys must be present, values must match their documented
   type, nullability and allowed values, and no capture may carry an
   undocumented key.

## Schema DSL

`doc/mcp_schema.json` describes each field with a small set of keys:

- `type`, `required` and `nullable` give the basic contract for the
  field.
- `presence` is a free-text predicate that names when an optional key
  appears.
- `values` lists the allowed values of a string field.
- `value` fixes a single value, such as `schemaVersion: 1` in the
  envelope.
- `buckets` lists the exact key set of a map, such as `frameHistogram`.
- `shape` is an inline `Map<String, FieldSpec>` that describes the keys
  of a Map field. The audit descends into it.
- `item_shape` applies to `List<...>` fields. A Map is applied to each
  item, and the audit descends into the items. A String is a reference.
  The audit resolves two references to the shapes they name:
  `"see ext.sleuth.snapshot.data.routeSessions item_shape"` and
  `"same as ext.sleuth.explain.data.explanation"`. It does not descend
  into other references, such as `"PerformanceIssue.toJson()"`, and
  records the path as skipped when the list holds maps.
- `value_shape` works like `item_shape` for `Map<*, *>` fields and
  applies to each map value.
- `opaque: true` marks a field that the audit does not validate below
  the container. `_opaque_reason` says why. Only `widgetHeatMap` carries
  it, until a documented consumer relies on its item shape.

The audit skips the schema metadata keys (`_doc`, `_shape_source`,
`_modes`, `_opaque_reason`) and any entry whose value is not a map, such
as `_projection_note`. These entries document the schema itself.

## Limitations

- The audit descends through `shape`, `item_shape` and `value_shape`
  maps and through the two string references named above. Other string
  references stay opaque. The audit prints them as skipped so the
  coverage gap stays visible.
- `routeHealth.data.route` uses `value_shape` for the session map
  itself, not for each value inside it. The audit checks that entry
  against the session shape directly.
- The shapes describe the MCP wire format as observed. The Dart model
  classes can hold more fields than their `toJson()` methods emit.
