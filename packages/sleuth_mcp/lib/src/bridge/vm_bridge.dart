import 'dart:async';

import 'package:meta/meta.dart';
import 'package:synchronized/synchronized.dart';
import 'package:vm_service/vm_service.dart' as vm;
import 'package:vm_service/vm_service_io.dart';

import 'app_log_stream.dart';

/// Bridges MCP tool handlers to the running app's VM service.
///
/// `Response.json` is the parsed sleuth envelope
/// `{connectionMode, schemaVersion, sessionUuid, data|error}` directly —
/// vm_service inlines the extension result string into the JSON-RPC
/// `result` field, no manual decode needed.
abstract class VmBridge {
  Future<bool> connect(Uri wsUri);

  /// Returns the inner sleuth envelope as a `Map`. Throws
  /// [VmBridgeException] on transport / decode failure, and
  /// [SessionChangedException] when the responding session's UUID differs
  /// from the baseline. A session change is reported once: the bridge then
  /// moves its baseline to the new session, so the next call succeeds.
  Future<Map<String, Object?>> callExtension(
    String method, {
    Map<String, dynamic> args = const <String, dynamic>{},
  });

  /// UUID captured from the first `ext.sleuth.diagnose` call at [connect]
  /// time. Used to detect hot-restart of the target app.
  String? get baselineSessionUuid;

  /// Envelope from the connect-time `ext.sleuth.diagnose` call. Tool
  /// handlers can read `data.packageVersion` from here without paying a
  /// second round-trip.
  Map<String, Object?>? get lastDiagnoseEnvelope;

  /// Re-fetches `ext.sleuth.diagnose` without disposing the service.
  /// Updates the last-diagnose envelope and bumps `baselineGeneration`.
  ///
  /// Throws [SessionChangedException] on sessionUuid rotation unless
  /// [acceptSessionRotation] is true. Callers that orchestrated the
  /// rotation (hot-restart) opt in; everyone else gets the safety net
  /// that `callExtension` relies on.
  Future<void> refreshBaseline({bool acceptSessionRotation = false});

  /// Monotonic counter incremented on every successful baseline update
  /// (connect or refreshBaseline). Resources key their caches on this
  /// to drop stale envelopes after a hot-restart.
  int get baselineGeneration;

  bool get isConnected;

  Future<void> disconnect();
}

/// What went wrong in a [VmBridgeException], so a caller can say what to do
/// next.
enum VmBridgeErrorKind {
  /// No app is connected, or a connect is still running or was refused.
  notConnected,

  /// The app did not answer within the bridge's per-call timeout. The
  /// connection stays open.
  timeout,

  /// Too many earlier calls are still unanswered, so the bridge did not send
  /// this one. The connection stays open.
  busy,

  /// The version-skew validator refused the app. The bridge is disconnected
  /// and the message starts with the refusal code (`version_skew_…`).
  refused,

  /// Any other failure.
  other,
}

/// Connect / dispatch failure not attributable to a session change.
class VmBridgeException implements Exception {
  VmBridgeException(
    this.message, {
    this.kind = VmBridgeErrorKind.other,
    this.timeout,
  });
  final String message;

  /// The failure class. Defaults to [VmBridgeErrorKind.other].
  final VmBridgeErrorKind kind;

  /// The deadline that passed, set when [kind] is [VmBridgeErrorKind.timeout].
  final Duration? timeout;

  @override
  String toString() => 'VmBridgeException: $message';
}

/// Converts a VM service URI to the WebSocket form that
/// `vmServiceConnectUri` needs.
///
/// `flutter run` and `flutter attach` print an http URI such as
/// `http://127.0.0.1:50000/AbCd=/`, which becomes
/// `ws://127.0.0.1:50000/AbCd=/ws`. An https URI becomes wss, and a ws or wss
/// URI without the `/ws` path gets it. Throws [FormatException] for any other
/// scheme or for a URI without a host.
Uri normalizeVmServiceUri(Uri uri) {
  final String scheme;
  switch (uri.scheme.toLowerCase()) {
    case 'http':
    case 'ws':
      scheme = 'ws';
    case 'https':
    case 'wss':
      scheme = 'wss';
    default:
      throw FormatException(
        'expected an http, https, ws or wss VM service URI, got "$uri"',
      );
  }
  if (uri.host.isEmpty) {
    throw FormatException('the VM service URI has no host: "$uri"');
  }
  var path = uri.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  if (!path.endsWith('/ws')) path = '$path/ws';
  return uri.replace(scheme: scheme, path: path);
}

/// Per-call bridge timeout for tools bounded by [toolTimeout].
///
/// It is shorter than [toolTimeout] (by a fifth, at most 2 seconds) so the
/// bridge reports a slow app call itself, naming the extension, before the
/// server's generic tool timeout fires.
Duration bridgeCallTimeoutWithin(Duration toolTimeout) {
  final fifth = toolTimeout ~/ 5;
  const maxMargin = Duration(seconds: 2);
  return toolTimeout - (fifth > maxMargin ? maxMargin : fifth);
}

/// The target app's `sessionUuid` differs from the baseline. Indicates a
/// hot-restart or a different app at the same URI.
class SessionChangedException implements Exception {
  SessionChangedException({required this.baseline, required this.current});
  final String baseline;
  final String current;
  @override
  String toString() =>
      'SessionChangedException: baseline=$baseline current=$current';
}

/// Validator invoked once per successful connect/reconnect, after the
/// bridge has read the connect-time `ext.sleuth.diagnose` envelope.
///
/// Returning a non-null string signals "refuse this connection" — the
/// bridge disconnects in place and throws [VmBridgeException] carrying
/// the returned message. Returning null lets the connect proceed.
///
/// The bridge layer owns refusal because every path that opens a real
/// WebSocket — `connect`, `_ensureReconnected`, future re-establish hooks
/// — funnels through `_connectUnlocked`. Putting the chokepoint at the
/// tool layer would let a transport-close reconnect serve an
/// incompatible app between tool calls.
typedef VersionSkewValidator =
    Future<String?> Function(Map<String, Object?> diagnoseEnvelope);

/// Production [VmBridge] over a real WebSocket VM service.
///
/// Connect / disconnect / reconnect serialize via [Lock] so concurrent
/// dispatches don't observe half-initialized state. `callServiceExtension`
/// itself runs outside the lock — vm_service handles concurrent calls.
class RealVmBridge implements VmBridge, AppLogSource {
  RealVmBridge({
    this.callTimeout = const Duration(seconds: 8),
    this.maxUnansweredCalls = 8,
    Sink<String>? logger,
    String? targetIsolateIdOverride,
    VersionSkewValidator? versionSkewValidator,
  }) : _logger = logger,
       _targetIsolateIdOverride = targetIsolateIdOverride,
       _versionSkewValidator = versionSkewValidator;

  /// How long one extension call may wait for the app. A call that passes
  /// it fails with [VmBridgeErrorKind.timeout] and the connection stays open.
  final Duration callTimeout;

  /// How many timed-out calls may still wait for an answer on the current
  /// connection. vm_service keeps each one until the app answers or the
  /// connection closes, so at this many the bridge refuses new calls with
  /// [VmBridgeErrorKind.busy] instead of piling up more. A new connect
  /// starts the count again.
  final int maxUnansweredCalls;

  final Sink<String>? _logger;

  /// Bypasses [pickMainIsolate] when set. In-process tests use it to bind
  /// the bridge to the test isolate when sibling isolates share the host VM.
  final String? _targetIsolateIdOverride;

  /// Invoked after every successful connect/reconnect with the connect-time
  /// diagnose envelope. Non-null return string aborts the connect with
  /// [VmBridgeException] (bridge is fully disconnected before the throw).
  final VersionSkewValidator? _versionSkewValidator;

  vm.VmService? _service;
  String? _mainIsolateId;
  String? _baselineSessionUuid;
  Map<String, Object?>? _lastDiagnoseEnvelope;
  Uri? _wsUri;
  int _baselineGeneration = 0;
  final Lock _connectLock = Lock();
  Future<void>? _reconnectInFlight;

  /// Bumped whenever [_service] is replaced or cleared, so an answer that
  /// arrives for an older connection does not touch [_unanswered].
  int _serviceGeneration = 0;

  /// Timed-out calls on the current connection that the app has not
  /// answered yet. Bounded by [maxUnansweredCalls].
  int _unanswered = 0;

  /// Timed-out calls on the current connection that still wait for an
  /// answer.
  @visibleForTesting
  int get unansweredCalls => _unanswered;

  /// Test seam: invoked once inside `_connectUnlocked` AFTER the
  /// `_validated` / `_service` / `_mainIsolateId` / `_wsUri` unpublish,
  /// BEFORE `await prior.dispose()`. Lets tests assert the gate is shut
  /// before the dispose suspension point opens a race window.
  @visibleForTesting
  void Function(RealVmBridge bridge)? debugPreDisposeProbe;

  /// Sibling of [debugPreDisposeProbe], wired into `_disconnectUnlocked`.
  /// Fires AFTER the disconnect-path unpublish (gate down; `_service` /
  /// `_mainIsolateId` / `_baselineSessionUuid` / `_lastDiagnoseEnvelope`
  /// / `_wsUri` cleared) but BEFORE `await prior.dispose()`. Kept
  /// separate so reconnect-dispose doesn't fire the disconnect probe.
  @visibleForTesting
  void Function(RealVmBridge bridge)? debugDisconnectPreDisposeProbe;

  /// Flipped to `true` only after `_connectUnlocked` has finished isolate
  /// discovery, fetched the connect-time diagnose envelope, AND passed
  /// any wired [_versionSkewValidator]. Reset to `false` in
  /// `_disconnectUnlocked` and at the top of each `_connectUnlocked`
  /// run. `callExtension` runs lock-free, so this flag is the only thing
  /// that prevents a concurrent dispatch from observing
  /// `isConnected == true` between the diagnose-fetch and validator
  /// completion windows.
  bool _validated = false;

  @override
  String? get baselineSessionUuid => _baselineSessionUuid;

  @override
  Map<String, Object?>? get lastDiagnoseEnvelope => _lastDiagnoseEnvelope;

  @override
  int get baselineGeneration => _baselineGeneration;

  @override
  bool get isConnected =>
      _service != null && _mainIsolateId != null && _validated;

  /// Prefers `name == 'main'`, then `startsWith('main')`, falls back to
  /// the first entry. Iteration follows the input order — a sorted
  /// fallback breaks apps where multiple isolates share the name.
  @visibleForTesting
  static vm.IsolateRef pickMainIsolate(List<vm.IsolateRef> isolates) {
    for (final i in isolates) {
      if (i.name == 'main') return i;
    }
    for (final i in isolates) {
      if ((i.name ?? '').startsWith('main')) return i;
    }
    return isolates.first;
  }

  @override
  Future<bool> connect(Uri wsUri) {
    // Initial connect: no prior baseline exists, so session-rotation
    // detection is a no-op. `_ensureReconnected` passes `false` to
    // enforce hot-restart detection on the retry path.
    return _connectLock.synchronized(
      () => _connectUnlocked(wsUri, acceptSessionRotation: true),
    );
  }

  Future<bool> _connectUnlocked(
    Uri requestedUri, {
    required bool acceptSessionRotation,
  }) async {
    final Uri wsUri;
    try {
      wsUri = normalizeVmServiceUri(requestedUri);
    } on FormatException catch (e) {
      throw VmBridgeException('invalid VM service URI: ${e.message}');
    }
    // Lower the gate AND unpublish refs BEFORE awaiting `prior.dispose()`.
    // Dispose is an async suspension point; if `_validated` / `_service`
    // / `_mainIsolateId` stay populated across it, a lock-free
    // `callExtension` racing the reconnect can pass the validated gate,
    // dispatch against the prior service, then see it torn down mid-call
    // (`_TransportClosed`) and trigger `_ensureReconnected` against a
    // stale `_wsUri`. Clearing first forces concurrent dispatchers into
    // the `bridge not yet validated` refusal. `_wsUri` is set to the NEW
    // target so racing reconnects coalesce via `_reconnectInFlight`.
    _validated = false;
    final prior = _service;
    _service = null;
    _serviceGeneration++;
    _unanswered = 0;
    _mainIsolateId = null;
    _wsUri = wsUri;
    assert(() {
      final probe = debugPreDisposeProbe;
      if (probe != null) probe(this);
      return true;
    }());
    if (prior != null) {
      try {
        await prior.dispose();
      } catch (e) {
        _logger?.add('prior service dispose failed: $e');
      }
    }
    try {
      _service = await vmServiceConnectUri(
        wsUri.toString(),
      ).timeout(const Duration(seconds: 5));
    } catch (e) {
      throw VmBridgeException('failed to connect: $e');
    }
    // Single try/catch wraps every step after the service is published.
    // Any throw on the bootstrap path (getVM, diagnose, validator,
    // session-rotation guard) must collapse the bridge before surfacing,
    // otherwise `_service` / `_mainIsolateId` linger and a later
    // `_callExtensionRaw` sees them populated but `_validated == false`.
    try {
      // Post-hot-restart, flutter daemon may ACK `app.restart` before
      // the new main isolate finishes registering. Retry until isolate
      // appears or the budget expires (Android emulator full-restart
      // can take >5s). Caller's responsibility to pass a LIVE wsUri —
      // if the underlying VM service has rotated to a new port,
      // retrying against the stale URI returns empty isolates
      // indefinitely.
      List<vm.IsolateRef> isolates = const <vm.IsolateRef>[];
      for (var attempt = 0; attempt < 80; attempt++) {
        // Per-call timeout: the 80x retry only counts attempts that
        // COMPLETE, so a half-open VM service that never returns
        // `getVM` would otherwise hang forever.
        final vmInfo = await _service!.getVM().timeout(
          const Duration(seconds: 3),
          onTimeout: () => throw VmBridgeException(
            'getVM bootstrap RPC timed out after 3s — VM service may '
            'be half-open (WS accepted but RPC never returns)',
          ),
        );
        isolates = vmInfo.isolates ?? <vm.IsolateRef>[];
        if (isolates.isNotEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      if (isolates.isEmpty) {
        throw VmBridgeException(
          'no isolates on target VM service after 20s wait',
        );
      }
      final override = _targetIsolateIdOverride;
      if (override != null) {
        _mainIsolateId = override;
      } else {
        final main = pickMainIsolate(isolates);
        _mainIsolateId = main.id;
        if (_mainIsolateId == null) {
          throw VmBridgeException('main isolate has no id');
        }
      }
      // Bootstrap call: the validator + session-rotation guard consume
      // this envelope. `bypassValidatedGate: true` because `_validated`
      // is intentionally false here — we're producing the data that
      // will flip it.
      final diag = await _callExtensionRaw(
        'ext.sleuth.diagnose',
        bypassValidatedGate: true,
      );
      await _applyBaseline(diag, acceptSessionRotation: acceptSessionRotation);
      _listenForAppLogs(_service!);
      return true;
    } catch (_) {
      // Collapse before rethrow so `isConnected` stays false and any
      // subsequent `_callExtensionRaw` sees `_service == null` (the
      // pre-existing "not connected" path).
      await _disconnectUnlocked();
      rethrow;
    }
  }

  @override
  Future<void> refreshBaseline({bool acceptSessionRotation = false}) {
    return _connectLock.synchronized(
      () => _refreshBaselineUnlocked(acceptSessionRotation),
    );
  }

  Future<void> _refreshBaselineUnlocked(bool acceptSessionRotation) async {
    if (_service == null || _mainIsolateId == null) {
      throw VmBridgeException(
        'cannot refresh because the bridge is disconnected',
        kind: VmBridgeErrorKind.notConnected,
      );
    }
    // Lower the gate BEFORE the diagnose await. `_applyBaseline` lowers
    // it again, but only AFTER the round-trip resolves; without this
    // pre-await lower a lock-free `callExtension` racing the refresh
    // would pass the validated check and dispatch against a
    // soon-to-be-revalidated target. The redundant re-lower inside
    // `_applyBaseline` protects a different suspension window.
    _validated = false;
    try {
      // `_applyBaseline` lowers the gate before re-running the
      // validator, so the diagnose call itself must bypass the gate.
      final diag = await _callExtensionRaw(
        'ext.sleuth.diagnose',
        bypassValidatedGate: true,
      );
      await _applyBaseline(diag, acceptSessionRotation: acceptSessionRotation);
    } catch (_) {
      // `_applyBaseline` disconnects on its own refusal paths
      // (validator + rotation), but a malformed envelope or transport
      // exception bypasses that cleanup. Tear down fully so callers see
      // "not connected" instead of a half-valid bridge that the next
      // refresh would inherit.
      if (_service != null) {
        try {
          await _disconnectUnlocked();
        } catch (_) {
          /* best effort — surfaced original error matters more */
        }
      }
      rethrow;
    }
  }

  /// Single chokepoint for publishing a fresh diagnose envelope as the
  /// new baseline. Connect, reconnect, and refresh all route through
  /// here so the version-skew validator + session-rotation guard cover
  /// every baseline mutation uniformly.
  ///
  /// Lowers `_validated` BEFORE running the validator so concurrent
  /// dispatchers cannot observe a stale "ready" bridge while validation
  /// is in flight against a newly-fetched envelope. Refusal disconnects
  /// and throws BEFORE publishing baseline.
  ///
  /// [acceptSessionRotation] — when false, throws
  /// [SessionChangedException] on sessionUuid mismatch.
  Future<void> _applyBaseline(
    Map<String, Object?> diag, {
    required bool acceptSessionRotation,
  }) async {
    final uuid = diag['sessionUuid'];
    if (uuid is! String) {
      throw VmBridgeException(
        'ext.sleuth.diagnose returned no sessionUuid — is sleuth attached?',
      );
    }
    final priorBaseline = _baselineSessionUuid;
    // Lower the gate BEFORE running the validator. On the refresh path
    // the bridge is already validated; without this, a concurrent
    // dispatcher could observe `isConnected == true` while the
    // validator awaits a newly-fetched envelope.
    _validated = false;
    // Validator runs BEFORE the session-rotation check so a skew
    // refusal surfaces first (more actionable). Refusal collapses the
    // connection in place; rotation throws.
    final validator = _versionSkewValidator;
    if (validator != null) {
      final refusal = await validator(diag);
      if (refusal != null) {
        await _disconnectUnlocked();
        throw VmBridgeException(refusal, kind: VmBridgeErrorKind.refused);
      }
    }
    if (!acceptSessionRotation &&
        priorBaseline != null &&
        uuid != priorBaseline) {
      await _disconnectUnlocked();
      throw SessionChangedException(baseline: priorBaseline, current: uuid);
    }
    _baselineSessionUuid = uuid;
    _lastDiagnoseEnvelope = diag;
    _baselineGeneration++;
    _validated = true;
  }

  @override
  Future<Map<String, Object?>> callExtension(
    String method, {
    Map<String, dynamic> args = const <String, dynamic>{},
  }) async {
    // Per-call retry budget so concurrent transport-close callers each get
    // their own retry instead of sharing a per-bridge flag.
    var retriesRemaining = 1;
    Map<String, Object?> inner;
    while (true) {
      try {
        inner = await _callExtensionRaw(method, args: args);
        break;
      } on _TransportClosed {
        if (retriesRemaining == 0 || _wsUri == null) rethrow;
        retriesRemaining--;
        await _ensureReconnected();
      }
    }
    final uuid = inner['sessionUuid'];
    final seen = _baselineSessionUuid;
    if (uuid is String && seen != null && uuid != seen) {
      // The app restarted (or another app answers at this URI). Report it
      // once, then follow the new session so the next call works.
      if (await _followSession(from: seen, to: uuid)) {
        throw SessionChangedException(baseline: seen, current: uuid);
      }
    }
    return inner;
  }

  /// Moves the baseline to the app's new session after a session change.
  ///
  /// Re-reads `ext.sleuth.diagnose` and runs the version-skew validator on
  /// it, so a restart into an incompatible sleuth version is still refused
  /// (that refusal disconnects the bridge and is rethrown). Any other
  /// failure keeps the connection and the old baseline, so the next call
  /// tries again.
  ///
  /// Returns false when a concurrent call already moved the baseline to
  /// [to]: the caller's result then belongs to the current session and
  /// needs no report. Returns true otherwise, and the caller reports the
  /// change.
  Future<bool> _followSession({required String from, required String to}) {
    return _connectLock.synchronized(() async {
      final current = _baselineSessionUuid;
      if (current == to) return false;
      if (current != from || _service == null) return true;
      // The gate stays up during the diagnose round trip: a concurrent call
      // that gets an answer from the new session sees the same mismatch and
      // waits on this lock, so it never returns data the validator has not
      // checked. `_applyBaseline` lowers the gate while the validator runs.
      final service = _service;
      try {
        final diag = await _callExtensionRaw(
          'ext.sleuth.diagnose',
          bypassValidatedGate: true,
        );
        await _applyBaseline(diag, acceptSessionRotation: true);
      } catch (e) {
        if (e is VmBridgeException && e.kind == VmBridgeErrorKind.refused) {
          rethrow;
        }
        // Keep the connection and the old baseline: the next call tries
        // again, or reconnects through `_ensureReconnected` after a
        // transport close.
        _logger?.add('could not follow the new session: $e');
        if (identical(_service, service)) _validated = true;
      }
      return true;
    });
  }

  /// Test-only handle on the same reconnect path `callExtension` takes
  /// when it observes a `_TransportClosed`. Production tests can't
  /// cleanly trigger a transport close while keeping the WebSocket
  /// alive enough to retry, so this exposes the reconnect step
  /// directly. Surfaces `SessionChangedException` when the post-
  /// reconnect diagnose envelope's `sessionUuid` no longer matches
  /// the prior baseline — the hot-restart detection contract the
  /// public `callExtension` retry path relies on.
  @visibleForTesting
  Future<void> debugSimulateReconnect() => _ensureReconnected();

  /// Coalesces concurrent transport-close retries onto one reconnect.
  Future<void> _ensureReconnected() {
    final inFlight = _reconnectInFlight;
    if (inFlight != null) return inFlight;
    final wsUri = _wsUri;
    if (wsUri == null) {
      return Future.error(VmBridgeException('no wsUri for reconnect'));
    }
    // Reconnect path: a prior baseline exists. If the new socket
    // belongs to a different sleuth session (hot-restart / different
    // app at the same URI), surface SessionChangedException so the
    // caller can decide whether to recover. Caller-initiated rotations
    // route through `refreshBaseline(acceptSessionRotation: true)`.
    final future = _connectLock.synchronized(
      () => _connectUnlocked(wsUri, acceptSessionRotation: false),
    );
    _reconnectInFlight = future.whenComplete(() {
      _reconnectInFlight = null;
    });
    return _reconnectInFlight!;
  }

  Future<Map<String, Object?>> _callExtensionRaw(
    String method, {
    Map<String, dynamic> args = const <String, dynamic>{},
    bool bypassValidatedGate = false,
  }) async {
    final service = _service;
    final isolateId = _mainIsolateId;
    if (service == null || isolateId == null) {
      throw VmBridgeException(
        'not connected to an app',
        kind: VmBridgeErrorKind.notConnected,
      );
    }
    // Lock-free callers must wait until `_connectUnlocked` finishes
    // validation. The only legitimate bypass is the bootstrap
    // diagnose call inside `_connectUnlocked` itself — it PRODUCES
    // the envelope the validator consumes.
    if (!bypassValidatedGate && !_validated) {
      throw VmBridgeException(
        'the connection to the app is not yet validated: a connect is '
        'still running, or it was refused',
        kind: VmBridgeErrorKind.notConnected,
      );
    }
    if (_unanswered >= maxUnansweredCalls) {
      throw VmBridgeException(
        '$_unanswered earlier calls to the app are still unanswered, so '
        '$method was not sent',
        kind: VmBridgeErrorKind.busy,
      );
    }
    final generation = _serviceGeneration;
    Future<vm.Response>? call;
    vm.Response response;
    try {
      call = service.callServiceExtension(
        method,
        isolateId: isolateId,
        args: args,
      );
      response = await call.timeout(callTimeout);
    } on TimeoutException {
      // Only `call.timeout` throws this, so `call` is set.
      _trackUnanswered(call!, generation);
      throw VmBridgeException(
        'the app did not answer $method within '
        '${callTimeout.inMilliseconds} ms',
        kind: VmBridgeErrorKind.timeout,
        timeout: callTimeout,
      );
    } on vm.RPCError catch (e) {
      // vm_service raises this RPCError when the socket closes or the
      // service is dispose()d mid-call — transport state, not an
      // extension rejection, so route into the reconnect path.
      final msg = e.message;
      if (msg.startsWith('Service connection disposed')) {
        throw _TransportClosed('$method against disposed service');
      }
      // Method-not-found on ext.sleuth.diagnose means the app didn't call
      // `Sleuth.track()`. Surface a clear actionable error rather than the
      // raw RPC message.
      if (e.code == vm.RPCErrorKind.kMethodNotFound.code &&
          method == 'ext.sleuth.diagnose') {
        throw VmBridgeException(
          'Sleuth package not initialized in target app — '
          'ensure Sleuth.track() is called in main()',
        );
      }
      throw VmBridgeException('$method rejected: $msg (code ${e.code})');
    } on vm.SentinelException catch (e) {
      throw VmBridgeException('$method against expired isolate: $e');
    } catch (e) {
      throw _TransportClosed('$method failed: $e');
    }
    final envelope = response.json;
    if (envelope == null) {
      throw VmBridgeException('$method returned null json');
    }
    return Map<String, Object?>.from(envelope);
  }

  /// Counts [call], whose caller timed out, until the app answers it or the
  /// connection it was sent on is replaced.
  void _trackUnanswered(Future<vm.Response> call, int generation) {
    _unanswered++;
    void settle() {
      if (generation == _serviceGeneration && _unanswered > 0) _unanswered--;
    }

    unawaited(
      call.then<void>((_) => settle(), onError: (Object _) => settle()),
    );
  }

  @override
  Future<void> disconnect() {
    return _connectLock.synchronized(_disconnectUnlocked);
  }

  Future<void> _disconnectUnlocked() async {
    // Lower the gate AND unpublish every observable bridge field BEFORE
    // awaiting `prior.dispose()`. Without this, a lock-free
    // `callExtension` racing the teardown could pass the validated gate,
    // observe `_TransportClosed` mid-call, and trigger
    // `_ensureReconnected` against the still-published `_wsUri` —
    // republishing the bridge after an explicit caller-requested
    // disconnect. Clearing `_wsUri` first makes `_ensureReconnected`
    // return `no wsUri for reconnect` instead of looping back into
    // `_connectUnlocked`.
    _validated = false;
    final prior = _service;
    _service = null;
    _serviceGeneration++;
    _unanswered = 0;
    _mainIsolateId = null;
    _baselineSessionUuid = null;
    _lastDiagnoseEnvelope = null;
    _wsUri = null;
    assert(() {
      final probe = debugDisconnectPreDisposeProbe;
      if (probe != null) probe(this);
      return true;
    }());
    if (prior != null) {
      try {
        await prior.dispose();
      } catch (e) {
        _logger?.add('service dispose failed: $e');
      }
    }
  }

  // App output from the VM service streams, read by the get_logs tool.

  final StreamController<AppLogLine> _appLogLines =
      StreamController<AppLogLine>.broadcast();
  final List<StreamSubscription<vm.Event>> _appLogSubscriptions = [];

  /// The connection whose `Stdout` stream the bridge listens to.
  vm.VmService? _appLogService;

  @override
  Stream<AppLogLine> get appLogLines => _appLogLines.stream;

  @override
  bool get appLogStreamsActive =>
      isConnected &&
      _appLogService != null &&
      identical(_appLogService, _service);

  /// Listens to the app's `Stdout`, `Stderr` and `Logging` streams on
  /// [service]. Runs after every successful connect, so a reconnect listens
  /// again on the new connection. A stream that cannot be listened to costs
  /// only its log lines, never the connection.
  void _listenForAppLogs(vm.VmService service) {
    for (final subscription in _appLogSubscriptions) {
      unawaited(subscription.cancel());
    }
    _appLogSubscriptions.clear();
    _appLogService = null;
    final decoder = VmLogEventDecoder(
      _appLogLines.add,
      resolveMessage: (isolateId, messageId) async {
        final object = await service.getObject(
          isolateId,
          messageId,
          count: maxAppLogLineLength,
        );
        return object is vm.Instance ? object.valueAsString : null;
      },
    );
    _appLogSubscriptions
      ..add(service.onStdoutEvent.listen((e) => decoder.onWrite('stdout', e)))
      ..add(service.onStderrEvent.listen((e) => decoder.onWrite('stderr', e)))
      ..add(service.onLoggingEvent.listen(decoder.onLogging));
    Future<bool> listen(String streamId) async {
      try {
        await service.streamListen(streamId).timeout(callTimeout);
        return true;
      } on vm.RPCError catch (e) {
        if (e.code == vm.RPCErrorKind.kStreamAlreadySubscribed.code) {
          return true;
        }
        _logger?.add('app log stream $streamId unavailable: $e');
        return false;
      } catch (e) {
        _logger?.add('app log stream $streamId unavailable: $e');
        return false;
      }
    }

    unawaited(() async {
      final listening = await Future.wait([
        listen(vm.EventStreams.kStdout),
        listen(vm.EventStreams.kStderr),
        listen(vm.EventStreams.kLogging),
      ]);
      if (listening.first && identical(_service, service)) {
        _appLogService = service;
      }
    }());
  }
}

class _TransportClosed implements Exception {
  _TransportClosed(this.message);
  final String message;
  @override
  String toString() => 'TransportClosed: $message';
}

/// Test-only fake that returns canned envelopes per extension name.
class FakeVmBridge implements VmBridge {
  FakeVmBridge({
    this.fakeSessionUuid = 'fake-session-uuid',
    Map<String, Map<String, Object?>> envelopes = const {},
    VersionSkewValidator? versionSkewValidator,
  }) : _envelopes = Map.of(envelopes),
       _baseline = fakeSessionUuid,
       _versionSkewValidator = versionSkewValidator;

  final String fakeSessionUuid;
  final Map<String, Map<String, Object?>> _envelopes;
  String _baseline;
  int _baselineGeneration = 0;
  bool _connected = false;
  bool _sessionDrifted = false;
  final VersionSkewValidator? _versionSkewValidator;
  final Map<String, Map<String, Object?> Function(Map<String, dynamic> args)>
  _responders = {};

  /// Every `callExtension` that reached an envelope, in order, with its
  /// args. Lets tests check what a handler asked the app for.
  final List<({String method, Map<String, dynamic> args})> callLog = [];

  /// The URI passed to the last [connect].
  Uri? lastConnectUri;

  /// Replace the canned envelope for a given extension name.
  void setEnvelope(String method, Map<String, Object?> envelope) {
    _envelopes[method] = envelope;
  }

  /// Answer [method] by calling [responder] with the call's args. Takes
  /// precedence over [setEnvelope] for that method.
  void setResponder(
    String method,
    Map<String, Object?> Function(Map<String, dynamic> args) responder,
  ) {
    _responders[method] = responder;
  }

  /// Force the next callExtension to throw a SessionChangedException.
  void simulateSessionChange(String newUuid) {
    _sessionDrifted = true;
    _baseline = newUuid;
  }

  final Map<String, Completer<void>> _extensionGates =
      <String, Completer<void>>{};

  /// Test seam: make the next `callExtension` for [method] suspend until the
  /// returned completer is completed. Lets a test hold a tool call in-flight
  /// while driving a concurrent message (e.g. a pipelined re-initialize).
  Completer<void> gateExtension(String method) {
    final gate = Completer<void>();
    _extensionGates[method] = gate;
    return gate;
  }

  @override
  String? get baselineSessionUuid => _baseline;

  @override
  Map<String, Object?>? get lastDiagnoseEnvelope =>
      _envelopes['ext.sleuth.diagnose'];

  @override
  int get baselineGeneration => _baselineGeneration;

  @override
  bool get isConnected => _connected;

  @override
  Future<bool> connect(Uri wsUri) async {
    lastConnectUri = wsUri;
    // Initial connect — no prior baseline exists, so session-rotation
    // detection is a no-op (matches RealVmBridge.connect semantics).
    final diag = _envelopes['ext.sleuth.diagnose'];
    await _applyBaseline(diag, acceptSessionRotation: true);
    return true;
  }

  @override
  Future<void> refreshBaseline({bool acceptSessionRotation = false}) async {
    if (!_connected) {
      throw VmBridgeException(
        'cannot refresh because the bridge is disconnected',
        kind: VmBridgeErrorKind.notConnected,
      );
    }
    final diag = _envelopes['ext.sleuth.diagnose'];
    await _applyBaseline(diag, acceptSessionRotation: acceptSessionRotation);
  }

  /// FakeVmBridge mirror of `RealVmBridge._applyBaseline`. Single
  /// chokepoint for connect + refresh so the validator + rotation
  /// guard cover every baseline mutation uniformly. Lowers the
  /// connected gate before running the validator (race parity).
  Future<void> _applyBaseline(
    Map<String, Object?>? diag, {
    required bool acceptSessionRotation,
  }) async {
    // Mirror RealVmBridge race semantics: do NOT keep `_connected ==
    // true` across the validator await on the refresh path. Concurrent
    // `callExtension` racing the validator would observe an unvalidated
    // bridge as ready — the production `_validated` flag closes the
    // same window.
    _connected = false;
    final validator = _versionSkewValidator;
    if (validator != null && diag != null) {
      final refusal = await validator(diag);
      if (refusal != null) {
        throw VmBridgeException(refusal, kind: VmBridgeErrorKind.refused);
      }
    }
    // Session-rotation guard: read uuid from the canned envelope so
    // tests can drive rotation by flipping `setEnvelope`.
    final priorBaseline = _baseline;
    final newUuid = diag?['sessionUuid'];
    if (newUuid is String) {
      if (!acceptSessionRotation && newUuid != priorBaseline) {
        throw SessionChangedException(
          baseline: priorBaseline,
          current: newUuid,
        );
      }
      _baseline = newUuid;
    }
    _connected = true;
    _baselineGeneration++;
  }

  @override
  Future<Map<String, Object?>> callExtension(
    String method, {
    Map<String, dynamic> args = const <String, dynamic>{},
  }) async {
    if (!_connected) {
      throw VmBridgeException(
        'not connected to an app',
        kind: VmBridgeErrorKind.notConnected,
      );
    }
    if (_sessionDrifted) {
      // Reported once; the baseline already moved to the new session, as
      // RealVmBridge does after it reports a change.
      _sessionDrifted = false;
      throw SessionChangedException(baseline: 'old-uuid', current: _baseline);
    }
    final gate = _extensionGates.remove(method);
    if (gate != null) await gate.future;
    callLog.add((method: method, args: Map<String, dynamic>.of(args)));
    final responder = _responders[method];
    if (responder != null) return responder(args);
    final canned = _envelopes[method];
    if (canned == null) {
      throw VmBridgeException('no canned envelope for $method');
    }
    return canned;
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
  }
}
