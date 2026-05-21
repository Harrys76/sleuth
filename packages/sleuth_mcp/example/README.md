# sleuth_mcp example

Wire the sidecar into an MCP client and query a running Flutter app's
live performance data in conversation.

## 1. Install

```bash
dart pub global activate sleuth_mcp
sleuth_mcp install   # writes mcpServers.sleuth to ~/.claude.json
```

Reload your MCP client.

## 2. Attach to a running app

Start your app in debug or profile mode (`flutter run`), then ask the
assistant:

> attach to my Flutter app and explore

The agent calls `list_devices` → `attach_app`, which spawns
`flutter attach --machine`, discovers the VM service URI, and connects.

iOS real device, one call:

```
attach_app(udid: "<udid>", bundle: "com.example.example")
```

## 3. Query live data

> what's causing jank on the checkout route?

The agent calls `get_issues` / `get_route_health` / `explain_issue`
against the live session. Each issue carries a fix hint.

See the [package README](../README.md) for the full tool list,
`connect`/`attach_app` routing modes, connection-mode (`basic` vs
`full`/`correlated`) notes, and the `sleuth_check` CI gate.
