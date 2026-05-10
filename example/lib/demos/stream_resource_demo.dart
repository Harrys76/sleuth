// Educational demo for `stream_resource_growth.warning`.
//
// Tap "Start leak" to drive a sustained leak that satisfies all three
// detector preconditions:
//   1. Heap slope > 512 KB/sec via Uint8List allocations →
//      `MemoryPressureDetector.heap_growing` latches.
//   2. ≥2 watchlist classes (`StreamController` + `_BroadcastSubscription`
//      + `_ControllerSubscription`) accumulate at ~5/sec each.
//   3. Top-class delta crosses minDelta=50 within the K=4 window
//      (default 4 polls × 10 s = 40 s).
//
// First emission lands ~30–60 s after Start. Open the Sleuth overlay
// to see the warning. Tap Stop to release everything.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

class StreamResourceDemo extends StatefulWidget {
  const StreamResourceDemo({super.key});

  @override
  State<StreamResourceDemo> createState() => _StreamResourceDemoState();
}

class _StreamResourceDemoState extends State<StreamResourceDemo> {
  final List<StreamSubscription<void>> _broadcastSubs = [];
  final List<StreamSubscription<void>> _periodicSubs = [];
  final List<StreamController<void>> _retainedControllers = [];
  final List<Uint8List> _retainedBytes = [];

  Timer? _allocTimer;
  Timer? _bytePressureTimer;
  Timer? _uiTimer;
  DateTime? _startedAt;

  @override
  void dispose() {
    _stopAll();
    super.dispose();
  }

  void _start() {
    if (_allocTimer != null) return;
    setState(() {
      _startedAt = DateTime.now();
    });

    // 1024 KB/sec byte pressure → heap_growing latches after ~13 s
    // (3 s warmup + 10 s sustained slope).
    _bytePressureTimer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => _retainedBytes.add(Uint8List(256 * 1024)),
    );

    // Allocate 5 instances of each watchlist class per second so the
    // K=4 window sees ≥3 ascending transitions across multiple
    // classes. After ~15 s the top-class delta crosses minDelta=50.
    _allocTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      for (var i = 0; i < 5; i++) {
        final controller = StreamController<void>.broadcast();
        _retainedControllers.add(controller);
        _broadcastSubs.add(controller.stream.listen((_) {}));
        final stream = Stream<void>.periodic(
          const Duration(seconds: 60),
          (_) {},
        );
        _periodicSubs.add(stream.listen((_) {}));
      }
      if (mounted) setState(() {});
    });

    _uiTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  void _stopAll() {
    _allocTimer?.cancel();
    _allocTimer = null;
    _bytePressureTimer?.cancel();
    _bytePressureTimer = null;
    _uiTimer?.cancel();
    _uiTimer = null;
    for (final s in _broadcastSubs) {
      s.cancel();
    }
    for (final s in _periodicSubs) {
      s.cancel();
    }
    for (final c in _retainedControllers) {
      // ignore: discarded_futures
      c.close();
    }
    _broadcastSubs.clear();
    _periodicSubs.clear();
    _retainedControllers.clear();
    _retainedBytes.clear();
    if (mounted) {
      setState(() {
        _startedAt = null;
      });
    }
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
      appBar: AppBar(title: const Text('Stream Resource Leaks')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Drives a sustained leak across StreamController + '
              'StreamSubscription watchlist classes alongside heap '
              'pressure. The detector emits '
              '`stream_resource_growth.warning` once heap_growing '
              'latches AND ≥2 watchlist classes cross minDelta — '
              'typically 30–60 s after Start.',
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
                '“Stream Resources Growing: StreamController '
                '+N instances (3 classes, M total)” — warning, '
                'category: memory, confidence: likely.',
                style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: running ? _stopAll : _start,
              child: Text(running ? 'Stop & release all' : 'Start leak'),
            ),
            const SizedBox(height: 24),
            _Stat(label: 'Elapsed', value: '${elapsed}s'),
            _Stat(
              label: 'StreamController instances',
              value: '${_retainedControllers.length}',
            ),
            _Stat(
              label: '_BroadcastSubscription instances',
              value: '${_broadcastSubs.length}',
            ),
            _Stat(
              label: '_ControllerSubscription instances',
              value: '${_periodicSubs.length}',
            ),
            _Stat(
              label: 'Retained Uint8List bytes',
              value: '${_retainedBytes.length * 256} KB',
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
