# MCP tool schema for sleuth_mcp

This file describes the return shapes of the 13 MCP tools that `sleuth_mcp` exposes. AI clients, and CI scripts that use `sleuth_check`, can rely on these shapes within `schemaVersion: 2`.

**Compact issues (`schemaVersion: 2`).** By default `get_issues` and `get_snapshot` trim each issue to `severity`, `category`, `confidence`, `title`, `detail`, `fixHint`, `stableId`, `widgetName`, `routeName`, `sourceRoute`, `confidenceReason` and `rootCauseIds`, copying only the keys that are present. Pass `verbose: true` for the full issue, which has up to 26 keys. Compaction removes fields only and keeps `stableId` and `severity`, so `compare_snapshots` and `check_budgets` work on compact snapshots.

[`mcp_tool_schema.json`](mcp_tool_schema.json) is the source of truth, and the audit test parses it. This markdown is a readable copy.

**Sidecar only.** The root sleuth package does not ship this file. The root `mcp_schema.{json,md}` documents the `ext.sleuth.*` envelopes; this file documents how the tools wrap them.

**Error envelopes.** A handler reports an error as `ToolCallResult.text(<message>, isError: true)`. The `code` of each entry in `errors[]` is the literal prefix of that text. There is no typed error class, so clients match on the prefix. Argument validation and dispatch errors apply to every tool and are listed once under [Server-level errors](#server-level-errors).

**Tool kinds.**

- `direct`: the handler builds the data map itself.
- `client_side`: the handler computes the result and makes no `ext.sleuth.*` call.
- `wraps`: the handler calls one `ext.sleuth.*` extension and reshapes its data.
- `passthrough`: the handler returns the `ext.sleuth.*` envelope unchanged, apart from the shims listed for the tool.

**Read-only hint.** Every descriptor sets `annotations.readOnlyHint`. It is `false` for `connect`, `attach_app`, `detach_app` and `hot_reload`, and `true` for the rest, so a client that honors the hint can approve the read-only tools without asking each time. `readOnlyTools` in `mcp_tool_schema.json` lists them, and the audit checks the descriptors against that list.

**Behavior hints.** Descriptors also set `destructiveHint`, `idempotentHint` and `openWorldHint`. `toolAnnotations` in `mcp_tool_schema.json` lists the values per tool, and the audit checks the descriptors against it. Among the read-only tools, `openWorldHint` is true for the ones that read the live app or host (`get_snapshot`, `get_issues`, `get_route_health`, `explain_issue`, `diagnose`, `check_budgets`, `list_devices`). It is false for `compare_snapshots`, which diffs its own input, and for `app_status`, which reports server state. `detach_app` sets `destructiveHint: true` because it ends the session and deletes disk-handoff files. Read-only tools omit `destructiveHint` and `idempotentHint`, which the MCP spec ignores unless `readOnlyHint` is false. The audit checks that the descriptors and this doc agree. It does not check that a hint matches what the handler does; that is a judgment against the MCP spec. The hints are advisory metadata, so `schemaVersion` stays `2`.

**Structured content.** A client that negotiates MCP protocol `2025-06-18` or later also gets a top-level `structuredContent` object on every successful `tools/call` result. It holds the same JSON as the text block, so the client does not need to parse the text. Clients on `2024-11-05` or `2025-03-26` get the text block only. Error results never carry `structuredContent`. No per-tool `data`, `args` or `errors` shape changes, so `schemaVersion` stays `2`.

## connect

Kind `direct`. Args: `uri` (String, required).

| `data` key | Type | Required | Notes |
|---|---|---|---|
| `connected` | bool | yes | always `true` on success |
| `vmServiceUri` | String | yes | echoes the arg |
| `sessionUuid` | String | yes | from `ext.sleuth.diagnose` |
| `connectionMode` | String | yes | one of `disconnected` / `warmup` / `basic` / `full` / `correlated` |
| `sidecarVersion` | String | yes | the sidecar's own version (`sleuthMcpVersion`) |
| `appPackageVersion` | String | yes (nullable) | the app's reported `kSleuthPackageVersion` |
| `warning` | String | no | `version_skew_minor` (a different version in the pinned lineage) or `version_skew_prior_lineage` (the accepted prior lineage, 0.36) |
| `launchModeAdvisory` | String | no | present when `connectionMode` is `warmup` or `disconnected`, or `basic` without a live VM self-connect, which means the VM-only detectors are off; asks for a `flutter run --profile --no-dds` relaunch |

**Errors:**

- `missing_required_arg: uri`
- `invalid_uri: <FormatException message>`
- `version_skew_major: app=<v> sidecar-pin=<v> — refusing to serve; align sleuth dep with sidecar version. Bridge disconnected.`: the app's lineage is neither the pin's nor the accepted prior lineage.
- `version_skew_unknown: diagnose envelope missing or malformed packageVersion stamp (got "<v>") — cannot verify wire contract. Bridge disconnected.`: `packageVersion` is absent, not a String, or not a semver `major.minor.patch`. An optional `-prerelease` or `+build` suffix keeps the version's lineage, so `0.37.0-dev.1` is in the 0.37 lineage. `(got "<v>")` appears only when the value is a String.

## attach_app

Kind `direct`. Three routing modes:

- `udid`: an iOS UDID. Runs the iOS attach pipeline and requires `bundle`. The pipeline looks for a VM service the app already announces over Bonjour, launches the app with `xcrun devicectl` when none is announced, opens an `iproxy` tunnel on USB or uses the `.local` host on wireless, and connects the bridge.
- `debugUrl`: a WebSocket URI. Connects directly, skipping both the flutter daemon and the iOS pipeline.
- `device`: a device id or name. Attaches through `flutter attach --machine`.

When both `device` and `debugUrl` are set, `debugUrl` wins.

Args:

| arg | type | purpose |
|---|---|---|
| `device` | String, optional | flutter daemon route. Cannot be combined with `udid`. |
| `debugUrl` | String, optional | direct WebSocket route. Cannot be combined with `udid`. |
| `udid` | String, optional | iOS device UDID. Selects the iOS-direct path. |
| `bundle` | String, optional (required with `udid`) | iOS bundle identifier |
| `transport` | String, optional | `auto` (default) / `usb` / `wireless` |
| `authOverride` | String, optional | iOS only. Pins the Bonjour authCode when more than one pairing is announced. |
| `forceRelaunch` | bool, optional (default `false`) | iOS only. Skips the Bonjour check and runs `xcrun devicectl process launch`. Recovers from a stale mDNS cache without restarting the sidecar. |

Data shape: `AppStatusPayload.toJson()`, defined in `packages/sleuth_mcp/lib/src/flutter_daemon/app_status.dart`.

| `data` key | Type | Required | Presence |
|---|---|---|---|
| `attached` | bool | yes | always |
| `state` | String | yes | one of `idle` / `attaching` / `ready` / `restarting` / `detaching` / `error` |
| `device` | String | no | states other than `idle` |
| `appId` | String | no | states other than `idle` |
| `sessionUuid` | String | no | after `ext.sleuth.diagnose` succeeds |
| `launchMode` | String | no | `attach` / `run` from the daemon (`attach` on a `debugUrl` session), or `ios-direct` |
| `mode` | String | no | `debug` / `profile` / `release` from the daemon; `unknown` on a `debugUrl` session; `profile` on an iOS-direct session |
| `lastError` | String | no | when `state == 'error'` |
| `transportMode` | String | no | `wired` / `wireless` / `unknown`; present only when `launchMode == 'ios-direct'` |
| `wsUri` | String | no | iOS-direct sessions only |
| `warning` | String | no | same values as `connect.warning`: `version_skew_minor` (a different version in the pinned lineage) or `version_skew_prior_lineage` (the accepted prior lineage); attached sessions only |
| `launchModeAdvisory` | String | no | present when `connectionMode` is `warmup` or `disconnected`, or `basic` without a live VM self-connect, which means the VM-only detectors are off; asks for a `flutter run --profile --no-dds` relaunch |

An attach that fails without throwing, for example a spawn failure, a refused `debugUrl` or a non-mobile `device`, returns this payload with `state: error` and a `lastError` instead of an error result.

**Errors:**

- `internal: daemon session not initialized`: the server is misconfigured.
- `version_skew_major: …` / `version_skew_unknown: …`: the attach reached `ready`, then the bridge's version check refused the app. The sidecar detaches before it returns the error.
- `already attached or attaching (state=<state>); call detach_app first`: a session is already attached or attaching.
- `<DaemonSessionException.message>`: a daemon RPC failed.

**iOS errors.** These set `isError: true` and carry two text blocks: `<code>: <message>`, then a JSON object `{error, message, ...data}`. Before it returns `ios_vmservice_busy` or `ios_vmservice_unreachable`, the sidecar retries once when the first connection was reset or refused, excluding that port from the Bonjour selection.

- `ios_missing_bundle`: `udid` was given without `bundle`.
- `ios_ambiguous_args`: `udid` was combined with `device` or `debugUrl`.
- `ios_invalid_transport`: `transport` is not `auto`, `usb` or `wireless`. Carries `data.allowed`. Through `tools/call` the server's enum check rejects such a value first with `arg_enum_violation`.
- `ios_missing_tool`: `xcrun` or `dns-sd` is not on PATH, or `iproxy` is missing on a USB attach. Carries `data.tool` and `data.remedy`.
- `ios_launch_failed`: `xcrun devicectl process launch` exited non-zero. Carries `data.exitCode` and `data.stderr`.
- `ios_bonjour_timeout`: no VM service announcement arrived within the collect budget.
- `ios_ambiguous_pairings`: more than one distinct authCode was announced. Carries `data.distinctAuthCodes`; pass one of them as `authOverride`. Without `authOverride` the sidecar first tries each announced code and keeps the one whose VM service connects, so this error reaches the client only when the 90-second attach budget ran out before it could try them.
- `ios_no_matching_auth`: `authOverride` matched no announcement. Carries `data.authCodes`.
- `ios_iproxy_failed`: `iproxy` failed to start or exited inside the readiness window. Carries `data.stderr` when `iproxy` printed anything.
- `ios_cancelled`: a caller-supplied cancellation fired during the pipeline.
- `ios_vmservice_busy`: the bridge connection was reset after the handshake because the VM service on the device still holds a prior session. Carries `data.remedy`: swipe the app off the device, or rebuild the profile binary.
- `ios_vmservice_unreachable`: the bridge connection was refused, or the handshake timed out after 10 seconds. The `iproxy` tunnel is open but nothing answers on the device side, usually because a stale Bonjour cache pinned a port the new service has not bound. Carries `data.remedy`: wait about 30 seconds for the mDNS cache to clear, or swipe the app off the device and retry.
- `attach_in_progress`: another iOS attach is already running on this `DaemonSession`, so the second call is rejected.

## detach_app

Kind `direct`. No args. Returns the same `AppStatusPayload.toJson()` shape as `attach_app` and deletes the files that `get_snapshot` wrote for `diskHandoff`.

**Errors:** `internal: daemon session not initialized`.

## app_status

Kind `direct`. No args. Returns the same `AppStatusPayload.toJson()` shape as `attach_app`.

**Errors:** `internal: daemon session not initialized`.

## hot_reload

Kind `direct`. No args. Returns the same `AppStatusPayload.toJson()` shape as `attach_app`.

A `debugUrl` session has no flutter daemon to send `r` to. On such a session `hot_reload` returns the status payload with `state: error` and a `lastError` that names the cause, not an error result. A failed or timed-out reload RPC is reported the same way.

**Errors:**

- `internal: daemon session not initialized`
- `<StateError.message>`: the session is not attached (`state` is not `ready`).
- `hot_reload_unsupported`: a typed envelope, shaped like the iOS errors, returned when `launchMode == 'ios-direct'`. That path attaches through the VM service without a flutter daemon, so hot reload is not available. Carries `data.remedy`.

## list_devices

Kind `direct`. Args: `mobileOnly` (bool, optional, default `true`). The sidecar caches the `flutter devices --machine` output for 3 seconds.

| `data` key | Type | Required | Notes |
|---|---|---|---|
| `devices` | List\<Map\> | yes | the raw daemon entries, filtered when `mobileOnly` is true |
| `count` | int | yes | `devices.length` |
| `filteredBy` | String | yes | `mobile` (default) or `none` |

**Errors:**

- `flutter not on PATH or failed to run: <ProcessException.message>`
- `<DaemonSessionException.message>`

## compare_snapshots

Kind `client_side`. Args: `before` (Map, required, the snapshot's `data` block) and `after` (Map, required).

Issues aggregate per stableId into the highest severity across its occurrences and the occurrence count. A new critical occurrence beside an existing warning with the same stableId shows in `elevatedSeverity`, and a second occurrence shows in `countChanged`.

| `data` key | Type | Required | Notes |
|---|---|---|---|
| `added` | List\<String\> | yes | stableIds present in `after` but not in `before` |
| `removed` | List\<String\> | yes | stableIds present in `before` but not in `after` |
| `elevatedSeverity` | List\<Map\> | yes | item shape `{stableId, before, after}` with severity strings; stableIds in both whose highest severity rose |
| `countChanged` | List\<Map\> | yes | item shape `{stableId, before, after}` with occurrence counts; stableIds in both whose count changed |
| `fpsDelta` | double | yes (nullable) | `afterFps - beforeFps`. Declared nullable, but the current code returns a `snapshot …` error instead of null when a side has neither `frameStatsSummary.averageFps` nor `actualFps`. |
| `beforeFps` | double | yes (nullable) | |
| `afterFps` | double | yes (nullable) | |
| `coverageWarning` | String | no | present when neither snapshot had a VM service link. It starts with `vm_detectors_not_observed:` and names the VM-only stableIds the diff cannot cover. |

**Errors:**

- `arg "before" must be object (SessionSnapshot data)`
- `arg "after" must be object (SessionSnapshot data)`
- `arg_capped_issues_uncomparable`: one or both inputs were projected with `maxIssueCount`. A truncated top-N window cannot be diffed, because an issue that left the window looks the same as one that was resolved.
- `arg_section_mismatch`: the inputs were projected to different sections or with different pagination limits.
- `arg_lineage_mismatch`: the two `packageVersion` values fall in different sleuth `major.minor` lineages, or either is missing or not semver. Detector ids and defaults change between lineages, so the diff would report instrumentation changes as app changes.
- `arg_coverage_mismatch`: only one snapshot had a VM service link, or either lacks a boolean `isVmConnected`. A snapshot counts as having no link when it reports `isVmConnected: false` or carries a `launchModeAdvisory`. VM-only detectors report nothing without a link, so their issues would read as resolved or new.
- `snapshot …`: a snapshot lacks or mistypes `currentIssues`, `currentIssues[].stableId` or `severity`, or the `frameStatsSummary` fps (schema drift).

## check_budgets

Kind `wraps` (`ext.sleuth.snapshot`). Args: `minFps` (num, required), `maxIssues` (int, required) and `maxCriticalIssues` (int, required). The tool requests the full snapshot. It refuses with `coverage_degraded` when the snapshot's `isVmConnected` is false or not a bool. A `basic` session with `isVmConnected: true` is evaluated normally. `sleuth_check` uses the same evaluator and exits `2` on any of the errors below.

| `data` key | Type | Required | Notes |
|---|---|---|---|
| `passed` | bool | yes | `violations.isEmpty` |
| `violations` | List\<Map\> | yes | item shape `{budget, expected, observed}`; `budget` is one of `minFps` / `maxIssues` / `maxCriticalIssues` |
| `observed` | Map | yes | `{fps: double?, issueCount: int, criticalCount: int}` |

**Errors:**

- `minFps must be number`
- `maxIssues must be integer`
- `maxCriticalIssues must be integer`
- `snapshot envelope had no data field`: the bridge returned a malformed envelope.
- `arg_capped_issues_unbudgetable`: the snapshot was projected with `maxIssueCount`, so its issue list is truncated and the budget counts would be wrong.
- `arg_missing_required_section`: the snapshot was projected without a section the budgets need (`currentIssues` or `frameStatsSummary`).
- `coverage_degraded`: the snapshot reports `isVmConnected: false`, or no boolean, so the VM-only detectors never ran and a pass would not cover memory, CPU or repaint issues.
- `snapshot …`: the snapshot lacks or mistypes `currentIssues`, `currentIssues[].severity`, or the `frameStatsSummary` fps (schema drift).

Through `tools/call`, the server's type check rejects a wrongly typed argument first with `arg_type_mismatch`. The tool and `sleuth_check` request the full snapshot, so the two `arg_*` errors fire only when other code passes a projected snapshot to `evaluateBudgets`.

## diagnose

Kind `wraps` (`ext.sleuth.diagnose`). No args.

The tool returns the extension's `data` block with two keys the sidecar adds, plus `launchModeAdvisory` on a degraded session:

| `data` key | Type | Required | Notes |
|---|---|---|---|
| (all keys from `ext.sleuth.diagnose.data`) | | | passed through; see `mcp_schema.md` |
| `sidecarVersion` | String | yes | `sleuthMcpVersion` |
| `sidecarBuiltAgainstSleuth` | String | yes | `sleuthPackageVersionPin` |
| `launchModeAdvisory` | String | no | present when `connectionMode` is `warmup` or `disconnected`, or `basic` without a live VM self-connect, which means the VM-only detectors are off; asks for a `flutter run --profile --no-dds` relaunch |

Apps on sleuth 0.36 do not report the keys added in sleuth 0.37.0: `effectiveFrameRateHz`, `frameBudgetUs`, `frameRateSource`, and the `lastPoll*`, `maxPoll*`, `pollDuplicatesDropped` and `pollWindowFallbacks` timings.

## get_snapshot

Kind `passthrough` (`ext.sleuth.snapshot`). Args: `sections` (List\<String\>, optional; forwarded as a comma-joined string; an empty list or no value returns the full payload, not metadata only), `maxIssueCount` (int, optional), `maxRouteCount` (int, optional), `diskHandoff` (bool, optional) and `verbose` (bool, optional, default `false`).

An app error envelope (one with a top-level `error`) comes back inline and is never written to disk.

**Shim `compact_issues`.** Unless `verbose: true`, the sidecar trims every `data.currentIssues` entry to the compact key set (`severity`, `category`, `confidence`, `title`, `detail`, `fixHint`, `stableId`, `widgetName`, `routeName`, `sourceRoute`, `confidenceReason`, `rootCauseIds`), copying only the keys that are present. It runs on both the inline and the disk-handoff path and builds a new map, so the bridge envelope is never changed. It does nothing when `sections` left out `currentIssues`, or when `currentIssues` is missing or not a list. It changes field shape only. `maxIssueCount` caps `currentIssues` in the app whether or not `verbose` is set.

**Shim `disk_handoff`.** When `diskHandoff` is true, the sidecar writes the envelope to `Directory.systemTemp/sleuth_snapshot_<pid>/<random>.json` and returns `{path, sizeBytes, sha256}`, plus any projection metadata, instead of the inline `data` block. Use it for snapshots larger than the client's response token cap. The file name is 128 random bits from `Random.secure()`. The sidecar creates the per-process directory with mode `0700` and the file with mode `0600`, and checks both with `FileStat`. On POSIX, if it cannot set and confirm owner-only permissions, it deletes the file and returns `disk_handoff_failed`. Windows has no POSIX modes, so the check is skipped there. The payload can hold sensitive data, such as query tokens in `recentRequests[].url`, which is why a permission failure stops the handoff. The sidecar deletes the files on `detach_app` and at shutdown, and each new write removes files older than 30 minutes from its own process directory. Each process has its own directory, so one sidecar never removes another's in-flight file. Without `diskHandoff` the envelope comes back inline.

**Lineage fallback (an app older than sleuth 0.35).** Such an app ignores the projection args and returns the full payload. On the disk-handoff path the sidecar writes it and stamps `_projectionApplied: by_sidecar_fallback`. On the inline path it returns `projection_unsupported_by_app` instead, because the full inline payload would overflow the response cap that projection exists to avoid. Sidecar 0.8.0 refuses apps older than the 0.36 lineage when it connects, so a connected app does not reach this path.

**Shim `launch_mode_advisory`.** On a degraded session (`connectionMode` `warmup` or `disconnected`, or `basic` with `isVmConnected: false`), the sidecar adds `data.launchModeAdvisory`. A client that reads data here, not only through `connect` or `diagnose`, learns that the VM-only detectors are off. On the disk-handoff path the advisory is in the written file's `data`.

**Errors:** `arg_invalid_section`, `arg_invalid_int` and `arg_pagination_unused` come back as the app's `ext.sleuth.snapshot` error envelope. `projection_unsupported_by_app` is an inline projection request to an app older than sleuth 0.35. `disk_handoff_failed` means the sidecar could not lock the temp directory or file to owner-only permissions, or could not pick an unused file name, and wrote nothing.

The underlying shape is in the `ext.sleuth.snapshot` section of `mcp_schema.md`.

## get_issues

Kind `passthrough` (`ext.sleuth.issues`). Args: `route` (String, optional; an empty string counts as absent; the app keeps issues whose `routeName` or `sourceRoute` equals it), `severityAtLeast` (String, optional, one of `ok` / `warning` / `critical`; the server rejects any other value, including upper case, with `arg_enum_violation`), `maxIssueCount` (int, optional, default 50; `0` means no cap) and `verbose` (bool, optional, default `false`).

**Shim `severity_filter`.** When `severityAtLeast` is `warning` or `critical`, the sidecar keeps only the entries in `data.issues` at or above that severity. Whenever `severityAtLeast` is set, including `ok`, the sidecar adds `data.severityAtLeast` with the requested level; `ok` applies no filter. When it is absent there is no filter and no echo.

**Shim `compact_projection`.** After the severity filter, the sidecar keeps the first `maxIssueCount` entries of `data.issues` in the app's ranked order. The default is 50, `0` removes the cap, and a negative value returns `arg_invalid_int`, as in `get_snapshot`. Unless `verbose: true`, it then trims each kept entry to the compact key set (`severity`, `category`, `confidence`, `title`, `detail`, `fixHint`, `stableId`, `widgetName`, `routeName`, `sourceRoute`, `confidenceReason`, `rootCauseIds`). The cap and the trim are independent: `verbose` changes field shape only and never disables the cap. Compaction drops fields but never shortens a value, so it does not bound the response size; use `maxIssueCount` here, or `get_snapshot` with `diskHandoff`. When the cap drops at least one issue, `data` gains `_truncated: true` and `_totalCount`, the count after the filter and before the cap. An envelope without a `data` map or an `issues` list, such as an error envelope, comes back unchanged.

**Shim `launch_mode_advisory`.** On a degraded session the sidecar adds `data.launchModeAdvisory`, warning that the issue list is incomplete because the VM-only detectors are off. The `ext.sleuth.issues` payload has no VM flag, so `get_issues` adds the advisory on every `basic` session, including one whose VM is connected while its verdict warms up.

**Errors:** `arg_invalid_int` for a negative `maxIssueCount`. An `ext.sleuth.issues` error envelope comes back unchanged.

The underlying shape is in the `ext.sleuth.issues` section of `mcp_schema.md`. Compact entries hold a subset of its keys.

## get_route_health

Kind `passthrough` (`ext.sleuth.routeHealth`). Args: `route` (String, optional; an empty string counts as absent). The envelope comes back unchanged. Every accepted lineage wraps a single-route match as `{route: <session>}`.

**Errors:** `unknown_route`, the app's error envelope, passed through unchanged.

The underlying shape is in the `ext.sleuth.routeHealth` section of `mcp_schema.md`.

## explain_issue

Kind `passthrough` (`ext.sleuth.explain`). Args: `stableId` (String, required, `minLength: 1`).

The text depends on live app state. Sleuth 0.37 and later fill the route, widget and count text from the live issue with that exact stableId. A canonical (bare) id with no exact match uses the first live issue of its family. Any other id with no exact match, such as an occurrence id, gets neutral wording, as does a canonical id with no live issue in its family. Sleuth 0.36 apps return the raw placeholders (`{widgetName}`, `{routeName}`, `{count}`).

**Errors:**

- `missing_required_arg: stableId`: no `stableId` was given. An empty string fails the server's `minLength` check with `arg_min_length_violation` instead.
- `unknown_stable_id`: `ext.sleuth.explain` returned this error envelope, which comes back unchanged.

The underlying shape is in the `ext.sleuth.explain` section of `mcp_schema.md`.

## Server-level errors

`McpServer` checks every `tools/call` against the tool's `inputSchema` before the handler runs, and it wraps dispatch failures. These errors use the same envelope as the per-tool errors (`isError: true`, with the code as the message prefix). `serverErrors` in `mcp_tool_schema.json` lists them.

- `missing_required_arg: <name>`: an arg in `inputSchema.required` is absent, or null (the message then ends in `(null)`).
- `arg_unknown: <name> (allowed: …)`: an arg that `inputSchema.properties` does not declare.
- `arg_type_mismatch: <name> expected <type> got <type>`: the JSON type differs from the declared type. An integer satisfies `number`.
- `arg_enum_violation: <name>=<value> not in [...]`: a value outside the declared `enum`.
- `arg_min_length_violation: <name> must be at least <n> chars`: a string shorter than `minLength`.
- `unknown_tool: <name>`: no tool is registered under that name.
- `missing "name" arg` / `arguments must be a JSON object`: the `tools/call` params are malformed.
- `timeout_after_<ms>ms — bridge disconnected; re-invoke connect`: a tool without its own deadlines exceeded the generic timeout (10 seconds by default, set with `--tool-timeout`). The server disconnects the bridge, so the client must connect again.
- `session_changed baseline=<uuid> current=<uuid>`: the app's session changed during the call.
- `error: <exception>`: the handler threw. The stack trace goes to the log only.

## Recovery from a refused connection

When `connect` or `attach_app` returns a `version_skew_*` error, the bridge is already disconnected. To recover:

1. Move the app's `sleuth` dependency to the lineage in `sidecarBuiltAgainstSleuth`. An earlier `diagnose` call reports it, and `sleuth_mcp --version` prints it.
2. Hot-restart the app (`R`) so the new `kSleuthPackageVersion` takes effect, then run `connect` or `attach_app` again.
