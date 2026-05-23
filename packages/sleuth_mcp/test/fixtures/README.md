# Captured flutter daemon protocol fixtures

These NDJSON files are real output from `flutter attach --machine` /
`flutter run --machine`, captured against a running app. The daemon
parser tests replay them line-by-line.

## Refresh procedure

When Flutter SDK changes might alter the daemon protocol:

```bash
# 1. Record exact Flutter version
fvm flutter --version > .version.txt

# 2. Start the example app in another terminal
cd example && fvm flutter run --profile -d <device>

# 3. Capture an attach session to fixture
cd ../packages/sleuth_mcp
fvm flutter attach --machine -d <device> 2>/dev/null \
  | tee test/fixtures/daemon_attach_<flutter_version>_<platform>.ndjson

# 4. In the flutter run terminal: trigger hot reload (r), then hot
#    restart (R), wait for app.started, then press q.

# 5. Add a header comment to the captured file with version + platform.

# 6. Update _minDaemonProtocolVersion in daemon_parser.dart if the
#    daemon.connected event reports a newer version we want to require.
```

## Fixture file naming

`daemon_<command>_flutter_<sem.ver.>_<platform>.ndjson` —
e.g. `daemon_attach_flutter_3_41_4_ios.ndjson`.

## What the parser tests assert

- Every line either parses to a typed `DaemonEvent` / `DaemonRpcResponse`
  or is silently dropped (banner/diagnostic lines).
- `app.debugPort` extracts `wsUri` correctly.
- `app.started`, `app.stop`, `app.log`, `app.progress`,
  `daemon.connected`, `daemon.logMessage`, `daemon.showMessage` all map
  to typed classes.
- Unknown events surface as `UnknownDaemonEvent` (forward-compat).
