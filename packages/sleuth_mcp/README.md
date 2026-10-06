# sleuth_mcp

`sleuth_mcp` is an MCP stdio sidecar for [sleuth](https://github.com/Harrys76/sleuth).
It connects the `ext.sleuth.*` VM service extensions to AI clients such as
Claude Code, Cursor and Zed over the Model Context Protocol, so your
assistant can query a running Flutter app's live performance data.

The in-app overlay is still sleuth's main interface. The sidecar is opt-in.

## Quickstart

```bash
dart pub global activate sleuth_mcp
sleuth_mcp install        # writes mcpServers.sleuth to ~/.claude.json
```

1. Reload your MCP client.
2. Run your app with `flutter run --profile --no-dds`. Without `--no-dds`
   Sleuth cannot reach the VM service, so its memory, CPU and repaint
   detectors stay off (see [Connection modes](#connection-modes)).
3. Ask the assistant to "attach to my Flutter app and explore". It calls
   `list_devices` and then `attach_app`, which spawns
   `flutter attach --machine`, finds the VM service URI and connects.
4. Ask a question such as "what's causing jank on the checkout route?".
   The assistant calls the tools below against the live session.

The server tells the client this workflow in the `instructions` field of
its `initialize` result.

You can run `install` more than once. It takes an advisory lock, writes the
config through an atomic rename and keeps a `.bak` copy. For a
project-local install, add `sleuth_mcp: ^0.8.0` to `dev_dependencies`
instead.

Cursor, Zed and hand-written configs use the same `command`. To connect at
startup, pass a known VM service URI with `--uri`. It takes the http URI
that `flutter run` prints or the ws form. The server answers `initialize`
at once and connects in the background; tool calls wait up to 15 seconds
for that connect.

```json
{
  "mcpServers": {
    "sleuth": {
      "command": "sleuth_mcp",
      "args": ["--uri", "http://127.0.0.1:55555/<token>=/"]
    }
  }
}
```

`--tool-timeout <seconds>` (default 10) bounds each tool call. It takes a
whole number of seconds, 1 or more; any other value exits `64` with a
usage error. When the client closes stdin, or the sidecar gets SIGINT or
SIGTERM, it detaches the session (waiting at most 10 seconds), so a
`flutter attach` child or an `iproxy` tunnel does not outlive it. While
the detach runs, it waits at most 10 seconds for requests still running
to finish and answer, then exits without them, so the sidecar exits
within about 12 seconds.

## Version compatibility

sleuth_mcp 0.8.0 is built against sleuth 0.37.0
(`sleuth_mcp --version` prints both). When it connects, it reads the app's
`packageVersion` from `ext.sleuth.diagnose`:

- Another version in the 0.37 lineage, such as 0.37.1 or 0.37.0-dev.1,
  connects with `warning: version_skew_minor`.
- An app on the 0.36 lineage connects with
  `warning: version_skew_prior_lineage`.
- Any other lineage is refused with `version_skew_major`. A
  `packageVersion` that is not semver `major.minor.patch` is refused with
  `version_skew_unknown`. The sidecar disconnects in both cases.

## Tools

| Tool | Args | Purpose |
| --- | --- | --- |
| `list_devices` | `mobileOnly?` | Runs `flutter devices --machine` and lists Android and iOS devices by default. |
| `attach_app` | `device?`, `debugUrl?`, `udid?`, `bundle?`, `transport?`, `authOverride?`, `forceRelaunch?` | Attaches to a running app. See [Attaching](#attaching) for the three modes, progress and cancellation. A failed attach returns `isError` with code `attach_failed`. |
| `connect` | `uri` | Connects to a known VM service URI: the http URI that `flutter run` prints (`http://127.0.0.1:PORT/<token>=/`) or the ws form, with or without `/ws`. Returns `connectionMode`, `vmConnected`, `sessionUuid`, the ws `vmServiceUri` it connected to, and a `warning` on version skew. `attach_app` returns the same `warning`. While an `attach_app` session is attached or attaching it refuses with `attached_session`; call `detach_app` first. |
| `get_snapshot` | `sections?`, `full?`, `maxIssueCount?`, `maxRouteCount?`, `diskHandoff?`, `verbose?` | Returns the performance snapshot: issues, frame stats summary, route history, session summary and recurrence trends. By default it leaves out the per-frame and raw sample sections (`capturedFrames`, `recentFrames`, `recentRequests`, `heapSamples`, `phaseEvents`, `gcEvents`, `platformChannelEvents`) and lists them in `data._omittedSections`. Pass `full: true` for every section, or `sections` to pick them. Issues are compact unless you pass `verbose: true`. |
| `get_issues` | `route?`, `severityAtLeast?`, `maxIssueCount?`, `verbose?` | Returns the current issues. `route` filters by route. `severityAtLeast` takes `ok`, `warning` or `critical` in lower case; the server rejects other values. Issues are compact and capped at 50 by default. `verbose: true` returns every field, and `maxIssueCount` changes the cap (`0` removes it). |
| `get_route_health` | `route?` | Returns the health score, FPS and issue counts for each route. |
| `explain_issue` | `stableId` | Returns the encyclopedia entry. Parametric stableIds resolve to their canonical form. On sleuth 0.37 apps the route, widget and count text comes from the live issue with that exact stableId. A canonical id with no exact match uses the first live issue of its family, and any other id gets neutral wording. Sleuth 0.36 apps return raw placeholders such as `{widgetName}` and `{routeName}`. |
| `compare_snapshots` | `before`, `after` | Diffs two snapshots on the client: added, removed and elevated issues, occurrence-count changes and the FPS delta. Issues aggregate per stableId. Refuses snapshots from different sleuth lineages (`arg_lineage_mismatch`), a snapshot taken while Sleuth was still warming up (`arg_snapshot_in_warmup`), or snapshots with different VM coverage (`arg_coverage_mismatch`, read from `isVmConnected`), and adds `coverageWarning` when neither snapshot had a VM link. |
| `check_budgets` | `minFps?`, `maxIssues?`, `maxCriticalIssues?` | Checks the live snapshot against the thresholds. Each is optional with the `sleuth_check` default: `minFps` 55, `maxIssues` 999999 (no practical limit), `maxCriticalIssues` 0. Refuses with `coverage_degraded` when the app has no VM service link. Requests only the `currentIssues` and `frameStatsSummary` sections, as `sleuth_check` does. Use `sleuth_check` for CI exit codes. |
| `diagnose` | none | Reports operational health: package version, VM connection and unbound extensions, plus the frame budget and VM poll timings on sleuth 0.37 apps. Call it when other tools return nothing. |
| `app_status` | none | Returns `{attached, state, connected, connectedVia, device, appId, sessionUuid, launchMode, mode, lastError}`, plus `transportMode` and `wsUri` on iOS-direct sessions. `connected` and `connectedVia` (`attach_device`, `attach_debug_url`, `attach_ios` or `connect`) report the bridge whichever tool opened it. `attached` is true only for an `attach_app` session in state `ready` whose bridge is still connected. |
| `detach_app` | none | Stops the daemon child or the `iproxy` tunnel, disconnects the bridge in every state, including a bridge opened with `connect`, clears the `get_logs` buffer and deletes disk-handoff files. A detach during an attach stops it and the commands it runs. Every step is bounded, so a detach ends within about 7 seconds. Safe to call when nothing is attached. |
| `hot_reload` | none | Hot reloads the app and keeps its state and `sessionUuid`. Works only on sessions attached with `attach_app(device:)`; other sessions get `hot_reload_unsupported` and keep working. A rejected reload, for example on a compile error, returns `hot_reload_failed`. While it runs, new tool calls, resource reads and prompts wait for it; `ping` and cancellations are answered at once. |
| `get_logs` | `maxLines?`, `filter?` | Returns the app's recent output: `print` and stderr lines and `dart:developer` log records from the VM service, or flutter daemon `app.log` lines while those streams are not active. The sidecar keeps the last 500 lines. `maxLines` defaults to 100, `filter` keeps lines containing the text (case insensitive), and `droppedCount` says how many older lines were evicted. `attach_app`, `detach_app` and a `connect` to another app clear the lines, so two apps' output never mixes. `truncated: true` marks a line that is not complete, such as a `dart:developer` message longer than 2000 characters. |

Every tool except `connect`, `attach_app`, `detach_app` and `hot_reload` sets `annotations.readOnlyHint: true`, so a client that honors the hint can approve those calls without asking each time. Each descriptor also sets `destructiveHint`, `idempotentHint` and `openWorldHint`, and an audit checks the values against `doc/mcp_tool_schema.json`. Among the read-only tools, `openWorldHint` is true for the ones that read the live app or host (`get_snapshot`, `get_issues`, `get_route_health`, `explain_issue`, `diagnose`, `check_budgets`, `list_devices`), and false for `compare_snapshots`, `app_status` and `get_logs`, which read only their input or the sidecar's own state. `detach_app` sets `destructiveHint: true` because it ends the session and deletes disk-handoff files.

**Snapshot size.** On an iPhone 12, a full snapshot was 87 KB right after launch and 528 KB after a few minutes on an animated screen, about 90 % of it `capturedFrames` and `recentFrames`. A `2025-06-18` client receives the JSON of each result twice (text and `structuredContent`), and Claude Code caps a tool result at 25,000 tokens by default. The default set is about 3 to 15 KB. Use `sections` for the heavy data you need, such as `sections: ["recentFrames"]`, or `diskHandoff: true`, which writes every section to a temp file.

**Compact issues.** By default `get_issues` and `get_snapshot` trim each issue to `severity`, `category`, `confidence`, `title`, `detail`, `fixHint`, `stableId`, `widgetName`, `routeName`, `sourceRoute`, `confidenceReason` and `rootCauseIds`. Pass `verbose: true` for the full issue, which has up to 26 keys. Compaction drops whole fields and never shortens a value, so it does not bound the response size; `maxIssueCount` and `diskHandoff` do. `get_issues` also keeps only the top 50 ranked issues by default and adds `_truncated` and `_totalCount` when it drops any. `maxIssueCount` changes that cap, `0` removes it, and a negative value returns `arg_invalid_int`. The cap applies with or without `verbose`. Compact issues keep `stableId` and `severity`, so `compare_snapshots` and `check_budgets` work on them.

**Structured content.** A client that negotiates MCP protocol `2025-06-18` or later gets a top-level `structuredContent` object on every successful `tools/call` result. It holds the same JSON as the text block, so the client does not need to parse the text. Clients on `2024-11-05` or `2025-03-26` get the text block only. Error results never carry `structuredContent`. A client that asks for a protocol version the server does not support gets `2025-06-18`, the latest one it speaks.

**Errors and timeouts.** Connection errors start with a code and say what to do next.

- `not_connected`: no app is attached. Call `attach_app` or `connect`.
- `timeout_after_<ms>ms`: the app did not answer in time, for example while it janks. The connection is kept, so retry or call `diagnose`. Each app call has its own limit, shorter than `--tool-timeout` (8 seconds for the default 10), so a slow call reports itself before the tool timeout.
- `app_busy`: 8 earlier calls timed out and the app still has not answered them, so the sidecar sends no more until it does. Retry in a few seconds, or call `attach_app` or `connect` to open a new connection.
- `session_changed`: the app restarted (for example a hot restart). It is reported once; the sidecar then follows the new session, so calling the tool again works. This covers a hot restart from `flutter run`, which replaces the app's isolate: the sidecar waits up to the per-call timeout for the new isolate to start Sleuth. When the sidecar could not read the new session yet, the message says so and the next call tries again. When the restart closed the connection, the message says to call `attach_app` or `connect` instead.

[`doc/mcp_tool_schema.md`](doc/mcp_tool_schema.md#server-level-errors) lists every error.

### Resources

- `sleuth://encyclopedia`: every `IssueExplanation`, keyed by canonical stableId.
- `sleuth://causal-graph`: the rules that link trigger stableIds to their downstream effects.

The sidecar caches both per `sessionUuid`. It fetches them again when the
app's session changes or the client sends `initialize` again.
[`doc/mcp_tool_schema.md`](doc/mcp_tool_schema.md) locks the tool return
shapes, and [`doc/mcp_schema.md`](doc/mcp_schema.md) locks the
`ext.sleuth.*` envelopes.

### Prompts

`prompts/list` and `prompts/get` serve three guided diagnostics. None takes arguments. Each one tells the client's model which tools to call, in order:

- `triage_performance` asks for the ranked issues from `get_issues`, then `get_snapshot` with `sections` set to `frameStatsSummary`, `sessionSummary`, `recurrenceTrends` and `routeSessions` (frame stats, memory trend, worsening issues and per-route health, without fetching the issues twice), then `explain_issue` on the most severe issue, and a summary of fixes ordered by severity that names the worst route.
- `audit_memory` asks for the memory issues from `get_issues` (heap growth, retained streams, tracked resources) and `explain_issue` on each, then remediations.
- `release_check` asks for `check_budgets` and the critical issues from `get_issues`, then a PASS or FAIL verdict. When `check_budgets` refuses, for example with `coverage_degraded`, the verdict is NOT RUN.

## Attaching

`attach_app` has three routing modes:

- `device` spawns `flutter attach --machine`. This is the Quickstart path.
- `debugUrl` connects to a WebSocket URI you already have.
- `udid` with `bundle` runs the iOS real-device pipeline directly. It
  needs macOS; on other hosts it returns `ios_missing_tool`.

On Windows the sidecar starts `flutter` through the shell, so
`flutter.bat` is found on PATH. That makes the child `cmd.exe`, so to stop
flutter the sidecar ends the whole process tree with
`taskkill /PID <pid> /T /F`.

While an `attach_app` session is attached or attaching, `connect` refuses
with `attached_session`, because pointing the bridge at another app would
leave `hot_reload` reloading the attached one. Call `detach_app` first.

When `flutter attach` exits before the app reports its VM service, for
example because more than one device is connected and `device` is not
set, `attach_app` returns `attach_failed` at once with the last lines
flutter printed, instead of waiting for the 30-second timeout.

**Progress and cancellation.** An iOS attach can take longer than a
client's request timeout. When the client sends a `progressToken` with
the request, `attach_app` reports each stage (starting flutter, waiting
for the daemon, Bonjour, launching the app, the `iproxy` tunnel,
connecting) as a `notifications/progress` frame. When the client sends
`notifications/cancelled` for the request, the sidecar stops the attach,
releases the `flutter attach` child or the `iproxy` tunnel, disconnects
the bridge and sends no response, as the MCP spec asks. `detach_app` and
the sidecar's shutdown stop an attach in flight the same way. The sidecar
owns every command the attach runs (`flutter devices`, `xcrun devicectl`,
`dns-sd`, `which`, `kill`, `ps`): a cancel, a detach or a step timeout
ends the command with `SIGTERM`, then `SIGKILL` after 1 second, instead
of leaving it running.

**iOS real device.** USB attach needs `iproxy`, so install it once with
`brew install libimobiledevice`. Wireless attach does not need it. Build
and install the app once (`flutter run --profile -d <udid>`, then quit).
Then call:

```
attach_app(udid: "<udid>", bundle: "com.example.example")
→ {attached: true, state: "ready", launchMode: "ios-direct",
   transportMode: "wired"|"wireless", wsUri: "ws://...", sessionUuid: ...}
```

The sidecar first looks for a VM service that the app already announces
over Bonjour. If none is announced, it launches the app with
`xcrun devicectl`. It then opens an `iproxy` tunnel on USB, or uses the
device's `.local` host on wireless, and connects the bridge.
`forceRelaunch: true` skips the first Bonjour check and launches the app.
`detach_app()` disconnects the bridge and then stops the `iproxy` child.

The transport defaults to `auto`, which reads `xcrun devicectl list devices`.
Pass `transport: "usb"` or `transport: "wireless"` to override it. When
the device announces more than one pairing with different authCodes, for
example a stale and a fresh service after a relaunch, `attach_app` tries
each code and keeps the one whose VM service connects. Pass
`authOverride: "<code>"` to pin one code instead. When the first
connection is reset or refused because Bonjour still lists a dead port,
the sidecar retries once with that port excluded.

**Standalone CLI.** Use it to bootstrap CI or from a shell with no MCP client:

```bash
sleuth_mcp attach-ios <udid> --bundle com.example.example
# → wsUri: ws://127.0.0.1:<port>/<token>=/ws ; iproxy running (Ctrl-C to tear down)
# then in your agent: attach_app(debugUrl: "<paste wsUri>")
```

If the WebSocket attach is refused (403 or closed), run the command again
with `--auth <code>`. Bonjour can list the Wi-Fi pairing before the USB
one, and the USB tunnel refuses the Wi-Fi authCode.

### Scope

- Android and iOS only. `list_devices` keeps devices whose `category` is
  `mobile`, or whose `targetPlatform` starts with `ios` or `android` when
  the daemon omits `category`. Pass `mobileOnly: false` to include
  desktop, web and embedded devices.
- One sidecar process owns one `flutter attach --machine` child. Each MCP
  client spawns its own sidecar.
- The flutter daemon must speak protocol `0.6.0` or later.

## Connection modes

Every `ext.sleuth.*` response carries a `connectionMode`, and `diagnose`
returns it. The mode says whether the app's own in-process VM connection
is live. The sidecar's bridge does not affect it.

- `warmup`: the first seconds after Sleuth initializes. The mode is not
  final yet.
- `basic`: Sleuth has no VM service link, or it has one and its verdict
  has not reached full mode yet. FrameTiming and structural detectors run.
  Without a VM link these stableIds are never reported: `heap_growing`,
  `gc_pressure`, `heap_near_capacity`, `native_memory_growing`,
  `heavy_compute`, `shader_compilation`, `platform_channel_traffic`,
  `stream_resource_growth`, `rebuild_activity` and `excessive_repaint`.
  Causal links and confidence upgrades that depend on one of them do not
  form either.
- `full`: the VM is connected and its timeline data arrives in batches.
- `correlated`: the VM is connected and timeline events match individual
  frames.
- `disconnected`: Sleuth is not initialized, or its controller was
  disposed.

`connect`, `attach_app`, `diagnose`, `get_snapshot` and `get_issues` add a
`launchModeAdvisory` string when the session is degraded: `warmup`,
`disconnected`, or `basic` without a VM link. The advisory names the
VM-only stableIds and says what to do. For `warmup` it asks the client to
run `diagnose` again shortly. For `basic` it suggests reopening the app,
then relaunching with `--no-dds` if the app was started with
`flutter run`. For `disconnected` it suggests
`flutter run --profile --no-dds`. Because the data tools add it too, a
client never reads a degraded issue list without the warning. `basic` means
Sleuth has no VM-tier frame verdict yet. A smooth session whose VM is
connected stays `basic` until a frame janks, so every tool reads the
app's VM flag before adding the advisory, and a connected `basic` session
gets none. `get_issues` reads `vmConnected` from the `ext.sleuth.issues`
payload; for apps before sleuth 0.37 it reads it from `ext.sleuth.diagnose`
first and adds no advisory when that read fails. `app_status` never
carries it.

`flutter run` starts DDS (Dart Development Service) by default. DDS
becomes the only client of the device's VM service, so Sleuth cannot
connect and `vmConnected` stays false. Pass `--no-dds` so Sleuth connects
on the first run:

```bash
flutter run --profile --no-dds
```

The VM service then accepts more than one client, and Sleuth connects to
it. In full mode Sleuth polls the VM on the app isolate. The cost is
negligible on real devices but can lower FPS on emulators and simulators,
so measure frame rates on real hardware. Hot reload and hot restart still
work. You lose the features that only DDS provides, such as multi-client
DevTools and log history.

If you also need DDS and DevTools, launch the installed binary yourself
and then call `attach_app(debugUrl: …)`:

```bash
# Android: relaunch the installed APK, read the URI, forward the port.
adb -s <id> shell am start -n com.example.example/.MainActivity
adb -s <id> logcat -d | grep "Dart VM service"   # → http://127.0.0.1:PORT/<token>=/
adb -s <id> forward tcp:PORT tcp:PORT
# attach_app(debugUrl: "ws://127.0.0.1:PORT/<token>=/ws")

# iOS simulator: shares localhost, so no port forward is needed.
xcrun simctl launch booted com.example.example
xcrun simctl spawn booted log stream --predicate 'process == "Runner"' | grep "Dart VM service"
# attach_app(debugUrl: "ws://127.0.0.1:PORT/<token>=/ws")
```

`diagnose` then reports `full`, or `correlated` once the per-frame
timeline correlator has warmed up.

## CI gate with `sleuth_check`

The stdio server cannot report a CI failure through its exit code, so CI
uses the one-shot `sleuth_check` binary:

```bash
sleuth_check --uri "http://127.0.0.1:55555/<token>=/" \
  --min-fps 55 --max-issues 10 --max-critical-issues 0 --json
```

`--uri` takes the http URI that `flutter run` prints or the ws form. It
exits `0` on a pass and `1` on a budget violation. It exits `2` when the
check could not run: a connect failure, a version refusal, a malformed
snapshot, or `coverage_degraded`. `coverage_degraded` means Sleuth had no
VM service link, so its VM-only detectors never ran; relaunch with
`flutter run --profile --no-dds`. A bad command line exits `64`: a
missing `--uri`, a URI that is not http, https, ws or wss, a non-numeric
`--min-fps`, a `--max-issues` or `--max-critical-issues` that is not a
non-negative integer, or an unknown option.

To inspect a live app from your own Dart tool, call the `ext.sleuth.*`
extensions directly with `package:vm_service`. You do not need the
sidecar for that.

## Known limitations

- Android and iOS only. `attach_app` rejects a non-mobile `device`.
- One `flutter attach --machine` child per sidecar process.
- Clients on MCP protocol versions before `2025-06-18` get every tool
  result, including the `compare_snapshots` diff, only as JSON text in
  `content[0].text`.
- JSON-RPC batches work only for clients that negotiate MCP `2025-03-26`,
  the one version that defines them (`2025-06-18` removed them). On
  `2024-11-05` or `2025-06-18` a batch gets one Invalid Request error;
  send each request on its own line.
- There is no `hot_restart` tool. In Android profile mode the new main
  isolate does not register again within the bridge's reconnect window
  after `app.restart`. Use `detach_app` and then `attach_app`.
  `hot_reload` works.
