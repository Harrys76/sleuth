import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/widget_watchdog.dart';

void main() {
  group('PerformanceIssue serialization', () {
    test('roundtrip with all fields populated', () {
      final original = PerformanceIssue(
        severity: IssueSeverity.critical,
        category: IssueCategory.build,
        confidence: IssueConfidence.confirmed,
        title: 'Heavy build',
        detail: '20.0ms blocks frame rendering',
        fixHint: 'Use Isolate.run()',
        stableId: 'heavy_compute',
        widgetName: 'MyWidget',
        routeName: '/home',
        observationSource: ObservationSource.vmTimeline,
        interactionContext: InteractionContext.scrolling,
        debugModeDisclaimer: true,
        detectedAt: DateTime.utc(2026, 3, 26, 12, 0, 0),
      );

      final json = original.toJson();
      final restored = PerformanceIssue.fromJson(json);

      expect(restored.severity, original.severity);
      expect(restored.category, original.category);
      expect(restored.confidence, original.confidence);
      expect(restored.title, original.title);
      expect(restored.detail, original.detail);
      expect(restored.fixHint, original.fixHint);
      expect(restored.stableId, original.stableId);
      expect(restored.widgetName, original.widgetName);
      expect(restored.routeName, original.routeName);
      expect(restored.observationSource, original.observationSource);
      expect(restored.interactionContext, original.interactionContext);
      expect(restored.debugModeDisclaimer, original.debugModeDisclaimer);
      expect(restored.detectedAt, original.detectedAt);
    });

    test('nullable fields omitted when null', () {
      const issue = PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.layout,
        confidence: IssueConfidence.possible,
        title: 'Intrinsic',
        detail: 'detail',
        fixHint: 'fix',
      );

      final json = issue.toJson();

      expect(json.containsKey('stableId'), isFalse);
      expect(json.containsKey('widgetName'), isFalse);
      expect(json.containsKey('routeName'), isFalse);
      expect(json.containsKey('observationSource'), isFalse);
      expect(json.containsKey('interactionContext'), isFalse);
      expect(json.containsKey('detectedAt'), isFalse);
    });

    test('fromJson handles absent nullable fields', () {
      final json = {
        'severity': 'warning',
        'category': 'layout',
        'confidence': 'possible',
        'title': 'Test',
        'detail': 'detail',
        'fixHint': 'fix',
        'debugModeDisclaimer': false,
      };

      final issue = PerformanceIssue.fromJson(json);

      expect(issue.stableId, isNull);
      expect(issue.widgetName, isNull);
      expect(issue.routeName, isNull);
      expect(issue.observationSource, isNull);
      expect(issue.interactionContext, isNull);
      expect(issue.detectedAt, isNull);
      expect(issue.debugModeDisclaimer, isFalse);
    });

    test('enums serialize as .name strings', () {
      const issue = PerformanceIssue(
        severity: IssueSeverity.critical,
        category: IssueCategory.raster,
        confidence: IssueConfidence.likely,
        title: 'T',
        detail: 'D',
        fixHint: 'F',
        observationSource: ObservationSource.debugCallbackAndStructural,
        interactionContext: InteractionContext.navigating,
      );

      final json = issue.toJson();
      expect(json['severity'], 'critical');
      expect(json['category'], 'raster');
      expect(json['confidence'], 'likely');
      expect(json['observationSource'], 'debugCallbackAndStructural');
      expect(json['interactionContext'], 'navigating');
    });
  });

  group('FrameStats serialization', () {
    test('roundtrip preserves Duration microsecond precision', () {
      final original = FrameStats(
        frameNumber: 42,
        uiDuration: const Duration(microseconds: 12345),
        rasterDuration: const Duration(microseconds: 67890),
        timestamp: DateTime.utc(2026, 3, 26, 12, 0, 0),
        vsyncOverhead: const Duration(microseconds: 500),
        layerCacheCount: 5,
        pictureCacheBytes: 1024000,
        frameBudgetMs: 8,
        totalSpan: const Duration(microseconds: 25000),
        buildToRasterGap: const Duration(microseconds: 3000),
      );

      final json = original.toJson();
      final restored = FrameStats.fromJson(json);

      expect(restored.frameNumber, 42);
      expect(restored.uiDuration.inMicroseconds, 12345);
      expect(restored.rasterDuration.inMicroseconds, 67890);
      expect(restored.timestamp, original.timestamp);
      expect(restored.vsyncOverhead.inMicroseconds, 500);
      expect(restored.layerCacheCount, 5);
      expect(restored.pictureCacheBytes, 1024000);
      expect(restored.frameBudgetMs, 8);
      expect(restored.totalSpan!.inMicroseconds, 25000);
      expect(restored.buildToRasterGap.inMicroseconds, 3000);
    });

    test('Duration fields use Us suffix in JSON keys', () {
      final stats = FrameStats(
        frameNumber: 1,
        uiDuration: const Duration(microseconds: 100),
        rasterDuration: const Duration(microseconds: 200),
        timestamp: DateTime.utc(2026),
        totalSpan: const Duration(microseconds: 100),
        buildToRasterGap: const Duration(microseconds: 50),
      );

      final json = stats.toJson();
      expect(json.containsKey('uiDurationUs'), isTrue);
      expect(json.containsKey('rasterDurationUs'), isTrue);
      expect(json.containsKey('vsyncOverheadUs'), isTrue);
      expect(json.containsKey('totalSpanUs'), isTrue);
      expect(json.containsKey('buildToRasterGapUs'), isTrue);
    });

    test('fromJson defaults for optional fields', () {
      final json = {
        'frameNumber': 1,
        'uiDurationUs': 1000,
        'rasterDurationUs': 2000,
        'timestamp': '2026-01-01T00:00:00.000Z',
      };

      final stats = FrameStats.fromJson(json);
      expect(stats.vsyncOverhead, Duration.zero);
      expect(stats.layerCacheCount, 0);
      expect(stats.pictureCacheBytes, 0);
      expect(stats.frameBudgetMs, 16);
      expect(stats.totalSpan, isNull);
      expect(stats.buildToRasterGap, Duration.zero);
    });

    test('roundtrip with phase timestamps', () {
      final original = FrameStats(
        frameNumber: 1,
        uiDuration: const Duration(microseconds: 10000),
        rasterDuration: const Duration(microseconds: 5000),
        timestamp: DateTime.utc(2026, 3, 26),
        vsyncStartUs: 100000,
        buildStartUs: 101000,
        buildFinishUs: 111000,
        rasterStartUs: 112000,
        rasterFinishUs: 117000,
      );

      final json = original.toJson();
      expect(json['vsyncStartUs'], 100000);
      expect(json['buildStartUs'], 101000);
      expect(json['buildFinishUs'], 111000);
      expect(json['rasterStartUs'], 112000);
      expect(json['rasterFinishUs'], 117000);

      final restored = FrameStats.fromJson(json);
      expect(restored.vsyncStartUs, 100000);
      expect(restored.buildStartUs, 101000);
      expect(restored.buildFinishUs, 111000);
      expect(restored.rasterStartUs, 112000);
      expect(restored.rasterFinishUs, 117000);
      expect(restored.hasPhaseTimestamps, isTrue);
    });

    test('roundtrip with null timestamps (backward compat)', () {
      final original = FrameStats(
        frameNumber: 1,
        uiDuration: const Duration(microseconds: 10000),
        rasterDuration: const Duration(microseconds: 5000),
        timestamp: DateTime.utc(2026, 3, 26),
      );

      final json = original.toJson();
      expect(json.containsKey('vsyncStartUs'), isFalse);
      expect(json.containsKey('buildStartUs'), isFalse);

      final restored = FrameStats.fromJson(json);
      expect(restored.vsyncStartUs, isNull);
      expect(restored.buildStartUs, isNull);
      expect(restored.hasPhaseTimestamps, isFalse);
    });
  });

  group('FrameVerdict serialization', () {
    test('roundtrip with full mode and nested relatedIssues', () {
      const issue = PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.build,
        confidence: IssueConfidence.possible,
        title: 'Issue',
        detail: 'Detail',
        fixHint: 'Fix',
      );

      final original = FrameVerdict(
        frameNumber: 10,
        totalFrameTime: const Duration(microseconds: 20000),
        uiThreadTime: const Duration(microseconds: 15000),
        rasterThreadTime: const Duration(microseconds: 5000),
        buildScopeTime: const Duration(microseconds: 10000),
        flushLayoutTime: const Duration(microseconds: 3000),
        flushPaintTime: const Duration(microseconds: 2000),
        totalSpan: const Duration(microseconds: 26000),
        buildToRasterGapTime: const Duration(microseconds: 4000),
        suspectedPhase: PipelinePhase.build,
        reason: 'Build dominated',
        relatedIssues: [issue],
        isFullMode: true,
      );

      final json = original.toJson();
      final restored = FrameVerdict.fromJson(json);

      expect(restored.frameNumber, 10);
      expect(restored.totalFrameTime.inMicroseconds, 20000);
      expect(restored.uiThreadTime.inMicroseconds, 15000);
      expect(restored.rasterThreadTime.inMicroseconds, 5000);
      expect(restored.buildScopeTime!.inMicroseconds, 10000);
      expect(restored.flushLayoutTime!.inMicroseconds, 3000);
      expect(restored.flushPaintTime!.inMicroseconds, 2000);
      expect(restored.suspectedPhase, PipelinePhase.build);
      expect(restored.reason, 'Build dominated');
      expect(restored.relatedIssues, hasLength(1));
      expect(restored.relatedIssues.first.title, 'Issue');
      expect(restored.totalSpan!.inMicroseconds, 26000);
      expect(restored.buildToRasterGapTime!.inMicroseconds, 4000);
      expect(restored.isFullMode, isTrue);
    });

    test('roundtrip with correlationCoverage and isCorrelated', () {
      final original = FrameVerdict(
        frameNumber: 10,
        totalFrameTime: const Duration(microseconds: 20000),
        uiThreadTime: const Duration(microseconds: 15000),
        rasterThreadTime: const Duration(microseconds: 5000),
        buildScopeTime: const Duration(microseconds: 10000),
        suspectedPhase: PipelinePhase.build,
        reason: 'Correlated',
        isFullMode: true,
        isCorrelated: true,
        correlationCoverage: 0.75,
      );

      final json = original.toJson();
      expect(json['isCorrelated'], isTrue);
      expect(json['correlationCoverage'], 0.75);

      final restored = FrameVerdict.fromJson(json);
      expect(restored.isCorrelated, isTrue);
      expect(restored.correlationCoverage, 0.75);
    });

    test('isCorrelated defaults to false when absent from JSON', () {
      final json = {
        'frameNumber': 1,
        'totalFrameTimeUs': 20000,
        'uiThreadTimeUs': 15000,
        'rasterThreadTimeUs': 5000,
        'suspectedPhase': 'build',
        'reason': 'Test',
      };

      final restored = FrameVerdict.fromJson(json);
      expect(restored.isCorrelated, isFalse);
      expect(restored.correlationCoverage, isNull);
    });

    test('correlationCoverage omitted from JSON when null', () {
      const verdict = FrameVerdict(
        frameNumber: 1,
        totalFrameTime: Duration(microseconds: 20000),
        uiThreadTime: Duration(microseconds: 15000),
        rasterThreadTime: Duration(microseconds: 5000),
        suspectedPhase: PipelinePhase.build,
        reason: 'Test',
      );

      final json = verdict.toJson();
      expect(json.containsKey('correlationCoverage'), isFalse);
      expect(json['isCorrelated'], isFalse);
    });

    test('nullable VM durations omitted in basic mode', () {
      const verdict = FrameVerdict(
        frameNumber: 1,
        totalFrameTime: Duration(microseconds: 20000),
        uiThreadTime: Duration(microseconds: 15000),
        rasterThreadTime: Duration(microseconds: 5000),
        suspectedPhase: PipelinePhase.unknown,
        reason: 'Basic mode',
      );

      final json = verdict.toJson();
      expect(json.containsKey('buildScopeTimeUs'), isFalse);
      expect(json.containsKey('flushLayoutTimeUs'), isFalse);
      expect(json.containsKey('flushPaintTimeUs'), isFalse);
      expect(json.containsKey('totalSpanUs'), isFalse);
      expect(json.containsKey('buildToRasterGapTimeUs'), isFalse);

      final restored = FrameVerdict.fromJson(json);
      expect(restored.buildScopeTime, isNull);
      expect(restored.flushLayoutTime, isNull);
      expect(restored.flushPaintTime, isNull);
      expect(restored.isFullMode, isFalse);
    });
  });

  group('CaptureEntry serialization', () {
    test('asymmetric roundtrip strips verdict.relatedIssues', () {
      const issue = PerformanceIssue(
        severity: IssueSeverity.critical,
        category: IssueCategory.build,
        confidence: IssueConfidence.confirmed,
        title: 'Stamped issue',
        detail: 'D',
        fixHint: 'F',
        routeName: '/home',
        interactionContext: InteractionContext.scrolling,
      );

      const unstampedIssue = PerformanceIssue(
        severity: IssueSeverity.critical,
        category: IssueCategory.build,
        confidence: IssueConfidence.confirmed,
        title: 'Unstamped',
        detail: 'D',
        fixHint: 'F',
      );

      final entry = CaptureEntry(
        frameStats: FrameStats(
          frameNumber: 5,
          uiDuration: const Duration(microseconds: 20000),
          rasterDuration: const Duration(microseconds: 5000),
          timestamp: DateTime.utc(2026, 3, 26),
        ),
        verdict: const FrameVerdict(
          frameNumber: 5,
          totalFrameTime: Duration(microseconds: 20000),
          uiThreadTime: Duration(microseconds: 15000),
          rasterThreadTime: Duration(microseconds: 5000),
          suspectedPhase: PipelinePhase.build,
          reason: 'Build dominated',
          relatedIssues: [unstampedIssue],
        ),
        relatedIssues: [issue],
        capturedAt: DateTime.utc(2026, 3, 26, 12, 0, 0),
      );

      final json = entry.toJson();

      // Verify verdict.relatedIssues is stripped from JSON
      final verdictJson = json['verdict'] as Map<String, dynamic>;
      expect(verdictJson.containsKey('relatedIssues'), isFalse);

      // Verify stamped relatedIssues at CaptureEntry level
      final issuesList = json['relatedIssues'] as List;
      expect(issuesList, hasLength(1));
      expect((issuesList[0] as Map)['routeName'], '/home');

      // Roundtrip: verdict.relatedIssues is empty after deserialization
      final restored = CaptureEntry.fromJson(json);
      expect(restored.verdict.relatedIssues, isEmpty);
      expect(restored.relatedIssues, hasLength(1));
      expect(restored.relatedIssues.first.routeName, '/home');

      // Verdict timing/phase data survives roundtrip
      expect(restored.verdict.frameNumber, 5);
      expect(restored.verdict.suspectedPhase, PipelinePhase.build);
      expect(restored.verdict.reason, 'Build dominated');
    });
  });

  group('FrameStatsSummary serialization', () {
    test('roundtrip', () {
      const original = FrameStatsSummary(
        totalFrames: 60,
        jankFrames: 5,
        averageFps: 58.3,
        worstFrameTimeUs: 45000,
      );

      final json = original.toJson();
      final restored = FrameStatsSummary.fromJson(json);

      expect(restored.totalFrames, 60);
      expect(restored.jankFrames, 5);
      expect(restored.averageFps, 58.3);
      expect(restored.worstFrameTimeUs, 45000);
    });
  });

  group('SessionSnapshot serialization', () {
    test('roundtrip with entries and issues', () {
      final entry = CaptureEntry(
        frameStats: FrameStats(
          frameNumber: 1,
          uiDuration: const Duration(microseconds: 20000),
          rasterDuration: const Duration(microseconds: 5000),
          timestamp: DateTime.utc(2026, 3, 26),
        ),
        verdict: const FrameVerdict(
          frameNumber: 1,
          totalFrameTime: Duration(microseconds: 20000),
          uiThreadTime: Duration(microseconds: 15000),
          rasterThreadTime: Duration(microseconds: 5000),
          suspectedPhase: PipelinePhase.build,
          reason: 'Build dominated',
        ),
        relatedIssues: const [],
        capturedAt: DateTime.utc(2026, 3, 26, 12, 0, 0),
      );

      const issue = PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.layout,
        confidence: IssueConfidence.possible,
        title: 'Intrinsic',
        detail: 'D',
        fixHint: 'F',
      );

      final snapshot = SessionSnapshot(
        exportedAt: DateTime.utc(2026, 3, 26, 12, 0, 0),
        capturedFrames: [entry],
        currentIssues: [issue],
        frameStatsSummary: const FrameStatsSummary(
          totalFrames: 60,
          jankFrames: 3,
          averageFps: 59.0,
          worstFrameTimeUs: 20000,
        ),
        packageVersion: '0.2.0',
        isVmConnected: true,
        isDebugMode: false,
      );

      final restored = SessionSnapshot.fromJson(snapshot.toJson());

      expect(restored.exportedAt, snapshot.exportedAt);
      expect(restored.packageVersion, '0.2.0');
      expect(restored.isVmConnected, isTrue);
      expect(restored.isDebugMode, isFalse);
      expect(restored.capturedFrames, hasLength(1));
      expect(restored.currentIssues, hasLength(1));
      expect(restored.frameStatsSummary.totalFrames, 60);
    });

    test('toJsonString produces valid decodable JSON', () {
      final snapshot = SessionSnapshot(
        exportedAt: DateTime.utc(2026),
        capturedFrames: const [],
        currentIssues: const [],
        frameStatsSummary: const FrameStatsSummary(
          totalFrames: 0,
          jankFrames: 0,
          averageFps: 0,
          worstFrameTimeUs: 0,
        ),
      );

      final jsonStr = snapshot.toJsonString();
      expect(() => jsonDecode(jsonStr), returnsNormally);
      expect(jsonStr, contains('\n')); // pretty-printed
    });
  });
}
