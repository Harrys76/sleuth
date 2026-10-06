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

  group('routeHealth passthrough', () {
    test('wrapped single-route shape passes through unchanged', () async {
      // Canonical wire shape for every accepted lineage. The tool must not
      // re-wrap; doing so would surface as `data.route.route.routeName`.
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
      expect(data.keys, ['route']);
      final routeMap = data['route'] as Map<String, Object?>;
      expect(routeMap['routeName'], 'home');
      expect(
        routeMap.containsKey('route'),
        isFalse,
        reason: 'double-wrap regression — tool re-wrapped a canonical shape',
      );
    });

    test(
      'error envelope passes through untouched (no `data` to wrap)',
      () async {
        // unknown_route shape — no `data` block.
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
      },
    );

    test('absent-route call passes through untouched', () async {
      // Caller asked for the full route list — `routes` plural.
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
