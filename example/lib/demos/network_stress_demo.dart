import 'dart:io';

import 'package:flutter/material.dart';

// ─────────────────────────────────────────
// Demo 15: Network Stress
// Triggers: NetworkMonitor detector (slow, frequency, large)
// ─────────────────────────────────────────
class NetworkStressDemo extends StatefulWidget {
  const NetworkStressDemo({super.key});

  @override
  State<NetworkStressDemo> createState() => _NetworkStressDemoState();
}

class _NetworkStressDemoState extends State<NetworkStressDemo> {
  final List<String> _log = [];
  bool _running = false;

  void _addLog(String message) {
    setState(() => _log.add(message));
  }

  Future<void> _triggerSlowRequest() async {
    _addLog('Sending slow request (3s delay)...');
    final client = HttpClient();
    try {
      final request = await client.getUrl(
        Uri.parse('https://httpbin.org/delay/3'),
      );
      final response = await request.close();
      await response.drain<void>();
      _addLog('Slow request done: ${response.statusCode}');
    } catch (e) {
      _addLog('Slow request error: $e');
    } finally {
      client.close();
    }
  }

  Future<void> _triggerFrequencySpike() async {
    _addLog('Firing 40 rapid requests...');
    final client = HttpClient();
    var completed = 0;
    final futures = <Future>[];
    for (var i = 0; i < 40; i++) {
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
    _addLog('Frequency spike done: $completed/40 completed');
    client.close();
  }

  Future<void> _triggerLargeResponse() async {
    _addLog('Requesting 2MB response...');
    final client = HttpClient();
    try {
      final request = await client.getUrl(
        Uri.parse('https://httpbin.org/bytes/2000000'),
      );
      final response = await request.close();
      var bytes = 0;
      await response.listen((chunk) => bytes += chunk.length).asFuture<void>();
      _addLog('Large response done: $bytes bytes');
    } catch (e) {
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
    _addLog('--- All done. Check the Sleuth overlay. ---');
    setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Network Stress')),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '❌ BAD: Slow requests, request floods, and oversized responses.\n'
              '✅ FIX: Cache, paginate, debounce, and compress.\n\n'
              'Requires internet connectivity.',
              style: TextStyle(fontSize: 13),
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              FilledButton.icon(
                onPressed: _running ? null : () => _triggerSlowRequest(),
                icon: const Icon(Icons.hourglass_bottom),
                label: const Text('Slow (3s)'),
              ),
              FilledButton.icon(
                onPressed: _running ? null : () => _triggerFrequencySpike(),
                icon: const Icon(Icons.bolt),
                label: const Text('40x Burst'),
              ),
              FilledButton.icon(
                onPressed: _running ? null : () => _triggerLargeResponse(),
                icon: const Icon(Icons.file_download),
                label: const Text('2MB'),
              ),
              FilledButton.tonalIcon(
                onPressed: _running ? null : _triggerAll,
                icon: const Icon(Icons.warning_amber),
                label: const Text('All 3'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: Container(
              margin: const EdgeInsets.all(16),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                borderRadius: BorderRadius.circular(8),
              ),
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
        ],
      ),
    );
  }
}
