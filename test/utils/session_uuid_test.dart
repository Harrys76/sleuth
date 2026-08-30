import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/utils/session_uuid.dart';

void main() {
  group('generateSessionUuid', () {
    test('value matches RFC 4122 v4 UUID pattern', () {
      final value = generateSessionUuid();
      final uuidRegex = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      );
      expect(value, matches(uuidRegex));
    });

    test('successive values are different', () {
      final first = generateSessionUuid();
      final second = generateSessionUuid();
      expect(first, isNot(second));
    });
  });
}
