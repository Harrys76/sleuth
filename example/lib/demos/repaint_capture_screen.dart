import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:sleuth/sleuth.dart';

import 'capture_driver.dart';

// Capture helper for the runtimeVerified `excessive_repaint.warning`
// bracket. The detector measures the share of UI-thread wall time spent
// inside PAINT scopes per ~1 s window, so the workload varies paint cost
// per frame at a fixed frame rate.
//
// 32 tiles of distinct widget types, each behind its own
// `RepaintBoundary`, repaint every frame through one shared notifier
// ([CapturePaintLoad]) passed as `CustomPainter.repaint`: no widget
// rebuilds, so BUILD stays flat and `rebuild_activity` does not fire
// inside the repaint captures. The knob `ops` is the number of
// `TextPainter` layouts per frame across all tiles: tile `i` lays out and
// draws `ops ~/ 32` texts, plus one more when `i < ops % 32`. Every text
// carries the current tick, so no paragraph cache hits and the cost lands
// in PAINT recording rather than on the raster thread.
//
// Each leg runs a 3 s calibration pre-pass at a known `ops`, reads the
// detector's measured share, scales `ops` to the leg target (below
// 0.5 t, at 1.25 t, above 2.1 t of the live threshold t =
// `paintTimePercentThreshold`, default 10 %), stops, drains the
// timeline, resets the detector, idles 1.5 s, and records a 4 s scenario;
// a peak outside the band gets up to four rescaled retries.
// Legs are started from the buttons or from `ext.sleuthDemo.captureLeg`.

/// Number of distinct widget runtime types (`_PT00`..`_PT31`) the
/// workload mounts. Pinned to the count of class declarations at the
/// bottom of this file.
const int _kTileCount = 32;

/// Leg targets as factors of the warning threshold.
const Map<String, double> _legFactors = {
  'below': 0.5,
  'at': 1.25,
  'above': 2.1,
};

/// `ops` the calibration pre-pass runs at (one layout per tile).
const int _calibrationOps = 32;

/// `ops` limits of the workload.
const int _minOps = 1;
const int _maxOps = 131072;

const Duration _workloadDuration = Duration(seconds: 4);

/// Driver key for this screen.
const String _detectorKey = 'repaint';

class RepaintCaptureScreen extends StatefulWidget {
  const RepaintCaptureScreen({super.key});

  @override
  State<RepaintCaptureScreen> createState() => _RepaintCaptureScreenState();
}

class _RepaintCaptureScreenState extends State<RepaintCaptureScreen> {
  /// Current `ops`, or null while no workload runs.
  final ValueNotifier<int?> _ops = ValueNotifier<int?>(null);

  @override
  void initState() {
    super.initState();
    CaptureDriver.instance.register(_detectorKey, _runLeg);
  }

  @override
  void dispose() {
    CaptureDriver.instance.unregister(_detectorKey, _runLeg);
    _ops.dispose();
    super.dispose();
  }

  Future<void> _runLeg(String tier, String role) async {
    final driver = CaptureDriver.instance;
    final detector = Sleuth.repaintDetector;
    final factor = _legFactors[role];
    if (detector == null || tier != 'warning' || factor == null) {
      driver.fail(
        detector == null
            ? 'Sleuth.repaintDetector is null (Sleuth.init() with '
                  'captureMode=true required)'
            : 'unknown leg $tier/$role (excessive_repaint brackets the '
                  'warning tier only)',
      );
      return;
    }
    final threshold = detector.paintTimePercentThreshold;
    await runTimeShareLeg(
      leg: TimeShareLeg(
        detector: _detectorKey,
        stableId: 'excessive_repaint',
        tier: tier,
        role: role,
        scenario: 'excessive_repaint_$role',
        tierThreshold: threshold,
        targetPercent: threshold * factor,
        knobName: 'ops',
        calibrationKnob: _calibrationOps,
        minKnob: _minOps,
        maxKnob: _maxOps,
        workloadDuration: _workloadDuration,
      ),
      startWorkload: (ops) {
        if (mounted) _ops.value = ops;
      },
      stopWorkload: () {
        if (mounted) _ops.value = null;
      },
      readPeak: () => detector.peakObservedPaintPercent,
      resetDetector: detector.resetCaptureState,
      isActive: () => mounted,
    );
  }

  void _onRunLeg(String role) {
    if (!CaptureDriver.instance.begin('$_detectorKey/warning/$role')) return;
    _runLeg('warning', role);
  }

  @override
  Widget build(BuildContext context) {
    final capture = Sleuth.diagnoseCaptureState();
    return Scaffold(
      appBar: AppBar(title: const Text('Repaint capture helper')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!capture.captureMode || !capture.vmConnected)
              CapturePreflightBanner(
                captureMode: capture.captureMode,
                vmConnected: capture.vmConnected,
              ),
            const Text(
              'Repaints 32 tiles every frame with a variable number of '
              'text layouts spread across them, so PAINT takes a chosen '
              'share of UI-thread time. Legs bracket excessive_repaint: '
              'warning above 10 % '
              '(default).',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 8),
            ValueListenableBuilder<int?>(
              valueListenable: _ops,
              builder: (_, ops, _) => ops == null
                  ? const SizedBox(height: 48)
                  : _RunningWorkload(ops: ops),
            ),
            CaptureLegPanel(
              tier: 'warning',
              tiers: const ['warning'],
              onTierChanged: (_) {},
              onRunLeg: _onRunLeg,
            ),
          ],
        ),
      ),
    );
  }
}

/// Owns the shared [CapturePaintLoad] and its per-frame Ticker while a
/// workload runs; an `ops` change updates the load in place.
class _RunningWorkload extends StatefulWidget {
  const _RunningWorkload({required this.ops});

  final int ops;

  @override
  State<_RunningWorkload> createState() => _RunningWorkloadState();
}

class _RunningWorkloadState extends State<_RunningWorkload>
    with SingleTickerProviderStateMixin {
  late final CapturePaintLoad _load = CapturePaintLoad(ops: widget.ops);
  late final Ticker _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  void _onTick(Duration elapsed) {
    _load.tick();
  }

  @override
  void didUpdateWidget(_RunningWorkload oldWidget) {
    super.didUpdateWidget(oldWidget);
    _load.ops = widget.ops;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _load.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CapturePaintWorkload(load: _load);
}

/// Shared repaint driver for the 32 workload tiles: [tick] repaints every
/// tile without rebuilding any widget; [ops] is the number of text
/// layouts per frame across all tiles.
@visibleForTesting
class CapturePaintLoad extends ChangeNotifier {
  CapturePaintLoad({required this.ops});

  /// Text layouts drawn per frame across all tiles.
  int ops;

  /// Text layouts tile [index] draws per paint: `ops ~/ 32`, plus one for
  /// the first `ops % 32` tiles.
  int opsForTile(int index) =>
      ops ~/ _kTileCount + (index < ops % _kTileCount ? 1 : 0);

  /// Number of [tick] calls since construction; painted into every text
  /// so no layout is served from a cache.
  int ticks = 0;

  /// Paint calls across all tiles since construction.
  int paintCalls = 0;

  /// Requests one repaint of every tile.
  void tick() {
    ticks++;
    notifyListeners();
  }
}

/// The 32-tile paint workload driven by [load].
@visibleForTesting
class CapturePaintWorkload extends StatelessWidget {
  const CapturePaintWorkload({super.key, required this.load});

  final CapturePaintLoad load;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: Wrap(
        spacing: 2,
        runSpacing: 2,
        children: [for (var i = 0; i < _kTileCount; i++) _tile(i)],
      ),
    );
  }

  Widget _tile(int index) {
    // Switch is the only Dart-friendly way to map an int to a distinct
    // widget runtime type.
    switch (index) {
      case 0:
        return _PT00(load: load, index: index);
      case 1:
        return _PT01(load: load, index: index);
      case 2:
        return _PT02(load: load, index: index);
      case 3:
        return _PT03(load: load, index: index);
      case 4:
        return _PT04(load: load, index: index);
      case 5:
        return _PT05(load: load, index: index);
      case 6:
        return _PT06(load: load, index: index);
      case 7:
        return _PT07(load: load, index: index);
      case 8:
        return _PT08(load: load, index: index);
      case 9:
        return _PT09(load: load, index: index);
      case 10:
        return _PT10(load: load, index: index);
      case 11:
        return _PT11(load: load, index: index);
      case 12:
        return _PT12(load: load, index: index);
      case 13:
        return _PT13(load: load, index: index);
      case 14:
        return _PT14(load: load, index: index);
      case 15:
        return _PT15(load: load, index: index);
      case 16:
        return _PT16(load: load, index: index);
      case 17:
        return _PT17(load: load, index: index);
      case 18:
        return _PT18(load: load, index: index);
      case 19:
        return _PT19(load: load, index: index);
      case 20:
        return _PT20(load: load, index: index);
      case 21:
        return _PT21(load: load, index: index);
      case 22:
        return _PT22(load: load, index: index);
      case 23:
        return _PT23(load: load, index: index);
      case 24:
        return _PT24(load: load, index: index);
      case 25:
        return _PT25(load: load, index: index);
      case 26:
        return _PT26(load: load, index: index);
      case 27:
        return _PT27(load: load, index: index);
      case 28:
        return _PT28(load: load, index: index);
      case 29:
        return _PT29(load: load, index: index);
      case 30:
        return _PT30(load: load, index: index);
      case 31:
        return _PT31(load: load, index: index);
      default:
        throw StateError('out-of-range tile index: $index');
    }
  }
}

abstract class _PaintTileBase extends StatelessWidget {
  const _PaintTileBase({required this.load, required this.index});
  final CapturePaintLoad load;
  final int index;

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(
      size: const Size(20, 20),
      painter: _OpsPainter(load, index),
    ),
  );
}

const TextStyle _kOpsTextStyle = TextStyle(
  fontSize: 12,
  color: Color(0xFF000000),
);

/// Lays out and draws `load.opsForTile(tileIndex)` fresh `TextPainter`s
/// on every notifier tick. The text includes the tick and tile index, so
/// every layout is new work.
class _OpsPainter extends CustomPainter {
  _OpsPainter(this.load, this.tileIndex) : super(repaint: load);

  final CapturePaintLoad load;
  final int tileIndex;

  @override
  void paint(Canvas canvas, Size size) {
    load.paintCalls++;
    final ops = load.opsForTile(tileIndex);
    final tick = load.ticks;
    for (var k = 0; k < ops; k++) {
      final painter = TextPainter(
        text: TextSpan(text: '$tick:$tileIndex:$k', style: _kOpsTextStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      painter.paint(canvas, Offset((k % 5) * 2.0, (k % 3) * 2.0));
      painter.dispose();
    }
  }

  @override
  bool shouldRepaint(_OpsPainter oldDelegate) => true;
}

// 32 distinct widget runtime types. Each subclass exists solely so
// `runtimeType` differs across instances — the debug per-widget gate
// keys paint counts on `typeName` from `DebugCreator`, so distinct types
// keep per-widget debug attribution from collapsing onto one entry.
class _PT00 extends _PaintTileBase {
  const _PT00({required super.load, required super.index});
}

class _PT01 extends _PaintTileBase {
  const _PT01({required super.load, required super.index});
}

class _PT02 extends _PaintTileBase {
  const _PT02({required super.load, required super.index});
}

class _PT03 extends _PaintTileBase {
  const _PT03({required super.load, required super.index});
}

class _PT04 extends _PaintTileBase {
  const _PT04({required super.load, required super.index});
}

class _PT05 extends _PaintTileBase {
  const _PT05({required super.load, required super.index});
}

class _PT06 extends _PaintTileBase {
  const _PT06({required super.load, required super.index});
}

class _PT07 extends _PaintTileBase {
  const _PT07({required super.load, required super.index});
}

class _PT08 extends _PaintTileBase {
  const _PT08({required super.load, required super.index});
}

class _PT09 extends _PaintTileBase {
  const _PT09({required super.load, required super.index});
}

class _PT10 extends _PaintTileBase {
  const _PT10({required super.load, required super.index});
}

class _PT11 extends _PaintTileBase {
  const _PT11({required super.load, required super.index});
}

class _PT12 extends _PaintTileBase {
  const _PT12({required super.load, required super.index});
}

class _PT13 extends _PaintTileBase {
  const _PT13({required super.load, required super.index});
}

class _PT14 extends _PaintTileBase {
  const _PT14({required super.load, required super.index});
}

class _PT15 extends _PaintTileBase {
  const _PT15({required super.load, required super.index});
}

class _PT16 extends _PaintTileBase {
  const _PT16({required super.load, required super.index});
}

class _PT17 extends _PaintTileBase {
  const _PT17({required super.load, required super.index});
}

class _PT18 extends _PaintTileBase {
  const _PT18({required super.load, required super.index});
}

class _PT19 extends _PaintTileBase {
  const _PT19({required super.load, required super.index});
}

class _PT20 extends _PaintTileBase {
  const _PT20({required super.load, required super.index});
}

class _PT21 extends _PaintTileBase {
  const _PT21({required super.load, required super.index});
}

class _PT22 extends _PaintTileBase {
  const _PT22({required super.load, required super.index});
}

class _PT23 extends _PaintTileBase {
  const _PT23({required super.load, required super.index});
}

class _PT24 extends _PaintTileBase {
  const _PT24({required super.load, required super.index});
}

class _PT25 extends _PaintTileBase {
  const _PT25({required super.load, required super.index});
}

class _PT26 extends _PaintTileBase {
  const _PT26({required super.load, required super.index});
}

class _PT27 extends _PaintTileBase {
  const _PT27({required super.load, required super.index});
}

class _PT28 extends _PaintTileBase {
  const _PT28({required super.load, required super.index});
}

class _PT29 extends _PaintTileBase {
  const _PT29({required super.load, required super.index});
}

class _PT30 extends _PaintTileBase {
  const _PT30({required super.load, required super.index});
}

class _PT31 extends _PaintTileBase {
  const _PT31({required super.load, required super.index});
}
