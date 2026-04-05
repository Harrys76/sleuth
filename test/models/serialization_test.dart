import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/sleuth.dart';

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
        fixEffort: FixEffort.quick,
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
      expect(restored.fixEffort, original.fixEffort);
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
      expect(json.containsKey('fixEffort'), isFalse);
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
      expect(issue.fixEffort, isNull);
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

    test('fixEffort serializes as .name string', () {
      const issue = PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.build,
        confidence: IssueConfidence.possible,
        title: 'T',
        detail: 'D',
        fixHint: 'F',
        fixEffort: FixEffort.involved,
      );

      final json = issue.toJson();
      expect(json['fixEffort'], 'involved');
    });

    test('toJson includes topAllocators when non-null', () {
      const issue = PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.memory,
        confidence: IssueConfidence.likely,
        title: 'Heap Growing',
        detail: 'D',
        fixHint: 'F',
        topAllocators: [
          AllocationEntry(
            className: 'MyWidget',
            libraryUri: 'package:app/w.dart',
            instancesDelta: 100,
            bytesDelta: 50000,
            percentage: 35.0,
          ),
        ],
      );

      final json = issue.toJson();
      expect(json.containsKey('topAllocators'), isTrue);
      final allocators = json['topAllocators'] as List;
      expect(allocators, hasLength(1));
      expect((allocators[0] as Map)['className'], 'MyWidget');
    });

    test('fromJson restores topAllocators', () {
      final json = {
        'severity': 'warning',
        'category': 'memory',
        'confidence': 'likely',
        'title': 'Heap Growing',
        'detail': 'D',
        'fixHint': 'F',
        'debugModeDisclaimer': false,
        'topAllocators': [
          {
            'className': 'Item',
            'libraryUri': 'package:app/item.dart',
            'instancesDelta': 200,
            'bytesDelta': 80000,
            'percentage': 60.0,
          },
        ],
      };

      final issue = PerformanceIssue.fromJson(json);
      expect(issue.topAllocators, isNotNull);
      expect(issue.topAllocators, hasLength(1));
      expect(issue.topAllocators![0].className, 'Item');
      expect(issue.topAllocators![0].bytesDelta, 80000);
      expect(issue.topAllocators![0].percentage, 60.0);
    });

    test('fromJson defaults topAllocators to null when missing', () {
      final json = {
        'severity': 'warning',
        'category': 'memory',
        'confidence': 'likely',
        'title': 'T',
        'detail': 'D',
        'fixHint': 'F',
        'debugModeDisclaimer': false,
      };

      final issue = PerformanceIssue.fromJson(json);
      expect(issue.topAllocators, isNull);
    });

    test('copyWith preserves topAllocators', () {
      const allocators = [
        AllocationEntry(
          className: 'A',
          libraryUri: '',
          instancesDelta: 10,
          bytesDelta: 1024,
          percentage: 50.0,
        ),
      ];

      const issue = PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.memory,
        confidence: IssueConfidence.likely,
        title: 'T',
        detail: 'D',
        fixHint: 'F',
      );

      final enriched = issue.copyWith(topAllocators: allocators);
      expect(enriched.topAllocators, hasLength(1));
      expect(enriched.topAllocators![0].className, 'A');

      // copyWith without topAllocators preserves existing value
      final updated = enriched.copyWith(title: 'Updated');
      expect(updated.topAllocators, hasLength(1));
      expect(updated.title, 'Updated');
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
      expect(stats.layerCacheBytes, 0);
      expect(stats.pictureCacheCount, 0);
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

    test('pictureCacheCount and layerCacheBytes included in toJson', () {
      final stats = FrameStats(
        frameNumber: 1,
        uiDuration: const Duration(microseconds: 1000),
        rasterDuration: const Duration(microseconds: 2000),
        timestamp: DateTime.utc(2026),
        pictureCacheCount: 12,
        layerCacheBytes: 204800,
      );

      final json = stats.toJson();
      expect(json['pictureCacheCount'], 12);
      expect(json['layerCacheBytes'], 204800);
    });

    test('pictureCacheCount and layerCacheBytes restored by fromJson', () {
      final original = FrameStats(
        frameNumber: 1,
        uiDuration: const Duration(microseconds: 1000),
        rasterDuration: const Duration(microseconds: 2000),
        timestamp: DateTime.utc(2026),
        pictureCacheCount: 8,
        layerCacheBytes: 102400,
        pictureCacheBytes: 51200,
        layerCacheCount: 3,
      );

      final restored = FrameStats.fromJson(original.toJson());
      expect(restored.pictureCacheCount, 8);
      expect(restored.layerCacheBytes, 102400);
      expect(restored.pictureCacheBytes, 51200);
      expect(restored.layerCacheCount, 3);
    });

    test('totalCacheBytes computes sum of picture and layer bytes', () {
      final stats = FrameStats(
        frameNumber: 1,
        uiDuration: const Duration(microseconds: 1000),
        rasterDuration: const Duration(microseconds: 2000),
        timestamp: DateTime.utc(2026),
        pictureCacheBytes: 30000,
        layerCacheBytes: 20000,
      );

      expect(stats.totalCacheBytes, 50000);
    });

    test('fromJson defaults pictureCacheCount and layerCacheBytes to 0', () {
      final json = {
        'frameNumber': 1,
        'uiDurationUs': 1000,
        'rasterDurationUs': 2000,
        'timestamp': '2026-01-01T00:00:00.000Z',
      };

      final stats = FrameStats.fromJson(json);
      expect(stats.pictureCacheCount, 0);
      expect(stats.layerCacheBytes, 0);
      expect(stats.totalCacheBytes, 0);
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

  group('CaptureEntry verdict with topFunctions', () {
    test('toJson includes topFunctions when verdict has them', () {
      final entry = CaptureEntry(
        frameStats: FrameStats(
          frameNumber: 7,
          uiDuration: const Duration(microseconds: 30000),
          rasterDuration: const Duration(microseconds: 5000),
          timestamp: DateTime.utc(2026, 3, 28),
        ),
        verdict: const FrameVerdict(
          frameNumber: 7,
          totalFrameTime: Duration(microseconds: 30000),
          uiThreadTime: Duration(microseconds: 25000),
          rasterThreadTime: Duration(microseconds: 5000),
          suspectedPhase: PipelinePhase.build,
          reason: 'Build dominant',
          topFunctions: [
            CpuAttribution(
              functionName: 'build',
              className: 'MyWidget',
              libraryUri: 'package:app/w.dart',
              percentage: 42.5,
            ),
          ],
        ),
        relatedIssues: [],
        capturedAt: DateTime.utc(2026, 3, 28, 12, 0, 0),
      );

      final json = entry.toJson();
      final verdictJson = json['verdict'] as Map<String, dynamic>;
      expect(verdictJson.containsKey('topFunctions'), isTrue);
      final topFunctions = verdictJson['topFunctions'] as List;
      expect(topFunctions, hasLength(1));
      expect((topFunctions[0] as Map)['displayName'], 'MyWidget.build');
    });
  });

  group('CaptureEntry fromJson with topFunctions (Gap 5)', () {
    test('fromJson restores topFunctions from verdict JSON', () {
      // This tests the deserialization direction — toJson is tested above.
      final json = {
        'frameStats': {
          'frameNumber': 7,
          'uiDurationUs': 30000,
          'rasterDurationUs': 5000,
          'timestamp': '2026-03-28T00:00:00.000Z',
        },
        'verdict': {
          'frameNumber': 7,
          'totalFrameTimeUs': 30000,
          'uiThreadTimeUs': 25000,
          'rasterThreadTimeUs': 5000,
          'suspectedPhase': 'build',
          'reason': 'Build dominant',
          'topFunctions': [
            {
              'functionName': 'build',
              'className': 'MyWidget',
              'libraryUri': 'package:app/w.dart',
              'percentage': 42.5,
              'displayName': 'MyWidget.build',
            },
            {
              'functionName': 'layout',
              'className': 'RenderFlex',
              'libraryUri': 'package:flutter/rendering.dart',
              'percentage': 15.3,
              'displayName': 'RenderFlex.layout',
            },
          ],
        },
        'relatedIssues': <dynamic>[],
        'capturedAt': '2026-03-28T12:00:00.000Z',
      };

      final entry = CaptureEntry.fromJson(json);
      expect(entry.verdict.topFunctions, isNotNull);
      expect(entry.verdict.topFunctions, hasLength(2));
      expect(entry.verdict.topFunctions![0].functionName, 'build');
      expect(entry.verdict.topFunctions![0].className, 'MyWidget');
      expect(entry.verdict.topFunctions![0].percentage, 42.5);
      expect(entry.verdict.topFunctions![0].displayName, 'MyWidget.build');
      expect(entry.verdict.topFunctions![1].functionName, 'layout');
      expect(entry.verdict.topFunctions![1].percentage, 15.3);
    });

    test('fromJson handles absent topFunctions (null)', () {
      final json = {
        'frameStats': {
          'frameNumber': 1,
          'uiDurationUs': 20000,
          'rasterDurationUs': 5000,
          'timestamp': '2026-03-28T00:00:00.000Z',
        },
        'verdict': {
          'frameNumber': 1,
          'totalFrameTimeUs': 20000,
          'uiThreadTimeUs': 15000,
          'rasterThreadTimeUs': 5000,
          'suspectedPhase': 'build',
          'reason': 'Test',
        },
        'relatedIssues': <dynamic>[],
        'capturedAt': '2026-03-28T12:00:00.000Z',
      };

      final entry = CaptureEntry.fromJson(json);
      expect(entry.verdict.topFunctions, isNull);
    });

    test('full roundtrip: toJson → fromJson preserves topFunctions', () {
      final entry = CaptureEntry(
        frameStats: FrameStats(
          frameNumber: 10,
          uiDuration: const Duration(microseconds: 30000),
          rasterDuration: const Duration(microseconds: 5000),
          timestamp: DateTime.utc(2026, 3, 28),
        ),
        verdict: const FrameVerdict(
          frameNumber: 10,
          totalFrameTime: Duration(microseconds: 30000),
          uiThreadTime: Duration(microseconds: 25000),
          rasterThreadTime: Duration(microseconds: 5000),
          suspectedPhase: PipelinePhase.build,
          reason: 'Build dominant',
          topFunctions: [
            CpuAttribution(
              functionName: 'build',
              className: 'ExpensiveWidget',
              libraryUri: 'package:app/expensive.dart',
              percentage: 67.2,
            ),
          ],
        ),
        relatedIssues: const [],
        capturedAt: DateTime.utc(2026, 3, 28, 12, 0, 0),
      );

      final json = entry.toJson();
      final restored = CaptureEntry.fromJson(json);

      expect(restored.verdict.topFunctions, isNotNull);
      expect(restored.verdict.topFunctions, hasLength(1));
      expect(restored.verdict.topFunctions![0].className, 'ExpensiveWidget');
      expect(restored.verdict.topFunctions![0].functionName, 'build');
      expect(restored.verdict.topFunctions![0].percentage, 67.2);
      expect(
        restored.verdict.topFunctions![0].libraryUri,
        'package:app/expensive.dart',
      );
    });
  });

  group('CpuAttribution call chain serialization', () {
    test('toJson includes callChain and inclusivePercentage when non-null', () {
      const attr = CpuAttribution(
        functionName: 'layout',
        className: 'RenderFlex',
        libraryUri: 'package:flutter/rendering.dart',
        percentage: 42.0,
        callChain: ['MyWidget.build', 'performLayout', 'RenderFlex.layout'],
        inclusivePercentage: 58.3,
      );

      final json = attr.toJson();
      expect(json['callChain'],
          ['MyWidget.build', 'performLayout', 'RenderFlex.layout']);
      expect(json['inclusivePercentage'], 58.3);
    });

    test('toJson omits callChain and inclusivePercentage when null', () {
      const attr = CpuAttribution(
        functionName: 'build',
        className: 'MyWidget',
        libraryUri: 'package:app/w.dart',
        percentage: 30.0,
      );

      final json = attr.toJson();
      expect(json.containsKey('callChain'), isFalse);
      expect(json.containsKey('inclusivePercentage'), isFalse);
    });

    test('fromJson restores callChain and inclusivePercentage', () {
      final json = {
        'functionName': 'layout',
        'className': 'RenderFlex',
        'libraryUri': 'package:flutter/rendering.dart',
        'percentage': 42.0,
        'callChain': ['MyWidget.build', 'performLayout', 'RenderFlex.layout'],
        'inclusivePercentage': 58.3,
      };

      final attr = CpuAttribution.fromJson(json);
      expect(attr.callChain, hasLength(3));
      expect(attr.callChain![0], 'MyWidget.build');
      expect(attr.callChain![2], 'RenderFlex.layout');
      expect(attr.inclusivePercentage, 58.3);
    });

    test('fromJson defaults to null when fields missing', () {
      final json = {
        'functionName': 'build',
        'className': 'MyWidget',
        'libraryUri': 'package:app/w.dart',
        'percentage': 30.0,
      };

      final attr = CpuAttribution.fromJson(json);
      expect(attr.callChain, isNull);
      expect(attr.inclusivePercentage, isNull);
    });

    test('chainDisplay computed property', () {
      const withChain = CpuAttribution(
        functionName: 'layout',
        className: '',
        libraryUri: '',
        percentage: 10.0,
        callChain: ['MyWidget.build', 'performLayout', 'layout'],
      );
      expect(withChain.chainDisplay, 'MyWidget.build → performLayout → layout');

      const withoutChain = CpuAttribution(
        functionName: 'build',
        className: '',
        libraryUri: '',
        percentage: 10.0,
      );
      expect(withoutChain.chainDisplay, isNull);

      const emptyChain = CpuAttribution(
        functionName: 'build',
        className: '',
        libraryUri: '',
        percentage: 10.0,
        callChain: [],
      );
      expect(emptyChain.chainDisplay, isNull);
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

    test('toJson includes heapSamples when non-null and non-empty', () {
      final snapshot = SessionSnapshot(
        exportedAt: DateTime.utc(2026, 3, 28),
        capturedFrames: const [],
        currentIssues: const [],
        frameStatsSummary: const FrameStatsSummary(
          totalFrames: 0,
          jankFrames: 0,
          averageFps: 0,
          worstFrameTimeUs: 0,
        ),
        heapSamples: [
          HeapSample(
            heapUsage: 50000000,
            heapCapacity: 100000000,
            externalUsage: 0,
            timestamp: DateTime.utc(2026, 3, 28, 12, 0, 0),
          ),
        ],
      );

      final json = snapshot.toJson();
      expect(json.containsKey('heapSamples'), isTrue);
      expect((json['heapSamples'] as List), hasLength(1));
    });

    test('toJson omits heapSamples when null', () {
      final snapshot = SessionSnapshot(
        exportedAt: DateTime.utc(2026, 3, 28),
        capturedFrames: const [],
        currentIssues: const [],
        frameStatsSummary: const FrameStatsSummary(
          totalFrames: 0,
          jankFrames: 0,
          averageFps: 0,
          worstFrameTimeUs: 0,
        ),
      );

      final json = snapshot.toJson();
      expect(json.containsKey('heapSamples'), isFalse);
    });
  });

  group('PhaseEvent serialization', () {
    test('roundtrip with all fields populated', () {
      const original = PhaseEvent(
        phase: TimelinePhase.build,
        timestampUs: 100000,
        durationUs: 5000,
        dirtyCount: 12,
        dirtyList: ['MyWidget', 'OtherWidget'],
        scopeContext: 'MyApp(dirty)',
      );

      final json = original.toJson();
      final restored = PhaseEvent.fromJson(json);

      expect(restored.phase, TimelinePhase.build);
      expect(restored.timestampUs, 100000);
      expect(restored.durationUs, 5000);
      expect(restored.dirtyCount, 12);
      expect(restored.dirtyList, ['MyWidget', 'OtherWidget']);
      expect(restored.scopeContext, 'MyApp(dirty)');
    });

    test('nullable fields omitted when null', () {
      const event = PhaseEvent(
        phase: TimelinePhase.raster,
        timestampUs: 200000,
        durationUs: 3000,
      );

      final json = event.toJson();
      expect(json.containsKey('dirtyCount'), isFalse);
      expect(json.containsKey('dirtyList'), isFalse);
      expect(json.containsKey('scopeContext'), isFalse);
    });

    test('fromJson handles absent nullable fields', () {
      final json = {
        'phase': 'paint',
        'timestampUs': 300000,
        'durationUs': 1000,
      };

      final event = PhaseEvent.fromJson(json);
      expect(event.phase, TimelinePhase.paint);
      expect(event.dirtyCount, isNull);
      expect(event.dirtyList, isNull);
      expect(event.scopeContext, isNull);
    });

    test('phase serializes as .name string', () {
      const event = PhaseEvent(
        phase: TimelinePhase.shader,
        timestampUs: 0,
        durationUs: 0,
      );

      final json = event.toJson();
      expect(json['phase'], 'shader');
    });
  });

  group('GcEventSummary serialization', () {
    test('roundtrip preserves all fields', () {
      const original = GcEventSummary(
        timestampUs: 500000,
        durationUs: 2000,
        category: 'GC',
        name: 'CollectNewGeneration',
      );

      final json = original.toJson();
      final restored = GcEventSummary.fromJson(json);

      expect(restored.timestampUs, 500000);
      expect(restored.durationUs, 2000);
      expect(restored.category, 'GC');
      expect(restored.name, 'CollectNewGeneration');
    });
  });

  group('PlatformChannelSummary serialization', () {
    test('roundtrip preserves all fields', () {
      const original = PlatformChannelSummary(
        timestampUs: 600000,
        durationUs: 1500,
        name: 'flutter/platform',
      );

      final json = original.toJson();
      final restored = PlatformChannelSummary.fromJson(json);

      expect(restored.timestampUs, 600000);
      expect(restored.durationUs, 1500);
      expect(restored.name, 'flutter/platform');
    });
  });

  group('FpsPercentiles serialization', () {
    test('roundtrip preserves values with 1 decimal precision', () {
      const original = FpsPercentiles(p50: 59.3, p95: 45.7, p99: 30.1);

      final json = original.toJson();
      final restored = FpsPercentiles.fromJson(json);

      expect(restored.p50, 59.3);
      expect(restored.p95, 45.7);
      expect(restored.p99, 30.1);
    });
  });

  group('PerformanceIssue ranking fields', () {
    test('roundtrip with rankingScore and rankingBreakdown', () {
      const original = PerformanceIssue(
        severity: IssueSeverity.critical,
        category: IssueCategory.build,
        confidence: IssueConfidence.confirmed,
        title: 'Heavy build',
        detail: 'D',
        fixHint: 'F',
        rankingScore: 339,
        rankingBreakdown: {
          'severity': 300,
          'frameImpact': 24,
          'confidence': 15,
          'recurrence': 0,
        },
      );

      final json = original.toJson();
      expect(json['rankingScore'], 339);
      expect(json['rankingBreakdown'], {
        'severity': 300,
        'frameImpact': 24,
        'confidence': 15,
        'recurrence': 0,
      });

      final restored = PerformanceIssue.fromJson(json);
      expect(restored.rankingScore, 339);
      expect(restored.rankingBreakdown!['severity'], 300);
      expect(restored.rankingBreakdown!['frameImpact'], 24);
    });

    test('ranking fields omitted when null', () {
      const issue = PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.layout,
        confidence: IssueConfidence.possible,
        title: 'T',
        detail: 'D',
        fixHint: 'F',
      );

      final json = issue.toJson();
      expect(json.containsKey('rankingScore'), isFalse);
      expect(json.containsKey('rankingBreakdown'), isFalse);
    });

    test('fromJson defaults ranking fields to null (v1 compat)', () {
      final json = {
        'severity': 'warning',
        'category': 'layout',
        'confidence': 'possible',
        'title': 'T',
        'detail': 'D',
        'fixHint': 'F',
        'debugModeDisclaimer': false,
      };

      final issue = PerformanceIssue.fromJson(json);
      expect(issue.rankingScore, isNull);
      expect(issue.rankingBreakdown, isNull);
    });

    test('copyWith preserves ranking fields', () {
      const issue = PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.build,
        confidence: IssueConfidence.likely,
        title: 'T',
        detail: 'D',
        fixHint: 'F',
        rankingScore: 215,
        rankingBreakdown: {
          'severity': 200,
          'confidence': 10,
          'frameImpact': 0,
          'recurrence': 5
        },
      );

      final updated = issue.copyWith(title: 'Updated');
      expect(updated.rankingScore, 215);
      expect(updated.rankingBreakdown!['severity'], 200);
      expect(updated.title, 'Updated');
    });
  });

  group('FrameStatsSummary with fpsPercentiles', () {
    test('roundtrip with fpsPercentiles populated', () {
      const original = FrameStatsSummary(
        totalFrames: 100,
        jankFrames: 5,
        averageFps: 58.3,
        worstFrameTimeUs: 45000,
        fpsPercentiles: FpsPercentiles(p50: 59.1, p95: 42.5, p99: 28.3),
      );

      final json = original.toJson();
      expect(json.containsKey('fpsPercentiles'), isTrue);

      final restored = FrameStatsSummary.fromJson(json);
      expect(restored.fpsPercentiles, isNotNull);
      expect(restored.fpsPercentiles!.p50, 59.1);
      expect(restored.fpsPercentiles!.p95, 42.5);
      expect(restored.fpsPercentiles!.p99, 28.3);
    });

    test('fromJson defaults fpsPercentiles to null (v1 compat)', () {
      final json = {
        'totalFrames': 50,
        'jankFrames': 2,
        'averageFps': 60.0,
        'worstFrameTimeUs': 20000,
      };

      final summary = FrameStatsSummary.fromJson(json);
      expect(summary.fpsPercentiles, isNull);
    });
  });

  group('SessionSnapshot v2 fields', () {
    test('schemaVersion defaults to 2 for new snapshots', () {
      final snapshot = SessionSnapshot(
        exportedAt: DateTime.utc(2026, 3, 30),
        capturedFrames: const [],
        currentIssues: const [],
        frameStatsSummary: const FrameStatsSummary(
          totalFrames: 0,
          jankFrames: 0,
          averageFps: 0,
          worstFrameTimeUs: 0,
        ),
      );

      expect(snapshot.schemaVersion, 2);
      expect(snapshot.toJson()['schemaVersion'], 2);
    });

    test('fromJson without schemaVersion defaults to 1', () {
      final json = {
        'exportedAt': '2026-03-30T00:00:00.000Z',
        'capturedFrames': <dynamic>[],
        'currentIssues': <dynamic>[],
        'frameStatsSummary': {
          'totalFrames': 0,
          'jankFrames': 0,
          'averageFps': 0.0,
          'worstFrameTimeUs': 0,
        },
      };

      final snapshot = SessionSnapshot.fromJson(json);
      expect(snapshot.schemaVersion, 1);
    });

    test('roundtrip with all v2 fields', () {
      final snapshot = SessionSnapshot(
        exportedAt: DateTime.utc(2026, 3, 30),
        capturedFrames: const [],
        currentIssues: const [],
        frameStatsSummary: const FrameStatsSummary(
          totalFrames: 60,
          jankFrames: 3,
          averageFps: 58.5,
          worstFrameTimeUs: 30000,
          fpsPercentiles: FpsPercentiles(p50: 59.0, p95: 45.0, p99: 30.0),
        ),
        phaseEvents: const [
          PhaseEvent(
            phase: TimelinePhase.build,
            timestampUs: 100000,
            durationUs: 5000,
            dirtyCount: 3,
          ),
        ],
        gcEvents: const [
          GcEventSummary(
            timestampUs: 200000,
            durationUs: 1500,
            category: 'GC',
            name: 'CollectNewGeneration',
          ),
        ],
        platformChannelEvents: const [
          PlatformChannelSummary(
            timestampUs: 300000,
            durationUs: 800,
            name: 'flutter/platform',
          ),
        ],
        recentFrames: [
          FrameStats(
            frameNumber: 1,
            uiDuration: const Duration(microseconds: 8000),
            rasterDuration: const Duration(microseconds: 4000),
            timestamp: DateTime.utc(2026, 3, 30),
          ),
        ],
      );

      final json = snapshot.toJson();
      expect(json['schemaVersion'], 2);
      expect(json.containsKey('phaseEvents'), isTrue);
      expect(json.containsKey('gcEvents'), isTrue);
      expect(json.containsKey('platformChannelEvents'), isTrue);
      expect(json.containsKey('recentFrames'), isTrue);

      final restored = SessionSnapshot.fromJson(json);
      expect(restored.schemaVersion, 2);
      expect(restored.phaseEvents, hasLength(1));
      expect(restored.phaseEvents![0].phase, TimelinePhase.build);
      expect(restored.gcEvents, hasLength(1));
      expect(restored.gcEvents![0].name, 'CollectNewGeneration');
      expect(restored.platformChannelEvents, hasLength(1));
      expect(restored.platformChannelEvents![0].name, 'flutter/platform');
      expect(restored.recentFrames, hasLength(1));
      expect(restored.recentFrames![0].frameNumber, 1);
    });

    test('v2 fromJson with new fields absent (all nullable)', () {
      final json = {
        'schemaVersion': 2,
        'exportedAt': '2026-03-30T00:00:00.000Z',
        'capturedFrames': <dynamic>[],
        'currentIssues': <dynamic>[],
        'frameStatsSummary': {
          'totalFrames': 0,
          'jankFrames': 0,
          'averageFps': 0.0,
          'worstFrameTimeUs': 0,
        },
      };

      final snapshot = SessionSnapshot.fromJson(json);
      expect(snapshot.schemaVersion, 2);
      expect(snapshot.phaseEvents, isNull);
      expect(snapshot.gcEvents, isNull);
      expect(snapshot.platformChannelEvents, isNull);
      expect(snapshot.recentFrames, isNull);
    });

    test('toJson omits new list fields when null', () {
      final snapshot = SessionSnapshot(
        exportedAt: DateTime.utc(2026, 3, 30),
        capturedFrames: const [],
        currentIssues: const [],
        frameStatsSummary: const FrameStatsSummary(
          totalFrames: 0,
          jankFrames: 0,
          averageFps: 0,
          worstFrameTimeUs: 0,
        ),
      );

      final json = snapshot.toJson();
      expect(json.containsKey('phaseEvents'), isFalse);
      expect(json.containsKey('gcEvents'), isFalse);
      expect(json.containsKey('platformChannelEvents'), isFalse);
      expect(json.containsKey('recentFrames'), isFalse);
    });

    test('JSON string roundtrip preserves v2 schema', () {
      final snapshot = SessionSnapshot(
        exportedAt: DateTime.utc(2026, 3, 30),
        capturedFrames: const [],
        currentIssues: const [],
        frameStatsSummary: const FrameStatsSummary(
          totalFrames: 10,
          jankFrames: 1,
          averageFps: 59.0,
          worstFrameTimeUs: 20000,
        ),
        phaseEvents: const [
          PhaseEvent(
              phase: TimelinePhase.layout, timestampUs: 0, durationUs: 100),
        ],
      );

      final jsonString = snapshot.toJsonString();
      final decoded = jsonDecode(jsonString) as Map<String, dynamic>;
      final restored = SessionSnapshot.fromJson(decoded);

      expect(restored.schemaVersion, 2);
      expect(restored.phaseEvents, hasLength(1));
    });
  });

  group('PerformanceIssue causal graph fields', () {
    test('roundtrip with rootCauseId and downstreamIds', () {
      const root = PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.build,
        confidence: IssueConfidence.likely,
        title: 'Wide setState scope',
        detail: 'D',
        fixHint: 'F',
        stableId: 'setstate_scope',
        downstreamIds: ['heavy_compute', 'layout_bottleneck'],
      );

      final json = root.toJson();
      expect(json['downstreamIds'], ['heavy_compute', 'layout_bottleneck']);
      expect(json.containsKey('rootCauseId'), isFalse);

      final restored = PerformanceIssue.fromJson(json);
      expect(restored.downstreamIds, ['heavy_compute', 'layout_bottleneck']);
      expect(restored.rootCauseId, isNull);
    });

    test('roundtrip with rootCauseId set', () {
      const downstream = PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.build,
        confidence: IssueConfidence.possible,
        title: 'Heavy compute',
        detail: 'D',
        fixHint: 'F',
        stableId: 'heavy_compute',
        rootCauseId: 'setstate_scope',
      );

      final json = downstream.toJson();
      expect(json['rootCauseId'], 'setstate_scope');
      expect(json.containsKey('downstreamIds'), isFalse);

      final restored = PerformanceIssue.fromJson(json);
      expect(restored.rootCauseId, 'setstate_scope');
      expect(restored.downstreamIds, isNull);
    });

    test('causal fields omitted when null', () {
      const issue = PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.layout,
        confidence: IssueConfidence.possible,
        title: 'T',
        detail: 'D',
        fixHint: 'F',
      );

      final json = issue.toJson();
      expect(json.containsKey('rootCauseId'), isFalse);
      expect(json.containsKey('downstreamIds'), isFalse);
    });

    test('fromJson defaults causal fields to null (v1 compat)', () {
      final json = {
        'severity': 'warning',
        'category': 'layout',
        'confidence': 'possible',
        'title': 'T',
        'detail': 'D',
        'fixHint': 'F',
        'debugModeDisclaimer': false,
      };

      final issue = PerformanceIssue.fromJson(json);
      expect(issue.rootCauseId, isNull);
      expect(issue.downstreamIds, isNull);
    });

    test('copyWith preserves causal fields', () {
      const issue = PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.build,
        confidence: IssueConfidence.likely,
        title: 'T',
        detail: 'D',
        fixHint: 'F',
        downstreamIds: ['heavy_compute'],
      );

      final updated = issue.copyWith(title: 'Updated');
      expect(updated.downstreamIds, ['heavy_compute']);
      expect(updated.title, 'Updated');
    });
  });
}
