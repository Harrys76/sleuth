import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/models/issue_measurement.dart';
import 'package:sleuth/src/models/performance_issue.dart';

void main() {
  const full = IssueMeasurement(
    value: 10.5,
    unit: MeasurementUnit.milliseconds,
    warningAt: 8,
    criticalAt: 16,
    window: Duration(seconds: 5),
  );

  group('MeasurementUnit', () {
    test('fromName returns built-in units and keeps unknown names', () {
      for (final unit in MeasurementUnit.values) {
        expect(MeasurementUnit.fromName(unit.name), same(unit));
      }
      final added = MeasurementUnit.fromName('furlongs');
      expect(added?.name, 'furlongs');
      expect(added, const MeasurementUnit('furlongs'));
      expect(MeasurementUnit.values, isNot(contains(added)));
      expect(MeasurementUnit.fromName(''), isNull);
      expect(MeasurementUnit.fromName(null), isNull);
      expect(MeasurementUnit.fromName(3), isNull);
    });

    test('units compare by name', () {
      expect(
        const MeasurementUnit('milliseconds'),
        MeasurementUnit.milliseconds,
      );
      expect(
        const MeasurementUnit('milliseconds').hashCode,
        MeasurementUnit.milliseconds.hashCode,
      );
    });

    test('names are unique', () {
      final names = MeasurementUnit.values.map((u) => u.name).toList();
      expect(names.toSet(), hasLength(names.length));
    });
  });

  group('IssueMeasurement JSON', () {
    test('round trips every field', () {
      final decoded = IssueMeasurement.fromJson(
        jsonDecode(jsonEncode(full.toJson())),
      );
      expect(decoded, full);
    });

    test('leaves out null lines and window', () {
      const m = IssueMeasurement(value: 3, unit: MeasurementUnit.count);
      expect(m.toJson(), {'value': 3.0, 'unit': 'count'});
      expect(IssueMeasurement.fromJson(m.toJson()), m);
    });

    test('reads integer JSON numbers as doubles', () {
      final m = IssueMeasurement.fromJson({
        'value': 34,
        'unit': 'perSecond',
        'warningAt': 20,
        'criticalAt': 40,
        'windowMs': 1000,
      });
      expect(
        m,
        const IssueMeasurement(
          value: 34,
          unit: MeasurementUnit.perSecond,
          warningAt: 20,
          criticalAt: 40,
          window: Duration(seconds: 1),
        ),
      );
    });

    test('returns null without a numeric value or a unit name', () {
      expect(IssueMeasurement.fromJson(null), isNull);
      expect(IssueMeasurement.fromJson('10 ms'), isNull);
      expect(IssueMeasurement.fromJson({'unit': 'milliseconds'}), isNull);
      expect(
        IssueMeasurement.fromJson({'value': '10', 'unit': 'milliseconds'}),
        isNull,
      );
      expect(IssueMeasurement.fromJson({'value': 10, 'unit': ''}), isNull);
      expect(
        IssueMeasurement.fromJson({'value': 10, 'unit': 'parsecs'})?.unit,
        const MeasurementUnit('parsecs'),
      );
    });

    test('drops malformed optional fields', () {
      final m = IssueMeasurement.fromJson({
        'value': 10,
        'unit': 'milliseconds',
        'warningAt': '8',
        'criticalAt': null,
        'windowMs': -1,
        'criticalStrict': 'yes',
      });
      expect(
        m,
        const IssueMeasurement(value: 10, unit: MeasurementUnit.milliseconds),
      );
    });

    test(
      'hasFiniteValue follows the value; toJson drops a line that is not',
      () {
        expect(full.hasFiniteValue, isTrue);
        expect(
          const IssueMeasurement(
            value: double.nan,
            unit: MeasurementUnit.percent,
          ).hasFiniteValue,
          isFalse,
        );
        const infiniteLine = IssueMeasurement(
          value: 1,
          unit: MeasurementUnit.percent,
          warningAt: 0.5,
          criticalAt: double.infinity,
        );
        expect(infiniteLine.hasFiniteValue, isTrue);
        expect(infiniteLine.toJson(), {
          'value': 1.0,
          'unit': 'percent',
          'warningAt': 0.5,
        });
      },
    );

    test('toJson drops a strict flag with the line it leaves out', () {
      for (final line in [
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        final m = IssueMeasurement(
          value: 1,
          unit: MeasurementUnit.percent,
          warningAt: 0.5,
          criticalAt: line,
          strict: true,
        );
        expect(m.criticalStrict, isTrue, reason: '$line');
        expect(m.toJson(), {
          'value': 1.0,
          'unit': 'percent',
          'warningAt': 0.5,
          'warningStrict': true,
        }, reason: '$line');
        final back = IssueMeasurement.fromJson(
          jsonDecode(jsonEncode(m.toJson())),
        )!;
        expect(back.criticalAt, isNull, reason: '$line');
        expect(back.criticalStrict, isFalse, reason: '$line');
        expect(back.warningStrict, isTrue, reason: '$line');
      }
      final noFiniteLine = IssueMeasurement(
        value: 1,
        unit: MeasurementUnit.count,
        warningAt: double.nan,
        criticalAt: double.infinity,
        strict: true,
      );
      expect(noFiniteLine.toJson(), {'value': 1.0, 'unit': 'count'});
    });

    test('windows keep their microseconds through JSON', () {
      const m = IssueMeasurement(
        value: 45,
        unit: MeasurementUnit.perSecond,
        window: Duration(microseconds: 1999600),
      );
      expect(m.toJson()['windowMs'], 1999.6);
      expect(IssueMeasurement.fromJson(jsonDecode(jsonEncode(m.toJson()))), m);
    });

    test('strict flags are written only when true and read back', () {
      const loose = IssueMeasurement(value: 6, unit: MeasurementUnit.count);
      const mixed = IssueMeasurement(
        value: 60,
        unit: MeasurementUnit.perSecond,
        warningAt: 30,
        criticalAt: 60,
        criticalStrict: true,
      );
      expect(loose.toJson().keys, isNot(contains('warningStrict')));
      expect(loose.toJson().keys, isNot(contains('criticalStrict')));
      expect(mixed.toJson().keys, isNot(contains('warningStrict')));
      expect(mixed.toJson()['criticalStrict'], isTrue);
      expect(IssueMeasurement.fromJson(mixed.toJson()), mixed);
      expect(mixed == loose, isFalse);

      const both = IssueMeasurement(
        value: 6,
        unit: MeasurementUnit.count,
        warningAt: 5,
        strict: true,
      );
      expect(both.warningStrict, isTrue);
      // No critical line, so no critical flag.
      expect(both.criticalStrict, isFalse);
      expect(both.toJson().keys, isNot(contains('criticalStrict')));
      expect(
        const IssueMeasurement(
          value: 6,
          unit: MeasurementUnit.count,
          warningAt: 5,
          criticalAt: 10,
          strict: true,
          criticalStrict: false,
        ).criticalStrict,
        isFalse,
      );
      // A flag without its line is not read back.
      expect(
        IssueMeasurement.fromJson({
          'value': 6,
          'unit': 'count',
          'criticalStrict': true,
        })!.criticalStrict,
        isFalse,
      );
    });

    test('equality and hashCode tell the strict flags apart', () {
      const atLeast = IssueMeasurement(
        value: 60,
        unit: MeasurementUnit.perSecond,
        warningAt: 30,
        criticalAt: 60,
      );
      const above = IssueMeasurement(
        value: 60,
        unit: MeasurementUnit.perSecond,
        warningAt: 30,
        criticalAt: 60,
        criticalStrict: true,
      );
      expect(atLeast == above, isFalse);
      expect(atLeast.hashCode == above.hashCode, isFalse);
    });

    test('toJson leaves out a window fromJson would drop', () {
      const negative = IssueMeasurement(
        value: 1,
        unit: MeasurementUnit.count,
        window: Duration(microseconds: -5),
      );
      expect(negative.toJson().keys, isNot(contains('windowMs')));
    });

    test('rejects a value that is not finite and drops out-of-range '
        'windows instead of throwing', () {
      expect(
        IssueMeasurement.fromJson({'value': double.nan, 'unit': 'count'}),
        isNull,
      );
      for (final windowMs in [1e308, 9223372036854775807, -1, double.nan]) {
        final m = IssueMeasurement.fromJson({
          'value': 1,
          'unit': 'count',
          'windowMs': windowMs,
          'warningAt': double.infinity,
        });
        expect(m, isNotNull);
        expect(m!.window, isNull, reason: '$windowMs');
        expect(m.warningAt, isNull);
      }
    });
  });

  group('PerformanceIssue.measurement', () {
    const base = PerformanceIssue(
      stableId: 'heavy_compute',
      severity: IssueSeverity.warning,
      category: IssueCategory.build,
      confidence: IssueConfidence.confirmed,
      title: 'Heavy Computation: 10.5ms',
      detail: 'detail',
      fixHint: 'fix',
    );

    test('toJson writes the measurement only when there is one', () {
      expect(base.toJson().containsKey('measurement'), isFalse);
      expect(
        base.copyWith(measurement: full).toJson()['measurement'],
        full.toJson(),
      );
    });

    test('toJson leaves out a measurement JSON cannot encode', () {
      final issue = base.copyWith(
        measurement: const IssueMeasurement(
          value: double.nan,
          unit: MeasurementUnit.milliseconds,
        ),
      );
      final json = issue.toJson();
      expect(json.containsKey('measurement'), isFalse);
      expect(() => jsonEncode(json), returnsNormally);
    });

    test('fromJson reads the measurement and tolerates its absence', () {
      final withMeasurement = PerformanceIssue.fromJson(
        jsonDecode(jsonEncode(base.copyWith(measurement: full).toJson()))
            as Map<String, dynamic>,
      );
      expect(withMeasurement.measurement, full);
      expect(PerformanceIssue.fromJson(base.toJson()).measurement, isNull);

      final unknownUnit = base.toJson()
        ..['measurement'] = {'value': 1, 'unit': 'added-later'};
      expect(
        PerformanceIssue.fromJson(unknownUnit).measurement?.unit.name,
        'added-later',
      );
    });

    test('copyWith keeps the measurement unless replaced', () {
      final issue = base.copyWith(measurement: full);
      expect(
        issue.copyWith(severity: IssueSeverity.critical).measurement,
        full,
      );
      const other = IssueMeasurement(
        value: 20,
        unit: MeasurementUnit.milliseconds,
      );
      expect(issue.copyWith(measurement: other).measurement, other);
    });

    test('equality still keys on stableId alone', () {
      expect(base.copyWith(measurement: full), base);
    });
  });
}
