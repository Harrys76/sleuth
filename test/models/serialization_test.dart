import 'dart:convert';
import 'dart:io';

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

    test('v4 fromJson — actualFps and throughputFps backfill from averageFps',
        () {
      // v4 snapshot: only averageFps is present. New reader must synthesize
      // actualFps and throughputFps from that single field so no v4 export
      // comes back with NaN or a silent zero.
      final v4Json = {
        'totalFrames': 60,
        'jankFrames': 5,
        'averageFps': 58.3,
        'worstFrameTimeUs': 45000,
      };
      final restored = FrameStatsSummary.fromJson(v4Json);
      expect(restored.averageFps, 58.3);
      expect(restored.actualFps, 58.3);
      expect(restored.throughputFps, 58.3);
      expect(restored.actualFpsRaw, 58.3);
    });

    test('v5 round-trip preserves all three FPS fields', () {
      const original = FrameStatsSummary(
        totalFrames: 120,
        jankFrames: 2,
        averageFps: 60.0,
        actualFps: 58.0,
        actualFpsRaw: 117.0,
        throughputFps: 60.0,
        worstFrameTimeUs: 33000,
      );
      final restored = FrameStatsSummary.fromJson(original.toJson());
      expect(restored.actualFps, 58.0);
      expect(restored.actualFpsRaw, 117.0);
      expect(restored.throughputFps, 60.0);
      expect(restored.averageFps, 60.0);
    });

    test('v5→v4 reader simulation — stripped v5 keys still parse', () {
      // Simulate an old (v4) consumer reading a v5 snapshot: the v5-only
      // keys are stripped from the payload but averageFps remains. The
      // backfill chain must make the result look like a v4 object.
      const v5 = FrameStatsSummary(
        totalFrames: 60,
        jankFrames: 0,
        averageFps: 60.0,
        actualFps: 58.0,
        actualFpsRaw: 120.0,
        throughputFps: 60.0,
        worstFrameTimeUs: 16000,
      );
      final v5Json = v5.toJson();
      v5Json.remove('actualFps');
      v5Json.remove('actualFpsRaw');
      v5Json.remove('throughputFps');
      final restored = FrameStatsSummary.fromJson(v5Json);
      expect(restored.averageFps, 60.0);
      expect(restored.actualFps, 60.0);
      expect(restored.actualFpsRaw, 60.0);
      expect(restored.throughputFps, 60.0);
    });

    test('schemaVersion default is 5', () {
      final snapshot = SessionSnapshot(
        exportedAt: DateTime.utc(2026, 4, 24),
        capturedFrames: const [],
        currentIssues: const [],
        frameStatsSummary: const FrameStatsSummary(
          totalFrames: 0,
          jankFrames: 0,
          averageFps: 0,
          worstFrameTimeUs: 0,
        ),
      );
      expect(snapshot.schemaVersion, 5);
    });

    // Schema-bump gate — any PR that adds a field to FrameStatsSummary or
    // SessionSnapshot without updating the v5 golden fixture fails here.
    // Forces an intentional schema decision instead of silent drift.
    test('v5 golden file gate', () {
      final fixture =
          File('test/models/_fixtures/session_snapshot_v5_golden.json');
      expect(fixture.existsSync(), isTrue,
          reason: 'v5 golden fixture missing — create it alongside any '
              'snapshot field addition');
      final json =
          jsonDecode(fixture.readAsStringSync()) as Map<String, dynamic>;
      final snapshot = SessionSnapshot.fromJson(json);
      expect(snapshot.schemaVersion, 5);
      expect(snapshot.frameStatsSummary.actualFps, 58.0);
      expect(snapshot.frameStatsSummary.actualFpsRaw, 117.0);
      expect(snapshot.frameStatsSummary.throughputFps, 60.0);
      expect(snapshot.frameStatsSummary.averageFps, 60.0);

      // Round-trip — re-serialize and require the re-emitted FrameStats
      // summary to match the golden byte-for-byte. Value equality (not
      // just key-set equality) catches both new-field additions AND
      // silent value drift (e.g. a rounding regression flipping
      // actualFps <-> throughputFps). Rounding in `toJson` is
      // deterministic (one decimal) so this comparison is stable.
      final roundTripped = snapshot.toJson();
      final summary = roundTripped['frameStatsSummary'] as Map<String, dynamic>;
      final goldenSummary = json['frameStatsSummary'] as Map<String, dynamic>;
      expect(summary, equals(goldenSummary),
          reason: 'FrameStatsSummary.toJson drifted from the v5 golden — '
              'either a new field was added without updating the golden '
              'fixture, or an existing field value changed');
    });

    // v0.17.0 C1 regression: v4 → fromJson → toJson must NOT produce a
    // schemaVersion=4 payload wrapping v5 field shape. Upgrade-on-read
    // normalises schemaVersion to 5 so the declared version matches the
    // actual emitted shape.
    test('v4 JSON → fromJson → toJson normalises schemaVersion to 5', () {
      final v4 = <String, dynamic>{
        'schemaVersion': 4,
        'exportedAt': DateTime.utc(2026, 4, 24).toIso8601String(),
        'packageVersion': '0.16.6',
        'isVmConnected': false,
        'isDebugMode': false,
        'frameStatsSummary': <String, dynamic>{
          'totalFrames': 60,
          'jankFrames': 2,
          'averageFps': 58.3,
          'worstFrameTimeUs': 33000,
        },
        'capturedFrames': <dynamic>[],
        'currentIssues': <dynamic>[],
      };
      final snapshot = SessionSnapshot.fromJson(v4);
      // Upgrade-on-read: in-memory object advertises v5 because toJson
      // will emit v5-shape unconditionally.
      expect(snapshot.schemaVersion, 5);
      final roundTripped = snapshot.toJson();
      expect(roundTripped['schemaVersion'], 5);
      // Re-emitted frameStatsSummary MUST contain every v5 FPS key.
      final summary = roundTripped['frameStatsSummary'] as Map<String, dynamic>;
      expect(summary.containsKey('actualFps'), isTrue);
      expect(summary.containsKey('actualFpsRaw'), isTrue);
      expect(summary.containsKey('throughputFps'), isTrue);
      expect(summary.containsKey('averageFps'), isTrue);
      // v4 averageFps backfills the three new fields at identical value.
      expect(summary['averageFps'], 58.3);
      expect(summary['actualFps'], 58.3);
      expect(summary['actualFpsRaw'], 58.3);
      expect(summary['throughputFps'], 58.3);
    });

    // v3 / v2 / v1 inputs also upgrade on read (no regression for older
    // schemas either — upgrade path is uniform for any schemaVersion < 5).
    test('v3 JSON → fromJson normalises schemaVersion to 5', () {
      final v3 = <String, dynamic>{
        'schemaVersion': 3,
        'exportedAt': DateTime.utc(2026, 4, 24).toIso8601String(),
        'frameStatsSummary': <String, dynamic>{
          'totalFrames': 10,
          'jankFrames': 0,
          'averageFps': 60.0,
          'worstFrameTimeUs': 16000,
        },
        'capturedFrames': <dynamic>[],
        'currentIssues': <dynamic>[],
      };
      final snapshot = SessionSnapshot.fromJson(v3);
      expect(snapshot.schemaVersion, 5);
    });

    // v6+ (hypothetical future schema) flows through untouched — don't
    // clobber forward schemaVersions.
    test('v6 JSON → fromJson preserves schemaVersion (no clobber on future)',
        () {
      final v6 = <String, dynamic>{
        'schemaVersion': 6,
        'exportedAt': DateTime.utc(2026, 4, 24).toIso8601String(),
        'frameStatsSummary': <String, dynamic>{
          'totalFrames': 0,
          'jankFrames': 0,
          'averageFps': 0,
          'worstFrameTimeUs': 0,
        },
        'capturedFrames': <dynamic>[],
        'currentIssues': <dynamic>[],
      };
      final snapshot = SessionSnapshot.fromJson(v6);
      expect(snapshot.schemaVersion, 6);
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
    test('schemaVersion defaults to 5 for new snapshots', () {
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

      expect(snapshot.schemaVersion, 5);
      expect(snapshot.toJson()['schemaVersion'], 5);
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
      // v0.17.0 C1 fix: upgrade-on-read normalises schemaVersion<5 to 5
      // so the in-memory shape matches what toJson unconditionally emits.
      // Historical behaviour (schemaVersion=1 default for absent key) is
      // preserved only in terms of which input path was taken.
      expect(snapshot.schemaVersion, 5);
    });

    test('roundtrip with all v2 fields', () {
      final snapshot = SessionSnapshot(
        schemaVersion: 2,
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
      // toJson emits whatever schemaVersion the in-memory object declares,
      // so explicitly-constructed v2 objects serialise with schemaVersion=2.
      expect(json['schemaVersion'], 2);
      expect(json.containsKey('phaseEvents'), isTrue);
      expect(json.containsKey('gcEvents'), isTrue);
      expect(json.containsKey('platformChannelEvents'), isTrue);
      expect(json.containsKey('recentFrames'), isTrue);

      // v0.17.0 C1 fix: fromJson upgrades schemaVersion<5 → 5 on read so
      // the in-memory object advertises the v5 shape it actually carries.
      final restored = SessionSnapshot.fromJson(json);
      expect(restored.schemaVersion, 5);
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
      // v0.17.0 C1 upgrade-on-read: 2 → 5.
      expect(snapshot.schemaVersion, 5);
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
      expect(json.containsKey('routeSessions'), isFalse);
    });

    test('JSON string roundtrip preserves v2 schema', () {
      final snapshot = SessionSnapshot(
        schemaVersion: 2,
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

      // v0.17.0 C1 upgrade-on-read: v2 normalises to v5 because toJson
      // always emits v5 frameStatsSummary shape.
      expect(restored.schemaVersion, 5);
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
        downstreamIds: ['heavy_compute', 'rebuild_activity'],
      );

      final json = root.toJson();
      expect(json['downstreamIds'], ['heavy_compute', 'rebuild_activity']);
      expect(json.containsKey('rootCauseId'), isFalse);

      final restored = PerformanceIssue.fromJson(json);
      expect(restored.downstreamIds, ['heavy_compute', 'rebuild_activity']);
      expect(restored.rootCauseIds, isNull);
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
      expect(restored.rootCauseIds, ['setstate_scope']);
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
      expect(issue.rootCauseIds, isNull);
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

  // ---------------------------------------------------------------------------
  // confidenceReason serialization (3b.6)
  // ---------------------------------------------------------------------------

  group('PerformanceIssue confidenceReason serialization', () {
    test('confidenceReason round-trips through toJson/fromJson', () {
      const original = PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.build,
        confidence: IssueConfidence.possible,
        title: 'Test',
        detail: 'detail',
        fixHint: 'fix',
        stableId: 'non_lazy_list',
        confidenceReason: 'Structural scan only',
      );

      final json = original.toJson();
      expect(json['confidenceReason'], 'Structural scan only');

      final restored = PerformanceIssue.fromJson(json);
      expect(restored.confidenceReason, 'Structural scan only');
    });

    test('confidenceReason null when absent in JSON (backward compat)', () {
      final json = {
        'severity': 'warning',
        'category': 'build',
        'confidence': 'possible',
        'title': 'T',
        'detail': 'D',
        'fixHint': 'F',
        'debugModeDisclaimer': false,
      };

      final issue = PerformanceIssue.fromJson(json);
      expect(issue.confidenceReason, isNull);
    });

    test('confidenceReason omitted from toJson when null', () {
      const issue = PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.build,
        confidence: IssueConfidence.possible,
        title: 'T',
        detail: 'D',
        fixHint: 'F',
      );

      final json = issue.toJson();
      expect(json.containsKey('confidenceReason'), isFalse);
    });

    test('copyWith preserves confidenceReason', () {
      const issue = PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.build,
        confidence: IssueConfidence.possible,
        title: 'T',
        detail: 'D',
        fixHint: 'F',
        confidenceReason: 'Structural scan only',
      );

      final updated = issue.copyWith(title: 'Updated');
      expect(updated.confidenceReason, 'Structural scan only');
      expect(updated.title, 'Updated');
    });
  });

  // ---------------------------------------------------------------------------
  // packageName serialization (3b.8)
  // ---------------------------------------------------------------------------

  group('PerformanceIssue packageName serialization', () {
    test('packageName round-trips through toJson/fromJson', () {
      const original = PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.build,
        confidence: IssueConfidence.possible,
        title: 'Test',
        detail: 'detail',
        fixHint: 'fix',
        packageName: 'my_app',
      );

      final json = original.toJson();
      expect(json['packageName'], 'my_app');

      final restored = PerformanceIssue.fromJson(json);
      expect(restored.packageName, 'my_app');
    });

    test('packageName null when absent in JSON (backward compat)', () {
      final json = {
        'severity': 'warning',
        'category': 'build',
        'confidence': 'possible',
        'title': 'T',
        'detail': 'D',
        'fixHint': 'F',
        'debugModeDisclaimer': false,
      };

      final issue = PerformanceIssue.fromJson(json);
      expect(issue.packageName, isNull);
    });

    test('packageName omitted from toJson when null', () {
      const issue = PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.build,
        confidence: IssueConfidence.possible,
        title: 'T',
        detail: 'D',
        fixHint: 'F',
      );

      final json = issue.toJson();
      expect(json.containsKey('packageName'), isFalse);
    });

    test('copyWith preserves packageName', () {
      const issue = PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.build,
        confidence: IssueConfidence.possible,
        title: 'T',
        detail: 'D',
        fixHint: 'F',
        packageName: 'my_app',
      );

      final updated = issue.copyWith(title: 'Updated');
      expect(updated.packageName, 'my_app');
      expect(updated.title, 'Updated');
    });
  });

  // ---------------------------------------------------------------------------
  // PerformanceIssue per-tab fields (v0.14.1): scaffoldHashKey, tabVisitIndex.
  // Stamped at aggregation time so bottom-nav / tab-shell apps can group issues
  // by the actual tab Scaffold instead of the shared ModalRoute name.
  // ---------------------------------------------------------------------------

  group('PerformanceIssue per-tab (v0.14.1) serialization', () {
    test('scaffoldHashKey + tabVisitIndex round-trip via toJson/fromJson', () {
      const original = PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.build,
        confidence: IssueConfidence.possible,
        title: 'T',
        detail: 'D',
        fixHint: 'F',
        scaffoldHashKey: 0xDEADBEEF,
        tabVisitIndex: 3,
      );

      final json = original.toJson();
      expect(json['scaffoldHashKey'], 0xDEADBEEF);
      expect(json['tabVisitIndex'], 3);

      final restored = PerformanceIssue.fromJson(json);
      expect(restored.scaffoldHashKey, 0xDEADBEEF);
      expect(restored.tabVisitIndex, 3);
    });

    test('both fields null when absent in JSON (backward compat)', () {
      final json = {
        'severity': 'warning',
        'category': 'build',
        'confidence': 'possible',
        'title': 'T',
        'detail': 'D',
        'fixHint': 'F',
        'debugModeDisclaimer': false,
      };

      final issue = PerformanceIssue.fromJson(json);
      expect(issue.scaffoldHashKey, isNull);
      expect(issue.tabVisitIndex, isNull);
    });

    test('toJson omits both fields when null', () {
      const issue = PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.build,
        confidence: IssueConfidence.possible,
        title: 'T',
        detail: 'D',
        fixHint: 'F',
      );

      final json = issue.toJson();
      expect(json.containsKey('scaffoldHashKey'), isFalse);
      expect(json.containsKey('tabVisitIndex'), isFalse);
    });

    test('toJson emits scaffoldHashKey when only that field is set', () {
      const issue = PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.build,
        confidence: IssueConfidence.possible,
        title: 'T',
        detail: 'D',
        fixHint: 'F',
        scaffoldHashKey: 42,
      );

      final json = issue.toJson();
      expect(json['scaffoldHashKey'], 42);
      expect(json.containsKey('tabVisitIndex'), isFalse);
    });

    test('toJson emits tabVisitIndex when only that field is set', () {
      const issue = PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.build,
        confidence: IssueConfidence.possible,
        title: 'T',
        detail: 'D',
        fixHint: 'F',
        tabVisitIndex: 2,
      );

      final json = issue.toJson();
      expect(json['tabVisitIndex'], 2);
      expect(json.containsKey('scaffoldHashKey'), isFalse);
    });

    test('copyWith preserves scaffoldHashKey + tabVisitIndex', () {
      const issue = PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.build,
        confidence: IssueConfidence.possible,
        title: 'T',
        detail: 'D',
        fixHint: 'F',
        scaffoldHashKey: 0xAA,
        tabVisitIndex: 4,
      );

      final updated = issue.copyWith(title: 'Updated');
      expect(updated.scaffoldHashKey, 0xAA);
      expect(updated.tabVisitIndex, 4);
      expect(updated.title, 'Updated');
    });

    test('copyWith can overwrite scaffoldHashKey + tabVisitIndex', () {
      const issue = PerformanceIssue(
        severity: IssueSeverity.warning,
        category: IssueCategory.build,
        confidence: IssueConfidence.possible,
        title: 'T',
        detail: 'D',
        fixHint: 'F',
        scaffoldHashKey: 1,
        tabVisitIndex: 1,
      );

      final updated = issue.copyWith(scaffoldHashKey: 99, tabVisitIndex: 7);
      expect(updated.scaffoldHashKey, 99);
      expect(updated.tabVisitIndex, 7);
    });

    test('JSON string round-trip via dart:convert', () {
      // Belt-and-suspenders: verify the fields survive jsonEncode/jsonDecode
      // (not just the in-memory toJson/fromJson path).
      const original = PerformanceIssue(
        severity: IssueSeverity.critical,
        category: IssueCategory.build,
        confidence: IssueConfidence.confirmed,
        title: 'Heavy build',
        detail: 'detail',
        fixHint: 'fix',
        stableId: 'heavy_build',
        scaffoldHashKey: 0x12345,
        tabVisitIndex: 2,
      );

      final encoded = jsonEncode(original.toJson());
      final decoded = jsonDecode(encoded) as Map<String, dynamic>;
      final restored = PerformanceIssue.fromJson(decoded);

      expect(restored.scaffoldHashKey, 0x12345);
      expect(restored.tabVisitIndex, 2);
      expect(restored.stableId, 'heavy_build');
    });

    // -----------------------------------------------------------------------
    // E1 regression: fromJson must not throw on non-int values for
    // scaffoldHashKey / tabVisitIndex. A JavaScript consumer (v0.15 MCP
    // server) can round-trip large ints as strings due to 53-bit Number
    // precision, and hand-rolled payloads may encode ordinals as doubles.
    // Coerce to null rather than crashing the whole snapshot.
    // -----------------------------------------------------------------------

    test('fromJson coerces non-int scaffoldHashKey / tabVisitIndex to null',
        () {
      final base = {
        'severity': 'warning',
        'category': 'build',
        'confidence': 'possible',
        'title': 'T',
        'detail': 'D',
        'fixHint': 'F',
        'debugModeDisclaimer': false,
      };

      // Strings (e.g. from a JS consumer that stringified a large int).
      final fromString = PerformanceIssue.fromJson({
        ...base,
        'scaffoldHashKey': '123456789',
        'tabVisitIndex': '3',
      });
      expect(fromString.scaffoldHashKey, isNull);
      expect(fromString.tabVisitIndex, isNull);

      // Doubles (e.g. a hand-rolled payload with `3.0`).
      final fromDouble = PerformanceIssue.fromJson({
        ...base,
        'scaffoldHashKey': 3.14,
        'tabVisitIndex': 2.0,
      });
      expect(fromDouble.scaffoldHashKey, isNull);
      expect(fromDouble.tabVisitIndex, isNull);

      // Boolean, object — anything non-int falls to null.
      final fromJunk = PerformanceIssue.fromJson({
        ...base,
        'scaffoldHashKey': true,
        'tabVisitIndex': {'not': 'an int'},
      });
      expect(fromJunk.scaffoldHashKey, isNull);
      expect(fromJunk.tabVisitIndex, isNull);

      // Valid ints still parse correctly alongside the defensive path.
      final valid = PerformanceIssue.fromJson({
        ...base,
        'scaffoldHashKey': 42,
        'tabVisitIndex': 5,
      });
      expect(valid.scaffoldHashKey, 42);
      expect(valid.tabVisitIndex, 5);
    });
  });

  // ---------------------------------------------------------------------------
  // C3 regression: PerformanceIssue.routeName must stay RAW (no `(tab-N)`
  // suffix baked in). Display surfaces derive the disambiguated label via
  // routeDisplayName so group-by-route keys remain stable and a route
  // literally named '"/x (tab-2)"' stays distinguishable from a disambiguated
  // tab-2 of "/x".
  // ---------------------------------------------------------------------------

  group('PerformanceIssue.routeDisplayName (C3)', () {
    PerformanceIssue make({String? routeName, int? tabVisitIndex}) =>
        PerformanceIssue(
          severity: IssueSeverity.warning,
          category: IssueCategory.build,
          confidence: IssueConfidence.possible,
          title: 'T',
          detail: 'D',
          fixHint: 'F',
          routeName: routeName,
          tabVisitIndex: tabVisitIndex,
        );

    test('null routeName → null display name', () {
      expect(make().routeDisplayName, isNull);
    });

    test('tabVisitIndex null → bare routeName', () {
      expect(make(routeName: '/home').routeDisplayName, '/home');
    });

    test('tabVisitIndex 1 → bare routeName (no suffix on first visit)', () {
      expect(
          make(routeName: '/home', tabVisitIndex: 1).routeDisplayName, '/home');
    });

    test('tabVisitIndex 2 → suffixed display name', () {
      expect(make(routeName: '/home', tabVisitIndex: 2).routeDisplayName,
          '/home (tab-2)');
    });

    test('tabVisitIndex 17 → suffixed with exact ordinal', () {
      expect(make(routeName: '/foo', tabVisitIndex: 17).routeDisplayName,
          '/foo (tab-17)');
    });

    test('raw routeName is NEVER overwritten — stays queryable by key', () {
      final issue = make(routeName: '/home', tabVisitIndex: 3);
      // Display name is disambiguated, but raw routeName stays bare so
      // consumers filtering `issue.routeName == '/home'` match across visits.
      expect(issue.routeDisplayName, '/home (tab-3)');
      expect(issue.routeName, '/home');
    });
  });

  // ---------------------------------------------------------------------------
  // SessionSnapshot v3 sessionSummary serialization (3b.9)
  // ---------------------------------------------------------------------------

  group('SessionSnapshot sessionSummary serialization', () {
    test('sessionSummary round-trips through toJson/fromJson', () {
      final summary = <String, dynamic>{
        'topIssues': [
          {
            'stableId': 'heavy_compute',
            'title': 'Heavy computation',
            'severity': 'critical',
            'confidence': 'confirmed',
            'rankingScore': 339,
          },
        ],
        'causalEdges': [
          {'cause': 'setstate_scope', 'effect': 'heavy_compute'},
        ],
        'frameHistogram': {
          '<16ms': 40,
          '16-33ms': 10,
          '33-50ms': 3,
          '50-100ms': 2,
          '>100ms': 1,
        },
        'detectorHitRates': {'heavyCompute': 2, 'setStateScope': 1},
        'memoryTrendSummary': {
          'startBytes': 50000000,
          'endBytes': 70000000,
          'peakBytes': 75000000,
          'growthRatePerSec': 200.0,
          'sampleCount': 10,
        },
      };

      final snapshot = SessionSnapshot(
        schemaVersion: 3,
        exportedAt: DateTime.utc(2026, 4, 1),
        capturedFrames: const [],
        currentIssues: const [],
        frameStatsSummary: const FrameStatsSummary(
          totalFrames: 56,
          jankFrames: 6,
          averageFps: 58.0,
          worstFrameTimeUs: 120000,
        ),
        sessionSummary: summary,
      );

      final json = snapshot.toJson();
      expect(json.containsKey('sessionSummary'), isTrue);

      final restored = SessionSnapshot.fromJson(json);
      expect(restored.sessionSummary, isNotNull);

      final restoredSummary = restored.sessionSummary!;
      expect(restoredSummary['topIssues'], hasLength(1));
      expect(
        (restoredSummary['topIssues'] as List)[0]['stableId'],
        'heavy_compute',
      );
      expect(restoredSummary['causalEdges'], hasLength(1));
      expect(restoredSummary['frameHistogram']['<16ms'], 40);
      expect(restoredSummary['detectorHitRates']['heavyCompute'], 2);
      expect(restoredSummary['memoryTrendSummary']['peakBytes'], 75000000);
    });

    test('sessionSummary null when absent in JSON (v2 backward compat)', () {
      final json = {
        'schemaVersion': 2,
        'exportedAt': '2026-04-01T00:00:00.000Z',
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
      expect(snapshot.sessionSummary, isNull);
    });

    test('schema v2 JSON (no sessionSummary) parses without error', () {
      final json = {
        'schemaVersion': 2,
        'exportedAt': '2026-04-01T00:00:00.000Z',
        'packageVersion': '0.5.0',
        'isVmConnected': true,
        'isDebugMode': false,
        'capturedFrames': <dynamic>[],
        'currentIssues': <dynamic>[
          {
            'severity': 'warning',
            'category': 'build',
            'confidence': 'possible',
            'title': 'Test issue',
            'detail': 'detail',
            'fixHint': 'fix',
            'debugModeDisclaimer': false,
          },
        ],
        'frameStatsSummary': {
          'totalFrames': 100,
          'jankFrames': 5,
          'averageFps': 58.0,
          'worstFrameTimeUs': 45000,
        },
      };

      final snapshot = SessionSnapshot.fromJson(json);
      // v0.17.0 C1 upgrade-on-read: 2 → 5.
      expect(snapshot.schemaVersion, 5);
      expect(snapshot.sessionSummary, isNull);
      expect(snapshot.currentIssues, hasLength(1));
      expect(snapshot.packageVersion, '0.5.0');
    });

    test('toJson omits sessionSummary when null', () {
      final snapshot = SessionSnapshot(
        exportedAt: DateTime.utc(2026, 4, 1),
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
      expect(json.containsKey('sessionSummary'), isFalse);
    });
  });

  group('SessionSnapshot v4 routeSessions', () {
    test('roundtrip with routeSessions', () {
      final routeSessions = [
        {
          'routeName': '/home',
          'startedAt': '2026-04-11T10:00:00.000Z',
          'endedAt': '2026-04-11T10:03:42.000Z',
          'healthScore': 92,
          'durationSeconds': 222,
          'scanCycles': 20,
          'frameStats': {
            'totalFrames': 45,
            'jankFrames': 0,
            'averageFps': 60.0,
          },
          'issueCount': 0,
          'criticalCount': 0,
          'warningCount': 0,
          'issues': <String>[],
        },
        {
          'routeName': '/settings',
          'startedAt': '2026-04-11T10:03:42.000Z',
          'healthScore': 72,
          'durationSeconds': 134,
          'scanCycles': 14,
          'frameStats': {
            'totalFrames': 30,
            'jankFrames': 2,
            'averageFps': 57.3,
          },
          'issueCount': 3,
          'criticalCount': 1,
          'warningCount': 2,
          'issues': [
            'rebuild_debug_SettingsPage',
            'opacity_zero',
            'heavy_build'
          ],
        },
      ];

      final snapshot = SessionSnapshot(
        schemaVersion: 4,
        exportedAt: DateTime.utc(2026, 4, 11, 10, 5),
        capturedFrames: const [],
        currentIssues: const [],
        frameStatsSummary: const FrameStatsSummary(
          totalFrames: 75,
          jankFrames: 2,
          averageFps: 58.5,
          worstFrameTimeUs: 34000,
        ),
        routeSessions: routeSessions,
      );

      final json = snapshot.toJson();
      // toJson preserves the declared schemaVersion on the in-memory object.
      expect(json['schemaVersion'], 4);
      expect(json.containsKey('routeSessions'), isTrue);
      expect(json['routeSessions'], hasLength(2));

      final restored = SessionSnapshot.fromJson(json);
      // v0.17.0 C1 upgrade-on-read: 4 → 5.
      expect(restored.schemaVersion, 5);
      expect(restored.routeSessions, isNotNull);
      expect(restored.routeSessions, hasLength(2));
      expect(restored.routeSessions![0]['routeName'], '/home');
      expect(restored.routeSessions![0]['healthScore'], 92);
      expect(restored.routeSessions![1]['routeName'], '/settings');
      expect(restored.routeSessions![1]['issueCount'], 3);
      expect(restored.routeSessions![1]['criticalCount'], 1);
    });

    test('routeSessions null for v3 JSON (backward compat)', () {
      final json = {
        'schemaVersion': 3,
        'exportedAt': '2026-04-11T00:00:00.000Z',
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
      expect(snapshot.routeSessions, isNull);
    });

    test('toJson omits routeSessions when null', () {
      final snapshot = SessionSnapshot(
        exportedAt: DateTime.utc(2026, 4, 11),
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
      expect(json.containsKey('routeSessions'), isFalse);
    });

    test('toJson omits routeSessions when empty list', () {
      final snapshot = SessionSnapshot(
        exportedAt: DateTime.utc(2026, 4, 11),
        capturedFrames: const [],
        currentIssues: const [],
        frameStatsSummary: const FrameStatsSummary(
          totalFrames: 0,
          jankFrames: 0,
          averageFps: 0,
          worstFrameTimeUs: 0,
        ),
        routeSessions: const [],
      );

      final json = snapshot.toJson();
      expect(json.containsKey('routeSessions'), isFalse);
    });
  });
}
