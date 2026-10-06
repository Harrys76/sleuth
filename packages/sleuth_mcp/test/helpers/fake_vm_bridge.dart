import 'package:sleuth_mcp/sleuth_mcp.dart';

/// Two full-shape issues mirroring `PerformanceIssue.toJson` — every
/// compact keep-field plus the verbose-only noise fields the compact
/// projection must drop. Used by both `ext.sleuth.issues` and the snapshot's
/// `currentIssues` so trim + cap behavior is exercisable. Ranked order is
/// the list order (the app emits already-ranked); index 0 is highest.
List<Map<String, Object?>> fullFakeIssues() => [
  {
    'severity': 'warning',
    'category': 'build',
    'confidence': 'confirmed',
    'title': 'Jank detected',
    'detail': 'Frame exceeded the 16ms budget.',
    'fixHint': 'Profile the build method.',
    'stableId': 'jank_detected',
    'widgetName': 'HomePage',
    'routeName': '/home',
    'sourceRoute': '/home',
    'confidenceReason': 'observed directly',
    'rootCauseIds': <String>['heap_growing'],
    // verbose-only noise — must be dropped by the compact projection.
    'captureTraceStableId': 'jank_detected',
    'observationSource': 'frameTiming',
    'debugModeDisclaimer': 'debug only',
    'detectedAt': '2026-05-17T00:00:01.000Z',
    'rankingScore': 88.0,
    'rankingBreakdown': {'severity': 100, 'recency': 76},
    'downstreamIds': <String>[],
    'packageName': 'example_app',
  },
  {
    'severity': 'critical',
    'category': 'memory',
    'confidence': 'likely',
    'title': 'Heap growing',
    'detail': 'Heap slope exceeded threshold.',
    'fixHint': 'Look for retained allocations.',
    'stableId': 'heap_growing',
    'widgetName': 'FeedList',
    'routeName': '/feed',
    'sourceRoute': '/feed',
    'confidenceReason': 'runtime + structural',
    // rootCauseIds intentionally omitted (real toJson omits when null) —
    // exercises compactIssue's "absent stays absent" path.
    // verbose-only noise.
    'captureTraceStableId': 'heap_growing',
    'observationSource': 'vmTimeline',
    'debugModeDisclaimer': 'debug only',
    'detectedAt': '2026-05-17T00:00:02.000Z',
    'rankingScore': 140.0,
    'rankingBreakdown': {'severity': 200, 'recency': 80},
    'tabVisitIndex': 1,
  },
];

/// `ext.sleuth.snapshot` envelope used by [defaultFakeBridge]: a `basic`
/// session whose snapshot reports [isVmConnected] (default false — no VM
/// self-connect, so the launch advisory fires and budgets refuse with
/// `coverage_degraded`). Pass true for a session whose VM-only detectors ran.
Map<String, Object?> fakeSnapshotEnvelope({bool isVmConnected = false}) => {
  'connectionMode': 'basic',
  'schemaVersion': 1,
  'sessionUuid': 'fake-uuid',
  'data': {
    'schemaVersion': 5,
    'exportedAt': '2026-05-17T00:00:00.000Z',
    'packageVersion': '0.37.0',
    'isVmConnected': isVmConnected,
    'currentIssues': fullFakeIssues(),
    'frameStatsSummary': {'averageFps': 59.5, 'jankFrames': 0},
  },
};

/// Snapshot `data` with every one of the 14 sections, the per-frame and raw
/// sample ones included, so projection is observable.
Map<String, Object?> fullFakeSnapshotData({bool isVmConnected = true}) => {
  'schemaVersion': 5,
  'exportedAt': '2026-05-17T00:00:00.000Z',
  'packageVersion': '0.37.0',
  'isVmConnected': isVmConnected,
  'isDebugMode': false,
  'frameStatsSummary': {'averageFps': 59.5, 'jankFrames': 0},
  'capturedFrames': [
    for (var i = 0; i < 3; i++) {'frameNumber': i, 'buildUs': 1200},
  ],
  'currentIssues': fullFakeIssues(),
  'recentRequests': [
    {'url': 'https://example.com/a?token=x', 'durationMs': 120},
  ],
  'heapSamples': [
    {'timestampUs': 1, 'heapUsage': 1000},
  ],
  'phaseEvents': [
    {'name': 'BUILD', 'durationUs': 900},
  ],
  'gcEvents': [
    {'timestampUs': 2, 'gcType': 'Scavenge'},
  ],
  'platformChannelEvents': [
    {'timestampUs': 3, 'durationUs': 40, 'name': 'flutter/platform'},
  ],
  'recentFrames': [
    for (var i = 0; i < 5; i++) {'buildUs': 1000, 'rasterUs': 2000},
  ],
  'widgetHeatMap': [
    {'widgetName': 'HomePage', 'score': 3},
  ],
  'recurrenceTrends': {
    'jank_detected': {
      'trend': 'stable',
      'totalOccurrences': 2,
      'totalObserved': 3,
      'lastSeenCycle': 4,
    },
  },
  'sessionSummary': {
    'frameHistogram': {'<16ms': 5},
  },
  'startupMetrics': {'firstFrameMs': 420},
  'routeSessions': [
    {'routeName': '/home', 'healthScore': 80},
  ],
};

/// Answers `ext.sleuth.snapshot` the way the app does: applies `sections`
/// (comma-joined, case-insensitive), `maxIssueCount` and `maxRouteCount` to
/// [data], and stamps `_projectedSections`, `_projectionLimits` and
/// `_projectionApplied: by_app` when any of them is set.
Map<String, Object?> Function(Map<String, dynamic> args)
projectingSnapshotResponder(Map<String, Object?> data) {
  return (args) {
    final rawSections = args['sections'] as String?;
    Set<String>? include;
    if (rawSections != null && rawSections.trim().isNotEmpty) {
      include = {};
      for (final token in rawSections.split(',')) {
        final t = token.trim();
        if (t.isEmpty) continue;
        final match = snapshotSectionKeys.where(
          (k) => k.toLowerCase() == t.toLowerCase(),
        );
        if (match.isEmpty) {
          return {
            'connectionMode': 'basic',
            'schemaVersion': 1,
            'sessionUuid': 'fake-uuid',
            'error': 'arg_invalid_section: "$t" is not a known section',
          };
        }
        include.add(match.first);
      }
    }
    final maxIssueCount = int.tryParse('${args['maxIssueCount']}');
    final maxRouteCount = int.tryParse('${args['maxRouteCount']}');
    final projected =
        include != null || maxIssueCount != null || maxRouteCount != null;
    final out = <String, Object?>{
      for (final entry in data.entries)
        if (!snapshotSectionKeys.contains(entry.key) ||
            include == null ||
            include.contains(entry.key))
          entry.key: entry.value,
    };
    if (maxIssueCount != null && out['currentIssues'] is List) {
      out['currentIssues'] = (out['currentIssues'] as List)
          .take(maxIssueCount)
          .toList();
    }
    if (maxRouteCount != null && out['routeSessions'] is List) {
      out['routeSessions'] = (out['routeSessions'] as List)
          .take(maxRouteCount)
          .toList();
    }
    if (projected) {
      out['_projectedSections'] =
          (include ?? snapshotSectionKeys.toSet()).toList()..sort();
      if (maxIssueCount != null || maxRouteCount != null) {
        out['_projectionLimits'] = {
          'maxIssueCount': ?maxIssueCount,
          'maxRouteCount': ?maxRouteCount,
        };
      }
      out['_projectionApplied'] = 'by_app';
    }
    return {
      'connectionMode': 'full',
      'schemaVersion': 1,
      'sessionUuid': 'fake-uuid',
      'data': out,
    };
  };
}

/// Build a `FakeVmBridge` pre-populated with realistic envelopes for
/// the seven `ext.sleuth.*` extensions.
FakeVmBridge defaultFakeBridge() {
  final bridge = FakeVmBridge(fakeSessionUuid: 'fake-uuid');
  bridge.setEnvelope('ext.sleuth.diagnose', {
    'connectionMode': 'basic',
    'schemaVersion': 1,
    'sessionUuid': 'fake-uuid',
    'data': {
      'packageVersion': '0.37.0',
      'initializedAtMicros': 0,
      'vmConnected': true,
      'captureMode': false,
      'lastCaptureExportFailure': null,
      'unboundExtensionNames': <String>[],
      'effectiveFrameRateHz': 60.0,
      'frameBudgetUs': 16667,
      'frameRateSource': 'fixed',
      'lastPollRpcMicros': 1800,
      'lastPollDecodeMicros': 600,
      'lastPollParseMicros': 420,
      'lastPollDispatchMicros': 310,
      'lastPollDispatchDetectorsMicros': 120,
      'lastPollDispatchCorrelateMicros': 40,
      'lastPollDispatchAggregateMicros': 130,
      'lastPollDispatchOtherMicros': 20,
      'lastPollTailMicros': 250,
      'lastPollTailMemoryMicros': 200,
      'lastPollTailCpuSamplesMicros': 0,
      'lastPollTailAllocationProfileMicros': 0,
      'lastPollEventCount': 575,
      'lastPollResponseChars': 98000,
      'maxPollRpcMicros': 4100,
      'maxPollDecodeMicros': 1300,
      'maxPollParseMicros': 900,
      'maxPollDispatchMicros': 780,
      'pollDuplicatesDropped': 0,
      'pollWindowFallbacks': 0,
    },
  });
  bridge.setEnvelope('ext.sleuth.snapshot', fakeSnapshotEnvelope());
  bridge.setEnvelope('ext.sleuth.issues', {
    'connectionMode': 'basic',
    'schemaVersion': 1,
    'sessionUuid': 'fake-uuid',
    // Same VM link as the diagnose envelope: a basic session whose VM is
    // connected but has had no VM-tier frame verdict yet.
    'data': {'issues': fullFakeIssues(), 'vmConnected': true},
  });
  bridge.setEnvelope('ext.sleuth.routeHealth', {
    'connectionMode': 'basic',
    'schemaVersion': 1,
    'sessionUuid': 'fake-uuid',
    'data': {'routes': <Map<String, Object?>>[]},
  });
  bridge.setEnvelope('ext.sleuth.explain', {
    'connectionMode': 'basic',
    'schemaVersion': 1,
    'sessionUuid': 'fake-uuid',
    'data': {
      'stableId': 'jank_detected',
      'canonical': 'jank_detected',
      'explanation': {
        'displayName': 'Jank Detected',
        'category': 'build',
        'whatItIs': 'desc',
        'whyItMatters': 'why',
        'howToFix': 'fix',
      },
    },
  });
  bridge.setEnvelope('ext.sleuth.encyclopedia', {
    'connectionMode': 'basic',
    'schemaVersion': 1,
    'sessionUuid': 'fake-uuid',
    'data': {
      'count': 2,
      'entries': {
        'jank_detected': {'displayName': 'Jank Detected'},
        'heap_growing': {'displayName': 'Heap Growing'},
      },
    },
  });
  bridge.setEnvelope('ext.sleuth.causalGraph', {
    'connectionMode': 'basic',
    'schemaVersion': 1,
    'sessionUuid': 'fake-uuid',
    'data': {
      'count': 1,
      'rules': [
        {'trigger': 'setstate_scope', 'effect': 'heavy_compute'},
      ],
    },
  });
  return bridge;
}
