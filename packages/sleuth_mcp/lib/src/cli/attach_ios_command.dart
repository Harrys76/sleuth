import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';

/// Result of [runAttachIosCommand]. Pure data — caller (the bin entry)
/// is responsible for `exit`.
class AttachIosResult {
  AttachIosResult({required this.exitCode, this.wsUri, this.message});

  final int exitCode;
  final String? wsUri;
  final String? message;
}

/// One pairing announced by Bonjour. iOS publishes the Dart VM service
/// over both USB-bridged (`usbmuxd`) and WiFi paths; only the
/// USB-bridged `authCode` works through `iproxy`.
class BonjourAnnouncement {
  BonjourAnnouncement({
    required this.interfaceIndex,
    required this.host,
    required this.port,
    required this.authCode,
  });

  /// Numeric interface index reported by `dns-sd`. The exact value for
  /// USB varies per host + per reboot (commonly 25, but not contractual)
  /// — caller selects by other means (probe / override / order).
  final int interfaceIndex;

  /// Resolved hostname (e.g. `Pengen.local.`). Informational only —
  /// `iproxy` tunnels to `127.0.0.1` regardless.
  final String host;

  /// VM service port the on-device app is listening on.
  final int port;

  /// `authCode=...` value that follows the reached-at line. The trailing
  /// `=` is part of the WebSocket path (`/<authCode>=/ws`).
  final String authCode;
}

/// Injection seams. Default to real `Process.run` / `Process.start`;
/// tests override with hermetic stubs.
typedef ProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);
typedef ProcessSpawner = Future<Process> Function(
  String executable,
  List<String> arguments,
);

/// Tool presence check seam (`which <tool>` by default).
typedef ToolChecker = Future<bool> Function(String tool);

/// Stream-of-lines emitted by `dns-sd -L`. Real impl spawns the process
/// and pipes stdout; tests pass a `Stream.fromIterable([...])`.
typedef BonjourLineStream = Stream<String> Function(
  String bundleId,
  String service,
);

/// Optional probe — `true` ⇒ this announcement's authCode + port works
/// through the local iproxy tunnel. Real impl issues a 1-second HTTP
/// GET against `http://127.0.0.1:<port>/<authCode>=/` and accepts a 403
/// (auth gate) or 101 (upgrade). Tests pass a deterministic predicate.
typedef AnnouncementProbe = Future<bool> Function(BonjourAnnouncement);

/// Default real-process runner.
Future<ProcessResult> _defaultRun(String exe, List<String> args) =>
    Process.run(exe, args);

Future<Process> _defaultStart(String exe, List<String> args) =>
    Process.start(exe, args);

/// Spawn iproxy under `nohup` so SIGHUP is ignored at the child
/// level. The parent attach-ios process may die without running its
/// teardown — under launchers that run our main in a spawned isolate
/// (e.g. `dart pub global run`) the root-isolate's default signal
/// disposition pre-empts our listener. With SIGHUP ignored at the
/// iproxy level the child survives that scenario and a follow-up
/// `attach-ios` call reclaims it via the on-disk pidfile.
///
/// `detachedWithStdio` is intentionally NOT used — it disables
/// `Process.exitCode` (Dart throws `Bad state: Process is detached`)
/// AND, on macOS, does not put the child in its own session, so
/// SIGHUP would still propagate through the controlling-terminal
/// process group. The `nohup` wrapper is portable and orthogonal to
/// the Dart spawn mode.
Future<Process> _defaultIproxyStart(String exe, List<String> args) =>
    Process.start('nohup', [exe, ...args]);

Future<bool> _defaultHasTool(String name) async {
  final r = await _defaultRun('which', [name]);
  return r.exitCode == 0;
}

Stream<String> _defaultBonjourLines(String bundleId, String service) async* {
  // dns-sd block-buffers on a pipe — output never reaches us until the
  // process exits and flushes. Spawn it, set a kill timer that fires
  // before the collector's timeout, then drain stdout via `.join()` —
  // which completes only once the process exits + the buffer drains.
  // This is the same pattern `timeout 8 dns-sd | grep ...` uses in
  // shells, just hand-rolled because Dart's Process doesn't expose
  // POSIX timeout semantics directly.
  final proc = await _defaultStart('dns-sd', [
    '-L',
    bundleId,
    service,
    'local.',
  ]);
  // Kill BEFORE the collector's timeout — once dns-sd exits, its buffer
  // flushes and `join()` resolves with the full batch. The collector's
  // own timeout is the safety net for the case where the kill fails.
  final killTimer = Timer(const Duration(seconds: 7), () {
    proc.kill();
  });
  try {
    final output = await proc.stdout.transform(systemEncoding.decoder).join();
    for (final line in const LineSplitter().convert(output)) {
      yield line;
    }
  } finally {
    killTimer.cancel();
    proc.kill();
  }
}

/// Parse a single dns-sd reached-at line.
///
/// Shape: `... can be reached at <host>:<port> (interface <n>) Flags: ...`
({String host, int port, int interfaceIndex})? parseReachedAtLine(String line) {
  final m = RegExp(
    r'can be reached at\s+([^\s:]+):(\d+)\s+\(interface (\d+)\)',
  ).firstMatch(line);
  if (m == null) return null;
  final port = int.tryParse(m.group(2)!);
  final iface = int.tryParse(m.group(3)!);
  if (port == null || iface == null) return null;
  return (host: m.group(1)!, port: port, interfaceIndex: iface);
}

/// Parse a single dns-sd `authCode=...` line. Returns null if absent.
String? parseAuthCodeLine(String line) {
  final m = RegExp(r'authCode=([A-Za-z0-9_+/=-]+)').firstMatch(line);
  if (m == null) return null;
  // Strip trailing `=` chars (we re-add one in the wsUri).
  return m.group(1)!.replaceAll(RegExp(r'=+$'), '');
}

/// Collect Bonjour announcements using an adaptive two-phase budget.
///
/// Two timing knobs decouple "wait for app to come up" from "wait for
/// sibling pairings to roll in":
///
/// * [collectFor] — total budget. Caller waits up to this long for the
///   FIRST announcement. Tuned for cold-launch cases where the VM
///   service takes a few seconds to publish.
/// * [siblingWindow] — once the first announcement arrives, additional
///   announcements are collected for this short window before exit
///   (or until [maxAnnouncements] is hit). Sized for the typical
///   USB+WiFi pair on iOS 17.5 (~1s between siblings).
///
/// Effect: fast-launch cases exit ~siblingWindow after first sighting;
/// slow-launch cases get up to [collectFor] for the first sighting
/// without padding the post-sighting wait.
Future<List<BonjourAnnouncement>> collectBonjourAnnouncements({
  required Stream<String> lines,
  Duration collectFor = const Duration(seconds: 8),
  Duration siblingWindow = const Duration(milliseconds: 1500),
  int maxAnnouncements = 2,
}) async {
  final out = <BonjourAnnouncement>[];
  ({String host, int port, int interfaceIndex})? pending;
  final completer = Completer<void>();
  Timer? siblingTimer;
  late StreamSubscription<String> sub;
  sub = lines.listen(
    (line) {
      final reached = parseReachedAtLine(line);
      if (reached != null) {
        pending = reached;
        return;
      }
      final code = parseAuthCodeLine(line);
      if (code != null && pending != null) {
        out.add(BonjourAnnouncement(
          interfaceIndex: pending!.interfaceIndex,
          host: pending!.host,
          port: pending!.port,
          authCode: code,
        ));
        pending = null;
        if (out.length >= maxAnnouncements && !completer.isCompleted) {
          completer.complete();
          return;
        }
        // First announcement → arm the sibling-window timer.
        siblingTimer ??= Timer(siblingWindow, () {
          if (!completer.isCompleted) completer.complete();
        });
      }
    },
    onDone: () {
      if (!completer.isCompleted) completer.complete();
    },
    onError: (_) {
      if (!completer.isCompleted) completer.complete();
    },
  );
  await completer.future.timeout(collectFor, onTimeout: () {});
  siblingTimer?.cancel();
  await sub.cancel();
  return out;
}

/// Select the USB-bridged announcement from a collected batch.
///
/// Strategy in priority order:
/// 1. If [authOverride] is set, return the announcement matching that
///    authCode and carry the matched row's port + interface as a unit
///    (so a user-supplied USB auth never gets paired with a WiFi port).
/// 2. If [probe] is provided, return the first announcement whose probe
///    returns true (the only deterministic signal — WiFi authCode is
///    refused by the on-device WebSocket gate when reached through the
///    USB tunnel).
/// 3. Otherwise, prefer the announcement with the HIGHEST interface
///    index. This is a heuristic used by unit-level callers; the
///    production wiring in [runAttachIosCommand] refuses to fall through
///    to this branch when more than one distinct authCode is announced
///    — see the ambiguity-refusal block before the selector is called.
Future<BonjourAnnouncement?> selectUsbAnnouncement(
  List<BonjourAnnouncement> announcements, {
  String? authOverride,
  AnnouncementProbe? probe,
}) async {
  if (announcements.isEmpty) return null;
  if (authOverride != null && authOverride.isNotEmpty) {
    final stripped = authOverride.replaceAll(RegExp(r'=+$'), '');
    for (final a in announcements) {
      if (a.authCode == stripped) return a;
    }
    return null;
  }
  if (probe != null) {
    for (final a in announcements) {
      if (await probe(a)) return a;
    }
  }
  final sorted = [...announcements]
    ..sort((a, b) => b.interfaceIndex.compareTo(a.interfaceIndex));
  return sorted.first;
}

/// Deterministic pidfile path for the (udid, hostPort) tuple. Lives
/// in [directory] (production: `/tmp`; tests pass a temp dir).
///
/// The path is stable across invocations so a follow-up attach-ios for
/// the same UDID + host port can find and reclaim an orphan iproxy
/// left behind when a previous teardown was bypassed (e.g. when a
/// launcher's signal disposition pre-empted our root-isolate listener).
File pidfileForSession({
  required String directory,
  required String udid,
  required int hostPort,
}) {
  // Restrict udid to alphanumerics + dashes so the path stays inside
  // [directory] even on hostile input.
  final safeUdid = udid.replaceAll(RegExp(r'[^A-Za-z0-9-]'), '_');
  return File('$directory/sleuth_mcp_iproxy_${safeUdid}_$hostPort.pid');
}

/// Lets a [withPidfileLock] body publish a just-spawned child so the
/// lock can SIGKILL it on timeout. Dart Futures aren't cancellable, so
/// a `body().timeout(...)` abandons the body but leaves whatever it
/// spawned alive — registration plugs that leak.
class PidfileLockGuard {
  Process? _spawned;
  File? _pidfile;

  /// Call IMMEDIATELY after `Process.start`, before any other `await`,
  /// so a timeout firing between spawn and pidfile write still reaches
  /// the cleanup path.
  void registerSpawn(Process process, File pidfile) {
    _spawned = process;
    _pidfile = pidfile;
  }
}

/// Exclusive POSIX advisory lock on a sibling `.lock` file for the
/// duration of [body]. Serialises `reclaim → spawn iproxy → write
/// pidfile` across concurrent MCP clients targeting the same UDID +
/// host port — without the lock, two clients can both pass the stale-
/// pid check, both spawn iproxy, and race on the port bind.
///
/// On [TimeoutException], any [PidfileLockGuard]-registered child is
/// SIGKILLed and the pidfile removed before rethrow, so a mid-body
/// spawn doesn't leak as an unreapable orphan.
Future<T> withPidfileLock<T>(
  File pidfile,
  Future<T> Function(PidfileLockGuard guard) body, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final lockFile = File('${pidfile.path}.lock');
  RandomAccessFile? raf;
  var locked = false;
  final guard = PidfileLockGuard();
  try {
    raf = await lockFile.open(mode: FileMode.write);
    await raf.lock(FileLock.blockingExclusive);
    locked = true;
    // 15s wall-clock: past readiness window + Bonjour collect ceiling.
    // Tripping it signals the iproxy spawn pipeline is wedged.
    try {
      return await body(guard).timeout(timeout);
    } on TimeoutException {
      // Body abandoned. Kill any registered child so a spawn that
      // completed before the timeout doesn't leak as an orphan whose
      // pid never reached the pidfile.
      final spawned = guard._spawned;
      if (spawned != null) {
        try {
          spawned.kill(ProcessSignal.sigkill);
        } on Object {
          // ignore — best effort
        }
      }
      final pf = guard._pidfile;
      if (pf != null) {
        try {
          if (pf.existsSync()) pf.deleteSync();
        } on FileSystemException {
          // ignore — best effort
        }
      }
      rethrow;
    }
  } finally {
    if (raf != null) {
      if (locked) {
        try {
          await raf.unlock();
        } on FileSystemException {
          // ignore — best effort
        }
      }
      try {
        await raf.close();
      } on FileSystemException {
        // ignore
      }
    }
  }
}

/// If [pidfile] points at a process that is still alive AND whose argv
/// matches `iproxy <hostPort> <devicePort> --udid <udid>`, terminate it
/// (SIGTERM, fall back to SIGKILL after a short grace period) and
/// remove the file. Otherwise just remove the stale file.
///
/// argv matching guards against friendly-fire on an unrelated process
/// that happens to be reusing the pid recorded in the pidfile.
Future<void> reclaimStaleIproxy({
  required File pidfile,
  required int hostPort,
  required int devicePort,
  required String udid,
  required ProcessRunner run,
  required StringSink err,
}) async {
  if (!pidfile.existsSync()) return;
  final int? pid;
  try {
    pid = int.tryParse(pidfile.readAsStringSync().trim());
  } on FileSystemException {
    // Unreadable — best-effort cleanup, then move on.
    try {
      pidfile.deleteSync();
    } on FileSystemException {
      // ignore
    }
    return;
  }
  if (pid == null || pid <= 1) {
    try {
      pidfile.deleteSync();
    } on FileSystemException {
      // ignore
    }
    return;
  }

  // `kill -0 <pid>` returns 0 if the process exists AND we can signal
  // it; non-zero otherwise. Cheaper than parsing `ps` for liveness.
  final aliveCheck = await run('kill', ['-0', '$pid']);
  if (aliveCheck.exitCode != 0) {
    try {
      pidfile.deleteSync();
    } on FileSystemException {
      // ignore
    }
    return;
  }

  // Verify argv before killing. Friendly-fire on a recycled pid (e.g.
  // a long-running editor that grabbed the pid after a reboot) would
  // be a worse failure than leaving the pidfile in place.
  final psResult = await run('ps', ['-o', 'args=', '-p', '$pid']);
  final psOut = '${psResult.stdout}'.trim();
  final expected = 'iproxy $hostPort $devicePort --udid $udid';
  if (!psOut.contains(expected)) {
    err.writeln(
      'pidfile ${pidfile.path} points at pid $pid but argv does not '
      'match expected iproxy invocation; leaving the process alone',
    );
    try {
      pidfile.deleteSync();
    } on FileSystemException {
      // ignore
    }
    return;
  }

  err.writeln(
    'removed stale iproxy from prior session (pid $pid, port $hostPort)',
  );
  await run('kill', ['-TERM', '$pid']);
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final stillAlive = await run('kill', ['-0', '$pid']);
    if (stillAlive.exitCode != 0) break;
  }
  final finalAlive = await run('kill', ['-0', '$pid']);
  if (finalAlive.exitCode == 0) {
    await run('kill', ['-KILL', '$pid']);
  }
  try {
    pidfile.deleteSync();
  } on FileSystemException {
    // ignore — best-effort cleanup
  }
}

void _removePidfile(File pidfile) {
  try {
    if (pidfile.existsSync()) pidfile.deleteSync();
  } on FileSystemException {
    // ignore — best-effort cleanup
  }
}

/// Transport detected via `xcrun devicectl list devices --json-output -`.
///
/// `wired` → USB-tethered; iproxy required.
/// `wireless` → on-LAN via "Connect via network" (Xcode WiFi pairing);
///              iproxy NOT required — WebSocket connects directly to
///              the device's `.local` hostname.
/// `unknown` → device not in the list; fall back to USB-mode assumption.
enum IosTransport { wired, wireless, unknown }

/// Inspect `xcrun devicectl list devices` JSON and locate the entry for
/// [udid] (case-insensitive). Maps `transportType: "localNetwork"` to
/// [IosTransport.wireless]; everything else (e.g. `"wired"`) becomes
/// [IosTransport.wired]. Missing / unparseable output → [IosTransport.unknown].
Future<IosTransport> detectIosTransport({
  required String udid,
  required ProcessRunner run,
}) async {
  final ProcessResult result;
  try {
    result = await run(
        'xcrun', ['devicectl', 'list', 'devices', '--json-output', '-']);
  } catch (_) {
    return IosTransport.unknown;
  }
  if (result.exitCode != 0) return IosTransport.unknown;
  final stdout = '${result.stdout}';
  if (stdout.isEmpty) return IosTransport.unknown;
  final Object? decoded;
  try {
    decoded = jsonDecode(stdout);
  } on FormatException {
    return IosTransport.unknown;
  }
  if (decoded is! Map<String, Object?>) return IosTransport.unknown;
  final resultBlock = decoded['result'];
  if (resultBlock is! Map<String, Object?>) return IosTransport.unknown;
  final devices = resultBlock['devices'];
  if (devices is! List) return IosTransport.unknown;
  final targetUdid = udid.toUpperCase();
  for (final device in devices) {
    if (device is! Map<String, Object?>) continue;
    final hw = device['hardwareProperties'];
    if (hw is! Map<String, Object?>) continue;
    final deviceUdid = hw['udid'];
    if (deviceUdid is! String) continue;
    if (deviceUdid.toUpperCase() != targetUdid) continue;
    final conn = device['connectionProperties'];
    if (conn is! Map<String, Object?>) return IosTransport.unknown;
    final transport = conn['transportType'];
    if (transport is! String) return IosTransport.unknown;
    if (transport.toLowerCase() == 'localnetwork') return IosTransport.wireless;
    return IosTransport.wired;
  }
  return IosTransport.unknown;
}

/// Parse `attach-ios` argv.
class _ParsedArgs {
  _ParsedArgs({
    required this.udid,
    required this.bundle,
    required this.hostPort,
    required this.authOverride,
    required this.transportMode,
    required this.help,
  });
  final String? udid;
  final String bundle;
  final int? hostPort;
  final String? authOverride;

  /// User override: `null` = auto-detect, otherwise force the chosen mode.
  final IosTransport? transportMode;
  final bool help;
}

_ParsedArgs? _parseArgs(List<String> argv, StringSink err) {
  String? udid;
  String bundle = 'com.example.example';
  int? hostPort;
  String? authOverride;
  IosTransport? transportMode;
  bool help = false;

  for (var i = 0; i < argv.length; i++) {
    final a = argv[i];
    if (a == '--help' || a == '-h') {
      help = true;
      continue;
    }
    if (a == '--bundle') {
      if (i + 1 >= argv.length) {
        err.writeln('--bundle requires a value');
        return null;
      }
      bundle = argv[++i];
      continue;
    }
    if (a == '--port') {
      if (i + 1 >= argv.length) {
        err.writeln('--port requires a value');
        return null;
      }
      final p = int.tryParse(argv[++i]);
      if (p == null || p <= 0 || p > 65535) {
        err.writeln('--port must be an integer in 1..65535');
        return null;
      }
      hostPort = p;
      continue;
    }
    if (a == '--auth') {
      if (i + 1 >= argv.length) {
        err.writeln('--auth requires a value');
        return null;
      }
      authOverride = argv[++i];
      continue;
    }
    if (a == '--wireless') {
      transportMode = IosTransport.wireless;
      continue;
    }
    if (a == '--usb') {
      transportMode = IosTransport.wired;
      continue;
    }
    if (a.startsWith('-')) {
      err.writeln('unknown flag: $a');
      return null;
    }
    if (udid == null) {
      udid = a;
      continue;
    }
    err.writeln('unexpected positional argument: $a');
    return null;
  }
  return _ParsedArgs(
    udid: udid,
    bundle: bundle,
    hostPort: hostPort,
    authOverride: authOverride,
    transportMode: transportMode,
    help: help,
  );
}

String _usage() => '''
sleuth_mcp attach-ios <udid> [--bundle <bundle-id>] [--port <host-port>]
                             [--auth <code>] [--wireless | --usb]

  Launches the app on the device, resolves the on-device VM service via
  Bonjour, and (for USB-tethered devices) spawns `iproxy` to tunnel the
  device port to 127.0.0.1. Prints the WebSocket URI for `attach_app`.

  Transport is auto-detected via `xcrun devicectl list devices`. Wireless
  ("Connect via network" in Xcode) skips iproxy entirely and points the
  wsUri at the device's `.local` hostname.

  Requires `libimobiledevice` (brew install) for `iproxy` when USB.
  macOS-only (uses xcrun devicectl + dns-sd).

  Options:
    --bundle <id>     iOS bundle identifier (default: com.example.example)
    --port <n>        Host-side port for iproxy (USB only; default: same as device)
    --auth <code>     Pin the Bonjour authCode (required on USB when more
                      than one pairing is announced).
    --wireless        Force wireless mode (skip iproxy; wsUri uses .local host)
    --usb             Force USB mode (always spawn iproxy)

  Env overrides (for slow devices):
    SLEUTH_MCP_BONJOUR_COLLECT=<n>   First-announcement budget seconds (default 8)
    SLEUTH_MCP_LAUNCH_SETTLE=<n>     Post-launch settle seconds (default 1)
''';

/// Pure-function entry. The bin shim prints any [AttachIosResult.message]
/// and exits with [AttachIosResult.exitCode].
///
/// Exit codes:
///   0  — clean teardown (Ctrl-C after iproxy was running)
///  64  — usage error (missing UDID, unknown flag, bad value)
///  65  — missing required external tool
///  66  — `devicectl launch` failed (app not installed? wrong UDID?)
///  67  — Bonjour timeout / ambiguous pairings / `--auth` no-match
///  68  — iproxy failed to spawn / exited inside readiness window
///
/// Signal handling: SIGINT/SIGTERM/SIGHUP trigger orderly teardown of
/// the child `iproxy` process. SIGKILL is untrappable — if the parent
/// is force-killed (e.g. terminal `kill -9`), the OS reaps the parent
/// before this code runs and the child `iproxy` may be left orphaned
/// until the OS' own reaper picks it up. Best-effort teardown is the
/// contract for SIGKILL; everything else is deterministic.
Future<AttachIosResult> runAttachIosCommand({
  required List<String> args,
  StringSink? stdout_,
  StringSink? stderr_,
  ToolChecker hasTool = _defaultHasTool,
  ProcessRunner run = _defaultRun,
  ProcessSpawner start = _defaultStart,
  ProcessSpawner iproxyStart = _defaultIproxyStart,
  BonjourLineStream bonjourLines = _defaultBonjourLines,
  AnnouncementProbe? probe,
  Duration bonjourCollectFor = const Duration(seconds: 8),
  Duration bonjourTimeout = const Duration(seconds: 20),
  Duration readinessWindow = const Duration(milliseconds: 300),
  Duration launchSettle = const Duration(seconds: 1),
  @visibleForTesting String pidfileDirectory = '/tmp',
  @visibleForTesting bool waitForSignal = true,
  @visibleForTesting Map<String, String>? environment,
  Stream<ProcessSignal>? interruptStream,
}) async {
  final out = stdout_ ?? stdout;
  final err = stderr_ ?? stderr;

  // Env overrides — slow devices can widen the bonjour window or
  // settle delay without code changes. Invalid / negative inputs fall
  // back to the call-site defaults.
  final env = environment ?? Platform.environment;
  final envCollect = int.tryParse(env['SLEUTH_MCP_BONJOUR_COLLECT'] ?? '');
  final effectiveBonjourCollect = (envCollect != null && envCollect > 0)
      ? Duration(seconds: envCollect)
      : bonjourCollectFor;
  final envSettle = int.tryParse(env['SLEUTH_MCP_LAUNCH_SETTLE'] ?? '');
  final effectiveLaunchSettle = (envSettle != null && envSettle >= 0)
      ? Duration(seconds: envSettle)
      : launchSettle;

  final parsed = _parseArgs(args, err);
  if (parsed == null) {
    err.writeln('');
    err.writeln(_usage());
    return AttachIosResult(exitCode: 64);
  }
  if (parsed.help) {
    out.writeln(_usage());
    return AttachIosResult(exitCode: 0);
  }
  final udid = parsed.udid;
  if (udid == null || udid.isEmpty) {
    err.writeln('missing required <udid>');
    err.writeln('');
    err.writeln(_usage());
    return AttachIosResult(exitCode: 64);
  }

  // Detect transport (wired/wireless) so we can skip iproxy entirely on
  // wireless devices. `--wireless` / `--usb` user-flags override the
  // auto-detection. `unknown` (device not found in devicectl listing,
  // or non-zero exit) falls back to USB to keep the existing path.
  final IosTransport transport;
  if (parsed.transportMode != null) {
    transport = parsed.transportMode!;
  } else {
    final detected = await detectIosTransport(udid: udid, run: run);
    transport =
        detected == IosTransport.unknown ? IosTransport.wired : detected;
  }
  final isWireless = transport == IosTransport.wireless;

  // Doctor — check binaries up front so failures are actionable. iproxy
  // is skipped on wireless mode since no USB tunnel is spawned.
  final requiredTools = isWireless
      ? const ['xcrun', 'dns-sd']
      : const ['xcrun', 'dns-sd', 'iproxy'];
  for (final tool in requiredTools) {
    if (!await hasTool(tool)) {
      err.writeln('missing required tool: $tool');
      if (tool == 'iproxy') {
        err.writeln('install via: brew install libimobiledevice');
      } else if (tool == 'xcrun' || tool == 'dns-sd') {
        err.writeln('attach-ios is macOS-only (requires Xcode CLI tools)');
      }
      return AttachIosResult(exitCode: 65);
    }
  }

  // Probe Bonjour first for an already-running VM service. On iOS 17.5
  // a `xcrun devicectl process launch --terminate-existing` relaunch
  // produces a VM service whose WebSocket gate refuses upgrades. Trying
  // the existing instance first avoids the broken relaunch path when
  // the app is already running (common after `flutter run --profile`).
  out.writeln('Probing Bonjour for existing VM service...');
  const probeWindow = Duration(seconds: 3);
  final probeLines = bonjourLines(parsed.bundle, '_dartVmService._tcp');
  List<BonjourAnnouncement> announcements;
  try {
    announcements = await collectBonjourAnnouncements(
      lines: probeLines,
      collectFor: probeWindow,
      maxAnnouncements: 2,
    ).timeout(probeWindow + const Duration(seconds: 1));
  } on TimeoutException {
    announcements = const <BonjourAnnouncement>[];
  }

  if (announcements.isEmpty) {
    // No existing VM service — launch fresh. `--terminate-existing` is
    // intentionally omitted: it produces an unhealthy WS gate on
    // iOS 17.5. If the app is already running with no service
    // announcement (release build, stale state), launch will fail with
    // "already running"; user swipe-kills and retries.
    out.writeln('No existing service — launching ${parsed.bundle} on $udid...');
    final launch = await run('xcrun', [
      'devicectl',
      'device',
      'process',
      'launch',
      '--device',
      udid,
      parsed.bundle,
    ]);
    if (launch.exitCode != 0) {
      err.writeln('devicectl launch failed (exit ${launch.exitCode}):');
      err.writeln(launch.stderr);
      return AttachIosResult(exitCode: 66);
    }
    await Future<void>.delayed(effectiveLaunchSettle);

    out.writeln('Resolving VM service via Bonjour...');
    final lines = bonjourLines(parsed.bundle, '_dartVmService._tcp');
    try {
      announcements = await collectBonjourAnnouncements(
        lines: lines,
        collectFor: effectiveBonjourCollect,
      ).timeout(bonjourTimeout);
    } on TimeoutException {
      err.writeln(
        'timeout waiting for Bonjour announcement after '
        '${bonjourTimeout.inSeconds}s — is the app actually running '
        'with --enable-vm-service (profile/debug build)?',
      );
      return AttachIosResult(exitCode: 67);
    }
  } else {
    out.writeln('Using existing VM service (no relaunch).');
  }

  if (announcements.isEmpty) {
    err.writeln(
      'no Bonjour announcement seen — the app launched but did not '
      'register a VM service within ${bonjourCollectFor.inSeconds}s. '
      'Check that the build is profile or debug (release builds strip '
      'the service) and the app is actually running with '
      '--enable-vm-service.',
    );
    return AttachIosResult(exitCode: 67);
  }

  // Print every collected pairing BEFORE selection so the user can see
  // what was on offer and re-run with `--auth <code>` when more than
  // one pairing is on offer.
  out.writeln('Collected ${announcements.length} announcement(s):');
  for (final a in announcements) {
    out.writeln(
      '  iface ${a.interfaceIndex}: ${a.host}:${a.port} '
      'authCode=${a.authCode}',
    );
  }

  // Refuse to guess when more than one DISTINCT authCode is on offer
  // and no override / probe is wired. iOS publishes the same service
  // over WiFi + USB and the iproxy tunnel only accepts the USB token;
  // interface-index ordering is not contractual, so silently picking
  // the highest-iface row produces a syntactically valid wsUri that
  // the on-device WebSocket gate rejects. Caller must disambiguate.
  final distinctAuthCodes = announcements.map((a) => a.authCode).toSet();
  if (distinctAuthCodes.length > 1 &&
      parsed.authOverride == null &&
      probe == null) {
    err.writeln(
      'ambiguous Bonjour pairings: ${distinctAuthCodes.length} distinct '
      'authCodes were announced. The iproxy tunnel only accepts the '
      'USB-bridged token, and interface-index ordering is not '
      'contractual. Re-run with --auth <code> using one of: '
      '${distinctAuthCodes.join(", ")}',
    );
    return AttachIosResult(exitCode: 67);
  }

  final picked = await selectUsbAnnouncement(
    announcements,
    authOverride: parsed.authOverride,
    probe: probe,
  );
  if (picked == null) {
    if (parsed.authOverride != null) {
      err.writeln(
        'no announcement matched --auth ${parsed.authOverride}. '
        'Bonjour returned ${announcements.length} pairing(s); pick one '
        'of these authCodes and re-run with --auth <code>: '
        '${announcements.map((a) => a.authCode).join(", ")}',
      );
    } else {
      err.writeln('could not select a Bonjour announcement');
    }
    return AttachIosResult(exitCode: 67);
  }

  final devicePort = picked.port;
  final hostPort = parsed.hostPort ?? devicePort;
  out.writeln(
    'Device port: $devicePort (interface ${picked.interfaceIndex}), '
    'auth: ${picked.authCode}',
  );

  // Wireless path: skip iproxy entirely. The wsUri points at the
  // device's `.local` hostname (resolved by macOS mDNSResponder); the
  // WebSocket connects over WiFi directly to the on-device VM service,
  // no USB tunnel required.
  if (isWireless) {
    // Bonjour reports the hostname with a trailing dot (FQDN form);
    // strip it for the URL.
    final hostRaw = picked.host;
    final host = hostRaw.endsWith('.')
        ? hostRaw.substring(0, hostRaw.length - 1)
        : hostRaw;
    final wsUri = 'ws://$host:$devicePort/${picked.authCode}=/ws';
    out.writeln('');
    out.writeln('wsUri: $wsUri');
    out.writeln('');
    out.writeln(
      "Paste the wsUri above into your agent: attach_app(debugUrl: '$wsUri')",
    );
    out.writeln(
      'Wireless attach — no iproxy tunnel needed. The on-device VM '
      'service is reached directly over WiFi.',
    );
    return AttachIosResult(exitCode: 0, wsUri: wsUri);
  }

  // Stale-pid cleanup. If a previous attach-ios was killed before its
  // teardown could run (e.g. terminal closed under a launcher whose
  // signal disposition pre-empted our listener), the orphan iproxy is
  // still holding $hostPort. Reclaim it before we try to bind the same
  // port in this session. Reclaim → spawn → write runs under an
  // exclusive flock so concurrent attach-ios invocations don't race.
  final pidfile = pidfileForSession(
    directory: pidfileDirectory,
    udid: udid,
    hostPort: hostPort,
  );

  // Spawn iproxy detached. See [_defaultIproxyStart] for why detach
  // matters under launcher-isolate signal disposition.
  out.writeln('Spawning iproxy $hostPort -> device:$devicePort...');
  late Process iproxy;
  Object? spawnError;
  await withPidfileLock<void>(pidfile, (guard) async {
    await reclaimStaleIproxy(
      pidfile: pidfile,
      hostPort: hostPort,
      devicePort: devicePort,
      udid: udid,
      run: run,
      err: err,
    );
    try {
      iproxy = await iproxyStart('iproxy', [
        '$hostPort',
        '$devicePort',
        '--udid',
        udid,
      ]);
      guard.registerSpawn(iproxy, pidfile);
    } catch (e) {
      spawnError = e;
      return;
    }
    // Persist the pid to disk immediately so a follow-up invocation can
    // reclaim this process even if our teardown is bypassed.
    try {
      pidfile.writeAsStringSync('${iproxy.pid}\n', flush: true);
    } on FileSystemException catch (e) {
      err.writeln('warning: could not write pidfile ${pidfile.path}: $e');
    }
  });
  if (spawnError != null) {
    err.writeln('iproxy failed to spawn: $spawnError');
    return AttachIosResult(exitCode: 68);
  }

  // Buffer iproxy stderr so an early-exit (port collision, missing
  // tunnel target) can replay `Address already in use` to the user
  // instead of vanishing into /dev/null. Cap the buffer so a verbose
  // child can't grow it without bound.
  //
  // Process.exitCode is unavailable on detached processes (throws
  // `Bad state: Process is detached`), so liveness is tracked via the
  // stderr/stdout stream-close events: when iproxy exits the kernel
  // closes its stdio pipes, `onDone` fires, and [exitCompleter]
  // completes. This works for both detached and non-detached spawns,
  // which keeps the same code path in unit tests (using `sh -c ...`).
  final stderrBuf = BytesBuilder(copy: false);
  const stderrCap = 64 * 1024;
  var stderrTruncated = false;
  final exitCompleter = Completer<void>();
  void markIproxyExit() {
    if (!exitCompleter.isCompleted) exitCompleter.complete();
  }

  final stderrSub = iproxy.stderr.listen(
    (chunk) {
      final remaining = stderrCap - stderrBuf.length;
      if (chunk.length <= remaining) {
        stderrBuf.add(chunk);
      } else {
        if (remaining > 0) stderrBuf.add(chunk.sublist(0, remaining));
        stderrTruncated = true;
      }
    },
    onDone: markIproxyExit,
  );
  unawaited(iproxy.stdout.drain<void>().then((_) => markIproxyExit()));

  // Readiness window: if iproxy exits inside the window the tunnel
  // never came up — replay buffered stderr and exit 68 instead of
  // printing a wsUri that won't connect.
  final earlyExit = await Future.any<bool>([
    exitCompleter.future.then((_) => true),
    Future<bool>.delayed(readinessWindow, () => false),
  ]);
  if (earlyExit) {
    await stderrSub.cancel();
    _removePidfile(pidfile);
    err.writeln(
      'iproxy exited inside readiness window — '
      'tunnel never came up; wsUri not printed.',
    );
    final captured = utf8.decode(stderrBuf.takeBytes(), allowMalformed: true);
    if (captured.trim().isNotEmpty) {
      err.writeln('iproxy stderr:');
      err.writeln(captured.trimRight());
      if (stderrTruncated) {
        err.writeln('  (...stderr truncated at $stderrCap bytes)');
      }
    } else {
      err.writeln('  (no stderr output captured)');
    }
    return AttachIosResult(exitCode: 68);
  }

  final wsUri = 'ws://127.0.0.1:$hostPort/${picked.authCode}=/ws';
  out.writeln('');
  out.writeln('wsUri: $wsUri');
  out.writeln('');
  out.writeln(
    "Paste the wsUri above into your agent: attach_app(debugUrl: '$wsUri')",
  );
  out.writeln(
    'iproxy running (pid ${iproxy.pid}). Press Ctrl-C to tear down.',
  );

  if (!waitForSignal) {
    await stderrSub.cancel();
    // Pidfile intentionally left in place: the iproxy child outlives
    // this invocation under the test seam, and a follow-up call will
    // reclaim it via [reclaimStaleIproxy].
    return AttachIosResult(exitCode: 0, wsUri: wsUri);
  }

  // Wait for any interrupt signal (SIGINT/SIGTERM/SIGHUP) or iproxy
  // exiting on its own. Cleanup runs in `finally` so a thrown
  // exception or a signal during teardown still tears down the child.
  final sigCompleter = Completer<void>();
  final signalSubs = <StreamSubscription<ProcessSignal>>[];
  void onSignal(ProcessSignal _) {
    if (!sigCompleter.isCompleted) sigCompleter.complete();
  }

  if (interruptStream != null) {
    signalSubs.add(interruptStream.listen(onSignal));
  } else {
    signalSubs.add(ProcessSignal.sigint.watch().listen(onSignal));
    signalSubs.add(ProcessSignal.sigterm.watch().listen(onSignal));
    signalSubs.add(ProcessSignal.sighup.watch().listen(onSignal));
  }

  try {
    await Future.any<void>([sigCompleter.future, exitCompleter.future]);
  } finally {
    for (final s in signalSubs) {
      await s.cancel();
    }
    await stderrSub.cancel();
    out.writeln('Tearing down iproxy...');
    iproxy.kill();
    // Wait for stream-close (exit signal); cap at 3s, then SIGKILL
    // via the OS if still alive. `Process.exitCode` is unavailable on
    // detached processes, so poll via `kill -0` instead.
    await exitCompleter.future.timeout(
      const Duration(seconds: 3),
      onTimeout: () async {
        await run('kill', ['-KILL', '${iproxy.pid}']);
      },
    );
    _removePidfile(pidfile);
  }
  return AttachIosResult(exitCode: 0, wsUri: wsUri);
}
