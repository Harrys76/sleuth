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
at once and connects in the background. Tool calls wait up to 15 seconds
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

`--tool-timeout <seconds>` (default 10) sets the time limit for each tool
call. It takes a whole number of seconds, 1 or more. Any other value
makes the sidecar exit with code `64` and a usage error.

When the client closes stdin, or the sidecar gets SIGINT or SIGTERM, the
sidecar detaches the session and waits at most 10 seconds for the
detach. A `flutter attach` child or an `iproxy` tunnel therefore does not
outlive it. While the detach runs, the sidecar waits at most 10 seconds
for running requests to finish and answer, then exits without them. The
sidecar exits within about 12 seconds.

## Version compatibility

sleuth_mcp 0.8.0 is built against sleuth 0.37.0
(`sleuth_mcp --version` prints both). When it connects, it reads the app's
`packageVersion` from `ext.sleuth.diagnose`:

- Another version in the 0.37 lineage, such as 0.37.1 or 0.37.0-dev.1,
  connects with `warning: version_skew_minor`.
- An app on the 0.36 lineage connects with
  `warning: version_skew_prior_lineage`.
- The sidecar refuses any other lineage with `version_skew_major`. It
  refuses a `packageVersion` that is not semver `major.minor.patch` with
  `version_skew_unknown`. The sidecar disconnects in both cases.

## Tools

| Tool | Args | Purpose |
| --- | --- | --- |
| `list_devices` | `mobileOnly?` | Runs `flutter devices --machine` and lists Android and iOS devices by default. |
| `attach_app` | `device?`, `debugUrl?`, `udid?`, `bundle?`, `transport?`, `authOverride?`, `forceRelaunch?` | Attaches to a running app. See [Attaching](#attaching) for the three modes, progress and cancellation. A failed attach returns `isError` with code `attach_failed`. |
| `connect` | `uri` | Connects to a known VM service URI. It takes the http URI that `flutter run` prints (`http://127.0.0.1:PORT/<token>=/`) or the ws form, with or without `/ws`. It returns `connectionMode`, `vmConnected`, `sessionUuid`, the ws `vmServiceUri` it connected to, and a `warning` on version skew. `attach_app` returns the same `warning`. While an `attach_app` session is attached or attaching, `connect` refuses with `attached_session`. Call `detach_app` first. |
| `get_snapshot` | `sections?`, `full?`, `maxIssueCount?`, `maxRouteCount?`, `diskHandoff?`, `verbose?` | Returns the performance snapshot: issues, frame stats summary, route history, session summary and recurrence trends. By default it leaves out the per-frame and raw sample sections (`capturedFrames`, `recentFrames`, `recentRequests`, `heapSamples`, `phaseEvents`, `gcEvents`, `platformChannelEvents`) and lists them in `data._omittedSections`. Pass `full: true` for every section, or `sections` to pick them. Issues are compact unless you pass `verbose: true`. |
| `get_issues` | `route?`, `severityAtLeast?`, `maxIssueCount?`, `verbose?` | Returns the current issues. `route` filters by route. `severityAtLeast` takes `ok`, `warning` or `critical` in lower case. The server rejects other values. By default the tool returns compact issues, at most 50. `verbose: true` returns every field, and `maxIssueCount` changes the cap (`0` removes it). |
| `get_route_health` | `route?` | Returns the health score, FPS and issue counts for each route. |
| `explain_issue` | `stableId` | Returns the encyclopedia entry. Parametric stableIds resolve to their canonical form. On sleuth 0.37 apps the route, widget and count text comes from the live issue with that exact stableId. A canonical id with no exact match uses the first live issue of its family. Any other id gets neutral wording. Sleuth 0.36 apps return raw placeholders such as `{widgetName}` and `{routeName}`. |
| `compare_snapshots` | `before`, `after` | Diffs two snapshots on the client: added, removed and elevated issues, occurrence-count changes and the FPS delta. It aggregates issues per stableId. It refuses snapshots from different sleuth lineages (`arg_lineage_mismatch`), a snapshot taken while Sleuth was still warming up (`arg_snapshot_in_warmup`), and snapshots with different VM coverage (`arg_coverage_mismatch`, read from `isVmConnected`). It adds `coverageWarning` when neither snapshot had a VM link. |
| `check_budgets` | `minFps?`, `maxIssues?`, `maxCriticalIssues?` | Checks the live snapshot against the thresholds. Each threshold is optional and defaults to the `sleuth_check` value: `minFps` 55, `maxIssues` 999999 (no practical limit) and `maxCriticalIssues` 0. It refuses with `coverage_degraded` when the app has no VM service link. Like `sleuth_check`, it requests only the `currentIssues` and `frameStatsSummary` sections. Use `sleuth_check` for CI exit codes. |
| `diagnose` | none | Reports the package version, the VM connection and unbound extensions. On sleuth 0.37 apps it also reports the frame budget and VM poll timings. Call it when other tools return nothing. |
| `app_status` | none | Returns `{attached, state, connected, connectedVia, device, appId, sessionUuid, launchMode, mode, lastError}`, plus `transportMode` and `wsUri` on iOS-direct sessions. `connected` and `connectedVia` (`attach_device`, `attach_debug_url`, `attach_ios` or `connect`) describe the bridge, whichever tool opened it. `attached` is true only for an `attach_app` session in state `ready` whose bridge is still connected. |
| `detach_app` | none | Stops the daemon child or the `iproxy` tunnel. It disconnects the bridge in every state, including a bridge opened with `connect`. It clears the `get_logs` buffer and deletes disk-handoff files. A detach during an attach stops the attach and the commands it runs. Every step has a time limit, so a detach ends within about 7 seconds. You can call it when nothing is attached. |
| `hot_reload` | none | Hot reloads the app and keeps its state and `sessionUuid`. It works only on sessions attached with `attach_app(device:)`. Other sessions get `hot_reload_unsupported` and keep working. A rejected reload, for example on a compile error, returns `hot_reload_failed`. While it runs, new tool calls, resource reads and prompts wait for it. The server answers `ping` and cancellations at once. |
| `get_logs` | `maxLines?`, `filter?` | Returns the app's recent output: `print` and stderr lines and `dart:developer` log records from the VM service, or flutter daemon `app.log` lines while those streams are not active. The sidecar keeps the last 500 lines. `maxLines` defaults to 100. `filter` keeps lines containing the text, ignoring case. `droppedCount` says how many older lines the sidecar evicted. `attach_app`, `detach_app` and a `connect` to another app clear the lines, so two apps' output never mixes. `truncated: true` marks a line that is not complete, such as a `dart:developer` message longer than 2000 characters. |

Every tool except `connect`, `attach_app`, `detach_app` and `hot_reload` sets `annotations.readOnlyHint: true`, so a client that honors the hint can approve those calls without asking each time. Each descriptor also sets `destructiveHint`, `idempotentHint` and `openWorldHint`. An audit checks the values against `doc/mcp_tool_schema.json`. Among the read-only tools, `openWorldHint` is true for the ones that read the live app or host (`get_snapshot`, `get_issues`, `get_route_health`, `explain_issue`, `diagnose`, `check_budgets`, `list_devices`). It is false for `compare_snapshots`, `app_status` and `get_logs`, which read only their input or the sidecar's own state. `detach_app` sets `destructiveHint: true` because it ends the session and deletes disk-handoff files.

**Snapshot size.** On an iPhone 12, a full snapshot was 87 KB right after launch and 528 KB after a few minutes on an animated screen. About 90 % of it was `capturedFrames` and `recentFrames`. A `2025-06-18` client receives the JSON of each result twice, as text and as `structuredContent`. Claude Code caps a tool result at 25,000 tokens by default. The default set is about 3 to 15 KB. Use `sections` to fetch the heavy data you need, such as `sections: ["recentFrames"]`. Or pass `diskHandoff: true`, which writes every section to a temp file.

**Compact issues.** By default `get_issues` and `get_snapshot` trim each issue to `severity`, `category`, `confidence`, `title`, `detail`, `fixHint`, `stableId`, `widgetName`, `routeName`, `sourceRoute`, `confidenceReason` and `rootCauseIds`. Pass `verbose: true` for the full issue, which has up to 26 keys. Compaction drops whole fields and never shortens a value, so it does not bound the response size. `maxIssueCount` and `diskHandoff` do. By default `get_issues` also keeps only the top 50 ranked issues and adds `_truncated` and `_totalCount` when it drops any. `maxIssueCount` changes that cap, and `0` removes it. A negative value returns `arg_invalid_int`. The cap applies with or without `verbose`. Compact issues keep `stableId` and `severity`, so `compare_snapshots` and `check_budgets` work on them.

**Structured content.** A client that negotiates MCP protocol `2025-06-18` or later gets a top-level `structuredContent` object on every successful `tools/call` result. It holds the same JSON as the text block, so the client does not need to parse the text. Clients on `2024-11-05` or `2025-03-26` get the text block only. Error results never carry `structuredContent`. A client that asks for a protocol version the server does not support gets `2025-06-18`, the latest one it speaks.

**Errors and timeouts.** Connection errors start with a code and say what to do next.

- `not_connected`: no app is attached. Call `attach_app` or `connect`.
- `timeout_after_<ms>ms`: the app did not answer in time, for example while it janks. The sidecar keeps the connection, so retry or call `diagnose`. Each app call has its own limit, shorter than `--tool-timeout` (8 seconds for the default 10), so a slow call reports itself before the tool timeout.
- `app_busy`: 8 earlier calls timed out and the app still has not answered them, so the sidecar sends no more until it does. Retry in a few seconds, or call `attach_app` or `connect` to open a new connection.
- `session_changed`: the app restarted, for example on a hot restart. The sidecar reports it once and then follows the new session, so calling the tool again works. This covers a hot restart from `flutter run`, which replaces the app's isolate. The sidecar waits up to the per-call timeout for the new isolate to start Sleuth. When the sidecar could not read the new session yet, the message says so and the next call tries again. When the restart closed the connection, the message says to call `attach_app` or `connect` instead.

[`doc/mcp_tool_schema.md`](doc/mcp_tool_schema.md#server-level-errors) lists every error.

### Resources

- `sleuth://encyclopedia`: every `IssueExplanation`, keyed by canonical stableId.
- `sleuth://causal-graph`: the rules that link trigger stableIds to their downstream effects.

The sidecar caches both per `sessionUuid`. It fetches them again when the
app's session changes or the client sends `initialize` again.
[`doc/mcp_tool_schema.md`](doc/mcp_tool_schema.md) defines the tool return
shapes, and [`doc/mcp_schema.md`](doc/mcp_schema.md) defines the
`ext.sleuth.*` envelopes.

### Prompts

`prompts/list` and `prompts/get` serve three guided diagnostics. None takes arguments. Each one tells the client's model which tools to call, in order:

- `triage_performance` asks for the ranked issues from `get_issues`. It then asks for `get_snapshot` with `sections` set to `frameStatsSummary`, `sessionSummary`, `recurrenceTrends` and `routeSessions`. These give the frame stats, the memory trend, worsening issues and per-route health without fetching the issues twice. Next it asks for `explain_issue` on the most severe issue. It ends with a summary of fixes, ordered by severity, that names the worst route.
- `audit_memory` asks for the memory issues from `get_issues` (heap growth, retained streams, tracked resources) and `explain_issue` on each. It ends with recommended fixes.
- `release_check` asks for `check_budgets` and the critical issues from `get_issues`, then a PASS or FAIL verdict. When `check_budgets` refuses, for example with `coverage_degraded`, the verdict is NOT RUN.

## Attaching

`attach_app` has three routing modes:

- `device` spawns `flutter attach --machine`. This is the Quickstart path.
- `debugUrl` connects to a WebSocket URI you already have.
- `udid` with `bundle` runs the iOS real-device pipeline directly. It
  needs macOS. On other hosts it returns `ios_missing_tool`.

On Windows the sidecar starts `flutter` through the shell, so the shell
finds `flutter.bat` on PATH. The child process is then `cmd.exe`, so the
sidecar stops flutter by ending the whole process tree with
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
the sidecar's shutdown stop an attach in flight the same way. The attach
runs `flutter devices`, `xcrun devicectl`, `dns-sd`, `which`, `kill` and
`ps`. A cancel, a detach or a step timeout ends each of these commands
with `SIGTERM`, then `SIGKILL` after 1 second, so none is left running.

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
the sidecar retries once and leaves that port out.

**Standalone CLI.** Use it to set up CI, or from a shell with no MCP client:

```bash
sleuth_mcp attach-ios <udid> --bundle com.example.example
# Prints wsUri: ws://127.0.0.1:<port>/<token>=/ws and keeps iproxy running until Ctrl-C.
# Then call it from your agent: attach_app(debugUrl: "<paste wsUri>")
```

If the WebSocket attach is refused (403 or closed), run the command again
with `--auth <code>`. Bonjour can list the Wi-Fi pairing before the USB
one, and the USB tunnel refuses the Wi-Fi authCode.

### Scope

- The sidecar supports only Android and iOS. `list_devices` keeps
  devices whose `category` is `mobile`, or whose `targetPlatform` starts
  with `ios` or `android` when the daemon omits `category`. Pass
  `mobileOnly: false` to include desktop, web and embedded devices.
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
  Without a VM link Sleuth never reports these stableIds: `heap_growing`,
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
connected stays `basic` until a frame janks. Every tool therefore reads
the app's VM flag before adding the advisory, and a connected `basic`
session gets none. `get_issues` reads `vmConnected` from the
`ext.sleuth.issues` payload. For apps before sleuth 0.37 it reads the flag
from `ext.sleuth.diagnose` first and adds no advisory when that read
fails. `app_status` never carries the advisory.

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
VM service link, so its VM-only detectors never ran. Relaunch with
`flutter run --profile --no-dds`. A bad command line exits `64`: a
missing `--uri`, a URI that is not http, https, ws or wss, a non-numeric
`--min-fps`, a `--max-issues` or `--max-critical-issues` that is not a
non-negative integer, or an unknown option.

To inspect a live app from your own Dart tool, call the `ext.sleuth.*`
extensions directly with `package:vm_service`. You do not need the
sidecar for that.

## Known limitations

- The sidecar supports only Android and iOS. `attach_app` rejects a
  non-mobile `device`.
- One `flutter attach --machine` child per sidecar process.
- Clients on MCP protocol versions before `2025-06-18` get every tool
  result, including the `compare_snapshots` diff, only as JSON text in
  `content[0].text`.
- JSON-RPC batches work only for clients that negotiate MCP `2025-03-26`,
  the one version that defines them (`2025-06-18` removed them). On
  `2024-11-05` or `2025-06-18` a batch gets one Invalid Request error.
  Send each request on its own line.
- There is no `hot_restart` tool. In Android profile mode the new main
  isolate does not register again within the bridge's reconnect window
  after `app.restart`. Use `detach_app` and then `attach_app`.
  `hot_reload` works.
