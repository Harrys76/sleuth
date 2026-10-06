# sleuth_mcp

`sleuth_mcp` lets an AI assistant read live performance data from a
running Flutter app. It is an MCP stdio server for Claude Code, Cursor,
Zed and other MCP clients. It talks to the app over the Dart VM service
and calls the `ext.sleuth.*` extensions that
[sleuth](https://pub.dev/packages/sleuth) registers, so the app must
depend on `sleuth` and wrap itself in `Sleuth.track`. The sidecar itself
does not depend on `sleuth`.

The sidecar is optional. The in-app overlay shows the same issues.

## Quickstart

```bash
dart pub global activate sleuth_mcp
sleuth_mcp install        # adds mcpServers.sleuth to ~/.claude.json
```

1. Reload your MCP client.
2. Run your app with `flutter run --profile --no-dds`. Without `--no-dds`
   Sleuth cannot reach the VM service, so its memory, CPU and repaint
   detectors stay off (see [Connection modes](#connection-modes)).
3. Ask the assistant to "attach to my Flutter app and explore". It calls
   `list_devices` and then `attach_app`, which runs
   `flutter attach --machine` and connects.
4. Ask a question such as "what's causing jank on the checkout route?".

You can run `install` again. It takes a lock, writes the config through
an atomic rename and keeps a `.bak` copy. For a project-local install, add
`sleuth_mcp: ^0.8.0` to `dev_dependencies` instead. The server also sends
this workflow to the client in the `instructions` field of its
`initialize` result.

## Options

Cursor, Zed and hand-written configs use the same `command`. To connect at
startup instead of through `attach_app`, pass the app's VM service URI:

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

| Option | Effect |
| --- | --- |
| `--uri <uri>` | Connects at startup. It takes the http URI that `flutter run` prints or the ws form. The server answers `initialize` at once, and tool calls wait up to 15 seconds for the connect. |
| `--tool-timeout <seconds>` | Time limit for each tool call, a whole number of 1 or more (default 10). Any other value exits with code 64. |
| `-v`, `--verbose` | Logs details to stderr. |
| `--version` | Prints the sidecar version and the sleuth version it was built against. |

When the client closes stdin, or the sidecar gets SIGINT or SIGTERM, it
detaches and exits within about 12 seconds. It stops any `flutter attach`
child or `iproxy` tunnel it started.

## Version compatibility

sleuth_mcp 0.8.0 is built against sleuth 0.37.0. When it connects, it
reads the app's `packageVersion` from `ext.sleuth.diagnose`. Another 0.37
version connects with `warning: version_skew_minor`, and a 0.36 app with
`warning: version_skew_prior_lineage`. The sidecar refuses any other
lineage (`version_skew_major`) and a version that is not
`major.minor.patch` (`version_skew_unknown`), and disconnects.

## Tools

| Tool | What it does |
| --- | --- |
| `list_devices` | Lists connected Android and iOS devices. `mobileOnly: false` adds desktop, web and embedded devices. |
| `attach_app` | Attaches to a running app by device, debug URL or iOS UDID. See [Attaching](#attaching). |
| `connect` | Connects to a VM service URI you already have. While an `attach_app` session is live it refuses with `attached_session`. |
| `detach_app` | Ends the session in any state and stops an attach in progress. You can call it when nothing is attached. |
| `app_status` | Reports whether a session is attached, which tool connected it, and its device, app and session ids. |
| `hot_reload` | Hot reloads an app attached with `attach_app(device:)` and keeps its state. Other sessions get `hot_reload_unsupported`. |
| `diagnose` | Reports the package version and the VM link (`vmConnected`), and on sleuth 0.37 the frame budget and VM poll timings. Call it first when other tools return nothing. |
| `get_issues` | Returns the current issues in rank order, optionally filtered by `route` or `severityAtLeast`. |
| `get_snapshot` | Returns the performance snapshot: issues, frame stats, route history, session summary and recurrence trends. |
| `get_route_health` | Returns the health score, FPS and issue counts for each route. |
| `explain_issue` | Returns the encyclopedia entry for a stableId, with the route, widget and counts of the live issue. |
| `compare_snapshots` | Diffs two snapshots: added, removed and more severe issues, count changes and the FPS change. It refuses snapshots from different sleuth lineages, from the warm-up, or with different VM coverage. |
| `check_budgets` | Checks the live session against FPS and issue-count budgets, with the same defaults as `sleuth_check`. It refuses with `coverage_degraded` when the app has no VM link. |
| `get_logs` | Returns the app's recent `print`, stderr and `dart:developer` lines. The sidecar keeps the last 500. |

[`doc/mcp_tool_schema.md`](doc/mcp_tool_schema.md) lists every argument,
return shape and error code.

### Reading results

- **Snapshot size.** On an iPhone 12 a full snapshot grew to 528 KB after
  a few minutes, mostly per-frame data, and Claude Code caps a tool result
  at 25,000 tokens by default. `get_snapshot` therefore leaves out the
  seven per-frame and raw-sample sections and lists them in
  `data._omittedSections`, which keeps it at about 3 to 15 KB. Pass
  `full: true` for everything, `sections` to pick sections, or
  `diskHandoff: true` to write the whole snapshot to a temp file and get
  its path.
- **Compact issues.** `get_issues` and `get_snapshot` return 12 fields per
  issue, including `stableId` and `severity`, and `verbose: true` returns
  all of them. `get_issues` returns the top 50 and adds `_truncated` and
  `_totalCount` when it drops any. `maxIssueCount` changes the cap, and
  `0` removes it.
- **Errors.** An error message starts with a code and says what to do next.
  `not_connected` means no app is attached. `timeout_after_<ms>ms` means
  the app did not answer in time; the connection stays, so retry.
  `app_busy` means 8 earlier calls are still unanswered; retry in a few
  seconds. `session_changed` means the app restarted; the sidecar follows
  the new session, so call the tool again.
- **Client features.** Read-only tools set `readOnlyHint`, so a client can
  run them without asking each time. A client on MCP `2025-06-18` also gets
  each result as `structuredContent`.

### Resources and prompts

The resources `sleuth://encyclopedia` (every issue explanation, keyed by
stableId) and `sleuth://causal-graph` (the rules that link causes to
effects) are cached per app session. The prompts `triage_performance`,
`audit_memory` and `release_check` tell the client's model which tools to
call in order, and end with ranked fixes, memory fixes, or a PASS, FAIL or
NOT RUN verdict.

## Attaching

`attach_app` has three modes:

- `device` runs `flutter attach --machine` and connects to the VM service
  it reports. It is the Quickstart path and the only mode where
  `hot_reload` works. `flutter attach` runs in the sidecar's working
  directory, so start your MCP client from the Flutter project.
- `debugUrl` connects to a ws URI you already have.
- `udid` with `bundle` attaches to an iOS device directly, on macOS only.
  Install the app once first (`flutter run --profile -d <udid>`, then
  quit). The sidecar finds the app's VM service over Bonjour, launches the
  app with `xcrun devicectl` if it is not running, and connects through an
  `iproxy` tunnel on USB (`brew install libimobiledevice`) or the device's
  `.local` host on Wi-Fi.

An attach reports each stage as progress when the client sends a
`progressToken`. A client cancel, `detach_app` or shutdown stops it along
with every process it started. When `flutter attach` exits early, for
example because two devices are connected and `device` is not set,
`attach_app` fails at once with flutter's last lines.

Without an MCP client, for example in a shell or CI, open the iOS tunnel
yourself and pass the printed URI to `attach_app(debugUrl:)` or
`sleuth_check`:

```bash
sleuth_mcp attach-ios <udid> --bundle com.example.example
# Prints wsUri: ws://127.0.0.1:<port>/<token>=/ws and keeps iproxy running until Ctrl-C.
```

If the WebSocket attach is refused (403 or closed), run it again with
`--auth <code>`. Bonjour can list the Wi-Fi pairing before the USB one,
and the USB tunnel refuses the Wi-Fi code.

[`doc/mcp_tool_schema.md`](doc/mcp_tool_schema.md#attach_app) covers the
transport choice, pairing codes and recovery from a stale Bonjour record.

## Connection modes

Every `ext.sleuth.*` response carries `connectionMode`, and `diagnose`
returns it:

- `warmup`: the first seconds after Sleuth starts.
- `basic`: no frame has a VM-tier verdict yet.
- `full`: a jank frame got a verdict from VM timeline data.
- `correlated`: as `full`, with the timeline events matched to the frame.
- `disconnected`: Sleuth is not initialized, or it was disposed.

`basic` does not mean the VM link is down. A connected session on a smooth
screen stays `basic` until a frame janks, so check `vmConnected` (in
`diagnose`, `connect` and `get_issues`). Without a VM link Sleuth never
reports `heap_growing`, `gc_pressure`, `heap_near_capacity`,
`native_memory_growing`, `heavy_compute`, `shader_compilation`,
`platform_channel_traffic`, `stream_resource_growth`, `rebuild_activity`
or `excessive_repaint`. In that case, and during warm-up or after a
disconnect, `connect`, `attach_app`, `diagnose`, `get_snapshot` and
`get_issues` add a `launchModeAdvisory` that says what is missing and what
to do.

`flutter run` starts DDS (Dart Development Service) by default. DDS becomes
the only client of the app's VM service, so Sleuth cannot connect. Run
with `--no-dds` and Sleuth polls the VM every 500 ms on the app isolate.
On an iPhone 12 a poll costs about 1.5 ms on an idle screen and about
32 ms on a screen that writes 10k timeline events per poll. Emulators and
simulators can lose FPS to polling, so measure on a real device. To keep
DDS and DevTools as well, launch the installed app yourself and call
`attach_app(debugUrl:)`.
[Sleuth internals](https://github.com/Harrys76/sleuth/blob/main/doc/internals.md#vm-connection)
has the Android and iOS simulator commands.

## CI gate with `sleuth_check`

The stdio server cannot fail a CI job through its exit code, so CI uses
the one-shot `sleuth_check` binary:

```bash
sleuth_check --uri "http://127.0.0.1:55555/<token>=/" \
  --min-fps 55 --max-issues 10 --max-critical-issues 0 --json
```

It exits `0` on a pass and `1` on a budget violation. It exits `2` when
the check could not run: a connect failure, a version refusal, a malformed
snapshot, or `coverage_degraded` because Sleuth had no VM link. A bad
command line exits `64`. Without flags the budgets are `--min-fps 55`,
`--max-critical-issues 0` and no limit on the total issue count.

To read the app from your own Dart tool instead, call the `ext.sleuth.*`
extensions with `package:vm_service`. They are described in
[`doc/mcp_schema.md`](doc/mcp_schema.md).

## Limitations

- Android and iOS apps only. `list_devices` hides other devices unless you
  pass `mobileOnly: false`, and `attach_app` rejects them.
- One `flutter attach` child per sidecar. Each MCP client starts its own
  sidecar.
- There is no `hot_restart` tool. In Android profile builds the restarted
  isolate does not register again in time, so use `detach_app` and then
  `attach_app`. The sidecar does follow a hot restart started from
  `flutter run`.
- JSON-RPC batches work only for clients on MCP `2025-03-26`, the one
  version that defines them.
- The flutter daemon must speak protocol `0.6.0` or later.
