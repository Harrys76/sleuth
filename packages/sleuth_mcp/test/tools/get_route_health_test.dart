import 'package:sleuth_mcp/src/tools/tools.dart';
import 'package:test/test.dart';

import '../helpers/fake_vm_bridge.dart';

void main() {
  test('get_route_health passes envelope', () async {
    final bridge = defaultFakeBridge();
    await bridge.connect(Uri.parse('ws://localhost/ws'));
    final handler = builtInTools['get_route_health']!.handler;
    final result = await handler(bridge, {}) as Map<String, Object?>;
    expect(result['data'], isA<Map<String, Object?>>());
  });

  group('routeHealth cross-version normalization', () {
    test('v0.33 wrapped shape passes through unchanged (no double-wrap)',
        () async {
      // Canonical wire shape — handler already wrapped the match. The
      // shim must NOT re-wrap; doing so would surface as
      // `data.route.route.routeName`.
      final bridge = defaultFakeBridge()
        ..setEnvelope('ext.sleuth.routeHealth', {
          'connectionMode': 'basic',
          'schemaVersion': 1,
          'sessionUuid': 'fake-uuid',
          'data': {
            'route': {'routeName': 'home', 'sessionId': 'abc'},
          },
        });
      await bridge.connect(Uri.parse('ws://localhost/ws'));
      final handler = builtInTools['get_route_health']!.handler;
      final result =
          await handler(bridge, {'route': 'home'}) as Map<String, Object?>;
      final data = result['data'] as Map<String, Object?>;
      expect(data.keys, contains('route'));
      final routeMap = data['route'] as Map<String, Object?>;
      expect(routeMap['routeName'], 'home',
          reason: 'wrapped session must surface routeName directly, not '
              'nested inside another `route` key');
      expect(routeMap.containsKey('route'), isFalse,
          reason: 'double-wrap regression — shim re-wrapped a canonical shape');
    });

    test('v0.32 inline shape gets wrapped into {route: <session>}', () async {
      // Inline shape — the v0.32 handler returned the RouteSession's
      // JSON directly as `data`. The shim must lift it under `route` so
      // downstream consumers can branch on the documented key.
      final bridge = defaultFakeBridge()
        ..setEnvelope('ext.sleuth.routeHealth', {
          'connectionMode': 'basic',
          'schemaVersion': 1,
          'sessionUuid': 'fake-uuid',
          'data': {'routeName': 'home', 'sessionId': 'abc'},
        });
      await bridge.connect(Uri.parse('ws://localhost/ws'));
      final handler = builtInTools['get_route_health']!.handler;
      final result =
          await handler(bridge, {'route': 'home'}) as Map<String, Object?>;
      final data = result['data'] as Map<String, Object?>;
      expect(data.keys, contains('route'),
          reason: 'shim must lift inline v0.32 shape under `route`');
      final routeMap = data['route'] as Map<String, Object?>;
      expect(routeMap['routeName'], 'home');
      expect(routeMap['sessionId'], 'abc');
      expect(data.containsKey('routeName'), isFalse,
          reason: 'inline keys must move under `route`, not co-exist');
    });

    test(
        'ambiguous shape (both route + routeName keys) passes through '
        'without double-wrap', () async {
      // Defensive guard — neither contract emits both keys, but if a
      // malformed producer does, the shim must not silently rewrite it.
      // Passthrough lets the downstream caller see the anomaly verbatim.
      final bridge = defaultFakeBridge()
        ..setEnvelope('ext.sleuth.routeHealth', {
          'connectionMode': 'basic',
          'schemaVersion': 1,
          'sessionUuid': 'fake-uuid',
          'data': {
            'route': {'routeName': 'home'},
            'routeName': 'home',
          },
        });
      await bridge.connect(Uri.parse('ws://localhost/ws'));
      final handler = builtInTools['get_route_health']!.handler;
      final result =
          await handler(bridge, {'route': 'home'}) as Map<String, Object?>;
      final data = result['data'] as Map<String, Object?>;
      // Both keys still present; route value not re-nested.
      expect(data.containsKey('route'), isTrue);
      expect(data.containsKey('routeName'), isTrue);
      final routeMap = data['route'] as Map<String, Object?>;
      expect(routeMap['routeName'], 'home');
      expect(routeMap.containsKey('route'), isFalse,
          reason: 'ambiguous case must NOT double-wrap');
    });

    test('error envelope passes through untouched (no `data` to wrap)',
        () async {
      // unknown_route shape — no `data` block. Shim must not attempt
      // any normalization.
      final bridge = defaultFakeBridge()
        ..setEnvelope('ext.sleuth.routeHealth', {
          'connectionMode': 'basic',
          'schemaVersion': 1,
          'sessionUuid': 'fake-uuid',
          'error': 'unknown_route',
          'route': 'ghost',
        });
      await bridge.connect(Uri.parse('ws://localhost/ws'));
      final handler = builtInTools['get_route_health']!.handler;
      final result =
          await handler(bridge, {'route': 'ghost'}) as Map<String, Object?>;
      expect(result['error'], 'unknown_route');
      expect(result.containsKey('data'), isFalse);
    });

    test('absent-route call passes through untouched', () async {
      // Caller asked for the full route list — `routes` plural. Shim
      // logic only applies to single-match responses.
      final bridge = defaultFakeBridge();
      await bridge.connect(Uri.parse('ws://localhost/ws'));
      final handler = builtInTools['get_route_health']!.handler;
      final result = await handler(bridge, {}) as Map<String, Object?>;
      final data = result['data'] as Map<String, Object?>;
      expect(data.keys, contains('routes'));
      expect(data.containsKey('route'), isFalse);
    });
  });
}
