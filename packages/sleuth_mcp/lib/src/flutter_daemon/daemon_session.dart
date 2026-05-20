import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../bridge/vm_bridge.dart';
import '../cli/attach_ios_command.dart' show IosTransport;
import '../cli/ios_attach_pipeline.dart'
    show IosAttachException, IosAttacher, IosAttachProgress;
import '../mcp/mcp_server.dart';
import '../util/device_filter.dart';
import 'app_status.dart';
import 'daemon_events.dart';
import 'daemon_parser.dart';
import 'daemon_rpc.dart';

/// Injection seam for `Process.start` so tests can fake the flutter child.
typedef ProcessFactory = Future<Process> Function(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
});

class DaemonSessionException implements Exception {
  DaemonSessionException(this.message);
  final String message;
  @override
  String toString() => 'DaemonSessionException: $message';
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
  })  : _processFactory = processFactory ?? Process.start,
        _logger = logger,
        _attachTimeout = attachTimeout,
        _hotReloadTimeout = hotReloadTimeout,
        _hotRestartTimeout = hotRestartTimeout,
        _flutterExecutable = flutterExecutable;

  final VmBridge bridge;
  final McpServer server;
  final ProcessFactory _processFactory;
  final Sink<String>? _logger;
  final Duration _attachTimeout;
  final Duration _hotReloadTimeout;
  final Duration _hotRestartTimeout;
  final String _flutterExecutable;

  AppSessionState _state = AppSessionState.idle;
  String? _appId;
  String? _deviceId;
  String? _launchMode;
  String? _mode;
  String? _lastError;
  Process? _child;
  DaemonRpc? _rpc;
  Uri? _lastWsUri;

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

  AppStatusPayload get status => AppStatusPayload(
        attached: _state == AppSessionState.ready,
        state: _state.name,
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

  /// Returns devices reported by `flutter devices --machine`. Each entry
  /// is the raw map from flutter — caller filters by `category`/`platform`.
  static Future<List<Map<String, Object?>>> listDevices({
    ProcessFactory? processFactory,
    String flutterExecutable = 'flutter',
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final factory = processFactory ?? Process.start;
    final proc = await factory(flutterExecutable, ['devices', '--machine']);
    final out = StringBuffer();
    final outDone = proc.stdout.transform(utf8.decoder).forEach(out.write);
    proc.stderr.drain<void>();
    final exit = await proc.exitCode.timeout(timeout, onTimeout: () {
      proc.kill();
      return -1;
    });
    await outDone;
    if (exit != 0) {
      throw DaemonSessionException(
        'flutter devices --machine exited $exit',
      );
    }
    final decoded = jsonDecode(out.toString());
    if (decoded is! List) {
      throw DaemonSessionException(
          'flutter devices --machine did not return an array');
    }
    return decoded.whereType<Map<String, Object?>>().toList(growable: false);
  }

  Future<AppStatusPayload> attach({
    String? device,
    String? debugUrl,
  }) async {
    if (_state != AppSessionState.idle && _state != AppSessionState.error) {
      throw StateError(
        'already attached or attaching (state=${_state.name}); '
        'call detach_app first',
      );
    }
    _state = AppSessionState.attaching;
    _lastError = null;
    _detachRequested = false;
    final gen = ++_sessionGeneration;

    // debugUrl escape hatch — bypass daemon entirely. Mode is unknown
    // because we did not negotiate it via daemon protocol; caller can
    // observe it via `ext.sleuth.diagnose` if needed.
    if (debugUrl != null) {
      try {
        await bridge.connect(Uri.parse(debugUrl));
        _lastWsUri = Uri.parse(debugUrl);
        _launchMode = 'attach';
        _mode = 'unknown';
        _state = AppSessionState.ready;
        return status;
      } catch (e) {
        if (_detachRequested) return status;
        _state = AppSessionState.error;
        _lastError = 'debugUrl connect failed: $e';
        return status;
      }
    }

    // Mobile-only scope check (Android + iOS). Pre-flight via flutter devices.
    if (device != null) {
      try {
        final devices = await listDevices(
          processFactory: _processFactory,
          flutterExecutable: _flutterExecutable,
        );
        final match = devices.firstWhere(
          (d) => d['id'] == device || d['name'] == device,
          orElse: () => const <String, Object?>{},
        );
        if (match.isNotEmpty && !isMobileFlutterDevice(match)) {
          _state = AppSessionState.error;
          final target = match['targetPlatform'] ?? match['category'];
          _lastError =
              'device $device (platform=$target) is not mobile; v0.2.0 supports android + ios only';
          return status;
        }
      } catch (_) {
        // device probe failed — proceed; flutter attach will report
      }
    }

    final args = <String>['attach', '--machine'];
    if (device != null) args.addAll(['-d', device]);
    try {
      _child = await _processFactory(_flutterExecutable, args);
    } catch (e) {
      _state = AppSessionState.error;
      _lastError = 'failed to spawn flutter: $e';
      return status;
    }

    // Sync-attached completers — guarantees we observe daemon.connected /
    // app.debugPort / app.stop even if they arrive before any await.
    final connected = Completer<DaemonConnectedEvent>();
    final debugPortOrStop = Completer<DaemonEvent>();
    final events = StreamController<DaemonEvent>.broadcast();
    _eventsForSession = events;

    final parser = DaemonParser();
    final responses = StreamController<DaemonRpcResponse>.broadcast();
    _eventSub = parser.parse(_child!.stdout).listen((event) {
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
      }
      // Sync-on-arrival resolution — broadcast subscribers can't lose events.
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
    });

    _rpc = DaemonRpc(
      stdin: _child!.stdin,
      responses: responses.stream,
      logger: _logger,
    );
    _stderrSub = _child!.stderr.transform(utf8.decoder).listen((line) {
      if (gen != _sessionGeneration) return; // stale session
      _logger?.add('[flutter] $line');
    });

    // Crashed flutter must not leave the session hung. Generation guard
    // stops a stale listener from a prior attach flipping a fresh session.
    unawaited(_child!.exitCode.then((code) {
      if (gen != _sessionGeneration) return;
      if (_state != AppSessionState.detaching &&
          _state != AppSessionState.idle) {
        _state = AppSessionState.error;
        _lastError = 'flutter daemon exited unexpectedly (code $code)';
      }
    }));

    try {
      final connectedEvent = await connected.future.timeout(_attachTimeout);
      if (!isAtLeastVersion(connectedEvent.version, minDaemonProtocolVersion)) {
        await _cleanup();
        if (_detachRequested) return status;
        _state = AppSessionState.error;
        _lastError =
            'unsupported flutter daemon ${connectedEvent.version} (min: $minDaemonProtocolVersion)';
        return status;
      }
      _logger?.add('daemon connected: version=${connectedEvent.version}');

      final outcome = await debugPortOrStop.future.timeout(_attachTimeout);

      if (outcome is AppStopEvent) {
        await _cleanup();
        if (_detachRequested) return status;
        _state = AppSessionState.error;
        _lastError =
            'flutter daemon emitted app.stop during attach — release-mode '
            'build or app exited before VM service was available';
        return status;
      }
      final debugPort = outcome as AppDebugPortEvent;
      _appId = debugPort.appId;
      _deviceId ??= device;
      _launchMode ??= 'attach';
      _mode ??= 'debug';

      await bridge.connect(Uri.parse(debugPort.wsUri));
      _lastWsUri = Uri.parse(debugPort.wsUri);
      _state = AppSessionState.ready;
      return status;
    } on TimeoutException {
      await _cleanup();
      if (_detachRequested) return status;
      _state = AppSessionState.error;
      _lastError = 'no daemon.connected / app.debugPort within '
          '${_attachTimeout.inSeconds}s — is the Flutter app running on the device?';
      return status;
    } on VmBridgeException catch (e) {
      await _cleanup();
      if (_detachRequested) return status;
      _state = AppSessionState.error;
      _lastError = 'bridge connect failed: ${e.message}';
      return status;
    }
  }

  /// iOS-direct attach. Drives [IosAttacher] (devicectl launch →
  /// Bonjour → iproxy → wsUri) then connects the bridge — one MCP
  /// round-trip.
  ///
  /// [IosAttachException] is rethrown to the tool handler (which maps
  /// to a typed envelope); `_state` is set to `error` + `_lastError`
  /// before rethrow so `app_status` reflects the failure.
  ///
  /// Concurrent calls serialise via [_iosAttachInFlight]; second call
  /// waits or rejects via [StateError] when `failFastOnConcurrent`.
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
    if (_state != AppSessionState.idle && _state != AppSessionState.error) {
      throw StateError(
        'already attached or attaching (state=${_state.name}); '
        'call detach_app first',
      );
    }
    final inFlight = _iosAttachInFlight;
    if (inFlight != null && !inFlight.isCompleted) {
      if (failFastOnConcurrent) {
        throw StateError('attach_in_progress: another iOS attach is running');
      }
      await inFlight.future;
    }
    final completer = Completer<void>();
    _iosAttachInFlight = completer;

    _state = AppSessionState.attaching;
    _lastError = null;
    _detachRequested = false;
    final gen = ++_sessionGeneration;

    final effectiveAttacher = attacher ?? IosAttacher();
    // Original connect error from the attempt that triggered recovery;
    // surfaced if recovery finds no live port. Outside the inner try so
    // the IosAttachException catch can read it.
    String? recoveryConnectError;
    try {
      try {
        var attempt = 0;
        var useForceRelaunch = forceRelaunch;
        var retryExcludePorts = const <int>{};
        // Gates recovery initiation only; per-attempt inner timeouts bound
        // actual runtime.
        final attachStopwatch = Stopwatch()..start();
        while (true) {
          attempt++;
          final result = await effectiveAttacher.attach(
            udid: udid,
            bundle: bundle,
            authOverride: authOverride,
            transportOverride: transportOverride,
            onProgress: onProgress,
            cancelSignal: cancelSignal,
            forceRelaunch: useForceRelaunch,
            excludePorts: retryExcludePorts,
          );
          if (gen != _sessionGeneration) {
            // Detach raced us — release the teardown immediately.
            await result.teardown();
            return status;
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
            _iosTeardown = null;
            _iosTransport = null;
            _iosWsUri = null;
            _deviceId = null;
            _launchMode = null;
            _mode = null;
            if (_detachRequested) return status;
            _state = AppSessionState.error;
            _lastError = 'ios_vmservice_unreachable: bridge connect timed '
                'out after ${bridgeConnectTimeout.inSeconds}s. Common cause: '
                'half-open VM service that accepts the WS handshake but '
                'never returns `getVM`. Swipe the app off the device and '
                're-run, or rebuild the profile binary.';
            return status;
          } catch (e) {
            final message = '$e';
            // Stale-mDNS recovery: selection landed on a dead cached port
            // (iOS retains the prior session's record ~1-2 min). Retry once,
            // re-resolving with that port excluded so a coexisting live
            // announcement wins.
            final deadPort = result.selected.port;
            final canRecover = attempt == 1 &&
                attachStopwatch.elapsed < attachBudget &&
                _isStaleRecoverable(message);
            await result.teardown();
            _iosTeardown = null;
            _iosTransport = null;
            _iosWsUri = null;
            _deviceId = null;
            _launchMode = null;
            _mode = null;
            if (_detachRequested) return status;
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
          _lastWsUri = Uri.parse(result.wsUri);
          _state = AppSessionState.ready;
          return status;
        }
      } on IosAttachException catch (e) {
        // Record state before rethrow so a follow-up `app_status`
        // reports `state: error` + `lastError` instead of a wedged-
        // looking `attaching`. Next `attach_app` recovers automatically.
        if (gen == _sessionGeneration && !_detachRequested) {
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
    } finally {
      if (!completer.isCompleted) completer.complete();
    }
  }

  Future<AppStatusPayload> hotReload() => _restart(fullRestart: false);

  Future<AppStatusPayload> hotRestart() => _restart(fullRestart: true);

  Future<AppStatusPayload> _restart({required bool fullRestart}) async {
    if (_state != AppSessionState.ready) {
      throw StateError(
        'not attached (state=${_state.name}); call attach_app first',
      );
    }
    final rpc = _rpc;
    final appId = _appId;
    if (rpc == null || appId == null) {
      // debugUrl sessions are connect-only — no daemon channel exists to
      // dispatch the app.restart RPC. Return a structured error rather
      // than throwing so the tool wrapper surfaces an actionable message.
      _state = AppSessionState.error;
      _lastError = 'hot ${fullRestart ? "restart" : "reload"} requires a '
          'daemon-spawn attach (attach_app device: …); debugUrl sessions '
          'are connect-only';
      return status;
    }
    _state = AppSessionState.restarting;
    // Auto-resume window exceeds RPC timeout so dispatch can't unpause
    // mid-restart against a half-rebuilt bridge.
    final timeout = fullRestart ? _hotRestartTimeout : _hotReloadTimeout;
    server.pauseDispatch(
        autoResumeAfter: timeout + const Duration(seconds: 30));
    // Settle completer armed pre-RPC: daemon can emit app.started in
    // the same event-loop turn as the response; lazy firstWhere misses it.
    final settleCompleter = fullRestart ? Completer<DaemonEvent>() : null;
    _restartSettleCompleter = settleCompleter;
    _restartDebugPort = null;
    try {
      await server.awaitPendingDrain();
      DaemonRpcResponse rpcResponse;
      try {
        rpcResponse = await rpc.call(
          'app.restart',
          {'appId': appId, 'fullRestart': fullRestart},
          timeout: timeout,
        );
      } on DaemonRpcTimeoutException catch (e) {
        _state = AppSessionState.error;
        _lastError = 'hot ${fullRestart ? 'restart' : 'reload'} '
            'timed out after ${e.timeout.inSeconds}s';
        return status;
      } on DaemonRpcException catch (e) {
        _state = AppSessionState.error;
        _lastError = 'hot ${fullRestart ? 'restart' : 'reload'} '
            'rpc failed: ${e.message}';
        return status;
      }
      if (rpcResponse.isError) {
        _state = AppSessionState.error;
        _lastError = 'hot ${fullRestart ? 'restart' : 'reload'} '
            'rpc error: ${rpcResponse.error}';
        return status;
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
          final reconnectUri =
              newDebugPort != null ? Uri.parse(newDebugPort.wsUri) : _lastWsUri;
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
        _lastError = 'bridge refresh failed post-restart: ${e.message}';
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

  @override
  Future<void> detach() async {
    if (_state == AppSessionState.idle) {
      return;
    }
    _detachRequested = true;
    _state = AppSessionState.detaching;
    try {
      final rpc = _rpc;
      final appId = _appId;
      if (rpc != null && appId != null) {
        try {
          await rpc.call(
            'app.detach',
            {'appId': appId},
            timeout: const Duration(seconds: 5),
          );
        } catch (_) {/* daemon may be dead; cleanup proceeds */}
      }
    } finally {
      await _cleanup();
      _state = AppSessionState.idle;
      _appId = null;
      _deviceId = null;
      _launchMode = null;
      _mode = null;
      _lastWsUri = null;
    }
  }

  Future<void> _cleanup() async {
    // Bump generation so any in-flight stderr / exitCode listener bails.
    _sessionGeneration++;
    _restartSettleCompleter = null;
    await _eventSub?.cancel();
    _eventSub = null;
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
    if (child != null) {
      child.kill(ProcessSignal.sigterm);
      try {
        await child.exitCode.timeout(const Duration(seconds: 5));
      } on TimeoutException {
        child.kill(ProcessSignal.sigkill);
      }
      // Orphan reaping is best-effort: Process.start doesn't setpgid(),
      // so we rely on flutter daemon's own SIGTERM teardown of subprocesses.
    }
    _child = null;
    try {
      await bridge.disconnect().timeout(const Duration(seconds: 2));
    } on TimeoutException {
      // Bridge disconnect can hang if the device-side VM service has
      // crashed or the iproxy tunnel is half-open. Bound the wait so
      // the iOS teardown below still gets a chance to release the
      // iproxy child + pidfile.
    } catch (_) {/* best effort */}
    // iOS-direct teardown — kill iproxy + remove pidfile. 6s outer
    // must exceed inner 3s grace + SIGKILL + pidfile-delete; otherwise
    // a back-to-back `attach_app` races the still-bound port.
    final iosTeardown = _iosTeardown;
    if (iosTeardown != null) {
      try {
        await iosTeardown().timeout(const Duration(seconds: 6));
      } on TimeoutException {
        // iproxy refused to exit within budget; SIGKILL fallback is
        // already wired inside the teardown callback.
      } catch (_) {/* best effort */}
      _iosTeardown = null;
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
        return 'ios_vmservice_busy: $exceptionMessage — swipe the app off '
            'the device and re-run, or rebuild the profile binary';
      case _BridgeConnectFailure.devicePortDead:
        return 'ios_vmservice_unreachable: $exceptionMessage — the iproxy '
            'tunnel is open but nothing is listening on the device side. '
            'Common cause: stale Bonjour cache pinned a dead port. Wait '
            "~30s for mDNS to clear or swipe the app and re-run.";
      case _BridgeConnectFailure.wirelessUnreachable:
        return 'ios_vmservice_unreachable: $exceptionMessage — wireless '
            "attach can't reach the device. Common causes: iOS Local "
            'Network permission denied for the launching app, the host '
            'and device are on different Wi-Fi networks, or the device '
            'left the network. Switch to USB (transport: wired) or '
            'grant Local Network permission and retry.';
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
