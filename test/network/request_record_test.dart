import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/network/request_record.dart';

void main() {
  group('RequestRecord', () {
    RequestRecord makeRecord({
      String url = 'https://example.com/api/data',
      String method = 'GET',
      int statusCode = 200,
      int durationMs = 150,
      int responseBytes = 4096,
      DateTime? startedAt,
    }) {
      return RequestRecord(
        url: url,
        method: method,
        statusCode: statusCode,
        durationMs: durationMs,
        responseBytes: responseBytes,
        startedAt: startedAt ?? DateTime(2026, 1, 1),
      );
    }

    test('toJson contains all fields with correct types', () {
      final record = makeRecord();
      final json = record.toJson();

      expect(json['url'], 'https://example.com/api/data');
      expect(json['method'], 'GET');
      expect(json['statusCode'], 200);
      expect(json['durationMs'], 150);
      expect(json['responseBytes'], 4096);
      expect(json['startedAt'], isA<String>());
    });

    test('startedAt serialized as ISO 8601', () {
      final record = makeRecord(
        startedAt: DateTime(2026, 3, 15, 10, 30, 0),
      );
      final json = record.toJson();
      expect(json['startedAt'], '2026-03-15T10:30:00.000');
    });

    test('failed request records error statusCode -1', () {
      final record = makeRecord(statusCode: -1, responseBytes: 0);
      final json = record.toJson();
      expect(json['statusCode'], -1);
      expect(json['responseBytes'], 0);
    });

    test('toString contains method, url, duration, and status', () {
      final record = makeRecord();
      final str = record.toString();
      expect(str, contains('GET'));
      expect(str, contains('example.com'));
      expect(str, contains('150ms'));
      expect(str, contains('status=200'));
    });
  });
}
