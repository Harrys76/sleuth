import 'dart:developer' show Timeline;
import 'dart:ui' show FramePhase;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart' show FrameTiming, SchedulerBinding;
import 'package:flutter/widgets.dart' show WidgetsFlutterBinding;

import '../models/startup_metrics.dart';

/// Startup tracing state behind `Sleuth.init`, `Sleuth.markInteractive`
/// and `Sleuth.startupMetrics`. The controller and the detectors read it
/// here, so none of it has to be public on `Sleuth`.
abstract final class StartupTracker {
  /// Whether [init] has run. Prevents double measurement, and survives a
  /// hot restart on purpose: a warm VM gives misleading cold-start numbers.
  static bool _initCalled = false;

  /// Wall-clock time [init] ran.
  static DateTime? _dartEntryTimestamp;

  static int? _dartEntryMonotonicUs;

  /// `Timeline.now` when [init] ran, null before. It is on the same clock
  /// as `PhaseEvent.timestampUs`, so detectors compare timeline events
  /// with app start directly.
  static int? get dartEntryMonotonicUs => _dartEntryMonotonicUs;

  /// Framework init duration in microseconds (direct measurement).
  static int? _frameworkInitDurationUs;

  static StartupMetrics? _metrics;

  /// Startup metrics set by the first-frame callback, null before it.
  static StartupMetrics? get metrics => _metrics;

  /// Engine events that arrived before the first-frame callback, applied
  /// to [metrics] when it fires.
  static _PendingEngineEvents? _pendingEngineEvents;

  /// Time [markInteractive] ran.
  static DateTime? _interactiveTimestamp;

  /// The clock [init] and its first-frame callback read. Tests set it to
  /// control the measured time to first frame; null reads [DateTime.now].
  static DateTime Function()? clockForTest;

  /// The first-frame callback [init] registered, kept until it fires so
  /// [resetForTest] can remove it.
  static void Function(List<FrameTiming>)? _firstFrameCallback;

  static DateTime _now() => (clockForTest ?? DateTime.now)();

  /// Records Dart entry and registers a one-shot timings callback that
  /// measures the first frame. See `Sleuth.init`.
  static void init() {
    if (kReleaseMode) return;
    if (_initCalled) return;
    _initCalled = true;
    _dartEntryTimestamp = _now();
    _dartEntryMonotonicUs = Timeline.now;

    // Ensure bindings exist so SchedulerBinding is available. Timeline.now
    // around it measures framework init directly, with no VM timeline.
    final fwInitStart = Timeline.now;
    try {
      WidgetsFlutterBinding.ensureInitialized();
    } catch (_) {
      // Custom binding already initialized. The timestamp is still
      // captured; if the FrameTiming callback cannot register below, the
      // detector uses the timestamp-only fallback.
    }
    _frameworkInitDurationUs = Timeline.now - fwInitStart;

    try {
      late void Function(List<FrameTiming>) callback;
      callback = (List<FrameTiming> timings) {
        // One-shot: unregister at once.
        SchedulerBinding.instance.removeTimingsCallback(callback);
        _firstFrameCallback = null;

        if (timings.isEmpty) return;
        final first = timings.first;

        final vsyncStart = first.timestampInMicroseconds(FramePhase.vsyncStart);
        final buildStart = first.timestampInMicroseconds(FramePhase.buildStart);
        final buildFinish = first.timestampInMicroseconds(
          FramePhase.buildFinish,
        );
        final rasterStart = first.timestampInMicroseconds(
          FramePhase.rasterStart,
        );
        final rasterFinish = first.timestampInMicroseconds(
          FramePhase.rasterFinish,
        );

        final vsyncOverhead = (buildStart - vsyncStart) / 1000.0;
        final buildMs = (buildFinish - buildStart) / 1000.0;
        final rasterMs = (rasterFinish - rasterStart) / 1000.0;
        final totalMs = (rasterFinish - vsyncStart) / 1000.0;

        // TTFF is the time from Dart entry to the first frame's raster
        // finish, on the wall clock. FrameTiming timestamps come from the
        // monotonic (uptime) clock, not the Unix epoch, so they cannot be
        // diffed against _dartEntryTimestamp.
        final firstFrameCompleteTime = _now();
        final ttff =
            firstFrameCompleteTime
                .difference(_dartEntryTimestamp!)
                .inMicroseconds /
            1000.0;

        _metrics = StartupMetrics(
          dartEntryTimestamp: _dartEntryTimestamp!,
          ttffMs: ttff > 0 ? ttff : null,
          ttiMs: _interactiveTimestamp != null
              ? _interactiveTimestamp!
                        .difference(_dartEntryTimestamp!)
                        .inMicroseconds /
                    1000.0
              : null,
          firstFrameVsyncOverheadMs: vsyncOverhead,
          firstFrameBuildMs: buildMs,
          firstFrameRasterMs: rasterMs,
          firstFrameTotalMs: totalMs,
          dartEntryMonotonicUs: _dartEntryMonotonicUs,
          frameworkInitDurationUs: _frameworkInitDurationUs,
        );

        // Flush any engine events that arrived before first frame.
        if (_pendingEngineEvents != null) {
          _metrics = _metrics!.copyWith(
            engineEnterUs: _pendingEngineEvents!.engineEnterUs,
            firstFrameRasterizedUs:
                _pendingEngineEvents!.firstFrameRasterizedUs,
            vmFirstBuildScopeMs: _pendingEngineEvents!.vmFirstBuildScopeMs,
            vmFirstFlushLayoutMs: _pendingEngineEvents!.vmFirstFlushLayoutMs,
            vmFirstFlushPaintMs: _pendingEngineEvents!.vmFirstFlushPaintMs,
            vmFirstRasterMs: _pendingEngineEvents!.vmFirstRasterMs,
          );
          _pendingEngineEvents = null;
        }
      };
      SchedulerBinding.instance.addTimingsCallback(callback);
      _firstFrameCallback = callback;
    } catch (_) {
      // SchedulerBinding not available (custom binding without
      // SchedulerBinding mixin). TTFF will not be measured, but
      // _dartEntryTimestamp is still available for TTI calculation.
    }
  }

  /// Records the time to interactive. See `Sleuth.markInteractive`.
  static void markInteractive() {
    if (kReleaseMode) return;
    if (_dartEntryTimestamp == null) return;
    _interactiveTimestamp = DateTime.now();

    // Update metrics if already captured by the first-frame callback.
    if (_metrics != null) {
      _metrics = _metrics!.copyWith(
        ttiMs:
            _interactiveTimestamp!
                .difference(_dartEntryTimestamp!)
                .inMicroseconds /
            1000.0,
      );
    }
  }

  /// Adds VM timeline data to [metrics]: sub-phase durations and engine
  /// timestamps the controller finds in the ring buffer on its first
  /// timeline read. Before the first frame the data waits for it.
  static void enrichWithVmData({
    double? vmFirstBuildScopeMs,
    double? vmFirstFlushLayoutMs,
    double? vmFirstFlushPaintMs,
    double? vmFirstRasterMs,
    int? engineEnterUs,
    int? firstFrameRasterizedUs,
  }) {
    if (_metrics == null) {
      // First-frame callback hasn't fired yet. Buffer all VM data
      // for deferred application when metrics become available.
      if (engineEnterUs != null ||
          firstFrameRasterizedUs != null ||
          vmFirstBuildScopeMs != null ||
          vmFirstFlushLayoutMs != null ||
          vmFirstFlushPaintMs != null ||
          vmFirstRasterMs != null) {
        _pendingEngineEvents = _PendingEngineEvents(
          engineEnterUs: engineEnterUs,
          firstFrameRasterizedUs: firstFrameRasterizedUs,
          vmFirstBuildScopeMs: vmFirstBuildScopeMs,
          vmFirstFlushLayoutMs: vmFirstFlushLayoutMs,
          vmFirstFlushPaintMs: vmFirstFlushPaintMs,
          vmFirstRasterMs: vmFirstRasterMs,
        );
      }
      return;
    }
    _metrics = _metrics!.copyWith(
      vmFirstBuildScopeMs: vmFirstBuildScopeMs,
      vmFirstFlushLayoutMs: vmFirstFlushLayoutMs,
      vmFirstFlushPaintMs: vmFirstFlushPaintMs,
      vmFirstRasterMs: vmFirstRasterMs,
      engineEnterUs: engineEnterUs,
      firstFrameRasterizedUs: firstFrameRasterizedUs,
    );
  }

  /// Clears every recorded value and removes an unfired first-frame
  /// callback.
  static void resetForTest() {
    // A callback that never fired would otherwise run on the next timing
    // report against the cleared state below.
    final pending = _firstFrameCallback;
    _firstFrameCallback = null;
    if (pending != null) {
      try {
        SchedulerBinding.instance.removeTimingsCallback(pending);
      } catch (_) {
        // Without a binding, init registered nothing.
      }
    }
    clockForTest = null;
    _initCalled = false;
    _dartEntryTimestamp = null;
    _dartEntryMonotonicUs = null;
    _frameworkInitDurationUs = null;
    _metrics = null;
    _pendingEngineEvents = null;
    _interactiveTimestamp = null;
  }

  static void setMetricsForTest(StartupMetrics metrics) {
    _metrics = metrics;
  }
}

/// Buffered engine events that arrived before the first-frame callback.
class _PendingEngineEvents {
  const _PendingEngineEvents({
    this.engineEnterUs,
    this.firstFrameRasterizedUs,
    this.vmFirstBuildScopeMs,
    this.vmFirstFlushLayoutMs,
    this.vmFirstFlushPaintMs,
    this.vmFirstRasterMs,
  });
  final int? engineEnterUs;
  final int? firstFrameRasterizedUs;
  final double? vmFirstBuildScopeMs;
  final double? vmFirstFlushLayoutMs;
  final double? vmFirstFlushPaintMs;
  final double? vmFirstRasterMs;
}
