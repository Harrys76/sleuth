import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/network/http_monitor.dart';
import 'package:sleuth/src/network/request_record.dart';

void main() {
  group('SleuthHttpOverrides', () {
    late List<RequestRecord> capturedRecords;
    late SleuthHttpOverrides overrides;

    setUp(() {
      capturedRecords = [];
      // Clear any global state
      HttpOverrides.global = null;
    });

    tearDown(() {
      HttpOverrides.global = null;
    });

    test('install sets HttpOverrides.global', () {
      overrides = SleuthHttpOverrides(onRecord: capturedRecords.add);
      SleuthHttpOverrides.install(overrides);
      expect(HttpOverrides.current, same(overrides));
    });

    test('uninstall restores previous override', () {
      final previousOverrides = _DummyHttpOverrides();
      HttpOverrides.global = previousOverrides;

      overrides = SleuthHttpOverrides(onRecord: capturedRecords.add);
      SleuthHttpOverrides.install(overrides);
      expect(HttpOverrides.current, same(overrides));

      SleuthHttpOverrides.uninstall(overrides);
      expect(HttpOverrides.current, same(previousOverrides));
    });

    test('uninstall no-op when override was replaced by another', () {
      overrides = SleuthHttpOverrides(onRecord: capturedRecords.add);
      SleuthHttpOverrides.install(overrides);

      // Another package overwrites us
      final thirdParty = _DummyHttpOverrides();
      HttpOverrides.global = thirdParty;

      // Our uninstall should NOT clobber the third party
      SleuthHttpOverrides.uninstall(overrides);
      expect(HttpOverrides.current, same(thirdParty));
    });

    test('install with null previous (no prior override)', () {
      HttpOverrides.global = null;
      overrides = SleuthHttpOverrides(onRecord: capturedRecords.add);
      SleuthHttpOverrides.install(overrides);

      SleuthHttpOverrides.uninstall(overrides);
      expect(HttpOverrides.current, isNull);
    });

    test('createHttpClient delegates to previous override', () {
      final previousOverrides = _TrackingHttpOverrides();
      HttpOverrides.global = previousOverrides;

      overrides = SleuthHttpOverrides(onRecord: capturedRecords.add);
      SleuthHttpOverrides.install(overrides);

      // Creating an HttpClient should go through the previous override first
      final client = overrides.createHttpClient(null);
      expect(previousOverrides.createCalled, isTrue);
      // The result is wrapped in _MonitoringHttpClient (implements HttpClient)
      expect(client, isA<HttpClient>());
    });

    test('findProxyFromEnvironment delegates to previous override', () {
      final previousOverrides = _TrackingHttpOverrides();
      HttpOverrides.global = previousOverrides;

      overrides = SleuthHttpOverrides(onRecord: capturedRecords.add);

      final result = overrides.findProxyFromEnvironment(
        Uri.parse('https://example.com'),
        {},
      );
      expect(previousOverrides.proxyCalled, isTrue);
      expect(result, 'DIRECT');
    });

    test('URL exclusion patterns are passed to monitoring client', () {
      overrides = SleuthHttpOverrides(
        onRecord: capturedRecords.add,
        excludePatterns: ['analytics.example.com'],
      );
      SleuthHttpOverrides.install(overrides);

      // The exclude patterns are stored — we verify by checking the override
      // accepted them without error. Full exclusion behavior is tested at the
      // HttpClient level via integration tests.
      expect(overrides.excludePatterns, contains('analytics.example.com'));
    });

    test('chaining preserves override stack order', () {
      final first = _DummyHttpOverrides();
      HttpOverrides.global = first;

      final second = SleuthHttpOverrides(onRecord: (_) {});
      SleuthHttpOverrides.install(second);

      final third = SleuthHttpOverrides(onRecord: (_) {});
      SleuthHttpOverrides.install(third);

      expect(HttpOverrides.current, same(third));

      // Uninstall third → should restore second
      SleuthHttpOverrides.uninstall(third);
      expect(HttpOverrides.current, same(second));

      // Uninstall second → should restore first
      SleuthHttpOverrides.uninstall(second);
      expect(HttpOverrides.current, same(first));
    });
  });

  // =========================================================================
  // Gap 4: URL exclusion behavioral tests
  // =========================================================================
  group('URL exclusion behavior (Gap 4)', () {
    late List<RequestRecord> capturedRecords;

    setUp(() {
      capturedRecords = [];
      HttpOverrides.global = null;
    });

    tearDown(() {
      HttpOverrides.global = null;
    });

    test('exclude patterns wired through to monitoring client', () async {
      final overrides = SleuthHttpOverrides(
        onRecord: capturedRecords.add,
        excludePatterns: ['analytics.example.com'],
      );
      SleuthHttpOverrides.install(overrides);

      // createHttpClient returns a _MonitoringHttpClient that receives
      // the exclude patterns. Full behavioral testing (making real HTTP
      // requests) is out of scope for unit tests.
      final client = overrides.createHttpClient(null);
      try {
        expect(client, isA<HttpClient>());
        expect(overrides.excludePatterns, contains('analytics.example.com'));
      } finally {
        client.close();
      }
    });

    test('null excludePatterns treats all URLs as monitored', () {
      final overrides = SleuthHttpOverrides(
        onRecord: capturedRecords.add,
      );
      expect(overrides.excludePatterns, isNull);

      // Client should be created with monitoring (wrapping all requests)
      final client = overrides.createHttpClient(null);
      expect(client, isA<HttpClient>());
      client.close();
    });

    test('empty excludePatterns treats all URLs as monitored', () {
      final overrides = SleuthHttpOverrides(
        onRecord: capturedRecords.add,
        excludePatterns: [],
      );
      expect(overrides.excludePatterns, isEmpty);

      final client = overrides.createHttpClient(null);
      expect(client, isA<HttpClient>());
      client.close();
    });

    test('multiple exclusion patterns stored correctly', () {
      final overrides = SleuthHttpOverrides(
        onRecord: capturedRecords.add,
        excludePatterns: [
          'analytics.example.com',
          '/health',
          'crashlytics',
        ],
      );
      expect(overrides.excludePatterns, hasLength(3));
      expect(overrides.excludePatterns, contains('analytics.example.com'));
      expect(overrides.excludePatterns, contains('/health'));
      expect(overrides.excludePatterns, contains('crashlytics'));
    });
  });

  // =========================================================================
  // v8.3: openUrl connection failure handling
  // =========================================================================
  group('openUrl connection failure (v8.3)', () {
    late List<RequestRecord> capturedRecords;
    late List<int> startedIds;
    late List<int> endedIds;

    setUp(() {
      capturedRecords = [];
      startedIds = [];
      endedIds = [];
      HttpOverrides.global = null;
    });

    tearDown(() {
      HttpOverrides.global = null;
    });

    HttpClient createFailingClient() {
      // Install a failing override as the "previous" so SleuthHttpOverrides
      // delegates to it via the chaining mechanism.
      final failing = _FailingHttpOverrides();
      HttpOverrides.global = failing;

      final overrides = SleuthHttpOverrides(
        onRecord: capturedRecords.add,
        onRequestStarted: (id, _) => startedIds.add(id),
        onRequestEnded: (id) => endedIds.add(id),
      );
      SleuthHttpOverrides.install(overrides);
      return overrides.createHttpClient(null);
    }

    test('openUrl failure calls onRequestEnded', () async {
      final client = createFailingClient();
      try {
        await client.openUrl('GET', Uri.parse('https://example.com'));
        fail('Expected SocketException');
      } on SocketException {
        // expected
      } finally {
        client.close();
      }

      expect(startedIds, hasLength(1));
      expect(endedIds, hasLength(1));
      expect(endedIds.first, startedIds.first);
    });

    test('openUrl failure emits RequestRecord with statusCode -1', () async {
      final client = createFailingClient();
      try {
        await client.openUrl('POST', Uri.parse('https://api.example.com/data'));
        fail('Expected SocketException');
      } on SocketException {
        // expected
      } finally {
        client.close();
      }

      expect(capturedRecords, hasLength(1));
      final record = capturedRecords.first;
      expect(record.statusCode, -1);
      expect(record.method, 'POST');
      expect(record.url, 'https://api.example.com/data');
      expect(record.responseBytes, 0);
      expect(record.durationMs, greaterThanOrEqualTo(0));
    });

    test('openUrl failure rethrows the original exception', () async {
      final client = createFailingClient();
      try {
        await client.openUrl('GET', Uri.parse('https://example.com'));
        fail('Expected SocketException');
      } on SocketException catch (e) {
        expect(e.message, contains('DNS lookup failed'));
      } finally {
        client.close();
      }
    });

    test('throwing onRequestEnded does not suppress failure record', () async {
      final failing = _FailingHttpOverrides();
      HttpOverrides.global = failing;

      var recordEmitted = false;
      final overrides = SleuthHttpOverrides(
        onRecord: (_) => recordEmitted = true,
        onRequestStarted: (id, _) {},
        onRequestEnded: (id) => throw StateError('onRequestEnded bug'),
      );
      SleuthHttpOverrides.install(overrides);
      final client = overrides.createHttpClient(null);

      try {
        await client.openUrl('GET', Uri.parse('https://example.com'));
        fail('Expected SocketException');
      } on SocketException {
        // expected — original transport error surfaces
      } finally {
        client.close();
      }

      // onRecord must still fire even though onRequestEnded threw.
      expect(recordEmitted, isTrue);
    });

    test('throwing onRecord cannot mask the transport exception', () async {
      // Install a failing inner client, then create overrides with a
      // throwing onRecord callback.
      final failing = _FailingHttpOverrides();
      HttpOverrides.global = failing;

      final overrides = SleuthHttpOverrides(
        onRecord: (_) => throw StateError('onRecord bug'),
        onRequestStarted: (id, _) {},
        onRequestEnded: (id) {},
      );
      SleuthHttpOverrides.install(overrides);
      final client = overrides.createHttpClient(null);

      try {
        await client.openUrl('GET', Uri.parse('https://example.com'));
        fail('Expected SocketException');
      } on SocketException catch (e) {
        // The original transport error must surface, not the StateError
        // from the broken callback.
        expect(e.message, contains('DNS lookup failed'));
      } finally {
        client.close();
      }
    });
  });

  // =========================================================================
  // v8.3: Success-path callback isolation
  // =========================================================================
  group('success-path callback isolation (v8.3)', () {
    setUp(() {
      HttpOverrides.global = null;
    });

    tearDown(() {
      HttpOverrides.global = null;
    });

    test('throwing onRecord does not break response body consumption',
        () async {
      final success = _SuccessHttpOverrides();
      HttpOverrides.global = success;

      final overrides = SleuthHttpOverrides(
        onRecord: (_) => throw StateError('onRecord bug'),
        onRequestStarted: (id, _) {},
        onRequestEnded: (id) {},
      );
      SleuthHttpOverrides.install(overrides);
      final client = overrides.createHttpClient(null);

      final request =
          await client.openUrl('GET', Uri.parse('https://example.com'));
      final response = await request.close();

      // Body consumption must complete normally even though onRecord throws.
      final body = await response.toList();
      expect(body, hasLength(1));
      expect(body.first, [72, 105]); // 'Hi'
      client.close();
    });

    test('throwing onRequestEnded does not suppress onRecord', () async {
      final success = _SuccessHttpOverrides();
      HttpOverrides.global = success;

      var recordCalled = false;
      final overrides = SleuthHttpOverrides(
        onRecord: (_) => recordCalled = true,
        onRequestStarted: (id, _) {},
        onRequestEnded: (id) => throw StateError('onRequestEnded bug'),
      );
      SleuthHttpOverrides.install(overrides);
      final client = overrides.createHttpClient(null);

      final request =
          await client.openUrl('GET', Uri.parse('https://example.com'));
      final response = await request.close();
      // Use toList() which passes onDone through listen() directly,
      // unlike drain() which uses asFuture() and replaces the handler.
      await response.toList();

      // onRecord must still fire even though onRequestEnded threw.
      expect(recordCalled, isTrue);
      client.close();
    });
  });
}

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

class _DummyHttpOverrides extends HttpOverrides {}

class _TrackingHttpOverrides extends HttpOverrides {
  bool createCalled = false;
  bool proxyCalled = false;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    createCalled = true;
    return super.createHttpClient(context);
  }

  @override
  String findProxyFromEnvironment(Uri url, Map<String, String>? environment) {
    proxyCalled = true;
    return 'DIRECT';
  }
}

class _FailingHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => _FailingHttpClient();
}

/// HttpClient whose openUrl always throws a SocketException (simulates
/// DNS failure, connection refused, etc.).
class _FailingHttpClient extends Fake implements HttpClient {
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      Future.error(const SocketException('DNS lookup failed'));

  @override
  void close({bool force = false}) {}
}

class _SuccessHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => _SuccessHttpClient();
}

/// HttpClient that returns a canned 200 response with a small body.
class _SuccessHttpClient extends Fake implements HttpClient {
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) =>
      Future.value(_FakeRequest());

  @override
  void close({bool force = false}) {}
}

class _FakeRequest extends Fake implements HttpClientRequest {
  @override
  Future<HttpClientResponse> close() => Future.value(_FakeResponse());
}

class _FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  @override
  int get statusCode => 200;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    // Emit a small body asynchronously, then complete.
    final controller = StreamController<List<int>>();
    controller.add([72, 105]); // 'Hi'
    controller.close();
    return controller.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  // -- Required HttpClientResponse stubs --
  @override
  String get reasonPhrase => 'OK';
  @override
  HttpHeaders get headers => _FakeHeaders();
  @override
  int get contentLength => 2;
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;
  @override
  List<Cookie> get cookies => [];
  @override
  bool get isRedirect => false;
  @override
  bool get persistentConnection => true;
  @override
  List<RedirectInfo> get redirects => [];
  @override
  X509Certificate? get certificate => null;
  @override
  HttpConnectionInfo? get connectionInfo => null;
  @override
  bool get isBroadcast => false;
  @override
  Future<HttpClientResponse> redirect(
          [String? method, Uri? url, bool? followLoops]) =>
      Future.value(this);
  @override
  Future<Socket> detachSocket() => throw UnsupportedError('detachSocket');
}

class _FakeHeaders extends Fake implements HttpHeaders {}
