// The gc_pressure capture screen: its own young-GC count, the allocator's
// calibration and closed loop, the bracket it reads, and the leg
// lifecycle.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/detectors/memory_pressure_detector.dart';
import 'package:vm_service/vm_service.dart' show Event, VmService;

import 'package:example/demos/capture_driver.dart';
import 'package:example/demos/gc_pressure_capture_screen.dart';

/// A GC feed the test drives by hand.
class _FakeGcSource implements GcEventSource {
  void Function(DateTime at, String? gcType)? onEvent;
  int starts = 0;
  int stops = 0;

  @override
  Future<void> start(void Function(DateTime at, String? gcType) onEvent) async {
    starts++;
    this.onEvent = onEvent;
  }

  @override
  Future<void> stop() async {
    stops++;
    onEvent = null;
  }
}

/// A GC feed whose start completes only when the test says so.
class _SlowGcSource implements GcEventSource {
  final Completer<void> started = Completer<void>();
  int stops = 0;

  @override
  Future<void> start(void Function(DateTime at, String? gcType) onEvent) =>
      started.future;

  @override
  Future<void> stop() async => stops++;
}

/// An allocator that records its batches instead of allocating.
class _RecordingAllocator extends ChurnAllocator {
  final List<int> batches = [];
  bool _on = false;

  @override
  bool get running => _on;

  @override
  void start(int batch) {
    this.batch = batch;
    batches.add(batch);
    _on = true;
  }

  @override
  void stop() => _on = false;
}

/// Leg calls that record what a leg did and hold the flush open until
/// [flush] completes.
class _RecordingCalls extends CaptureLegCalls {
  final List<String> log = [];
  Completer<void>? flush;

  /// Whether the flush fails the way `flushTimelineNow` does past its
  /// 2 s limit.
  bool flushTimesOut = false;

  /// Whether restoring the streams throws after it is logged.
  bool resumeThrows = false;

  @override
  Future<void> suspendStreams() async => log.add('suspend');

  @override
  Future<void> resumeStreams() async {
    log.add('resume');
    if (resumeThrows) throw StateError('resume refused');
  }

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

/// The raw `kGC` payloads of an iPhone 12 fixture and its app isolate id.
({List<Map<String, dynamic>> events, String appIsolateId}) _fixture(
  String path,
) {
  final root =
      jsonDecode(File('../test/detectors/_fixtures/$path').readAsStringSync())
          as Map<String, dynamic>;
  final provenance = root['provenance'] as Map<String, dynamic>;
  return (
    events: (root['events'] as List).cast<Map<String, dynamic>>(),
    appIsolateId: provenance['appIsolateId'] as String,
  );
}

void main() {
  final bracket = gcPressureBracket(
    MemoryPressureDetector().validationMetadata,
  )!;

  group('YoungGcLog', () {
    test('peakIn counts the largest 10 s window, ends included', () {
      final log = YoungGcLog();
      final start = DateTime(2026);
      // One young collection every 200 ms for 13 s. A window that ends on
      // one also holds the one exactly 10 s before it, as the detector's
      // eviction keeps it.
      for (var ms = 0; ms <= 13000; ms += 200) {
        log.add(start.add(Duration(milliseconds: ms)), 'Scavenge');
      }
      expect(
        log.peakIn(
          const Duration(seconds: 10),
          from: start,
          to: start.add(const Duration(seconds: 13)),
        ),
        51,
      );
    });

    test('peakIn counts only arrivals inside [from, to]', () {
      final log = YoungGcLog();
      final start = DateTime(2026);
      for (var ms = 0; ms < 3000; ms += 100) {
        log.add(start.add(Duration(milliseconds: ms)), 'Scavenge');
      }
      expect(
        log.peakIn(
          const Duration(seconds: 10),
          from: start.add(const Duration(seconds: 1)),
          to: start.add(const Duration(seconds: 2)),
        ),
        11,
      );
    });

    test('old-generation sweeps and marking starts are not counted', () {
      final log = YoungGcLog();
      final at = DateTime(2026);
      for (final type in ['MarkSweep', 'MarkCompact', 'StartCMark']) {
        log.add(at, type);
      }
      log
        ..add(at, 'Scavenge')
        ..add(at, 'Evacuate')
        ..add(at, null);
      expect(log.countSince(at), 3);
    });
  });

  group('classification parity on iPhone 12 payloads', () {
    // The screen and the detector each classify the device's own kGC
    // payloads. Feeding the same events to both must give the same young
    // count, and the screen must drop other isolates' copies.
    for (final path in [
      'gc/ios_gc_churn.json',
      'gc/ios_live_waveform.json',
      'gc_dump_multi_isolate_ios_profile.json',
    ]) {
      test(path, () {
        final fixture = _fixture(path);
        final log = YoungGcLog();
        final at = DateTime(2026);
        final detector = MemoryPressureDetector(
          clock: () => at,
          warmupDurationMs: 0,
        )..vmConnected = true;
        var own = 0;
        for (final json in fixture.events) {
          final read = VmServiceGcEventSource.readGcEvent(
            Event.parse(json)!,
            fixture.appIsolateId,
          );
          if (!read.own) continue;
          own++;
          log.add(at, read.gcType);
          detector.recordGcCycle(gcType: read.gcType);
        }
        expect(own, greaterThan(0));
        expect(log.countSince(at), detector.gcWindowStats.young);
        if (path.contains('multi_isolate')) {
          expect(own, lessThan(fixture.events.length));
        }
      });
    }
  });

  group('VmServiceGcEventSource', () {
    test('a stop while the connection opens closes it and subscribes to '
        'nothing', () async {
      final sent = <String>[];
      final incoming = StreamController<String>();
      final service = VmService(incoming.stream, sent.add);
      final connecting = Completer<VmService>();
      final source = VmServiceGcEventSource(
        serviceUri: () async => Uri.parse('ws://127.0.0.1:1/ws'),
        connect: (_) => connecting.future,
      );
      final start = source.start((_, _) {});
      await Future<void>.delayed(Duration.zero);
      await source.stop();
      connecting.complete(service);
      // A start that ignored the stop would send streamListen and wait
      // for an answer that never comes.
      await start.timeout(const Duration(seconds: 1));
      await service.onDone.timeout(const Duration(seconds: 1));
      expect(sent, isEmpty, reason: 'no streamListen after the stop');
      await incoming.close();
    });
  });

  group('allocator rate', () {
    test('the closed loop steps at most 30 % toward the target', () {
      expect(nextChurnBatch(batch: 1000, measured: 25, target: 50), 1300);
      expect(nextChurnBatch(batch: 1000, measured: 100, target: 50), 700);
      expect(nextChurnBatch(batch: 1000, measured: 55, target: 50), 909);
    });

    test('with no collection measured the batch grows from a floor', () {
      expect(nextChurnBatch(batch: 0, measured: 0, target: 50), 65);
      expect(nextChurnBatch(batch: 400, measured: 0, target: 50), 520);
    });

    test('calibration scales the seed by the young GCs it added', () {
      expect(
        calibratedChurnBatch(
          ambient: 10,
          atSeed: 50,
          seedBatch: 1000,
          target: 50,
        ),
        1000,
      );
      expect(
        calibratedChurnBatch(
          ambient: 10,
          atSeed: 30,
          seedBatch: 1000,
          target: 80,
        ),
        3500,
      );
    });

    test('an ambient rate at the target needs no allocation', () {
      expect(
        calibratedChurnBatch(
          ambient: 30,
          atSeed: 60,
          seedBatch: 1000,
          target: 25,
        ),
        0,
      );
    });
  });

  group('bracket and legs', () {
    test('reads the detector bracket: 41, at [41, 61.5], above '
        '(61.5, 102.5], largest record, two in band', () {
      expect(bracket.eventName, 'sleuth.issue.gc_pressure.warning');
      expect(bracket.argKey, 'scavengeCount');
      expect(bracket.bandText('below'), '(0, 41)');
      expect(bracket.bandText('at'), '[41, 61.5]');
      expect(bracket.bandText('above'), '(61.5, 102.5]');
      expect(bracket.reduction, 'max');
      expect(bracket.requiredInBand, 2);
      expect(bracket.observedAxisTolerance, 0.25);
    });

    test('each leg target is a measurement its role accepts', () {
      for (final leg in GcPressureLeg.values) {
        expect(
          bracket.acceptsMeasurement(leg.target, leg.label),
          isTrue,
          reason: leg.label,
        );
      }
    });

    test('export bands stay inside the role bands', () {
      expect(gcPressureBand(bracket, 'below'), (min: 1.0, max: 40.0));
      expect(gcPressureBand(bracket, 'at'), (min: 41.0, max: 61.5));
      expect(gcPressureBand(bracket, 'above'), (min: 61.5, max: 102.5));
    });

    test('scenario names and labels', () {
      expect(GcPressureLeg.values.map((l) => l.scenario), [
        'gc_pressure_below',
        'gc_pressure_at',
        'gc_pressure_above',
      ]);
      expect(GcPressureLeg.at.buttonLabel, 'At: 50 young GCs in 10 s');
    });
  });

  group('leg lifecycle', () {
    // The test runs outside capture mode, without a VM link and without a
    // Sleuth instance, and the seams let a leg run anyway. The fake GC
    // feed sends nothing, so a finished leg is refused as unmeasured.
    late _FakeGcSource source;
    late _RecordingAllocator allocator;

    Future<void> pumpScreen(
      WidgetTester tester, {
      bool vmConnected = true,
      CaptureLegCalls calls = const CaptureLegCalls(),
      Size size = const Size(1200, 2400),
      GcEventSource Function()? gcEvents,
    }) async {
      source = _FakeGcSource();
      allocator = _RecordingAllocator();
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: GcPressureCaptureScreen(
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
            gcEvents: gcEvents ?? () => source,
            allocator: allocator,
          ),
        ),
      );
      await tester.pump();
    }

    Future<void> startLeg(WidgetTester tester, GcPressureLeg leg) async {
      final button = find.text(leg.buttonLabel);
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pump();
    }

    /// Runs ambient, calibration, settle and span, then the barrier.
    Future<void> runToFlush(WidgetTester tester) async {
      for (var s = 0; s < 23; s++) {
        await tester.pump(const Duration(seconds: 1));
      }
      await tester.pump(const Duration(milliseconds: 300));
    }

    testWidgets('a leg without a VM link is refused before its workload', (
      tester,
    ) async {
      await pumpScreen(tester, vmConnected: false);
      await startLeg(tester, GcPressureLeg.at);
      expect(
        find.textContaining('[at] ABORT: VM service not connected'),
        findsOneWidget,
      );
      expect(source.starts, 0);
      expect(allocator.batches, isEmpty);
    });

    testWidgets('a leg with no young GC is refused as unmeasured and '
        'releases everything', (tester) async {
      final calls = _RecordingCalls()..flush = (Completer<void>()..complete());
      await pumpScreen(tester, calls: calls);
      await startLeg(tester, GcPressureLeg.at);
      await runToFlush(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(
        find.textContaining('[at] UNMEASURED: young GC peak is 0'),
        findsOneWidget,
      );
      // The screen repeats the verdict once in an announced line.
      final outcome = find.textContaining('Last leg (at): UNMEASURED');
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
      expect(find.textContaining('fires at 41 young GCs in 10 s'), findsOne);
      expect(calls.log, [
        'suspend',
        'begin gc_pressure_at',
        'flush',
        'end gc_pressure_at',
        'resume',
      ]);
      expect(source.starts, 1);
      expect(source.stops, greaterThanOrEqualTo(1));
      expect(allocator.running, isFalse);
      expect(allocator.batches.first, 1000, reason: 'the calibration seed');
    });

    for (final size in const [Size(390, 844), Size(844, 390), Size(320, 568)]) {
      for (final textScale in const [1.0, 2.0]) {
        testWidgets('at $size and text scale $textScale Export, the status and '
            'the outcome stay in view, or the body scrolls as one column', (
          tester,
        ) async {
          tester.platformDispatcher.textScaleFactorTestValue = textScale;
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          final calls = _RecordingCalls()
            ..flush = (Completer<void>()..complete());
          await pumpScreen(tester, calls: calls, size: size);
          await startLeg(tester, GcPressureLeg.at);
          await runToFlush(tester);
          await tester.pump(const Duration(seconds: 1));
          expect(tester.takeException(), isNull);
          expect(find.textContaining('Last leg (at)'), findsOneWidget);
          final log = tester.getSize(find.byType(ListView)).height;
          final body = size.height - kToolbarHeight - 32;
          final split = body >= CaptureBodyLayout.minSplitHeight(textScale);
          if (size == const Size(390, 844)) expect(split, isTrue);
          if (!split) {
            expect(log, CaptureBodyLayout.compactLogHeight);
            return;
          }
          for (final finder in [
            find.text('Export last leg'),
            find.text('Idle.'),
            find.textContaining('Last leg (at)'),
          ]) {
            expect(tester.getRect(finder).bottom, lessThan(size.height));
          }
          expect(log, greaterThan(48));
        });
      }
    }

    testWidgets('a cleanup error after the verdict stays in the log and the '
        'outcome keeps the verdict', (tester) async {
      final calls = _RecordingCalls()
        ..flush = (Completer<void>()..complete())
        ..resumeThrows = true;
      await pumpScreen(tester, calls: calls);
      await startLeg(tester, GcPressureLeg.at);
      await runToFlush(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(
        find.textContaining('[at] resumeAllTimelineStreams'),
        findsOneWidget,
      );
      expect(find.textContaining('Last leg (at): UNMEASURED'), findsOneWidget);
    });

    testWidgets('a stopped feed of an earlier leg does not count in the '
        'next leg', (tester) async {
      final sources = <_FakeGcSource>[];
      final calls = _RecordingCalls()..flush = (Completer<void>()..complete());
      await pumpScreen(
        tester,
        calls: calls,
        gcEvents: () {
          final next = _FakeGcSource();
          sources.add(next);
          return next;
        },
      );
      await startLeg(tester, GcPressureLeg.at);
      await tester.pump(const Duration(seconds: 1));
      final stale = sources.single.onEvent!;
      await runToFlush(tester);
      await tester.pump(const Duration(seconds: 1));
      await startLeg(tester, GcPressureLeg.at);
      for (var s = 0; s < 12; s++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(sources, hasLength(2));
      // The first feed calls back after its stop, inside the second
      // leg's span.
      for (var i = 0; i < 60; i++) {
        stale(DateTime.now(), 'Scavenge');
      }
      await runToFlush(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(
        find.textContaining('[at] UNMEASURED: young GC peak is 0'),
        findsNWidgets(2),
      );
    });

    testWidgets('two legs in a row run on one screen', (tester) async {
      final calls = _RecordingCalls()..flush = (Completer<void>()..complete());
      await pumpScreen(tester, calls: calls);
      for (var leg = 0; leg < 2; leg++) {
        await startLeg(tester, GcPressureLeg.below);
        await runToFlush(tester);
        await tester.pump(const Duration(seconds: 1));
      }
      expect(tester.takeException(), isNull);
      expect(find.textContaining('[below] attempt 2/5'), findsOneWidget);
      expect(calls.log.where((l) => l == 'resume'), hasLength(2));
    });

    testWidgets('the closed loop follows the screen\'s own count', (
      tester,
    ) async {
      final calls = _RecordingCalls()..flush = (Completer<void>()..complete());
      await pumpScreen(tester, calls: calls);
      await startLeg(tester, GcPressureLeg.at);
      // Ambient and calibration see no collection, so the calibrated batch
      // is the cap. The loop then steps it down while the feed reports
      // 10 young GCs per second (100 per 10 s, twice the target).
      for (var s = 0; s < 10; s++) {
        await tester.pump(const Duration(seconds: 1));
      }
      final before = allocator.batches.length;
      for (var s = 0; s < 5; s++) {
        for (var i = 0; i < 10; i++) {
          source.onEvent?.call(DateTime.now(), 'Scavenge');
        }
        await tester.pump(const Duration(seconds: 1));
      }
      final loop = allocator.batches.skip(before).toList();
      expect(loop, isNotEmpty);
      for (var i = 1; i < loop.length; i++) {
        expect(loop[i], lessThanOrEqualTo(loop[i - 1]));
        expect(loop[i], greaterThanOrEqualTo((loop[i - 1] * 0.7).floor()));
      }
      await runToFlush(tester);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('closing the screen mid-span ends the scenario, restores '
        'the streams and stops the allocator and the feed at once', (
      tester,
    ) async {
      final calls = _RecordingCalls();
      await pumpScreen(tester, calls: calls);
      await startLeg(tester, GcPressureLeg.above);
      for (var s = 0; s < 12; s++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(calls.log, ['suspend', 'begin gc_pressure_above']);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(calls.log, [
        'suspend',
        'begin gc_pressure_above',
        'end gc_pressure_above',
        'resume',
      ]);
      expect(allocator.running, isFalse);
      expect(source.stops, greaterThanOrEqualTo(1));
      // The leg reaches its next one-second check and stops; no timer is
      // left pending when the test ends.
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('closing the screen while the GC feed starts stops the '
        'feed and leaves no timer', (tester) async {
      final slow = _SlowGcSource();
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final calls = _RecordingCalls();
      await tester.pumpWidget(
        MaterialApp(
          home: GcPressureCaptureScreen(
            captureModeOverride: true,
            provenanceCheck: () => (
              provenance: const CaptureProvenance(
                device: 'iPhone 12',
                deviceOsVersion: 'iOS 17.5',
                flutterVersion: '3.47.6',
              ),
              problem: null,
            ),
            vmConnected: () => true,
            calls: calls,
            gcEvents: () => slow,
            allocator: _RecordingAllocator(),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text(GcPressureLeg.at.buttonLabel));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(slow.stops, 1);
      expect(calls.log, ['suspend', 'resume']);
      // The start answers late; the leg sees the screen gone and stops.
      slow.started.complete();
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('a flush that times out ends the leg with a FAILED line', (
      tester,
    ) async {
      final calls = _RecordingCalls()..flushTimesOut = true;
      await pumpScreen(tester, calls: calls);
      await startLeg(tester, GcPressureLeg.below);
      await runToFlush(tester);
      await tester.pump();
      expect(
        find.textContaining('[below] FAILED: TimeoutException'),
        findsOneWidget,
      );
      expect(calls.log.last, 'resume');
    });

    testWidgets('outside capture mode every leg stays disabled', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        const MaterialApp(home: GcPressureCaptureScreen()),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      for (final leg in GcPressureLeg.values) {
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
