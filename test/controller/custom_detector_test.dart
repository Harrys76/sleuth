import 'dart:ui' show FrameTiming;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/detectors/frame_timing_detector.dart';
import 'package:sleuth/src/detectors/listview_detector.dart';
import 'package:sleuth/src/models/base_detector.dart';
import 'package:sleuth/src/models/frame_stats.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/models/widget_highlight.dart';
import 'package:sleuth/src/vm/timeline_parser.dart';

// ---------------------------------------------------------------------------
// Test detectors
// ---------------------------------------------------------------------------

/// Minimal structural custom detector for testing.
class _TestStructuralDetector extends BaseDetector {
  _TestStructuralDetector()
    : super(
        type: DetectorType.custom,
        lifecycle: DetectorLifecycle.structural,
        name: 'Test Structural',
        description: 'Test detector for v4.2',
      );

  final List<PerformanceIssue> _issues = [];
  final List<WidgetHighlight> _highlights = [];
  bool _isEnabled = true;
  int scanCount = 0;
  bool disposed = false;

  @override
  List<PerformanceIssue> get issues => _issues;
  @override
  List<WidgetHighlight> get highlights => _highlights;
  @override
  bool get isEnabled => _isEnabled;
  @override
  set isEnabled(bool v) => _isEnabled = v;

  @override
  void scanTree(BuildContext context) {
    if (!_isEnabled) return;
    scanCount++;
    _issues.clear();
    _issues.add(
      PerformanceIssue(
        stableId: 'test_custom_issue',
        severity: IssueSeverity.warning,
        category: IssueCategory.build,
        confidence: IssueConfidence.possible,
        title: 'Test Custom Issue',
        detail: 'Scan #$scanCount',
        fixHint: 'Test fix',
        observationSource: ObservationSource.structural,
        detectedAt: DateTime.now(),
      ),
    );
    _highlights.add(
      const WidgetHighlight(
        rect: Rect.fromLTWH(0, 0, 100, 100),
        widgetName: 'TestWidget',
        severity: IssueSeverity.warning,
        detectorName: 'Test Structural',
      ),
    );
  }

  @override
  void dispose() {
    disposed = true;
    _issues.clear();
  }
}

/// Minimal hybrid custom detector for timeline tests.
class _TestHybridDetector extends BaseDetector {
  _TestHybridDetector()
    : super(
        type: DetectorType.custom,
        lifecycle: DetectorLifecycle.hybrid,
        name: 'Test Hybrid',
        description: 'Test hybrid detector for v4.2',
      );

  final List<PerformanceIssue> _issues = [];
  bool _isEnabled = true;
  int timelineCallCount = 0;
  int evaluateNowCount = 0;
  int scanCount = 0;
  bool disposed = false;

  @override
  List<PerformanceIssue> get issues => _issues;
  @override
  bool get isEnabled => _isEnabled;
  @override
  set isEnabled(bool v) => _isEnabled = v;

  @override
  void processTimelineData(ParsedTimelineData data) {
    timelineCallCount++;
  }

  @override
  void evaluateNow() {
    evaluateNowCount++;
    if (timelineCallCount > 0) {
      _issues.clear();
      _issues.add(
        PerformanceIssue(
          stableId: 'test_hybrid_issue',
          severity: IssueSeverity.warning,
          category: IssueCategory.build,
          confidence: IssueConfidence.likely,
          title: 'Test Hybrid Issue',
          detail: 'Timeline calls: $timelineCallCount',
          fixHint: 'Test fix',
          observationSource: ObservationSource.vmTimeline,
          detectedAt: DateTime.now(),
        ),
      );
    }
  }

  @override
  void scanTree(BuildContext context) {
    scanCount++;
  }

  @override
  void dispose() {
    disposed = true;
    _issues.clear();
  }
}

/// Minimal vmOnly custom detector for timeline tests.
class _TestVmOnlyDetector extends BaseDetector {
  _TestVmOnlyDetector()
    : super(
        type: DetectorType.custom,
        lifecycle: DetectorLifecycle.vmOnly,
        name: 'Test VmOnly',
        description: 'Test vmOnly detector for v4.2',
      );

  final List<PerformanceIssue> _issues = [];
  bool _isEnabled = true;
  int timelineCallCount = 0;
  bool disposed = false;

  @override
  List<PerformanceIssue> get issues => _issues;
  @override
  bool get isEnabled => _isEnabled;
  @override
  set isEnabled(bool v) => _isEnabled = v;

  @override
  void processTimelineData(ParsedTimelineData data) {
    timelineCallCount++;
    _issues.clear();
    _issues.add(
      PerformanceIssue(
        stableId: 'test_vmonly_issue',
        severity: IssueSeverity.critical,
        category: IssueCategory.raster,
        confidence: IssueConfidence.confirmed,
        title: 'Test VmOnly Issue',
        detail: 'Timeline calls: $timelineCallCount',
        fixHint: 'Test fix',
        observationSource: ObservationSource.vmTimeline,
        detectedAt: DateTime.now(),
      ),
    );
  }

  @override
  void dispose() {
    disposed = true;
    _issues.clear();
  }
}

/// Runtime custom detector that counts presented frames.
class _TestFrameDetector extends BaseDetector {
  _TestFrameDetector({this.onFrame})
    : super(
        type: DetectorType.custom,
        lifecycle: DetectorLifecycle.runtime,
        name: 'Test Frame',
        description: 'Counts processFrame calls',
      );

  final void Function()? onFrame;
  bool _isEnabled = true;
  final List<FrameStats> frames = [];

  @override
  List<PerformanceIssue> get issues => const [];
  @override
  bool get isEnabled => _isEnabled;
  @override
  set isEnabled(bool v) => _isEnabled = v;

  @override
  void processFrame(FrameStats frame) {
    frames.add(frame);
    onFrame?.call();
  }

  @override
  void dispose() {}
}

/// A second frame-timing producer: the fan-out must not feed it frames.
class _CountingFrameTimingDetector extends FrameTimingDetector {
  int processFrameCalls = 0;

  @override
  void processFrame(FrameStats frame) => processFrameCalls++;
}

int _vsync = 1000000000;

/// [count] engine timings at 60 Hz spacing (build 2 ms, raster 2 ms).
List<FrameTiming> _timings(int count) => [
  for (var i = 0; i < count; i++)
    () {
      _vsync += 16667;
      return FrameTiming(
        vsyncStart: _vsync,
        buildStart: _vsync,
        buildFinish: _vsync + 2000,
        rasterStart: _vsync + 2000,
        rasterFinish: _vsync + 4000,
        rasterFinishWallTime: _vsync + 4000,
      );
    }(),
];

// ---------------------------------------------------------------------------
// Shared widget tree
// ---------------------------------------------------------------------------

const _minimalTree = Directionality(
  textDirection: TextDirection.ltr,
  child: SizedBox(width: 10, height: 10),
);

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('Custom Detector Plugin API (v4.2)', () {
    group('structural custom detector', () {
      late SleuthController controller;
      late _TestStructuralDetector detector;

      setUp(() {
        detector = _TestStructuralDetector();
        controller = SleuthController(
          config: SleuthConfig(customDetectors: [detector]),
        );
        controller.initializeDetectorsForTest();
      });

      tearDown(() => controller.dispose());

      testWidgets('receives scanTree calls', (tester) async {
        await tester.pumpWidget(_minimalTree);
        controller.runTreeScanForTest(
          tester.element(find.byType(Directionality)),
        );

        expect(detector.scanCount, 1);
      });

      testWidgets('issues appear in aggregated list', (tester) async {
        await tester.pumpWidget(_minimalTree);
        controller.runTreeScanForTest(
          tester.element(find.byType(Directionality)),
        );

        final issues = controller.issuesNotifier.value;
        expect(issues.any((i) => i.stableId == 'test_custom_issue'), isTrue);
      });

      testWidgets('highlights appear in overlay collection', (tester) async {
        await tester.pumpWidget(_minimalTree);
        controller.runTreeScanForTest(
          tester.element(find.byType(Directionality)),
        );

        final highlights = controller.highlightsNotifier.value.items;
        expect(
          highlights.any((h) => h.detectorName == 'Test Structural'),
          isTrue,
        );
      });
    });

    group('hybrid custom detector', () {
      late SleuthController controller;
      late _TestHybridDetector detector;

      setUp(() {
        detector = _TestHybridDetector();
        controller = SleuthController(
          config: SleuthConfig(customDetectors: [detector]),
        );
        controller.initializeDetectorsForTest();
      });

      tearDown(() => controller.dispose());

      test('receives processTimelineData', () {
        controller.feedTimelineDataForTest(ParsedTimelineData());
        expect(detector.timelineCallCount, 1);
      });

      test('receives evaluateNow after timeline data', () {
        controller.feedTimelineDataForTest(ParsedTimelineData());
        expect(detector.evaluateNowCount, 1);
      });

      testWidgets('receives scanTree calls (hybrid)', (tester) async {
        await tester.pumpWidget(_minimalTree);
        controller.runTreeScanForTest(
          tester.element(find.byType(Directionality)),
        );

        expect(detector.scanCount, 1);
      });
    });

    group('vmOnly custom detector', () {
      late SleuthController controller;
      late _TestVmOnlyDetector detector;

      setUp(() {
        detector = _TestVmOnlyDetector();
        controller = SleuthController(
          config: SleuthConfig(customDetectors: [detector]),
        );
        controller.initializeDetectorsForTest();
      });

      tearDown(() => controller.dispose());

      test('receives processTimelineData', () {
        controller.feedTimelineDataForTest(ParsedTimelineData());
        expect(detector.timelineCallCount, 1);
        expect(detector.issues.length, 1);
        expect(detector.issues.first.stableId, 'test_vmonly_issue');
      });
    });

    group('per-frame hook', () {
      late SleuthController controller;
      late _TestFrameDetector detector;

      setUp(() {
        detector = _TestFrameDetector();
        controller = SleuthController(
          config: SleuthConfig(customDetectors: [detector]),
        );
        controller.initializeDetectorsForTest();
      });

      tearDown(() => controller.dispose());

      testWidgets('one processFrame call per presented frame', (tester) async {
        controller.handleTimingsForTest(_timings(1));
        controller.handleTimingsForTest(_timings(1));
        expect(detector.frames, hasLength(2));
      });

      testWidgets('one callback carrying 5 timings → 5 calls in order', (
        tester,
      ) async {
        controller.handleTimingsForTest(_timings(5));
        expect(detector.frames, hasLength(5));
        final vsyncs = detector.frames.map((f) => f.vsyncStartUs!).toList();
        expect(vsyncs, orderedEquals([...vsyncs]..sort()));
      });

      testWidgets('addFrameForTest frames are fanned out too', (tester) async {
        controller.addFrameForTest(
          FrameStats(
            frameNumber: 1,
            uiDuration: const Duration(milliseconds: 2),
            rasterDuration: const Duration(milliseconds: 2),
            timestamp: DateTime(2026),
          ),
        );
        expect(detector.frames, hasLength(1));
      });

      testWidgets('frame-timing detectors never receive frames', (
        tester,
      ) async {
        final producer = _CountingFrameTimingDetector();
        controller.addDetectorForTest(producer);
        controller.handleTimingsForTest(_timings(3));
        expect(producer.processFrameCalls, 0);
        expect(detector.frames, hasLength(3));
      });

      testWidgets('disabled detector receives no frames', (tester) async {
        detector.isEnabled = false;
        controller.handleTimingsForTest(_timings(3));
        expect(detector.frames, isEmpty);
      });

      testWidgets('no frames reach detectors when FrameTiming is disabled', (
        tester,
      ) async {
        controller.disableDetector(DetectorType.frameTiming);
        controller.handleTimingsForTest(_timings(3));
        expect(detector.frames, isEmpty);
      });

      testWidgets('enabling a detector from processFrame is deferred safely', (
        tester,
      ) async {
        late SleuthController c;
        var requested = false;
        final reentrant = _TestFrameDetector(
          onFrame: () {
            if (requested) return;
            requested = true;
            c.enableDetector(DetectorType.listview);
          },
        );
        c = SleuthController(
          config: SleuthConfig(
            enabledDetectors: const {DetectorType.frameTiming},
            customDetectors: [reentrant],
          ),
        )..initializeDetectorsForTest();
        addTearDown(c.dispose);

        c.handleTimingsForTest(_timings(3));

        expect(reentrant.frames, hasLength(3));
        expect(c.detectorsForAudit.whereType<ListviewDetector>(), hasLength(1));
      });
    });

    group('lifecycle', () {
      testWidgets('disposed on controller dispose', (tester) async {
        final detector = _TestStructuralDetector();
        final controller = SleuthController(
          config: SleuthConfig(customDetectors: [detector]),
        );
        controller.initializeDetectorsForTest();

        controller.dispose();
        expect(detector.disposed, isTrue);
      });

      testWidgets('disabled custom detector skipped in scanTree', (
        tester,
      ) async {
        final detector = _TestStructuralDetector();
        final controller = SleuthController(
          config: SleuthConfig(customDetectors: [detector]),
        );
        controller.initializeDetectorsForTest();

        // Disable the detector after initialization
        detector.isEnabled = false;

        await tester.pumpWidget(_minimalTree);
        controller.runTreeScanForTest(
          tester.element(find.byType(Directionality)),
        );

        expect(detector.scanCount, 0);
        expect(
          controller.issuesNotifier.value.any(
            (i) => i.stableId == 'test_custom_issue',
          ),
          isFalse,
        );

        controller.dispose();
      });
    });

    group('integration', () {
      test('empty customDetectors has zero overhead (default)', () {
        final controller = SleuthController();
        controller.initializeDetectorsForTest();

        // No crash, no issues from custom detectors
        expect(controller.issuesNotifier.value, isEmpty);
        controller.dispose();
      });

      testWidgets('custom detector issues affected by suppression', (
        tester,
      ) async {
        final detector = _TestStructuralDetector();
        final controller = SleuthController(
          config: SleuthConfig(
            customDetectors: [detector],
            suppressedIssues: {'test_custom_*'},
          ),
        );
        controller.initializeDetectorsForTest();

        await tester.pumpWidget(_minimalTree);
        controller.runTreeScanForTest(
          tester.element(find.byType(Directionality)),
        );

        // Issue suppressed by wildcard
        expect(
          controller.issuesNotifier.value.any(
            (i) => i.stableId == 'test_custom_issue',
          ),
          isFalse,
        );
        expect(controller.suppressedCountForTest, 1);

        controller.dispose();
      });

      testWidgets('multiple custom detectors coexist', (tester) async {
        final structural = _TestStructuralDetector();
        final hybrid = _TestHybridDetector();
        final controller = SleuthController(
          config: SleuthConfig(customDetectors: [structural, hybrid]),
        );
        controller.initializeDetectorsForTest();

        await tester.pumpWidget(_minimalTree);
        controller.runTreeScanForTest(
          tester.element(find.byType(Directionality)),
        );

        expect(structural.scanCount, 1);
        expect(hybrid.scanCount, 1);

        final issues = controller.issuesNotifier.value;
        expect(issues.any((i) => i.stableId == 'test_custom_issue'), isTrue);

        controller.dispose();
      });
    });
  });
}
