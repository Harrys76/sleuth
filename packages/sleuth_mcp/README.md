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

### Connection modes — `basic` vs `full` / `correlated`

`diagnose` returns a `connectionMode`:

- `basic` — sleuth's in-app `VmServiceClient` could not self-connect to
  the host VM service. FrameTiming + structural detectors fire;
  vmOnly detectors (`excessive_repaint`, `gc_pressure`, `heap_growing`,
  `heavy_compute`, `stream_resource_growth`) stay silent. Causal-graph
  rootCauseIds / downstreamIds inactive. Confidence stays at `possible`
  for structural emissions.
- `full` / `correlated` — VM connected. vmOnly detectors fire,
  confidence escalates to `likely` or `confirmed` with VM evidence,
  causal-graph rootCauseIds / downstreamIds wire across emissions.

On both Android and iOS, `flutter run` keeps the host-side daemon
holding the VM service as an exclusive observer, which blocks sleuth's
in-process `Service.controlWebServer(enable: true)` call. Result:
`basic` mode permanently. Workaround — launch the installed binary
directly so no host daemon competes:

**Android:**
```bash
# 1. Build + install ONCE via flutter run; immediately quit (q).
fvm flutter run --profile -d <device-id>

# 2. Re-launch the installed APK directly. Repeat as needed.
adb -s <device-id> shell am start -n com.example.example/.MainActivity

# 3. Read the VM service URI from device logcat.
adb -s <device-id> logcat -d | grep "Dart VM service"
# → I/flutter: The Dart VM service is listening on http://127.0.0.1:33999/<token>=/

# 4. Forward the device port to the host.
adb -s <device-id> forward tcp:33999 tcp:33999

# 5. attach_app(debugUrl: "ws://127.0.0.1:33999/<token>=/ws")
```

**iOS simulator:**
```bash
# 1. Build + install ONCE via flutter run; immediately quit (q).
fvm flutter run --profile -d <simulator-id>

# 2. Re-launch the installed app directly.
xcrun simctl launch booted com.example.example

# 3. Capture VM service URI from simulator log stream.
xcrun simctl spawn booted log stream --predicate 'process == "Runner"' \
  | grep "Dart VM service"

# 4. attach_app(debugUrl: "ws://127.0.0.1:<port>/<token>=/ws")
#    (simulator shares localhost with host — no forward needed)
```

`diagnose` should now report `connectionMode: full` (or `correlated`
once the per-frame timeline correlator warms up).

**iOS real device — one-command attach:**

```bash
# Prerequisite once: brew install libimobiledevice  (provides iproxy
# for USB-tethered attach; not required for wireless / "Connect via
# network" pairings).

# Build + install the app ONCE via flutter run; immediately quit (q).
fvm flutter run --profile -d <udid>
```

**Quick start (recommended).** From the MCP client, one call:

```
attach_app(udid: "<udid>", bundle: "com.example.example")
→ {attached: true, state: "ready", launchMode: "ios-direct",
   transportMode: "wired"|"wireless", wsUri: "ws://...", sessionUuid: ...}
```

The sidecar runs the full pipeline (devicectl launch → Bonjour resolve
→ iproxy tunnel on USB, or direct `.local` host on wireless → bridge
connect) and returns the attached envelope. `detach_app()` tears down
the bridge and the iproxy child in order.

Transport defaults to `auto` (parsed from `xcrun devicectl list devices`'s
`transportType`). Override with `transport: "usb"` or `transport:
"wireless"`. On multi-pairing USB ambiguity, pass `authOverride: "<code>"`
selected from the `ios_ambiguous_pairings` error's `distinctAuthCodes`.

**Standalone CLI (no MCP client).** For CI bootstrap or ad-hoc shells:

```bash
# One-command attach — launches the installed app, resolves Bonjour,
# spawns iproxy as a child process, prints the wsUri.
sleuth_mcp attach-ios <udid> --bundle com.example.example
# → wsUri: ws://127.0.0.1:<port>/<token>=/ws
#   iproxy running (pid 12345). Press Ctrl-C to tear down.

# Paste the wsUri into your agent: attach_app(debugUrl: "<paste>")
```

If WebSocket attach is refused (403 / closed), re-run with
`--auth <code>` choosing one of the printed pairings — Bonjour
ordering between USB and WiFi paths is non-deterministic and the
WiFi-bridged authCode is refused when reached through the USB tunnel.

**No-Dart alternative.** CI bootstrap scripts and ad-hoc shells that
don't have `sleuth_mcp` pub-activated can run the equivalent bash
wrapper:

```bash
./packages/sleuth_mcp/tool/attach_ios.sh <udid> --bundle com.example.example
```

Same flags (`--bundle`, `--port`, `--auth`), same output, same
USB-vs-WiFi Bonjour caveat. Requires `brew install libimobiledevice`
(for `iproxy`); no `coreutils` needed — the script uses `/usr/bin/perl`
for its dns-sd timeout. The Dart subcommand remains the canonical
entry; the bash wrapper exists for parity + as a readable reference
for the `devicectl → dns-sd → iproxy` pipeline.

## Tools

| Tool | Args | Purpose |
| --- | --- | --- |
| `connect` | `uri` | Attach to a running Flutter app. Always call first. Returns `connectionMode`, `sessionUuid`, and a `warning` if sidecar / app versions are skewed. |
| `get_snapshot` | — | Full performance snapshot (issues, frame stats, route history). |
| `get_issues` | `route?`, `severityAtLeast?` | Currently-aggregated issues. Optional route filter and case-insensitive severity gate (`ok` / `warning` / `critical`). |
| `get_route_health` | `route?` | Per-route health score + FPS + issue counts. |
| `explain_issue` | `stableId` | Encyclopedia entry — parametric stableIds resolve through canonical form. |
| `compare_snapshots` | `before`, `after` | Pure client-side diff of two snapshots. Use to compare runs before / after a code change. |
| `check_budgets` | `minFps`, `maxIssues`, `maxCriticalIssues` | Compare live snapshot against thresholds. For CI exit-code gating use the separate `sleuth_check` binary. |
| `diagnose` | — | Operational health: package version, VM connection, unbound extension names. Use when other tools return empty. |
| `attach_app` | `device?`, `debugUrl?`, `udid?`, `bundle?`, `transport?`, `authOverride?` | Three routing modes: `udid` drives the iOS attach pipeline directly (devicectl + Bonjour + iproxy); `debugUrl` connects to a known WebSocket URI; `device` spawns `flutter attach --machine`. iOS-direct sessions report `transportMode` + `wsUri` on the response. |
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

Wire-shape contracts:

- [`doc/mcp_schema.json`](doc/mcp_schema.json) +
  [`doc/mcp_schema.md`](doc/mcp_schema.md) — `ext.sleuth.*` envelope
  shapes (mirrored from the root sleuth package).
- [`doc/mcp_tool_schema.json`](doc/mcp_tool_schema.json) +
  [`doc/mcp_tool_schema.md`](doc/mcp_tool_schema.md) — sidecar
  tool-call return shapes (success `data:` + error `errors:`) for the
  13 MCP tools.

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
| --- | --- |
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
