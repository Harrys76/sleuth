// Source-level check that every runtimeVerified bracket's observed-axis
// key is stamped by the detector itself.
//
// The capture audit checks recorded traces, so a renamed `extraTraceArgs`
// key would only surface at the next re-record. Here each detector with
// a bracket that declares `observedAxisArgKey` runs through a minimal
// emission, and every bracket's `(stableId, severity)` must produce an
// issue carrying that key.

import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/detectors/frame_timing_detector.dart';
import 'package:sleuth/src/detectors/heavy_compute_detector.dart';
import 'package:sleuth/src/detectors/memory_pressure_detector.dart';
import 'package:sleuth/src/detectors/network_monitor_detector.dart';
import 'package:sleuth/src/detectors/platform_channel_detector.dart';
import 'package:sleuth/src/detectors/rebuild_detector.dart';
import 'package:sleuth/src/detectors/repaint_detector.dart';
import 'package:sleuth/src/detectors/stream_resource_detector.dart';
import 'package:sleuth/src/detectors/tracked_resource_detector.dart';
import 'package:sleuth/src/models/base_detector.dart';
import 'package:sleuth/src/models/frame_stats.dart';
import 'package:sleuth/src/models/heap_sample.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/network/request_record.dart';
import 'package:sleuth/src/validation/detector_metadata.dart';
import 'package:vm_service/vm_service.dart';

import '../helpers/timeline_test_helpers.dart';

typedef _Bracket = ({String stableId, String severity, String argKey});

/// Brackets of [meta] that declare an observed-axis key.
List<_Bracket> _axisBrackets(DetectorMetadata meta) => [
  if (meta.bracketStableId != null &&
      meta.bracketSeverityLabel != null &&
      meta.observedAxisArgKey != null)
    (
      stableId: meta.bracketStableId!,
      severity: meta.bracketSeverityLabel!,
      argKey: meta.observedAxisArgKey!,
    ),
  for (final spec in meta.additionalBrackets ?? const <BracketSpec>[])
    if (spec.observedAxisArgKey != null)
      (
        stableId: spec.stableId,
        severity: spec.severityLabel,
        argKey: spec.observedAxisArgKey!,
      ),
];

class _Holder {
  _Holder(this.id);
  final int id;
}

/// Issues from minimal emissions of each detector type, covering every
/// severity its brackets name.
final Map<DetectorType, Future<List<PerformanceIssue>> Function()> _recipes = {
  DetectorType.heavyCompute: () async => [
    for (final us in [9000, 20000])
      ...(HeavyComputeDetector()..processTimelineData(
            heavyComputeData(buildScopeDurationsUs: [us]),
          ))
          .issues,
  ],
  DetectorType.platformChannel: () async {
    var now = DateTime(2026);
    final d = PlatformChannelDetector(clock: () => now)
      ..processTimelineData(
        platformChannelData(channelEventCount: 25, durUs: 2000),
      );
    now = now.add(const Duration(seconds: 2));
    d.processTimelineData(emptyTimelineData());
    return d.issues;
  },
  DetectorType.frameTiming: () async {
    final d = FrameTimingDetector(warmupDuration: Duration.zero);
    FrameStats frame(int uiMs) => FrameStats(
      frameNumber: 0,
      uiDuration: Duration(milliseconds: uiMs),
      rasterDuration: const Duration(milliseconds: 6),
      timestamp: DateTime.now(),
    );
    for (var i = 0; i < 80; i++) {
      d.addFrameForTest(frame(8));
    }
    for (var i = 0; i < 20; i++) {
      d.addFrameForTest(frame(40));
    }
    return d.issues;
  },
  DetectorType.memoryPressure: () async {
    var now = DateTime(2026);
    final d = MemoryPressureDetector(clock: () => now, warmupDurationMs: 0)
      ..vmConnected = true;
    for (var i = 0; i < 25; i++) {
      d.processHeapSample(
        HeapSample(
          heapUsage: i * 300000,
          heapCapacity: 100 * 1024 * 1024,
          externalUsage: 0,
          timestamp: now,
        ),
      );
      now = now.add(const Duration(milliseconds: 500));
    }
    return d.issues;
  },
  DetectorType.rebuild: () async {
    final issues = <PerformanceIssue>[];
    for (final buildUs in [110000, 310000]) {
      var now = DateTime(2026);
      final d = RebuildDetector(clock: () => now)..vmConnected = true;
      d.processTimelineData(buildLoadData(buildTimeUs: buildUs));
      now = now.add(const Duration(seconds: 1));
      d
        ..processTimelineData(emptyTimelineData())
        ..evaluateNow();
      issues.addAll(d.issues);
    }
    return issues;
  },
  DetectorType.repaint: () async {
    final issues = <PerformanceIssue>[];
    for (final paintUs in [110000, 310000]) {
      var now = DateTime(2026);
      final d = RepaintDetector(clock: () => now)..vmConnected = true;
      d.processTimelineData(paintLoadData(paintTimeUs: paintUs));
      now = now.add(const Duration(seconds: 1));
      d
        ..processTimelineData(emptyTimelineData())
        ..evaluateNow();
      issues.addAll(d.issues);
    }
    return issues;
  },
  DetectorType.networkMonitor: () async {
    final now = DateTime(2026);
    RequestRecord record({
      String url = 'https://example.com/api',
      int durationMs = 100,
      int responseBytes = 1024,
      DateTime? startedAt,
    }) => RequestRecord(
      url: url,
      method: 'GET',
      statusCode: 200,
      durationMs: durationMs,
      responseBytes: responseBytes,
      startedAt: startedAt ?? now,
    );
    // One detector per emission: issues of one id are merged per scan.
    final slowWarning = NetworkMonitorDetector(clock: () => now)
      ..processRecord(record(durationMs: 1500));
    final slowCritical = NetworkMonitorDetector(clock: () => now)
      ..processRecord(record(durationMs: 5000));
    final large = NetworkMonitorDetector(clock: () => now)
      ..processRecord(record(responseBytes: 2 << 20));
    final frequent = NetworkMonitorDetector(clock: () => now);
    for (var i = 0; i < 38; i++) {
      frequent.processRecord(
        record(
          url: 'http://127.0.0.1/ping?seq=$i',
          startedAt: now.add(Duration(milliseconds: i * 100)),
        ),
      );
    }
    return [
      for (final d in [slowWarning, slowCritical, large, frequent]) ...d.issues,
    ];
  },
  DetectorType.trackedResource: () async {
    var now = DateTime.utc(2026);
    final d = TrackedResourceDetector(
      maxConcurrent: 5,
      longLivedSeconds: 300,
      maxDistinctNames: 1000,
      sweepIntervalSeconds: 10,
      clock: () => now,
    );
    final keep = [for (var i = 0; i < 6; i++) _Holder(i)];
    for (final h in keep) {
      d.track('socket', h);
    }
    now = now.add(const Duration(seconds: 301));
    d.evaluateNowForTest();
    final issues = d.issues;
    expect(keep, hasLength(6));
    d.dispose();
    return issues;
  },
  DetectorType.streamResource: () async {
    var now = DateTime(2026);
    final profiles = <AllocationProfile>[
      for (var i = 0; i < 4; i++)
        AllocationProfile(
          members: [
            ClassHeapStats(
              classRef: ClassRef(
                id: 'class/StreamSubscription',
                name: 'StreamSubscription',
                library: LibraryRef(
                  id: 'lib/dart:async',
                  name: 'dart.async',
                  uri: 'dart:async',
                ),
              ),
              instancesCurrent: 100 + i * 30,
            ),
            ClassHeapStats(
              classRef: ClassRef(
                id: 'class/_BroadcastSubscription',
                name: '_BroadcastSubscription',
                library: LibraryRef(
                  id: 'lib/dart:async',
                  name: 'dart.async',
                  uri: 'dart:async',
                ),
              ),
              instancesCurrent: 50 + i * 10,
            ),
          ],
        ),
    ];
    final d = StreamResourceDetector(
      vmClientProvider: () => null,
      heapGrowingStateProvider: () => true,
      clock: () => now,
      sampleSeconds: 10,
      minDelta: 50,
      warmupSeconds: 20,
      windowSize: 4,
      allocationProfileFetcherForTest: () async =>
          profiles.isEmpty ? null : profiles.removeAt(0),
    );
    Future<void> tick() async {
      d.processTimelineData(emptyTimelineData());
      await Future<void>.delayed(Duration.zero);
    }

    await tick();
    now = now.add(const Duration(seconds: 25));
    for (var i = 0; i < 4; i++) {
      await tick();
      now = now.add(const Duration(seconds: 10));
    }
    return d.issues;
  },
};

bool _inFamily(PerformanceIssue issue, String stableId) {
  final id = issue.stableId;
  return id == stableId || (id != null && id.startsWith('$stableId:'));
}

void main() {
  test('every detector with an observed-axis bracket has a recipe here', () {
    final controller = SleuthController()..initializeDetectorsForTest();
    addTearDown(controller.dispose);
    final withAxis = <DetectorType>{
      for (final d in controller.detectorsForAudit)
        if (d is DetectorMetadataProvider &&
            _axisBrackets(
              (d as DetectorMetadataProvider).validationMetadata,
            ).isNotEmpty)
          d.type,
    };
    expect(withAxis, isNotEmpty);
    expect(_recipes.keys.toSet(), containsAll(withAxis));
  });

  final controller = SleuthController()..initializeDetectorsForTest();
  final metadataByType = <DetectorType, DetectorMetadata>{
    for (final d in controller.detectorsForAudit)
      if (d is DetectorMetadataProvider)
        d.type: (d as DetectorMetadataProvider).validationMetadata,
  };
  controller.dispose();

  for (final entry in _recipes.entries) {
    final type = entry.key;
    final meta = metadataByType[type];
    test('$type stamps its brackets\' observed-axis keys', () async {
      expect(meta, isNotNull, reason: '$type has no metadata');
      final brackets = _axisBrackets(meta!);
      expect(brackets, isNotEmpty);
      final issues = await entry.value();
      for (final b in brackets) {
        final matching = issues
            .where(
              (i) => _inFamily(i, b.stableId) && i.severity.name == b.severity,
            )
            .toList();
        expect(
          matching,
          isNotEmpty,
          reason: 'no ${b.stableId}.${b.severity} emission from the recipe',
        );
        for (final issue in matching) {
          expect(
            issue.extraTraceArgs?.containsKey(b.argKey),
            isTrue,
            reason:
                '${issue.stableId}.${b.severity} lacks extraTraceArgs.'
                '${b.argKey}',
          );
        }
      }
    });
  }
}
