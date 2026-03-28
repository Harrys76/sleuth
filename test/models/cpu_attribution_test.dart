import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/widget_watchdog.dart';

void main() {
  group('CpuAttribution', () {
    const attribution = CpuAttribution(
      functionName: 'build',
      className: 'MyWidget',
      libraryUri: 'package:my_app/widgets/my_widget.dart',
      percentage: 42.567,
    );

    test('toJson contains all fields', () {
      final json = attribution.toJson();
      expect(json['functionName'], 'build');
      expect(json['className'], 'MyWidget');
      expect(json['libraryUri'], 'package:my_app/widgets/my_widget.dart');
      expect(json['percentage'], 42.6); // rounded to 1 decimal
      expect(json['displayName'], 'MyWidget.build');
    });

    test('fromJson roundtrip preserves data', () {
      final json = attribution.toJson();
      final restored = CpuAttribution.fromJson(json);
      expect(restored.functionName, attribution.functionName);
      expect(restored.className, attribution.className);
      expect(restored.libraryUri, attribution.libraryUri);
      expect(restored.percentage, closeTo(42.6, 0.01));
    });

    test('displayName with class and method', () {
      expect(attribution.displayName, 'MyWidget.build');
    });

    test('displayName with bare function (empty className)', () {
      const topLevel = CpuAttribution(
        functionName: 'jsonDecode',
        className: '',
        libraryUri: 'dart:convert',
        percentage: 25.0,
      );
      expect(topLevel.displayName, 'jsonDecode');
    });

    test('percentage formatted to 1 decimal in toJson', () {
      const precise = CpuAttribution(
        functionName: 'f',
        className: '',
        libraryUri: '',
        percentage: 33.3333,
      );
      expect(precise.toJson()['percentage'], 33.3);
    });
  });
}
