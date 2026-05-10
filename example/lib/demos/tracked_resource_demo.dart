// Educational demo AND integration coverage for `Sleuth.trackResource`
// production Finalizer wiring. The hermetic reproducer
// (test/validation/tracked_resource_reproducer_test.dart) uses an
// internal seam; this demo exercises the real WeakReference +
// Finalizer path under a real iOS profile-mode workload. Do not
// weaken the leak workload without adding a separate integration
// test.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sleuth/sleuth.dart';

class TrackedResourceDemo extends StatefulWidget {
  const TrackedResourceDemo({super.key});

  @override
  State<TrackedResourceDemo> createState() => _TrackedResourceDemoState();
}

class _ChatService {
  _ChatService(this.id);
  final int id;
}

class _DataRepository {
  _DataRepository(this.id);
  final int id;
}

class _TrackedResourceDemoState extends State<TrackedResourceDemo> {
  final List<_ChatService> _chatServices = [];
  final List<_DataRepository> _dataRepositories = [];
  Timer? _allocTimer;
  Timer? _uiTimer;
  DateTime? _startedAt;

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  void _start() {
    if (_allocTimer != null) return;
    setState(() => _startedAt = DateTime.now());
    _allocTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      // Each tick allocates 1 of each watched class and registers it
      // by name. Resources are retained in lists so the GC can't
      // reclaim them — Finalizers stay un-fired and the bucket count
      // grows. Crosses concurrent threshold (>5) by ~T=6 s; emission
      // appears in the Sleuth overlay shortly after.
      final chat = _ChatService(_chatServices.length);
      _chatServices.add(chat);
      Sleuth.trackResource('chat_service', chat);

      final repo = _DataRepository(_dataRepositories.length);
      _dataRepositories.add(repo);
      Sleuth.trackResource('data_repository', repo);
    });
    _uiTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  void _stop() {
    _allocTimer?.cancel();
    _allocTimer = null;
    _uiTimer?.cancel();
    _uiTimer = null;
    for (final s in _chatServices) {
      Sleuth.untrackResource('chat_service', s);
    }
    for (final r in _dataRepositories) {
      Sleuth.untrackResource('data_repository', r);
    }
    _chatServices.clear();
    _dataRepositories.clear();
    if (mounted) setState(() => _startedAt = null);
  }

  int get _elapsedSec {
    if (_startedAt == null) return 0;
    return DateTime.now().difference(_startedAt!).inSeconds;
  }

  @override
  Widget build(BuildContext context) {
    final running = _allocTimer != null;
    final elapsed = _elapsedSec;
    return Scaffold(
      appBar: AppBar(title: const Text('Tracked Resource Leaks')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Allocates 1 chat_service + 1 data_repository per second '
              'and registers each via Sleuth.trackResource. The detector '
              'fires tracked_resource_concurrent.warning once each '
              'bucket crosses the configured concurrent threshold '
              '(default 5) — typically ~6 s after Start. Long-lived '
              'fires after 5 minutes wall-clock per default.',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 16),
            const Text(
              'Issue you should see in the Sleuth overlay:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: Text(
                '“Tracked Resource Concurrent: chat_service '
                '(N live instances)” — warning, category: memory, '
                'confidence: confirmed.',
                style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: running ? _stop : _start,
              child: Text(running ? 'Stop & untrack all' : 'Start leak'),
            ),
            const SizedBox(height: 24),
            _Stat(label: 'Elapsed', value: '${elapsed}s'),
            _Stat(
              label: 'chat_service instances',
              value: '${_chatServices.length}',
            ),
            _Stat(
              label: 'data_repository instances',
              value: '${_dataRepositories.length}',
            ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}
