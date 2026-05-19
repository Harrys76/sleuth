import 'package:sleuth_mcp/sleuth_mcp.dart';
import 'package:test/test.dart';

void main() {
  group('AppStatusPayload conditional fields', () {
    test('ios-direct attach emits transportMode + wsUri', () {
      const payload = AppStatusPayload(
        attached: true,
        state: 'ready',
        device: '00008101-001679123408801E',
        sessionUuid: 'abc',
        launchMode: 'ios-direct',
        mode: 'profile',
        transportMode: 'wired',
        wsUri: 'ws://127.0.0.1:55958/MjcDN-9pu8o=/ws',
      );
      final json = payload.toJson();
      expect(json['launchMode'], 'ios-direct');
      expect(json['transportMode'], 'wired',
          reason: 'iOS-direct sessions must surface transportMode');
      expect(json['wsUri'], isA<String>(),
          reason: 'iOS-direct sessions must surface wsUri');
    });

    test('daemon attach omits transportMode + wsUri', () {
      const payload = AppStatusPayload(
        attached: true,
        state: 'ready',
        device: 'Pengen',
        sessionUuid: 'abc',
        launchMode: 'attach',
        mode: 'debug',
      );
      final json = payload.toJson();
      expect(json.containsKey('transportMode'), isFalse,
          reason: 'daemon-attach sessions must not leak transportMode');
      expect(json.containsKey('wsUri'), isFalse,
          reason: 'daemon-attach sessions must not leak wsUri');
    });

    test('idle state omits all session-scoped fields', () {
      const payload = AppStatusPayload(attached: false, state: 'idle');
      final json = payload.toJson();
      expect(json.keys.toSet(), {'attached', 'state'});
    });

    test('wireless ios-direct emits transportMode=wireless', () {
      const payload = AppStatusPayload(
        attached: true,
        state: 'ready',
        launchMode: 'ios-direct',
        transportMode: 'wireless',
        wsUri: 'ws://Pengen.local:54321/abc=/ws',
      );
      final json = payload.toJson();
      expect(json['transportMode'], 'wireless');
      expect(json['wsUri'], startsWith('ws://Pengen.local:'));
    });

    test(
        'transportMode + wsUri suppressed when launchMode != ios-direct '
        '(even if fields populated)', () {
      // Negative invariant: a partially-cleaned-up session struct or
      // accidental construction with ios-direct fields on a daemon
      // session must NOT leak the iOS-only fields into JSON.
      const accidentallyPopulated = AppStatusPayload(
        attached: true,
        state: 'ready',
        launchMode: 'attach', // daemon-attach, NOT ios-direct
        mode: 'debug',
        transportMode: 'wired', // populated by accident
        wsUri: 'ws://127.0.0.1:9999/foo=/ws', // populated by accident
      );
      final json = accidentallyPopulated.toJson();
      expect(json.containsKey('transportMode'), isFalse,
          reason: 'transportMode must be suppressed on non-ios-direct '
              'launch modes regardless of constructor input');
      expect(json.containsKey('wsUri'), isFalse,
          reason: 'wsUri must be suppressed on non-ios-direct launch '
              'modes regardless of constructor input');
    });

    test('null launchMode also suppresses ios-direct fields', () {
      const payload = AppStatusPayload(
        attached: false,
        state: 'idle',
        transportMode: 'wired', // stale from prior session
        wsUri: 'ws://stale/',
      );
      final json = payload.toJson();
      expect(json.containsKey('transportMode'), isFalse);
      expect(json.containsKey('wsUri'), isFalse);
    });
  });
}
