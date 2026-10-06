import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../bridge/app_log_stream.dart';
import '../bridge/vm_bridge.dart';
import '../cli/attach_ios_command.dart' show IosTransport;
import '../cli/ios_attach_pipeline.dart'
    show
        IosAttachErrorKind,
        IosAttachException,
        IosAttachResult,
        IosAttacher,
        IosAttachProgress;
import '../mcp/mcp_server.dart';
import '../util/device_filter.dart';
import '../util/owned_process.dart'
    show
        CommandCancelledException,
        CommandRunner,
        CommandTimeoutException,
        OwnedProcessRunner,
        killProcessTree,
        waitAtMost;
import 'app_log_buffer.dart';
import 'app_status.dart';
import 'daemon_events.dart';
import 'daemon_parser.dart';
import 'daemon_rpc.dart';

/// Injection seam for `Process.start` so tests can fake the flutter child.
typedef ProcessFactory =
    Future<Process> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
    });

/// Default [ProcessFactory]. On Windows `flutter` is the `flutter.bat`
/// script, which `Process.start` finds only through the shell. The child is
/// then `cmd.exe`, so the session ends it with [killProcessTree], which
/// also ends flutter's `dart.exe` under it.
Future<Process> _startProcess(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
}) => Process.start(
  executable,
  arguments,
  workingDirectory: workingDirectory,
  environment: environment,
  runInShell: Platform.isWindows,
);

class DaemonSessionException implements Exception {
  DaemonSessionException(this.message);
  final String message;
  @override
  String toString() => 'DaemonSessionException: $message';
}

/// Upper bounds for each wait in [DaemonSession.detach]. The sidecar's exit
/// path gives the whole detach 10 seconds, so [worstCase] must stay well
/// inside that.
class DetachBudget {
  const DetachBudget({
    this.appDetach = const Duration(seconds: 2),
    this.childTerm = const Duration(seconds: 2),
    this.childKill = const Duration(seconds: 1),
    this.bridgeDisconnect = const Duration(seconds: 2),
    this.iosTeardown = const Duration(seconds: 3),
    this.attachUnwind = const Duration(seconds: 2),
  });

  /// Wait for the daemon to answer `app.detach`.
  final Duration appDetach;

  /// Wait for the flutter child to exit after SIGTERM, or on Windows after
  /// `taskkill /T /F`, including the taskkill run itself.
  final Duration childTerm;

  /// Wait for the flutter child to exit after SIGKILL.
  final Duration childKill;

  /// Wait for the bridge to disconnect.
  final Duration bridgeDisconnect;

  /// Wait for the iOS tunnel teardown (iproxy and its pidfile).
  final Duration iosTeardown;

  /// Wait for an attach that the detach cancelled to end the external
  /// commands it runs: the `flutter devices` probe, or the iOS pipeline's
  /// devicectl, dns-sd and iproxy children.
  final Duration attachUnwind;

  /// Longest a detach can take. A session holds a flutter child, an iOS
  /// tunnel, or an attach still running its probe or pipeline, never two
  /// of them, so the slowest of the three paths bounds it.
  Duration get worstCase {
    final daemon = appDetach + childTerm + childKill + bridgeDisconnect;
    final ios = bridgeDisconnect + iosTeardown;
    final unwinding = bridgeDisconnect + attachUnwind;
    var longest = daemon > ios ? daemon : ios;
    if (unwinding > longest) longest = unwinding;
    return longest;
  }
}

/// The flutter child exited before the attach finished.
class _FlutterExited implements Exception {
  _FlutterExited(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A detach or a cleanup ended the attach while it waited for the daemon.
class _AttachStopped implements Exception {
  @override
  String toString() => 'the attach was stopped before it finished';
}

/// The cancel signal of one attach. It fires when the client cancels the
/// request ([signal]), or when the session fires it itself with [fire],
/// which a detach does, and so does the sidecar's shutdown through it.
class _CancelWatch {
  _CancelWatch(Stream<void>? signal, void Function() onClientCancel) {
    _subscription = signal?.listen((_) {
      if (_stopped || _fired.isCompleted) return;
      _fired.complete();
      onClientCancel();
    });
  }

  StreamSubscription<void>? _subscription;
  final Completer<void> _fired = Completer<void>();
  bool _stopped = false;

  bool get fired => _fired.isCompleted;

  /// Completes when the signal fires.
  Future<void> get future => _fired.future;

  /// Fires the signal from inside the session. The client callback does
  /// not run, because the caller is already detaching.
  void fire() {
    if (!_fired.isCompleted) _fired.complete();
  }

  /// A new stream that emits once when the signal fires, even when it fired
  /// before the listen. The iOS pipeline listens again on every attempt.
  Stream<void> stream() => _fired.future.asStream();

  Future<void> stop() async {
    _stopped = true;
    await _subscription?.cancel();
  }
}

/// Owns the lifecycle of one `flutter attach --machine` child:
/// spawning, parsing daemon protocol, sending RPC requests, coordinating
/// bridge reconnect on hot restart. Idempotent detach.
///
/// State machine:
///   idle -> attaching -> ready -> restarting -> ready -> detaching -> idle
///   (any state) -> error -> (attach -> attaching)
class DaemonSession implements DaemonSessionLifecycle {
  DaemonSession({
    required this.bridge,
    required this.server,
    ProcessFactory? processFactory,
    Sink<String>? logger,
    Duration attachTimeout = const Duration(seconds: 30),
    Duration hotReloadTimeout = const Duration(seconds: 30),
    Duration hotRestartTimeout = const Duration(seconds: 45),
    String flutterExecutable = 'flutter',
    bool? hostIsMacOS,
    bool? hostIsWindows,
    CommandRunner? runCommand,
    IosAttacher? iosAttacher,
    AppLogBuffer? appLogs,
    this.detachBudget = const DetachBudget(),
  }) : _processFactory = processFactory ?? _startProcess,
       _logger = logger,
       _attachTimeout = attachTimeout,
       _hotReloadTimeout = hotReloadTimeout,
       _hotRestartTimeout = hotRestartTimeout,
       _flutterExecutable = flutterExecutable,
       _hostIsMacOS = hostIsMacOS ?? Platform.isMacOS,
       _hostIsWindows = hostIsWindows ?? Platform.isWindows,
       _runCommand = runCommand,
       _iosAttacher = iosAttacher,
       appLogs = appLogs ?? AppLogBuffer() {
    final Object source = bridge;
    if (source is AppLogSource) {
      source.appLogLines.listen(this.appLogs.add);
    }
  }

  final VmBridge bridge;
  final McpServer server;

  /// Bounds for every wait in [detach]; see [DetachBudget.worstCase].
  final DetachBudget detachBudget;
  final ProcessFactory _processFactory;
  final Sink<String>? _logger;
  final Duration _attachTimeout;
  final Duration _hotReloadTimeout;
  final Duration _hotRestartTimeout;
  final String _flutterExecutable;

  /// The iOS-direct path needs `xcrun` and `dns-sd`, so it runs only on
  /// macOS.
  final bool _hostIsMacOS;

  /// On Windows the flutter child runs under `cmd.exe`, so ending it takes
  /// `taskkill /T /F` ([killProcessTree]).
  final bool _hostIsWindows;

  /// Runs taskkill on Windows. Null means `Process.run`.
  final CommandRunner? _runCommand;

  /// Pipeline used by [attachViaIos] when the call passes none. Null means
  /// a real [IosAttacher].
  final IosAttacher? _iosAttacher;

  /// Fails the daemon waiters of the attach in progress, so a detach does
  /// not leave that attach waiting for its full timeout.
  void Function()? _abortAttachWait;

  /// Cancel signal of the attach in progress. A detach fires it, so the
  /// attach stops its probe or pipeline and kills the commands it runs.
  _CancelWatch? _attachCancel;

  /// Cancel signal of the iOS attach that holds [_iosAttachInFlight].
  _CancelWatch? _iosAttachCancel;

  /// The external work the attach in progress waits for: the `flutter
  /// devices` probe, the iOS pipeline, or the teardown of a tunnel that a
  /// detach left without an owner. A detach waits for it, at most
  /// [DetachBudget.attachUnwind], so the commands it ran are gone when the
  /// detach returns. The work never waits for the session, so the wait
  /// cannot deadlock. Never completes with an error.
  Future<void>? _attachWork;

  /// The detach that is running, if any. A second [detach] joins it, and an
  /// attach that a detach took over waits for it before it returns.
  Future<void>? _detachInFlight;

  /// Recent app output for the `get_logs` tool. The bridge feeds it from
  /// the VM service `Stdout`, `Stderr` and `Logging` streams; daemon
  /// `app.log` lines fill in while those streams are not active. A new
  /// attach and every detach clear it.
  final AppLogBuffer appLogs;

  AppSessionState _state = AppSessionState.idle;
  String? _appId;
  String? _deviceId;
  String? _launchMode;
  String? _mode;
  String? _lastError;
  Process? _child;
  DaemonRpc? _rpc;
  Uri? _lastWsUri;

  /// How the attach that reached `ready` opened the bridge, as reported in
  /// `connectedVia`. Null when no attach owns the connection.
  String? _attachRoute;

  /// iOS-direct attach owns an iproxy child + pidfile on USB, or no
  /// child at all on wireless. The teardown callback returned by
  /// `IosAttacher` encapsulates either case — set when
  /// `launchMode == 'ios-direct'`, invoked from `_cleanup()`.
  Future<void> Function()? _iosTeardown;
  IosTransport? _iosTransport;
  String? _iosWsUri;

  /// Serialises concurrent `attachViaIos` calls so two MCP requests
  /// in flight don't race on iproxy spawn / pidfile write.
  Completer<void>? _iosAttachInFlight;
  StreamSubscription<DaemonEvent>? _eventSub;
  StreamSubscription<String>? _stderrSub;
  StreamController<DaemonEvent>? _eventsForSession;

  /// Monotonic counter — every attach bumps it. Async closures that
  /// outlive their session (exit-code listener, stderr listener) capture
  /// the value at spawn time and bail when it no longer matches.
  int _sessionGeneration = 0;

  /// Set by `detach()` before any state mutation so a concurrent attach's
  /// catch block can recognize "user asked to stop" and skip flipping
  /// state back to `error`.
  bool _detachRequested = false;

  /// Armed by `_restart()` BEFORE sending `app.restart`. Resolved by the
  /// parser listener on AppStartedEvent — the new isolate is registered
  /// by that point. Sync-on-arrival so the event can't be lost to a
  /// lazy subscriber.
  Completer<DaemonEvent>? _restartSettleCompleter;

  /// Latest AppDebugPortEvent captured in the parser listener — the
  /// settle waits for AppStartedEvent (later), but the debugPort wsUri
  /// may rotate independently. Cleared at the start of each restart.
  AppDebugPortEvent? _restartDebugPort;

  /// Lines of flutter output kept for the message of an early exit.
  static const int _recentOutputLines = 6;

  /// Changes on every attach and every cleanup. A caller that captured it
  /// can tell whether the session it started is still the current one.
  int get generation => _sessionGeneration;

  /// Where new app output comes from right now, as `get_logs` reports it:
  /// `vm_service` while the bridge listens to the VM service streams,
  /// `daemon` while only the flutter daemon's `app.log` lines arrive, and
  /// `none` otherwise.
  String get logCapture {
    final Object source = bridge;
    if (source is AppLogSource && source.appLogStreamsActive) {
      return 'vm_service';
    }
    if (_eventSub != null) return 'daemon';
    return 'none';
  }

  /// True when an attach that is no longer current, because a detach or a
  /// newer attach took over, must leave the session alone.
  bool _superseded(int gen) => gen != _sessionGeneration || _detachRequested;

  /// True while an earlier session still holds a flutter child, the
  /// daemon channel or an iOS tunnel.
  bool get _holdsResources =>
      _child != null ||
      _rpc != null ||
      _eventSub != null ||
      _iosTeardown != null;

  /// True while an `attach_app` session owns the bridge connection: an
  /// attach is running, attached, reloading or detaching, or a session that
  /// ended in error still holds its flutter child, daemon channel or iOS
  /// tunnel. The `connect` tool refuses then, because pointing the bridge
  /// at another app would leave `hot_reload` reloading the attached app
  /// while every diagnostic reads the other one.
  bool get ownsConnection =>
      (_state != AppSessionState.idle && _state != AppSessionState.error) ||
      _holdsResources;

  AppStatusPayload get status {
    final connected = bridge.isConnected;
    return AppStatusPayload(
      attached: _state == AppSessionState.ready && connected,
      state: _state.name,
      connected: connected,
      connectedVia: connected ? (_attachRoute ?? ConnectedVia.connect) : null,
      device: _deviceId,
      appId: _appId,
      sessionUuid: bridge.baselineSessionUuid,
      launchMode: _launchMode,
      mode: _mode,
      lastError: _lastError,
      transportMode: _iosTransport == null
          ? null
          : (_iosTransport == IosTransport.wireless
                ? 'wireless'
                : _iosTransport == IosTransport.wired
                ? 'wired'
                : 'unknown'),
      wsUri: _iosWsUri,
    );
  }

  /// Returns devices reported by `flutter devices --machine`. Each entry
  /// is the raw map from flutter — caller filters by `category`/`platform`.
  ///
  /// The child is owned: when [timeout] passes or [cancel] completes first,
  /// it is killed (with `taskkill /T /F` on Windows, where it runs under
  /// `cmd.exe`) and the call throws [DaemonSessionException]. Reading its
  /// output waits at most [outputWait] once it exited or was killed, so a
  /// grandchild that holds the pipe cannot hold the caller. [isWindows] and
  /// [runCommand] replace the platform check and taskkill's runner in tests.
  static Future<List<Map<String, Object?>>> listDevices({
    ProcessFactory? processFactory,
    String flutterExecutable = 'flutter',
    Duration timeout = const Duration(seconds: 15),
    Future<void>? cancel,
    bool? isWindows,
    CommandRunner? runCommand,
    Duration outputWait = const Duration(seconds: 2),
  }) async {
    final factory = processFactory ?? _startProcess;
    final runner = OwnedProcessRunner(
      start: (executable, arguments) => factory(executable, arguments),
      outputWait: outputWait,
      encoding: utf8,
      isWindows: isWindows,
      runCommand: runCommand,
    );
    final ProcessResult result;
    try {
      result = await runner.run(
        flutterExecutable,
        const ['devices', '--machine'],
        timeout: timeout,
        cancel: cancel,
      );
    } on CommandTimeoutException {
      throw DaemonSessionException(
        'flutter devices --machine did not finish within '
        '${timeout.inSeconds}s',
      );
    } on CommandCancelledException {
      throw DaemonSessionException('flutter devices --machine was cancelled');
    }
    final exit = result.exitCode;
    if (exit != 0) {
      throw DaemonSessionException('flutter devices --machine exited $exit');
    }
    final decoded = jsonDecode(result.stdout as String);
    if (decoded is! List) {
      throw DaemonSessionException(
        'flutter devices --machine did not return an array',
      );
    }
    return decoded.whereType<Map<String, Object?>>().toList(growable: false);
  }

  /// Attaches through `flutter attach --machine`, or straight to
  /// [debugUrl] when it is set.
  ///
  /// [onProgress] receives a short message at each stage. When
  /// [cancelSignal] emits while the attach runs, the session detaches,
  /// which stops the flutter child and disconnects the bridge, and the
  /// attach returns the idle status. A [detach] that runs meanwhile, also
  /// the one the sidecar's shutdown runs, stops the attach the same way and
  /// kills its `flutter devices` probe.
  Future<AppStatusPayload> attach({
    String? device,
    String? debugUrl,
    void Function(String message)? onProgress,
    Stream<void>? cancelSignal,
  }) async {
    if (_state != AppSessionState.idle && _state != AppSessionState.error) {
      throw StateError(
        'already attached or attaching (state=${_state.name}). '
        'Call detach_app first.',
      );
    }
    _state = AppSessionState.attaching;
    _lastError = null;
    _detachRequested = false;
    if (_holdsResources) {
      // A session that ended in error, for example after a failed hot
      // reload, can still hold its flutter child. Release it first.
      await _cleanup();
      if (_detachRequested) return await _supersededStatus();
    }
    final gen = ++_sessionGeneration;
    appLogs.clear();
    final cancel = _attachCancel = _CancelWatch(
      cancelSignal,
      () => unawaited(detachIfCurrent(gen)),
    );
    try {
      if (debugUrl != null) {
        return await _attachToUrl(gen, debugUrl, onProgress);
      }
      return await _attachThroughDaemon(gen, device, onProgress, cancel);
    } finally {
      await cancel.stop();
      if (identical(_attachCancel, cancel)) _attachCancel = null;
    }
  }

  /// Runs [body] as the attach work that a detach waits for (see
  /// [_attachWork]). [body] must never wait for a detach.
  Future<T> _asAttachWork<T>(Future<T> Function() body) async {
    final work = Completer<void>();
    final future = work.future;
    _attachWork = future;
    try {
      return await body();
    } finally {
      work.complete();
      if (identical(_attachWork, future)) _attachWork = null;
    }
  }

  /// Waits for the attach work in flight, at most
  /// [DetachBudget.attachUnwind] in all. Between two pieces of work, for
  /// example a pipeline and then the teardown of the tunnel it returned
  /// after the detach, the attach gets a turn to start the next one.
  Future<void> _awaitAttachWork() async {
    final waited = Stopwatch()..start();
    while (true) {
      final work = _attachWork;
      final left = detachBudget.attachUnwind - waited.elapsed;
      if (work == null || left <= Duration.zero) return;
      await waitAtMost(work, left);
      await Future<void>.delayed(Duration.zero);
      if (identical(_attachWork, work)) return;
    }
  }

  /// debugUrl escape hatch: connects the bridge without a flutter daemon.
  /// The mode is unknown because no daemon reported it; `ext.sleuth.diagnose`
  /// can tell.
  Future<AppStatusPayload> _attachToUrl(
    int gen,
    String debugUrl,
    void Function(String message)? onProgress,
  ) async {
    onProgress?.call('Connecting to the VM service at debugUrl');
    try {
      final uri = Uri.parse(debugUrl);
      await bridge.connect(uri);
      if (_superseded(gen)) return await _supersededStatus();
      _lastWsUri = uri;
      _launchMode = 'attach';
      _mode = 'unknown';
      _attachRoute = ConnectedVia.attachDebugUrl;
      _state = AppSessionState.ready;
      return status;
    } catch (e) {
      return await _failAttach(gen, 'debugUrl connect failed: $e');
    }
  }

  Future<AppStatusPayload> _attachThroughDaemon(
    int gen,
    String? device,
    void Function(String message)? onProgress,
    _CancelWatch cancel,
  ) async {
    // Mobile-only scope check (Android + iOS). Pre-flight via flutter devices.
    if (device != null) {
      onProgress?.call('Checking that $device is an Android or iOS device');
      try {
        final devices = await _asAttachWork(
          () => listDevices(
            processFactory: _processFactory,
            flutterExecutable: _flutterExecutable,
            cancel: cancel.future,
            isWindows: _hostIsWindows,
            runCommand: _runCommand,
          ),
        );
        if (_superseded(gen)) return await _supersededStatus();
        final match = devices.firstWhere(
          (d) => d['id'] == device || d['name'] == device,
          orElse: () => const <String, Object?>{},
        );
        if (match.isNotEmpty && !isMobileFlutterDevice(match)) {
          final target = match['targetPlatform'] ?? match['category'];
          return await _failAttach(
            gen,
            'device $device (platform=$target) is not a mobile device. '
            'attach_app supports only Android and iOS devices.',
          );
        }
      } catch (_) {
        // The probe failed; flutter attach reports a bad device itself.
        if (_superseded(gen)) return await _supersededStatus();
      }
    }

    final args = <String>['attach', '--machine'];
    if (device != null) args.addAll(['-d', device]);
    onProgress?.call('Starting flutter attach');
    final Process child;
    try {
      child = await _processFactory(_flutterExecutable, args);
    } catch (e) {
      return await _failAttach(gen, 'failed to spawn flutter: $e');
    }
    if (_superseded(gen)) {
      // A detach ran while flutter was starting, so no session owns this
      // child.
      unawaited(_killTree(child));
      return await _supersededStatus();
    }
    _child = child;

    // Sync-attached completers — guarantees we observe daemon.connected /
    // app.debugPort / app.stop even if they arrive before any await. An
    // early flutter exit completes them with an error.
    final connected = Completer<DaemonConnectedEvent>();
    final debugPortOrStop = Completer<DaemonEvent>();
    // Once the attach gave up, nobody awaits them; a late exit error must
    // not surface as an unhandled error.
    connected.future.ignore();
    debugPortOrStop.future.ignore();
    _abortAttachWait = () {
      final stopped = _AttachStopped();
      if (!connected.isCompleted) connected.completeError(stopped);
      if (!debugPortOrStop.isCompleted) debugPortOrStop.completeError(stopped);
    };

    // Last lines flutter printed outside the daemon protocol (stderr, plain
    // stdout, daemon error messages), for the message of an early exit.
    final recentOutput = <String>[];
    void remember(String line) {
      if (gen != _sessionGeneration) return;
      final trimmed = line.trim();
      if (trimmed.isEmpty) return;
      recentOutput.add(
        trimmed.length > 300 ? '${trimmed.substring(0, 300)}...' : trimmed,
      );
      if (recentOutput.length > _recentOutputLines) recentOutput.removeAt(0);
    }

    final events = StreamController<DaemonEvent>.broadcast();
    _eventsForSession = events;

    final parser = DaemonParser();
    final responses = StreamController<DaemonRpcResponse>.broadcast();
    _eventSub = parser
        .parse(child.stdout, onOtherLine: remember)
        .listen(
          (event) {
            if (event is DaemonRpcResponse) {
              responses.add(event);
              return;
            }
            // Refine session metadata from app events as they arrive.
            if (event is AppStartEvent) {
              _deviceId = event.deviceId;
              _launchMode = event.launchMode;
              _mode = event.mode;
              _appId = event.appId;
            } else if (event is AppDebugPortEvent) {
              _appId = event.appId;
            } else if (event is AppLogEvent) {
              _addDaemonLog(event);
            } else if (event is DaemonLogMessageEvent &&
                event.level == 'error') {
              remember(event.message);
            }
            // Sync-on-arrival resolution — broadcast subscribers can't lose
            // events.
            if (event is DaemonConnectedEvent && !connected.isCompleted) {
              connected.complete(event);
            }
            if ((event is AppDebugPortEvent || event is AppStopEvent) &&
                !debugPortOrStop.isCompleted) {
              debugPortOrStop.complete(event);
            }
            // AppDebugPortEvent carries the (possibly rotated) wsUri but
            // fires BEFORE the new main isolate is registered. Capture it
            // for reconnect targeting, but do NOT use it as the settle
            // signal — reconnecting then would race the isolate spawn and
            // observe an empty isolates list.
            if (event is AppDebugPortEvent) {
              _restartDebugPort = event;
            }
            // Settle resolves ONLY on AppStartedEvent — by then the new
            // isolate is registered with the VM service and reconnect can
            // successfully pick it up.
            final restartCompleter = _restartSettleCompleter;
            if (restartCompleter != null &&
                !restartCompleter.isCompleted &&
                event is AppStartedEvent) {
              restartCompleter.complete(event);
            }
            events.add(event);
          },
          onError: (Object e) {
            _logger?.add('flutter stdout error: $e');
          },
        );

    _rpc = DaemonRpc(
      stdin: child.stdin,
      responses: responses.stream,
      logger: _logger,
    );
    final stderrDone = Completer<void>();
    _stderrSub = child.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(
          (line) {
            if (gen != _sessionGeneration) return; // stale session
            _logger?.add('[flutter] $line');
            remember(line);
          },
          onError: (Object e) {
            _logger?.add('flutter stderr error: $e');
          },
          onDone: () {
            if (!stderrDone.isCompleted) stderrDone.complete();
          },
        );

    // Crashed flutter must not leave the session hung. Generation guard
    // stops a stale listener from a prior attach flipping a fresh session.
    unawaited(
      child.exitCode.then((code) async {
        if (gen != _sessionGeneration) return;
        // The exit code can arrive before the last stderr lines.
        await stderrDone.future.timeout(
          const Duration(milliseconds: 500),
          onTimeout: () {},
        );
        if (gen != _sessionGeneration) return;
        final message = _exitMessage(
          code,
          recentOutput,
          beforeVmService: !debugPortOrStop.isCompleted,
        );
        final exited = _FlutterExited(message);
        if (!connected.isCompleted) connected.completeError(exited);
        if (!debugPortOrStop.isCompleted) debugPortOrStop.completeError(exited);
        // Nothing answers daemon RPCs any more. Fail the ones in flight, for
        // example a hot reload, instead of letting them wait out their
        // timeouts, and skip `app.detach` on the next detach.
        final rpc = _rpc;
        _rpc = null;
        unawaited(rpc?.close());
        if (!_detachRequested &&
            _state != AppSessionState.detaching &&
            _state != AppSessionState.idle) {
          _state = AppSessionState.error;
          _lastError = message;
        }
      }),
    );

    try {
      onProgress?.call('Waiting for the flutter daemon to start');
      final connectedEvent = await connected.future.timeout(_attachTimeout);
      if (_superseded(gen)) return await _supersededStatus();
      if (!isAtLeastVersion(connectedEvent.version, minDaemonProtocolVersion)) {
        return await _failAttach(
          gen,
          'unsupported flutter daemon ${connectedEvent.version}. The '
          'minimum version is $minDaemonProtocolVersion.',
        );
      }
      _logger?.add('daemon connected: version=${connectedEvent.version}');

      onProgress?.call(
        'Flutter daemon connected; waiting for the app to report its VM '
        'service',
      );
      final outcome = await debugPortOrStop.future.timeout(_attachTimeout);
      if (_superseded(gen)) return await _supersededStatus();

      if (outcome is AppStopEvent) {
        return await _failAttach(
          gen,
          'the flutter daemon sent app.stop during the attach. Either the '
          'app is a release-mode build, or it exited before its VM service '
          'was available.',
        );
      }
      final debugPort = outcome as AppDebugPortEvent;
      _appId = debugPort.appId;
      _deviceId ??= device;
      _launchMode ??= 'attach';
      _mode ??= 'debug';

      onProgress?.call('Connecting to the app VM service');
      final uri = Uri.parse(debugPort.wsUri);
      await bridge.connect(uri);
      if (_superseded(gen)) return await _supersededStatus();
      _lastWsUri = uri;
      _abortAttachWait = null;
      _attachRoute = ConnectedVia.attachDevice;
      _state = AppSessionState.ready;
      return status;
    } on TimeoutException {
      return await _failAttach(
        gen,
        'no daemon.connected or app.debugPort event arrived within '
        '${_attachTimeout.inSeconds}s. Is the Flutter app running on the '
        'device?',
      );
    } on VmBridgeException catch (e) {
      return await _failAttach(gen, 'bridge connect failed: ${e.message}');
    } on _FlutterExited catch (e) {
      return await _failAttach(gen, e.message);
    } catch (e) {
      // bridge.connect can throw more than VmBridgeException, for example
      // an RPCError from getVM or a closed transport during the bootstrap
      // diagnose. The flutter child must still be released.
      return await _failAttach(gen, 'attach failed: $e');
    }
  }

  /// Message for a flutter child that exited on its own.
  static String _exitMessage(
    int code,
    List<String> recentOutput, {
    required bool beforeVmService,
  }) {
    final buffer = StringBuffer('flutter attach exited with code $code');
    if (beforeVmService) {
      buffer.write(' before the app reported its VM service');
    }
    if (recentOutput.isEmpty) {
      buffer.write(
        '. It printed nothing. Common causes: more than one device is '
        'connected and attach_app got no device, or no Flutter app is '
        'running on the device.',
      );
    } else {
      buffer.write('. Last output:\n${recentOutput.join('\n')}');
    }
    return buffer.toString();
  }

  /// Ends a failed attach: releases what it started and records [message]
  /// as the error, unless a detach or a newer attach took over first.
  Future<AppStatusPayload> _failAttach(int gen, String message) async {
    if (_superseded(gen)) return await _supersededStatus();
    await _cleanup();
    // A detach or a newer attach that ran during the cleanup owns the
    // state now; the cleanup itself moved the generation by one.
    if (_detachRequested || _sessionGeneration != gen + 1) {
      return await _supersededStatus();
    }
    _state = AppSessionState.error;
    _lastError = message;
    return status;
  }

  /// Adds a daemon `app.log` line to [appLogs] when the bridge does not
  /// read the same output from the VM service streams.
  void _addDaemonLog(AppLogEvent event) {
    final Object source = bridge;
    if (source is AppLogSource && source.appLogStreamsActive) return;
    final now = DateTime.now();
    for (final line in const LineSplitter().convert(event.log)) {
      appLogs.add(AppLogLine(time: now, source: 'daemon', text: line));
    }
  }

  /// iOS-direct attach. Drives [IosAttacher] (devicectl launch →
  /// Bonjour → iproxy → wsUri) then connects the bridge — one MCP
  /// round-trip.
  ///
  /// [IosAttachException] is rethrown to the tool handler (which maps
  /// to a typed envelope); `_state` is set to `error` + `_lastError`
  /// before rethrow so `app_status` reflects the failure. Any other
  /// failure sets the error state and returns the status.
  ///
  /// When [cancelSignal] emits, the pipeline stops at once, kills the
  /// external commands it runs, and the session detaches. A [detach] that
  /// runs meanwhile, also the one the sidecar's shutdown runs, stops the
  /// pipeline the same way and waits, bounded, for it to end.
  ///
  /// Concurrent calls serialise via [_iosAttachInFlight]; second call
  /// waits or rejects via [StateError] when `failFastOnConcurrent`. An
  /// attach that a detach cancelled is only ending, so a new call waits for
  /// it, at most [DetachBudget.attachUnwind], instead of being refused.
  Future<AppStatusPayload> attachViaIos({
    required String udid,
    required String bundle,
    String? authOverride,
    IosTransport? transportOverride,
    IosAttacher? attacher,
    IosAttachProgress? onProgress,
    Stream<void>? cancelSignal,
    bool failFastOnConcurrent = true,
    bool forceRelaunch = false,
    Duration bridgeConnectTimeout = const Duration(seconds: 10),
    Duration attachBudget = const Duration(seconds: 90),
  }) async {
    final pipeline = attacher ?? _iosAttacher;
    if (pipeline == null && !_hostIsMacOS) {
      throw IosAttachException(
        IosAttachErrorKind.missingTool,
        'attach_app(udid:) runs only on macOS, because it needs xcrun and '
        'dns-sd from the Xcode command line tools. This host runs '
        '${Platform.operatingSystem}.',
        data: const <String, Object?>{
          'tool': 'xcrun',
          'remedy':
              'Run the sidecar on a Mac, or attach with attach_app(device:) '
              'or attach_app(debugUrl:).',
        },
      );
    }
    if (_state != AppSessionState.idle && _state != AppSessionState.error) {
      throw StateError(
        'already attached or attaching (state=${_state.name}). '
        'Call detach_app first.',
      );
    }
    final inFlight = _iosAttachInFlight;
    if (inFlight != null && !inFlight.isCompleted) {
      if (_iosAttachCancel?.fired ?? false) {
        await waitAtMost(inFlight.future, detachBudget.attachUnwind);
      }
    }
    if (inFlight != null && !inFlight.isCompleted) {
      if (failFastOnConcurrent) {
        throw StateError('attach_in_progress: another iOS attach is running');
      }
      await inFlight.future;
    }
    // A detach or another attach may have run while this call waited.
    if (_state != AppSessionState.idle && _state != AppSessionState.error) {
      throw StateError(
        'already attached or attaching (state=${_state.name}). '
        'Call detach_app first.',
      );
    }
    final completer = Completer<void>();
    _iosAttachInFlight = completer;

    _state = AppSessionState.attaching;
    _lastError = null;
    _detachRequested = false;
    int? started;
    _CancelWatch? cancel;
    try {
      if (_holdsResources) {
        // A session that ended in error can still hold its flutter child
        // or tunnel. Release it first.
        await _cleanup();
        if (_detachRequested) return await _supersededStatus();
      }
      final gen = started = ++_sessionGeneration;
      appLogs.clear();
      final watch = cancel = _attachCancel = _iosAttachCancel = _CancelWatch(
        cancelSignal,
        () => unawaited(detachIfCurrent(gen)),
      );
      return await _attachViaIosAttempts(
        gen: gen,
        udid: udid,
        bundle: bundle,
        authOverride: authOverride,
        transportOverride: transportOverride,
        attacher: pipeline ?? IosAttacher(),
        onProgress: onProgress,
        cancel: watch,
        forceRelaunch: forceRelaunch,
        bridgeConnectTimeout: bridgeConnectTimeout,
        attachBudget: attachBudget,
      );
    } on IosAttachException {
      // When a detach (for example a cancel) ended this attach, report the
      // error once that detach finished.
      final gen = started;
      if (gen != null && _superseded(gen)) await _supersededStatus();
      rethrow;
    } catch (e) {
      // Anything else, for example a TimeoutException from the pidfile lock
      // or a ProcessException from a missing `which`, must not leave the
      // session in `attaching`.
      final gen = started;
      if (gen != null) return await _failAttach(gen, 'iOS attach failed: $e');
      if (!_detachRequested && _state == AppSessionState.attaching) {
        _state = AppSessionState.error;
        _lastError = 'iOS attach failed: $e';
      }
      return status;
    } finally {
      await cancel?.stop();
      if (cancel != null && identical(_attachCancel, cancel)) {
        _attachCancel = null;
      }
      if (cancel != null && identical(_iosAttachCancel, cancel)) {
        _iosAttachCancel = null;
      }
      if (!completer.isCompleted) completer.complete();
    }
  }

  Future<AppStatusPayload> _attachViaIosAttempts({
    required int gen,
    required String udid,
    required String bundle,
    required String? authOverride,
    required IosTransport? transportOverride,
    required IosAttacher attacher,
    required IosAttachProgress? onProgress,
    required _CancelWatch cancel,
    required bool forceRelaunch,
    required Duration bridgeConnectTimeout,
    required Duration attachBudget,
  }) async {
    // Original connect error from the attempt that triggered recovery;
    // surfaced if recovery finds no live port. Outside the inner try so
    // the IosAttachException catch can read it.
    String? recoveryConnectError;
    try {
      var attempt = 0;
      var useForceRelaunch = forceRelaunch;
      var retryExcludePorts = const <int>{};
      // Ambiguous-pairings recovery: when multiple distinct authCodes
      // coexist (a stale + a fresh service after a relaunch), connect to
      // each in turn and keep the one whose VM service is live.
      var candidateQueue = <String>[];
      String? candidateAuth;
      // Gates recovery initiation only; per-attempt inner timeouts bound
      // actual runtime.
      final attachStopwatch = Stopwatch()..start();
      while (true) {
        attempt++;
        if (cancel.fired) {
          throw IosAttachException(
            IosAttachErrorKind.cancelled,
            'the caller cancelled the attach',
          );
        }
        final IosAttachResult result;
        try {
          final auth = candidateAuth ?? authOverride;
          final excluded = retryExcludePorts;
          final relaunch = useForceRelaunch;
          result = await _asAttachWork(
            () => attacher.attach(
              udid: udid,
              bundle: bundle,
              authOverride: auth,
              transportOverride: transportOverride,
              onProgress: onProgress,
              cancelSignal: cancel.stream(),
              forceRelaunch: relaunch,
              excludePorts: excluded,
            ),
          );
        } on IosAttachException catch (e) {
          final detached = _superseded(gen);
          final budgetLeft = attachStopwatch.elapsed < attachBudget;
          if (!detached && candidateAuth != null) {
            // Advancing broadly is safe here (unlike the bridge-connect
            // catch): attach()'s errors are pipeline-only, no contract
            // failures. Only the fatal-for-all kinds are excluded.
            final advanceable =
                e.kind != IosAttachErrorKind.missingTool &&
                e.kind != IosAttachErrorKind.cancelled;
            if (advanceable && candidateQueue.isNotEmpty && budgetLeft) {
              candidateAuth = candidateQueue.removeAt(0);
              continue;
            }
          } else if (!detached &&
              e.kind == IosAttachErrorKind.ambiguousPairings &&
              authOverride == null &&
              budgetLeft) {
            // whereType (not cast) so a malformed entry is skipped, not
            // thrown as an uncaught CastError out of attachViaIos.
            final codes =
                (e.data?['distinctAuthCodes'] as List?)
                    ?.whereType<String>()
                    .toList() ??
                const <String>[];
            if (codes.isNotEmpty) {
              candidateQueue = [...codes];
              candidateAuth = candidateQueue.removeAt(0);
              useForceRelaunch = false;
              continue;
            }
          }
          rethrow;
        }
        if (_superseded(gen)) {
          // A detach raced this attempt, so release its tunnel now. The
          // detach waits for this teardown too.
          await _asAttachWork(result.teardown);
          return await _supersededStatus();
        }
        _iosTeardown = result.teardown;
        _iosTransport = result.transport;
        _iosWsUri = result.wsUri;
        _deviceId = udid;
        _launchMode = 'ios-direct';
        _mode = 'profile';

        try {
          // Bound the handshake end-to-end. A half-open VM service
          // (WS accepted, getVM never returns) would otherwise pin
          // the mutex indefinitely.
          await bridge
              .connect(Uri.parse(result.wsUri))
              .timeout(bridgeConnectTimeout);
        } on TimeoutException {
          await result.teardown();
          // A detach that ran meanwhile already released this attempt.
          if (_superseded(gen)) return await _supersededStatus();
          _clearIosAttempt();
          if (candidateAuth != null &&
              candidateQueue.isNotEmpty &&
              attachStopwatch.elapsed < attachBudget) {
            // Half-open candidate (WS accepts, getVM never returns) — a
            // stale service that times out rather than resets. Try the
            // next announced candidate; the live one completes getVM.
            candidateAuth = candidateQueue.removeAt(0);
            continue;
          }
          _state = AppSessionState.error;
          _lastError =
              'ios_vmservice_unreachable: bridge connect timed out after '
              '${bridgeConnectTimeout.inSeconds}s. A common cause is a '
              'half-open VM service that accepts the WebSocket handshake '
              'but never answers `getVM`. Swipe the app off the device and '
              're-run, or rebuild the profile binary.';
          return status;
        } catch (e) {
          final message = '$e';
          final deadPort = result.selected.port;
          await result.teardown();
          if (_superseded(gen)) return await _supersededStatus();
          _clearIosAttempt();
          if (candidateAuth != null) {
            // Advance only on a dead-port signal (reset/refused). A
            // non-stale failure (version-skew, bootstrap, wireless) isn't
            // evidence the port is dead — surface it so a fail-closed
            // contract isn't masked.
            if (_isStaleRecoverable(message) &&
                candidateQueue.isNotEmpty &&
                attachStopwatch.elapsed < attachBudget) {
              candidateAuth = candidateQueue.removeAt(0);
              continue;
            }
            _state = AppSessionState.error;
            _lastError = mapBridgeConnectErrorToLastError(message);
            return status;
          }
          // Stale-mDNS recovery: selection landed on a dead cached port
          // (iOS retains the prior session's record ~1-2 min). Retry once,
          // re-resolving with that port excluded so a coexisting live
          // announcement wins.
          final canRecover =
              attempt == 1 &&
              attachStopwatch.elapsed < attachBudget &&
              _isStaleRecoverable(message);
          if (canRecover) {
            // forceRelaunch:false re-probes; excluding the dead port
            // redirects selection. A second cached-dead port can still be
            // picked on this single retry, ending on the busy error.
            recoveryConnectError = mapBridgeConnectErrorToLastError(message);
            useForceRelaunch = false;
            retryExcludePorts = {deadPort};
            continue;
          }
          _state = AppSessionState.error;
          // Substring → typed-name mapping lives in
          // [mapBridgeConnectErrorToLastError] so SDK wording drift
          // surfaces as a unit-test failure, not silent envelope
          // degradation.
          _lastError = mapBridgeConnectErrorToLastError(message);
          return status;
        }
        if (_superseded(gen)) return await _supersededStatus();
        _lastWsUri = Uri.parse(result.wsUri);
        _attachRoute = ConnectedVia.attachIos;
        _state = AppSessionState.ready;
        return status;
      }
    } on IosAttachException catch (e) {
      // Record state before rethrow so a follow-up `app_status`
      // reports `state: error` + `lastError` instead of a wedged-
      // looking `attaching`. Next `attach_app` recovers automatically.
      if (!_superseded(gen)) {
        _state = AppSessionState.error;
        if (recoveryConnectError != null) {
          // Recovery found no live port; surface the original connect
          // failure (names the real cause) instead of the fallback's
          // generic launch/bonjour error. Return so the tool maps it.
          _lastError = recoveryConnectError;
          return status;
        }
        _lastError = '${e.kind.name}: ${e.message}';
      }
      rethrow;
    }
  }

  /// Forgets the iOS attempt whose tunnel was just torn down.
  void _clearIosAttempt() {
    _iosTeardown = null;
    _iosTransport = null;
    _iosWsUri = null;
    _deviceId = null;
    _launchMode = null;
    _mode = null;
  }

  Future<AppStatusPayload> hotReload() => _restart(fullRestart: false);

  Future<AppStatusPayload> hotRestart() => _restart(fullRestart: true);

  /// Hot reload or restart through the flutter daemon.
  ///
  /// Throws [StateError] when the session is not `ready`, or, with a
  /// `hot_reload_unsupported:` message, when the session has no flutter
  /// daemon (a `debugUrl` or iOS-direct attach); the session is left as it
  /// was. Throws [DaemonSessionException] when flutter rejects the reload,
  /// for example on a compile error; the session stays `ready`. A timeout,
  /// an RPC failure or a failed bridge refresh returns the status with
  /// `state: error`.
  Future<AppStatusPayload> _restart({required bool fullRestart}) async {
    final verb = fullRestart ? 'restart' : 'reload';
    if (_state != AppSessionState.ready) {
      throw StateError(
        'not attached (state=${_state.name}). Call attach_app first.',
      );
    }
    final rpc = _rpc;
    final appId = _appId;
    if (rpc == null || appId == null) {
      // debugUrl and iOS-direct sessions have no daemon channel for the
      // app.restart RPC. The connection itself still works, so the session
      // stays as it is.
      throw StateError(
        'hot_reload_unsupported: hot $verb needs a session attached with '
        'attach_app(device:), which runs flutter attach. This session has '
        'no flutter daemon.',
      );
    }
    _state = AppSessionState.restarting;
    // Auto-resume window exceeds RPC timeout so dispatch can't unpause
    // mid-restart against a half-rebuilt bridge.
    final timeout = fullRestart ? _hotRestartTimeout : _hotReloadTimeout;
    server.pauseDispatch(
      autoResumeAfter: timeout + const Duration(seconds: 30),
    );
    // Settle completer armed pre-RPC: daemon can emit app.started in
    // the same event-loop turn as the response; lazy firstWhere misses it.
    final settleCompleter = fullRestart ? Completer<DaemonEvent>() : null;
    _restartSettleCompleter = settleCompleter;
    _restartDebugPort = null;
    try {
      await server.awaitPendingDrain();
      DaemonRpcResponse rpcResponse;
      try {
        rpcResponse = await rpc.call('app.restart', {
          'appId': appId,
          'fullRestart': fullRestart,
        }, timeout: timeout);
      } on DaemonRpcTimeoutException catch (e) {
        _state = AppSessionState.error;
        _lastError = 'hot $verb timed out after ${e.timeout.inSeconds}s';
        return status;
      } on DaemonRpcException catch (e) {
        _state = AppSessionState.error;
        _lastError = 'hot $verb rpc failed: ${e.message}';
        return status;
      }
      if (rpcResponse.isError) {
        _state = AppSessionState.error;
        _lastError = 'hot $verb rpc error: ${rpcResponse.error}';
        return status;
      }
      final result = rpcResponse.result;
      if (result is Map && result['code'] is int && result['code'] != 0) {
        // flutter refused the reload, for example on a compile error. The
        // app keeps running the old code and the session still works.
        _state = AppSessionState.ready;
        final message = result['message'];
        throw DaemonSessionException(
          'hot $verb rejected by flutter (code ${result['code']})'
          '${message is String && message.isNotEmpty ? ': $message' : ''}',
        );
      }

      // Full restart can rotate wsUri; hot reload preserves the connection.
      // Daemon never emits app.started for fullRestart:false.
      if (fullRestart && settleCompleter != null) {
        try {
          await settleCompleter.future.timeout(const Duration(seconds: 10));
        } on TimeoutException {
          // No app.started observed — proceed with whatever debugPort we saw.
        }
      }
      final newDebugPort = _restartDebugPort;

      try {
        // Full restart rotates the main isolate even when wsUri stays
        // the same — refreshBaseline reuses the old _mainIsolateId and
        // would hit a `[Sentinel kind: Collected]`. Always reconnect on
        // full restart so the bridge re-picks the live main isolate.
        if (fullRestart) {
          final reconnectUri = newDebugPort != null
              ? Uri.parse(newDebugPort.wsUri)
              : _lastWsUri;
          if (reconnectUri != null) {
            await bridge.connect(reconnectUri);
            _lastWsUri = reconnectUri;
          } else {
            await bridge.refreshBaseline(acceptSessionRotation: true);
          }
        } else {
          await bridge.refreshBaseline(acceptSessionRotation: true);
        }
      } on VmBridgeException catch (e) {
        _state = AppSessionState.error;
        _lastError = 'bridge refresh failed after the restart: ${e.message}';
        return status;
      }

      _state = AppSessionState.ready;
      _lastError = null;
      return status;
    } finally {
      _restartSettleCompleter = null;
      server.resumeDispatch();
    }
  }

  /// Detaches only when [generation] still names the current session, so a
  /// caller holding an old generation cannot end a newer attach.
  Future<void> detachIfCurrent(int generation) async {
    if (generation != _sessionGeneration) return;
    if (_state == AppSessionState.idle) return;
    await detach();
  }

  /// Ends the session: asks flutter to detach, stops the flutter child or
  /// the iOS tunnel, and disconnects the bridge. Also disconnects a bridge
  /// that the `connect` tool (or `--uri` at startup) opened while no attach
  /// was running. Idempotent, and every step is bounded. A call made while
  /// a detach runs waits for that detach.
  @override
  Future<void> detach() {
    final running = _detachInFlight;
    if (running != null) return running;
    final detaching = _detach();
    _detachInFlight = detaching;
    return detaching.whenComplete(() {
      if (identical(_detachInFlight, detaching)) _detachInFlight = null;
    });
  }

  /// The status for an attach that a detach or a newer attach took over.
  /// Waits for a running detach first, so the caller sees where it ended.
  Future<AppStatusPayload> _supersededStatus() async {
    final detaching = _detachInFlight;
    if (detaching != null) {
      try {
        await detaching;
      } catch (_) {
        /* the detach reports its own failure */
      }
    }
    return status;
  }

  Future<void> _detach() async {
    // Stop an attach in progress at once: its probe or iOS pipeline kills
    // the commands it runs instead of running on to its own timeouts.
    _attachCancel?.fire();
    if (_state == AppSessionState.idle) {
      _attachRoute = null;
      appLogs.clear();
      await _disconnectBridge();
      await _awaitAttachWork();
      return;
    }
    _detachRequested = true;
    _state = AppSessionState.detaching;
    try {
      final rpc = _rpc;
      final appId = _appId;
      if (rpc != null && appId != null) {
        try {
          // The outer bound also covers a stdin write that stalls.
          await rpc
              .call('app.detach', {
                'appId': appId,
              }, timeout: detachBudget.appDetach)
              .timeout(detachBudget.appDetach);
        } catch (_) {
          /* daemon may be dead; cleanup proceeds */
        }
      }
    } finally {
      await _cleanup();
      _state = AppSessionState.idle;
      _appId = null;
      _deviceId = null;
      _launchMode = null;
      _mode = null;
      _lastWsUri = null;
      appLogs.clear();
      await _awaitAttachWork();
    }
  }

  /// Sends SIGTERM to the flutter child, or on Windows ends its whole tree
  /// with `taskkill /T /F`, within [DetachBudget.childTerm].
  Future<void> _killTree(Process child) => killProcessTree(
    child,
    isWindows: _hostIsWindows,
    runCommand: _runCommand,
    taskkillTimeout: detachBudget.childTerm,
  );

  /// Ends the flutter child and waits for it: [_killTree], then SIGKILL
  /// when it still runs after [DetachBudget.childTerm] (which includes the
  /// taskkill run on Windows), then at most [DetachBudget.childKill] more.
  Future<void> _stopChild(Process child) async {
    final exited = child.exitCode;
    final term = Stopwatch()..start();
    await _killTree(child);
    final left = detachBudget.childTerm - term.elapsed;
    try {
      await exited.timeout(left > Duration.zero ? left : Duration.zero);
    } on TimeoutException {
      child.kill(ProcessSignal.sigkill);
      try {
        await exited.timeout(detachBudget.childKill);
      } on TimeoutException {
        _logger?.add('flutter child ${child.pid} did not exit after SIGKILL');
      }
    }
    // Orphan reaping beyond that is best-effort: Process.start doesn't
    // setpgid(), so on POSIX we rely on the flutter daemon's own SIGTERM
    // teardown of its subprocesses.
  }

  /// Disconnects the bridge within [DetachBudget.bridgeDisconnect]. A
  /// crashed VM service or a half-open tunnel can stall the disconnect.
  Future<void> _disconnectBridge() async {
    try {
      await bridge.disconnect().timeout(detachBudget.bridgeDisconnect);
    } on TimeoutException {
      _logger?.add('bridge disconnect did not finish in time');
    } catch (_) {
      /* best effort */
    }
  }

  Future<void> _cleanup() async {
    // Bump generation so any in-flight stderr / exitCode listener bails.
    _sessionGeneration++;
    _restartSettleCompleter = null;
    _attachRoute = null;
    // An attach still waiting for the daemon returns now instead of at its
    // timeout.
    final abortAttachWait = _abortAttachWait;
    _abortAttachWait = null;
    abortAttachWait?.call();
    // Cancelling the parser subscription completes only once flutter's
    // stdout closes, which the kill below causes. Waiting for it here
    // would block the cleanup behind a silent child.
    final eventSub = _eventSub;
    _eventSub = null;
    if (eventSub != null) {
      unawaited(eventSub.cancel().catchError((Object _) {}));
    }
    await _stderrSub?.cancel();
    _stderrSub = null;
    await _rpc?.close();
    _rpc = null;
    await _eventsForSession?.close();
    _eventsForSession = null;
    // Clear metadata so partial-attach state doesn't leak into status.
    _appId = null;
    _deviceId = null;
    _launchMode = null;
    _mode = null;
    final child = _child;
    _child = null;
    if (child != null) await _stopChild(child);
    // Bridge disconnect can hang if the device-side VM service has
    // crashed or the iproxy tunnel is half-open. Bound the wait so the
    // iOS teardown below still gets a chance to release the iproxy child
    // + pidfile.
    await _disconnectBridge();
    // iOS-direct teardown: kill iproxy and remove the pidfile. The 3s budget
    // must exceed the teardown's own 2s grace + SIGKILL + pidfile-delete;
    // otherwise a back-to-back `attach_app` races the still-bound port.
    final iosTeardown = _iosTeardown;
    _iosTeardown = null;
    if (iosTeardown != null) {
      try {
        await iosTeardown().timeout(detachBudget.iosTeardown);
      } on TimeoutException {
        // iproxy refused to exit within budget; SIGKILL fallback is
        // already wired inside the teardown callback.
      } catch (_) {
        /* best effort */
      }
    }
    _iosTransport = null;
    _iosWsUri = null;
  }

  /// Test seam: indicates whether an `attachViaIos` callback installed
  /// an iproxy teardown. True iff `launchMode == 'ios-direct'` and the
  /// session has not yet been cleaned up.
  bool get debugHasIosTeardown => _iosTeardown != null;

  /// Test seam: returns the typed exception class name used by
  /// `IosAttachException` so test wrappers can grep without importing.
  static String get debugIosAttachExceptionName => '$IosAttachException';

  /// True when the failure looks like a dead/stale device port
  /// (recoverable by re-resolving Bonjour with that port excluded), not a
  /// wireless-transport failure. Derived from [_classifyBridgeConnectError]
  /// so it cannot drift from [mapBridgeConnectErrorToLastError].
  static bool _isStaleRecoverable(String message) {
    final failure = _classifyBridgeConnectError(message);
    return failure == _BridgeConnectFailure.busy ||
        failure == _BridgeConnectFailure.devicePortDead;
  }

  /// Maps a `bridge.connect` exception message to the iOS-direct
  /// `lastError`. Exposed for unit testing so SDK wording drift
  /// surfaces as a test failure, not silent envelope degradation.
  static String mapBridgeConnectErrorToLastError(String exceptionMessage) {
    switch (_classifyBridgeConnectError(exceptionMessage)) {
      case _BridgeConnectFailure.busy:
        return 'ios_vmservice_busy: $exceptionMessage. Swipe the app off '
            'the device and re-run, or rebuild the profile binary.';
      case _BridgeConnectFailure.devicePortDead:
        return 'ios_vmservice_unreachable: $exceptionMessage. The iproxy '
            'tunnel is open, but nothing is listening on the device side. '
            'A common cause is a stale Bonjour cache that pinned a dead '
            'port. Wait about 30 s for mDNS to clear, or swipe the app off '
            'the device and re-run.';
      case _BridgeConnectFailure.wirelessUnreachable:
        return 'ios_vmservice_unreachable: $exceptionMessage. The wireless '
            'attach cannot reach the device. Common causes are a denied '
            'iOS Local Network permission for the launching app, a host '
            'and device on different Wi-Fi networks, or a device that left '
            'the network. Switch to USB (transport: usb), or grant Local '
            'Network permission and retry.';
      case _BridgeConnectFailure.unknown:
        return 'bridge connect failed: $exceptionMessage';
    }
  }
}

/// Classifies a `bridge.connect` failure. Both the `lastError` mapping and
/// recovery eligibility derive from it, so they can't disagree.
enum _BridgeConnectFailure {
  /// Tunnel reset/closed mid-handshake — the device refused the iproxy
  /// channel because the announced port is dead (stale mDNS).
  busy,

  /// Nothing listening on the device port (`Connection refused`).
  devicePortDead,

  /// Wireless transport can't reach the device (permission/network) —
  /// re-resolving Bonjour won't help.
  wirelessUnreachable,

  /// Unrecognised wording — surfaced verbatim, not recovered.
  unknown,
}

/// Precedence: reset/closed → busy, then refused, then wireless, then
/// unknown. Order matters — refused is checked before wireless markers.
_BridgeConnectFailure _classifyBridgeConnectError(String message) {
  if (message.contains('Connection reset') ||
      message.contains('Connection closed before full header')) {
    return _BridgeConnectFailure.busy;
  }
  if (message.contains('Connection refused')) {
    return _BridgeConnectFailure.devicePortDead;
  }
  if (message.contains('Operation not permitted') ||
      message.contains('Network is unreachable') ||
      message.contains('Failed host lookup') ||
      message.contains('No address associated with hostname')) {
    return _BridgeConnectFailure.wirelessUnreachable;
  }
  return _BridgeConnectFailure.unknown;
}
