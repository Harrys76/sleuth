# MCP Tool Schema — sleuth_mcp wire contract

Locked tool-call return shapes for the 13 MCP tools exposed by `sleuth_mcp`. Consumers (AI clients, CI scripts via `sleuth_check`) can rely on these shapes within `schemaVersion: 2`.

**`schemaVersion: 2` — compact-issue projection.** `get_issues` and `get_snapshot` now trim each issue to an actionable subset by default (`severity`, `category`, `confidence`, `title`, `detail`, `fixHint`, `stableId`, `widgetName`, `routeName`, `sourceRoute`, `confidenceReason`, `rootCauseIds` — only present keys copied). Pass `verbose: true` for the full ~22-field shape. Compaction is field-only and keeps `stableId` + `severity`, so `compare_snapshots` and `check_budgets` still operate on compact snapshots.

Structured source-of-truth: [`mcp_tool_schema.json`](mcp_tool_schema.json) — that file is what the audit test parses. This markdown is human-readable rendering only.

**Sidecar-only.** This file does not ship in the root sleuth pub archive. The root `mcp_schema.{json,md}` documents the `ext.sleuth.*` wire envelopes; tool-layer wrapping lives here.

**Error envelopes.** Each handler returns `ToolCallResult.text(<message>, isError: true)` on the documented error codes. The `code` listed in each `errors[]` entry appears verbatim as the prefix of the text content. A centralized typed error class is acknowledged debt — message-prefix matching is the current contract.

**Tool categories.**

- `direct` — handler builds the data map directly.
- `client_side` — pure compute, no `ext.sleuth.*` call.
- `wraps` — calls one `ext.sleuth.*` extension and reshapes the data.
- `passthrough` — returns the `ext.sleuth.*` envelope unmodified (or with a documented shim).

**Read-only annotations.** Every descriptor carries `annotations.readOnlyHint` — `true` for read-only tools, `false` for `connect`/`attach_app`/`detach_app`/`hot_reload`. Annotation-aware clients can auto-approve the read-only set. Locked in `mcp_tool_schema.json` (`readOnlyTools`) and enforced by the audit.

**Structured content (transport, cross-cutting).** For clients that negotiate MCP protocol `2025-06-18` or later, every **success** `tools/call` result also carries a top-level `structuredContent` field — the same JSON the text content block carries, as an object — so clients consume it without re-parsing the text. Clients on older protocol versions (`2024-11-05`, `2025-03-26`) receive the text content only. `structuredContent` is never set on error results. This is additive and doesn't alter any per-tool `data`/`args`/`errors` shape, so `schemaVersion` stays `2`.

## connect

Direct. Args: `uri` (String, required).

| `data` key | Type | Required | Notes |
|---|---|---|---|
| `connected` | bool | yes | always `true` on success path |
| `vmServiceUri` | String | yes | echoes the arg |
| `sessionUuid` | String | yes | from `ext.sleuth.diagnose` |
| `connectionMode` | String | yes | one of `disconnected` / `warmup` / `basic` / `full` / `correlated` |
| `sidecarVersion` | String | yes | sidecar pin |
| `appPackageVersion` | String | yes (nullable) | app's reported `kSleuthPackageVersion` |
| `warning` | String | no | `version_skew_minor` (same lineage, different patch) or `version_skew_prior_lineage` (accepted prior lineage) |

**Errors:**

- `missing_required_arg: uri`
- `invalid_uri: <FormatException message>`
- `version_skew_major: app=<v> sidecar-pin=<v> — refusing to serve; align sleuth dep with sidecar version. Bridge disconnected.`
- `version_skew_unknown: diagnose envelope missing packageVersion stamp — cannot verify wire contract. Bridge disconnected.`

## attach_app

Direct. Three routing modes:

- **`udid`** — iOS UDID; drives the iOS attach pipeline (devicectl
  launch → Bonjour resolve → iproxy tunnel on USB / direct `.local`
  host on wireless → bridge connect). Requires `bundle`.
- **`debugUrl`** — direct WebSocket URI; bypasses both the flutter
  daemon and the iOS pipeline.
- **`device`** — device id or name; routes via `flutter attach
  --machine`.

Args:

| arg | type | purpose |
|---|---|---|
| `device` | String, optional | flutter daemon route. Mutually exclusive with `udid`. |
| `debugUrl` | String, optional | direct WebSocket route. Mutually exclusive with `udid`. |
| `udid` | String, optional | iOS device UDID. Triggers the iOS-direct path. |
| `bundle` | String, optional (required with `udid`) | iOS bundle identifier |
| `transport` | String, optional | `auto` (default) / `usb` / `wireless` |
| `authOverride` | String, optional | iOS-only; pins the Bonjour authCode when more than one pairing is announced |
| `forceRelaunch` | bool, optional (default `false`) | iOS-only; skip the Bonjour probe and go straight to `xcrun devicectl process launch`. Recovers from a stale mDNS cache without sidecar restart. |

Data shape: `AppStatusPayload.toJson()` — see source at `packages/sleuth_mcp/lib/src/flutter_daemon/app_status.dart`.

| `data` key | Type | Required | Presence |
|---|---|---|---|
| `attached` | bool | yes | always |
| `state` | String | yes | one of `idle` / `attaching` / `ready` / `restarting` / `detaching` / `error` |
| `device` | String | no | non-idle states |
| `appId` | String | no | non-idle states |
| `sessionUuid` | String | no | after `ext.sleuth.diagnose` succeeds |
| `launchMode` | String | no | `attach` / `run` / `ios-direct` |
| `mode` | String | no | `debug` / `profile` / `release` |
| `lastError` | String | no | when `state == 'error'` |
| `transportMode` | String | no | `wired` / `wireless` / `unknown`; conditional: present iff `launchMode == 'ios-direct'` |
| `wsUri` | String | no | iOS-direct sessions only |

**Errors:**

- `internal: daemon session not initialized` (server misconfiguration)
- `version_skew_major: …` / `version_skew_unknown: …` — attach reached `ready` but bridge-layer skew validator refused; auto-detach fires before the error returns
- `<DaemonSessionException.message>` — daemon RPC failure

**iOS-typed errors** (returned as `isError: true` with structured JSON in second `text` content block carrying `{error, message, ...data}`):

- `ios_missing_bundle` — `udid` provided without `bundle`
- `ios_ambiguous_args` — `udid` combined with `device` or `debugUrl`
- `ios_invalid_transport` — `transport` not in `{auto, usb, wireless}`. Carries `data.allowed`.
- `ios_missing_tool` — `xcrun` / `dns-sd` / `iproxy` not on PATH. Carries `data.tool` + `data.remedy`.
- `ios_launch_failed` — `xcrun devicectl process launch` returned non-zero. Carries `data.exitCode` + `data.stderr`.
- `ios_bonjour_timeout` — VM service not announced within the collect budget
- `ios_ambiguous_pairings` — more than one distinct authCode announced. Carries `data.distinctAuthCodes`; remedy: pass `authOverride`.
- `ios_no_matching_auth` — `authOverride` provided but no announcement matched. Carries `data.authCodes`.
- `ios_iproxy_failed` — `iproxy` either failed to spawn or exited inside the readiness window. Carries `data.stderr` when available.
- `ios_cancelled` — caller-injected cancellation fired mid-pipeline
- `ios_vmservice_busy` — bridge `connect` returned a post-handshake reset; the device-side VM service is holding a prior session. Carries `data.remedy` (swipe-kill the app on device or rebuild the profile binary).
- `ios_vmservice_unreachable` — bridge `connect` returned Connection-refused; the iproxy tunnel is open but nothing is listening on the device side (typically a stale Bonjour cache pinned a port that the new service has not yet bound). Carries `data.remedy` (wait ~30s for mDNS to clear, or swipe-kill + retry).
- `attach_in_progress` — another iOS attach is already running on this `DaemonSession`; the concurrency mutex rejected the second concurrent call.

## detach_app

Direct. No args. Same `AppStatusPayload.toJson()` shape as `attach_app`.

**Errors:** `internal: daemon session not initialized`.

## app_status

Direct. No args. Same `AppStatusPayload.toJson()` shape as `attach_app`.

**Errors:** `internal: daemon session not initialized`.

## hot_reload

Direct. No args. Same `AppStatusPayload.toJson()` shape as `attach_app`.

**Errors:**

- `internal: daemon session not initialized`
- `<StateError.message>` — not attached, or session was created from `debugUrl` (no daemon to send `r` to)
- `hot_reload_unsupported` — typed envelope returned when `launchMode == 'ios-direct'`; the iOS-direct path attaches via VM service without a flutter daemon, so hot-reload is not wired

## list_devices

Direct. Args: `mobileOnly` (bool, optional, default `true`).

| `data` key | Type | Required | Notes |
|---|---|---|---|
| `devices` | List\<Map\> | yes | raw daemon entries, optionally filtered |
| `count` | int | yes | `devices.length` |
| `filteredBy` | String | yes | `mobile` (default) or `none` |

**Errors:**

- `flutter not on PATH or failed to run: <ProcessException.message>`
- `<DaemonSessionException.message>`

## compare_snapshots

Pure client-side. Args: `before` (Map, required, snapshot `data` block), `after` (Map, required).

| `data` key | Type | Required | Notes |
|---|---|---|---|
| `added` | List\<String\> | yes | stableIds present in `after` but not `before` |
| `removed` | List\<String\> | yes | stableIds present in `before` but not `after` |
| `elevatedSeverity` | List\<Map\> | yes | item shape `{stableId, before, after}` |
| `fpsDelta` | double | yes (nullable) | `afterFps - beforeFps`; null when either side lacks `frameStatsSummary.averageFps` / `actualFps` |
| `beforeFps` | double | yes (nullable) | |
| `afterFps` | double | yes (nullable) | |

**Errors:**

- `arg "before" must be object (SessionSnapshot data)`
- `arg "after" must be object (SessionSnapshot data)`
- `arg_capped_issues_uncomparable` — one/both inputs projected with `maxIssueCount`; a truncated top-N window can't be diffed (an issue leaving the window is indistinguishable from one resolved)
- `arg_section_mismatch` — inputs projected to different sections or different pagination limits

## check_budgets

Wraps `ext.sleuth.snapshot`. Args: `minFps` (num, required), `maxIssues` (int, required), `maxCriticalIssues` (int, required).

| `data` key | Type | Required | Notes |
|---|---|---|---|
| `passed` | bool | yes | `violations.isEmpty` |
| `violations` | List\<Map\> | yes | item shape `{budget, expected, observed}`; `budget` is one of `minFps` / `maxIssues` / `maxCriticalIssues` |
| `observed` | Map | yes | `{fps: double?, issueCount: int, criticalCount: int}` |

**Errors:**

- `minFps must be number`
- `maxIssues must be integer`
- `maxCriticalIssues must be integer`
- `snapshot envelope had no data field` — bridge returned a malformed envelope
- `arg_capped_issues_unbudgetable` — snapshot projected with `maxIssueCount`; truncated issue list would make budget counts wrong
- `arg_missing_required_section` — snapshot projected without a section budgets need (`currentIssues` / `frameStatsSummary`)

## diagnose

Wraps `ext.sleuth.diagnose`. No args.

Augments the extension's `data` block with two sidecar-stamped keys:

| `data` key | Type | Required | Notes |
|---|---|---|---|
| (all keys from `ext.sleuth.diagnose.data`) | | | passthrough — see `mcp_schema.md` |
| `sidecarVersion` | String | yes | `sleuthMcpVersion` |
| `sidecarBuiltAgainstSleuth` | String | yes | `sleuthPackageVersionPin` |

## get_snapshot

Passthrough for `ext.sleuth.snapshot`. Args: `sections` (List\<String\>, optional — forwarded comma-joined; empty list or absent = full payload, not metadata-only), `maxIssueCount` (int, optional), `maxRouteCount` (int, optional), `diskHandoff` (bool, optional), `verbose` (bool, optional, default false).

**Shim — `compact_issues`.** Unless `verbose: true`, the sidecar trims every `data.currentIssues` entry to the compact key set (`severity`, `category`, `confidence`, `title`, `detail`, `fixHint`, `stableId`, `widgetName`, `routeName`, `sourceRoute`, `confidenceReason`, `rootCauseIds`), copying only keys that are present. Runs on both the inline-return and disk-handoff paths from a fresh map (the bridge envelope is never mutated). No-op when `currentIssues` was projected out via `sections` or is absent / non-list. Field shape only — independent of `maxIssueCount`, which caps `currentIssues` lib-side regardless of `verbose`.

**Shim — `disk_handoff`.** When `diskHandoff` is true the sidecar serializes the envelope to a per-process `Directory.systemTemp/sleuth_snapshot_<pid>/<random>.json` file and returns `{path, sizeBytes, sha256}` plus any projection metadata instead of the inline `data` block — use for large snapshots that exceed the response token cap. The filename is 128-bit `Random.secure()`. The per-pid dir is created `0700` and the file `0600`, both verified via `FileStat`; if owner-only perms can't be set + verified on POSIX, the file is deleted and `disk_handoff_failed` is returned (fail-closed). Windows has no POSIX mode — that verification is skipped. The payload MAY contain mildly-sensitive data (e.g. `recentRequests[].url` carrying query tokens), which is why perms are fail-closed rather than best-effort. Files are deleted on `detach_app`, on sidecar shutdown, and aged files (30 min) in the process's own dir are swept on each new write — the per-pid dir keeps concurrent sidecar instances from sweeping each other's in-flight handoffs. When `diskHandoff` is false/absent the envelope passes through unmodified.

**Lineage fallback (app predates projection, sleuth < 0.35):** the app ignores projection args and returns the full payload. On the **disk-handoff** path the sidecar writes it and stamps `_projectionApplied: by_sidecar_fallback`. On the **inline** path it returns `projection_unsupported_by_app` instead — the full inline payload would overflow the response cap that projection exists to avoid.

**Errors:** `arg_invalid_section`, `arg_invalid_int`, `arg_pagination_unused` (forwarded from `ext.sleuth.snapshot`); `projection_unsupported_by_app` (inline projection vs a pre-0.35 app); `disk_handoff_failed` (temp file couldn't be locked to owner-only perms).

Underlying shape: see `mcp_schema.md` § `ext.sleuth.snapshot`.

## get_issues

Passthrough for `ext.sleuth.issues`. Args: `route` (String, optional), `severityAtLeast` (String, optional, one of `ok` / `warning` / `critical`), `maxIssueCount` (int, optional, default 50; 0 = unbounded), `verbose` (bool, optional, default false).

**Shim — `severity_filter`.** When `severityAtLeast` is `warning` or `critical`, the sidecar filters `data.issues` to entries whose severity meets the threshold AND adds a `data.severityAtLeast` key echoing the requested level. When `severityAtLeast` is `ok` or absent, no filter + no echo.

**Shim — `compact_projection`.** After the optional severity filter, `data.issues` is capped to the front `maxIssueCount` entries (default 50; `0` = unbounded; negative is rejected with `arg_invalid_int`, for parity with get_snapshot) of the app's already-ranked order, then — unless `verbose: true` — each kept entry is trimmed to the compact key set (`severity`, `category`, `confidence`, `title`, `detail`, `fixHint`, `stableId`, `widgetName`, `routeName`, `sourceRoute`, `confidenceReason`, `rootCauseIds`). The cap and the field-trim are orthogonal: `verbose` controls field shape only and never disables the cap. Compaction drops fields, not field contents — it is not a hard byte bound; use `maxIssueCount` + `diskHandoff` for size management. When the cap dropped at least one issue, `data` gains `_truncated: true` and `_totalCount` (post-filter, pre-cap count). Error envelopes (no `data` map / no `issues` list) pass through unmodified.

Underlying shape: see `mcp_schema.md` § `ext.sleuth.issues` (compact entries are a key-subset of that shape).

## get_route_health

Passthrough for `ext.sleuth.routeHealth`. Args: `route` (String, optional).

**Shim — `lineage_route_wrapper`.** When the `route` arg is provided and the bridge is connected to an `acceptedPriorLineages` app emitting the v0.32 inline `RouteSession` shape (data carries `routeName` but no `route` key), the shim wraps data into `{route: <inline-session>}` so downstream consumers always see the canonical v0.33 envelope. v0.33+ apps already emit the wrapper and pass through untouched. Error envelopes and absent-route shapes are never wrapped.

**Invariant — shim must be idempotent on the canonical shape.** Running the shim against an already-wrapped `{route: <session>}` payload MUST yield the same payload (no double-wrap, no key drop). The shim's gating predicate is `data.containsKey('routeName')` — a payload that already lacks the inline key is left untouched. Idempotency is regression-guarded by `test/schema/mcp_tool_schema_audit_test.dart` (the canonical-wrapper / inline-wrapped / absent-route triad of tests in the `lineage_route_wrapper` group).

Underlying shape: see `mcp_schema.md` § `ext.sleuth.routeHealth`.

## explain_issue

Passthrough for `ext.sleuth.explain`. Args: `stableId` (String, **required**, `minLength: 1`).

**Errors:**

- `missing_required_arg: stableId` — validated at the tool layer before delegating
- `unknown_stable_id` — `ext.sleuth.explain` returned an error envelope; passed through unmodified

Underlying shape: see `mcp_schema.md` § `ext.sleuth.explain`.

## Recovery from a refused connection

When `connect` or `attach_app` returns a `version_skew_*` error, the bridge is already disconnected. To recover:

1. Align the app's `sleuth` dependency lineage with `sidecarBuiltAgainstSleuth` (see the `diagnose` tool output before the disconnect, or `pubspec.yaml` of the sidecar).
2. Hot-restart the app (`R`) so the new `kSleuthPackageVersion` is in effect, then re-run `connect` / `attach_app`.
