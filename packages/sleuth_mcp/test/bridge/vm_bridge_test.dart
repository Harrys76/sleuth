@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:isolate';

import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart' as vm;

import '../helpers/fake_vm_bridge.dart';

void main() {
  test('FakeVmBridge returns canned envelope', () async {
    final bridge = defaultFakeBridge();
    await bridge.connect(Uri.parse('ws://localhost/ws'));
    final env = await bridge.callExtension('ext.sleuth.diagnose');
    expect(env['sessionUuid'], 'fake-uuid');
    expect(env['schemaVersion'], 1);
    expect(env['data'], isA<Map<String, Object?>>());
  });

  test('FakeVmBridge throws on session drift', () async {
    final bridge = defaultFakeBridge();
    await bridge.connect(Uri.parse('ws://localhost/ws'));
    bridge.simulateSessionChange('different-uuid');
    expect(
      () => bridge.callExtension('ext.sleuth.diagnose'),
      throwsA(isA<SessionChangedException>()),
    );
  });

  test('FakeVmBridge errors before connect', () async {
    final bridge = defaultFakeBridge();
    expect(
      () => bridge.callExtension('ext.sleuth.diagnose'),
      throwsA(isA<VmBridgeException>()),
    );
  });

  test('FakeVmBridge exposes lastDiagnoseEnvelope', () async {
    final bridge = defaultFakeBridge();
    await bridge.connect(Uri.parse('ws://localhost/ws'));
    final diag = bridge.lastDiagnoseEnvelope;
    expect(diag, isNotNull);
    expect(diag!['sessionUuid'], 'fake-uuid');
  });

  group('RealVmBridge.pickMainIsolate', () {
    vm.IsolateRef ref({String? id, String? name}) =>
        vm.IsolateRef(id: id, name: name);

    test('prefers exact name=main', () {
      final picked = RealVmBridge.pickMainIsolate([
        ref(id: 'bg-1', name: 'background'),
        ref(id: 'main-2', name: 'main'),
        ref(id: 'bg-3', name: 'worker'),
      ]);
      expect(picked.id, 'main-2');
    });

    test('falls back to startsWith(main)', () {
      final picked = RealVmBridge.pickMainIsolate([
        ref(id: 'bg-1', name: 'background'),
        ref(id: 'main-iso-2', name: 'main-iso'),
      ]);
      expect(picked.id, 'main-iso-2');
    });

    test('falls back to first when no main candidate', () {
      final picked = RealVmBridge.pickMainIsolate([
        ref(id: 'bg-1', name: 'background'),
        ref(id: 'bg-2', name: 'worker'),
      ]);
      expect(picked.id, 'bg-1');
    });
  });

  group('versionSkewValidator chokepoint', () {
    test('refusal collapses the bridge in place + throws VmBridgeException',
        () async {
      // Validator returns a non-null refusal — bridge must disconnect
      // before surfacing the exception so retry / reconnect paths cannot
      // keep talking to the rejected app.
      final bridge = FakeVmBridge(
        envelopes: {
          'ext.sleuth.diagnose': {
            'connectionMode': 'basic',
            'schemaVersion': 1,
            'sessionUuid': 'uuid',
            'data': {'packageVersion': '0.99.0'},
          },
        },
        versionSkewValidator: (env) async {
          final data = env['data'] as Map<String, Object?>?;
          final v = data?['packageVersion'];
          if (v != '0.33.0') return 'version_skew_major: synthetic refusal';
          return null;
        },
      );
      await expectLater(
        () => bridge.connect(Uri.parse('ws://localhost/ws')),
        throwsA(isA<VmBridgeException>()
            .having((e) => e.message, 'message', contains('version_skew_'))),
      );
      expect(bridge.isConnected, isFalse,
          reason: 'bridge must be torn down when validator refuses');
    });

    test('null return lets connect succeed normally', () async {
      final bridge = FakeVmBridge(
        envelopes: {
          'ext.sleuth.diagnose': {
            'connectionMode': 'basic',
            'schemaVersion': 1,
            'sessionUuid': 'uuid',
            'data': {'packageVersion': '0.33.0'},
          },
        },
        versionSkewValidator: (env) async => null,
      );
      final ok = await bridge.connect(Uri.parse('ws://localhost/ws'));
      expect(ok, isTrue);
      expect(bridge.isConnected, isTrue);
    });

    test('defaultVersionSkewValidator refuses on missing packageVersion',
        () async {
      final refusal = await defaultVersionSkewValidator({
        'sessionUuid': 'uuid',
        'data': const <String, Object?>{},
      });
      expect(refusal, isNotNull);
      expect(refusal, contains('version_skew_unknown'));
    });

    test('defaultVersionSkewValidator passes on accepted prior lineage',
        () async {
      // `acceptedPriorLineages` contains '0.32' — transition window.
      final refusal = await defaultVersionSkewValidator({
        'sessionUuid': 'uuid',
        'data': {'packageVersion': '0.32.5'},
      });
      expect(refusal, isNull,
          reason: 'cross-lineage tolerance must not surface as bridge-layer '
              'refusal — sidecar handles it as a warning at the tool layer');
    });

    test('defaultVersionSkewValidator refuses on cross-lineage drift',
        () async {
      final refusal = await defaultVersionSkewValidator({
        'sessionUuid': 'uuid',
        'data': {'packageVersion': '0.99.0'},
      });
      expect(refusal, isNotNull);
      expect(refusal, contains('version_skew_major'));
    });

    test(
      'isConnected stays false while validator is in flight (race guard)',
      () async {
        // The bridge MUST NOT report `isConnected == true` between the
        // diagnose-fetch and the validator's completion. `callExtension`
        // runs lock-free, so any pre-validator publish window is a race:
        // a concurrent dispatch would observe the bridge as ready and
        // hit an unvalidated app. The `_validated` gate closes it.
        final hold = Completer<String?>();
        final bridge = FakeVmBridge(
          envelopes: {
            'ext.sleuth.diagnose': {
              'connectionMode': 'basic',
              'schemaVersion': 1,
              'sessionUuid': 'uuid',
              'data': {'packageVersion': '0.33.0'},
            },
          },
          versionSkewValidator: (_) => hold.future,
        );
        final connectFuture = bridge.connect(Uri.parse('ws://localhost/ws'));
        // Yield once to let `connect()` reach the awaited validator.
        await Future<void>.delayed(Duration.zero);
        expect(bridge.isConnected, isFalse,
            reason: 'bridge must not report connected while validator is '
                'pending — concurrent callExtension would race past the gate');
        await expectLater(
          () => bridge.callExtension('ext.sleuth.diagnose'),
          throwsA(isA<VmBridgeException>()),
          reason: 'callExtension must refuse to dispatch against an '
              'unvalidated bridge',
        );
        hold.complete(null);
        await connectFuture;
        expect(bridge.isConnected, isTrue,
            reason: 'bridge flips to connected once validator clears');
        // After-validator dispatch succeeds.
        final env = await bridge.callExtension('ext.sleuth.diagnose');
        expect(env['sessionUuid'], 'uuid');
      },
    );

    test(
      'refusal mid-connect leaves bridge fully disconnected (race guard)',
      () async {
        // Variant: validator refuses. Connect throws; isConnected stays
        // false; subsequent callExtension still surfaces "not connected"
        // even though the dispatch race could not observe a transient
        // published state.
        final bridge = FakeVmBridge(
          envelopes: {
            'ext.sleuth.diagnose': {
              'connectionMode': 'basic',
              'schemaVersion': 1,
              'sessionUuid': 'uuid',
              'data': {'packageVersion': '0.99.0'},
            },
          },
          versionSkewValidator: (_) async =>
              'version_skew_major: synthetic refusal',
        );
        await expectLater(
          () => bridge.connect(Uri.parse('ws://localhost/ws')),
          throwsA(isA<VmBridgeException>()),
        );
        expect(bridge.isConnected, isFalse);
        await expectLater(
          () => bridge.callExtension('ext.sleuth.diagnose'),
          throwsA(isA<VmBridgeException>()),
        );
      },
    );
  });

  // Tests in this group share one `ext.sleuth.diagnose` registration —
  // `developer.registerExtension` is per-isolate global and refuses
  // re-registration, so tests cooperate via shared mutable state on
  // `_SharedDiagnoseFixture` rather than each registering their own.
  group('real-VM-service tests', () {
    final fixture = _SharedDiagnoseFixture();
    final currentIsolateId = developer.Service.getIsolateId(Isolate.current);

    setUpAll(() {
      developer.registerExtension('ext.sleuth.diagnose', (method, args) async {
        return developer.ServiceExtensionResponse.result(jsonEncode({
          'connectionMode': 'basic',
          'schemaVersion': 1,
          'sessionUuid': fixture.diagnoseUuid,
          'data': {'packageVersion': fixture.packageVersion},
        }));
      });
      developer.registerExtension('ext.test.echo', (method, args) async {
        return developer.ServiceExtensionResponse.result(jsonEncode({
          'connectionMode': 'basic',
          'schemaVersion': 1,
          'sessionUuid': fixture.diagnoseUuid,
          'data': const <String, Object?>{'echo': 'ok'},
        }));
      });
    });

    setUp(() {
      // Reset between tests so each starts with predictable state.
      fixture.diagnoseUuid = 'shared-default-uuid';
      fixture.packageVersion = '0.33.0';
    });

    Future<Uri?> ensureWsUri() async {
      final info = await developer.Service.controlWebServer(
        enable: true,
        silenceOutput: true,
      );
      return info.serverWebSocketUri;
    }

    test(
      'validator refusal leaves bridge fully disconnected; '
      'subsequent callExtension surfaces "not connected"',
      () async {
        fixture.diagnoseUuid = 'refuse-uuid';
        fixture.packageVersion = '0.99.0';
        final wsUri = await ensureWsUri();
        if (wsUri == null) {
          markTestSkipped('VM service not available');
          return;
        }
        final bridge = RealVmBridge(
          callTimeout: const Duration(seconds: 5),
          targetIsolateIdOverride: currentIsolateId,
          versionSkewValidator: (env) async {
            final data = env['data'] as Map<String, Object?>?;
            if (data?['packageVersion'] != '0.33.0') {
              return 'version_skew_major: synthetic';
            }
            return null;
          },
        );
        await expectLater(
          () => bridge.connect(wsUri),
          throwsA(isA<VmBridgeException>().having(
            (e) => e.message,
            'message',
            contains('version_skew_'),
          )),
        );
        expect(bridge.isConnected, isFalse);
        // Post-refusal dispatch must hit the "not connected" branch,
        // proving the try/catch in `_connectUnlocked` collapsed
        // `_service` + `_mainIsolateId` before rethrowing. If the
        // cleanup were skipped, the gate would still fire but the
        // message would be the validated-gate one instead.
        await expectLater(
          () => bridge.callExtension('ext.sleuth.diagnose'),
          throwsA(isA<VmBridgeException>().having(
            (e) => e.message,
            'message',
            contains('not connected'),
          )),
        );
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'concurrent callExtension during validator window is blocked '
      'by _validated gate',
      () async {
        fixture.diagnoseUuid = 'race-uuid';
        final wsUri = await ensureWsUri();
        if (wsUri == null) {
          markTestSkipped('VM service not available');
          return;
        }
        final hold = Completer<String?>();
        final bridge = RealVmBridge(
          callTimeout: const Duration(seconds: 5),
          targetIsolateIdOverride: currentIsolateId,
          versionSkewValidator: (_) => hold.future,
        );
        final connectFuture = bridge.connect(wsUri);
        // Yield until `_service` + `_mainIsolateId` are published but
        // `_validated` is still false (validator awaiting Completer).
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(bridge.isConnected, isFalse,
            reason: 'gate must keep isConnected false during validation');
        await expectLater(
          () => bridge.callExtension('ext.test.echo'),
          throwsA(isA<VmBridgeException>().having(
            (e) => e.message,
            'message',
            contains('not yet validated'),
          )),
          reason: 'public callExtension must not bypass the gate',
        );
        hold.complete(null);
        await connectFuture;
        expect(bridge.isConnected, isTrue);
        // After-validator dispatch succeeds — confirms the bootstrap
        // diagnose-fetch path uses `bypassValidatedGate: true` and the
        // gate is satisfied for normal callers post-validation.
        final env = await bridge.callExtension('ext.test.echo');
        expect(env['sessionUuid'], 'race-uuid');
        await bridge.disconnect();
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    // Uses `debugSimulateReconnect()` rather than a mock because
    // `_ensureReconnected` is the production reconnect path; swapping
    // `_callExtensionRaw` with a mock would bypass the very
    // `_connectUnlocked` logic (priorBaseline capture + session-rotation
    // guard) under test.
    test(
      'reconnect with rotated sessionUuid throws '
      'SessionChangedException and tears down the bridge',
      () async {
        fixture.diagnoseUuid = 'session-A';
        final wsUri = await ensureWsUri();
        if (wsUri == null) {
          markTestSkipped('VM service not available');
          return;
        }
        final bridge = RealVmBridge(
          callTimeout: const Duration(seconds: 5),
          targetIsolateIdOverride: currentIsolateId,
        );
        await bridge.connect(wsUri);
        expect(bridge.baselineSessionUuid, 'session-A');
        expect(bridge.isConnected, isTrue);
        // Simulate hot-restart: target app now reports a new uuid.
        fixture.diagnoseUuid = 'session-B';
        await expectLater(
          bridge.debugSimulateReconnect(),
          throwsA(isA<SessionChangedException>()
              .having((e) => e.baseline, 'baseline', 'session-A')
              .having((e) => e.current, 'current', 'session-B')),
        );
        // `_connectUnlocked`'s try/catch must collapse the bridge on
        // rotation throws too — not just validator refusals.
        expect(bridge.isConnected, isFalse,
            reason: 'bridge must be torn down after rotation throw');
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'pre-dispose gate is already closed when prior service is '
      'about to be disposed — concurrent dispatcher refuses cleanly',
      () async {
        // Protects the window inside `_connectUnlocked` where the prior
        // `vm.VmService` is about to be `await`-disposed. If
        // `_validated` / `_service` / `_mainIsolateId` stayed populated
        // across that suspension, a lock-free `callExtension` racing
        // the reconnect would pass the gate, dispatch against the prior
        // service, then crash mid-call. Gate + refs unpublish BEFORE
        // awaiting dispose. The probe asserts that snapshot.
        fixture.diagnoseUuid = 'predispose-uuid';
        final wsUri = await ensureWsUri();
        if (wsUri == null) {
          markTestSkipped('VM service not available');
          return;
        }
        final bridge = RealVmBridge(
          callTimeout: const Duration(seconds: 5),
          targetIsolateIdOverride: currentIsolateId,
        );
        await bridge.connect(wsUri);
        expect(bridge.isConnected, isTrue,
            reason: 'initial connect should publish all baseline state');

        // Snapshot what the bridge looked like at the pre-dispose
        // probe point. If the ordering regresses, `validated` here
        // flips to true and the test fails loudly.
        bool? validatedAtProbe;
        bool? isConnectedAtProbe;
        Object? raceCallError;
        bridge.debugPreDisposeProbe = (b) {
          // The synthetic probe runs synchronously between the
          // unpublish writes and `await prior.dispose()` — exactly the
          // window where a lock-free dispatcher could race. We can't
          // run an async `callExtension` synchronously here, but we
          // CAN record the gate state and fire a callExtension whose
          // first synchronous step (`_callExtensionRaw`'s validated
          // check) settles before any further awaits.
          isConnectedAtProbe = b.isConnected;
          // Reach into the gate via the public `isConnected` getter:
          // `_validated` is private, but `isConnected` already ANDs
          // service + isolate + validated, and we've already cleared
          // service+isolate, so isConnected == false implies the gate
          // is shut. We still want to prove a concurrent dispatcher
          // can't slip through, so fire a callExtension and capture
          // its (expected) rejection asynchronously.
          validatedAtProbe = b.isConnected;
          unawaited(
            b.callExtension('ext.test.echo').then(
                  (_) => raceCallError = 'unexpected success — gate failed',
                  onError: (Object e) => raceCallError = e,
                ),
          );
        };

        // Trigger the reconnect path that runs `_connectUnlocked` with
        // a non-null `_service` (i.e. the dispose await fires). Same
        // uuid so the reconnect succeeds and we can assert post-state.
        await bridge.debugSimulateReconnect();
        // Drain the concurrent callExtension scheduled inside the probe.
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(isConnectedAtProbe, isFalse,
            reason: 'bridge must report disconnected at the pre-dispose '
                'probe point — gate was lowered + refs unpublished before '
                'the dispose await opened a race window');
        expect(validatedAtProbe, isFalse,
            reason: '_validated must be false at probe point');
        expect(raceCallError, isA<VmBridgeException>(),
            reason: 'concurrent callExtension during the dispose window '
                'must be rejected — never dispatched against the prior '
                'service');
        // Reconnect should still succeed end-to-end.
        expect(bridge.isConnected, isTrue,
            reason: 'reconnect completes cleanly after the probe window');
        bridge.debugPreDisposeProbe = null;
        await bridge.disconnect();
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'refreshBaseline routes through validator — major skew on '
      'refresh disconnects the bridge',
      () async {
        // Every baseline mutation re-runs the validator via
        // `_applyBaseline`, so a hot-restart that produces a skewed
        // envelope on refresh tears down the bridge just like a skewed
        // connect does.
        fixture.diagnoseUuid = 'refresh-refuse-uuid';
        fixture.packageVersion = '0.33.0';
        final wsUri = await ensureWsUri();
        if (wsUri == null) {
          markTestSkipped('VM service not available');
          return;
        }
        final bridge = RealVmBridge(
          callTimeout: const Duration(seconds: 5),
          targetIsolateIdOverride: currentIsolateId,
          versionSkewValidator: (env) async {
            final data = env['data'] as Map<String, Object?>?;
            if (data?['packageVersion'] != '0.33.0') {
              return 'version_skew_major: synthetic refusal on refresh';
            }
            return null;
          },
        );
        await bridge.connect(wsUri);
        expect(bridge.isConnected, isTrue,
            reason: 'initial connect at matching version must succeed');

        // Hot-restart in place: target app now reports a skewed
        // packageVersion. Refresh must re-validate and refuse.
        fixture.packageVersion = '0.99.0';
        await expectLater(
          bridge.refreshBaseline(acceptSessionRotation: true),
          throwsA(isA<VmBridgeException>().having(
            (e) => e.message,
            'message',
            contains('version_skew_'),
          )),
        );
        expect(bridge.isConnected, isFalse,
            reason: 'refresh refusal must disconnect the bridge — same '
                'semantics as connect refusal so subsequent callExtension '
                'cannot dispatch against the skewed app');
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'refreshBaseline session-rotation guard fires when '
      'acceptSessionRotation is false (parity with reconnect)',
      () async {
        fixture.diagnoseUuid = 'session-A';
        fixture.packageVersion = '0.33.0';
        final wsUri = await ensureWsUri();
        if (wsUri == null) {
          markTestSkipped('VM service not available');
          return;
        }
        final bridge = RealVmBridge(
          callTimeout: const Duration(seconds: 5),
          targetIsolateIdOverride: currentIsolateId,
          versionSkewValidator: (_) async => null,
        );
        await bridge.connect(wsUri);
        expect(bridge.baselineSessionUuid, 'session-A');

        // Simulate hot-restart: same packageVersion (validator passes)
        // but a different sessionUuid. Refresh without opt-in must
        // surface SessionChangedException AND tear down the bridge.
        fixture.diagnoseUuid = 'session-B';
        await expectLater(
          bridge.refreshBaseline(acceptSessionRotation: false),
          throwsA(isA<SessionChangedException>()
              .having((e) => e.baseline, 'baseline', 'session-A')
              .having((e) => e.current, 'current', 'session-B')),
        );
        expect(bridge.isConnected, isFalse,
            reason: 'rotation throw on refresh must collapse the bridge — '
                'parity with reconnect rotation handling');
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'refreshBaseline lowers _validated gate while validator runs '
      '(concurrent dispatcher blocked)',
      () async {
        fixture.diagnoseUuid = 'refresh-race-uuid';
        fixture.packageVersion = '0.33.0';
        final wsUri = await ensureWsUri();
        if (wsUri == null) {
          markTestSkipped('VM service not available');
          return;
        }
        // First call: bootstrap validation passes. Second call (refresh):
        // validator hangs on Completer so a concurrent dispatcher can
        // observe the gate state mid-refresh.
        final hold = Completer<String?>();
        var validatorCalls = 0;
        final bridge = RealVmBridge(
          callTimeout: const Duration(seconds: 5),
          targetIsolateIdOverride: currentIsolateId,
          versionSkewValidator: (_) async {
            validatorCalls++;
            if (validatorCalls == 1) return null;
            return hold.future;
          },
        );
        await bridge.connect(wsUri);
        expect(bridge.isConnected, isTrue,
            reason: 'first validator call cleared connect');

        final refreshFuture =
            bridge.refreshBaseline(acceptSessionRotation: true);
        // Yield until refresh has fetched diagnose + entered the
        // hanging validator. `_applyBaseline` lowers `_validated`
        // BEFORE running the validator, so a lock-free dispatcher
        // here must hit the validated-gate refusal.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(bridge.isConnected, isFalse,
            reason: 'refresh must lower the gate before awaiting the '
                'validator — without this, a concurrent dispatcher could '
                'race past _validated against a not-yet-revalidated app');
        await expectLater(
          () => bridge.callExtension('ext.test.echo'),
          throwsA(isA<VmBridgeException>().having(
            (e) => e.message,
            'message',
            contains('not yet validated'),
          )),
          reason: 'lock-free callExtension during refresh validator '
              'window must be refused — same semantics as the connect '
              'validator window',
        );
        hold.complete(null);
        await refreshFuture;
        expect(bridge.isConnected, isTrue,
            reason: 'bridge flips back to connected once refresh validator '
                'clears');
        await bridge.disconnect();
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'refreshBaseline lowers _validated gate BEFORE awaiting '
      'diagnose (concurrent dispatcher blocked across diagnose window)',
      () async {
        // Sibling of the validator-window race test: covers the
        // earlier `ext.sleuth.diagnose` round-trip BEFORE
        // `_applyBaseline` runs. Without the pre-await lower in
        // `_refreshBaselineUnlocked`, `_validated` stays true from the
        // prior connect across the round-trip, so a lock-free
        // `callExtension` racing the refresh could dispatch against
        // the soon-to-be-revalidated target. Can't suspend the shared
        // diagnose handler (registerExtension is one-per-name), but we
        // CAN suspend the validator and assert the gate is ALREADY
        // false at validator entry — proving the lower happened before
        // the diagnose round-trip, not after.
        fixture.diagnoseUuid = 'refresh-stable-uuid';
        fixture.packageVersion = '0.33.0';
        final wsUri = await ensureWsUri();
        if (wsUri == null) {
          markTestSkipped('VM service not available');
          return;
        }
        bool? isConnectedAtValidatorEntry;
        final validatorHold = Completer<String?>();
        var validatorCalls = 0;
        // Late-bound holder so the validator closure can read the bridge
        // it's wired into without forward-referencing the `bridge` local.
        final bridgeRef = <RealVmBridge>[];
        final bridge = RealVmBridge(
          callTimeout: const Duration(seconds: 5),
          targetIsolateIdOverride: currentIsolateId,
          versionSkewValidator: (env) async {
            validatorCalls++;
            if (validatorCalls == 1) return null;
            // Snapshot the gate at validator entry. If the gate was
            // lowered at refresh entry (correct ordering), this is
            // false. If it were only lowered inside `_applyBaseline`,
            // this would ALSO be false because `_applyBaseline` lowers
            // before invoking the validator. So this single snapshot
            // can't distinguish the two; the distinguishing signal is
            // the EARLIER snapshot taken outside the validator (below).
            isConnectedAtValidatorEntry = bridgeRef.first.isConnected;
            return validatorHold.future;
          },
        );
        bridgeRef.add(bridge);
        await bridge.connect(wsUri);
        expect(bridge.isConnected, isTrue);

        // Start refresh in background. The pre-await lower in
        // `_refreshBaselineUnlocked` drops the gate synchronously at
        // refresh entry, before any await. Sample the gate immediately
        // after kicking off refresh — this is BEFORE the diagnose
        // round-trip resolves and BEFORE `_applyBaseline` runs. Without
        // the pre-await lower the gate would still be true here.
        final refreshFuture =
            bridge.refreshBaseline(acceptSessionRotation: true);
        // No `await` here — sample synchronously after the call returns
        // its Future. Refresh has entered (`_validated = false` ran
        // synchronously inside `_refreshBaselineUnlocked` before the
        // first await). isConnected reads `_validated` — must be false.
        final isConnectedRightAfterRefreshKickoff = bridge.isConnected;

        // Now yield so the diagnose round-trip resolves and we land
        // inside the suspended validator.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(isConnectedRightAfterRefreshKickoff, isFalse,
            reason: 'gate must be lowered synchronously at refresh entry '
                '— before the diagnose round-trip suspends. Without the '
                'pre-await lower isConnected would still be true here.');
        expect(isConnectedAtValidatorEntry, isFalse,
            reason: 'gate must remain lowered through to validator entry');
        expect(bridge.isConnected, isFalse,
            reason: 'gate remains lowered while validator awaits');
        await expectLater(
          () => bridge.callExtension('ext.test.echo'),
          throwsA(isA<VmBridgeException>().having(
            (e) => e.message,
            'message',
            contains('not yet validated'),
          )),
          reason: 'lock-free dispatcher during refresh window must be '
              'refused with the validated-gate message',
        );
        validatorHold.complete(null);
        await refreshFuture;
        expect(bridge.isConnected, isTrue,
            reason: 'refresh flips back to connected once validator clears');
        await bridge.disconnect();
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'disconnect lowers gate + unpublishes wsUri BEFORE awaiting '
      'dispose — concurrent dispatcher refused, no reconnect republish',
      () async {
        // Protects the dispose suspension point inside
        // `_disconnectUnlocked`. If `_validated` / `_service` /
        // `_mainIsolateId` / `_wsUri` stayed populated across
        // `await _service?.dispose()`, a lock-free callExtension racing
        // the disconnect would pass the gate, dispatch against the
        // about-to-be-disposed service, observe `_TransportClosed`, and
        // `_ensureReconnected` would see the still-published `_wsUri`
        // and republish the bridge AFTER an explicit caller-requested
        // disconnect. Everything unpublishes synchronously before
        // dispose.
        fixture.diagnoseUuid = 'disconnect-stable-uuid';
        fixture.packageVersion = '0.33.0';
        final wsUri = await ensureWsUri();
        if (wsUri == null) {
          markTestSkipped('VM service not available');
          return;
        }
        final bridge = RealVmBridge(
          callTimeout: const Duration(seconds: 5),
          targetIsolateIdOverride: currentIsolateId,
        );
        await bridge.connect(wsUri);
        expect(bridge.isConnected, isTrue,
            reason: 'connect must publish baseline before the probe runs');

        // Snapshot bridge state at the disconnect-path pre-dispose
        // probe point. If the ordering regresses, isConnectedAtProbe
        // stays true (or the race callExtension succeeds).
        bool? isConnectedAtProbe;
        Object? raceCallError;
        Object? reconnectCallError;
        bridge.debugDisconnectPreDisposeProbe = (b) {
          isConnectedAtProbe = b.isConnected;
          // Fire a racing callExtension whose validated-gate check
          // settles synchronously. The future resolves later with the
          // expected rejection.
          unawaited(
            b.callExtension('ext.test.echo').then(
                  (_) => raceCallError = 'unexpected success — gate failed',
                  onError: (Object e) => raceCallError = e,
                ),
          );
          // Also poke the reconnect entry point — if the unpublish
          // ordering regresses, `_wsUri` is still set here and
          // `debugSimulateReconnect()` would queue a `_connectUnlocked`
          // call that republishes the bridge after disconnect. With
          // `_wsUri == null`, `_ensureReconnected` returns a
          // VmBridgeException('no wsUri for reconnect').
          unawaited(
            b.debugSimulateReconnect().then(
                  (_) => reconnectCallError =
                      'unexpected reconnect success — wsUri not cleared',
                  onError: (Object e) => reconnectCallError = e,
                ),
          );
        };

        await bridge.disconnect();
        // Drain the racing futures scheduled inside the probe.
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(isConnectedAtProbe, isFalse,
            reason: 'bridge must report disconnected at the pre-dispose '
                'probe point — gate was lowered + every ref (including '
                '_wsUri) was unpublished before the dispose await opened '
                'a race window');
        expect(raceCallError, isA<VmBridgeException>(),
            reason: 'concurrent callExtension during the disconnect '
                'window must be rejected — never dispatched against the '
                'service being disposed');
        expect(reconnectCallError, isA<VmBridgeException>(),
            reason: '_ensureReconnected during the disconnect window '
                'must surface no-wsUri — never republish the bridge '
                'after an explicit disconnect');
        // Bridge stays disconnected after the probe drains.
        expect(bridge.isConnected, isFalse,
            reason: 'no reconnect republish after explicit disconnect');
        await expectLater(
          () => bridge.callExtension('ext.test.echo'),
          throwsA(isA<VmBridgeException>().having(
            (e) => e.message,
            'message',
            anyOf(contains('not connected'), contains('not yet validated')),
          )),
          reason: 'post-disconnect dispatch must surface a clean refusal',
        );
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test(
      'reconnect with same sessionUuid succeeds and bumps '
      'baselineGeneration',
      () async {
        fixture.diagnoseUuid = 'session-stable';
        final wsUri = await ensureWsUri();
        if (wsUri == null) {
          markTestSkipped('VM service not available');
          return;
        }
        final bridge = RealVmBridge(
          callTimeout: const Duration(seconds: 5),
          targetIsolateIdOverride: currentIsolateId,
        );
        await bridge.connect(wsUri);
        final genBefore = bridge.baselineGeneration;
        await bridge.debugSimulateReconnect();
        expect(bridge.isConnected, isTrue);
        expect(bridge.baselineSessionUuid, 'session-stable');
        expect(bridge.baselineGeneration, greaterThan(genBefore),
            reason: 'baseline generation should advance on every '
                'successful reconnect');
        await bridge.disconnect();
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });
}

/// Mutable diagnose state shared between the singleton extension
/// handler and the tests that drive it. `developer.registerExtension`
/// only accepts one handler per name per isolate, so tests cooperate
/// via this fixture instead of each registering their own.
class _SharedDiagnoseFixture {
  String diagnoseUuid = 'shared-default-uuid';
  String packageVersion = '0.33.0';
}
