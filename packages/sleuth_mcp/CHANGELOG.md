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
