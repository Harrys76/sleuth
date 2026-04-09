import 'dart:io';

import 'package:flutter/material.dart';

import '../demo_scaffold.dart';

// ─────────────────────────────────────────
// Demo 15: Network Stress
// Triggers: NetworkMonitor detector (slow, frequency, large)
// ─────────────────────────────────────────

/// Demonstrates three network anti-patterns: slow requests, request
/// frequency spikes, and oversized responses. The fix demonstrates the
/// *presence* of a cache (a single request, subsequent taps are served
/// from memory) and pagination (a small page instead of 2MB).
class NetworkStressDemo extends StatefulWidget {
  const NetworkStressDemo({super.key});

  @override
  State<NetworkStressDemo> createState() => _NetworkStressDemoState();
}

class _NetworkStressDemoState extends State<NetworkStressDemo> {
  /// Soft cap on log lines. Prevents the list from growing unbounded
  /// if the demo is left running — otherwise each toggle/tap appends
  /// entries forever and eventually janks the ListView that renders
  /// them.
  static const _maxLogLines = 200;

  final List<String> _log = [];
  bool _running = false;

  /// Total requests issued during the current session (both modes).
  final ValueNotifier<int> _requestCount = ValueNotifier<int>(0);

  /// Client used by the fixed body to cache the first response.
  String? _cachedSmallResponse;

  void _addLog(String message) {
    if (!mounted) return;
    setState(() {
      _log.add(message);
      if (_log.length > _maxLogLines) {
        _log.removeRange(0, _log.length - _maxLogLines);
      }
    });
  }

  void _handleToggle(bool isFixed) {
    _addLog(
      isFixed
          ? '--- Switched to fixed pattern ---'
          : '--- Back to bad pattern ---',
    );
  }

  // ── Bad patterns ──────────────────────────────────────────

  Future<void> _triggerSlowRequest() async {
    _addLog('Sending slow request (3s delay)...');
    _requestCount.value++;
    final client = HttpClient();
    try {
      final request = await client.getUrl(
        Uri.parse('https://httpbin.org/delay/3'),
      );
      final response = await request.close();
      await response.drain<void>();
      if (!mounted) return;
      _addLog('Slow request done: ${response.statusCode}');
    } catch (e) {
      if (!mounted) return;
      _addLog('Slow request error: $e');
    } finally {
      client.close();
    }
  }

  Future<void> _triggerFrequencySpike() async {
    _addLog('Firing 40 rapid requests...');
    final client = HttpClient();
    var completed = 0;
    try {
      final futures = <Future>[];
      for (var i = 0; i < 40; i++) {
        _requestCount.value++;
        futures.add(() async {
          try {
            final req = await client.getUrl(
              Uri.parse('https://httpbin.org/get?i=$i'),
            );
            final res = await req.close();
            await res.drain<void>();
            completed++;
          } catch (_) {
            completed++;
          }
        }());
      }
      await Future.wait(futures);
      if (!mounted) return;
      _addLog('Frequency spike done: $completed/40 completed');
    } finally {
      // Always close even if the widget was disposed mid-flight —
      // otherwise the HttpClient leaks until GC.
      client.close(force: true);
    }
  }

  Future<void> _triggerLargeResponse() async {
    _addLog('Requesting 2MB response...');
    _requestCount.value++;
    final client = HttpClient();
    try {
      final request = await client.getUrl(
        Uri.parse('https://httpbin.org/bytes/2000000'),
      );
      final response = await request.close();
      var bytes = 0;
      await response.listen((chunk) => bytes += chunk.length).asFuture<void>();
      if (!mounted) return;
      _addLog('Large response done: $bytes bytes');
    } catch (e) {
      if (!mounted) return;
      _addLog('Large response error: $e');
    } finally {
      client.close();
    }
  }

  Future<void> _triggerAll() async {
    if (_running) return;
    setState(() {
      _running = true;
      _log.clear();
    });
    _addLog('--- Triggering all 3 issue types ---');
    await Future.wait([
      _triggerSlowRequest(),
      _triggerFrequencySpike(),
      _triggerLargeResponse(),
    ]);
    if (!mounted) return;
    _addLog('--- All done. Check the Sleuth overlay. ---');
    setState(() => _running = false);
  }

  // ── Fixed patterns ────────────────────────────────────────

  /// Cached fetch — only the first tap issues a request; later taps
  /// return the cached value and do not bump the request counter.
  Future<void> _triggerCached() async {
    if (_cachedSmallResponse != null) {
      _addLog('Served from in-memory cache (0 network calls).');
      return;
    }
    _addLog('First fetch — issuing one request and caching the result...');
    _requestCount.value++;
    final client = HttpClient();
    try {
      final request = await client.getUrl(
        Uri.parse('https://httpbin.org/get?cached=1'),
      );
      final response = await request.close();
      await response.drain<void>();
      if (!mounted) return;
      _cachedSmallResponse = '<cached ${response.statusCode}>';
      _addLog('Cached. Subsequent taps will be 0 requests.');
    } catch (e) {
      if (!mounted) return;
      _addLog('Cached fetch error: $e');
    } finally {
      client.close();
    }
  }

  /// Paginated fetch — one small page at a time instead of a 2MB blob.
  Future<void> _triggerPaginated() async {
    _addLog('Fetching 1 page of 20 items...');
    _requestCount.value++;
    final client = HttpClient();
    try {
      final request = await client.getUrl(
        Uri.parse('https://httpbin.org/bytes/20000'),
      );
      final response = await request.close();
      var bytes = 0;
      await response.listen((chunk) => bytes += chunk.length).asFuture<void>();
      if (!mounted) return;
      _addLog('Page done: $bytes bytes (fits in a single small payload).');
    } catch (e) {
      if (!mounted) return;
      _addLog('Paginated fetch error: $e');
    } finally {
      client.close();
    }
  }

  @override
  void dispose() {
    _requestCount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DemoScaffold(
      title: 'Network Stress',
      description:
          '❌ BAD: Slow requests (3s delays), request floods (40 parallel '
          'gets), and oversized responses (2MB). NetworkMonitor flags all '
          'three.\n'
          '✅ FIX: Cache frequently-fetched data, paginate large responses, '
          'and debounce rapid requests.\n\n'
          '▶ Tap any of the bad buttons, watch the "Requests" chip climb, '
          'then flip to Fixed Pattern — the cached button makes at most 1 '
          'request and pagination keeps responses small.\n\n'
          'Requires internet connectivity.',
      metricsBar: MetricsBar(
        chips: [
          ValueListenableBuilder<int>(
            valueListenable: _requestCount,
            builder: (_, v, _) => MetricChip(label: 'Requests', value: '$v'),
          ),
        ],
      ),
      onToggle: _handleToggle,
      body: _buildBody(bad: true),
      fixedBody: _buildBody(bad: false),
    );
  }

  Widget _buildBody({required bool bad}) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: bad
                ? [
                    FilledButton.icon(
                      onPressed: _running ? null : _triggerSlowRequest,
                      icon: const Icon(Icons.hourglass_bottom),
                      label: const Text('Slow (3s)'),
                    ),
                    FilledButton.icon(
                      onPressed: _running ? null : _triggerFrequencySpike,
                      icon: const Icon(Icons.bolt),
                      label: const Text('40x Burst'),
                    ),
                    FilledButton.icon(
                      onPressed: _running ? null : _triggerLargeResponse,
                      icon: const Icon(Icons.file_download),
                      label: const Text('2MB'),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: _running ? null : _triggerAll,
                      icon: const Icon(Icons.warning_amber),
                      label: const Text('All 3'),
                    ),
                  ]
                : [
                    FilledButton.icon(
                      onPressed: _triggerCached,
                      icon: const Icon(Icons.cached),
                      label: const Text('Cached fetch'),
                    ),
                    FilledButton.icon(
                      onPressed: _triggerPaginated,
                      icon: const Icon(Icons.view_stream),
                      label: const Text('Paginated page'),
                    ),
                  ],
          ),
        ),
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: ListView.builder(
                itemCount: _log.length,
                itemBuilder: (_, i) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    _log[i],
                    style: const TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }
}
