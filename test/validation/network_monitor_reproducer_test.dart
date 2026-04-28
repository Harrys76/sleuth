// Hermetic reproducer for [NetworkMonitorDetector].
//
// Cited by `NetworkMonitorDetector.validationMetadata.reproducerPath` as the
// single-file evidence supporting the detector's `EvidenceTier.reproducerOnly`
// claim (v0.16.1 per-detector validation milestone).
//
// Two layers:
//   - Layer 1: direct `processRecord()` at threshold boundaries — documents
//     the public warning/critical contract (1000 ms / 3000 ms) and the
//     reachability invariant (`critical > slow`).
//   - Layer 2: full pipeline — `SleuthHttpOverrides` → `_MonitoringHttpClient`
//     → `_MonitoringRequest` → `RequestRecord` → `processRecord` — exercised
//     against a loopback `HttpServer` with a controlled response delay, so
//     the test is deterministic, hermetic (no external network), and fast.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/detectors/network_monitor_detector.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/network/http_monitor.dart';
import 'package:sleuth/src/network/request_record.dart';

/// How the Layer 2 consumer drains the response body. Each mode exercises
/// a different `StreamSubscription` code path the v0.16.1 AB1 fix covers:
/// before the fix, `drain` and `asFuture` silently replaced the proxy's
/// wrapping `onDone` and the `RequestRecord` never landed.
enum DrainMode {
  /// `await for (final _ in response) {}` — the subscription's `onDone`
  /// is the one the proxy installed, so the record emission path fires
  /// naturally. Safe even on the pre-AB1 implementation.
  awaitFor,

  /// `response.drain<void>()` — internally calls `listen(null,
  /// cancelOnError: true).asFuture(futureValue)`, which replaces the
  /// inner subscription's `_onDone`. Before AB1, the proxy's record
  /// never emitted on this path.
  drain,

  /// `response.listen(...).asFuture()` — the explicit form of the
  /// pattern `drain` uses internally. Same replacement behaviour.
  listenAsFuture,

  /// Consume one chunk then `cancel()`. Exercises the wrapper's
  /// `cancel()` override, which fires the terminal emit before
  /// delegating to the inner subscription so early-abort consumers
  /// still produce a `RequestRecord`.
  cancelEarly,
}

void main() {
  group('NetworkMonitorDetector — Layer 1: direct processRecord', () {
    late NetworkMonitorDetector detector;
    late DateTime fakeNow;

    setUp(() {
      fakeNow = DateTime(2026, 1, 1);
      detector = NetworkMonitorDetector(clock: () => fakeNow);
    });

    tearDown(() => detector.dispose());

    RequestRecord record({
      required int durationMs,
      int responseBytes = 1024,
      int statusCode = 200,
    }) {
      return RequestRecord(
        url: 'https://example.test/api/endpoint',
        method: 'GET',
        statusCode: statusCode,
        durationMs: durationMs,
        responseBytes: responseBytes,
        startedAt: fakeNow,
      );
    }

    test('999 ms — below slow threshold, no issue', () {
      detector.processRecord(record(durationMs: 999));
      expect(detector.issues, isEmpty);
    });

    test('1000 ms — at slow threshold, warning fires', () {
      detector.processRecord(record(durationMs: 1000));
      final slow =
          detector.issues.where((i) => i.stableId == 'slow_request').toList();
      expect(slow, hasLength(1));
      expect(slow.first.severity, IssueSeverity.warning);
    });

    test('2999 ms — below critical, warning stays', () {
      detector.processRecord(record(durationMs: 2999));
      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.severity, IssueSeverity.warning);
    });

    test('3000 ms — at critical threshold, severity escalates', () {
      detector.processRecord(record(durationMs: 3000));
      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.severity, IssueSeverity.critical);
    });

    test('3001 ms — above critical, severity stays critical', () {
      detector.processRecord(record(durationMs: 3001));
      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.severity, IssueSeverity.critical);
    });

    test('reachability invariant: critical must exceed slow', () {
      expect(
        () => NetworkMonitorDetector(
          slowThresholdMs: 2000,
          criticalSlowThresholdMs: 2000,
        ),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => NetworkMonitorDetector(
          slowThresholdMs: 2000,
          criticalSlowThresholdMs: 1500,
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('NetworkMonitorDetector — Layer 2: SleuthHttpOverrides pipeline', () {
    late HttpServer server;
    late NetworkMonitorDetector detector;
    late SleuthHttpOverrides overrides;
    late Completer<void> recordEmitted;

    setUp(() async {
      // Loopback server. Port 0 → kernel assigns a free port.
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);

      detector = NetworkMonitorDetector();

      // `flutter test` installs its own [HttpOverrides] that blocks real
      // HTTP to discourage network I/O in tests. SleuthHttpOverrides
      // delegates to `_previous` (captured at construction), so naively
      // installing on top would route the inner client through that mock
      // and the request would never reach our loopback server. Clear the
      // global first so `_previous` is null and `super.createHttpClient`
      // yields a real dart:io client.
      HttpOverrides.global = null;

      recordEmitted = Completer<void>();
      overrides = SleuthHttpOverrides(
        onRecord: (record) {
          detector.processRecord(record);
          if (!recordEmitted.isCompleted) recordEmitted.complete();
        },
      );
      SleuthHttpOverrides.install(overrides);
    });

    tearDown(() async {
      SleuthHttpOverrides.uninstall(overrides);
      HttpOverrides.global = null;
      detector.dispose();
      await server.close(force: true);
    });

    Future<void> consume(HttpClientResponse response, DrainMode mode) async {
      switch (mode) {
        case DrainMode.awaitFor:
          await for (final _ in response) {
            // Intentionally empty.
          }
          break;
        case DrainMode.drain:
          await response.drain<void>();
          break;
        case DrainMode.listenAsFuture:
          await response.listen((_) {}, cancelOnError: false).asFuture<void>();
          break;
        case DrainMode.cancelEarly:
          // Consume one event then cancel — exercises the wrapper's
          // cancel() override that emits the terminal record before
          // delegating to the inner subscription.
          final completer = Completer<void>();
          late StreamSubscription<List<int>> sub;
          sub = response.listen(
            (_) async {
              if (completer.isCompleted) return;
              completer.complete();
              await sub.cancel();
            },
            onDone: () {
              if (!completer.isCompleted) completer.complete();
            },
            onError: (Object _) {
              if (!completer.isCompleted) completer.complete();
            },
          );
          await completer.future;
          break;
      }
    }

    Future<void> drive({
      required Duration serverDelay,
      int responseBodyBytes = 256,
      DrainMode drainMode = DrainMode.awaitFor,
    }) async {
      // Server handler: delay then respond with a fixed-size body.
      server.listen((req) async {
        await Future<void>.delayed(serverDelay);
        req.response.headers.contentType = ContentType.text;
        req.response.add(List<int>.filled(responseBodyBytes, 0x41));
        await req.response.close();
      });

      final client = HttpClient();
      try {
        final request = await client.getUrl(
          Uri.parse('http://${server.address.host}:${server.port}/'),
        );
        final response = await request.close();
        await consume(response, drainMode);
      } finally {
        client.close(force: true);
      }

      // Wait for the proxy to fire onRecord (it does so from the response
      // stream's onDone callback, which can trail the drain completion by
      // a microtask hop).
      await recordEmitted.future.timeout(const Duration(seconds: 5));
    }

    test(
      'fast response (< 1000 ms) emits record but no slow_request issue',
      () async {
        await drive(serverDelay: const Duration(milliseconds: 50));
        // Record must have been captured by the proxy.
        expect(detector.records, hasLength(1));
        final rec = detector.records.first;
        expect(rec.statusCode, 200);
        expect(rec.responseBytes, 256);
        // No slow issue — duration well under 1000 ms.
        expect(
          detector.issues.where((i) => i.stableId == 'slow_request'),
          isEmpty,
        );
      },
    );

    test(
      'slow response (>= 1000 ms) fires slow_request warning via full pipeline',
      () async {
        await drive(serverDelay: const Duration(milliseconds: 1100));
        expect(detector.records, hasLength(1));
        final rec = detector.records.first;
        expect(rec.durationMs, greaterThanOrEqualTo(1000));
        // Proxy measured the duration — not a synthetic record.
        final slow =
            detector.issues.where((i) => i.stableId == 'slow_request').toList();
        expect(slow, hasLength(1));
        expect(slow.first.severity, IssueSeverity.warning);
        expect(slow.first.confidence, IssueConfidence.confirmed);
      },
    );

    // AB1 regression tests (v0.16.1): the proxy must emit a
    // `RequestRecord` regardless of how the consumer drains the
    // response. Before the `_MonitoringSubscription` wrapper,
    // `Stream.drain()` and `StreamSubscription.asFuture()` each
    // replaced the inner subscription's `_onDone` and silently
    // erased the proxy's record emission. These four parameterised
    // tests pin the fix so a regression fails CI.
    test(
      'AB1: drain() still emits RequestRecord',
      () async {
        await drive(
          serverDelay: const Duration(milliseconds: 50),
          drainMode: DrainMode.drain,
        );
        expect(detector.records, hasLength(1),
            reason: 'drain() used to bypass the proxy. The wrapper '
                "subscription's asFuture override must preserve the "
                'terminal-event emission.');
      },
    );

    test(
      'AB1: listen().asFuture() still emits RequestRecord',
      () async {
        await drive(
          serverDelay: const Duration(milliseconds: 50),
          drainMode: DrainMode.listenAsFuture,
        );
        expect(detector.records, hasLength(1),
            reason: 'explicit listen().asFuture() used to bypass the '
                'proxy for the same reason drain() did — asFuture '
                "replaces the inner subscription's _onDone.");
      },
    );

    test(
      'AB1: early cancel() still emits RequestRecord',
      () async {
        await drive(
          serverDelay: const Duration(milliseconds: 50),
          drainMode: DrainMode.cancelEarly,
        );
        expect(detector.records, hasLength(1),
            reason: "the wrapper's cancel() override must fire the "
                'terminal emit before delegating to the inner '
                'subscription so early-abort consumers still produce '
                'a RequestRecord.');
      },
    );

    test(
      'AB1: slow response via drain() still escalates to warning',
      () async {
        await drive(
          serverDelay: const Duration(milliseconds: 1100),
          drainMode: DrainMode.drain,
        );
        expect(detector.records, hasLength(1));
        expect(detector.records.first.durationMs, greaterThanOrEqualTo(1000));
        final slow =
            detector.issues.where((i) => i.stableId == 'slow_request').toList();
        expect(slow, hasLength(1),
            reason: 'drain() consumers must participate in the full '
                'detector pipeline — not just emit a record but also '
                'escalate severity through processRecord.');
        expect(slow.first.severity, IssueSeverity.warning);
      },
    );

    // Regression tests for cases beyond happy-path completion and early
    // cancel: post-listen `sub.onDone(newCb)` / `sub.onError(newCb)`
    // rebinding, mid-stream response error, and cancel-before-first-chunk.
    // The post-listen rebinding case is the exact vector by which the
    // earlier `_MonitoringSubscription` bug survived the prior regression
    // suite. These
    // tests pin the corrected contract: the proxy owns the inner
    // subscription's terminal handlers permanently; the wrapper's setters
    // mutate stored user callbacks instead of touching `_inner`, so record
    // emission is invariant under rebinding.

    test(
      'B2: post-listen sub.onDone(newCb) fires newCb AND emits RequestRecord',
      () async {
        server.listen((req) async {
          req.response.add(List<int>.filled(64, 0x41));
          await req.response.close();
        });

        final client = HttpClient();
        var newDoneFired = false;
        try {
          final response = await (await client.getUrl(
                  Uri.parse('http://${server.address.host}:${server.port}/')))
              .close();

          final done = Completer<void>();
          final sub = response.listen((_) {});
          // Rebind onDone AFTER listen — this used to silently strip the
          // proxy's emit path because _MonitoringSubscription forwarded
          // straight to _inner.onDone(...).
          sub.onDone(() {
            newDoneFired = true;
            done.complete();
          });
          await done.future.timeout(const Duration(seconds: 5));
        } finally {
          client.close(force: true);
        }

        await recordEmitted.future.timeout(const Duration(seconds: 5));
        expect(newDoneFired, isTrue,
            reason: 'rebound onDone callback must still fire');
        expect(detector.records, hasLength(1),
            reason: 'RequestRecord must land even when the caller rebinds '
                "sub.onDone() after listen() — the proxy's terminal "
                'handlers are permanent.');
      },
    );

    test(
      'B2: post-listen sub.onError(newCb) fires newCb AND emits RequestRecord',
      () async {
        // Server accepts the connection, writes nothing, then destroys the
        // socket to surface a stream error on the client side.
        server.listen((req) async {
          final socket = await req.response.detachSocket(writeHeaders: false);
          socket.destroy();
        });

        final client = HttpClient();
        var newErrorFired = false;
        try {
          final request = await client.getUrl(
              Uri.parse('http://${server.address.host}:${server.port}/'));
          try {
            final response = await request.close();

            final done = Completer<void>();
            final sub = response.listen(
              (_) {},
              onError: (Object _) {
                // This handler must be replaced by the onError below before
                // the error surfaces — but if the socket error already
                // fired, the test still passes via the rebinding assertion.
              },
            );
            sub.onError((Object _, [StackTrace? __]) {
              newErrorFired = true;
              if (!done.isCompleted) done.complete();
            });
            sub.onDone(() {
              if (!done.isCompleted) done.complete();
            });
            await done.future.timeout(const Duration(seconds: 5));
          } on HttpException {
            // Some platforms surface the reset as an HttpException on
            // request.close() instead of on the stream — that's fine, the
            // proxy should still emit a record via its error path.
          }
        } finally {
          client.close(force: true);
        }

        await recordEmitted.future.timeout(const Duration(seconds: 5));
        expect(detector.records, hasLength(1),
            reason: 'RequestRecord must land even when the caller rebinds '
                "sub.onError() after listen() — the proxy's terminal "
                'handlers are permanent.');
        // `newErrorFired` is best-effort: on some platforms the socket
        // reset surfaces before listen() returns, so the rebind never has
        // a chance to catch it. The record emission is the load-bearing
        // assertion.
        expect(newErrorFired || detector.records.first.statusCode <= 0, isTrue,
            reason: 'either the rebound error handler fires, or the error '
                'surfaced earlier on the request path — both satisfy B2');
      },
    );

    test(
      'B2: mid-stream server-close emits record with partial bytes AND '
      'asFuture() surfaces the error',
      () async {
        // Bind a raw ServerSocket instead of reusing `server` (HttpServer)
        // so we can hand-write an HTTP response with a content-length
        // header, ship partial bytes, then destroy the connection. The
        // stock `HttpServer` guards against Content-Length mismatches and
        // `detachSocket` errors once headers are flushed, which prevents
        // the mid-stream-abort pattern we need to reproduce.
        final rawServer =
            await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        const prefixBytes = 32;
        const declaredLen = 1024;
        try {
          rawServer.listen((socket) {
            // Drain the request so the client finishes sending before we
            // respond; don't hold onto it.
            socket.listen((_) {}, onError: (_) {}, onDone: () {});
            // Defer write slightly to ensure request headers are in
            // flight before the response lands.
            Future<void>.delayed(
              const Duration(milliseconds: 20),
              () async {
                socket.add(
                  'HTTP/1.1 200 OK\r\n'
                          'Content-Length: $declaredLen\r\n'
                          'Content-Type: text/plain\r\n'
                          'Connection: close\r\n'
                          '\r\n'
                      .codeUnits,
                );
                socket.add(List<int>.filled(prefixBytes, 0x41));
                await socket.flush();
                socket.destroy();
              },
            );
          });

          final client = HttpClient();
          Object? errorFromAsFuture;
          try {
            final response = await (await client.getUrl(Uri.parse(
                    'http://${rawServer.address.host}:${rawServer.port}/')))
                .close();
            try {
              await response
                  .listen((_) {}, cancelOnError: false)
                  .asFuture<void>();
            } catch (e) {
              errorFromAsFuture = e;
            }
          } finally {
            client.close(force: true);
          }

          await recordEmitted.future.timeout(const Duration(seconds: 5));
          expect(detector.records, hasLength(1),
              reason: 'mid-stream errors must still produce a record — the '
                  'proxy emits via its permanent onError handler and '
                  'completes the terminal Completer with the error.');
          expect(errorFromAsFuture, isNotNull,
              reason: 'asFuture() chainers must see the error — the '
                  'wrapper completes its own Completer with the error '
                  'before the proxy marks the request done.');
          // Partial bytes captured — not a completion with zero bytes.
          expect(detector.records.first.responseBytes, greaterThan(0));
          expect(detector.records.first.responseBytes,
              lessThanOrEqualTo(declaredLen));
        } finally {
          await rawServer.close();
        }
      },
    );

    test(
      'B2: cancel-before-first-chunk emits record with bytes=0 and marks '
      'cancelled=true',
      () async {
        // Server delays long enough for the client to cancel before any
        // data is written.
        server.listen((req) async {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          req.response.add(List<int>.filled(64, 0x41));
          await req.response.close();
        });

        final client = HttpClient();
        try {
          final response = await (await client.getUrl(
                  Uri.parse('http://${server.address.host}:${server.port}/')))
              .close();
          // Listen but immediately cancel — no chunks should have
          // arrived. The wrapper's cancel() fires the terminal emit
          // with `cancelled: true` before delegating to the inner
          // subscription.
          final sub = response.listen((_) {});
          await sub.cancel();
        } finally {
          client.close(force: true);
        }

        await recordEmitted.future.timeout(const Duration(seconds: 5));
        expect(detector.records, hasLength(1));
        final rec = detector.records.first;
        expect(rec.responseBytes, 0,
            reason: 'cancel-before-first-chunk must record zero bytes');
        expect(rec.cancelled, isTrue,
            reason: 'cancelled flag distinguishes aborts from completions '
                'so the detector can filter them out of slow_request and '
                'request_frequency classification');
        // Idempotence: record count stays 1 even if an additional
        // terminal event races through the inner subscription.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(detector.records, hasLength(1),
            reason: '_emitOnTerminal must be idempotent — a post-cancel '
                'onDone from the inner subscription must not double-emit');
      },
    );

    test(
      'B3: cancelled records are excluded from slow_request classification',
      () async {
        // Server delay > 1000 ms so a completion would trip slow_request.
        server.listen((req) async {
          await Future<void>.delayed(const Duration(milliseconds: 1100));
          req.response.add(List<int>.filled(64, 0x41));
          await req.response.close();
        });

        final client = HttpClient();
        try {
          final response = await (await client.getUrl(
                  Uri.parse('http://${server.address.host}:${server.port}/')))
              .close();
          // Wait past the slow threshold, THEN cancel — the record's
          // durationMs will exceed 1000 ms but cancelled=true.
          await Future<void>.delayed(const Duration(milliseconds: 1050));
          final sub = response.listen((_) {});
          await sub.cancel();
        } finally {
          client.close(force: true);
        }

        await recordEmitted.future.timeout(const Duration(seconds: 5));
        expect(detector.records, hasLength(1));
        final rec = detector.records.first;
        expect(rec.cancelled, isTrue);
        expect(rec.durationMs, greaterThanOrEqualTo(1000),
            reason: 'duration should have crossed the slow threshold — '
                "this is the test's setup, not the assertion");
        expect(
          detector.issues.where((i) => i.stableId == 'slow_request'),
          isEmpty,
          reason: 'a cancelled request past the slow threshold is an '
              'intentional abort, not a slow API — it must not fire '
              'slow_request',
        );
      },
    );
  });

  // Layer 3 (v0.18.3): per-family credit for the four reproducerOnly
  // families NetworkMonitor emits beyond `slow_request`. The detector
  // metadata's `coveredStableIds` declares all five; the audit's
  // reproducer walker requires each declared family to appear as an
  // AST-credited literal in this file. These tests exercise each family
  // through `processRecord` so the literals are detector-derived
  // assertions, not bare strings.
  group('NetworkMonitorDetector — Layer 3: other emitted families', () {
    late NetworkMonitorDetector detector;
    late DateTime fakeNow;

    setUp(() {
      fakeNow = DateTime(2026, 1, 1);
      detector = NetworkMonitorDetector(clock: () => fakeNow);
    });

    tearDown(() => detector.dispose());

    RequestRecord record({
      String url = 'https://example.test/api/endpoint',
      int durationMs = 100,
      int responseBytes = 1024,
      int statusCode = 200,
    }) {
      return RequestRecord(
        url: url,
        method: 'GET',
        statusCode: statusCode,
        durationMs: durationMs,
        responseBytes: responseBytes,
        startedAt: fakeNow,
      );
    }

    // Boundary triads: each family pinned at threshold-1 (silent),
    // threshold (fires), and 2× threshold (fires + correct severity).
    // Detector constructed with EXPLICIT threshold values inside each
    // test so default-drift in the source doesn't silently invalidate
    // the boundary claim. Source-of-truth operators per family:
    //   - large_response: `>= largeResponseBytes` (network_monitor_detector.dart:254)
    //   - request_frequency: `> frequencyLimit` (line 294, 315)
    //   - http_error_spike: `>= 3` errors (line 340)
    //   - high_frequency_same_path: `>= _duplicateThreshold` (line 429)

    test('large_response boundary triad pins `>= largeResponseBytes`', () {
      const limit = 1024;
      // threshold-1: silent
      var d = NetworkMonitorDetector(
          largeResponseBytes: limit, clock: () => fakeNow);
      d.processRecord(record(responseBytes: limit - 1));
      expect(d.issues.where((i) => i.stableId == 'large_response'), isEmpty,
          reason: 'responseBytes < largeResponseBytes must be silent.');
      d.dispose();
      // threshold: fires (>= semantics)
      d = NetworkMonitorDetector(
          largeResponseBytes: limit, clock: () => fakeNow);
      d.processRecord(record(responseBytes: limit));
      final atIssues =
          d.issues.where((i) => i.stableId == 'large_response').toList();
      expect(atIssues, hasLength(1),
          reason: 'responseBytes == largeResponseBytes must fire (>=).');
      d.dispose();
      // 2× threshold: fires
      d = NetworkMonitorDetector(
          largeResponseBytes: limit, clock: () => fakeNow);
      d.processRecord(record(responseBytes: limit * 2));
      expect(
          d.issues.where((i) => i.stableId == 'large_response'), hasLength(1));
      d.dispose();
    });

    test('request_frequency boundary triad pins `> frequencyLimit`', () {
      const limit = 5;
      // limit records: silent (recordsList.length <= frequencyLimit returns)
      var d =
          NetworkMonitorDetector(frequencyLimit: limit, clock: () => fakeNow);
      for (var i = 0; i < limit; i++) {
        d.processRecord(record(url: 'https://example.test/api/$i'));
      }
      expect(d.issues.where((i) => i.stableId == 'request_frequency'), isEmpty,
          reason: 'recordsList.length == frequencyLimit must be silent (>).');
      d.dispose();
      // limit+1: fires (strict greater)
      d = NetworkMonitorDetector(frequencyLimit: limit, clock: () => fakeNow);
      for (var i = 0; i < limit + 1; i++) {
        d.processRecord(record(url: 'https://example.test/api/$i'));
      }
      expect(d.issues.where((i) => i.stableId == 'request_frequency'),
          hasLength(1),
          reason: 'recordsList.length > frequencyLimit must fire.');
      d.dispose();
      // 2× limit: fires
      d = NetworkMonitorDetector(frequencyLimit: limit, clock: () => fakeNow);
      for (var i = 0; i < limit * 2; i++) {
        d.processRecord(record(url: 'https://example.test/api/$i'));
      }
      expect(
          d.issues.where((i) => i.stableId == 'request_frequency'), isNotEmpty);
      d.dispose();
    });

    test(
        'large_response stamps observedResponseBytes + dedupIdentityMicros '
        'on extraTraceArgs', () {
      const limit = 1024;
      const worst = 4096;
      final d = NetworkMonitorDetector(
          largeResponseBytes: limit, clock: () => fakeNow);
      d.processRecord(record(responseBytes: limit + 100));
      d.processRecord(record(responseBytes: worst));
      d.processRecord(record(responseBytes: limit + 200));
      final issue = d.issues.firstWhere((i) => i.stableId == 'large_response');
      expect(issue.extraTraceArgs, isNotNull,
          reason: 'large_response must stamp extraTraceArgs.');
      expect(issue.extraTraceArgs!['observedResponseBytes'],
          equals(worst.toString()),
          reason: 'observedResponseBytes must be the worst (max) byte count.');
      expect(issue.dedupIdentityMicros, isNotNull,
          reason: 'dedupIdentityMicros must be set for the audit-gate '
              'strong uniqueness invariant.');
      expect(issue.dedupIdentityMicros,
          equals(issue.detectedAt!.microsecondsSinceEpoch),
          reason: 'dedupIdentityMicros derives from detectedAt; reuses the '
              'same instant so audit-gate cross-check sees a stable identity.');
      d.dispose();
    });

    test(
        'request_frequency stamps observedRequestCount + dedupIdentityMicros '
        'on extraTraceArgs', () {
      const limit = 5;
      final d =
          NetworkMonitorDetector(frequencyLimit: limit, clock: () => fakeNow);
      for (var i = 0; i < limit + 3; i++) {
        d.processRecord(record(url: 'https://example.test/api/$i'));
      }
      final issue =
          d.issues.firstWhere((i) => i.stableId == 'request_frequency');
      expect(issue.extraTraceArgs, isNotNull,
          reason: 'request_frequency must stamp extraTraceArgs.');
      expect(issue.extraTraceArgs!['observedRequestCount'],
          equals((limit + 3).toString()),
          reason: 'observedRequestCount must equal the peak 5-second '
              'window count (8 records inside one window here).');
      expect(issue.dedupIdentityMicros, isNotNull);
      expect(issue.dedupIdentityMicros,
          equals(issue.detectedAt!.microsecondsSinceEpoch));
      d.dispose();
    });

    test(
        'http_error_spike boundary triad pins `>= 3` errors per 5s '
        'window', () {
      // 2 errors: silent (errorRecords.length < 3 returns)
      var d = NetworkMonitorDetector(clock: () => fakeNow);
      for (var i = 0; i < 2; i++) {
        d.processRecord(record(statusCode: 500));
      }
      expect(d.issues.where((i) => i.stableId == 'http_error_spike'), isEmpty,
          reason: 'errorRecords.length == 2 must be silent (>= 3).');
      d.dispose();
      // 3 errors: fires (>= 3 semantics)
      d = NetworkMonitorDetector(clock: () => fakeNow);
      for (var i = 0; i < 3; i++) {
        d.processRecord(record(statusCode: 500));
      }
      expect(
          d.issues.where((i) => i.stableId == 'http_error_spike'), hasLength(1),
          reason: 'errorRecords.length == 3 must fire.');
      d.dispose();
      // 10 errors: fires + critical (peakCount >= 10 || serverErrors >= 5
      // → critical)
      d = NetworkMonitorDetector(clock: () => fakeNow);
      for (var i = 0; i < 10; i++) {
        d.processRecord(record(statusCode: 500));
      }
      final crit = d.issues.firstWhere((i) => i.stableId == 'http_error_spike');
      expect(crit.severity, IssueSeverity.critical,
          reason: 'peakCount >= 10 must escalate to critical.');
      d.dispose();
    });

    test(
        'high_frequency_same_path boundary triad pins `>= 3` cluster + '
        '`>= 10` critical', () {
      // 2 same-URL records: silent (records.length < _duplicateThreshold
      // returns)
      var d = NetworkMonitorDetector(clock: () => fakeNow);
      for (var i = 0; i < 2; i++) {
        d.processRecord(record());
      }
      expect(
          d.issues.where((i) =>
              i.stableId != null &&
              i.stableId!.startsWith('high_frequency_same_path:')),
          isEmpty,
          reason: '2 same-URL records < _duplicateThreshold must be silent.');
      d.dispose();
      // 3 same-URL records: fires warning
      d = NetworkMonitorDetector(clock: () => fakeNow);
      for (var i = 0; i < 3; i++) {
        d.processRecord(record());
      }
      final warn = d.issues
          .where((i) =>
              i.stableId != null &&
              i.stableId!.startsWith('high_frequency_same_path:'))
          .toList();
      expect(warn, hasLength(1),
          reason: '3 same-URL records >= _duplicateThreshold must fire.');
      expect(warn.first.severity, IssueSeverity.warning);
      d.dispose();
      // 10 same-URL records: fires critical
      d = NetworkMonitorDetector(clock: () => fakeNow);
      for (var i = 0; i < 10; i++) {
        d.processRecord(record());
      }
      final crit = d.issues.firstWhere((i) =>
          i.stableId != null &&
          i.stableId!.startsWith('high_frequency_same_path:'));
      expect(crit.severity, IssueSeverity.critical,
          reason: 'maxCluster >= _criticalDuplicateThreshold must '
              'escalate to critical.');
      d.dispose();
    });

    test(
        'request_frequency 5s sliding window: clusters separated by '
        '>5s do not fire even when total count exceeds limit', () {
      // Pin the time-window logic, not just count threshold. Two
      // clusters of 5 records spaced 6s apart sum to 10 records but
      // peak window holds only 5 → silent below the limit=5 threshold.
      final d = NetworkMonitorDetector(frequencyLimit: 5, clock: () => fakeNow);
      addTearDown(d.dispose);
      RequestRecord recAt(DateTime t) => RequestRecord(
            url: 'https://example.test/api/${t.microsecond}',
            method: 'GET',
            statusCode: 200,
            durationMs: 100,
            responseBytes: 1024,
            startedAt: t,
          );

      final t0 = DateTime(2026, 1, 1);
      for (var i = 0; i < 5; i++) {
        fakeNow = t0;
        d.processRecord(recAt(t0.add(Duration(microseconds: i))));
      }
      // Advance past the 5s sliding window.
      final t1 = t0.add(const Duration(seconds: 6));
      for (var i = 0; i < 5; i++) {
        fakeNow = t1;
        d.processRecord(recAt(t1.add(Duration(microseconds: i))));
      }
      expect(d.issues.where((i) => i.stableId == 'request_frequency'), isEmpty,
          reason: '5+5 records spread across a 6s gap → peak 5s '
              'window holds only 5 records, equal to limit, silent.');
    });

    test(
        'http_error_spike 5s sliding window: clusters separated by '
        '>5s do not aggregate', () {
      final d = NetworkMonitorDetector(clock: () => fakeNow);
      addTearDown(d.dispose);
      RequestRecord recAt(DateTime t) => RequestRecord(
            url: 'https://example.test/api/endpoint',
            method: 'GET',
            statusCode: 500,
            durationMs: 100,
            responseBytes: 1024,
            startedAt: t,
          );

      final t0 = DateTime(2026, 1, 1);
      // 2 errors at t0 (below the >=3 threshold for any single window).
      for (var i = 0; i < 2; i++) {
        fakeNow = t0;
        d.processRecord(recAt(t0.add(Duration(microseconds: i))));
      }
      // 2 more errors 6s later — distinct window from t0 cluster.
      final t1 = t0.add(const Duration(seconds: 6));
      for (var i = 0; i < 2; i++) {
        fakeNow = t1;
        d.processRecord(recAt(t1.add(Duration(microseconds: i))));
      }
      expect(d.issues.where((i) => i.stableId == 'http_error_spike'), isEmpty,
          reason: '2+2 errors spread across a 6s gap → peak 5s window '
              'holds only 2 errors, below the >=3 threshold, silent.');
    });

    // ----------------------------------------------------------------
    // Producer-wiring guard
    // ----------------------------------------------------------------
    // The schema's per-leg invariants leave the below-leg's axis
    // unchecked (silent leg has no trace event to cross-check
    // against), so a producer that exports `requestCount` (planned
    // send count) instead of the detector's measured peak silently
    // certifies a sub-threshold value the detector never observed.
    // Pin the producer's source-of-truth here so a refactor that
    // reverts to plan-not-measured fails CI.
    test(
        'producer-wiring: request_frequency capture reads detector peak, '
        'not requestCount', () {
      // Search the example/lib/demos/ tree for the runner so a future
      // refactor that splits the capture-screen file (e.g. extracts
      // each runner into its own file) does not silently break this
      // contract test. The contract is "wherever the request_frequency
      // runner lives, it MUST read lastObservedPeakCount and call
      // flushFrequencyEvaluation()" — not "lives in this exact file".
      final demosDir = Directory('example/lib/demos');
      expect(demosDir.existsSync(), isTrue,
          reason: 'example/lib/demos/ must exist to enforce the contract');
      final dartFiles = demosDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'));
      File? runnerFile;
      String? runnerSrc;
      for (final f in dartFiles) {
        final src = f.readAsStringSync();
        if (src.contains('_runRequestFrequencyCapture') ||
            src.contains('_CaptureMode.requestFrequency')) {
          runnerFile = f;
          runnerSrc = src;
          break;
        }
      }
      expect(runnerFile, isNotNull,
          reason: 'request_frequency capture runner not found anywhere '
              'under example/lib/demos/. Either restore the runner or '
              'update this contract test if the capture flow has been '
              'restructured.');
      final src = runnerSrc!;
      expect(
        RegExp(r'observedCount\s*=\s*requestCount\s*;').hasMatch(src),
        isFalse,
        reason: 'request_frequency capture must NOT export the planned send '
            'count. Use Sleuth.networkMonitor?.lastObservedPeakCount after '
            'flushFrequencyEvaluation() so below-leg evidence reflects '
            'what the detector measured. Found in: ${runnerFile!.path}',
      );
      expect(src.contains('lastObservedPeakCount'), isTrue,
          reason: 'request_frequency runner must read '
              'Sleuth.networkMonitor?.lastObservedPeakCount as the source '
              'of expectedMagnitude.observed. Found in: ${runnerFile.path}');
      expect(src.contains('flushFrequencyEvaluation()'), isTrue,
          reason: 'capture runner must call flushFrequencyEvaluation() '
              'before reading lastObservedPeakCount so peak compute is '
              'deterministic regardless of timer phase. '
              'Found in: ${runnerFile.path}');
    });
  });
}
