import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/utils/session_uuid.dart';

void main() {
  group('generateSessionUuid', () {
    test('batch of 20 values match RFC 4122 v4 UUID pattern', () {
      final uuidRegex = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      );
      final values = List.generate(20, (_) => generateSessionUuid());
      for (final value in values) {
        expect(value, matches(uuidRegex));
      }
    });

    test('successive values are different', () {
      final first = generateSessionUuid();
      final second = generateSessionUuid();
      expect(first, isNot(second));
    });
  });
}
