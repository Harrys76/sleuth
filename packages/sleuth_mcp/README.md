# sleuth_mcp

MCP stdio sidecar for [sleuth](https://github.com/Harrys76/sleuth).
Bridges the `ext.sleuth.*` VM service extensions to AI clients
(Claude Code, Cursor, Zed) over the Model Context Protocol.

The in-app overlay remains sleuth's primary UX. This sidecar is opt-in,
for developers who want their AI assistant to query live performance
data during a debug session.

## Install

```yaml
# pubspec.yaml — only needed if you want sleuth_mcp installed alongside the
# main sleuth dep; otherwise install globally below.
dev_dependencies:
  sleuth_mcp: ^0.1.0
```

Or globally:

```bash
dart pub global activate sleuth_mcp
```

## Discovery

The sidecar takes the VM service URI directly via `--uri`. Copy it from
`flutter run`'s output:

```
A Dart VM Service on iPhone 12 is available at: http://127.0.0.1:55555/<token>=/
```

The corresponding WebSocket URI is `ws://127.0.0.1:55555/<token>=/ws`.

Why manual: sleuth targets ios + android, so the app process runs
inside the device sandbox while the sidecar runs on your host machine.
There is no shared filesystem for auto-discovery. (DevTools' "Open in
Browser" workflow has the same constraint.)

## MCP client configuration

### Claude Code

Add to `~/.claude.json` (or per-project `.mcp.json`):

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

### Cursor / Zed

Similar pattern — see your IDE's MCP setup docs. The command is
`sleuth_mcp` plus the same `--uri` arg.

The exact config-file format for each MCP client evolves — check
upstream docs for the current schema if the snippet above is rejected.

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

`sleuth_mcp` v0.1.x is built against `sleuth` v0.32.x. The `connect`
tool cross-checks the app's reported package version against the
sidecar's pin and emits:

- `warning: version_skew_minor` — bump the sidecar or the app to align.
- `error: version_skew_major` — refuse to serve; bump both together.

## Known limitations (v0.1.0)

- Auto-discovery deferred. Manual `--uri` only.
- One sleuth-attached VM connection per sidecar process. Each MCP
  client spawns its own sidecar.
- The MCP wire shape is not yet locked behind a schema audit — that
  lands in sleuth v0.33.0 + sleuth_mcp v0.1.1. Until then, treat the
  envelope shape as stable but unaudited.
- `compare_snapshots` returns its diff as a JSON-stringified `text`
  content block rather than a structured tool result. Consumers must
  `JSON.parse(content[0].text)`. Pinning the wire shape to structured
  content lands in M3 alongside the schema audit.

## Manual smoke test

When verifying a build, record this in the PR description:

```
Manual smoke — sleuth_mcp v0.1.0
Device:       <android-emu / iPhone 12 / Pixel 7>
OS:           <Android 14 / iOS 17.5>
Flutter:      <3.41.4>
Date:         <YYYY-MM-DD>
Sidecar got URI:                        yes
8 tools advertised with inputSchema:    yes
get_snapshot returns connectionMode:    yes
Hot-restart raises session_changed:     yes
sleuth_check exits 0 on pass / 1 on violation: yes / yes
```
