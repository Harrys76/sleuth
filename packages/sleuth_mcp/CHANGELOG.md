## 0.6.2

iOS attach ambiguous-pairings recovery. Sidecar-only; pins sleuth 0.35.0.

- When a stale dead VM-service port and a fresh live port coexist in the
  iOS mDNS cache after a relaunch (each with a distinct authCode),
  `attach_app` no longer refuses with `ios_ambiguous_pairings`. It connects
  to each announced authCode in turn and keeps the one whose VM service is
  live (the dead port resets). A user-supplied `authOverride` still pins a
  single service (no iteration). All candidates dead, or 3+ coexisting
  records, fall back to `ios_vmservice_busy` (swipe the app and re-run).
- `sleuthMcpVersion` 0.6.1 → 0.6.2.

## 0.6.1

iOS attach mDNS-staleness auto-recovery. Sidecar-only; pins sleuth 0.35.0.

- `attach_app(udid:, bundle:)` now recovers automatically when the iOS
  mDNS cache pins a dead VM-service port from a prior session. On a
  `bridge.connect` failure that looks like a dead device port
  (`Connection reset` — iproxy resets the tunnel when the device refuses
  the channel — or `Connection refused`), the attach retries once,
  re-resolving Bonjour with the dead port excluded so selection lands on
  the live service, which announces a different port within the same
  staleness window. Falls through to a plain relaunch only if no live
  port is announced. No manual `devicectl` relaunch needed.
- Wireless-transport failures and half-open VM services (connect
  timeout) are not recovered — re-resolving can't help those.
- `IosAttacher.attach` gains `excludePorts` and bounds each `xcrun
  devicectl` call with a `devicectlTimeout` (default 20s), so a
  disconnected device or stalled device-services can't hang the attach
  (and the single-attach mutex) indefinitely. `DaemonSession.attachViaIos`
  gains an `attachBudget` (default 90s) gating whether recovery is
  attempted. An attach that recovers holds the mutex (`attach_in_progress`)
  until it completes.
- `sleuthMcpVersion` 0.6.0 → 0.6.1.

## 0.6.0

Snapshot projection + pagination + disk-handoff. Pins sleuth 0.35.0.

- `get_snapshot` gains optional `sections` (List<String>),
  `maxIssueCount`, `maxRouteCount` — forwarded to `ext.sleuth.snapshot`
  so a long-session snapshot can be trimmed below the MCP response
  token cap. Typed errors `arg_invalid_section` / `arg_invalid_int` /
  `arg_pagination_unused` pass through.
- New `diskHandoff: bool` arg. When true the sidecar writes the
  envelope to a `Directory.systemTemp` file (mode 0600, crypto-random
  name) and returns `{path, sizeBytes, sha256}` plus projection
  metadata instead of inline `data`. Files are deleted on `detach_app`,
  on sidecar shutdown, and swept by age (30 min) on each write. When
  the app predates projection support the sidecar stamps
  `_projectionApplied: by_sidecar_fallback`.
- `compare_snapshots` rejects diffing differently-projected snapshots
  (`arg_section_mismatch`) — compared as a Set so list order of
  `_projectedSections` is irrelevant; also cross-checks
  `_projectionLimits`. Rejects `maxIssueCount`-capped inputs entirely
  (`arg_capped_issues_uncomparable`): a truncated top-N window can't be
  diffed since an issue leaving the window looks identical to one that
  resolved.
- `evaluateBudgets` returns `arg_missing_required_section` (instead of a
  generic drift error) when a projected snapshot omits a section budgets
  need, and `arg_capped_issues_unbudgetable` when the snapshot was
  projected with `maxIssueCount` (truncated issue list would make budget
  counts wrong). `maxRouteCount`-only projections still budget normally.
- `get_snapshot` surfaces app error envelopes inline even under
  `diskHandoff: true` (never writes an error to a temp file). On the
  lineage-fallback path against a pre-0.35 app, the inline path returns
  `projection_unsupported_by_app` (the full payload would overflow the
  response cap) while the disk-handoff path writes + stamps
  `by_sidecar_fallback`. Empty `sections: []` is treated as a full-payload
  request, not a projection.
- Disk-handoff is fail-closed: the per-pid temp dir (`0700`) and file
  (`0600`) are `FileStat`-verified; if owner-only perms can't be
  established on POSIX the file is deleted and `disk_handoff_failed` is
  returned. The payload may carry `recentRequests[].url` (query tokens),
  so loose permissions are refused rather than tolerated.
- `sleuthMcpVersion` 0.5.1 → 0.6.0; `sleuthPackageVersionPin` 0.34.0 →
  0.35.0; `acceptedPriorLineages = {0.34}` one-cycle fallback.
- Adds `crypto` dependency (sha256 for the handoff pointer).
- `attach_app` now declares `forceRelaunch` in its `inputSchema`, so the
  documented stale-mDNS-recovery arg is reachable over MCP (was rejected
  as `arg_unknown`). An audit cross-checks documented `attach_app` args
  against the live `inputSchema` to prevent allowlist drift.

## 0.5.1

iOS-direct attach hardening. No wire-shape change.

- `attach_app(udid:, bundle:, forceRelaunch:)` new arg skips the Bonjour
  probe and drives `xcrun devicectl process launch` directly. Auto-
  retries internally when the probe returns a wsUri whose
  `bridge.connect` fails with `Connection refused` — recovers from
  stale iOS mDNS without sidecar restart.
- `bridge.connect` end-to-end timeout-bounded (10s) inside
  `DaemonSession.attachViaIos`; bootstrap `getVM()` bounded per-RPC at
  3s. Half-open VM services that accept the WS but never return RPC
  no longer wedge the attach mutex; surfaces as
  `ios_vmservice_unreachable: bridge connect timed out`.
- `IosAttachException` thrown by the pipeline records `state: error` +
  typed `lastError` before rethrow, so `app_status` after a failed
  attach reflects the failure instead of staying `attaching`. Next
  `attach_app` auto-recovers.
- `withPidfileLock` gains `PidfileLockGuard.registerSpawn(process,
  pidfile)`. Lock timeout after spawn but before pidfile write
  SIGKILLs the registered child + deletes the pidfile, preventing
  unreapable orphans.
- `mapBridgeConnectErrorToLastError` adds wireless pins:
  `Operation not permitted`, `Network is unreachable`,
  `Failed host lookup` → `ios_vmservice_unreachable` with wireless
  remedy text.
- `attach_app` trims all routing args at the handler boundary so
  whitespace-only values don't slip into iOS-direct routing.
- `_cleanup` iOS-teardown budget 3s → 6s so outer exceeds inner
  grace + SIGKILL + pidfile-delete; back-to-back detach/reattach no
  longer races on a bound port.
- Schema doc adds `attach_app.args.forceRelaunch` and
  `hot_reload.errors.hot_reload_unsupported`.

## 0.5.0

- `attach_app` MCP tool gains iOS-direct routing: passing `udid` + `bundle`
  drives the full attach pipeline (devicectl launch → Bonjour resolve →
  iproxy tunnel → bridge.connect) in a single round-trip, removing the
  separate `sleuth_mcp attach-ios` CLI + manual `attach_app(debugUrl:)`
  copy-paste step. The standalone CLI remains for non-MCP workflows.
- New `attach_app` args: `udid`, `bundle`, `transport` (`auto`|`usb`|
  `wireless`), `authOverride`. `udid` is mutually exclusive with `device`
  and `debugUrl`; daemon and direct-WS paths are unchanged.
- New `AppStatusPayload` fields: `transportMode` (`wired`|`wireless`|
  `unknown`) and `wsUri`, populated only on iOS-direct sessions.
- Typed error envelopes for the iOS path: `ios_missing_bundle`,
  `ios_ambiguous_args`, `ios_invalid_transport`, `ios_missing_tool`,
  `ios_launch_failed`, `ios_bonjour_timeout`, `ios_ambiguous_pairings`,
  `ios_no_matching_auth`, `ios_iproxy_failed`, `ios_cancelled`,
  `ios_vmservice_busy`. Each carries a structured `data` block with
  remedy text when applicable.
- `detach_app` extended with a bounded state machine: `bridge.disconnect`
  (2s timeout) → iproxy teardown (3s timeout) → pidfile removal.
  Partial state always clears even if either phase hangs.
- `hot_reload` MCP tool returns the typed `hot_reload_unsupported`
  error on iOS-direct sessions (no flutter daemon child to invoke
  `app.restart`); remedy is to detach + reattach via `device:`.
- New `IosAttacher` class (`lib/src/cli/ios_attach_pipeline.dart`)
  encapsulates the pipeline with the same injection seams the CLI uses;
  callers receive `IosAttachResult` + teardown callback. The pipeline
  throws `IosAttachException(kind, message, data)` for categorised
  failure mapping by callers.
- Detects the device-side VM service "Connection reset post-handshake"
  symptom that occurs after the first MCP attach + detach on a single
  app instance and surfaces it as `ios_vmservice_busy` with a remedy
  (swipe-kill the app on device or rebuild the profile binary).

## 0.4.2

- `attach-ios`: bump Bonjour collect window 4s → 8s so the USB-interface
  authCode (which announces later than WiFi on iOS 17.5) is captured
  before selection.
- `attach-ios`: print all collected announcements before selection so
  re-running with `--auth <code>` is one copy-paste away when the
  heuristic picks wrong.
- `tool/attach_ios.sh` mirrors the same selector + diagnostic output.

## 0.4.1

- New `sleuth_mcp attach-ios <udid> [--bundle <id>] [--port <n>] [--auth <code>]`
  subcommand. Bundles `xcrun devicectl process launch
  --terminate-existing`, Bonjour resolution via `dns-sd -L`, and
  `iproxy` tunneling into a single command. Prints the WebSocket URI
  for `attach_app(debugUrl:)` and holds the iproxy child open until
  Ctrl-C tears it down. Replaces the six-step manual iOS-on-real-device
  flow documented in the README.
- New `tool/attach_ios.sh` bash wrapper mirroring the same flow for
  users without a Dart runtime / pub-activated sidecar (CI bootstrap,
  ad-hoc shell). Bash 3.2+, no `coreutils` dependency (uses
  `/usr/bin/perl` for the dns-sd timeout). The Dart subcommand remains
  the canonical entry; the wrapper is a no-Dart fallback + readable
  reference for the `devicectl → dns-sd → iproxy` pipeline.
- Requires `libimobiledevice` (`brew install libimobiledevice`) for
  `iproxy`. macOS-only.
- Selection between USB-bridged and WiFi-bridged Bonjour pairings is
  first-pairing-wins by default; pass `--auth <code>` to override when
  the heuristic picks the WiFi pairing (the WiFi authCode is refused by
  the on-device WebSocket gate when reached through the USB tunnel).
- No wire-shape changes — `sleuthPackageVersionPin` stays at `0.34.0`,
  `acceptedPriorLineages` stays at `{0.33}`.

## 0.4.0

Companion to sleuth v0.34.0 — tool-layer schema lock + snapshot deep
shape.

- `sleuthPackageVersionPin` 0.33.0 → 0.34.0. `sleuthMcpVersion`
  0.3.0 → 0.4.0.
- New `doc/mcp_tool_schema.json` (structured contract) + `.md`
  (human view) ship in the pub archive — locks tool-call return shapes
  for the 13 MCP tools. Success-path `data:` keys and error-path
  `errors:` codes documented per tool. `connect`, `attach_app`,
  `detach_app`, `app_status`, `hot_reload`, `list_devices`,
  `compare_snapshots`, `check_budgets`, `diagnose` are first-class;
  `get_snapshot`, `get_issues`, `get_route_health`, `explain_issue`
  passthrough the corresponding `ext.sleuth.*` envelope with documented
  shims (`severity_filter` on `get_issues`, `lineage_route_wrapper` on
  `get_route_health`).
- New `test/schema/mcp_tool_schema_audit_test.dart` enforces the
  contract — drives FakeVmBridge through every documented error code,
  asserts success-path keys ⊆ documented, and tests the
  `get_route_health` lineage shim against canonical + legacy inline
  shapes. Mirror-parity audit asserts root sleuth ships no parallel
  `mcp_tool_schema.{json,md}` (sidecar-only file).
- `acceptedPriorLineages` rolled from `{'0.32'}` to `{'0.33'}` — one
  release cycle of fallback for 0.33.x apps mid-upgrade. Drop on next
  release.
- Snapshot deep shapes (`recurrenceTrends`, `sessionSummary`,
  `routeSessions`) now codified in the upstream
  `doc/mcp_schema.{json,md}` (mirrored at
  `packages/sleuth_mcp/doc/mcp_schema.{json,md}`). Derived from
  on-device captures — see sleuth's
  `doc/mcp_schema_derivation.md` for the derivation procedure and
  device-context limitations.
- Drift-guard regex in `test/sleuth_mcp_smoke_test.dart` tightened to
  tolerate whitespace and `multiLine` matching.
- After v0.4.0 ships, v0.3.0 sidecars hit `version_skew_major` on
  attach to a v0.34.0 app — their pin (`0.33.0`) is in the prior
  lineage. Recovery:
  `dart pub global activate sleuth_mcp` (>= 0.4.0). Local pre-publish:
  `dart pub global activate --source path packages/sleuth_mcp`.

## 0.3.0

Companion to sleuth v0.33.0 — wire-schema lock.

- `sleuthPackageVersionPin` 0.32.0 → 0.33.0. `sleuthMcpVersion`
  0.2.0 → 0.3.0.
- Version-skew enforcement runs on every `bridge.connect()` — both
  the `connect` tool and `attach_app` (daemon-spawn and `debugUrl`).
  Previously only `connect` gated lineage drift; `attach_app` could
  attach to a lineage the sidecar pin couldn't speak.
- `_enforceVersionSkew` returns the cached `ext.sleuth.diagnose`
  envelope on OK / minor skew, or a refusal `ToolCallResult` (after
  `bridge.disconnect()`) on major skew. `attach_app` calls
  `session.detach()` before returning the refusal so the daemon
  child tears down cleanly.
- `acceptedPriorLineages` in `version_lineage.dart` tolerates sleuth
  0.32.x apps for one release cycle — drift surfaces as
  `version_skew_minor` (warning), not `version_skew_major` (refusal),
  so users mid-upgrade aren't locked out. Drop in v0.4.0.
- Baseline mutations route through one `_applyBaseline` chokepoint;
  validator + rotation guard cover connect, reconnect, and refresh
  uniformly. `_validated` lowers before the validator runs on the
  refresh path so a lock-free dispatcher can't observe
  `isConnected == true` mid-validation.
- Schema doc mirrored at `packages/sleuth_mcp/doc/mcp_schema.{json,md}`
  for pub.dev consumers.
- Tool-layer audit (`test/schema/`) deferred to v0.4.0. Tool return
  shapes documented in `doc/mcp_schema.md` "Sidecar tool layer" as a
  stable best-effort contract until v0.4.0 locks them byte-for-byte.
- After v0.3.0 ships, v0.2.0 sidecars hit `version_skew_major` on
  attach to a v0.33.0 app — their pin (`0.32.0`) predates
  `acceptedPriorLineages`. Recovery:
  `dart pub global activate sleuth_mcp` (>= 0.3.0). Local pre-publish:
  `dart pub global activate --source path packages/sleuth_mcp`.

## 0.2.0

Zero-config attach-mode DX. AI agents discover and explore developer-launched
Flutter apps with no manual VM service URI copy/paste.

### Tools (8 → 13)
- New lifecycle tools: `attach_app`, `detach_app`, `app_status`,
  `list_devices`, `hot_reload`. `hot_restart` deferred to v0.2.1 —
  Android profile-mode isolate re-registration window is not yet
  reliably observable from the VM service after `app.restart`.
- `attach_app` wraps `flutter attach --machine`: spawns the daemon child,
  waits for `daemon.connected` (min protocol `0.6.0`) + `app.debugPort`,
  connects the VM bridge to the discovered `wsUri`. `debugUrl` escape
  hatch bypasses daemon discovery.
- Scope: Android + iOS only. `list_devices` defaults to mobile;
  `attach_app` rejects non-mobile devices. Mobile filter falls back to
  `targetPlatform.startsWith('ios'|'android')` when `category` is absent
  (Flutter 3.41.4 `flutter devices --machine` omits `category`).
- Hot reload/restart pause dispatch → drain → daemon RPC →
  `bridge.refreshBaseline()` (or `connect()` if `wsUri` rotated) → resume.
- `list_devices` caches `flutter devices --machine` for 3s.

### CLI
- `sleuth_mcp install [--remove]` writes `~/.claude.json` `mcpServers.sleuth`
  idempotently. OS advisory lock under `${XDG_CACHE_HOME:-~/.cache}/sleuth_mcp/`,
  atomic rename via `.tmp`, `.bak` preserved.
- `_writeAtomic` resolves `configFile` symlinks so `.tmp` lands on the
  resolved target volume — iCloud-symlinked configs no longer trigger EXDEV.

### Bridge + dispatcher
- `VmBridge.refreshBaseline({acceptSessionRotation})` — default `false`
  throws `SessionChangedException` on sessionUuid rotation. Hot-restart
  path opts in.
- `VmBridge.baselineGeneration` counter — resource caches key on it.
- Lifecycle tools opt out of the dispatcher's generic `_toolTimeout` +
  post-timeout `bridge.disconnect()` via `BuiltInTool.bypassesGenericTimeout`.
  Per-operation deadlines inside `DaemonSession` (`attachTimeout`,
  `hotRestartTimeout`) govern instead.
- `pauseDispatch({autoResumeAfter})` — caller-supplied window. Hot restart
  passes `hotRestartTimeout + 30s`.
- `_validateArgs` rejects undeclared keys (`arg_unknown: <key>`); typos no
  longer silently default.

### Daemon protocol layer
- Sealed `DaemonEvent` hierarchy. `DaemonParser` iterates every frame in
  batched `[…]` lines, drops non-`[…]` banners + malformed JSON silently,
  surfaces unknown event names as `UnknownDaemonEvent`.
- `_sessionGeneration` counter — stale exit-code / stderr listeners from
  a prior attach cannot flip a fresh session into `error`.
- Hot-restart settle uses a per-restart `Completer<DaemonEvent>` armed in
  the parser listener BEFORE the `app.restart` RPC. Daemons emit
  `app.debugPort` in the same event-loop turn as the response; lazy
  subscribers miss it.
- Hot reload (`fullRestart: false`) skips the `app.debugPort`/`app.started`
  wait — daemon never emits these events for in-place reload.
- `_cleanup()` clears `appId`/`deviceId`/`launchMode`/`mode` so partial-attach
  state doesn't leak into the error-state status payload.
- `app_status.attached` is true only for `ready` (not `restarting`).
- `attach_app` debugUrl path reports `mode: 'unknown'`.
- Child reap: SIGTERM → 5s → SIGKILL. Orphan reaping of flutter daemon's
  subprocesses is best-effort and relies on flutter daemon's own teardown.

### Server architecture
- `DaemonSessionLifecycle` abstract in `mcp_server.dart` breaks the import
  cycle with `DaemonSession`. Bound via `McpServer.setDaemonSession`.
- `McpServer.shutdown()` calls `detach()` with a 2s timeout before draining
  the dispatch queue.

## 0.1.0

Initial release. Companion to sleuth v0.32.0.

- MCP stdio JSON-RPC server (`bin/sleuth_mcp.dart`) bridging seven
  `ext.sleuth.*` VM service extensions to AI clients.
- Eight MCP tools: `connect`, `get_snapshot`, `get_issues`,
  `get_route_health`, `explain_issue`, `compare_snapshots`,
  `check_budgets`, `diagnose`. Each ships an `inputSchema`.
- Two MCP resources cached per `sessionUuid`: `sleuth://encyclopedia`,
  `sleuth://causal-graph`. Generation-counter guards against
  in-flight `read()` ↔ `invalidate()` interleaving. Caches drop on
  re-`initialize`.
- Separate one-shot CI gate binary `bin/sleuth_check.dart` returns
  exit-code on budget violations. Refuses to run when the target
  app's sleuth lineage (`major.minor`) doesn't match the binary pin.
- `connect` MCP tool returns `isError: true` and disconnects the
  bridge on major lineage skew. Minor skew emits a `warning` field.
- Hot-restart detection inline on every tool call via the envelope's
  `sessionUuid` field. No idle polling.
- Concurrent JSON-RPC dispatch with serialized stdout writes — slow
  tools no longer block fast ones. `McpServer.shutdown()` plus
  `serve()`'s finally drain pending dispatches and the write chain
  before returning; first write failure trips cooperative shutdown.
- VM bridge serializes connect / disconnect / reconnect with a
  `Lock` so concurrent dispatches can't observe half-initialized
  state. Per-call retry budget + shared `_reconnectInFlight` future
  coalesces concurrent transport-close retries onto one reconnect.
- `RPCError(kServerError, 'Service connection disposed')` from
  vm_service routes through the reconnect path; only true
  extension-level rejections become `VmBridgeException`. `SentinelException`
  surfaces as bridge exception with isolate-expired context.
- Main isolate picked by `name == 'main'` (or `startsWith('main')`),
  not blindly by `isolates.first` — robust against background
  isolates (Firebase, Workmanager, `compute()`). Tests can override
  via `targetIsolateIdOverride`.
- Re-connecting disposes the prior VM service handle so per-attempt
  WebSockets don't leak.
- SIGINT/SIGTERM trigger cooperative drain + `bridge.disconnect()`
  in a `finally` block, not `exit(0)`. `-v` logger plumbs through to
  `RealVmBridge` so disconnect / prior-service errors land on stderr.
- Hand-rolled JSON-RPC 2.0 codec with `allowMalformed: true` UTF-8
  decoding so a stray byte on stdin doesn't kill the server.
- `initialize` accepts MCP protocol versions `2024-11-05`,
  `2025-03-26`, `2025-06-18`. Echoes the client's pin when supported.
- `inputSchema` validation enforces `required`, `type`, `enum`,
  `minLength`. Unknown enum values rejected before reaching the
  handler. Non-object `arguments` rejected explicitly.
- Tool errors return `error: <message>` content only — stack traces
  go to stderr (with `-v`), never the MCP response.
- Shared `versionLineage` helper used by both the `connect` MCP tool
  and the `sleuth_check` CI gate. Exported from the barrel.
- Discovery is `--uri` only (sleuth targets ios + android; sidecar
  runs on the host machine).
