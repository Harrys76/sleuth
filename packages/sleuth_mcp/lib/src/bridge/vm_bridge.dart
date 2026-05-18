import 'dart:async';

import 'package:meta/meta.dart';
import 'package:synchronized/synchronized.dart';
import 'package:vm_service/vm_service.dart' as vm;
import 'package:vm_service/vm_service_io.dart';

/// Bridges MCP tool handlers to the running app's VM service.
///
/// `Response.json` is the parsed sleuth envelope
/// `{connectionMode, schemaVersion, sessionUuid, data|error}` directly —
/// vm_service inlines the extension result string into the JSON-RPC
/// `result` field, no manual decode needed.
abstract class VmBridge {
  Future<bool> connect(Uri wsUri);

  /// Returns the inner sleuth envelope as a `Map`. Throws
  /// [VmBridgeException] on transport / decode failure, [SessionChangedException]
  /// when the responding session's UUID differs from the baseline captured
  /// at [connect] time.
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

/// Connect / dispatch failure not attributable to a session change.
class VmBridgeException implements Exception {
  VmBridgeException(this.message);
  final String message;
  @override
  String toString() => 'VmBridgeException: $message';
}

/// The target app's `sessionUuid` differs from the baseline. Indicates a
/// hot-restart or a different app at the same URI.
class SessionChangedException implements Exception {
  SessionChangedException({
    required this.baseline,
    required this.current,
  });
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
typedef VersionSkewValidator = Future<String?> Function(
  Map<String, Object?> diagnoseEnvelope,
);

/// Production [VmBridge] over a real WebSocket VM service.
///
/// Connect / disconnect / reconnect serialize via [Lock] so concurrent
/// dispatches don't observe half-initialized state. `callServiceExtension`
/// itself runs outside the lock — vm_service handles concurrent calls.
class RealVmBridge implements VmBridge {
  RealVmBridge({
    this.callTimeout = const Duration(seconds: 10),
    Sink<String>? logger,
    String? targetIsolateIdOverride,
    VersionSkewValidator? versionSkewValidator,
  })  : _logger = logger,
        _targetIsolateIdOverride = targetIsolateIdOverride,
        _versionSkewValidator = versionSkewValidator;

  final Duration callTimeout;
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

  /// INTERNAL test seam (M11). When non-null, invoked exactly once at the
  /// pre-dispose snapshot point inside `_connectUnlocked` — AFTER the
  /// `_validated` / `_service` / `_mainIsolateId` / `_wsUri` unpublish but
  /// BEFORE `await prior.dispose()`. The probe runs synchronously against
  /// the bridge's current state so a test can assert the gate is already
  /// closed before the dispose suspension point opens a race window. Not
  /// for production use — leave null on real bridges.
  @visibleForTesting
  void Function(RealVmBridge bridge)? debugPreDisposeProbe;

  /// INTERNAL test seam (M14). Sibling of [debugPreDisposeProbe], wired
  /// into `_disconnectUnlocked` instead of `_connectUnlocked`. Fires
  /// synchronously AFTER the disconnect-path unpublish (gate down,
  /// `_service` / `_mainIsolateId` / `_baselineSessionUuid` /
  /// `_lastDiagnoseEnvelope` / `_wsUri` cleared) but BEFORE
  /// `await prior.dispose()`. Distinct from the connect-time probe so a
  /// single bridge can be wired with one or the other independently —
  /// otherwise reconnect dispose would also fire the M14 probe.
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
    Uri wsUri, {
    required bool acceptSessionRotation,
  }) async {
    // M11: lower the gate AND unpublish refs BEFORE awaiting
    // `prior.dispose()`. The dispose await is an async suspension point;
    // if `_validated` / `_service` / `_mainIsolateId` stay populated
    // across it, a lock-free `callExtension` racing the reconnect can
    // pass `_callExtensionRaw`'s validated-gate, dispatch against the
    // prior service, then see it torn down mid-call (`_TransportClosed`)
    // and trigger an `_ensureReconnected` against a stale `_wsUri`.
    // Clearing first guarantees concurrent dispatchers see
    // `bridge not yet validated` and refuse without touching the
    // service being disposed. `_wsUri` is set to the NEW target so any
    // racing reconnect coalesces onto the connect already in flight
    // via `_reconnectInFlight`.
    _validated = false;
    final prior = _service;
    _service = null;
    _mainIsolateId = null;
    _wsUri = wsUri;
    // M11 test seam: assert state visible to a hypothetical concurrent
    // dispatcher right before the dispose suspension point. Guarded by
    // `assert` so the call site is stripped in release-mode builds and
    // the probe field is only paid for by tests.
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
      _service = await vmServiceConnectUri(wsUri.toString())
          .timeout(const Duration(seconds: 5));
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
        final vmInfo = await _service!.getVM();
        isolates = vmInfo.isolates ?? <vm.IsolateRef>[];
        if (isolates.isNotEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      if (isolates.isEmpty) {
        throw VmBridgeException(
            'no isolates on target VM service after 20s wait');
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
      throw VmBridgeException('cannot refresh — bridge disconnected');
    }
    // M13: lower the gate BEFORE the diagnose await. `_applyBaseline`
    // also lowers `_validated` at its top, but only AFTER the diagnose
    // round-trip resolves. During that round-trip the gate would stay
    // true (carried over from the prior connect) — a lock-free
    // `callExtension` racing the refresh would pass `_callExtensionRaw`'s
    // validated check and dispatch against a soon-to-be-revalidated
    // target. Same family as the M11 / M12 race; idempotent re-lower
    // inside `_applyBaseline` is acceptable redundancy because each
    // write protects a different suspension window.
    _validated = false;
    try {
      // Bootstrap-style diagnose: refresh runs on an already-validated
      // bridge, but `_applyBaseline` lowers the gate before re-running
      // the validator, so the diagnose call itself must bypass the gate
      // for the same reason `_connectUnlocked` does.
      final diag = await _callExtensionRaw(
        'ext.sleuth.diagnose',
        bypassValidatedGate: true,
      );
      await _applyBaseline(diag, acceptSessionRotation: acceptSessionRotation);
    } catch (_) {
      // Refresh failed mid-flight. `_applyBaseline` disconnects on its
      // own refusal paths (validator + rotation), but a malformed
      // diagnose envelope or transport exception bypasses that cleanup
      // and leaves `_service` + `_mainIsolateId` populated while
      // `_validated == false`. Tear the bridge down fully so callers
      // see a clean "not connected" state instead of a partially-valid
      // bridge that the next refresh attempt would inherit.
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

  /// Single chokepoint for every code path that publishes a fresh
  /// diagnose envelope as the new baseline. Connect, reconnect, and
  /// refresh all route through here so the version-skew validator +
  /// session-rotation guard cover every baseline mutation uniformly —
  /// no future baseline-mutation path can bypass either gate by
  /// accident.
  ///
  /// Lowers `_validated` BEFORE running the validator so concurrent
  /// dispatchers (including refresh-time ones) cannot observe a stale
  /// "ready" bridge while the validator is in flight against a newly-
  /// fetched envelope.
  ///
  /// Refusal disconnects the bridge and throws [VmBridgeException]
  /// BEFORE publishing baseline, so concurrent dispatchers cannot
  /// observe a partially-applied unsafe baseline.
  ///
  /// [acceptSessionRotation] — when false, throws
  /// [SessionChangedException] if the new sessionUuid differs from the
  /// prior baseline (caller did not opt into hot-restart rotation).
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
    // Lower the gate BEFORE running the validator. On the refresh
    // path the bridge is already validated; without this, a concurrent
    // dispatcher could observe `isConnected == true` while the
    // validator is awaiting against a newly-fetched envelope. Symmetric
    // with `_connectUnlocked`'s pre-dispose unpublish — same race,
    // different code path.
    _validated = false;
    // Validator runs BEFORE the session-rotation check so a skew
    // refusal surfaces first — its message is more actionable. Refusal
    // collapses the connection in place; rotation throws after publish
    // is suppressed by the try/catch in the caller.
    final validator = _versionSkewValidator;
    if (validator != null) {
      final refusal = await validator(diag);
      if (refusal != null) {
        await _disconnectUnlocked();
        throw VmBridgeException(refusal);
      }
    }
    if (!acceptSessionRotation &&
        priorBaseline != null &&
        uuid != priorBaseline) {
      await _disconnectUnlocked();
      throw SessionChangedException(
        baseline: priorBaseline,
        current: uuid,
      );
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
    if (uuid is String &&
        _baselineSessionUuid != null &&
        uuid != _baselineSessionUuid) {
      throw SessionChangedException(
        baseline: _baselineSessionUuid!,
        current: uuid,
      );
    }
    return inner;
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
      throw VmBridgeException('not connected');
    }
    // Lock-free callers must wait until `_connectUnlocked` finishes
    // validation. The only legitimate bypass is the bootstrap
    // diagnose call inside `_connectUnlocked` itself — it PRODUCES
    // the envelope the validator consumes.
    if (!bypassValidatedGate && !_validated) {
      throw VmBridgeException(
        'bridge not yet validated — connect did not complete '
        'or refusal pending',
      );
    }
    vm.Response response;
    try {
      response = await service
          .callServiceExtension(method, isolateId: isolateId, args: args)
          .timeout(callTimeout);
    } on TimeoutException {
      throw VmBridgeException('$method timed out after $callTimeout');
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

  @override
  Future<void> disconnect() {
    return _connectLock.synchronized(_disconnectUnlocked);
  }

  Future<void> _disconnectUnlocked() async {
    // M14: lower the gate AND unpublish every observable bridge field
    // BEFORE awaiting `prior.dispose()`. The dispose await is an async
    // suspension point; if `_validated` / `_service` / `_mainIsolateId`
    // stay populated across it, a lock-free `callExtension` racing the
    // teardown can pass `_callExtensionRaw`'s validated-gate, dispatch
    // against the about-to-be-disposed service, observe the transport
    // close mid-call (`_TransportClosed`), and trigger
    // `_ensureReconnected` against the still-published `_wsUri` — which
    // would republish the bridge after an explicit caller-requested
    // disconnect. Clearing `_wsUri` first makes `_ensureReconnected`
    // return `Future.error(VmBridgeException('no wsUri for reconnect'))`
    // instead of looping back through `_connectUnlocked`. Concurrent
    // dispatchers see `_validated == false` (→ `bridge not yet
    // validated`) or `_service == null` (→ `not connected`); either
    // outcome blocks dispatch against the disposed service.
    _validated = false;
    final prior = _service;
    _service = null;
    _mainIsolateId = null;
    _baselineSessionUuid = null;
    _lastDiagnoseEnvelope = null;
    _wsUri = null;
    // M14 test seam: same role as `debugPreDisposeProbe` but wired into
    // the disconnect path. Assert-only call site so it's stripped from
    // release-mode builds.
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
  })  : _envelopes = Map.of(envelopes),
        _baseline = fakeSessionUuid,
        _versionSkewValidator = versionSkewValidator;

  final String fakeSessionUuid;
  final Map<String, Map<String, Object?>> _envelopes;
  String _baseline;
  int _baselineGeneration = 0;
  bool _connected = false;
  bool _sessionDrifted = false;
  final VersionSkewValidator? _versionSkewValidator;

  /// Replace the canned envelope for a given extension name.
  void setEnvelope(String method, Map<String, Object?> envelope) {
    _envelopes[method] = envelope;
  }

  /// Force the next callExtension to throw a SessionChangedException.
  void simulateSessionChange(String newUuid) {
    _sessionDrifted = true;
    _baseline = newUuid;
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
    // Initial connect — no prior baseline exists, so session-rotation
    // detection is a no-op (matches RealVmBridge.connect semantics).
    final diag = _envelopes['ext.sleuth.diagnose'];
    await _applyBaseline(diag, acceptSessionRotation: true);
    return true;
  }

  @override
  Future<void> refreshBaseline({bool acceptSessionRotation = false}) async {
    if (!_connected) {
      throw VmBridgeException('cannot refresh — bridge disconnected');
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
        throw VmBridgeException(refusal);
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
      throw VmBridgeException('not connected');
    }
    if (_sessionDrifted) {
      _sessionDrifted = false;
      throw SessionChangedException(
        baseline: 'old-uuid',
        current: _baseline,
      );
    }
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
