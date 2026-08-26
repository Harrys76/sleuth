import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/utils/session_uuid.dart';

final _rfc4122V4Pattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}'
  r'-4[0-9a-f]{3}'
  r'-[89ab][0-9a-f]{3}'
  r'-[0-9a-f]{12}$',
);

void main() {
  group('generateSessionUuid', () {
    test('matches RFC 4122 v4 format', () {
      expect(generateSessionUuid(), matches(_rfc4122V4Pattern));
    });

    test('successive values differ', () {
      final first = generateSessionUuid();
      final second = generateSessionUuid();
      expect(second, isNot(first));
    });
  });
}
