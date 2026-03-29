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

    // -- rssBytes / nativeBytes --

    test('rssBytes included in toJson when present', () {
      final withRss = HeapSample(
        heapUsage: 52428800,
        heapCapacity: 104857600,
        externalUsage: 1048576,
        timestamp: timestamp,
        rssBytes: 500000000,
      );
      final json = withRss.toJson();

      expect(json['rssBytes'], 500000000);
      expect(json['nativeBytes'], 500000000 - 52428800);
    });

    test('rssBytes omitted from toJson when null', () {
      final json = sample.toJson();

      expect(json.containsKey('rssBytes'), isFalse);
      expect(json.containsKey('nativeBytes'), isFalse);
    });

    test('toJson field count is 6 with rss', () {
      final withRss = HeapSample(
        heapUsage: 52428800,
        heapCapacity: 104857600,
        externalUsage: 1048576,
        timestamp: timestamp,
        rssBytes: 500000000,
      );

      expect(withRss.toJson().length, 6);
    });

    test('nativeBytes computes rss minus heap', () {
      final withRss = HeapSample(
        heapUsage: 50000000,
        heapCapacity: 100000000,
        externalUsage: 0,
        timestamp: timestamp,
        rssBytes: 200000000,
      );

      expect(withRss.nativeBytes, 200000000 - 50000000);
    });

    test('nativeBytes is null when rssBytes is null', () {
      expect(sample.nativeBytes, isNull);
    });

    test('nativeBytes clamps to zero when rss < heap', () {
      final edgeCase = HeapSample(
        heapUsage: 100000000,
        heapCapacity: 200000000,
        externalUsage: 0,
        timestamp: timestamp,
        rssBytes: 50000000, // RSS < heap (stale RSS or memory-mapped)
      );

      expect(edgeCase.nativeBytes, 0);
    });

    test('nativeBytes clamps to rssBytes maximum', () {
      final zeroHeap = HeapSample(
        heapUsage: 0,
        heapCapacity: 100000000,
        externalUsage: 0,
        timestamp: timestamp,
        rssBytes: 300000000,
      );

      expect(zeroHeap.nativeBytes, 300000000);
    });

    test('constructor works with rssBytes', () {
      final withRss = HeapSample(
        heapUsage: 50000000,
        heapCapacity: 100000000,
        externalUsage: 0,
        timestamp: timestamp,
        rssBytes: 200000000,
      );
      expect(withRss.rssBytes, 200000000);
    });
  });
}
