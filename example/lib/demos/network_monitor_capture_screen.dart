import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sleuth/sleuth.dart';

/// Capture helper for the runtimeVerified tier raise on three
/// `NetworkMonitorDetector` warning families:
///
/// - `slow_request.warning` (v0.18.0, 1000 ms threshold) — original
///   purpose; flow preserved byte-for-byte.
/// - `large_response.warning` (v0.19.9, 1 MB threshold) — new.
/// - `request_frequency.warning` (v0.19.9, > 30 req per 5 s window) —
///   new.
///
/// All three legs export a wrapped capture JSON to the iOS clipboard.
/// Operator pastes into Notes / Mail / AirDrop → sends to Mac → saves
/// under `test/validation/captures/network_monitor/<family>_<leg>.json`.
///
/// **Procedure (USB iPhone, in-app export — no DevTools needed):**
///
///  1. `cd example && fvm flutter run --profile -d "iPhone 12" \
///        --dart-define=SLEUTH_CAPTURE_MODE=true`. First build attaches
///     DevTools (FRAME mode for Sleuth — capture won't work yet).
///  2. Quit `flutter run` (`q`). DevTools detaches.
///  3. Re-open the app from the iPhone home screen. No DevTools
///     attached → SleuthController.VmServiceClient connects → VM+
///     mode active → real `NetworkMonitorDetector` observes HTTP
///     completions and emits the three target trace records.
///  4. Navigate to "NetworkMonitor capture helper" → pick a mode →
///     tap a leg → wait for "tap Export now" log line → tap **Export
///     last leg**.
///
/// **Mode-specific timing**: scenario span and post-completion dwell
/// differ by family because the trace event's `ts` lands at different
/// points in the detection cycle:
///
/// - slow_request: 1 request, 200 ms dwell + 800 ms drain barrier.
/// - large_response: 1 request, 200 ms dwell + 800 ms drain barrier.
/// - request_frequency: N parallel requests, 5.5 s scenario span (covers
///   the detector's 5 s sliding window plus headroom), 800 ms post-end
///   drain barrier. Wraps with `Sleuth.suspendNonEssentialTimelineStreams`
///   so the longer span doesn't overflow the VM ring buffer.
///
/// **Why a loopback HTTP server**: a real remote would be
/// non-deterministic (DNS, transit jitter, server-side variance) so
/// bracket magnitudes would drift between recordings and audit's
/// at-band would reject some captures. The loopback server delays the
/// response by exactly the requested duration AND returns exactly the
/// requested byte count, so each capture lands inside its target
/// bracket on the first try.
class NetworkMonitorCaptureScreen extends StatefulWidget {
  const NetworkMonitorCaptureScreen({super.key});

  @override
  State<NetworkMonitorCaptureScreen> createState() =>
      _NetworkMonitorCaptureScreenState();
}

enum _CaptureMode {
  slowRequest('slow_request', 'Slow request (ms)'),
  largeResponse('large_response', 'Large response (bytes)'),
  requestFrequency('request_frequency', 'Request frequency (events/5s)');

  const _CaptureMode(this.stableId, this.label);

  final String stableId;
  final String label;
}

/// Severity tier for `_CaptureMode.slowRequest`. Other modes are
/// single-tier and ignore this field. Tier drives scenario name,
/// capture file name, and per-leg target ms.
enum _Tier {
  warning('warning', 1000),
  critical('critical', 3000);

  const _Tier(this.label, this.thresholdMs);

  final String label;
  final int thresholdMs;
}

/// Per-leg target + scenario-band bounds for slow_request captures
/// resolved against the active [_Tier]. Targets sit far enough from
/// each band edge that ±15 % network/scheduler drift stays inside the
/// schema-accepted band.
({int delayMs, int msMin, int msMax}) _slowRequestLegSpec(
  _Tier tier,
  String leg,
) {
  switch (tier) {
    case _Tier.warning:
      switch (leg) {
        case 'below':
          return (delayMs: 800, msMin: 0, msMax: 999);
        case 'at':
          return (delayMs: 1020, msMin: 1000, msMax: 1100);
        case 'above':
          return (delayMs: 1500, msMin: 1101, msMax: 1999);
      }
    case _Tier.critical:
      switch (leg) {
        // Below band [0, 2999] — warning fires (>=1000), critical does
        // not. Schema's name-scoped no-record check accepts.
        case 'below':
          return (delayMs: 2700, msMin: 0, msMax: 2999);
        // At band [3000, 4200] (atTolerance=0.40). Target 3600 = mid;
        // ±15% network drift = [3060, 4140] — both edges in band.
        case 'at':
          return (delayMs: 3600, msMin: 3000, msMax: 4200);
        // Above band (4201, 6000] (above-ceiling 2.0×3000=6000). Target
        // 5000 = mid-band.
        case 'above':
          return (delayMs: 5000, msMin: 4201, msMax: 6000);
      }
  }
  throw ArgumentError('Unknown leg: $leg');
}

class _NetworkMonitorCaptureScreenState
    extends State<NetworkMonitorCaptureScreen> {
  HttpServer? _server;
  HttpClient? _client;
  final List<String> _log = [];
  bool _busy = false;
  _CaptureMode _mode = _CaptureMode.slowRequest;
  // Active severity tier for slow_request (warning vs critical). Other
  // modes ignore this. Defaults to warning so the v0.18.0 capture flow
  // is the no-tier-switch default.
  _Tier _slowRequestTier = _Tier.warning;

  // Last completed leg state — what the Export button serialises.
  // Cleared on each new leg request so the operator cannot accidentally
  // export an out-of-band run from an earlier session.
  String? _lastCompletedLeg;
  _CaptureMode? _lastCompletedMode;
  // slow_request: tier of the completed leg (warning or critical).
  _Tier? _lastCompletedTier;
  // slow_request: ms wall-clock from Stopwatch.
  int? _lastMeasuredMs;
  // large_response: bytes received from the loopback response.
  int? _lastObservedBytes;
  // request_frequency: count of records sent inside the scenario span.
  int? _lastObservedCount;

  // In-flight scenario name. Stamped at markScenarioBegin, cleared at
  // markScenarioEnd. Non-null at dispose() means the operator popped or
  // backgrounded mid-scenario; emit a synthetic markScenarioEnd so the
  // begin marker doesn't outlive the screen and pair with whatever
  // scenario the next session opens. Existing per-mode catch blocks
  // already call markScenarioEnd on HTTP errors; this guards the
  // narrower window where dispose interleaves with the postFrame chain.
  String? _inFlightScenarioName;

  @override
  void initState() {
    super.initState();
    _startServer();
  }

  @override
  void dispose() {
    final scenario = _inFlightScenarioName;
    if (scenario != null) {
      // Operator popped or backgrounded mid-scenario. Emit the matching
      // scenario.end so the in-buffer begin marker pairs and the next
      // session's recorded span can't accidentally absorb it. Routed
      // through `_endScenarioOnce` so the catch path that fires after
      // `client.close(force)` cancels the in-flight HTTP request can't
      // emit a second end marker for the same scenario.
      _endScenarioOnce(scenario);
    }
    final client = _client;
    final server = _server;
    _client = null;
    _server = null;
    client?.close(force: true);
    unawaited(server?.close(force: true) ?? Future<void>.value());
    super.dispose();
  }

  /// Idempotent scenario-end emitter. Clears `_inFlightScenarioName`
  /// BEFORE calling `Sleuth.markScenarioEnd` so a second invocation
  /// for the same scenario name (typically from a per-mode catch
  /// block firing after dispose's `client.close(force)` cancels the
  /// awaiting request) early-returns without double-emitting. Two
  /// `scenario.end` markers for one `scenario.begin` would fail
  /// `ProfileCaptureSchema._scenarioSpan`'s "exactly one end"
  /// invariant.
  void _endScenarioOnce(String scenarioName) {
    if (_inFlightScenarioName != scenarioName) return;
    _inFlightScenarioName = null;
    Sleuth.markScenarioEnd(scenarioName);
  }

  Future<void> _startServer() async {
    try {
      // Loopback only. Port 0 = kernel-assigned. No external exposure.
      final server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
        shared: false,
      );
      server.listen(
        (HttpRequest req) async {
          // A client that disconnects mid-delay (app reload, user
          // back-navigation) throws on `req.response.close()`; the
          // default behaviour unwinds into the unhandled stream onError
          // and the log surface tells the user nothing. Catch + log so
          // an unexpected recording failure is visible in-screen.
          try {
            final delayMs =
                int.tryParse(req.uri.queryParameters['delay'] ?? '') ?? 0;
            final bytes =
                int.tryParse(req.uri.queryParameters['bytes'] ?? '') ?? 0;
            if (delayMs > 0) {
              await Future<void>.delayed(Duration(milliseconds: delayMs));
            }
            req.response.headers.contentType = ContentType.json;
            if (bytes > 0) {
              // Pad the JSON envelope toward the requested `bytes`
              // total. Wrapper `{"pad":"…"}` adds 10 bytes around
              // the padding, so target ≈ requested - 10. The capture
              // pipeline records actual wire-summed bytes (not the
              // request target) so this approximation only affects
              // operator-side leg-targeting precision; the recorded
              // evidence is always wire-measured.
              const envelopeOverhead = 10;
              final padLen = (bytes - envelopeOverhead).clamp(0, bytes);
              final padding = List.filled(padLen, 0x41).map((b) {
                return String.fromCharCode(b);
              }).join();
              req.response.write(jsonEncode({'pad': padding}));
            } else {
              req.response.write(jsonEncode({'ok': true, 'delayMs': delayMs}));
            }
            await req.response.close();
          } catch (e) {
            if (!mounted) return;
            setState(() => _log.add('Server-side request error: $e'));
          }
        },
        onError: (Object e, StackTrace st) {
          if (!mounted) return;
          setState(() => _log.add('Server listen error: $e'));
        },
      );
      if (!mounted) {
        // Screen disposed mid-bind — release the port rather than leak.
        await server.close(force: true);
        return;
      }
      setState(() {
        _server = server;
        _client = HttpClient();
        _log.add('Server ready on http://127.0.0.1:${server.port}');
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _log.add('Server bind failed: $e'));
    }
  }

  void _resetLastLeg() {
    _lastCompletedLeg = null;
    _lastCompletedMode = null;
    _lastCompletedTier = null;
    _lastMeasuredMs = null;
    _lastObservedBytes = null;
    _lastObservedCount = null;
  }

  /// Wire-format scenario name for slow_request captures. Warning tier
  /// keeps the v0.18.0 prefix (`slow_request_below`) for backward compat
  /// with the original capture file names. Critical tier injects
  /// `_critical_` so capture files land at distinct paths.
  String _slowRequestScenarioName(_Tier tier, String leg) =>
      tier == _Tier.warning
      ? 'slow_request_$leg'
      : 'slow_request_critical_$leg';

  Future<void> _runSlowRequestCapture({
    required _Tier tier,
    required String label,
    required int delayMs,
  }) async {
    final server = _server;
    final client = _client;
    if (server == null || client == null || _busy) return;
    setState(() {
      _busy = true;
      _resetLastLeg();
      _log.add(
        '[${tier.label}/$label] scenario.begin → GET /slow?delay=$delayMs',
      );
    });

    final scenarioName = _slowRequestScenarioName(tier, label);
    Sleuth.markScenarioBegin(scenarioName);
    _inFlightScenarioName = scenarioName;
    final messenger = ScaffoldMessenger.of(context);

    final stopwatch = Stopwatch()..start();
    try {
      final uri = Uri.parse(
        'http://127.0.0.1:${server.port}/slow?delay=$delayMs',
      );
      final req = await client.getUrl(uri);
      final resp = await req.close();
      // Drain response. `await for` (not `.drain()`) per the
      // proxy-onDone limitation documented in NetworkMonitorDetector
      // pipeline — `.drain()` replaces the wrapping `onDone` handler
      // and suppresses `RequestRecord` emission.
      var bytes = 0;
      await for (final chunk in resp) {
        bytes += chunk.length;
      }
      stopwatch.stop();
      final measuredMs = stopwatch.elapsedMilliseconds;

      // Post-completion dwell BEFORE markScenarioEnd. The detector
      // emits the trace event from one of three async callback paths
      // (structural scan, VM poll, frame stats) AFTER the request
      // completes. With markScenarioEnd called immediately, the trace
      // event would land outside the scenario span and audit would
      // reject. The 200 ms delay guarantees ~12 frame stats callbacks
      // fire (60 Hz) — far more than needed for one to flush the
      // issue into the trace buffer with a `ts` strictly inside
      // [scenario.begin, scenario.end].
      await Future<void>.delayed(const Duration(milliseconds: 200));
      _endScenarioOnce(scenarioName);

      // Additional dwell so the VM Timeline buffer drains before
      // exportCaptureJson reads it.
      await Future<void>.delayed(const Duration(milliseconds: 800));

      if (!mounted) return;
      setState(() {
        _busy = false;
        _lastCompletedLeg = label;
        _lastCompletedMode = _CaptureMode.slowRequest;
        _lastCompletedTier = tier;
        _lastMeasuredMs = measuredMs;
        _log.add(
          '[${tier.label}/$label] scenario.end (${measuredMs}ms, ${bytes}B) — '
          'tap "Export last leg" to write the wrapped capture.',
        );
      });
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '${tier.label}/$label OK (${measuredMs}ms). Tap Export now.',
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (e, st) {
      _endScenarioOnce(scenarioName);
      developer.log(
        '[sleuth.capture] FAILED ${tier.label}/$label: $e',
        name: 'sleuth.capture',
        error: e,
        stackTrace: st,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _log.add('[${tier.label}/$label] FAILED: $e');
      });
    }
  }

  Future<void> _runLargeResponseCapture({
    required String label,
    required int responseBytes,
  }) async {
    final server = _server;
    final client = _client;
    if (server == null || client == null || _busy) return;
    setState(() {
      _busy = true;
      _resetLastLeg();
      _log.add('[$label] scenario.begin → GET /sized?bytes=$responseBytes');
    });

    final scenarioName = 'large_response_$label';
    Sleuth.markScenarioBegin(scenarioName);
    _inFlightScenarioName = scenarioName;
    final messenger = ScaffoldMessenger.of(context);

    var bytes = 0;
    try {
      final uri = Uri.parse(
        'http://127.0.0.1:${server.port}/sized?bytes=$responseBytes',
      );
      final req = await client.getUrl(uri);
      final resp = await req.close();
      await for (final chunk in resp) {
        bytes += chunk.length;
      }

      await Future<void>.delayed(const Duration(milliseconds: 200));
      _endScenarioOnce(scenarioName);
      await Future<void>.delayed(const Duration(milliseconds: 800));

      if (!mounted) return;
      setState(() {
        _busy = false;
        _lastCompletedLeg = label;
        _lastCompletedMode = _CaptureMode.largeResponse;
        _lastObservedBytes = bytes;
        _log.add(
          '[$label] scenario.end (${bytes}B observed, target '
          '${responseBytes}B) — tap "Export last leg" to write the '
          'wrapped capture.',
        );
      });
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '$label OK (${(bytes / 1024).toStringAsFixed(1)} KB). Tap Export now.',
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (e, st) {
      _endScenarioOnce(scenarioName);
      developer.log(
        '[sleuth.capture] FAILED $label: $e',
        name: 'sleuth.capture',
        error: e,
        stackTrace: st,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _log.add('[$label] FAILED: $e');
      });
    }
  }

  Future<void> _runRequestFrequencyCapture({
    required String label,
    required int requestCount,
  }) async {
    final server = _server;
    final client = _client;
    if (server == null || client == null || _busy) return;
    setState(() {
      _busy = true;
      _resetLastLeg();
      _log.add(
        '[$label] scenario.begin → $requestCount× GET /ping over 4 s '
        '(scenario span 5.5 s)',
      );
    });

    final scenarioName = 'request_frequency_$label';
    // Stream narrowing: scenario span is 5.5 s + 800 ms barrier ≈ 6.3 s.
    // Default Dart + Embedder + GC + raster streams generate tens of
    // thousands of events that overflow the ~50k-event VM ring buffer,
    // potentially rolling the scenario.begin marker off before
    // exportCaptureJson reads it. Restrict to Dart-only for the span.
    Sleuth.suspendNonEssentialTimelineStreams();
    Sleuth.markScenarioBegin(scenarioName);
    _inFlightScenarioName = scenarioName;
    final messenger = ScaffoldMessenger.of(context);

    var observedCount = 0;
    final scenarioStart = DateTime.now();
    try {
      // Spread the N requests over ~4 seconds so they all land inside
      // the same 5-second sliding window the detector observes. A
      // batch issued within one tick risks the detector's window
      // tracking only the spike instant, not the steady-state.
      const requestSpreadMs = 4000;
      final intervalMs = (requestSpreadMs / requestCount).round();
      final futures = <Future<void>>[];
      for (var i = 0; i < requestCount; i++) {
        await Future<void>.delayed(Duration(milliseconds: intervalMs));
        futures.add(() async {
          final uri = Uri.parse('http://127.0.0.1:${server.port}/ping?seq=$i');
          final req = await client.getUrl(uri);
          final resp = await req.close();
          await for (final _ in resp) {}
        }());
      }
      await Future.wait(futures);

      // Total scenario span target ≥ 5.5 s. If batches finished early
      // (small intervalMs, fast loopback) pad the remaining time to
      // ensure the detector's 5 s window has fully elapsed and
      // emission has fired inside the span.
      final elapsed = DateTime.now().difference(scenarioStart).inMilliseconds;
      const minScenarioMs = 5500;
      if (elapsed < minScenarioMs) {
        await Future<void>.delayed(
          Duration(milliseconds: minScenarioMs - elapsed),
        );
      }

      // Post-completion dwell pattern (200 ms + barrier + 800 ms).
      //
      // flushFrequencyEvaluation only updates the detector's peak
      // getter — issue emission lives in the periodic + processRecord-
      // driven _evaluate path. For at/above legs the warning trace
      // events are already written during the workload via
      // _recordIssuesForCapture from the controller's scan loop. The
      // explicit Sleuth.flushTimelineNow() below is the deterministic
      // VM-poll barrier used by HeavyCompute / FrameTiming captures —
      // it guarantees pending detector emissions are drained into the
      // VM trace buffer before markScenarioEnd closes the span.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final monitor = Sleuth.networkMonitor;
      if (monitor == null) {
        _endScenarioOnce(scenarioName);
        Sleuth.resumeAllTimelineStreams();
        if (!mounted) return;
        setState(() {
          _busy = false;
          _log.add(
            '[$label] FAILED: Sleuth.networkMonitor is null. '
            'Verify Sleuth.init() ran with captureMode=true and '
            '--dart-define=SLEUTH_CAPTURE_MODE=true.',
          );
        });
        return;
      }
      monitor.flushFrequencyEvaluation();
      // Read the detector-measured peak AFTER the flush. Below-leg
      // (sub-threshold) has no warning event for the schema's
      // observedAxisArgKey cross-check to pin against, so the
      // exported magnitude must come from the same axis the detector
      // classifies on rather than the operator's planned send count.
      observedCount = monitor.lastObservedPeakCount;
      // Drain detector emissions into the VM trace buffer before the
      // scenario closes. Without this, the LAST in-span emission can
      // land in trace records with a `ts` after markScenarioEnd, and
      // the audit gate filters it out for ts > spanHi.
      await Sleuth.flushTimelineNow(timeout: const Duration(seconds: 2));
      _endScenarioOnce(scenarioName);
      await Future<void>.delayed(const Duration(milliseconds: 800));

      Sleuth.resumeAllTimelineStreams();

      if (!mounted) return;
      setState(() {
        _busy = false;
        _lastCompletedLeg = label;
        _lastCompletedMode = _CaptureMode.requestFrequency;
        _lastObservedCount = observedCount;
        _log.add(
          '[$label] scenario.end ($observedCount requests sent across '
          '${DateTime.now().difference(scenarioStart).inMilliseconds}ms) '
          '— tap "Export last leg" to write the wrapped capture.',
        );
      });
      messenger.showSnackBar(
        SnackBar(
          content: Text('$label OK ($observedCount sent). Tap Export now.'),
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (e, st) {
      _endScenarioOnce(scenarioName);
      Sleuth.resumeAllTimelineStreams();
      developer.log(
        '[sleuth.capture] FAILED $label: $e',
        name: 'sleuth.capture',
        error: e,
        stackTrace: st,
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _log.add('[$label] FAILED: $e');
      });
    }
  }

  /// Composes the wrapped capture JSON for the most recent completed
  /// leg and copies it to the iOS clipboard. Operator pastes into
  /// Notes / Mail / AirDrop note → sends to Mac → saves under
  /// `test/validation/captures/network_monitor/`.
  Future<void> _exportLastLeg() async {
    final leg = _lastCompletedLeg;
    final mode = _lastCompletedMode;
    final messenger = ScaffoldMessenger.of(context);
    if (leg == null || mode == null) {
      setState(() {
        _log.add(
          'Export: no completed leg yet. Tap a leg button and wait '
          'for "tap Export" before exporting.',
        );
      });
      return;
    }
    // slow_request critical-tier captures need the `_critical_` infix
    // to land at distinct file paths from the warning triad. Other
    // modes are single-tier so the mode.stableId prefix is unambiguous.
    final tier = _lastCompletedTier;
    final scenarioName = (mode == _CaptureMode.slowRequest && tier != null)
        ? _slowRequestScenarioName(tier, leg)
        : '${mode.stableId}_$leg';
    final bracketSeverityLabel =
        (mode == _CaptureMode.slowRequest && tier != null)
        ? tier.label
        : 'warning';
    final (
      int magnitudeMin,
      int magnitudeObserved,
      int magnitudeMax,
      String unit,
    )
    magnitude;
    switch (mode) {
      case _CaptureMode.slowRequest:
        final ms = _lastMeasuredMs;
        if (ms == null) {
          setState(() => _log.add('Export: missing slow_request ms.'));
          return;
        }
        magnitude = ((ms - 50).clamp(0, 1 << 30), ms, ms + 50, 'ms');
      case _CaptureMode.largeResponse:
        final bytes = _lastObservedBytes;
        if (bytes == null) {
          setState(() => _log.add('Export: missing large_response bytes.'));
          return;
        }
        magnitude = (
          (bytes - 1024).clamp(0, 1 << 30),
          bytes,
          bytes + 1024,
          'bytes',
        );
      case _CaptureMode.requestFrequency:
        final count = _lastObservedCount;
        if (count == null) {
          setState(() => _log.add('Export: missing request_frequency count.'));
          return;
        }
        magnitude = ((count - 2).clamp(0, 1 << 30), count, count + 2, 'events');
    }

    setState(() {
      _busy = true;
      _log.add('[$leg] Export: composing wrapped capture JSON…');
    });

    String? json;
    try {
      json = await Sleuth.exportCaptureJson(
        scenario: scenarioName,
        role: leg, // 'below' | 'at' | 'above'
        magnitudeMin: magnitude.$1,
        magnitudeObserved: magnitude.$2,
        magnitudeMax: magnitude.$3,
        unit: magnitude.$4,
        device: 'iPhone 12',
        deviceOsVersion: 'iOS 17.5',
        flutterVersion: '3.41.4',
        captureCommand:
            'fvm flutter run --profile -d "iPhone 12" '
            '--dart-define=SLEUTH_CAPTURE_MODE=true',
        // Magnitude is measured directly from request observations
        // (Stopwatch ms, response bytes, peak count). No matching
        // named timeline event the schema can derive from, so pass
        // empty string to skip BUILD-derivation.
        magnitudeSourceEventName: '',
        // Client-side mirror of the schema's per-leg trace-record
        // contract: at/above must contain the matching issue event
        // in span; below must contain none. Refused exports surface
        // a debugPrint diagnostic before JSON hits the clipboard so
        // operators see the failure mode without waiting for
        // test-time audit rejection.
        bracketStableId: mode.stableId,
        bracketSeverityLabel: bracketSeverityLabel,
      );
    } catch (e) {
      json = null;
      if (mounted) {
        setState(() {
          _log.add('[$leg] Export FAILED: $e');
        });
      }
    }
    if (!mounted) return;
    if (json == null) {
      setState(() {
        _busy = false;
        _log.add(
          '[$leg] Export FAILED: returned null. Common causes: VM '
          'service disconnected (FRAME mode — kill the app from Xcode '
          'and re-open from the home screen so VM+ mode activates), '
          'or scenario markers missing from the trace buffer (re-tap '
          'the leg and Export within 30 s).',
        );
      });
      return;
    }
    final jsonText = json;
    try {
      await Clipboard.setData(ClipboardData(text: jsonText));
      if (!mounted) return;
      setState(() {
        _busy = false;
        _log.add(
          '[$leg] Export OK — wrapped capture '
          '(${jsonText.length} chars) copied to iOS clipboard.',
        );
        _log.add(
          '[$leg] Paste into Notes / Mail / AirDrop note → send to '
          'Mac. Save the pasted JSON as $scenarioName.json under '
          'test/validation/captures/network_monitor/.',
        );
      });
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Capture copied to clipboard. Paste anywhere to share.',
          ),
          duration: Duration(seconds: 6),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _log.add('[$leg] Clipboard copy FAILED: $e');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready = _server != null && _client != null;
    return Scaffold(
      appBar: AppBar(title: const Text('NetworkMonitor capture helper')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<_CaptureMode>(
                initialValue: _mode,
                decoration: const InputDecoration(
                  labelText: 'Capture mode',
                  border: OutlineInputBorder(),
                ),
                items: _CaptureMode.values.map((m) {
                  return DropdownMenuItem(value: m, child: Text(m.label));
                }).toList(),
                onChanged: _busy
                    ? null
                    : (m) {
                        if (m == null) return;
                        setState(() {
                          _mode = m;
                          _resetLastLeg();
                        });
                      },
              ),
              if (_mode == _CaptureMode.slowRequest) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<_Tier>(
                  initialValue: _slowRequestTier,
                  decoration: const InputDecoration(
                    labelText: 'Severity tier',
                    border: OutlineInputBorder(),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: _Tier.warning,
                      child: Text('Warning (1000 ms)'),
                    ),
                    DropdownMenuItem(
                      value: _Tier.critical,
                      child: Text('Critical (3000 ms)'),
                    ),
                  ],
                  onChanged: _busy
                      ? null
                      : (next) {
                          if (next == null || next == _slowRequestTier) return;
                          setState(() {
                            _slowRequestTier = next;
                            _resetLastLeg();
                            _log.add(
                              'Switched slow_request tier → ${next.label} '
                              '(threshold ${next.thresholdMs} ms). '
                              'Leg targets retuned.',
                            );
                          });
                        },
                ),
              ],
              const SizedBox(height: 12),
              Text(_modeBlurb(_mode), style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 16),
              ..._buildLegButtons(ready),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _busy ? null : _exportLastLeg,
                icon: const Icon(Icons.save_alt),
                label: const Text('Export last leg'),
              ),
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 8),
              const Text('Log', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Expanded(
                child: ListView.builder(
                  reverse: true,
                  itemCount: _log.length,
                  itemBuilder: (context, i) {
                    final line = _log[_log.length - 1 - i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        line,
                        style: const TextStyle(
                          fontSize: 12,
                          fontFamily: 'monospace',
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _modeBlurb(_CaptureMode mode) {
    switch (mode) {
      case _CaptureMode.slowRequest:
        return 'slow_request WARNING tier (1000 ms threshold). Above '
            'preset stays inside [1000, 2000) so the artifact cannot '
            'ambiently bracket the 3000 ms critical tier.';
      case _CaptureMode.largeResponse:
        return 'large_response WARNING tier (1 MB threshold). No '
            'critical tier on this family — above-leg ceiling is '
            '2.0× threshold (2 MB).';
      case _CaptureMode.requestFrequency:
        return 'request_frequency WARNING tier (> 30 req per 5 s '
            'sliding window). At-band [30, 45] (atTolerance 0.50 '
            'absorbs iOS scheduling jitter on Dart HttpClient). '
            'Above-ceiling 60 (2.0×) — no critical tier.';
    }
  }

  List<Widget> _buildLegButtons(bool ready) {
    switch (_mode) {
      case _CaptureMode.slowRequest:
        final tier = _slowRequestTier;
        final below = _slowRequestLegSpec(tier, 'below');
        final at = _slowRequestLegSpec(tier, 'at');
        final above = _slowRequestLegSpec(tier, 'above');
        final belowSubtitle = tier == _Tier.warning
            ? 'Under 1000 ms slow threshold; detector silent'
            : 'Between 1000 ms and 3000 ms — fires .warning, NOT .critical';
        return [
          _CaptureButton(
            label:
                'Below (${below.delayMs} ms) — '
                '${tier == _Tier.warning ? "silent" : "warning fires"}',
            subtitle: belowSubtitle,
            enabled: ready && !_busy,
            onTap: () => _runSlowRequestCapture(
              tier: tier,
              label: 'below',
              delayMs: below.delayMs,
            ),
          ),
          const SizedBox(height: 8),
          _CaptureButton(
            label: 'At (${at.delayMs} ms) — ${tier.label}',
            subtitle:
                'In [${at.msMin}, ${at.msMax}] at-band '
                '(${tier == _Tier.warning ? "10% tolerance" : "40% tolerance"})',
            enabled: ready && !_busy,
            onTap: () => _runSlowRequestCapture(
              tier: tier,
              label: 'at',
              delayMs: at.delayMs,
            ),
          ),
          const SizedBox(height: 8),
          _CaptureButton(
            label: 'Above (${above.delayMs} ms) — ${tier.label}',
            subtitle:
                'In (${above.msMin}, ${above.msMax}] above-band'
                '${tier == _Tier.warning ? "; stays under 3000 ms crit" : "; ceiling 6000 ms (2.0×)"}',
            enabled: ready && !_busy,
            onTap: () => _runSlowRequestCapture(
              tier: tier,
              label: 'above',
              delayMs: above.delayMs,
            ),
          ),
        ];
      case _CaptureMode.largeResponse:
        return [
          _CaptureButton(
            label: 'Below (800 KB) — passes',
            subtitle: 'Under 1 MB large_response threshold',
            enabled: ready && !_busy,
            onTap: () => _runLargeResponseCapture(
              label: 'below',
              responseBytes: 800 * 1024,
            ),
          ),
          const SizedBox(height: 8),
          _CaptureButton(
            label: 'At (1.05 MB) — warning',
            subtitle: 'In [1 MB, 1.1 MB] at-band (10% tolerance)',
            enabled: ready && !_busy,
            onTap: () =>
                _runLargeResponseCapture(label: 'at', responseBytes: 1101000),
          ),
          const SizedBox(height: 8),
          _CaptureButton(
            label: 'Above (1.5 MB) — warning',
            subtitle: 'In (1 MB, 2 MB) above-band; ceiling 2 MB (2.0×)',
            enabled: ready && !_busy,
            onTap: () => _runLargeResponseCapture(
              label: 'above',
              responseBytes: 1572864,
            ),
          ),
        ];
      case _CaptureMode.requestFrequency:
        return [
          _CaptureButton(
            label: 'Below (25 req) — passes',
            subtitle: 'Under 30-req/5s frequency threshold',
            enabled: ready && !_busy,
            onTap: () =>
                _runRequestFrequencyCapture(label: 'below', requestCount: 25),
          ),
          const SizedBox(height: 8),
          _CaptureButton(
            label: 'At (38 req) — warning',
            subtitle: 'In [30, 45] at-band (50% tolerance for iOS jitter)',
            enabled: ready && !_busy,
            onTap: () =>
                _runRequestFrequencyCapture(label: 'at', requestCount: 38),
          ),
          const SizedBox(height: 8),
          _CaptureButton(
            label: 'Above (52 req) — warning',
            subtitle: 'In (45, 60] above-band; ceiling 60 (2.0×)',
            enabled: ready && !_busy,
            onTap: () =>
                _runRequestFrequencyCapture(label: 'above', requestCount: 52),
          ),
        ];
    }
  }
}

class _CaptureButton extends StatelessWidget {
  const _CaptureButton({
    required this.label,
    required this.subtitle,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final String subtitle;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      onPressed: enabled ? onTap : null,
      style: ElevatedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
        alignment: Alignment.centerLeft,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          Text(
            subtitle,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w400),
          ),
        ],
      ),
    );
  }
}
