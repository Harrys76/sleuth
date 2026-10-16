import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sleuth/sleuth.dart';
// The detector is not exported; the screen reads its brackets from the
// detector's own metadata so the bands cannot drift from the audit.
// ignore: implementation_imports
import 'package:sleuth/src/detectors/image_memory_detector.dart'
    show ImageMemoryDetector;

import 'capture_driver.dart';

/// Capture helper for the `runtimeVerified` brackets on
/// `ImageMemoryDetector.uncached_images`, the warning at 1 MiB of decoded
/// bytes wasted above what the display box needs, and the critical at
/// 16 MiB.
///
/// Each leg generates a square checkerboard PNG on the device, sized so
/// that, shown in a 48 × 48 dp box at the measured pixel ratio, it wastes
/// the leg's target: 0.5, 1.2 or 2 MiB for the warning legs and 8, 20 or
/// 32 MiB for the critical legs. The screen reads the decoded size and the
/// laid-out box itself and exports its own computed waste
/// ([uncachedImageWasteBytes], the detector's formula on the screen's own
/// reads). The capture audit compares it with the `wastedBytes` the
/// detector stamps on each scan within 10 %.
///
/// The image is shown with no `cacheWidth` or `cacheHeight` (a
/// `ResizeImage` is skipped by the detector) and `BoxFit.fill`, and stays
/// for at least two Sleuth scans (one per second). Every leg end removes
/// it and evicts it from the image cache.
///
/// **Procedure per leg:**
///
///   1. `cd example && fvm flutter run --profile --no-dds -d "iPhone 12" \
///         --dart-define=SLEUTH_CAPTURE_MODE=true \
///         --dart-define=SLEUTH_CAPTURE_DEVICE="iPhone 12"`.
///   2. Open Capture Helpers, then ImageMemory (uncached_images). The
///      pixel-ratio and provenance lines name what the export stamps; a red
///      banner lists anything that blocks a leg.
///   3. Tap a leg, from "Below: 0.5 MiB wasted" to "Critical above: 32 MiB
///      wasted", and wait for "capture stashed".
///   4. Tap **Export last leg** and save the clipboard text as
///      `<scenario>.json` under `test/validation/captures/image_memory/`.
class UncachedImagesCaptureScreen extends StatefulWidget {
  const UncachedImagesCaptureScreen({
    super.key,
    this.captureModeOverride,
    this.provenanceCheck = currentCaptureProvenance,
    this.vmConnected = _sleuthVmConnected,
    this.calls = const CaptureLegCalls(),
    this.specimens = const UncachedImageSpecimens(),
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

  /// The stream, scenario and flush calls a leg makes.
  @visibleForTesting
  final CaptureLegCalls calls;

  /// Generates and decodes the leg's image.
  @visibleForTesting
  final UncachedImageSpecimens specimens;

  @override
  State<UncachedImagesCaptureScreen> createState() =>
      _UncachedImagesCaptureScreenState();
}

bool _sleuthVmConnected() => Sleuth.diagnoseCaptureState().vmConnected;

/// Side of the display box, in logical pixels.
const double uncachedImageBoxDp = 48;

/// The smallest decode-to-need ratio the detector counts
/// (`ImageMemoryDetector.oversizeRatio`).
const double _oversizeRatio = 1.5;

/// The side, in pixels, of a square decode that wastes [targetBytes] in a
/// square box of [boxDp] logical pixels at [devicePixelRatio].
int uncachedImageDecodeSide({
  required double targetBytes,
  required double devicePixelRatio,
  double boxDp = uncachedImageBoxDp,
}) {
  final needed = boxDp * devicePixelRatio;
  return math.sqrt(targetBytes / 4 + needed * needed).round();
}

/// Decoded bytes wasted by a [decodedW] × [decodedH] decode shown in a
/// [boxW] × [boxH] box at [devicePixelRatio], with the detector's formula
/// (`image_memory_detector.dart`): `(decoded - needed) × 4` RGBA bytes,
/// rounded. Null when the decode is not at least 1.5 times the needed
/// size on both axes, because the detector does not count it then.
int? uncachedImageWasteBytes({
  required int decodedW,
  required int decodedH,
  required double boxW,
  required double boxH,
  required double devicePixelRatio,
}) {
  final neededW = boxW * devicePixelRatio;
  final neededH = boxH * devicePixelRatio;
  if (neededW <= 0 || neededH <= 0) return null;
  final ratio = math.min(decodedW / neededW, decodedH / neededH);
  if (ratio < _oversizeRatio) return null;
  return ((decodedW * decodedH - neededW * neededH) * 4).round();
}

/// One uncached_images leg, with its tier, role and target waste.
enum UncachedImagesLeg {
  below(tier: 'warning', role: 'below', targetMiB: 0.5),
  at(tier: 'warning', role: 'at', targetMiB: 1.2),
  above(tier: 'warning', role: 'above', targetMiB: 2),
  criticalBelow(tier: 'critical', role: 'below', targetMiB: 8),
  criticalAt(tier: 'critical', role: 'at', targetMiB: 20),
  criticalAbove(tier: 'critical', role: 'above', targetMiB: 32);

  const UncachedImagesLeg({
    required this.tier,
    required this.role,
    required this.targetMiB,
  });

  /// The bracket the leg records for, `warning` or `critical`.
  final String tier;

  /// `below`, `at` or `above`.
  final String role;

  /// Wasted bytes the leg aims for, in MiB.
  final double targetMiB;

  /// The leg as the log names it.
  String get label => tier == 'critical' ? 'critical/$role' : role;

  /// Scenario name, which is also the capture's file basename.
  String get scenario => tier == 'critical'
      ? 'uncached_images_critical_$role'
      : 'uncached_images_$role';

  /// Target waste in bytes.
  double get targetBytes => targetMiB * 1024 * 1024;

  /// The leg's button label.
  String get buttonLabel {
    final roleText = '${role[0].toUpperCase()}${role.substring(1)}';
    final size = targetMiB == targetMiB.roundToDouble()
        ? targetMiB.toStringAsFixed(0)
        : '$targetMiB';
    return tier == 'critical'
        ? 'Critical $role: $size MiB wasted'
        : '$roleText: $size MiB wasted';
  }
}

/// The bracket [leg] is judged against, read from [metadata] (the
/// detector's `validationMetadata`).
CaptureBracket? uncachedImagesBracket(
  DetectorMetadata metadata,
  UncachedImagesLeg leg,
) => CaptureBracket.fromMetadata(
  metadata,
  stableId: 'uncached_images',
  severityLabel: leg.tier,
);

/// The `expectedMagnitude` band a [role] leg exports against [bracket]:
/// below `[1, threshold - 1]`, at `[threshold, atUpper]`, above
/// `[atUpper, aboveCeiling]`. The schema rejects a bound at or below 0.
({double min, double max}) uncachedImagesBand(
  CaptureBracket bracket,
  String role,
) => switch (role) {
  'below' => (min: 1, max: bracket.threshold - 1),
  'at' => (min: bracket.threshold, max: bracket.atUpper),
  _ => (min: bracket.atUpper, max: bracket.aboveCeiling),
};

/// Why an at or above [leg]'s capture [json] cannot be exported given its
/// last in-span record, or null when that record measured exactly one
/// image. Below legs carry no record of their tier and return null.
LegRefusal? uncachedImagesLastRecordRefusal(
  String json,
  UncachedImagesLeg leg, {
  required CaptureBracket bracket,
}) {
  if (leg.role == 'below') return null;
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
  Object? imageCount;
  for (final event in events) {
    if (event is! Map || event['name'] != bracket.eventName) continue;
    // Only instant events count, as in the capture audit.
    final ph = event['ph'];
    if (ph != 'i' && ph != 'I' && ph != 'n') continue;
    final ts = event['ts'];
    if (ts is! num || ts < begin || ts > end) continue;
    // Keep the latest record. A tie goes to the later one in file order.
    if (lastTs != null && ts < lastTs) continue;
    lastTs = ts.toInt();
    final args = event['args'];
    final dartArgs = args is Map ? args['Dart Arguments'] : null;
    imageCount = (dartArgs is Map ? dartArgs : args as Map?)?['imageCount'];
  }
  if (lastTs == null) {
    return (verdict: 'OUT-OF-BAND', reason: 'no in-span ${bracket.eventName}');
  }
  if ('$imageCount' != '1') {
    return (
      verdict: 'OUT-OF-BAND',
      reason: 'the last record measured $imageCount images; the leg shows one',
    );
  }
  return null;
}

/// Generates and decodes the leg's image. Tests pass a subclass that
/// skips the codec.
class UncachedImageSpecimens {
  const UncachedImageSpecimens();

  /// PNG bytes of a [side] × [side] 8 × 8 checkerboard. Two colors keep
  /// the file small, which random pixels would not.
  Future<Uint8List> png(
    int side, {
    required Color dark,
    required Color light,
  }) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final cell = side / 8;
    final darkPaint = Paint()..color = dark;
    final lightPaint = Paint()..color = light;
    for (var row = 0; row < 8; row++) {
      for (var col = 0; col < 8; col++) {
        canvas.drawRect(
          Rect.fromLTWH(col * cell, row * cell, cell, cell),
          (row + col).isEven ? darkPaint : lightPaint,
        );
      }
    }
    final picture = recorder.endRecording();
    final image = await picture.toImage(side, side);
    picture.dispose();
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw StateError('PNG encoding returned no bytes');
      return data.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }

  /// Decodes [provider] for [configuration], or throws on a decode error.
  Future<ImageInfo> decode(
    ImageProvider provider,
    ImageConfiguration configuration,
  ) {
    final done = Completer<ImageInfo>();
    final stream = provider.resolve(configuration);
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        stream.removeListener(listener);
        if (!done.isCompleted) done.complete(info);
      },
      onError: (error, stack) {
        stream.removeListener(listener);
        if (!done.isCompleted) done.completeError(error, stack);
      },
    );
    stream.addListener(listener);
    return done.future;
  }
}

// Leg phases.
// A scan runs about once a second, but with a large decode on screen the
// iPhone 12 managed only one scan in 2.5 s on two of three attempts.
const _dwell = Duration(milliseconds: 3500);
const _specimenTimeout = Duration(seconds: 30);
const _maxAttemptsPerLeg = 5;

class _UncachedImagesCaptureScreenState
    extends State<UncachedImagesCaptureScreen> {
  bool _busy = false;
  UncachedImagesLeg? _attemptLeg;
  int _attempts = 0;
  UncachedImagesLeg? _stashedLeg;
  String? _stashedJson;
  final List<String> _log = [];
  String _caption = 'No leg image. A leg shows one here.';

  late final CaptureProvenanceCheck _provenance;
  final GlobalKey _boxKey = GlobalKey();

  // The resources a leg owns. They are fields, not locals, so dispose can
  // end the scenario, restore the streams and drop the image while the
  // leg still awaits.
  MemoryImage? _shown;
  ImageInfo? _decoded;
  String? _openScenario;
  bool _streamsSuspended = false;

  bool get _captureModeOn =>
      widget.captureModeOverride ??
      const bool.fromEnvironment('SLEUTH_CAPTURE_MODE');

  @override
  void initState() {
    super.initState();
    _provenance = widget.provenanceCheck();
  }

  @override
  void dispose() {
    // A running leg may be awaiting its dwell, the flush or the export.
    // End its scenario and restore the streams now, so neither lands
    // inside another capture's span, and drop the image.
    _endScenario(log: false);
    unawaited(_resumeStreams(log: false));
    _dropImage(rebuild: false);
    super.dispose();
  }

  void _say(String line) {
    if (!mounted) return;
    setState(() => _log.add(line));
  }

  /// Ends the leg's open scenario once. A throw is logged, not rethrown,
  /// so it cannot replace the leg's outcome.
  void _endScenario({String label = '', bool log = true}) {
    final scenario = _openScenario;
    if (scenario == null) return;
    _openScenario = null;
    try {
      widget.calls.markScenarioEnd(scenario);
    } catch (e) {
      if (log) _say('[$label] markScenarioEnd: $e');
    }
  }

  /// Restores the timeline streams once, bounded so an unanswered VM call
  /// cannot keep the screen busy.
  Future<void> _resumeStreams({String label = '', bool log = true}) async {
    if (!_streamsSuspended) return;
    _streamsSuspended = false;
    try {
      await withCallTimeout(
        widget.calls.resumeStreams(),
        'resumeAllTimelineStreams',
      );
    } catch (e) {
      if (log) _say('[$label] resumeAllTimelineStreams: $e');
    }
  }

  /// Removes the leg image, evicts it from the image cache and releases
  /// the decode the leg held.
  void _dropImage({bool rebuild = true}) {
    final shown = _shown;
    _shown = null;
    _decoded?.dispose();
    _decoded = null;
    if (shown != null) unawaited(shown.evict());
    if (rebuild && mounted) {
      setState(() => _caption = 'No leg image. A leg shows one here.');
    }
  }

  Future<void> _runLeg(UncachedImagesLeg leg) async {
    if (_busy) return;
    final label = leg.label;
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
    final bracket = uncachedImagesBracket(
      ImageMemoryDetector().validationMetadata,
      leg,
    );
    if (bracket == null) {
      _say(
        '[$label] ABORT: ImageMemoryDetector declares no uncached_images '
        '${leg.tier} bracket.',
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
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final side = uncachedImageDecodeSide(
      targetBytes: leg.targetBytes,
      devicePixelRatio: dpr,
    );
    final scheme = Theme.of(context).colorScheme;
    final configuration = createLocalImageConfiguration(context);
    setState(() {
      _busy = true;
      _stashedLeg = null;
      _stashedJson = null;
      _log.add(
        '[$label] attempt $_attempts/$_maxAttemptsPerLeg: $side px decode '
        'in a ${uncachedImageBoxDp.toStringAsFixed(0)} dp box at '
        '${dpr.toStringAsFixed(1)}x, target ${leg.targetMiB} MiB, band '
        '${bracket.bandText(leg.role)} bytes',
      );
    });

    try {
      // Only the Dart timeline stream during the leg, as the other capture
      // screens do. The flag is set before the call, because a suspension
      // that times out may still land later.
      _streamsSuspended = true;
      await withCallTimeout(
        widget.calls.suspendStreams(),
        'suspendNonEssentialTimelineStreams',
      );
      if (!mounted) return;

      setState(() => _caption = 'Generating a $side × $side px PNG');
      final bytes = await widget.specimens
          .png(
            side,
            dark: scheme.outline,
            light: scheme.surfaceContainerHighest,
          )
          .timeout(_specimenTimeout);
      if (!mounted) return;
      setState(() => _caption = 'Decoding');
      final provider = MemoryImage(bytes);
      _shown = provider;
      final decoded = _decoded = await widget.specimens
          .decode(provider, configuration)
          .timeout(_specimenTimeout);
      if (!mounted) return;

      widget.calls.markScenarioBegin(leg.scenario);
      _openScenario = leg.scenario;
      // The decode is cached under the same provider, so the Image shows
      // it at once and Sleuth's next scan reads it from the RawImage.
      setState(() {});
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      final box = _boxKey.currentContext?.size;
      final waste = box == null
          ? null
          : uncachedImageWasteBytes(
              decodedW: decoded.image.width,
              decodedH: decoded.image.height,
              boxW: box.width,
              boxH: box.height,
              devicePixelRatio: dpr,
            );
      setState(() {
        _caption =
            'decoded ${decoded.image.width} × ${decoded.image.height} px, '
            'shown ${box?.width.toStringAsFixed(0)} × '
            '${box?.height.toStringAsFixed(0)} dp at '
            '${dpr.toStringAsFixed(1)}x, waste ${waste ?? 'not counted'} B';
      });

      // At least two scans see the image (one per second).
      await Future<void>.delayed(_dwell);
      if (!mounted) return;
      await widget.calls.flushTimeline();
      if (!mounted) return;
      _endScenario(label: label);
      _dropImage();

      if (box == null ||
          box.width != uncachedImageBoxDp ||
          box.height != uncachedImageBoxDp) {
        _say(
          '[$label] UNMEASURED: the image box laid out at $box, not '
          '${uncachedImageBoxDp.toStringAsFixed(0)} dp square',
        );
        return;
      }
      final measured = measurementRefusal(
        waste,
        role: leg.role,
        bracket: bracket,
        what: 'computed waste',
        unit: 'bytes',
      );
      if (measured != null) {
        _say('[$label] ${measured.verdict}: ${measured.reason}');
        return;
      }

      // The end marker must reach the VM buffer before the export reads it.
      await Future<void>.delayed(const Duration(milliseconds: 800));
      if (!mounted) return;
      await _resumeStreams(label: label);
      if (!mounted) return;

      final provenance = requireCaptureProvenance(
        check: widget.provenanceCheck,
      );
      final band = uncachedImagesBand(bracket, leg.role);
      String? json;
      String? composeFailure;
      try {
        json = await withCallTimeout(
          Sleuth.exportCaptureJson(
            scenario: leg.scenario,
            role: leg.role,
            magnitudeMin: band.min,
            magnitudeObserved: waste!.toDouble(),
            magnitudeMax: band.max,
            unit: 'bytes',
            device: provenance.device,
            deviceOsVersion: provenance.deviceOsVersion,
            flutterVersion: provenance.flutterVersion,
            captureCommand: provenance.captureCommand,
            bracketStableId: 'uncached_images',
            bracketSeverityLabel: leg.tier,
            // The waste comes from a structural scan, not a timeline event.
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
        role: leg.role,
        observed: waste,
        unit: 'bytes',
      );
      final exportRefusal =
          recordRefusal(check, role: leg.role, bracket: bracket) ??
          uncachedImagesLastRecordRefusal(json, leg, bracket: bracket);
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
      // An encode or decode error, a VM call past its limit, or any other
      // failure still ends the leg with an outcome line.
      _say('[$label] FAILED: $e. Tap the leg again.');
    } finally {
      // All of these are no-ops when the leg or dispose already did them.
      _endScenario(label: label);
      _dropImage();
      await _resumeStreams(label: label);
      if (mounted) setState(() => _busy = false);
    }
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
        '${leg.scenario}.json under test/validation/captures/image_memory/.',
      );
    } catch (e) {
      _say('[${leg.label}] clipboard copy FAILED: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final capture = Sleuth.diagnoseCaptureState();
    final ready = _captureModeOn && _provenance.provenance != null && !_busy;
    final stamp = _provenance.provenance;
    final scheme = Theme.of(context).colorScheme;
    final shown = _shown;
    const evidenceStyle = TextStyle(
      fontFamily: 'monospace',
      fontSize: 12,
      fontFeatures: [FontFeature.tabularFigures()],
    );
    return Scaffold(
      appBar: AppBar(title: const Text('uncached_images capture')),
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
                        'Pixel ratio: '
                        '${MediaQuery.devicePixelRatioOf(context).toStringAsFixed(1)}x',
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
                        'Shows one generated PNG decoded larger than its '
                        '48 dp box needs and records the uncached_images '
                        'issue: a warning at 1 MiB wasted, critical at '
                        '16 MiB.',
                        style: TextStyle(fontSize: 13),
                      ),
                      const SizedBox(height: 12),
                      for (final leg in UncachedImagesLeg.values) ...[
                        if (leg == UncachedImagesLeg.criticalBelow)
                          const SizedBox(height: 8),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: FilledButton.tonal(
                            onPressed: ready ? () => _runLeg(leg) : null,
                            child: Text(leg.buttonLabel),
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      FilledButton.icon(
                        onPressed: _busy ? null : _exportLastLeg,
                        icon: const Icon(Icons.save_alt),
                        label: const Text('Export last leg'),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              // The leg image. Its box is pinned, so a large decode cannot
              // change the layout; the placeholder is not an Image, so the
              // detector sees one image per leg.
              Row(
                children: [
                  SizedBox(
                    key: _boxKey,
                    width: uncachedImageBoxDp,
                    height: uncachedImageBoxDp,
                    child: shown == null
                        ? DecoratedBox(
                            decoration: BoxDecoration(
                              border: Border.all(color: scheme.outlineVariant),
                            ),
                          )
                        : Image(
                            image: shown,
                            width: uncachedImageBoxDp,
                            height: uncachedImageBoxDp,
                            fit: BoxFit.fill,
                            excludeFromSemantics: true,
                          ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_caption, style: evidenceStyle)),
                ],
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
