import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/issue_measurement.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/ui/measurement_gauge.dart';
import 'package:sleuth/src/utils/measurement_text.dart';
import 'package:sleuth/src/validation/detector_metadata.dart';

/// Families whose detectors stamp no measurement.
const _withoutMeasurement = {
  'always_repaint_painter',
  'sliver_fill_remaining_scrollable',
  'sliver_to_box_adapter_shrinkwrap',
  'layout_bottleneck',
  'runtime_font_loading',
  'expensive_gpu_nodes',
};

PerformanceIssue _issue(
  String stableId,
  IssueMeasurement measurement, {
  IssueSeverity severity = IssueSeverity.warning,
  String? widgetName,
}) => PerformanceIssue(
  severity: severity,
  category: IssueCategory.build,
  confidence: IssueConfidence.confirmed,
  title: 'T',
  detail: 'D',
  fixHint: 'F',
  stableId: stableId,
  widgetName: widgetName,
  measurement: measurement,
);

void main() {
  group('measured phrases', () {
    late Set<String> families;

    setUpAll(() {
      final controller = SleuthController()..initializeDetectorsForTest();
      families = {
        for (final d in controller.detectorsForAudit)
          if (d is DetectorMetadataProvider) ...[
            ...?(d as DetectorMetadataProvider)
                .validationMetadata
                .coveredStableIds,
            ...?(d as DetectorMetadataProvider)
                .validationMetadata
                .parametricFamilies,
          ],
      };
      controller.dispose();
    });

    test('every family a detector reports has a phrase, or carries no '
        'measurement', () {
      final missing = [
        for (final f in families)
          if (!measuredPhrases.containsKey(f) &&
              !_withoutMeasurement.contains(f))
            f,
      ];
      expect(missing, isEmpty);
    });

    test('the table lists the 43 families that stamp a measurement and '
        'no other', () {
      expect(measuredPhrases, hasLength(43));
      expect([
        for (final f in measuredPhrases.keys)
          if (!families.contains(f)) f,
      ], isEmpty);
      expect(
        measuredPhrases.keys.toSet().intersection(_withoutMeasurement),
        isEmpty,
      );
    });

    test('each phrase holds the value once', () {
      for (final MapEntry(:key, :value) in measuredPhrases.entries) {
        expect('{v}'.allMatches(value), hasLength(1), reason: key);
      }
    });

    test('a parametric id finds its family', () {
      expect(measurementFamilyOf('rebuild_debug_FeedTile'), 'rebuild_debug');
      expect(measurementFamilyOf('repaint_debug_Chart'), 'repaint_debug');
      expect(
        measurementFamilyOf('excessive_repaint_debug'),
        'excessive_repaint_debug',
      );
      expect(
        measurementFamilyOf('tracked_resource_concurrent:socket'),
        'tracked_resource_concurrent',
      );
      expect(
        measurementFamilyOf('excessive_keep_alive:Tile~k-1'),
        'excessive_keep_alive',
      );
    });
  });

  group('measuredLine', () {
    test('sets the value apart from the phrase', () {
      expect(
        measuredLine(
          _issue(
            'heavy_compute',
            const IssueMeasurement(
              value: 10,
              unit: MeasurementUnit.milliseconds,
            ),
          ),
        ),
        ('', '10.0 ms', ' in one build on the UI thread'),
      );
    });

    test('fills in the widget and the parametric name', () {
      expect(
        measuredLine(
          _issue(
            'setstate_scope',
            const IssueMeasurement(value: 88, unit: MeasurementUnit.percent),
            widgetName: 'DemoScaffold',
          ),
        ),
        ('', '88%', ' of the widget tree sits under DemoScaffold'),
      );
      expect(
        measuredLine(
          _issue(
            'tracked_resource_concurrent:socket',
            const IssueMeasurement(value: 8, unit: MeasurementUnit.count),
          ),
        ),
        ('', '8', ' live "socket" instances'),
      );
      expect(
        measuredLine(
          _issue(
            'rebuild_debug_FeedTile',
            const IssueMeasurement(value: 45, unit: MeasurementUnit.perSecond),
            widgetName: 'FeedTile',
          ),
        ),
        ('Rebuilds of FeedTile at ', '45/s', ''),
      );
    });

    test('a window names its length; without one the phrase names none', () {
      expect(
        measuredLine(
          _issue(
            'jank_detected',
            const IssueMeasurement(
              value: 18,
              unit: MeasurementUnit.percent,
              window: Duration(milliseconds: 4200),
            ),
          ),
        ),
        ('', '18%', ' of frames missed their deadline in the last 4.2 s'),
      );
      expect(
        measuredLine(
          _issue(
            'raster_dominance',
            const IssueMeasurement(value: 4, unit: MeasurementUnit.frames),
          ),
        ),
        ('', '4 frames', ' missed the deadline on the raster thread'),
      );
      expect(
        measuredLine(
          _issue(
            'high_frequency_same_path:abc',
            const IssueMeasurement(
              value: 5,
              unit: MeasurementUnit.count,
              window: Duration(milliseconds: 500),
            ),
          ),
        ),
        ('', '5', ' requests to one path within 500 ms'),
      );
    });

    test('formatWindow', () {
      expect(formatWindow(const Duration(milliseconds: 500)), '500 ms');
      expect(formatWindow(const Duration(milliseconds: 4200)), '4.2 s');
      expect(formatWindow(const Duration(seconds: 5)), '5 s');
      expect(formatWindow(const Duration(seconds: 10)), '10 s');
    });

    test('the fingerprint text changes with a line, not with rounding', () {
      String? text(double value, double critical) => measuredText(
        _issue(
          'heavy_compute',
          IssueMeasurement(
            value: value,
            unit: MeasurementUnit.milliseconds,
            warningAt: 8,
            criticalAt: critical,
          ),
        ),
      );
      expect(text(10.01, 16), text(10.04, 16));
      expect(text(10, 16), isNot(text(10, 20)));
    });

    test('a non-finite value has no line', () {
      expect(
        measuredLine(
          _issue(
            'heavy_compute',
            const IssueMeasurement(
              value: double.nan,
              unit: MeasurementUnit.milliseconds,
            ),
          ),
        ),
        isNull,
      );
    });
  });

  group('formatMeasurementValue', () {
    for (final (value, unit, text) in [
      (8.44, MeasurementUnit.milliseconds, '8.4 ms'),
      (2177.0, MeasurementUnit.milliseconds, '2,177 ms'),
      (420.0, MeasurementUnit.seconds, '420 s'),
      (88.0, MeasurementUnit.percent, '88%'),
      (8.5, MeasurementUnit.percent, '8.5%'),
      (1258020.0, MeasurementUnit.bytes, '1.2 MB'),
      (900.0, MeasurementUnit.bytes, '900 B'),
      (1048576.0, MeasurementUnit.bytesPerSecond, '1.0 MB/s'),
      (1432.0, MeasurementUnit.count, '1,432'),
      (34.0, MeasurementUnit.perSecond, '34/s'),
      (282.0, MeasurementUnit.perMinute, '282/min'),
      (1.0, MeasurementUnit.frames, '1 frame'),
      (6.0, MeasurementUnit.frames, '6 frames'),
      (3.0, const MeasurementUnit('widgets'), '3.0 widgets'),
    ]) {
      test('$value ${unit.name} reads $text', () {
        expect(formatMeasurementValue(value, unit), text);
      });
    }
  });

  group('measuredSeverityNote', () {
    const rate = MeasurementUnit.perSecond;

    test('a critical held under its line says so', () {
      expect(
        measuredSeverityNote(
          _issue(
            'rebuild_activity',
            const IssueMeasurement(
              value: 20,
              unit: MeasurementUnit.percent,
              warningAt: 10,
              criticalAt: 30,
            ),
            severity: IssueSeverity.critical,
          ),
        ),
        startsWith('Held at critical'),
      );
    });

    test('a warning held under its line says so', () {
      expect(
        measuredSeverityNote(
          _issue(
            'gc_pressure',
            const IssueMeasurement(
              value: 100,
              unit: MeasurementUnit.perMinute,
              warningAt: 240,
            ),
          ),
        ),
        startsWith('Held at warning'),
      );
    });

    test('a debug rate over the critical line at warning names the latest '
        'second', () {
      expect(
        measuredSeverityNote(
          _issue(
            'rebuild_debug_FeedTile',
            const IssueMeasurement(
              value: 35,
              unit: rate,
              warningAt: 10,
              criticalAt: 30,
              criticalStrict: true,
            ),
          ),
        ),
        'Not critical: the latest second stayed at or under the line',
      );
    });

    test('a value that matches its severity has no note', () {
      expect(
        measuredSeverityNote(
          _issue(
            'heavy_compute',
            const IssueMeasurement(
              value: 12,
              unit: MeasurementUnit.milliseconds,
              warningAt: 8,
              criticalAt: 16,
            ),
          ),
        ),
        isNull,
      );
    });

    test('a strict line is not reached by an equal value', () {
      expect(
        measuredSeverityNote(
          _issue(
            'platform_channel_traffic',
            const IssueMeasurement(
              value: 40,
              unit: rate,
              warningAt: 15,
              criticalAt: 40,
              strict: true,
            ),
            severity: IssueSeverity.critical,
          ),
        ),
        startsWith('Held at critical'),
      );
    });
  });

  test('the semantics label reads the value and both lines', () {
    expect(
      measuredSemanticsLabel(
        _issue(
          'heavy_compute',
          const IssueMeasurement(
            value: 10,
            unit: MeasurementUnit.milliseconds,
            warningAt: 8,
            criticalAt: 16,
          ),
        ),
      ),
      'Measured: 10.0 ms in one build on the UI thread. Warning at 8.0 ms. '
      'Critical at 16.0 ms',
    );
  });

  group('copyDetailsText', () {
    test('puts the Measured sentence after the header lines', () {
      final issue = PerformanceIssue(
        severity: IssueSeverity.critical,
        category: IssueCategory.build,
        confidence: IssueConfidence.confirmed,
        title: 'Heavy Computation: 243.7ms',
        detail: 'A long-running operation ran on the UI thread.',
        fixHint: 'Move the work off the UI thread.',
        stableId: 'heavy_compute',
        routeName: '/demo/CSV Import',
        measurement: const IssueMeasurement(
          value: 243.7,
          unit: MeasurementUnit.milliseconds,
          warningAt: 8,
          criticalAt: 16,
        ),
      );
      expect(
        copyDetailsText(issue),
        'Heavy Computation: 243.7ms\n'
        'Severity: critical\n'
        'Confidence: confirmed\n'
        'Route: /demo/CSV Import\n'
        'Measured: 244 ms in one build on the UI thread. Warning at 8.0 ms. '
        'Critical at 16.0 ms.\n'
        '\n'
        'A long-running operation ran on the UI thread.\n'
        '\n'
        'Fix: Move the work off the UI thread.\n'
        '\n'
        'Stable ID: heavy_compute',
      );
    });

    test('is the plain clipboard text without a measurement', () {
      const issue = PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.build,
        confidence: IssueConfidence.confirmed,
        title: 'T',
        detail: 'D',
        fixHint: 'F',
        stableId: 'heavy_compute',
      );
      expect(copyDetailsText(issue), issue.toClipboardText());
    });
  });

  group('gaugeMax', () {
    test('a quarter past the higher line', () {
      expect(
        gaugeMax(
          const IssueMeasurement(
            value: 10,
            unit: MeasurementUnit.milliseconds,
            warningAt: 8,
            criticalAt: 16,
          ),
        ),
        20,
      );
    });

    test('stays put while the value grows past the lines', () {
      IssueMeasurement frames(double value) => IssueMeasurement(
        value: value,
        unit: MeasurementUnit.frames,
        criticalAt: 3,
      );
      expect(gaugeMax(frames(3)), 3.75);
      expect(gaugeMax(frames(52)), 3.75);
      expect(gaugeMax(frames(77)), 3.75);
    });

    test('a quarter past the value without a positive line', () {
      expect(
        gaugeMax(
          const IssueMeasurement(
            value: 10,
            unit: MeasurementUnit.count,
            warningAt: 0,
          ),
        ),
        12.5,
      );
    });

    test('100 for a percent within it', () {
      expect(
        gaugeMax(
          const IssueMeasurement(
            value: 88,
            unit: MeasurementUnit.percent,
            warningAt: 50,
            criticalAt: 75,
          ),
        ),
        100,
      );
    });
  });
}
