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

/// Build a `FakeVmBridge` pre-populated with realistic envelopes for
/// the seven `ext.sleuth.*` extensions.
FakeVmBridge defaultFakeBridge() {
  final bridge = FakeVmBridge(fakeSessionUuid: 'fake-uuid');
  bridge.setEnvelope('ext.sleuth.diagnose', {
    'connectionMode': 'basic',
    'schemaVersion': 1,
    'sessionUuid': 'fake-uuid',
    'data': {
      'packageVersion': '0.36.0',
      'initializedAtMicros': 0,
      'vmConnected': true,
      'captureMode': false,
      'lastCaptureExportFailure': null,
      'unboundExtensionNames': <String>[],
    },
  });
  bridge.setEnvelope('ext.sleuth.snapshot', {
    'connectionMode': 'basic',
    'schemaVersion': 1,
    'sessionUuid': 'fake-uuid',
    'data': {
      'schemaVersion': 5,
      'exportedAt': '2026-05-17T00:00:00.000Z',
      'currentIssues': fullFakeIssues(),
      'frameStatsSummary': {'averageFps': 59.5, 'jankFrames': 0},
    },
  });
  bridge.setEnvelope('ext.sleuth.issues', {
    'connectionMode': 'basic',
    'schemaVersion': 1,
    'sessionUuid': 'fake-uuid',
    'data': {
      'issues': fullFakeIssues(),
    },
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
