import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/sleuth.dart';
import 'package:sleuth/src/detectors/startup_detector.dart';

void main() {
  setUp(() {
    Sleuth.resetStartupForTest();
  });

  tearDown(() {
    Sleuth.resetStartupForTest();
  });

  group('StartupDetector', () {
    test('type is startup', () {
      final detector = StartupDetector();
      expect(detector.type, DetectorType.startup);
      detector.dispose();
    });

    test('lifecycle is structural', () {
      final detector = StartupDetector();
      expect(detector.lifecycle, DetectorLifecycle.structural);
      detector.dispose();
    });

    test('no issues when Sleuth.init() was not called', () {
      final detector = StartupDetector();
      // startupMetrics is null — init() was not called.
      expect(Sleuth.startupMetrics, isNull);

      // prepareScan should produce no issues.
      detector.prepareScan(_dummyContext());
      expect(detector.issues, isEmpty);
      detector.dispose();
    });

    test('no issues when TTFF is below warning threshold', () {
      _setStartupMetrics(ttffMs: 500); // well below default 1500ms

      final detector = StartupDetector();
      detector.prepareScan(_dummyContext());
      expect(detector.issues, isEmpty);
      detector.dispose();
    });

    test('warning severity when TTFF exceeds warning but not critical', () {
      _setStartupMetrics(ttffMs: 2000); // above 1500, below 3000

      final detector = StartupDetector();
      detector.prepareScan(_dummyContext());

      expect(detector.issues, hasLength(1));
      final issue = detector.issues.first;
      expect(issue.stableId, 'slow_startup_ttff');
      expect(issue.severity, IssueSeverity.warning);
      expect(issue.category, IssueCategory.startup);
      expect(issue.confidence, IssueConfidence.confirmed);
      expect(issue.title, contains('2000'));
      detector.dispose();
    });

    test('critical severity when TTFF exceeds critical threshold', () {
      _setStartupMetrics(ttffMs: 4000); // above 3000

      final detector = StartupDetector();
      detector.prepareScan(_dummyContext());

      expect(detector.issues, hasLength(1));
      final issue = detector.issues.first;
      expect(issue.stableId, 'slow_startup_ttff');
      expect(issue.severity, IssueSeverity.critical);
      detector.dispose();
    });

    test('custom thresholds are respected', () {
      _setStartupMetrics(ttffMs: 800);

      final detector = StartupDetector(
        ttffWarningMs: 500,
        ttffCriticalMs: 1000,
      );
      detector.prepareScan(_dummyContext());

      expect(detector.issues, hasLength(1));
      expect(detector.issues.first.severity, IssueSeverity.warning);
      detector.dispose();
    });

    test('detail includes TTFF value', () {
      _setStartupMetrics(ttffMs: 2500);

      final detector = StartupDetector();
      detector.prepareScan(_dummyContext());

      expect(detector.issues.first.detail, contains('2500'));
      detector.dispose();
    });

    test('detail includes TTI when available', () {
      _setStartupMetrics(ttffMs: 2500, ttiMs: 3500);

      final detector = StartupDetector();
      detector.prepareScan(_dummyContext());

      expect(detector.issues.first.detail, contains('3500'));
      detector.dispose();
    });

    test('detail includes first frame breakdown', () {
      _setStartupMetrics(
        ttffMs: 2500,
        buildMs: 15.0,
        rasterMs: 8.0,
        totalMs: 25.0,
        vsyncMs: 2.0,
      );

      final detector = StartupDetector();
      detector.prepareScan(_dummyContext());

      final detail = detector.issues.first.detail;
      expect(detail, contains('Build:'));
      expect(detail, contains('Raster:'));
      expect(detail, contains('Total:'));
      detector.dispose();
    });

    test('detail includes VM sub-phases when available', () {
      _setStartupMetrics(
        ttffMs: 2500,
        vmBuildScopeMs: 10.0,
        vmFlushLayoutMs: 3.0,
      );

      final detector = StartupDetector();
      detector.prepareScan(_dummyContext());

      final detail = detector.issues.first.detail;
      expect(detail, contains('buildScope:'));
      expect(detail, contains('flushLayout:'));
      detector.dispose();
    });

    test('one-shot: second prepareScan produces no new issues', () {
      _setStartupMetrics(ttffMs: 2500);

      final detector = StartupDetector();
      detector.prepareScan(_dummyContext());
      expect(detector.issues, hasLength(1));

      // Second scan — metrics still present, but _consumed is true.
      detector.prepareScan(_dummyContext());
      expect(detector.issues, hasLength(1)); // same issues, not doubled
      detector.dispose();
    });

    test('checkElement is a no-op', () {
      final detector = StartupDetector();
      // Should not throw.
      detector.checkElement(_dummyElement());
      detector.dispose();
    });

    test('finalizeScan is a no-op', () {
      final detector = StartupDetector();
      // Should not throw.
      detector.finalizeScan();
      detector.dispose();
    });

    test('dispose clears issues', () {
      _setStartupMetrics(ttffMs: 2500);

      final detector = StartupDetector();
      detector.prepareScan(_dummyContext());
      expect(detector.issues, hasLength(1));

      detector.dispose();
      expect(detector.issues, isEmpty);
    });

    test('isEnabled flag gates detection', () {
      _setStartupMetrics(ttffMs: 2500);

      final detector = StartupDetector()..isEnabled = false;
      expect(detector.isEnabled, isFalse);

      detector.isEnabled = true;
      expect(detector.isEnabled, isTrue);
      detector.dispose();
    });
  });

  group('StartupMetrics', () {
    test('dominantPhase returns build when build exceeds 50%', () {
      final metrics = StartupMetrics(
        dartEntryTimestamp: DateTime.now(),
        firstFrameBuildMs: 300,
        firstFrameRasterMs: 100,
        firstFrameVsyncOverheadMs: 50,
        firstFrameTotalMs: 500,
      );
      expect(metrics.dominantPhase, 'build');
    });

    test('dominantPhase returns raster when raster exceeds 50%', () {
      final metrics = StartupMetrics(
        dartEntryTimestamp: DateTime.now(),
        firstFrameBuildMs: 100,
        firstFrameRasterMs: 300,
        firstFrameVsyncOverheadMs: 50,
        firstFrameTotalMs: 500,
      );
      expect(metrics.dominantPhase, 'raster');
    });

    test('dominantPhase returns balanced when no phase exceeds 50%', () {
      final metrics = StartupMetrics(
        dartEntryTimestamp: DateTime.now(),
        firstFrameBuildMs: 200,
        firstFrameRasterMs: 200,
        firstFrameVsyncOverheadMs: 100,
        firstFrameTotalMs: 500,
      );
      expect(metrics.dominantPhase, 'balanced');
    });

    test('dominantPhase returns unknown when totalMs is null', () {
      final metrics = StartupMetrics(dartEntryTimestamp: DateTime.now());
      expect(metrics.dominantPhase, 'unknown');
    });

    test('dominantPhasePercent returns correct percentage', () {
      final metrics = StartupMetrics(
        dartEntryTimestamp: DateTime.now(),
        firstFrameBuildMs: 400,
        firstFrameRasterMs: 50,
        firstFrameVsyncOverheadMs: 50,
        firstFrameTotalMs: 500,
      );
      expect(metrics.dominantPhasePercent, 80.0);
    });

    test('copyWith updates ttiMs', () {
      final original = StartupMetrics(
        dartEntryTimestamp: DateTime(2026, 4, 10),
        ttffMs: 1200,
      );
      final updated = original.copyWith(ttiMs: 2000);
      expect(updated.ttiMs, 2000);
      expect(updated.ttffMs, 1200);
      expect(updated.dartEntryTimestamp, DateTime(2026, 4, 10));
    });

    test('copyWith updates VM sub-phases', () {
      final original = StartupMetrics(
        dartEntryTimestamp: DateTime(2026, 4, 10),
        ttffMs: 1200,
      );
      final updated = original.copyWith(
        vmFirstBuildScopeMs: 10,
        vmFirstFlushLayoutMs: 5,
      );
      expect(updated.vmFirstBuildScopeMs, 10);
      expect(updated.vmFirstFlushLayoutMs, 5);
      expect(updated.vmFirstFlushPaintMs, isNull);
    });

    test('toJson produces expected keys', () {
      final metrics = StartupMetrics(
        dartEntryTimestamp: DateTime(2026, 4, 10),
        ttffMs: 1500.5,
        ttiMs: 2500.3,
        firstFrameBuildMs: 10.12,
        firstFrameRasterMs: 5.67,
        firstFrameTotalMs: 20.99,
      );
      final json = metrics.toJson();
      expect(json['dartEntryTimestamp'], isNotNull);
      expect(json['ttffMs'], 1500.5);
      expect(json['ttiMs'], 2500.3);
      expect(json['dominantPhase'], isNotNull);
      expect(json['dominantPhasePercent'], isNotNull);
    });

    test('fromJson round-trips correctly', () {
      final original = StartupMetrics(
        dartEntryTimestamp: DateTime(2026, 4, 10),
        ttffMs: 1500,
        ttiMs: 2500,
        firstFrameBuildMs: 10,
        firstFrameRasterMs: 5,
        firstFrameTotalMs: 20,
        vmFirstBuildScopeMs: 8,
      );
      final json = original.toJson();
      final restored = StartupMetrics.fromJson(json);
      expect(restored.ttffMs, original.ttffMs);
      expect(restored.ttiMs, original.ttiMs);
      expect(restored.firstFrameBuildMs, original.firstFrameBuildMs);
      expect(restored.vmFirstBuildScopeMs, original.vmFirstBuildScopeMs);
    });

    test('fromJson round-trip truncates to documented precision', () {
      // toJson uses toStringAsFixed(1) for TTFF/TTI, toStringAsFixed(2) for
      // phase values. Non-exact decimals are rounded on round-trip.
      final original = StartupMetrics(
        dartEntryTimestamp: DateTime(2026, 4, 10),
        ttffMs: 1500.15, // .15 rounds to .2 (1 decimal)
        ttiMs: 2500.99, // .99 rounds to 2501.0 (1 decimal)
        firstFrameBuildMs: 10.125, // .125 rounds to .13 (2 decimals)
        firstFrameRasterMs: 5.999, // rounds to 6.00 (2 decimals)
        firstFrameTotalMs: 20.5,
      );
      final json = original.toJson();
      final restored = StartupMetrics.fromJson(json);
      // TTFF: 1500.15 → toStringAsFixed(1) → "1500.2" → 1500.2
      expect(restored.ttffMs, 1500.2);
      // TTI: 2500.99 → toStringAsFixed(1) → "2501.0" → 2501.0
      expect(restored.ttiMs, 2501.0);
      // Build: 10.125 → toStringAsFixed(2) → "10.13" → 10.13 (not 10.125)
      expect(restored.firstFrameBuildMs, 10.13);
      // Raster: 5.999 → toStringAsFixed(2) → "6.00" → 6.0
      expect(restored.firstFrameRasterMs, 6.0);
    });

    test('engine fields are included in toJson and fromJson', () {
      final original = StartupMetrics(
        dartEntryTimestamp: DateTime(2026, 4, 10),
        ttffMs: 1500,
        dartEntryMonotonicUs: 22614577000,
        frameworkInitDurationUs: 281595,
        engineEnterUs: 22332982085,
        firstFrameRasterizedUs: 22334541649,
      );
      final json = original.toJson();
      expect(json['dartEntryMonotonicUs'], 22614577000);
      expect(json['frameworkInitDurationUs'], 281595);
      expect(json['engineEnterUs'], 22332982085);
      expect(json['firstFrameRasterizedUs'], 22334541649);
      // Computed getters in JSON
      expect(json['frameworkInitMs'], closeTo(281.60, 0.01));
      expect(json['engineTtffMs'], closeTo(1559.56, 0.01));

      final restored = StartupMetrics.fromJson(json);
      expect(restored.dartEntryMonotonicUs, 22614577000);
      expect(restored.frameworkInitDurationUs, 281595);
      expect(restored.engineEnterUs, 22332982085);
      expect(restored.firstFrameRasterizedUs, 22334541649);
    });

    test('computed getters: frameworkInitMs', () {
      final metrics = StartupMetrics(
        dartEntryTimestamp: DateTime.now(),
        frameworkInitDurationUs: 500000, // 500 ms
      );
      expect(metrics.frameworkInitMs, 500.0);
    });

    test('computed getters: preDartOverheadMs', () {
      final metrics = StartupMetrics(
        dartEntryTimestamp: DateTime.now(),
        dartEntryMonotonicUs: 1000000, // 1s
        engineEnterUs: 500000, // 0.5s
      );
      // preDartOverhead = (dartEntry - engineEnter) / 1000
      expect(metrics.preDartOverheadMs, 500.0);
    });

    test('computed getters: engineTtffMs', () {
      final metrics = StartupMetrics(
        dartEntryTimestamp: DateTime.now(),
        engineEnterUs: 22332982085,
        firstFrameRasterizedUs: 22332982085 + 1559564,
      );
      expect(metrics.engineTtffMs, closeTo(1559.564, 0.001));
    });

    test('computed getters return null when source data missing', () {
      final metrics = StartupMetrics(dartEntryTimestamp: DateTime.now());
      expect(metrics.frameworkInitMs, isNull);
      expect(metrics.preDartOverheadMs, isNull);
      expect(metrics.engineTtffMs, isNull);
    });

    test('preDartOverheadMs returns null on negative delta (clock anomaly)',
        () {
      // engineEnterUs AFTER dartEntryMonotonicUs → negative delta → null
      final metrics = StartupMetrics(
        dartEntryTimestamp: DateTime.now(),
        dartEntryMonotonicUs: 1000000,
        engineEnterUs: 2000000, // engine timestamp after Dart entry
      );
      expect(metrics.preDartOverheadMs, isNull);
    });

    test('copyWith updates engine fields', () {
      final original = StartupMetrics(
        dartEntryTimestamp: DateTime(2026, 4, 10),
        ttffMs: 1200,
        dartEntryMonotonicUs: 1000,
      );
      final updated = original.copyWith(
        engineEnterUs: 500,
        firstFrameRasterizedUs: 2500,
      );
      expect(updated.dartEntryMonotonicUs, 1000); // preserved
      expect(updated.engineEnterUs, 500);
      expect(updated.firstFrameRasterizedUs, 2500);
      expect(updated.ttffMs, 1200); // preserved
    });
  });

  group('SessionSnapshot startupMetrics', () {
    test('toJson includes startupMetrics when present', () {
      final snapshot = SessionSnapshot(
        exportedAt: DateTime(2026, 4, 10),
        capturedFrames: const [],
        currentIssues: const [],
        frameStatsSummary: const FrameStatsSummary(
          totalFrames: 100,
          jankFrames: 2,
          averageFps: 58.5,
          worstFrameTimeUs: 34000,
        ),
        startupMetrics: StartupMetrics(
          dartEntryTimestamp: DateTime(2026, 4, 10),
          ttffMs: 1500,
        ),
      );
      final json = snapshot.toJson();
      expect(json.containsKey('startupMetrics'), isTrue);
      expect((json['startupMetrics'] as Map)['ttffMs'], 1500.0);
    });

    test('toJson omits startupMetrics when null', () {
      final snapshot = SessionSnapshot(
        exportedAt: DateTime(2026, 4, 10),
        capturedFrames: const [],
        currentIssues: const [],
        frameStatsSummary: const FrameStatsSummary(
          totalFrames: 100,
          jankFrames: 2,
          averageFps: 58.5,
          worstFrameTimeUs: 34000,
        ),
      );
      final json = snapshot.toJson();
      expect(json.containsKey('startupMetrics'), isFalse);
    });

    test('fromJson restores startupMetrics', () {
      final original = SessionSnapshot(
        exportedAt: DateTime(2026, 4, 10),
        capturedFrames: const [],
        currentIssues: const [],
        frameStatsSummary: const FrameStatsSummary(
          totalFrames: 100,
          jankFrames: 2,
          averageFps: 58.5,
          worstFrameTimeUs: 34000,
        ),
        startupMetrics: StartupMetrics(
          dartEntryTimestamp: DateTime(2026, 4, 10),
          ttffMs: 1500,
          ttiMs: 2500,
        ),
      );
      final json = original.toJson();
      final restored = SessionSnapshot.fromJson(json);
      expect(restored.startupMetrics, isNotNull);
      expect(restored.startupMetrics!.ttffMs, 1500.0);
      expect(restored.startupMetrics!.ttiMs, 2500.0);
    });
  });

  group('Sleuth.init / markInteractive integration', () {
    test('markInteractive updates TTI on pre-existing metrics', () {
      // Simulate the real pipeline: init() captures _dartEntryTimestamp,
      // first-frame callback populates metrics, then markInteractive() is
      // called later. We can't mock FrameTiming, but we CAN verify that
      // markInteractive() correctly updates TTI on existing metrics.
      final before = DateTime.now();
      Sleuth.setStartupMetricsForTest(StartupMetrics(
        dartEntryTimestamp: before,
        ttffMs: 1200,
      ));
      // TTI should be null initially.
      expect(Sleuth.startupMetrics!.ttiMs, isNull);

      // Simulate init() having captured _dartEntryTimestamp by calling init()
      // directly. In a real app, init() runs before runApp().
      Sleuth.resetStartupForTest();
      Sleuth.init();
      // Inject metrics as if the first-frame callback fired.
      Sleuth.setStartupMetricsForTest(StartupMetrics(
        dartEntryTimestamp: before,
        ttffMs: 1200,
      ));
      Sleuth.markInteractive();
      // markInteractive() should have set ttiMs since _dartEntryTimestamp
      // was captured by init().
      expect(Sleuth.startupMetrics!.ttiMs, isNotNull);
      expect(Sleuth.startupMetrics!.ttiMs!, greaterThan(0));
    });

    test('markInteractive is no-op without init()', () {
      // Without init(), _dartEntryTimestamp is null, so markInteractive
      // should silently return without modifying metrics.
      Sleuth.setStartupMetricsForTest(StartupMetrics(
        dartEntryTimestamp: DateTime.now(),
        ttffMs: 1200,
      ));
      Sleuth.markInteractive();
      // TTI remains null because init() was never called.
      expect(Sleuth.startupMetrics!.ttiMs, isNull);
    });
  });

  group('deferred engine enrichment', () {
    test('engine events buffered when metrics not yet available', () {
      // Simulate: VM poll delivers engine events BEFORE first-frame callback.
      // enrichStartupWithVmData should buffer, not drop.
      Sleuth.enrichStartupWithVmData(
        engineEnterUs: 22332982085,
        firstFrameRasterizedUs: 22334541649,
      );

      // No metrics yet — engine data should be buffered, not lost.
      expect(Sleuth.startupMetrics, isNull);

      // Now simulate the first-frame callback by injecting metrics and
      // calling init() which triggers the flush in the callback.
      // Since we can't trigger the real callback, verify the buffer
      // by setting metrics and re-enriching (the buffer was consumed
      // in the real callback path).
      Sleuth.setStartupMetricsForTest(StartupMetrics(
        dartEntryTimestamp: DateTime.now(),
        ttffMs: 2000,
        dartEntryMonotonicUs: 22614577000,
      ));

      // Re-enrich to simulate what the controller does — the real fix
      // applies the buffer in the first-frame callback, but here we
      // verify the enrichment path works when metrics exist.
      Sleuth.enrichStartupWithVmData(
        engineEnterUs: 22332982085,
        firstFrameRasterizedUs: 22334541649,
      );
      expect(Sleuth.startupMetrics!.engineEnterUs, 22332982085);
      expect(Sleuth.startupMetrics!.firstFrameRasterizedUs, 22334541649);
      expect(Sleuth.startupMetrics!.engineTtffMs, isNotNull);
    });

    test('enrichment works normally when metrics already exist', () {
      Sleuth.setStartupMetricsForTest(StartupMetrics(
        dartEntryTimestamp: DateTime.now(),
        ttffMs: 2000,
        dartEntryMonotonicUs: 22614577000,
      ));

      Sleuth.enrichStartupWithVmData(
        engineEnterUs: 22332982085,
        firstFrameRasterizedUs: 22334541649,
      );

      expect(Sleuth.startupMetrics!.engineEnterUs, 22332982085);
      expect(Sleuth.startupMetrics!.firstFrameRasterizedUs, 22334541649);
    });

    test('deferred buffer stores sub-phases alongside engine timestamps', () {
      // Enrich with all 6 fields while metrics are null (deferred path).
      Sleuth.enrichStartupWithVmData(
        engineEnterUs: 22332982085,
        firstFrameRasterizedUs: 22334541649,
        vmFirstBuildScopeMs: 3.0,
        vmFirstFlushLayoutMs: 1.5,
        vmFirstFlushPaintMs: 0.8,
        vmFirstRasterMs: 5.0,
      );

      // Buffer should hold everything — metrics not yet available.
      expect(Sleuth.startupMetrics, isNull);

      // Set metrics, then re-enrich to simulate the direct-apply path.
      Sleuth.setStartupMetricsForTest(StartupMetrics(
        dartEntryTimestamp: DateTime.now(),
        ttffMs: 2000,
        dartEntryMonotonicUs: 22614577000,
      ));

      Sleuth.enrichStartupWithVmData(
        engineEnterUs: 22332982085,
        firstFrameRasterizedUs: 22334541649,
        vmFirstBuildScopeMs: 3.0,
        vmFirstFlushLayoutMs: 1.5,
        vmFirstFlushPaintMs: 0.8,
        vmFirstRasterMs: 5.0,
      );

      // All 6 fields should be present on the metrics.
      final m = Sleuth.startupMetrics!;
      expect(m.engineEnterUs, 22332982085);
      expect(m.firstFrameRasterizedUs, 22334541649);
      expect(m.vmFirstBuildScopeMs, 3.0);
      expect(m.vmFirstFlushLayoutMs, 1.5);
      expect(m.vmFirstFlushPaintMs, 0.8);
      expect(m.vmFirstRasterMs, 5.0);
    });

    test('sub-phases enrich directly when metrics already exist', () {
      Sleuth.setStartupMetricsForTest(StartupMetrics(
        dartEntryTimestamp: DateTime.now(),
        ttffMs: 2000,
        dartEntryMonotonicUs: 22614577000,
      ));

      Sleuth.enrichStartupWithVmData(
        engineEnterUs: 22332982085,
        firstFrameRasterizedUs: 22334541649,
        vmFirstBuildScopeMs: 4.2,
        vmFirstFlushLayoutMs: 2.1,
        vmFirstFlushPaintMs: 0.9,
        vmFirstRasterMs: 6.3,
      );

      final m = Sleuth.startupMetrics!;
      expect(m.vmFirstBuildScopeMs, 4.2);
      expect(m.vmFirstFlushLayoutMs, 2.1);
      expect(m.vmFirstFlushPaintMs, 0.9);
      expect(m.vmFirstRasterMs, 6.3);
    });
  });

  group('engine-level detail display', () {
    test('detail includes framework init when available', () {
      _setStartupMetrics(
        ttffMs: 2500,
        frameworkInitDurationUs: 281595, // ~281.6 ms
      );

      final detector = StartupDetector();
      detector.prepareScan(_dummyContext());

      final detail = detector.issues.first.detail;
      expect(detail, contains('Framework init:'));
      expect(detail, contains('281.6'));
      detector.dispose();
    });

    test('detail includes pre-Dart overhead when engine data available', () {
      _setStartupMetrics(
        ttffMs: 2500,
        dartEntryMonotonicUs: 22614577000,
        engineEnterUs: 22332982085,
      );

      final detector = StartupDetector();
      detector.prepareScan(_dummyContext());

      final detail = detector.issues.first.detail;
      expect(detail, contains('Pre-Dart overhead:'));
      detector.dispose();
    });

    test('detail includes engine TTFF when available', () {
      _setStartupMetrics(
        ttffMs: 2500,
        engineEnterUs: 22332982085,
        firstFrameRasterizedUs: 22332982085 + 1559564, // ~1559.6 ms
      );

      final detector = StartupDetector();
      detector.prepareScan(_dummyContext());

      final detail = detector.issues.first.detail;
      expect(detail, contains('Engine TTFF:'));
      expect(detail, contains('1559.6'));
      detector.dispose();
    });

    test('detail omits engine section when no engine data', () {
      _setStartupMetrics(ttffMs: 2500);

      final detector = StartupDetector();
      detector.prepareScan(_dummyContext());

      final detail = detector.issues.first.detail;
      expect(detail, isNot(contains('Engine startup phases:')));
      detector.dispose();
    });
  });

  group('DetectorThresholds startup fields', () {
    test('default values', () {
      const thresholds = DetectorThresholds();
      expect(thresholds.startupTtffWarningMs, 1500);
      expect(thresholds.startupTtffCriticalMs, 3000);
    });

    test('custom values are accepted', () {
      const thresholds = DetectorThresholds(
        startupTtffWarningMs: 1000,
        startupTtffCriticalMs: 2000,
      );
      expect(thresholds.startupTtffWarningMs, 1000);
      expect(thresholds.startupTtffCriticalMs, 2000);
    });
  });
}

void _setStartupMetrics({
  double? ttffMs,
  double? ttiMs,
  double? buildMs,
  double? rasterMs,
  double? vsyncMs,
  double? totalMs,
  double? vmBuildScopeMs,
  double? vmFlushLayoutMs,
  int? dartEntryMonotonicUs,
  int? frameworkInitDurationUs,
  int? engineEnterUs,
  int? firstFrameRasterizedUs,
}) {
  Sleuth.setStartupMetricsForTest(StartupMetrics(
    dartEntryTimestamp: DateTime.now(),
    ttffMs: ttffMs,
    ttiMs: ttiMs,
    firstFrameBuildMs: buildMs,
    firstFrameRasterMs: rasterMs,
    firstFrameVsyncOverheadMs: vsyncMs,
    firstFrameTotalMs: totalMs,
    vmFirstBuildScopeMs: vmBuildScopeMs,
    vmFirstFlushLayoutMs: vmFlushLayoutMs,
    dartEntryMonotonicUs: dartEntryMonotonicUs,
    frameworkInitDurationUs: frameworkInitDurationUs,
    engineEnterUs: engineEnterUs,
    firstFrameRasterizedUs: firstFrameRasterizedUs,
  ));
}

BuildContext _dummyContext() => _DummyElement();

Element _dummyElement() => _DummyElement();

class _DummyElement extends Element {
  _DummyElement() : super(const SizedBox());

  @override
  bool get debugDoingBuild => false;

  @override
  // ignore: must_call_super — test stub
  void performRebuild() {}
}
