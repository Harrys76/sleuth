import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/src/network/http_monitor.dart';
import 'package:widget_watchdog/src/network/request_record.dart';

void main() {
  group('WatchdogHttpOverrides', () {
    late List<RequestRecord> capturedRecords;
    late WatchdogHttpOverrides overrides;

    setUp(() {
      capturedRecords = [];
      // Clear any global state
      HttpOverrides.global = null;
    });

    tearDown(() {
      HttpOverrides.global = null;
    });

    test('install sets HttpOverrides.global', () {
      overrides = WatchdogHttpOverrides(onRecord: capturedRecords.add);
      WatchdogHttpOverrides.install(overrides);
      expect(HttpOverrides.current, same(overrides));
    });

    test('uninstall restores previous override', () {
      final previousOverrides = _DummyHttpOverrides();
      HttpOverrides.global = previousOverrides;

      overrides = WatchdogHttpOverrides(onRecord: capturedRecords.add);
      WatchdogHttpOverrides.install(overrides);
      expect(HttpOverrides.current, same(overrides));

      WatchdogHttpOverrides.uninstall(overrides);
      expect(HttpOverrides.current, same(previousOverrides));
    });

    test('uninstall no-op when override was replaced by another', () {
      overrides = WatchdogHttpOverrides(onRecord: capturedRecords.add);
      WatchdogHttpOverrides.install(overrides);

      // Another package overwrites us
      final thirdParty = _DummyHttpOverrides();
      HttpOverrides.global = thirdParty;

      // Our uninstall should NOT clobber the third party
      WatchdogHttpOverrides.uninstall(overrides);
      expect(HttpOverrides.current, same(thirdParty));
    });

    test('install with null previous (no prior override)', () {
      HttpOverrides.global = null;
      overrides = WatchdogHttpOverrides(onRecord: capturedRecords.add);
      WatchdogHttpOverrides.install(overrides);

      WatchdogHttpOverrides.uninstall(overrides);
      expect(HttpOverrides.current, isNull);
    });

    test('createHttpClient delegates to previous override', () {
      final previousOverrides = _TrackingHttpOverrides();
      HttpOverrides.global = previousOverrides;

      overrides = WatchdogHttpOverrides(onRecord: capturedRecords.add);
      WatchdogHttpOverrides.install(overrides);

      // Creating an HttpClient should go through the previous override first
      final client = overrides.createHttpClient(null);
      expect(previousOverrides.createCalled, isTrue);
      // The result is wrapped in _MonitoringHttpClient (implements HttpClient)
      expect(client, isA<HttpClient>());
    });

    test('findProxyFromEnvironment delegates to previous override', () {
      final previousOverrides = _TrackingHttpOverrides();
      HttpOverrides.global = previousOverrides;

      overrides = WatchdogHttpOverrides(onRecord: capturedRecords.add);

      final result = overrides.findProxyFromEnvironment(
        Uri.parse('https://example.com'),
        {},
      );
      expect(previousOverrides.proxyCalled, isTrue);
      expect(result, 'DIRECT');
    });

    test('URL exclusion patterns are passed to monitoring client', () {
      overrides = WatchdogHttpOverrides(
        onRecord: capturedRecords.add,
        excludePatterns: ['analytics.example.com'],
      );
      WatchdogHttpOverrides.install(overrides);

      // The exclude patterns are stored — we verify by checking the override
      // accepted them without error. Full exclusion behavior is tested at the
      // HttpClient level via integration tests.
      expect(overrides.excludePatterns, contains('analytics.example.com'));
    });

    test('chaining preserves override stack order', () {
      final first = _DummyHttpOverrides();
      HttpOverrides.global = first;

      final second = WatchdogHttpOverrides(onRecord: (_) {});
      WatchdogHttpOverrides.install(second);

      final third = WatchdogHttpOverrides(onRecord: (_) {});
      WatchdogHttpOverrides.install(third);

      expect(HttpOverrides.current, same(third));

      // Uninstall third → should restore second
      WatchdogHttpOverrides.uninstall(third);
      expect(HttpOverrides.current, same(second));

      // Uninstall second → should restore first
      WatchdogHttpOverrides.uninstall(second);
      expect(HttpOverrides.current, same(first));
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
