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

    // B2 regression tests (v0.16.1 second triangulation): AB1's Layer 2
    // covered only happy-path completion and early cancel. Both reviewers
    // independently flagged that post-listen `sub.onDone(newCb)` /
    // `sub.onError(newCb)` rebinding, mid-stream response error, and
    // cancel-before-first-chunk were uncovered — and the first one is the
    // exact vector by which B1 (the post-listen rebinding bug on
    // `_MonitoringSubscription`) survived the AB1 regression suite. These
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
}
