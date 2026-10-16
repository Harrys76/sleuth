import 'package:flutter/widgets.dart';

import '../../sleuth.dart';

/// Detects slow app startup using metrics captured by [Sleuth.init].
///
/// **Structural Detector** — operates one-shot in [prepareScan] to read
/// [Sleuth.startupMetrics]. The element-walking methods are no-ops because
/// startup timing comes from [FrameTiming] and wall-clock timestamps, not
/// the widget tree.
///
/// Fires a single issue type:
/// - **Slow TTFF** (`slow_startup_ttff`): Time-to-first-frame exceeds
///   [DetectorThresholds.startupTtffWarningMs].
///
/// The issue is one-shot — once detected on the first scan after startup,
/// it persists for the session but is not re-evaluated. This avoids stale
/// re-detection on hot restart where [Sleuth.init] guards against
/// double-measurement.
class StartupDetector extends BaseDetector with DetectorMetadataProvider {
  StartupDetector({this.ttffWarningMs = 1500, this.ttffCriticalMs = 3000})
    : super(
        type: DetectorType.startup,
        lifecycle: DetectorLifecycle.structural,
        name: 'Startup Performance',
        description: 'Detects slow app startup and phase bottlenecks',
      );

  /// Warning threshold in ms. Applied to [StartupMetrics.ttffMs], which is
  /// measured from [Sleuth.init] (Dart entry) to first-frame raster-finish.
  /// The native pre-Dart phase — iOS (`dyld`, `UIApplicationMain`,
  /// `AppDelegate`, `FlutterEngine` creation) or Android (Zygote fork,
  /// `Application.onCreate`, ContentProvider init, `FlutterActivity`,
  /// `FlutterEngine` creation), then Dart VM bootstrap + AOT snapshot
  /// load on both — is excluded by design. These thresholds are
  /// calibrated for the portion Dart code can actually move. See
  /// [StartupMetrics.engineTtffMs] for the `flutter run --trace-startup`
  /// -equivalent engine-level number.
  final int ttffWarningMs;

  /// Critical threshold in ms. Applied to [StartupMetrics.ttffMs]. See
  /// [ttffWarningMs] for the measurement-window rationale.
  final int ttffCriticalMs;

  final List<PerformanceIssue> _issues = [];
  bool _isEnabled = true;

  /// One-shot guard — once metrics are consumed, skip future scans.
  bool _consumed = false;

  @override
  List<PerformanceIssue> get issues => List.unmodifiable(_issues);

  /// Whether the detector has judged the first-frame metrics, with or
  /// without an issue. False until [Sleuth.startupMetrics] exists and a
  /// scan has read it.
  bool get evaluated => _consumed;

  @override
  bool get isEnabled => _isEnabled;

  @override
  set isEnabled(bool value) => _isEnabled = value;

  @override
  void prepareScan(BuildContext context) {
    // One-shot: only evaluate startup metrics once.
    if (_consumed) return;

    final metrics = Sleuth.startupMetrics;
    if (metrics == null) {
      return; // init() not called or first frame not yet rendered
    }

    _consumed = true;
    _issues.clear();

    _checkTtff(metrics);
  }

  void _checkTtff(StartupMetrics metrics) {
    final ttff = metrics.ttffMs;
    if (ttff == null) return;

    if (ttff < ttffWarningMs) return;

    final severity = ttff >= ttffCriticalMs
        ? IssueSeverity.critical
        : IssueSeverity.warning;

    final (hint, effort) = FixHintBuilder.slowStartupTtff(
      ttffMs: ttff,
      dominantPhase: metrics.dominantPhase,
    );

    _issues.add(
      PerformanceIssue(
        stableId: 'slow_startup_ttff',
        severity: severity,
        category: IssueCategory.startup,
        confidence: IssueConfidence.confirmed,
        title: 'Slow Startup: ${ttff.toStringAsFixed(0)} ms to first frame',
        detail: _buildTtffDetail(metrics),
        fixHint: hint,
        fixEffort: effort,
        observationSource: ObservationSource.structural,
        confidenceReason:
            'Measured from Sleuth.init() to the first FrameTiming raster '
            'end with SchedulerBinding.addTimingsCallback',
        detectedAt: DateTime.now(),
        extraTraceArgs: {'observedTtffMs': ttff.toStringAsFixed(1)},
      ),
    );
  }

  String _buildTtffDetail(StartupMetrics metrics) {
    final buffer = StringBuffer();
    buffer.writeln(
      'Time to first frame: ${metrics.ttffMs!.toStringAsFixed(0)} ms.',
    );

    if (metrics.ttiMs != null) {
      buffer.writeln(
        'Time to interactive: ${metrics.ttiMs!.toStringAsFixed(0)} ms.',
      );
    }

    if (metrics.firstFrameTotalMs != null) {
      buffer.writeln();
      buffer.writeln('First frame breakdown:');
      if (metrics.firstFrameVsyncOverheadMs != null) {
        buffer.writeln(
          '  Vsync overhead: '
          '${metrics.firstFrameVsyncOverheadMs!.toStringAsFixed(1)} ms',
        );
      }
      if (metrics.firstFrameBuildMs != null) {
        buffer.writeln(
          '  Build: '
          '${metrics.firstFrameBuildMs!.toStringAsFixed(1)} ms',
        );
      }
      if (metrics.firstFrameRasterMs != null) {
        buffer.writeln(
          '  Raster: '
          '${metrics.firstFrameRasterMs!.toStringAsFixed(1)} ms',
        );
      }
      buffer.writeln(
        '  Total: '
        '${metrics.firstFrameTotalMs!.toStringAsFixed(1)} ms',
      );

      // Always show dominant phase from StartupMetrics.
      final dominantPhase = metrics.dominantPhase;
      if (dominantPhase != 'unknown' && dominantPhase != 'balanced') {
        final pct = metrics.dominantPhasePercent;
        buffer.writeln();
        buffer.writeln(
          'Dominant phase: $dominantPhase '
          '(${pct.toStringAsFixed(0)}%)',
        );
      }
    }

    if (metrics.vmFirstBuildScopeMs != null ||
        metrics.vmFirstFlushLayoutMs != null ||
        metrics.vmFirstFlushPaintMs != null ||
        metrics.vmFirstRasterMs != null) {
      buffer.writeln();
      buffer.writeln('VM timeline sub-phases:');
      if (metrics.vmFirstBuildScopeMs != null) {
        buffer.writeln(
          '  buildScope: '
          '${metrics.vmFirstBuildScopeMs!.toStringAsFixed(1)} ms',
        );
      }
      if (metrics.vmFirstFlushLayoutMs != null) {
        buffer.writeln(
          '  flushLayout: '
          '${metrics.vmFirstFlushLayoutMs!.toStringAsFixed(1)} ms',
        );
      }
      if (metrics.vmFirstFlushPaintMs != null) {
        buffer.writeln(
          '  flushPaint: '
          '${metrics.vmFirstFlushPaintMs!.toStringAsFixed(1)} ms',
        );
      }
      if (metrics.vmFirstRasterMs != null) {
        buffer.writeln(
          '  raster: '
          '${metrics.vmFirstRasterMs!.toStringAsFixed(1)} ms',
        );
      }
    }

    // Engine-level startup phases (direct capture + VM extraction).
    final hasEngineData =
        metrics.frameworkInitMs != null ||
        metrics.preDartOverheadMs != null ||
        metrics.engineTtffMs != null;
    if (hasEngineData) {
      buffer.writeln();
      buffer.writeln('Engine startup phases:');
      if (metrics.frameworkInitMs != null) {
        buffer.writeln(
          '  Framework init: '
          '${metrics.frameworkInitMs!.toStringAsFixed(1)} ms',
        );
      }
      if (metrics.preDartOverheadMs != null) {
        buffer.writeln(
          '  Pre-Dart overhead: '
          '${metrics.preDartOverheadMs!.toStringAsFixed(1)} ms',
        );
      }
      if (metrics.engineTtffMs != null) {
        buffer.writeln(
          '  Engine TTFF: '
          '${metrics.engineTtffMs!.toStringAsFixed(1)} ms',
        );
      }
    }

    return buffer.toString().trimRight();
  }

  @override
  void checkElement(Element element) {
    // No-op: startup metrics come from FrameTiming, not the widget tree.
  }

  @override
  void finalizeScan() {
    // No-op: all work is done in prepareScan (one-shot).
  }

  @override
  void dispose() {
    _issues.clear();
  }

  @override
  DetectorMetadata get validationMetadata => const DetectorMetadata(
    tier: EvidenceTier.reproducerOnly,
    rationale:
        'Hermetic reproducer pins `slow_startup_ttff` by injecting '
        'StartupMetrics through the `@visibleForTesting` '
        '`Sleuth.setStartupMetricsForTest` hook. A ttffMs at or above '
        '`ttffWarningMs` fires at warning severity, and a ttffMs at or '
        'above `ttffCriticalMs` promotes to critical. The detector stays '
        'silent when ttffMs is below the warning threshold (strict-less), '
        'when ttffMs is null and when there are no StartupMetrics at all. '
        'A no-op second prepareScan pins the one-shot `_consumed` guard. '
        'The detector works only in `prepareScan` (its element methods are '
        'no-ops). A second group runs the real measurement with '
        '`Sleuth.init`, a test clock and a first-frame timing report '
        'through `onReportTimings`, at the 1500 and 3000 ms edges.\n\n'
        'v0.38.0 raises `slow_startup_ttff` to runtimeVerified through '
        '`perStableIdTier`, warning (1500 ms, canonical bracket) and '
        'critical (3000 ms, `additionalBrackets[0]`), each on three iPhone '
        '12 captures (iOS 17.5, Flutter 3.47.6). Each leg is a cold launch '
        'that `xcrun devicectl` starts after copying a request file that '
        'names the leg into the app container; the app blocks for the '
        'leg\'s delay between '
        '`Sleuth.init` and `runApp`. The app takes its own wall-clock '
        'reading before `Sleuth.init` and exports the first frame\'s '
        '`rasterFinishWallTime` minus that reading as the observed value. '
        'That end point is the engine\'s raster finish, not the timing '
        'report that ends the detector\'s measurement; the audit compares '
        'the two within 1 % (the detector read 0.4 to 1.0 ms more on six '
        'launches). A launch writes one record.',
    reproducerPath: 'test/validation/startup_reproducer_test.dart',
    coveredStableIds: {'slow_startup_ttff'},
    perStableIdTier: {'slow_startup_ttff': EvidenceTier.runtimeVerified},
    profileCapturePaths: [
      'test/validation/captures/startup/slow_startup_ttff_below.json',
      'test/validation/captures/startup/slow_startup_ttff_at.json',
      'test/validation/captures/startup/slow_startup_ttff_above.json',
    ],
    // The warning fires at 1500 ms. The at band is [1500, 1800] ms and
    // the above band (1800, 2850] ms. The above band ends below the
    // 3000 ms critical line, where the detector records critical instead.
    // The delay sets the time within a few ms, so the at band is narrower
    // than the 0.5 the other brackets use.
    bracketThreshold: 1500,
    bracketUnit: 'ms',
    bracketStableId: 'slow_startup_ttff',
    bracketSeverityLabel: 'warning',
    bracketAtTolerance: 0.2,
    aboveCeilingMultiplier: 1.9,
    observedAxisArgKey: 'observedTtffMs',
    observedAxisTolerance: 0.01,
    observedAxisReduction: 'max',
    bracketRequireUniqueDetectedAtMicros: true,
    coveredThresholds: {
      'slow_startup_ttff.warning',
      'slow_startup_ttff.critical',
    },
    additionalBrackets: [
      // The critical fires at 3000 ms. The at band is [3000, 3600] ms and
      // the above band (3600, 6000] ms.
      BracketSpec(
        stableId: 'slow_startup_ttff',
        severityLabel: 'critical',
        threshold: 3000,
        unit: 'ms',
        coveredThresholds: {'slow_startup_ttff.critical'},
        profileCapturePaths: [
          'test/validation/captures/startup/slow_startup_ttff_critical_below.json',
          'test/validation/captures/startup/slow_startup_ttff_critical_at.json',
          'test/validation/captures/startup/slow_startup_ttff_critical_above.json',
        ],
        atTolerance: 0.2,
        aboveCeilingMultiplier: 2.0,
        observedAxisArgKey: 'observedTtffMs',
        observedAxisTolerance: 0.01,
        observedAxisReduction: 'max',
        requireUniqueDetectedAtMicros: true,
        requireDetectorTraceRecord: true,
      ),
    ],
  );
}
