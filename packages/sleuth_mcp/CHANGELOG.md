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
