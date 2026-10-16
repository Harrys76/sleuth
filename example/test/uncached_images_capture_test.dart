// The uncached_images capture screen: leg sizes at the device pixel
// ratio, the waste it computes, the brackets it reads, the last-record
// check, and the leg lifecycle.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/detectors/image_memory_detector.dart';

import 'package:example/demos/capture_driver.dart';
import 'package:example/demos/uncached_images_capture_screen.dart';

/// Leg calls that record what a leg did and hold the flush open until
/// [flush] completes.
class _RecordingCalls extends CaptureLegCalls {
  final List<String> log = [];
  Completer<void>? flush;

  /// Whether the flush fails the way `flushTimelineNow` does past its
  /// 2 s limit.
  bool flushTimesOut = false;

  @override
  Future<void> suspendStreams() async => log.add('suspend');

  @override
  Future<void> resumeStreams() async => log.add('resume');

  @override
  Future<void> flushTimeline() {
    log.add('flush');
    if (flushTimesOut) {
      return Future.error(
        TimeoutException('flush', const Duration(seconds: 2)),
      );
    }
    return (flush ??= Completer<void>()).future;
  }

  @override
  void markScenarioBegin(String scenario) => log.add('begin $scenario');

  @override
  void markScenarioEnd(String scenario) => log.add('end $scenario');
}

/// Specimens that skip the codec, with a tiny PNG for the widget and a
/// pre-made decode of [side] pixels for the leg's own read.
class _FakeSpecimens extends UncachedImageSpecimens {
  _FakeSpecimens(this.png8, this.decoded);

  final Uint8List png8;
  final ui.Image decoded;
  final List<int> sides = [];

  @override
  Future<Uint8List> png(
    int side, {
    required Color dark,
    required Color light,
  }) async {
    sides.add(side);
    return png8;
  }

  @override
  Future<ImageInfo> decode(
    ImageProvider provider,
    ImageConfiguration configuration,
  ) async => ImageInfo(image: decoded.clone());
}

/// A capture whose span holds `uncached_images.warning` records with the
/// given `imageCount` args, 1 ms apart.
String _capture(List<Object?> imageCounts) {
  return jsonEncode({
    'traceEvents': [
      {
        'name': 'sleuth.scenario.begin',
        'ph': 'n',
        'ts': 1000,
        'args': {'name': 's'},
      },
      for (var i = 0; i < imageCounts.length; i++)
        {
          'name': 'sleuth.issue.uncached_images.warning',
          'ph': 'n',
          'ts': 2000 + i * 1000,
          'args': {'wastedBytes': '1258020', 'imageCount': ?imageCounts[i]},
        },
      {
        'name': 'sleuth.scenario.end',
        'ph': 'n',
        'ts': 99000,
        'args': {'name': 's'},
      },
    ],
  });
}

void main() {
  final metadata = ImageMemoryDetector().validationMetadata;
  final warning = uncachedImagesBracket(metadata, UncachedImagesLeg.at)!;
  final critical = uncachedImagesBracket(
    metadata,
    UncachedImagesLeg.criticalAt,
  )!;

  group('leg sizes', () {
    test('at pixel ratio 3.0 each leg decodes to the planned side', () {
      expect(
        [
          for (final leg in UncachedImagesLeg.values)
            uncachedImageDecodeSide(
              targetBytes: leg.targetBytes,
              devicePixelRatio: 3,
            ),
        ],
        [390, 579, 738, 1455, 2294, 2900],
      );
    });

    test('the computed waste lands on the target at ratios 2.0 and 3.0, '
        'inside the leg\'s band', () {
      for (final dpr in [2.0, 3.0]) {
        for (final leg in UncachedImagesLeg.values) {
          final side = uncachedImageDecodeSide(
            targetBytes: leg.targetBytes,
            devicePixelRatio: dpr,
          );
          final waste = uncachedImageWasteBytes(
            decodedW: side,
            decodedH: side,
            boxW: uncachedImageBoxDp,
            boxH: uncachedImageBoxDp,
            devicePixelRatio: dpr,
          )!;
          expect(
            (waste - leg.targetBytes).abs() / leg.targetBytes,
            lessThan(0.01),
            reason: '${leg.label} at $dpr',
          );
          final bracket = leg.tier == 'critical' ? critical : warning;
          expect(
            bracket.acceptsMeasurement(waste, leg.role),
            isTrue,
            reason: '${leg.label} at $dpr: $waste',
          );
        }
      }
    });

    test('the waste uses the detector\'s formula', () {
      // The image reproducer pins the detector's stamps at these sizes.
      int waste(int side) => uncachedImageWasteBytes(
        decodedW: side,
        decodedH: side,
        boxW: 48,
        boxH: 48,
        devicePixelRatio: 3,
      )!;
      expect(waste(390), 525456);
      expect(waste(579), 1258020);
      expect(waste(2294), 20966800);
    });

    test('a decode under 1.5 times the need is not counted', () {
      expect(
        uncachedImageWasteBytes(
          decodedW: 215,
          decodedH: 215,
          boxW: 48,
          boxH: 48,
          devicePixelRatio: 3,
        ),
        isNull,
      );
    });
  });

  group('brackets and legs', () {
    test('the warning bracket: 1 MiB, at [1, 1.5] MiB, above '
        '(1.5, 2.5] MiB, last record, 10 %', () {
      expect(warning.eventName, 'sleuth.issue.uncached_images.warning');
      expect(warning.argKey, 'wastedBytes');
      expect(warning.threshold, 1048576);
      expect(warning.atUpper, 1572864);
      expect(warning.aboveCeiling, 2621440);
      expect(warning.reduction, 'last');
      expect(warning.observedAxisTolerance, 0.10);
      expect(warning.requiredInBand, 1);
    });

    test('the critical bracket: 16 MiB, at [16, 24] MiB, above '
        '(24, 40] MiB, two in band', () {
      expect(critical.eventName, 'sleuth.issue.uncached_images.critical');
      expect(critical.threshold, 16777216);
      expect(critical.atUpper, 25165824);
      expect(critical.aboveCeiling, 41943040);
      expect(critical.requiredInBand, 2);
    });

    test('scenario names and labels', () {
      expect(UncachedImagesLeg.values.map((l) => l.scenario), [
        'uncached_images_below',
        'uncached_images_at',
        'uncached_images_above',
        'uncached_images_critical_below',
        'uncached_images_critical_at',
        'uncached_images_critical_above',
      ]);
      expect(UncachedImagesLeg.below.buttonLabel, 'Below: 0.5 MiB wasted');
      expect(
        UncachedImagesLeg.criticalAbove.buttonLabel,
        'Critical above: 32 MiB wasted',
      );
    });

    test('export bands stay inside the role bands', () {
      expect(uncachedImagesBand(warning, 'below'), (min: 1.0, max: 1048575.0));
      expect(uncachedImagesBand(warning, 'above'), (
        min: 1572864.0,
        max: 2621440.0,
      ));
    });
  });

  group('uncachedImagesLastRecordRefusal', () {
    test('one image in the last record passes', () {
      expect(
        uncachedImagesLastRecordRefusal(
          _capture(['1', '1']),
          UncachedImagesLeg.at,
          bracket: warning,
        ),
        isNull,
      );
    });

    test('a second image in the last record is refused', () {
      expect(
        uncachedImagesLastRecordRefusal(
          _capture(['1', '2']),
          UncachedImagesLeg.at,
          bracket: warning,
        )?.reason,
        contains('measured 2 images'),
      );
    });

    test('below legs are not judged on a record', () {
      expect(
        uncachedImagesLastRecordRefusal(
          _capture([]),
          UncachedImagesLeg.below,
          bracket: warning,
        ),
        isNull,
      );
    });
  });

  group('leg lifecycle', () {
    // The test runs outside capture mode, without a VM link and without a
    // Sleuth instance, and the seams let a leg run anyway. With no Sleuth
    // instance the export returns null, so a finished leg ends with
    // "capture FAILED to compose".
    late _FakeSpecimens specimens;

    Future<void> pumpScreen(
      WidgetTester tester, {
      bool vmConnected = true,
      CaptureLegCalls calls = const CaptureLegCalls(),
      int decodedSide = 579,
      Size logicalSize = const Size(1200, 2400),
    }) async {
      tester.view.physicalSize = logicalSize * 3;
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      final made = await tester.runAsync(() async {
        final small = await createTestImage(width: 8, height: 8);
        final data = await small.toByteData(format: ui.ImageByteFormat.png);
        final big = await createTestImage(
          width: decodedSide,
          height: decodedSide,
        );
        return (png: data!.buffer.asUint8List(), image: big);
      });
      specimens = _FakeSpecimens(made!.png, made.image);
      await tester.pumpWidget(
        MaterialApp(
          home: UncachedImagesCaptureScreen(
            captureModeOverride: true,
            provenanceCheck: () => (
              provenance: const CaptureProvenance(
                device: 'iPhone 12',
                deviceOsVersion: 'iOS 17.5',
                flutterVersion: '3.47.6',
              ),
              problem: null,
            ),
            vmConnected: () => vmConnected,
            calls: calls,
            specimens: specimens,
          ),
        ),
      );
      await tester.pump();
    }

    Future<void> startLeg(WidgetTester tester, UncachedImagesLeg leg) async {
      final button = find.text(leg.buttonLabel);
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pump();
      await tester.pump();
    }

    /// Runs the dwell and the post-end wait of a leg.
    Future<void> finishLeg(WidgetTester tester) async {
      await tester.pump(const Duration(milliseconds: 3600));
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pump();
    }

    testWidgets('a leg without a VM link is refused before its workload', (
      tester,
    ) async {
      await pumpScreen(tester, vmConnected: false);
      await startLeg(tester, UncachedImagesLeg.at);
      expect(
        find.textContaining('[at] ABORT: VM service not connected'),
        findsOneWidget,
      );
      expect(specimens.sides, isEmpty);
    });

    testWidgets('a leg sizes its decode, shows one image for the span and '
        'drops it afterwards', (tester) async {
      final calls = _RecordingCalls()..flush = (Completer<void>()..complete());
      await pumpScreen(tester, calls: calls);
      await startLeg(tester, UncachedImagesLeg.at);
      expect(specimens.sides, [579]);
      expect(find.byType(Image), findsOneWidget);
      expect(find.textContaining('waste 1258020 B'), findsOneWidget);
      await finishLeg(tester);
      expect(calls.log, [
        'suspend',
        'begin uncached_images_at',
        'flush',
        'end uncached_images_at',
        'resume',
      ]);
      expect(find.byType(Image), findsNothing);
      expect(
        find.textContaining('[at] capture FAILED to compose'),
        findsOneWidget,
      );
      // The screen repeats the verdict once in an announced line.
      final outcome = find.textContaining(
        'Last leg (at): capture FAILED to compose',
      );
      expect(outcome, findsOneWidget);
      expect(
        tester
            .widget<Semantics>(
              find
                  .ancestor(of: outcome, matching: find.byType(Semantics))
                  .first,
            )
            .properties
            .liveRegion,
        isTrue,
      );
      expect(
        find.textContaining('a warning at 1 MiB wasted and critical at 16 MiB'),
        findsOneWidget,
      );
    });

    testWidgets('the image leaves as soon as the span ends, before the '
        'export', (tester) async {
      final calls = _RecordingCalls();
      await pumpScreen(tester, calls: calls);
      await startLeg(tester, UncachedImagesLeg.at);
      await tester.pump(const Duration(milliseconds: 3600));
      expect(find.byType(Image), findsOneWidget);
      calls.flush!.complete();
      await tester.pump();
      await tester.pump();
      // The span has ended and the 800 ms wait before the export runs; the
      // decode is released already.
      expect(calls.log.last, 'end uncached_images_at');
      expect(find.byType(Image), findsNothing);
      expect(find.text('Composing the capture'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('on an iPhone 12 at twice the text size, Export, the image '
        'row and the outcome stay on screen above the log', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final calls = _RecordingCalls()..flush = (Completer<void>()..complete());
      await pumpScreen(tester, calls: calls, logicalSize: const Size(390, 844));
      await startLeg(tester, UncachedImagesLeg.at);
      await finishLeg(tester);
      expect(tester.takeException(), isNull);
      final bottom =
          tester.view.physicalSize.height / tester.view.devicePixelRatio;
      for (final finder in [
        find.text('Export last leg'),
        find.textContaining('No leg image'),
        find.textContaining('Last leg (at)'),
      ]) {
        expect(tester.getRect(finder).bottom, lessThan(bottom));
      }
      expect(tester.getSize(find.byType(ListView)).height, greaterThan(48));
    });

    testWidgets('two legs in a row run on one screen', (tester) async {
      final calls = _RecordingCalls()..flush = (Completer<void>()..complete());
      await pumpScreen(tester, calls: calls);
      for (var leg = 0; leg < 2; leg++) {
        await startLeg(tester, UncachedImagesLeg.at);
        await finishLeg(tester);
      }
      expect(tester.takeException(), isNull);
      expect(find.textContaining('[at] attempt 2/5'), findsOneWidget);
      expect(calls.log.where((l) => l == 'resume'), hasLength(2));
    });

    testWidgets('closing the screen during the dwell ends the scenario and '
        'restores the streams at once', (tester) async {
      final calls = _RecordingCalls();
      await pumpScreen(tester, calls: calls);
      await startLeg(tester, UncachedImagesLeg.at);
      await tester.pump(const Duration(seconds: 1));
      expect(calls.log, ['suspend', 'begin uncached_images_at']);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(calls.log, [
        'suspend',
        'begin uncached_images_at',
        'end uncached_images_at',
        'resume',
      ]);
      await tester.pump(const Duration(seconds: 3));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a flush that times out ends the leg with a FAILED line', (
      tester,
    ) async {
      final calls = _RecordingCalls()..flushTimesOut = true;
      await pumpScreen(tester, calls: calls);
      await startLeg(tester, UncachedImagesLeg.at);
      await finishLeg(tester);
      expect(
        find.textContaining('[at] FAILED: TimeoutException'),
        findsOneWidget,
      );
      expect(calls.log.last, 'resume');
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('outside capture mode every leg stays disabled', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        const MaterialApp(home: UncachedImagesCaptureScreen()),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      for (final leg in UncachedImagesLeg.values) {
        final button = tester.widget<ButtonStyleButton>(
          find.ancestor(
            of: find.text(leg.buttonLabel),
            matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
          ),
        );
        expect(button.onPressed, isNull, reason: leg.label);
      }
    });
  });
}
