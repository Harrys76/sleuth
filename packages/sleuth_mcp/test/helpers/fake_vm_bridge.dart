import 'package:sleuth_mcp/sleuth_mcp.dart';

/// Build a `FakeVmBridge` pre-populated with realistic envelopes for
/// the seven `ext.sleuth.*` extensions.
FakeVmBridge defaultFakeBridge() {
  final bridge = FakeVmBridge(fakeSessionUuid: 'fake-uuid');
  bridge.setEnvelope('ext.sleuth.diagnose', {
    'connectionMode': 'basic',
    'schemaVersion': 1,
    'sessionUuid': 'fake-uuid',
    'data': {
      'packageVersion': '0.33.0',
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
      'currentIssues': <Map<String, Object?>>[],
      'frameStatsSummary': {'averageFps': 59.5, 'jankFrames': 0},
    },
  });
  bridge.setEnvelope('ext.sleuth.issues', {
    'connectionMode': 'basic',
    'schemaVersion': 1,
    'sessionUuid': 'fake-uuid',
    'data': {
      'issues': <Map<String, Object?>>[
        {'stableId': 'jank_detected', 'severity': 'warning'},
        {'stableId': 'heap_growing', 'severity': 'critical'},
      ],
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
