# Captured flutter daemon protocol fixtures

These NDJSON files are real output from `flutter attach --machine` or
`flutter run --machine`, captured against a running app. The daemon
parser tests replay them line by line.

## Refresh procedure

Refresh the fixtures when a Flutter SDK change may alter the daemon
protocol:

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

# 6. Update minDaemonProtocolVersion in daemon_parser.dart if the
#    daemon.connected event reports a newer version we want to require.
```

## Fixture file naming

Name each fixture
`daemon_<command>_flutter_<major>_<minor>_<patch>_<platform>.ndjson`, for
example `daemon_attach_flutter_3_41_4_ios.ndjson`.

## What the parser tests assert

- Every line parses to a typed `DaemonEvent` or `DaemonRpcResponse`,
  except banner and diagnostic lines, which the parser drops without an
  error.
- The parser reads `wsUri` from `app.debugPort`.
- `app.started`, `app.stop`, `app.log`, `app.progress`,
  `daemon.connected`, `daemon.logMessage` and `daemon.showMessage` each
  map to a typed class.
- Unknown events become `UnknownDaemonEvent`, so a newer daemon does not
  break the parser.
