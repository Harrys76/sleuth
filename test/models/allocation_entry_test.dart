import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/src/models/allocation_entry.dart';

void main() {
  group('AllocationEntry', () {
    const entry = AllocationEntry(
      className: 'MyWidget',
      libraryUri: 'package:my_app/widgets/my_widget.dart',
      instancesDelta: 150,
      bytesDelta: 24576,
      percentage: 42.37,
    );

    test('toJson includes all fields with rounded percentage', () {
      final json = entry.toJson();
      expect(json['className'], 'MyWidget');
      expect(json['libraryUri'], 'package:my_app/widgets/my_widget.dart');
      expect(json['instancesDelta'], 150);
      expect(json['bytesDelta'], 24576);
      expect(json['percentage'], 42.4); // rounded to 1 decimal
    });

    test('fromJson restores all fields', () {
      final json = {
        'className': 'Item',
        'libraryUri': 'package:app/models/item.dart',
        'instancesDelta': 500,
        'bytesDelta': 102400,
        'percentage': 31.5,
      };

      final restored = AllocationEntry.fromJson(json);
      expect(restored.className, 'Item');
      expect(restored.libraryUri, 'package:app/models/item.dart');
      expect(restored.instancesDelta, 500);
      expect(restored.bytesDelta, 102400);
      expect(restored.percentage, 31.5);
    });

    test('fromJson/toJson roundtrip preserves data', () {
      final json = entry.toJson();
      final restored = AllocationEntry.fromJson(json);
      expect(restored.className, entry.className);
      expect(restored.libraryUri, entry.libraryUri);
      expect(restored.instancesDelta, entry.instancesDelta);
      expect(restored.bytesDelta, entry.bytesDelta);
      // percentage is rounded to 1 decimal in toJson
      expect(restored.percentage, 42.4);
    });

    test('displayBytes formats correctly', () {
      // Bytes
      const small = AllocationEntry(
        className: 'A',
        libraryUri: '',
        instancesDelta: 1,
        bytesDelta: 512,
        percentage: 1.0,
      );
      expect(small.displayBytes, '512B');

      // KB
      const medium = AllocationEntry(
        className: 'B',
        libraryUri: '',
        instancesDelta: 10,
        bytesDelta: 24576, // 24 KB
        percentage: 10.0,
      );
      expect(medium.displayBytes, '24.0KB');

      // MB
      const large = AllocationEntry(
        className: 'C',
        libraryUri: '',
        instancesDelta: 100,
        bytesDelta: 2 * 1024 * 1024, // 2 MB
        percentage: 50.0,
      );
      expect(large.displayBytes, '2.0MB');
    });

    test('toString includes className and percentage', () {
      final str = entry.toString();
      expect(str, contains('MyWidget'));
      expect(str, contains('42.4%'));
      expect(str, contains('24.0KB'));
    });
  });
}
