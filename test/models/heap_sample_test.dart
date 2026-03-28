import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/widget_watchdog.dart';

void main() {
  group('HeapSample', () {
    final timestamp = DateTime.utc(2026, 3, 28, 12, 0, 0);
    final sample = HeapSample(
      heapUsage: 52428800,
      heapCapacity: 104857600,
      externalUsage: 1048576,
      timestamp: timestamp,
    );

    test('toJson contains all fields', () {
      final json = sample.toJson();

      expect(json['heapUsage'], 52428800);
      expect(json['heapCapacity'], 104857600);
      expect(json['externalUsage'], 1048576);
      expect(json.length, 4);
    });

    test('timestamp serialized as ISO 8601', () {
      final json = sample.toJson();

      expect(json['timestamp'], '2026-03-28T12:00:00.000Z');
    });

    test('const constructor creates immutable instance', () {
      expect(sample.heapUsage, isA<int>());
      expect(sample.heapCapacity, isA<int>());
      expect(sample.externalUsage, isA<int>());
      expect(sample.timestamp, isA<DateTime>());
    });
  });
}
