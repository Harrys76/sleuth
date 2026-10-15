import 'dart:async';
import 'dart:convert';
import 'dart:ui' show FrameTiming, PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:sleuth/sleuth.dart';
// The detector is not exported; the screen reads its bracket from the
// detector's own metadata so the bands cannot drift from the audit.
// ignore: implementation_imports
import 'package:sleuth/src/detectors/frame_timing_detector.dart'
    show FrameTimingDetector;

import 'capture_driver.dart';

/// Capture helper for the `runtimeVerified` bracket on
/// `FrameTimingDetector.sustained_jank.critical`: three or more severe
/// frames among the frames the detector judged since the scenario began.
/// A frame is severe when its raster time, or its start delay (less
/// Sleuth's own share) plus its build time, is over twice the 16.7 ms
/// budget.
///
/// Each leg injects an exact number of severe frames: a ticker spins the
/// UI thread for 40 ms inside its callback on ticks 30, 50, 70 and so on,
/// 2 times for below, 3 for at and 6 for above, and stops 30 ticks after
/// the last spin. The callback runs in the frame's build phase, so each
/// spin makes one frame with more than 33.3 ms of build. The leg ends
/// within 160 frames, well inside the detector's 240-frame buffer, so no
/// spin frame is evicted before the export.
///
/// The screen judges every frame of the span itself ([isCaptureSevere]),
/// with Sleuth's share of the start delay left in, so its rule is
/// stricter than the detector's. A leg is exported only when the frames
/// the screen judged severe are exactly the spin frames, and, for at and
/// above, when the last in-span record's `observedSevereCount` equals
/// the spin count with `bufferSize` under 240. A severe frame before the
/// first spin stops the leg: an ambient severe frame is refused, never
/// subtracted.
///
/// **Procedure per leg:**
///
///   1. `cd example && fvm flutter run --profile --no-dds -d "iPhone 12" \
///         --dart-define=SLEUTH_CAPTURE_MODE=true \
///         --dart-define=SLEUTH_CAPTURE_DEVICE="iPhone 12"`. The VM
///      service must be connected (VM+), because the export reads the
///      detector's records from the VM timeline.
///   2. Open Capture Helpers, then FrameTiming (sustained_jank). Check
///      that the refresh-rate line shows 60 Hz and the provenance line
///      names the device, OS and Flutter version. A red banner lists
///      anything that blocks a leg.
///   3. Tap a leg and wait for "capture stashed" in the log.
///   4. Tap **Export last leg** and save the clipboard text as
///      `sustained_jank_<role>.json` under
///      `test/validation/captures/frame_timing/`.
class FrameTimingSustainedJankCaptureScreen extends StatefulWidget {
  const FrameTimingSustainedJankCaptureScreen({
    super.key,
    this.captureModeOverride,
    this.provenanceCheck = currentCaptureProvenance,
    this.vmConnected = _sleuthVmConnected,
  });

  /// Capture mode for tests. Null reads the build's
  /// `SLEUTH_CAPTURE_MODE` dart-define.
  @visibleForTesting
  final bool? captureModeOverride;

  /// Where the screen reads the provenance its exports stamp.
  @visibleForTesting
  final CaptureProvenanceCheck Function() provenanceCheck;

  /// Whether Sleuth's VM service client is connected, which the export
  /// needs to read the detector's records.
  @visibleForTesting
  final bool Function() vmConnected;

  @override
  State<FrameTimingSustainedJankCaptureScreen> createState() =>
      _FrameTimingSustainedJankCaptureScreenState();
}

bool _sleuthVmConnected() => Sleuth.diagnoseCaptureState().vmConnected;

/// Frame budget the screen judges against. The pre-flight requires a
/// 60 Hz display, and capture mode keeps the detector's budget fixed at
/// the same 16,667 µs.
const int sustainedJankCaptureBudgetUs = 16667;

/// Whether [timing] is severe by the screen's rule: raster time, or the
/// start delay (vsync start to build start) plus build time, over twice
/// [budgetUs]. The detector subtracts Sleuth's own share of the start
/// delay first, so every frame it judges severe is severe here too.
bool isCaptureSevere(
  FrameTiming timing, {
  int budgetUs = sustainedJankCaptureBudgetUs,
}) {
  final limit = 2 * budgetUs;
  if (timing.rasterDuration.inMicroseconds > limit) return true;
  final delayUs = timing.vsyncOverhead.inMicroseconds;
  return (delayUs < 0 ? 0 : delayUs) + timing.buildDuration.inMicroseconds >
      limit;
}

// Spin per injected frame. With a 1 to 3 ms baseline build it puts the
// frame clear of the 33.3 ms severe line.
const _spinMs = 40;

// Ticks before the first spin, between spins and after the last one.
// The first gap lets the leg's start frames settle; 20 ticks between
// spins keep each spin frame and the frame after it apart in the log.
const _firstSpinTick = 30;
const _spinSpacingTicks = 20;
const _tailTicks = 30;

// Idle time after `markScenarioBegin` before the ticker starts.
const _settleMs = 500;

// Wait after the ticker stops, so the last frames' timings reach Sleuth
// (profile builds report them in batches about every 100 ms).
const _postScenarioBarrierMs = 200;

// Longest a leg may wait for the ticker to finish before it gives up.
const _tickerTimeout = Duration(seconds: 10);

// Attempts per leg before the screen asks for a restart.
const _maxAttemptsPerLeg = 5;

// The bracket is calibrated on a 60 Hz display.
const _expected60HzMin = 59.0;
const _expected60HzMax = 61.0;

/// One capture leg and the severe frames it injects.
enum SustainedJankLeg {
  below(spins: 2),
  at(spins: 3),
  above(spins: 6);

  const SustainedJankLeg({required this.spins});

  /// Severe frames the leg injects.
  final int spins;

  /// `below`, `at` or `above`.
  String get label => name;

  /// Scenario name, which is also the capture's file basename.
  String get scenario => 'frame_timing_sustained_jank_$label';

  /// Ticker tick of spin [index] (from 0).
  int spinTick(int index) => _firstSpinTick + index * _spinSpacingTicks;

  /// Tick at which the ticker stops.
  int get stopTick => spinTick(spins - 1) + _tailTicks;
}

/// The bracket every leg is judged against, read from [metadata] (the
/// detector's `validationMetadata`).
CaptureBracket? sustainedJankBracket(DetectorMetadata metadata) =>
    CaptureBracket.fromMetadata(
      metadata,
      stableId: 'sustained_jank',
      severityLabel: 'critical',
    );

/// Why [leg] cannot be exported given what the screen saw, or null when
/// the frames match the injection. [spinFrames] are the engine frame
/// numbers of the spin frames, [severeFrames] those of the frames the
/// screen judged severe, and [ambientSevere] the severe frames before the
/// first spin. A frame number of -1 means the engine did not report it;
/// then only the counts are compared.
LegRefusal? sustainedJankFrameRefusal(
  SustainedJankLeg leg, {
  required List<int> spinFrames,
  required List<int> severeFrames,
  required int ambientSevere,
}) {
  if (ambientSevere > 0) {
    return (
      verdict: 'OUT-OF-BAND',
      reason: '$ambientSevere severe frame(s) before the first spin',
    );
  }
  if (spinFrames.length != leg.spins) {
    return (
      verdict: 'UNMEASURED',
      reason: '${spinFrames.length} of ${leg.spins} spins ran',
    );
  }
  if (severeFrames.length != leg.spins) {
    return (
      verdict: 'OUT-OF-BAND',
      reason:
          '${severeFrames.length} severe frame(s) in the span; the leg '
          'injects ${leg.spins}',
    );
  }
  final numbered = !spinFrames.contains(-1) && !severeFrames.contains(-1);
  if (numbered && !(Set.of(spinFrames).containsAll(severeFrames))) {
    return (
      verdict: 'OUT-OF-BAND',
      reason:
          'severe frames $severeFrames are not the spin frames '
          '$spinFrames',
    );
  }
  return null;
}

/// Why an at or above [leg]'s capture [json] cannot be exported given
/// its last in-span `sustained_jank.critical` record, or null when that
/// record's `observedSevereCount` equals the spin count and its
/// `bufferSize` is under 240, so the detector counted every injected
/// frame and evicted none. Below legs carry no record and return null.
LegRefusal? sustainedJankLastRecordRefusal(
  String json,
  SustainedJankLeg leg, {
  required CaptureBracket bracket,
}) {
  if (leg == SustainedJankLeg.below) return null;
  final List<Object?> events;
  final int begin;
  final int end;
  try {
    final root = jsonDecode(json);
    final raw = root is Map ? root['traceEvents'] : null;
    if (raw is! List) {
      throw const FormatException('capture has no traceEvents array');
    }
    events = raw;
    (begin, end) = ProfileCaptureSchema.findScenarioSpan(events, leg.scenario);
  } on FormatException catch (e) {
    return (verdict: 'OUT-OF-BAND', reason: 'capture unreadable: $e');
  }
  int? lastTs;
  Map<Object?, Object?>? lastArgs;
  for (final event in events) {
    if (event is! Map || event['name'] != bracket.eventName) continue;
    // Instant events only, as the capture audit reads them.
    final ph = event['ph'];
    if (ph != 'i' && ph != 'I' && ph != 'n') continue;
    final ts = event['ts'];
    if (ts is! num || ts < begin || ts > end) continue;
    // The latest record; a tie goes to the later one in file order.
    if (lastTs != null && ts < lastTs) continue;
    lastTs = ts.toInt();
    final args = event['args'];
    final dartArgs = args is Map ? args['Dart Arguments'] : null;
    lastArgs = dartArgs is Map ? {...args as Map, ...dartArgs} : args as Map?;
  }
  if (lastTs == null) {
    return (verdict: 'OUT-OF-BAND', reason: 'no in-span ${bracket.eventName}');
  }
  int? read(String key) => switch (lastArgs?[key]) {
    final num n => n.toInt(),
    final String s => int.tryParse(s.trim()),
    _ => null,
  };
  final count = read('observedSevereCount');
  final buffer = read('bufferSize');
  if (count != leg.spins) {
    return (
      verdict: 'OUT-OF-BAND',
      reason:
          'last in-span observedSevereCount is $count; the leg injects '
          '${leg.spins}',
    );
  }
  if (buffer == null || buffer >= 240) {
    return (
      verdict: 'OUT-OF-BAND',
      reason:
          'last in-span bufferSize is $buffer; a full buffer may have '
          'evicted a spin frame',
    );
  }
  return null;
}

/// Timing of one frame of the span, kept for the log.
typedef _FrameCost = ({int delayUs, int buildUs, int rasterUs, bool severe});

class _FrameTimingSustainedJankCaptureScreenState
    extends State<FrameTimingSustainedJankCaptureScreen>
    with SingleTickerProviderStateMixin {
  // One ticker for the State, started and stopped per leg: the mixin
  // allows only one `createTicker` call.
  late final Ticker _ticker;
  bool _busy = false;
  double? _refreshRate;
  bool _refreshRateOk = false;

  SustainedJankLeg? _attemptLeg;
  int _attempts = 0;

  SustainedJankLeg? _stashedLeg;
  String? _stashedJson;

  final List<String> _log = [];

  // Per-leg state, filled by the ticker and the timings callback.
  final List<int> _spinFrames = [];
  final List<int> _severeFrames = [];
  final Map<int, _FrameCost> _frames = {};
  int _tickCount = 0;
  int _spinsRun = 0;
  int _ambientSevere = 0;
  Completer<void>? _legDone;

  late final CaptureProvenanceCheck _provenance;

  bool get _captureModeOn =>
      widget.captureModeOverride ??
      const bool.fromEnvironment('SLEUTH_CAPTURE_MODE');

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _provenance = widget.provenanceCheck();
    // The display may not be known in initState on iOS.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final rate = View.maybeOf(context)?.display.refreshRate;
      setState(() {
        _refreshRate = rate;
        _refreshRateOk =
            rate != null &&
            rate >= _expected60HzMin &&
            rate <= _expected60HzMax;
        _log.add(
          rate == null
              ? 'Pre-flight: no view, so the refresh rate is unknown. '
                    'Re-open the screen.'
              : 'Pre-flight: ${rate.toStringAsFixed(1)} Hz, '
                    '${_refreshRateOk ? 'OK' : 'REJECTED (needs 60 Hz)'}',
        );
      });
    });
  }

  @override
  void dispose() {
    // Lets a running leg reach its `mounted` check now, so its cleanup
    // ends the scenario and restores the streams before another capture
    // can start, instead of after the ticker timeout.
    final done = _legDone;
    if (done != null && !done.isCompleted) done.complete();
    _ticker.dispose();
    _stopTimings();
    super.dispose();
  }

  // Whether [_onTimings] is registered; removing an unregistered
  // callback fails an assert in debug builds.
  bool _timingsRegistered = false;

  void _stopTimings() {
    if (!_timingsRegistered) return;
    _timingsRegistered = false;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      final severe = isCaptureSevere(timing);
      final number = timing.frameNumber;
      _frames[number] = (
        delayUs: timing.vsyncOverhead.inMicroseconds,
        buildUs: timing.buildDuration.inMicroseconds,
        rasterUs: timing.rasterDuration.inMicroseconds,
        severe: severe,
      );
      if (!severe) continue;
      _severeFrames.add(number);
      // Timings arrive after their frame, so a severe frame reported
      // before any spin ran, or numbered below the first spin frame, is
      // ambient.
      final firstSpin = _spinFrames.isEmpty ? null : _spinFrames.first;
      final beforeFirstSpin =
          _spinsRun == 0 ||
          (firstSpin != null &&
              firstSpin >= 0 &&
              number >= 0 &&
              number < firstSpin);
      if (beforeFirstSpin) {
        _ambientSevere++;
        final done = _legDone;
        if (done != null && !done.isCompleted) done.complete();
      }
    }
  }

  void _onTick(Duration _) {
    final leg = _attemptLeg;
    final done = _legDone;
    if (leg == null || done == null || done.isCompleted) return;
    _tickCount++;
    if (_spinsRun < leg.spins && _tickCount == leg.spinTick(_spinsRun)) {
      _spinsRun++;
      final sw = Stopwatch()..start();
      while (sw.elapsedMilliseconds < _spinMs) {
        // Busy-wait inside the frame's build phase.
      }
      // The engine updates the frame number after the begin-frame
      // callbacks, so read it once the frame has drawn.
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _spinFrames.add(PlatformDispatcher.instance.frameData.frameNumber);
      });
    }
    if (_tickCount >= leg.stopTick) done.complete();
  }

  void _say(String line) {
    if (!mounted) return;
    setState(() => _log.add(line));
  }

  Future<void> _runLeg(SustainedJankLeg leg) async {
    if (_busy) return;
    final label = leg.label;
    if (!_refreshRateOk) {
      _say(
        '[$label] ABORT: refresh rate is '
        '${_refreshRate?.toStringAsFixed(1) ?? 'unknown'} Hz, not 60 Hz.',
      );
      return;
    }
    if (!_captureModeOn) {
      _say(
        '[$label] ABORT: capture mode is off. Relaunch with '
        '--dart-define=SLEUTH_CAPTURE_MODE=true.',
      );
      return;
    }
    if (!widget.vmConnected()) {
      _say(
        '[$label] ABORT: VM service not connected. Run a profile build '
        'with --no-dds so Sleuth can attach.',
      );
      return;
    }
    final refusal = provenanceRefusal(label, check: widget.provenanceCheck);
    if (refusal != null) {
      _say(refusal);
      return;
    }
    final bracket = sustainedJankBracket(
      FrameTimingDetector().validationMetadata,
    );
    if (bracket == null) {
      _say(
        '[$label] ABORT: FrameTimingDetector declares no '
        'sustained_jank critical bracket.',
      );
      return;
    }
    if (_attemptLeg != leg) _attempts = 0;
    if (_attempts >= _maxAttemptsPerLeg) {
      _say(
        '[$label] $_maxAttemptsPerLeg attempts used. Switch leg or restart '
        'the app.',
      );
      return;
    }
    _attempts++;
    _attemptLeg = leg;
    _spinFrames.clear();
    _severeFrames.clear();
    _frames.clear();
    _spinsRun = 0;
    _ambientSevere = 0;
    _tickCount = 0;
    final done = _legDone = Completer<void>();
    setState(() {
      _busy = true;
      _stashedLeg = null;
      _stashedJson = null;
      _log.add(
        '[$label] attempt $_attempts/$_maxAttemptsPerLeg: ${leg.spins} '
        'spins of $_spinMs ms, band ${bracket.bandText(label)} frames',
      );
    });

    var streamsSuspended = false;
    var scenarioOpen = false;
    try {
      // The span is short, but a full stream set can still roll the
      // scenario markers out of the VM ring buffer; restored in finally.
      // Marked first: a suspension that times out may still land later.
      streamsSuspended = true;
      await withCallTimeout(
        Sleuth.suspendNonEssentialTimelineStreams(),
        'suspendNonEssentialTimelineStreams',
      );
      if (!mounted) return;
      // Registered in the same synchronous block as markScenarioBegin, so
      // the screen and the detector judge the same timing batches.
      SchedulerBinding.instance.addTimingsCallback(_onTimings);
      _timingsRegistered = true;
      Sleuth.markScenarioBegin(leg.scenario);
      scenarioOpen = true;

      await Future<void>.delayed(const Duration(milliseconds: _settleMs));
      if (!mounted) return;
      if (_ambientSevere == 0) {
        _ticker.start();
        try {
          await done.future.timeout(_tickerTimeout);
        } on TimeoutException {
          // Judged below as missing spins.
        }
      }
      if (_ticker.isActive) _ticker.stop();
      if (!mounted) return;

      await Future<void>.delayed(
        const Duration(milliseconds: _postScenarioBarrierMs),
      );
      if (!mounted) return;
      await Sleuth.flushTimelineNow(timeout: const Duration(seconds: 2));
      if (!mounted) return;
      Sleuth.markScenarioEnd(leg.scenario);
      scenarioOpen = false;
      _stopTimings();

      _logSpinFrames(label);
      final frameRefusal = sustainedJankFrameRefusal(
        leg,
        spinFrames: List.of(_spinFrames),
        severeFrames: List.of(_severeFrames),
        ambientSevere: _ambientSevere,
      );
      if (frameRefusal != null) {
        _say('[$label] ${frameRefusal.verdict}: ${frameRefusal.reason}');
        return;
      }

      // The end marker must reach the VM buffer before the export reads it.
      await Future<void>.delayed(const Duration(milliseconds: 800));
      if (!mounted) return;
      streamsSuspended = false;
      await withCallTimeout(
        Sleuth.resumeAllTimelineStreams(),
        'resumeAllTimelineStreams',
      );
      if (!mounted) return;

      final provenance = requireCaptureProvenance(
        check: widget.provenanceCheck,
      );
      String? json;
      String? composeFailure;
      try {
        json = await withCallTimeout(
          Sleuth.exportCaptureJson(
            scenario: leg.scenario,
            role: label,
            magnitudeMin: leg.spins > 1 ? leg.spins - 1.0 : 1.0,
            magnitudeObserved: leg.spins.toDouble(),
            magnitudeMax: leg.spins + 1.0,
            unit: 'frames',
            device: provenance.device,
            deviceOsVersion: provenance.deviceOsVersion,
            flutterVersion: provenance.flutterVersion,
            captureCommand: provenance.captureCommand,
            bracketStableId: 'sustained_jank',
            bracketSeverityLabel: 'critical',
            // The count comes from FrameTiming, not a VM timeline event.
            magnitudeSourceEventName: '',
          ),
          'exportCaptureJson',
        );
        if (json == null) {
          composeFailure =
              Sleuth.lastCaptureExportFailure ??
              'exportCaptureJson gave no reason';
        }
      } catch (e) {
        composeFailure = '$e';
      }
      if (!mounted) return;
      if (json == null) {
        _say('[$label] capture FAILED to compose: $composeFailure');
        return;
      }
      final check = checkCaptureJson(
        json,
        bracket: bracket,
        role: label,
        observed: leg.spins,
        unit: 'frames',
      );
      final exportRefusal =
          recordRefusal(check, role: label, bracket: bracket) ??
          sustainedJankLastRecordRefusal(json, leg, bracket: bracket);
      if (exportRefusal != null) {
        _say('[$label] ${exportRefusal.verdict}: ${exportRefusal.reason}');
        return;
      }
      final stashed = json;
      setState(() {
        _stashedLeg = leg;
        _stashedJson = stashed;
        _attemptLeg = null;
        _log.add(
          '[$label] capture stashed (${stashed.length} chars). Tap '
          '"Export last leg" to copy it.',
        );
      });
    } on CaptureProvenanceUnavailable catch (e) {
      _say('[$label] ABORT: capture provenance: ${e.problem}.');
    } catch (e) {
      // A flush past its 2 s limit, a VM call past its limit, or any other
      // failure still ends the leg with an outcome line.
      _say('[$label] FAILED: $e. Tap the leg again.');
    } finally {
      if (_ticker.isActive) _ticker.stop();
      _stopTimings();
      final pending = _legDone;
      if (pending != null && !pending.isCompleted) pending.complete();
      _legDone = null;
      if (scenarioOpen) {
        // A throw here must not replace the leg's own outcome.
        try {
          Sleuth.markScenarioEnd(leg.scenario);
        } catch (e) {
          _say('[$label] markScenarioEnd on cleanup: $e');
        }
      }
      if (streamsSuspended) {
        // Bounded, so an unanswered VM call cannot keep the screen busy.
        try {
          await withCallTimeout(
            Sleuth.resumeAllTimelineStreams(),
            'resumeAllTimelineStreams',
          );
        } catch (e) {
          _say('[$label] resumeAllTimelineStreams on cleanup: $e');
        }
      }
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Logs each spin frame and the frame after it, so a refused leg shows
  /// which frame went wrong.
  void _logSpinFrames(String label) {
    String cost(int number) {
      final f = _frames[number];
      if (f == null) return '#$number not reported';
      return '#$number delay ${(f.delayUs / 1000).toStringAsFixed(1)} ms, '
          'build ${(f.buildUs / 1000).toStringAsFixed(1)} ms, '
          'raster ${(f.rasterUs / 1000).toStringAsFixed(1)} ms'
          '${f.severe ? ', SEVERE' : ''}';
    }

    for (final number in _spinFrames) {
      _say(
        '[$label] spin ${cost(number)}; next '
        '${number < 0 ? '(no frame number)' : cost(number + 1)}',
      );
    }
    _say(
      '[$label] ${_frames.length} frames, ${_severeFrames.length} severe, '
      '$_ambientSevere before the first spin',
    );
  }

  Future<void> _exportLastLeg() async {
    final leg = _stashedLeg;
    final json = _stashedJson;
    if (leg == null || json == null) {
      _say('Export: no stashed leg. Run a leg until "capture stashed".');
      return;
    }
    try {
      await Clipboard.setData(ClipboardData(text: json));
      _say(
        '[${leg.label}] copied ${json.length} chars. Save as '
        'sustained_jank_${leg.label}.json under '
        'test/validation/captures/frame_timing/.',
      );
    } catch (e) {
      _say('[${leg.label}] clipboard copy FAILED: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final capture = Sleuth.diagnoseCaptureState();
    final ready =
        _refreshRateOk &&
        _captureModeOn &&
        _provenance.provenance != null &&
        !_busy;
    final rate = _refreshRate;
    final stamp = _provenance.provenance;
    return Scaffold(
      appBar: AppBar(title: const Text('sustained_jank capture')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Natural height up to three quarters of the body, scrolling
              // past that, so a long pre-flight reason or a large text
              // scale cannot overflow.
              Flexible(
                flex: 3,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      CapturePreflightBanner(
                        captureMode: capture.captureMode,
                        vmConnected: capture.vmConnected,
                        provenanceProblem: _provenance.problem,
                      ),
                      Text(
                        'Refresh rate: '
                        '${rate == null ? 'detecting' : rate.toStringAsFixed(1)}'
                        ' Hz${_refreshRateOk ? '' : ' (needs 60 Hz)'}',
                        style: const TextStyle(fontSize: 12),
                      ),
                      if (stamp != null)
                        Text(
                          'Provenance: ${stamp.device} / '
                          '${stamp.deviceOsVersion} / '
                          'Flutter ${stamp.flutterVersion}',
                          style: const TextStyle(fontSize: 12),
                        ),
                      const SizedBox(height: 8),
                      const Text(
                        'Injects an exact number of severe frames (40 ms '
                        'spins inside the frame) and records the '
                        'sustained_jank critical issue, which fires at 3. '
                        'Bands: at [3, 4.5], above (4.5, 7.5].',
                        style: TextStyle(fontSize: 13),
                      ),
                      const SizedBox(height: 12),
                      for (final leg in SustainedJankLeg.values)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: FilledButton.tonal(
                            onPressed: ready ? () => _runLeg(leg) : null,
                            child: Text(
                              '${leg.label[0].toUpperCase()}'
                              '${leg.label.substring(1)}: ${leg.spins} '
                              'severe frames',
                            ),
                          ),
                        ),
                      FilledButton.icon(
                        onPressed: _busy ? null : _exportLastLeg,
                        icon: const Icon(Icons.save_alt),
                        label: const Text('Export last leg'),
                      ),
                    ],
                  ),
                ),
              ),
              const Divider(height: 24),
              Expanded(
                child: ListView.builder(
                  reverse: true,
                  itemCount: _log.length,
                  itemBuilder: (context, i) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      _log[_log.length - 1 - i],
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
