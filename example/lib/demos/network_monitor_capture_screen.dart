import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/material.dart';

/// Capture helper for the planned v0.16.5 `externallyCited` tier raise
/// on `NetworkMonitorDetector.slow_request` **WARNING tier only**.
///
/// This screen produces three deterministic profile-mode timeline
/// captures — below / at / above the detector's 1000 ms slow threshold —
/// that `ProfileCaptureSchema.validateBracket` will accept. The `above`
/// preset is deliberately capped well under the 3000 ms critical tier so
/// the artifact on disk cannot ambiently bracket the critical threshold
/// (see detector rationale and
/// `ProfileCaptureSchema.defaultAboveCeilingMultiplier`).
///
/// This helper is scoped to the warning tier. A critical-tier (3000 ms)
/// protocol is reserved for a future raise with its own below/at/above
/// triad recorded inside the critical band with an appropriate
/// `aboveCeilingMultiplier` on the detector's metadata.
///
/// Preset sizing rule: the **Above**
/// preset sits at the midpoint of the acceptable band
/// `(threshold, threshold × aboveCeilingMultiplier)`, i.e. approximately
/// `threshold × (1 + aboveCeilingMultiplier) / 2`. At the shipped
/// warning defaults (`threshold = 1000 ms`, schema
/// `defaultAboveCeilingMultiplier = 2.0`, ceiling at 2000 ms) the
/// midpoint is exactly 1500 ms — the shipped **Above (1500 ms)** preset
/// lands squarely in the middle of `(1000 ms, 2000 ms]` with ~500 ms
/// headroom against device jitter on either side. When re-tuning (new
/// `aboveCeilingMultiplier`, new warning threshold), re-derive the
/// preset from this rule rather than hand-picking a value: an `above`
/// preset at or just under `threshold × aboveCeilingMultiplier` risks
/// silent CI rejection if device jitter pushes any single recording
/// past the ceiling.
///
/// Protocol:
///
///  1. `fvm flutter run --profile` on a device in the pinned matrix
///     (v0.16.4: iPhone 12 / iOS 17.5 is the primary recording device).
///  2. Open DevTools Performance tab, clear timeline.
///  3. Tap **Below (800 ms)**, wait ~1 s for `scenario.end` marker.
///  4. DevTools → Performance → Export timeline → save as
///     `slow_request_below.json` (raw Chrome Trace Event Format).
///  5. Repeat for **At (1020 ms)** and **Above (1500 ms)**.
///  6. Wrap each export with the `sleuthMetadata` block described in
///     `test/validation/captures/README.md` and drop the files under
///     `test/validation/captures/network_monitor/`.
///
/// Why a loopback HTTP server: a real remote would be non-deterministic
/// (DNS, transit jitter, server-side variance) so bracket magnitudes
/// would drift between recordings and `validateBracket`'s ±10% at-band
/// would reject some captures as out-of-band. The loopback server
/// delays the response by exactly the requested duration, so each
/// capture lands inside its target bracket on the first try.
///
/// Why `Timeline.instantSync` markers: `ProfileCaptureSchema`'s AB-1
/// cross-check binds the observed-magnitude claim to the
/// `sleuth.scenario.begin` / `sleuth.scenario.end` instant-event pair
/// (ph=`i`), not to the min/max timestamp across the whole capture.
/// Without these markers, a capture containing a 50-second cold-start
/// warmup would appear to have an observed magnitude of ~50 s, failing
/// the 100× trace-vs-observed ratio invariant. The markers pin the
/// scenario span to the request itself.
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
      _log.add('[$label] scenario.begin → GET /slow?delay=$delayMs');
    });

    // Scenario span pinned for ProfileCaptureSchema AB-1 cross-check.
    // ph=`i` (instant) events — `Timeline.instantSync` is the source-of-truth
    // emitter per `dart:developer/Timeline`.
    developer.Timeline.instantSync('sleuth.scenario.begin');
    developer.log(
      '[sleuth.capture] begin $label (delay=${delayMs}ms)',
      name: 'sleuth.capture',
    );

    var bytes = 0;
    final stopwatch = Stopwatch()..start();
    try {
      final uri = Uri.parse(
        'http://127.0.0.1:${server.port}/slow?delay=$delayMs',
      );
      final req = await client.getUrl(uri);
      final resp = await req.close();
      // Drain response. `await for` (not `.drain()`) per the v0.16.1
      // proxy-onDone limitation documented in NetworkMonitorDetector
      // pipeline — `.drain()` replaces the wrapping `onDone` handler
      // and suppresses `RequestRecord` emission.
      await for (final chunk in resp) {
        bytes += chunk.length;
      }
      stopwatch.stop();

      developer.Timeline.instantSync('sleuth.scenario.end');
      developer.log(
        '[sleuth.capture] end $label (${stopwatch.elapsedMilliseconds}ms, ${bytes}B)',
        name: 'sleuth.capture',
      );

      // Post-end dwell: Dart Timeline events buffer on the VM before
      // DevTools drains them. Exporting immediately after
      // `scenario.end` fires can miss the event and produce a capture
      // with only the begin marker — which then fails AB-1. 1.5 s is
      // conservatively longer than the VM's default drain cadence.
      await Future<void>.delayed(const Duration(milliseconds: 1500));

      if (!mounted) return;
      setState(() {
        _log.add(
          '[$label] scenario.end (${stopwatch.elapsedMilliseconds} ms, $bytes B) — safe to Export',
        );
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '$label OK (${stopwatch.elapsedMilliseconds} ms). Export timeline now.',
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (e, st) {
      developer.Timeline.instantSync('sleuth.scenario.end');
      developer.log(
        '[sleuth.capture] FAILED $label: $e',
        name: 'sleuth.capture',
        error: e,
        stackTrace: st,
      );
      if (!mounted) return;
      setState(() => _log.add('[$label] FAILED: $e'));
    } finally {
      if (mounted) setState(() => _busy = false);
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
