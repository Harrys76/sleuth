import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sleuth/sleuth.dart';

/// Capture helper for the v0.18.0 `runtimeVerified` tier raise on
/// `NetworkMonitorDetector.slow_request` **WARNING tier only**.
///
/// Produces three deterministic profile-mode timeline captures — below
/// / at / above the detector's 1000 ms slow threshold — that
/// `ProfileCaptureSchema.validateBracket(... requireDetectorTraceRecord:
/// true, stableId: 'slow_request', severityLabel: 'warning')` will
/// accept. The `above` preset stays under the 3000 ms critical tier so
/// the artifact cannot ambiently bracket the critical threshold.
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
///     completions and emits `sleuth.issue.slow_request.warning`
///     trace records.
///  4. Navigate to "NetworkMonitor capture helper" → tap a leg
///     (Below 800 ms, At 1020 ms, Above 1500 ms) → wait for
///     "tap Export now" log line → tap **Export last leg**.
///  5. Capture screen calls `Sleuth.exportCaptureJson` which fetches
///     the VM Timeline, filters to the matching scenario span, wraps
///     with `sleuthMetadata`, and copies the JSON to the iOS
///     clipboard. Paste into Notes / Mail / AirDrop note → send to
///     Mac. One leg at a time — clipboard holds one capture; tap
///     next leg, paste, repeat.
///  6. Save each pasted JSON as
///     `slow_request_<leg>.json` under
///     `test/validation/captures/network_monitor/`.
///
/// **Scenario span timing**: `markScenarioEnd` is intentionally called
/// AFTER a 200 ms post-completion dwell. The detector's
/// `_recordIssuesForCapture` emission goes through async callback paths
/// (frame stats, structural scan, VM poll). Calling `markScenarioEnd`
/// immediately after the request completes would place the trace event
/// outside the scenario window. The 200 ms dwell guarantees ~12 frame
/// stats callbacks fire (60 Hz), at least one of which flushes the
/// `sleuth.issue.slow_request.warning` event into the trace buffer
/// with a `ts` strictly inside `[scenario.begin, scenario.end]`.
///
/// **Why a loopback HTTP server**: a real remote would be
/// non-deterministic (DNS, transit jitter, server-side variance) so
/// bracket magnitudes would drift between recordings and
/// `validateBracket`'s ±10% at-band would reject some captures. The
/// loopback server delays the response by exactly the requested
/// duration, so each capture lands inside its target bracket on the
/// first try.
class NetworkMonitorCaptureScreen extends StatefulWidget {
  const NetworkMonitorCaptureScreen({super.key});

  @override
  State<NetworkMonitorCaptureScreen> createState() =>
      _NetworkMonitorCaptureScreenState();
}

class _NetworkMonitorCaptureScreenState
    extends State<NetworkMonitorCaptureScreen> {
  HttpServer? _server;
  HttpClient? _client;
  final List<String> _log = [];
  bool _busy = false;

  // Last completed leg state — what the Export button serialises.
  // Cleared on each new leg request so the operator cannot accidentally
  // export an out-of-band run from an earlier session.
  String? _lastCompletedLeg;
  int? _lastMeasuredMs;

  @override
  void initState() {
    super.initState();
    _startServer();
  }

  @override
  void dispose() {
    // v0.16.4 post-review MED-3: fire-and-forget `close()` without `await`
    // is safe here because `dispose` cannot be async, but we still want
    // the close to actually run before the State is collected. Assign to
    // `unawaited` so the analyzer doesn't flag it, and mark the fields
    // null so stray late callbacks after dispose short-circuit.
    final client = _client;
    final server = _server;
    _client = null;
    _server = null;
    client?.close(force: true);
    // `HttpServer.close(force: true)` returns a Future; fire-and-forget
    // is the only option from a sync `dispose`. The loopback socket is
    // process-scoped so the OS reclaims it either way.
    unawaited(server?.close(force: true) ?? Future<void>.value());
    super.dispose();
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
          // v0.16.4 post-review MED-3: wrap the per-request handler in a
          // try/catch. A client that disconnects mid-delay (app reload,
          // user back-navigation) throws on `req.response.close()`; the
          // default behaviour unwinds into the unhandled stream onError
          // and the log surface tells the user nothing. Catch + log so
          // an unexpected recording failure is visible in-screen.
          try {
            final delayMs =
                int.tryParse(req.uri.queryParameters['delay'] ?? '') ?? 0;
            if (delayMs > 0) {
              await Future<void>.delayed(Duration(milliseconds: delayMs));
            }
            req.response.headers.contentType = ContentType.json;
            req.response.write(jsonEncode({'ok': true, 'delayMs': delayMs}));
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

  Future<void> _runCapture({
    required String label,
    required int delayMs,
  }) async {
    final server = _server;
    final client = _client;
    if (server == null || client == null || _busy) return;
    setState(() {
      _busy = true;
      _lastCompletedLeg = null;
      _lastMeasuredMs = null;
      _log.add('[$label] scenario.begin → GET /slow?delay=$delayMs');
    });

    // Scenario span via Sleuth public API. Triple-gated on captureMode
    // so production runs see no extra Timeline traffic.
    //
    // markScenarioBegin auto-resets the producer-side capture-emission
    // dedup set AND per-detector record buffers (NetworkMonitor +
    // future runtimeVerified detectors). No explicit clearRecords call
    // is needed here — the leg-boundary contract is owned by
    // markScenarioBegin so a multi-leg flow on this screen cannot leak
    // leg N records into leg N+1 emissions.
    final scenarioName = 'slow_request_$label';
    Sleuth.markScenarioBegin(scenarioName);
    final messenger = ScaffoldMessenger.of(context);

    var bytes = 0;
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
      await for (final chunk in resp) {
        bytes += chunk.length;
      }
      stopwatch.stop();
      final measuredMs = stopwatch.elapsedMilliseconds;

      // Post-completion dwell BEFORE markScenarioEnd. `_recordIssuesForCapture`
      // emits the `sleuth.issue.slow_request.warning` trace event from one
      // of three async callback paths (structural scan, VM poll, frame
      // stats) AFTER the request completes. With markScenarioEnd called
      // immediately, the trace event would land outside the scenario span
      // and the audit would reject the capture. The 200ms delay guarantees
      // ~12 frame_stats callbacks fire (60 Hz) — far more than needed for
      // one of them to flush the issue into the trace buffer with a `ts`
      // strictly inside [scenario.begin, scenario.end].
      await Future<void>.delayed(const Duration(milliseconds: 200));
      Sleuth.markScenarioEnd(scenarioName);

      // Additional dwell so the VM Timeline buffer drains before
      // exportCaptureJson reads it. Cheaper than the 1500 ms the
      // pre-Sleuth.markCaptureIssue procedure used because the trace
      // event has already been emitted into the ring buffer.
      await Future<void>.delayed(const Duration(milliseconds: 800));

      if (!mounted) return;
      setState(() {
        _busy = false;
        _lastCompletedLeg = label;
        _lastMeasuredMs = measuredMs;
        _log.add(
          '[$label] scenario.end (${measuredMs}ms, ${bytes}B) — '
          'tap "Export last leg" to write the wrapped capture.',
        );
      });
      messenger.showSnackBar(
        SnackBar(
          content: Text('$label OK (${measuredMs}ms). Tap Export now.'),
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (e, st) {
      // On failure still close the scenario so the buffer doesn't
      // accumulate orphan begins. The audit will reject any export
      // anyway because the issue trace event is missing.
      Sleuth.markScenarioEnd(scenarioName);
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
    final measured = _lastMeasuredMs;
    final messenger = ScaffoldMessenger.of(context);
    if (leg == null || measured == null) {
      setState(() {
        _log.add(
          'Export: no completed leg yet. Tap a leg button and wait '
          'for "tap Export" before exporting.',
        );
      });
      return;
    }
    setState(() {
      _busy = true;
      _log.add('[$leg] Export: composing wrapped capture JSON…');
    });
    String? json;
    try {
      json = await Sleuth.exportCaptureJson(
        scenario: 'slow_request_$leg',
        magnitudeMin: (measured - 50).clamp(0, 1 << 30).toInt(),
        magnitudeObserved: measured,
        magnitudeMax: measured + 50,
        unit: 'ms',
        device: 'iPhone 12',
        deviceOsVersion: 'iOS 17.5',
        flutterVersion: '3.41.4',
        captureCommand:
            'fvm flutter run --profile -d "iPhone 12" '
            '--dart-define=SLEUTH_CAPTURE_MODE=true',
        // NetworkMonitor's slow_request magnitude is the request's
        // wall-clock duration measured by Stopwatch. There is no
        // matching named timeline event the schema can derive from,
        // so pass empty string to skip BUILD-derivation and trust
        // the caller-supplied value.
        magnitudeSourceEventName: '',
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
          'Mac. Save the pasted JSON as '
          'slow_request_$leg.json under '
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
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Records profile-mode captures for slow_request WARNING-tier '
              'bracketing (1000 ms threshold). Above preset stays inside '
              '[1000, 2000) so the artifact cannot ambiently bracket the '
              '3000 ms critical tier. See class docstring for the full '
              'recording protocol.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 16),
            _CaptureButton(
              label: 'Below (800 ms) — passes',
              subtitle: 'Under 1000 ms slow threshold',
              enabled: ready && !_busy,
              onTap: () => _runCapture(label: 'below', delayMs: 800),
            ),
            const SizedBox(height: 8),
            _CaptureButton(
              label: 'At (1020 ms) — warning',
              subtitle: 'In [1000, 1100] at-band (±10% tolerance)',
              enabled: ready && !_busy,
              onTap: () => _runCapture(label: 'at', delayMs: 1020),
            ),
            const SizedBox(height: 8),
            _CaptureButton(
              label: 'Above (1500 ms) — warning',
              subtitle:
                  'In (1000, 2000) warning band; stays under 3000 ms crit',
              enabled: ready && !_busy,
              onTap: () => _runCapture(label: 'above', delayMs: 1500),
            ),
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
    );
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
