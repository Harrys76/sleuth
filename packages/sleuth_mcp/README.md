# sleuth_mcp

MCP stdio sidecar for [sleuth](https://github.com/Harrys76/sleuth).
Bridges the `ext.sleuth.*` VM service extensions to AI clients
(Claude Code, Cursor, Zed) over the Model Context Protocol.

The in-app overlay remains sleuth's primary UX. This sidecar is opt-in,
for developers who want their AI assistant to query live performance
data during a debug session.

## Install

```bash
dart pub global activate sleuth_mcp
sleuth_mcp install
```

`install` writes `mcpServers.sleuth` to `~/.claude.json` idempotently
(advisory lock + atomic rename + `.bak`). Reload your MCP client, then
in conversation: "attach to my Flutter app and explore" — the agent
calls `list_devices` → `attach_app`, which spawns `flutter attach
--machine`, discovers the VM service URI, and connects.

For project-local installs, add `sleuth_mcp: ^0.3.0` to `dev_dependencies`.

Manual `--uri` mode (pre-v0.2 workflow) still works:

```json
{
  "mcpServers": {
    "sleuth": {
      "command": "sleuth_mcp",
      "args": ["--uri", "ws://127.0.0.1:55555/<token>=/ws"]
    }
  }
}
```

Cursor / Zed: same `command` + entry shape; check upstream docs for
the per-IDE config path.

### Scope

- Android + iOS only. `list_devices` filters by `category == 'mobile'`;
  pass `mobileOnly: false` to include desktop / web / embedded.
- One sidecar process owns one `flutter attach --machine` child. Each
  MCP client spawns its own sidecar.
- Min daemon protocol version `0.6.0`. Older Flutter SDKs refused.

## Tools

| Tool | Args | Purpose |
|---|---|---|
| `connect` | `uri` | Attach to a running Flutter app. Always call first. Returns `connectionMode`, `sessionUuid`, and a `warning` if sidecar / app versions are skewed. |
| `get_snapshot` | — | Full performance snapshot (issues, frame stats, route history). |
| `get_issues` | `route?`, `severityAtLeast?` | Currently-aggregated issues. Optional route filter and case-insensitive severity gate (`ok` / `warning` / `critical`). |
| `get_route_health` | `route?` | Per-route health score + FPS + issue counts. |
| `explain_issue` | `stableId` | Encyclopedia entry — parametric stableIds resolve through canonical form. |
| `compare_snapshots` | `before`, `after` | Pure client-side diff of two snapshots. Use to compare runs before / after a code change. |
| `check_budgets` | `minFps`, `maxIssues`, `maxCriticalIssues` | Compare live snapshot against thresholds. For CI exit-code gating use the separate `sleuth_check` binary. |
| `diagnose` | — | Operational health: package version, VM connection, unbound extension names. Use when other tools return empty. |
| `attach_app` | `device?`, `debugUrl?` | Spawn `flutter attach --machine`, discover VM URI, connect bridge. Replaces manual `--uri`. |
| `detach_app` | — | Stop the daemon child + disconnect the bridge. Idempotent. |
| `app_status` | — | `{attached, state, device, appId, sessionUuid, launchMode, mode, lastError}`. |
| `list_devices` | `mobileOnly?` | `flutter devices --machine`, filtered to mobile by default (android + ios). |
| `hot_reload` | — | Hot reload (preserves state + sessionUuid). Daemon-spawn sessions only. |

## Resources

- `sleuth://encyclopedia` — every `IssueExplanation` keyed by canonical
  stableId.
- `sleuth://causal-graph` — full rule set linking trigger stableIds to
  downstream effects.

Both are cached per `sessionUuid` and refresh inline on hot-restart of
the target app.

## `sleuth_check` — one-shot CI gate

The stdio MCP server cannot signal CI failure via exit code because it
runs as a long-lived stdio process. For CI use the separate one-shot
binary:

```bash
sleuth_check \
  --uri "ws://127.0.0.1:55555/<token>=/ws" \
  --min-fps 55 \
  --max-issues 10 \
  --max-critical-issues 0 \
  --json
```

Exits 0 on pass, 1 on budget violation, 2 on connect / handler failure.

## Tools vs `sleuth_check`

| Use case | Mechanism |
|---|---|
| Conversational diagnosis with an AI assistant | `sleuth_mcp` stdio server, tools/resources |
| Comparing two snapshots side-by-side in an AI conversation | `compare_snapshots` MCP tool |
| Pass/fail gate inside a CI script | `sleuth_check` one-shot binary |
| Live programmatic inspection from a custom Dart tool | Direct `package:vm_service` calls to `ext.sleuth.*` (no sidecar needed) |

## Version sync rule

`sleuth_mcp` v0.3.x is built against `sleuth` v0.33.x. The sidecar
tolerates one prior lineage (`sleuth 0.32.x`) during the transition
window — drift surfaces as `version_skew_minor` (warning). The `connect`
tool cross-checks the app's reported package version against the
sidecar's pin and emits:

- `warning: version_skew_minor` — bump the sidecar or the app to align.
- `error: version_skew_major` — refuse to serve; bump both together.

## Known limitations

- Android + iOS only. `list_devices` filters non-mobile by default;
  `attach_app` rejects non-mobile devices.
- One `flutter attach --machine` child per sidecar process. Each MCP
  client spawns its own sidecar.
- `compare_snapshots` returns its diff as a JSON-stringified `text`
  content block. Consumers must `JSON.parse(content[0].text)`.
  Structured-content output lands with the v0.4.0 tool-layer audit.
- `hot_restart` deferred. Android profile-mode does not re-register the
  new main isolate within the bridge's reconnect window after
  `app.restart`. Workaround: `detach_app` + `attach_app`. `hot_reload`
  is unaffected.
