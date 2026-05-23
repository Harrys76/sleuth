# sleuth_mcp

MCP stdio sidecar for [sleuth](https://github.com/Harrys76/sleuth).
Bridges the `ext.sleuth.*` VM service extensions to AI clients
(Claude Code, Cursor, Zed) over the Model Context Protocol, so your
assistant can query a running Flutter app's live performance data in
conversation.

The in-app overlay remains sleuth's primary UX. This sidecar is opt-in.

## Quickstart

```bash
dart pub global activate sleuth_mcp
sleuth_mcp install        # writes mcpServers.sleuth to ~/.claude.json
```

1. Reload your MCP client.
2. Run your app: `flutter run` (debug or profile).
3. In conversation: **"attach to my Flutter app and explore"** — the
   agent calls `list_devices` → `attach_app`, which spawns
   `flutter attach --machine`, discovers the VM service URI, and connects.
4. Ask away: *"what's causing jank on the checkout route?"* The agent
   calls the tools below against the live session.

`install` is idempotent (advisory lock + atomic rename + `.bak`). For a
project-local install instead, add `sleuth_mcp: ^0.7.0` to
`dev_dependencies`.

**Cursor / Zed** (or manual config) — same `command`, point it at a
known VM service URI:

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

## Tools

| Tool | Args | Purpose |
| --- | --- | --- |
| `list_devices` | `mobileOnly?` | `flutter devices --machine`, mobile-only by default (android + ios). |
| `attach_app` | `device?`, `debugUrl?`, `udid?`, `bundle?`, `transport?`, `authOverride?` | Attach. Three modes — see [Attaching](#attaching). |
| `connect` | `uri` | Attach to a known VM service URI. Returns `connectionMode`, `sessionUuid`, and a `warning` on version skew. |
| `get_snapshot` | `sections?`, `maxIssueCount?`, `maxRouteCount?`, `diskHandoff?`, `verbose?` | Full performance snapshot (issues, frame stats, route history). Issues are compact by default — pass `verbose: true` for full fields. |
| `get_issues` | `route?`, `severityAtLeast?`, `maxIssueCount?`, `verbose?` | Currently-aggregated issues. Optional route filter + case-insensitive severity gate (`ok` / `warning` / `critical`). Compact + capped to 50 by default; `verbose: true` for full fields, `maxIssueCount` to change the cap (`0` = unbounded). |
| `get_route_health` | `route?` | Per-route health score + FPS + issue counts. |
| `explain_issue` | `stableId` | Encyclopedia entry; parametric stableIds resolve through canonical form. |
| `compare_snapshots` | `before`, `after` | Client-side diff of two snapshots — added / removed / elevated issues, fps delta. |
| `check_budgets` | `minFps`, `maxIssues`, `maxCriticalIssues` | Compare the live snapshot against thresholds. For CI exit codes use `sleuth_check`. |
| `diagnose` | — | Operational health: package version, VM connection, unbound extensions. Use when other tools return empty. |
| `app_status` | — | `{attached, state, device, appId, sessionUuid, launchMode, mode, lastError}`. |
| `detach_app` | — | Stop the daemon child + disconnect the bridge. Idempotent. |
| `hot_reload` | — | Hot reload (preserves state + sessionUuid). Daemon-spawn sessions only. |

The read tools (everything except `connect`, `attach_app`, `detach_app`, `hot_reload`) carry `annotations.readOnlyHint: true`, so MCP clients that honor it can auto-approve them instead of prompting per call.

**Compact issues (default).** `get_issues` and `get_snapshot` trim each issue to an actionable subset (`severity`, `category`, `confidence`, `title`, `detail`, `fixHint`, `stableId`, `widgetName`, `routeName`, `sourceRoute`, `confidenceReason`, `rootCauseIds`) so responses stay readable and smaller. Pass `verbose: true` for the full ~22-field shape. Compaction drops fields, not field contents — hard size bounds come from `maxIssueCount` (issue count) and `diskHandoff` (large snapshots), not from field compaction. `get_issues` also caps to the top 50 ranked issues by default and stamps `_truncated` + `_totalCount` when it drops any — raise or disable with `maxIssueCount` (`0` = unbounded; negative is rejected with `arg_invalid_int`). The cap is independent of `verbose`. Compaction keeps `stableId` + `severity`, so `compare_snapshots` and `check_budgets` still work on compact snapshots.

**Structured content (MCP `2025-06-18`+).** Clients that negotiate protocol `2025-06-18` or later get a top-level `structuredContent` field on every **success** `tools/call` result — the same JSON the text block carries, as an object — so there's no need to re-parse the text. Older clients (`2024-11-05`, `2025-03-26`) receive the text content only. `structuredContent` is never set on error results.

### Resources

- `sleuth://encyclopedia` — every `IssueExplanation` keyed by canonical stableId.
- `sleuth://causal-graph` — rule set linking trigger stableIds to downstream effects.

Both cache per `sessionUuid` and refresh inline on hot-restart of the
target app. Wire shapes are locked in
[`doc/mcp_tool_schema.md`](doc/mcp_tool_schema.md) (tool returns) and
[`doc/mcp_schema.md`](doc/mcp_schema.md) (`ext.sleuth.*` envelopes).

### Prompts

Guided-diagnostic templates surfaced via `prompts/list` + `prompts/get`. Each is argument-free and instructs the client's model to chain the tools above:

- `triage_performance` — snapshot → top-ranked issues → explain the worst → worst route.
- `audit_memory` — memory-class issues (heap growth, retained streams, tracked resources) → explain → remediations.
- `release_check` — `check_budgets` + critical issues → PASS/FAIL verdict.

## Attaching

`attach_app` has three routing modes:

- **`device`** — spawns `flutter attach --machine` (the Quickstart path).
- **`debugUrl`** — connects to a WebSocket URI you already have.
- **`udid` + `bundle`** — drives the iOS real-device pipeline directly.

**iOS real device — one call.** Prerequisite once:
`brew install libimobiledevice` (provides `iproxy` for USB-tethered
attach; not needed for wireless pairings). Build + install the app once
(`flutter run --profile -d <udid>`, then quit), then:

```
attach_app(udid: "<udid>", bundle: "com.example.example")
→ {attached: true, state: "ready", launchMode: "ios-direct",
   transportMode: "wired"|"wireless", wsUri: "ws://...", sessionUuid: ...}
```

The sidecar runs the full pipeline (devicectl launch → Bonjour resolve →
iproxy tunnel on USB, or direct `.local` host on wireless → bridge
connect). `detach_app()` tears down the bridge and iproxy child in order.

Transport defaults to `auto`. Override with `transport: "usb"` /
`"wireless"`. On multi-pairing USB ambiguity, pass `authOverride: "<code>"`
from the `ios_ambiguous_pairings` error's `distinctAuthCodes`.

**Standalone CLI** (CI bootstrap or shells with no MCP client):

```bash
sleuth_mcp attach-ios <udid> --bundle com.example.example
# → wsUri: ws://127.0.0.1:<port>/<token>=/ws ; iproxy running (Ctrl-C to tear down)
# then in your agent: attach_app(debugUrl: "<paste wsUri>")
```

If WebSocket attach is refused (403 / closed), re-run with `--auth <code>`
— USB-vs-WiFi Bonjour ordering is non-deterministic and the WiFi-bridged
authCode is refused through the USB tunnel.

### Scope

- Android + iOS only. `list_devices` filters by `category == 'mobile'`;
  pass `mobileOnly: false` for desktop / web / embedded.
- One sidecar process owns one `flutter attach --machine` child; each MCP
  client spawns its own sidecar.
- Min Flutter daemon protocol version `0.6.0`.

## Connection modes — `basic` vs `full`

`diagnose` reports a `connectionMode`. It reflects whether the **app's
own** in-process VM connection is live, independent of the sidecar bridge:

- **`basic`** — sleuth couldn't self-connect to the host VM service.
  FrameTiming + structural detectors fire; vmOnly detectors
  (`excessive_repaint`, `gc_pressure`, `heap_growing`, `heavy_compute`,
  `stream_resource_growth`) stay silent; causal-graph links inactive;
  structural confidence stays `possible`.
- **`full` / `correlated`** — VM connected. vmOnly detectors fire,
  confidence escalates to `likely` / `confirmed`, causal-graph links wire.

`flutter run` defaults to **DDS** (Dart Development Service), which claims
the device's VM service as its sole client and forces `basic` for the
session. Reach `full` on the first run with `--no-dds`:

```bash
flutter run --profile --no-dds
```

The VM service stays multi-client, so sleuth self-connects. Full mode runs
periodic VM polling on the app isolate — negligible on real devices,
but it can depress FPS on emulators/simulators; measure frame rates on
real hardware. Hot reload/restart are unaffected; you lose DDS-only
niceties (multi-client DevTools, log history).

Fallback (when you need DDS + DevTools too): launch the installed binary
directly, then `attach_app(debugUrl: …)`:

```bash
# Android — relaunch the installed APK, read the URI, forward the port:
adb -s <id> shell am start -n com.example.example/.MainActivity
adb -s <id> logcat -d | grep "Dart VM service"   # → http://127.0.0.1:PORT/<token>=/
adb -s <id> forward tcp:PORT tcp:PORT
# attach_app(debugUrl: "ws://127.0.0.1:PORT/<token>=/ws")

# iOS simulator — shares localhost, no forward needed:
xcrun simctl launch booted com.example.example
xcrun simctl spawn booted log stream --predicate 'process == "Runner"' | grep "Dart VM service"
# attach_app(debugUrl: "ws://127.0.0.1:PORT/<token>=/ws")
```

`diagnose` then reports `full` (or `correlated` once the per-frame
timeline correlator warms up).

## `sleuth_check` — CI gate

The stdio server can't signal CI failure via exit code, so use the
one-shot binary:

```bash
sleuth_check --uri "ws://127.0.0.1:55555/<token>=/ws" \
  --min-fps 55 --max-issues 10 --max-critical-issues 0 --json
```

Exits `0` pass, `1` budget violation, `2` connect / handler failure.

For live programmatic inspection from a custom Dart tool, call
`ext.sleuth.*` directly via `package:vm_service` — no sidecar needed.

## Known limitations

- Android + iOS only; `attach_app` rejects non-mobile devices.
- One `flutter attach --machine` child per sidecar process.
- `compare_snapshots` returns its diff as a JSON-stringified `text`
  content block — parse `content[0].text`.
- `hot_restart` not supported: Android profile-mode doesn't re-register
  the new main isolate within the bridge's reconnect window after
  `app.restart`. Use `detach_app` + `attach_app`. `hot_reload` is fine.
