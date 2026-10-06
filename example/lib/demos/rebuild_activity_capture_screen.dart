// Capture screen for `RebuildDetector.rebuild_activity` runtime-verified
// brackets. The detector measures the share of UI-thread wall time spent
// inside BUILD scopes per ~1 s window, so the workload varies build cost
// per frame at a fixed element count: a Ticker rebuilds 64 leaves on
// every frame the display delivers (the share is time-based, so the
// display rate does not change what is measured), and each leaf's
// `build()` runs a deterministic `work`-iteration integer loop whose
// result goes into its child. The added cost is computation inside BUILD;
// the tree, and with it LAYOUT, PAINT and Sleuth's own structural scan,
// stays the same size at every `work`.
//
// Each leg runs a 3 s calibration pre-pass at a known `work`, reads the
// detector's measured share, and scales `work` to the leg's target, a
// factor of the live tier threshold:
//
//   warning  (threshold t = buildTimePercentThreshold, default 10 %)
//     below 0.5 t · at 1.25 t · above 2.1 t
//   critical (threshold 3 t, default 30 %)
//     below 0.8 · at 1.23 · above 2.0 × 3 t
//
// The leg then stops, drains the timeline, resets the detector, idles
// 1.5 s, and records a 6 s scenario; a peak outside the band, or an export
// with fewer in-band records than the bracket requires (two for
// critical), gets another span, up to five in all. Bands come from
// `timeShareBand`. The workload runs only while the screen is in front.
// Legs are started from the buttons or from `ext.sleuthDemo.captureLeg`.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:sleuth/sleuth.dart';

import 'capture_driver.dart';

/// One bracket leg: role and target as a factor of the tier threshold.
class _Leg {
  const _Leg(this.label, this.factor);

  final String label;
  final double factor;
}

/// Leg targets for the warning tier, as factors of the warning threshold.
const _warningLegs = <_Leg>[
  _Leg('below', 0.5),
  _Leg('at', 1.25),
  _Leg('above', 2.1),
];

/// Leg targets for the critical tier, as factors of the critical
/// threshold (3× the warning threshold).
const _criticalLegs = <_Leg>[
  _Leg('below', 0.8),
  _Leg('at', 1.23),
  _Leg('above', 2.0),
];

/// `work` the calibration pre-pass runs at.
const int _calibrationWork = 4000;

/// `work` limits of the workload.
const int _minWork = 1;
const int _maxWork = 4000000;

const Duration _workloadDuration = Duration(seconds: 6);

/// Driver key for this screen.
const String _detectorKey = 'rebuild';

class RebuildActivityCaptureScreen extends StatefulWidget {
  const RebuildActivityCaptureScreen({super.key});

  @override
  State<RebuildActivityCaptureScreen> createState() =>
      _RebuildActivityCaptureScreenState();
}

class _RebuildActivityCaptureScreenState
    extends State<RebuildActivityCaptureScreen>
    with CaptureScreenStateMixin<RebuildActivityCaptureScreen> {
  /// Current `work`, or null while no workload runs.
  final ValueNotifier<int?> _work = ValueNotifier<int?>(null);
  String _tier = 'warning';

  @override
  String get captureDetector => _detectorKey;

  @override
  void dispose() {
    _work.dispose();
    super.dispose();
  }

  @override
  Future<void> runCaptureLeg(String tier, String role) async {
    final driver = CaptureDriver.instance;
    final detector = Sleuth.rebuildDetector;
    final legs = tier == 'critical' ? _criticalLegs : _warningLegs;
    final leg = legs.where((l) => l.label == role).firstOrNull;
    if (detector == null || leg == null) {
      driver.fail(
        detector == null
            ? 'Sleuth.rebuildDetector is null (Sleuth.init() with '
                  'captureMode=true required)'
            : 'unknown leg $tier/$role',
      );
      return;
    }
    final bracket = CaptureBracket.fromMetadata(
      detector.validationMetadata,
      stableId: 'rebuild_activity',
      severityLabel: tier,
    );
    if (bracket == null) {
      driver.fail('no rebuild_activity.$tier bracket is declared');
      return;
    }
    if (mounted && _tier != tier) setState(() => _tier = tier);
    final warning = detector.buildTimePercentThreshold;
    final tierThreshold = tier == 'critical' ? warning * 3 : warning;
    final basename = tier == 'critical' ? 'critical_$role' : role;
    await runTimeShareLeg(
      leg: TimeShareLeg(
        detector: _detectorKey,
        bracket: bracket,
        tier: tier,
        role: role,
        scenario: 'rebuild_activity_$basename',
        tierThreshold: tierThreshold,
        targetPercent: tierThreshold * leg.factor,
        knobName: 'work',
        calibrationKnob: _calibrationWork,
        minKnob: _minWork,
        maxKnob: _maxWork,
        workloadDuration: _workloadDuration,
      ),
      startWorkload: (work) {
        if (mounted) _work.value = work;
      },
      stopWorkload: () {
        if (mounted) _work.value = null;
      },
      readPeak: () => detector.peakObservedBuildPercent,
      resetDetector: detector.resetCaptureState,
      isActive: () => captureInFront,
    );
  }

  void _onRunLeg(String role) {
    if (!CaptureDriver.instance.begin('$_detectorKey/$_tier/$role')) return;
    unawaited(CaptureDriver.instance.runLeg(runCaptureLeg, _tier, role));
  }

  @override
  Widget build(BuildContext context) {
    final capture = Sleuth.diagnoseCaptureState();
    return Scaffold(
      appBar: AppBar(title: const Text('RebuildActivity Capture')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CapturePreflightBanner(
              captureMode: capture.captureMode,
              vmConnected: capture.vmConnected,
              provenanceProblem: currentCaptureProvenance().problem,
            ),
            const Text(
              'Rebuilds 64 leaf widgets every frame, each running a '
              'variable amount of integer work inside build(), so BUILD '
              'takes a chosen share of UI-thread time. Legs bracket '
              'rebuild_activity: warning above 10 %, critical above 30 % '
              '(defaults).',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 8),
            ValueListenableBuilder<int?>(
              valueListenable: _work,
              builder: (_, work, _) => work == null
                  ? const SizedBox(height: 4)
                  : CaptureBuildLoad(work: work),
            ),
            CaptureLegPanel(
              tier: _tier,
              tiers: const ['warning', 'critical'],
              onTierChanged: (tier) => setState(() => _tier = tier),
              onRunLeg: _onRunLeg,
            ),
          ],
        ),
      ),
    );
  }
}

/// Leaves the build workload rebuilds every frame.
const int _kLeafCount = 64;

/// Build-cost workload: rebuilds [_kLeafCount] leaves every frame at
/// 60 Hz; each leaf's `build()` runs [work] iterations of an integer loop.
/// Every leaf ends in a zero-size box at the origin of a 4×4 box, so the
/// element count and the layout/paint inputs never change with [work].
@visibleForTesting
class CaptureBuildLoad extends StatefulWidget {
  const CaptureBuildLoad({super.key, required this.work});

  /// Loop iterations each leaf runs per build.
  final int work;

  @override
  State<CaptureBuildLoad> createState() => _CaptureBuildLoadState();
}

class _CaptureBuildLoadState extends State<CaptureBuildLoad>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  int _tick = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  void _onTick(Duration elapsed) {
    if (!mounted) return;
    setState(() => _tick++);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: 4,
      child: Stack(
        children: [
          for (var i = 0; i < _kLeafCount; i++)
            _CostLeaf(index: i, tick: _tick, work: widget.work),
        ],
      ),
    );
  }
}

/// One leaf. The parent creates a new instance each tick (carrying
/// [tick]), so the element diff never short-circuits; [build] runs a
/// deterministic [work]-iteration loop seeded by [index] and [tick] and
/// hands the result to [_CostResult] so the loop cannot be dropped.
class _CostLeaf extends StatelessWidget {
  const _CostLeaf({
    required this.index,
    required this.tick,
    required this.work,
  });

  final int index;
  final int tick;
  final int work;

  @override
  Widget build(BuildContext context) {
    var acc = index;
    for (var k = 0; k < work; k++) {
      acc = (acc * 1103515245 + k + tick) & 0x7fffffff;
    }
    return _CostResult(acc);
  }
}

/// Carries a leaf's loop result; renders one const zero-size box whose
/// render object is never dirtied.
class _CostResult extends StatelessWidget {
  const _CostResult(this.value);

  final int value;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();

  @override
  void debugFillProperties(DiagnosticPropertiesBuilder properties) {
    super.debugFillProperties(properties);
    properties.add(IntProperty('value', value));
  }
}
