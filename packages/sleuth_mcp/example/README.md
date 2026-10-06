# sleuth_mcp example

This example connects the sidecar to an MCP client so you can ask about
a running Flutter app's live performance data in conversation.

## 1. Install

```bash
dart pub global activate sleuth_mcp
sleuth_mcp install   # writes mcpServers.sleuth to ~/.claude.json
```

Reload your MCP client.

## 2. Attach to a running app

Start your app with `flutter run --profile --no-dds` (without `--no-dds`
Sleuth cannot reach the VM service), then ask the assistant:

> attach to my Flutter app and explore

The assistant calls `list_devices` and then `attach_app`, which spawns
`flutter attach --machine`, finds the VM service URI and connects.

On an iOS real device, one call attaches:

```
attach_app(udid: "<udid>", bundle: "com.example.example")
```

## 3. Query live data

> what's causing jank on the checkout route?

The assistant calls `get_issues`, `get_route_health` and `explain_issue`
against the live session. Each issue carries a fix hint.

The [package README](../README.md) covers the full tool list, the
`connect` and `attach_app` routing modes, the connection modes (`basic`,
`full` and `correlated`) and the `sleuth_check` CI gate.
