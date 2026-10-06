import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../util/owned_process.dart'
    show CommandCancelledException, CommandTimeoutException, OwnedProcessRunner;
import 'attach_ios_command.dart'
    show
        AnnouncementProbe,
        BonjourAnnouncement,
        BonjourLineStream,
        IosTransport,
        ProcessRunner,
        ProcessSpawner,
        ToolChecker,
        collectBonjourAnnouncements,
        detectIosTransport,
        ownedBonjourLines,
        pidfileForSession,
        reclaimStaleIproxy,
        selectUsbAnnouncement,
        withPidfileLock;

/// Categorised failure reasons that the iOS attach pipeline can raise.
/// Callers map these to either CLI exit codes (`runAttachIosCommand`)
/// or typed MCP error envelopes (`tools.dart attachHandler`).
enum IosAttachErrorKind {
  /// Required external tool (`xcrun`, `dns-sd`, `iproxy`) not on PATH.
  missingTool,

  /// `xcrun devicectl launch` returned non-zero exit.
  launchFailed,

  /// No Bonjour announcement seen within budget.
  bonjourTimeout,

  /// More than one DISTINCT authCode announced and caller did not pin
  /// one via `authOverride`. Refusing to guess (interface ordering is
  /// not contractual).
  ambiguousPairings,

  /// `authOverride` supplied but no announcement matched.
  noMatchingAuth,

  /// `Process.start('iproxy', ...)` raised.
  iproxyFailedSpawn,

  /// iproxy exited inside the readiness window.
  iproxyReadinessFailed,

  /// Cancellation signal fired mid-pipeline.
  cancelled,
}

/// Thrown by [IosAttacher.attach] when the pipeline can't produce a
/// usable wsUri. The [kind] drives caller-side mapping (CLI exit code
/// vs MCP error envelope).
class IosAttachException implements Exception {
  IosAttachException(this.kind, this.message, {this.data});

  final IosAttachErrorKind kind;
  final String message;

  /// Optional structured payload — e.g. `{distinctAuthCodes: [...]}`
  /// for `ambiguousPairings` so the caller can render a remedy.
  final Map<String, Object?>? data;

  @override
  String toString() => 'IosAttachException(${kind.name}): $message';
}

/// How the wsUri was obtained. `probedExisting` = Bonjour probe found
/// an already-running VM service. `launchedFresh` = pipeline ran
/// `xcrun devicectl process launch`. `DaemonSession.attachViaIos`
/// auto-retries a `Connection refused` after `probedExisting` (stale
/// Bonjour) with `forceRelaunch: true`; the same failure after
/// `launchedFresh` is genuine.
enum IosAttachOrigin { probedExisting, launchedFresh }

/// Successful pipeline output. The caller owns the [teardown] callback
/// — invoking it kills any spawned iproxy child and removes the
/// pidfile. Wireless mode returns a no-op teardown (nothing to clean
/// up host-side).
class IosAttachResult {
  IosAttachResult({
    required this.wsUri,
    required this.transport,
    required this.announcements,
    required this.selected,
    required this.hostPort,
    required this.teardown,
    required this.origin,
    this.iproxyProcess,
    this.pidfile,
  });

  /// WebSocket URI consumable by `bridge.connect(Uri.parse(wsUri))`.
  /// Wireless: `ws://<host>.local:<devicePort>/<auth>=/ws`.
  /// USB     : `ws://127.0.0.1:<hostPort>/<auth>=/ws`.
  final String wsUri;
  final IosTransport transport;
  final List<BonjourAnnouncement> announcements;
  final BonjourAnnouncement selected;

  /// Equal to `selected.port` on wireless; equal to caller's --port
  /// override (or `selected.port`) on USB.
  final int hostPort;

  /// Tears down side effects: kills iproxy (USB) and removes pidfile.
  /// Wireless: no-op. Safe to call multiple times.
  final Future<void> Function() teardown;

  /// USB only — the spawned iproxy Process. Exposed so the CLI wrapper
  /// can wait on its exit / signal-watch. MCP path does not use this.
  final Process? iproxyProcess;
  final File? pidfile;

  /// Probe-vs-launch provenance — see [IosAttachOrigin]. Used by the
  /// daemon-side stale-Bonjour auto-retry.
  final IosAttachOrigin origin;
}

/// Phase markers emitted via the optional `onProgress` callback. CLI
/// renders these to stdout; MCP path may forward them to log
/// notifications.
enum IosAttachPhase {
  detectingTransport,
  launchingApp,
  resolvingBonjour,
  announcementsCollected,
  selectingAnnouncement,
  reclaimingStalePidfile,
  spawningIproxy,
  iproxyReady,
  attachComplete,
}

typedef IosAttachProgress =
    void Function(IosAttachPhase phase, {Map<String, Object?>? data});

/// Pipeline that drives an iOS profile-mode attach end-to-end and
/// returns the WebSocket URI plus a teardown closure. Both the
/// standalone CLI (`runAttachIosCommand`) and the MCP `attach_app`
/// tool delegate to this class — the logic must remain transport- and
/// UI-agnostic.
///
/// Caller responsibilities:
/// * Argv parsing (CLI) or MCP arg validation (server) — `attach`
///   only accepts already-parsed values.
/// * Signal handling. The pipeline supports a [cancelSignal] stream
///   for graceful abort, but does NOT install OS signal handlers; the
///   caller registers `ProcessSignal.sigint.watch()` (CLI) or wires a
///   `CancelToken` (MCP) and forwards into the stream.
/// * Stdout / log rendering. Pipeline emits structured progress via
///   [IosAttachProgress]; caller decides whether to print human text,
///   emit MCP `notifications/log`, etc.
///
/// Every external command of an attach is owned: a step that outlives its
/// timeout, or that is running when [attach]'s cancel signal fires, kills
/// its child and waits, bounded, for it to exit, and a cancel interrupts
/// every wait of the pipeline.
///
/// Test seams (mirror of `runAttachIosCommand`):
/// * [hasTool] defaults to `which <tool>`, run as an owned child. Tests
///   stub it.
/// * [run] defaults to an owned runner built on [start]. An injected
///   runner owns no child, so a timeout or a cancel only stops waiting for
///   it. Tests stub it.
/// * [start] starts the default runner's children (`xcrun`, `which`,
///   `kill`, `ps`) and dns-sd. It defaults to `Process.start`. Tests pass
///   fake processes.
/// * [iproxyStart] defaults to `nohup iproxy ...`. Tests stub it with
///   `sh -c "sleep ..."`.
/// * [bonjourLines] defaults to [ownedBonjourLines] on [start]. Tests
///   pass `Stream.fromIterable([...])`.
/// * [probe] is an optional active HTTP probe for selecting the right
///   announcement when multiple pairings announce.
class IosAttacher {
  IosAttacher({
    this.hasTool,
    this.run,
    this.start,
    this.iproxyStart = _defaultIproxyStart,
    this.bonjourLines,
    this.probe,
  });

  /// Null means `which <tool>` on macOS, and false elsewhere.
  final ToolChecker? hasTool;

  /// Null means an [OwnedProcessRunner] on [start] for each attach.
  final ProcessRunner? run;

  /// Null means `Process.start`.
  final ProcessSpawner? start;
  final ProcessSpawner iproxyStart;

  /// Null means [ownedBonjourLines] on [start].
  final BonjourLineStream? bonjourLines;
  final AnnouncementProbe? probe;

  /// Upper bound for `which`, `kill` and `ps`.
  static const Duration _shortCommandTimeout = Duration(seconds: 5);

  /// Drive the full pipeline. On success returns [IosAttachResult]
  /// containing the wsUri and a teardown callback. On failure throws
  /// [IosAttachException] with a categorised [IosAttachErrorKind].
  Future<IosAttachResult> attach({
    required String udid,
    required String bundle,
    String? authOverride,
    int? hostPortOverride,
    IosTransport? transportOverride,
    Duration bonjourCollectFor = const Duration(seconds: 8),
    Duration bonjourTimeout = const Duration(seconds: 20),
    Duration launchSettle = const Duration(seconds: 1),
    Duration readinessWindow = const Duration(milliseconds: 300),
    String pidfileDirectory = '/tmp',
    IosAttachProgress? onProgress,
    Stream<void>? cancelSignal,
    Map<String, String>? environment,
    bool forceRelaunch = false,
    Set<int> excludePorts = const <int>{},
    Duration devicectlTimeout = const Duration(seconds: 20),
  }) async {
    final env = environment ?? Platform.environment;
    final envCollect = int.tryParse(env['SLEUTH_MCP_BONJOUR_COLLECT'] ?? '');
    final effectiveBonjourCollect = (envCollect != null && envCollect > 0)
        ? Duration(seconds: envCollect)
        : bonjourCollectFor;
    final envSettle = int.tryParse(env['SLEUTH_MCP_LAUNCH_SETTLE'] ?? '');
    final effectiveLaunchSettle = (envSettle != null && envSettle >= 0)
        ? Duration(seconds: envSettle)
        : launchSettle;

    final cancelled = Completer<void>();
    final cancelSub = cancelSignal?.listen((_) {
      if (!cancelled.isCompleted) cancelled.complete();
    });
    void throwIfCancelled() {
      if (cancelled.isCompleted) throw _cancelledError();
    }

    // Children this attach starts through the default runner. A step that
    // times out or is cancelled kills its child before it throws.
    final owned = OwnedProcessRunner(start: start);
    final injectedRun = run;
    Future<ProcessResult> command(
      String executable,
      List<String> arguments,
      Duration timeout,
    ) {
      if (cancelled.isCompleted) {
        return Future.error(CommandCancelledException(executable));
      }
      if (injectedRun == null) {
        return owned.run(
          executable,
          arguments,
          timeout: timeout,
          cancel: cancelled.future,
        );
      }
      return _interruptible(
        injectedRun(executable, arguments),
        executable,
        timeout: timeout,
        cancel: cancelled.future,
      );
    }

    final checkTool =
        hasTool ?? (String tool) => _toolOnPath(owned, tool, cancelled.future);
    final linesFor =
        bonjourLines ??
        (String bundleId, String service) =>
            ownedBonjourLines(bundleId, service, start: start);

    try {
      // (1) Resolve transport.
      onProgress?.call(IosAttachPhase.detectingTransport);
      final IosTransport transport;
      if (transportOverride != null) {
        transport = transportOverride;
      } else {
        // detectIosTransport maps every runner failure to unknown, so note
        // a timeout here and report it after the call.
        var listTimedOut = false;
        final detected = await detectIosTransport(
          udid: udid,
          run: (executable, arguments) async {
            try {
              return await command(executable, arguments, devicectlTimeout);
            } on CommandTimeoutException {
              listTimedOut = true;
              rethrow;
            }
          },
        );
        throwIfCancelled();
        if (listTimedOut) {
          throw IosAttachException(
            IosAttachErrorKind.launchFailed,
            'devicectl list devices timed out after '
            '${devicectlTimeout.inSeconds}s — the device may have '
            'disconnected or device services stalled.',
          );
        }
        transport = detected == IosTransport.unknown
            ? IosTransport.wired
            : detected;
      }
      throwIfCancelled();
      final isWireless = transport == IosTransport.wireless;

      // (2) Doctor checks. iproxy skipped on wireless.
      final requiredTools = isWireless
          ? const ['xcrun', 'dns-sd']
          : const ['xcrun', 'dns-sd', 'iproxy'];
      for (final tool in requiredTools) {
        throwIfCancelled();
        final present = await _interruptible(
          checkTool(tool),
          'which',
          cancel: cancelled.future,
          afterCancel: _reapAfterCancel,
        );
        if (!present) {
          throw IosAttachException(
            IosAttachErrorKind.missingTool,
            'missing required tool: $tool',
            data: <String, Object?>{
              'tool': tool,
              if (tool == 'iproxy')
                'remedy': 'install via: brew install libimobiledevice'
              else if (tool == 'xcrun' || tool == 'dns-sd')
                'remedy': 'attach-ios is macOS-only (requires Xcode CLI tools)',
            },
          );
        }
      }
      throwIfCancelled();

      // (3) Probe Bonjour first for an already-running VM service. On
      // iOS 17.5, `devicectl process launch --terminate-existing`
      // produces a WS gate that refuses upgrades; launching without
      // `--terminate-existing` (or skipping launch entirely when the
      // app is already running) sidesteps the broken path.
      //
      // [forceRelaunch] skips the probe — used by the daemon-side
      // auto-retry when the probe returned a stale wsUri.
      onProgress?.call(IosAttachPhase.resolvingBonjour);
      const probeWindow = Duration(seconds: 3);
      List<BonjourAnnouncement> announcements;
      var origin = IosAttachOrigin.probedExisting;
      if (forceRelaunch) {
        announcements = const <BonjourAnnouncement>[];
      } else {
        final probeLines = linesFor(bundle, '_dartVmService._tcp');
        try {
          announcements = await _interruptible(
            collectBonjourAnnouncements(
              lines: probeLines,
              collectFor: probeWindow,
              maxAnnouncements: 2,
              stop: cancelled.future,
            ),
            'dns-sd',
            timeout: probeWindow + const Duration(seconds: 1),
            cancel: cancelled.future,
            afterCancel: _reapAfterCancel,
          );
        } on CommandTimeoutException {
          announcements = const <BonjourAnnouncement>[];
        }
      }
      // Drop excluded (dead) ports before the launch-skip check, so an
      // empty result after exclusion triggers a fresh launch.
      if (excludePorts.isNotEmpty) {
        announcements = announcements
            .where((a) => !excludePorts.contains(a.port))
            .toList();
      }
      throwIfCancelled();

      if (announcements.isEmpty) {
        origin = IosAttachOrigin.launchedFresh;
        // (3b) No existing VM service — launch fresh. `--terminate-existing`
        // is intentionally NOT passed: it produces an unhealthy WS gate
        // on iOS 17.5. If the app is already running with no service
        // announcement (e.g. release build or stale state), launch will
        // fail with "already running"; user must swipe-kill and retry.
        onProgress?.call(
          IosAttachPhase.launchingApp,
          data: <String, Object?>{'bundle': bundle, 'udid': udid},
        );
        final ProcessResult launch;
        try {
          launch = await command('xcrun', [
            'devicectl',
            'device',
            'process',
            'launch',
            '--device',
            udid,
            bundle,
          ], devicectlTimeout);
        } on CommandTimeoutException {
          throw IosAttachException(
            IosAttachErrorKind.launchFailed,
            'devicectl process launch timed out after '
            '${devicectlTimeout.inSeconds}s — the device may have '
            'disconnected or device services stalled.',
          );
        }
        throwIfCancelled();
        if (launch.exitCode != 0) {
          throw IosAttachException(
            IosAttachErrorKind.launchFailed,
            'devicectl launch failed (exit ${launch.exitCode}): '
            '${launch.stderr}',
            data: <String, Object?>{
              'exitCode': launch.exitCode,
              'stderr': '${launch.stderr}',
            },
          );
        }
        await _interruptible(
          Future<void>.delayed(effectiveLaunchSettle),
          'launch settle',
          cancel: cancelled.future,
        );
        throwIfCancelled();

        // (4) Resolve via Bonjour now that the fresh service has booted.
        final lines = linesFor(bundle, '_dartVmService._tcp');
        try {
          announcements = await _interruptible(
            collectBonjourAnnouncements(
              lines: lines,
              collectFor: effectiveBonjourCollect,
              stop: cancelled.future,
            ),
            'dns-sd',
            timeout: bonjourTimeout,
            cancel: cancelled.future,
            afterCancel: _reapAfterCancel,
          );
        } on CommandTimeoutException {
          throw IosAttachException(
            IosAttachErrorKind.bonjourTimeout,
            'timeout waiting for Bonjour announcement after '
            '${bonjourTimeout.inSeconds}s — is the app actually running '
            'with --enable-vm-service (profile/debug build)?',
          );
        }
        if (excludePorts.isNotEmpty) {
          announcements = announcements
              .where((a) => !excludePorts.contains(a.port))
              .toList();
        }
        throwIfCancelled();
      }
      if (announcements.isEmpty) {
        throw IosAttachException(
          IosAttachErrorKind.bonjourTimeout,
          'no Bonjour announcement seen — the app launched but did not '
          'register a VM service within '
          '${effectiveBonjourCollect.inSeconds}s. Check that the build '
          'is profile or debug (release strips the service) and the '
          'app is actually running with --enable-vm-service.',
        );
      }
      onProgress?.call(
        IosAttachPhase.announcementsCollected,
        data: <String, Object?>{
          'announcements': announcements
              .map(
                (a) => <String, Object?>{
                  'interfaceIndex': a.interfaceIndex,
                  'host': a.host,
                  'port': a.port,
                  'authCode': a.authCode,
                },
              )
              .toList(),
        },
      );

      // (5) Refuse to guess when more than one DISTINCT authCode is on
      // offer and the caller hasn't pinned one. iOS publishes the same
      // service over WiFi + USB; iproxy only accepts the USB token,
      // and interface ordering is not contractual.
      // Sorted so the daemon-side candidate iteration (and tests) see a
      // stable order — `Set.toList()` order is otherwise undefined.
      final distinctAuthCodes = announcements.map((a) => a.authCode).toSet();
      final sortedAuthCodes = distinctAuthCodes.toList()..sort();
      if (distinctAuthCodes.length > 1 &&
          authOverride == null &&
          probe == null) {
        throw IosAttachException(
          IosAttachErrorKind.ambiguousPairings,
          'ambiguous Bonjour pairings: ${distinctAuthCodes.length} '
          'distinct authCodes were announced. The iproxy tunnel only '
          'accepts the USB-bridged token. Re-run with --auth <code> '
          'using one of: ${sortedAuthCodes.join(", ")}',
          data: <String, Object?>{'distinctAuthCodes': sortedAuthCodes},
        );
      }

      onProgress?.call(IosAttachPhase.selectingAnnouncement);
      final picked = await selectUsbAnnouncement(
        announcements,
        authOverride: authOverride,
        probe: probe,
      );
      if (picked == null) {
        if (authOverride != null) {
          throw IosAttachException(
            IosAttachErrorKind.noMatchingAuth,
            'no announcement matched --auth $authOverride. '
            'Bonjour returned ${announcements.length} pairing(s); pick '
            'one of these authCodes: '
            '${announcements.map((a) => a.authCode).join(", ")}',
            data: <String, Object?>{
              'authCodes': announcements.map((a) => a.authCode).toList(),
            },
          );
        }
        throw IosAttachException(
          IosAttachErrorKind.bonjourTimeout,
          'could not select a Bonjour announcement',
        );
      }
      throwIfCancelled();

      final devicePort = picked.port;
      final hostPort = hostPortOverride ?? devicePort;

      // (6a) Wireless path — no iproxy, no pidfile, no teardown.
      if (isWireless) {
        final hostRaw = picked.host;
        final host = hostRaw.endsWith('.')
            ? hostRaw.substring(0, hostRaw.length - 1)
            : hostRaw;
        final wsUri = 'ws://$host:$devicePort/${picked.authCode}=/ws';
        onProgress?.call(IosAttachPhase.attachComplete);
        return IosAttachResult(
          wsUri: wsUri,
          transport: transport,
          announcements: announcements,
          selected: picked,
          hostPort: devicePort,
          teardown: () async {},
          origin: origin,
        );
      }

      // (6b) USB path — reclaim stale pidfile, spawn iproxy under
      // nohup, persist pid, run readiness window. The reclaim → spawn
      // → write sequence runs under an exclusive flock on a sibling
      // `.lock` file so two MCP clients targeting the same UDID can't
      // race past each other's stale-pid check.
      final pidfile = pidfileForSession(
        directory: pidfileDirectory,
        udid: udid,
        hostPort: hostPort,
      );
      onProgress?.call(IosAttachPhase.reclaimingStalePidfile);
      // `late iproxy` is assigned inside the lock body; the only path
      // that skips the assignment is the `IosAttachException` throw on
      // spawn failure, which propagates out of `withPidfileLock` before
      // any outer reference to `iproxy`. Static analysis can't prove
      // this — the contract is "spawn-failure path never reads iproxy".
      late Process iproxy;
      try {
        await withPidfileLock<void>(pidfile, (guard) async {
          await reclaimStaleIproxy(
            pidfile: pidfile,
            hostPort: hostPort,
            devicePort: devicePort,
            udid: udid,
            run: (executable, arguments) =>
                command(executable, arguments, _shortCommandTimeout),
            err: _NullStringSink(),
          );
          throwIfCancelled();

          onProgress?.call(
            IosAttachPhase.spawningIproxy,
            data: <String, Object?>{
              'hostPort': hostPort,
              'devicePort': devicePort,
            },
          );
          try {
            iproxy = await iproxyStart('iproxy', [
              '$hostPort',
              '$devicePort',
              '--udid',
              udid,
            ]);
            // Register before any other await so a lock timeout between
            // spawn and pidfile write doesn't leave an unreapable orphan.
            guard.registerSpawn(iproxy, pidfile);
          } catch (e) {
            throw IosAttachException(
              IosAttachErrorKind.iproxyFailedSpawn,
              'iproxy failed to spawn: $e',
            );
          }

          try {
            pidfile.writeAsStringSync('${iproxy.pid}\n', flush: true);
          } on FileSystemException {
            // Pidfile write failure is non-fatal — sidecar still owns
            // the child process. Orphan reclamation degrades to "no-op"
            // on next run but the present attach can proceed.
          }
        });
      } on TimeoutException catch (e) {
        // Either another process held the pidfile lock, or the reclaim and
        // spawn inside it stalled. The lock already killed any iproxy it
        // started.
        throw IosAttachException(
          IosAttachErrorKind.iproxyFailedSpawn,
          'iproxy setup did not finish: ${e.message ?? 'pidfile lock timed out'}',
        );
      }

      // Stderr buffer + stdout drain. Stream-close detection covers
      // both detached (no exitCode access) and non-detached spawns.
      final stderrBuf = BytesBuilder(copy: false);
      const stderrCap = 64 * 1024;
      var stderrTruncated = false;
      final exitCompleter = Completer<void>();
      void markIproxyExit() {
        if (!exitCompleter.isCompleted) exitCompleter.complete();
      }

      final stderrSub = iproxy.stderr.listen((chunk) {
        final remaining = stderrCap - stderrBuf.length;
        if (chunk.length <= remaining) {
          stderrBuf.add(chunk);
        } else {
          if (remaining > 0) stderrBuf.add(chunk.sublist(0, remaining));
          stderrTruncated = true;
        }
      }, onDone: markIproxyExit);
      unawaited(iproxy.stdout.drain<void>().then((_) => markIproxyExit()));

      // Stops iproxy and removes its pidfile. exitCode is unavailable on
      // detached spawns, so the exit shows as stream-close (wired via
      // `markIproxyExit`). The grace stays below the session's 3s teardown
      // budget.
      Future<void> stopIproxy() async {
        await stderrSub.cancel();
        iproxy.kill();
        await exitCompleter.future.timeout(
          const Duration(seconds: 2),
          onTimeout: () => iproxy.kill(ProcessSignal.sigkill),
        );
        try {
          if (pidfile.existsSync()) pidfile.deleteSync();
        } on FileSystemException {
          // Best effort: a pidfile that cannot be removed stays.
        }
      }

      final earlyExit = await Future.any<bool>([
        exitCompleter.future.then((_) => true),
        cancelled.future.then((_) => false),
        Future<bool>.delayed(readinessWindow, () => false),
      ]);
      if (cancelled.isCompleted) {
        await stopIproxy();
        throw _cancelledError();
      }
      if (earlyExit) {
        await stderrSub.cancel();
        try {
          if (pidfile.existsSync()) pidfile.deleteSync();
        } on FileSystemException {
          // ignore
        }
        final captured = utf8.decode(
          stderrBuf.takeBytes(),
          allowMalformed: true,
        );
        throw IosAttachException(
          IosAttachErrorKind.iproxyReadinessFailed,
          'iproxy exited inside readiness window — tunnel never came '
          'up; wsUri not printed.'
          '${captured.trim().isEmpty ? "" : "\niproxy stderr:\n$captured"}'
          '${stderrTruncated ? "\n  (...stderr truncated at $stderrCap bytes)" : ""}',
          data: <String, Object?>{
            if (captured.trim().isNotEmpty) 'stderr': captured,
            'truncated': stderrTruncated,
          },
        );
      }

      onProgress?.call(
        IosAttachPhase.iproxyReady,
        data: <String, Object?>{'pid': iproxy.pid, 'hostPort': hostPort},
      );

      final wsUri = 'ws://127.0.0.1:$hostPort/${picked.authCode}=/ws';
      onProgress?.call(IosAttachPhase.attachComplete);

      return IosAttachResult(
        wsUri: wsUri,
        transport: transport,
        announcements: announcements,
        selected: picked,
        hostPort: hostPort,
        teardown: stopIproxy,
        iproxyProcess: iproxy,
        pidfile: pidfile,
        origin: origin,
      );
    } on CommandCancelledException {
      // A cancel reached a command inside a helper, for example the stale
      // iproxy check; its child is already gone.
      throw _cancelledError();
    } finally {
      await cancelSub?.cancel();
    }
  }
}

IosAttachException _cancelledError() => IosAttachException(
  IosAttachErrorKind.cancelled,
  'attach cancelled by caller',
);

/// Waits for [work], but throws [CommandTimeoutException] once [timeout]
/// passes and [CommandCancelledException] once [cancel] completes. When
/// [cancel] completes, [work] first gets [afterCancel] to finish, which
/// lets work that ends its own child on cancel, such as a Bonjour collector
/// over [ownedBonjourLines], reap it. Past that the work keeps running
/// unobserved: use this only for work that owns no child, or whose child a
/// cancel ends.
Future<T> _interruptible<T>(
  Future<T> work,
  String what, {
  Duration? timeout,
  required Future<void> cancel,
  Duration afterCancel = Duration.zero,
}) {
  final result = Completer<T>();
  Timer? timer;
  Timer? cancelTimer;
  void finish(void Function() complete) {
    if (result.isCompleted) return;
    timer?.cancel();
    cancelTimer?.cancel();
    complete();
  }

  void cancelNow() =>
      finish(() => result.completeError(CommandCancelledException(what)));

  work.then<void>(
    (value) => finish(() => result.complete(value)),
    onError: (Object e, StackTrace st) =>
        finish(() => result.completeError(e, st)),
  );
  if (timeout != null) {
    timer = Timer(
      timeout,
      () => finish(
        () => result.completeError(CommandTimeoutException(what, timeout)),
      ),
    );
  }
  cancel.then<void>((_) {
    if (result.isCompleted) return;
    if (afterCancel <= Duration.zero) {
      cancelNow();
    } else {
      cancelTimer = Timer(afterCancel, cancelNow);
    }
  }, onError: (Object _) {});
  return result.future;
}

/// How long a step whose work ends its own child on cancel gets to reap
/// it: the owned runner's SIGTERM grace and SIGKILL wait, plus a margin.
const Duration _reapAfterCancel = Duration(seconds: 2);

/// `which <tool>` as an owned child. The tools come from Xcode and
/// libimobiledevice, so only macOS has them; elsewhere `which` itself may
/// be missing.
Future<bool> _toolOnPath(
  OwnedProcessRunner owned,
  String tool,
  Future<void> cancel,
) async {
  if (!Platform.isMacOS) return false;
  try {
    final r = await owned.run(
      'which',
      [tool],
      timeout: IosAttacher._shortCommandTimeout,
      cancel: cancel,
    );
    return r.exitCode == 0;
  } on ProcessException {
    return false;
  } on CommandTimeoutException {
    return false;
  }
}

Future<Process> _defaultIproxyStart(String exe, List<String> args) =>
    Process.start('nohup', [exe, ...args]);

/// Drops writes — used when callers don't want diagnostic stderr
/// surfaced (e.g. the MCP path renders structured errors instead).
class _NullStringSink implements StringSink {
  @override
  void write(Object? object) {}
  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) {}
  @override
  void writeCharCode(int charCode) {}
  @override
  void writeln([Object? object = '']) {}
}
