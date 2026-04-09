import 'dart:async';
import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';

import '../demo_scaffold.dart';

// ─────────────────────────────────────────
// Demo 21: Memory Pressure
// Triggers: MemoryPressure detector (VM-only, heap growth + GC pressure)
// ─────────────────────────────────────────

/// Demonstrates three independent memory pressure signals:
///
/// * **Dart heap growth** — allocate Dart objects that remain reachable.
///   Shows up as `heap_growing` once the linear-regression slope exceeds
///   512 KB/s for 10 sustained seconds.
/// * **Native memory growth** — allocate via `dart:ffi`'s `calloc`. These
///   bytes live outside the Dart heap, so the VM's `heapUsage` stays flat
///   while process RSS grows, triggering `native_memory_growing`
///   (`nativeBytes = rss - heapUsage`).
/// * **GC pressure** — continuously churn short-lived allocations via a
///   periodic timer to force the scavenger to run repeatedly, triggering
///   `gc_pressure` (>30 GC/min).
class MemoryPressureDemo extends StatefulWidget {
  const MemoryPressureDemo({super.key});

  @override
  State<MemoryPressureDemo> createState() => _MemoryPressureDemoState();
}

class _MemoryPressureDemoState extends State<MemoryPressureDemo> {
  /// Dart heap allocations — retained Maps/Lists on the Dart heap.
  /// Targets `_evaluateHeapTrend()` (heapUsage slope).
  final List<List<Map<String, Object>>> _dartObjects = [];

  /// Estimated KB per Dart-heap batch (so GC Churn's tiny retained batch
  /// doesn't get counted as a full 10MB allocation).
  final List<int> _dartBatchKB = [];

  /// FFI-allocated native buffers — NOT tracked by the Dart VM heap.
  /// They grow process RSS without growing heapUsage, which is exactly
  /// what `_evaluateNativeGrowth()` detects.
  final List<ffi.Pointer<ffi.Uint8>> _ffiBuffers = [];
  static const int _ffiBufferBytes = 10 * 1024 * 1024; // 10 MB per allocation

  /// Continuous GC churn timer. Generates short-lived garbage on every tick
  /// to force the scavenger to run repeatedly.
  Timer? _churnTimer;
  bool _churning = false;

  /// Side-effect sink so the optimizer can't eliminate churn allocations.
  // ignore: unused_field
  int _churnBytesSeen = 0;

  int get _dartMB => _dartBatchKB.fold(0, (s, kb) => s + kb) ~/ 1024;

  int get _nativeMB => (_ffiBuffers.length * _ffiBufferBytes) ~/ (1024 * 1024);

  int get _totalAllocations => _dartObjects.length + _ffiBuffers.length;

  // ── Dart Heap ──

  void _allocateDartHeap() {
    // Create ~10MB of Dart heap objects: 10,000 Maps each holding a small list.
    // These live on the Dart heap (not external), triggering heap_growing.
    final batch = List.generate(
      10000,
      (i) => <String, Object>{
        'id': i,
        'data': List.filled(100, i),
        'label': 'entry_$i padding string to increase size',
      },
    );
    setState(() {
      _dartObjects.add(batch);
      _dartBatchKB.add(10 * 1024); // ~10MB
    });
  }

  // ── Native Memory (FFI) ──

  void _allocateNative() {
    // calloc<Uint8>(N) allocates N bytes via malloc, OUTSIDE the Dart heap.
    // The VM's heapUsage stays flat — only process RSS grows — so the
    // detector's `nativeBytes = rss - heapUsage` trend rises sharply.
    final buffer = calloc<ffi.Uint8>(_ffiBufferBytes);
    // Touch one byte per 4KB page to force physical commit. Without this,
    // lazy allocators may defer RSS growth until the memory is written.
    for (var i = 0; i < _ffiBufferBytes; i += 4096) {
      buffer[i] = 1;
    }
    setState(() => _ffiBuffers.add(buffer));
  }

  // ── GC Churn ──

  void _toggleChurn() {
    if (_churning) {
      _churnTimer?.cancel();
      _churnTimer = null;
      setState(() => _churning = false);
    } else {
      setState(() => _churning = true);
      // Every 50ms, allocate ~1MB of garbage that immediately becomes
      // unreachable. Over a few seconds this overflows new-space repeatedly,
      // producing many scavenger GCs — enough to exceed 30 GC/min.
      _churnTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
        final garbage = List.generate(
          2000,
          (i) => <String, Object>{'i': i, 'data': List.filled(50, i)},
        );
        // Write to a field so the optimizer keeps the allocation.
        _churnBytesSeen += garbage.length;
      });
    }
  }

  // ── Release ──

  void _releaseAll() {
    for (final buffer in _ffiBuffers) {
      calloc.free(buffer);
    }
    setState(() {
      _dartObjects.clear();
      _dartBatchKB.clear();
      _ffiBuffers.clear();
    });
  }

  @override
  void dispose() {
    _churnTimer?.cancel();
    // Free any remaining FFI allocations to avoid native memory leaks.
    for (final buffer in _ffiBuffers) {
      calloc.free(buffer);
    }
    _ffiBuffers.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return DemoScaffold(
      title: 'Memory Pressure',
      description:
          '❌ BAD: Allocating large objects without disposal causes heap '
          'growth, native memory growth, and GC pressure.\n'
          '✅ FIX: Dispose resources, use object pools, free FFI allocations, '
          'limit concurrent loads.\n\n'
          '▶ Tap "Dart Heap +10MB" 3–4 times over 10 seconds to trigger '
          '`heap_growing`.\n'
          '▶ Tap "Native +10MB" 3–4 times over 10 seconds to trigger '
          '`native_memory_growing` (FFI-allocated, outside the Dart heap).\n'
          '▶ Toggle "GC Churn" on for ~5 seconds to trigger `gc_pressure` '
          '(>30 GC/min). The "Retained (Dart)" counter stays at 0 during '
          'churn because the allocations are intentionally transient.\n\n'
          'Requires VM service connection (profile mode). Heap/native trend '
          'signals have a 3s warmup before evaluation begins.',
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // ── Stats ──
            DecoratedBox(
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _StatColumn(label: 'Retained (Dart)', value: '$_dartMB MB'),
                    _StatColumn(label: 'Native', value: '$_nativeMB MB'),
                    _StatColumn(
                      label: 'Allocations',
                      value: '$_totalAllocations',
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),

            // ── Allocation Buttons ──
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: _allocateDartHeap,
                  icon: const Icon(Icons.add_circle),
                  label: const Text('Dart Heap +10MB'),
                ),
                FilledButton.icon(
                  onPressed: _allocateNative,
                  icon: const Icon(Icons.add_circle_outline),
                  label: const Text('Native +10MB'),
                ),
                FilledButton.icon(
                  onPressed: _toggleChurn,
                  icon: Icon(_churning ? Icons.stop : Icons.grain),
                  label: Text(_churning ? 'Stop Churn' : 'GC Churn'),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // ── Release ──
            OutlinedButton.icon(
              onPressed: _releaseAll,
              icon: const Icon(Icons.delete_sweep),
              label: const Text('Release All'),
            ),
            const SizedBox(height: 24),

            // ── Visual representation ──
            Expanded(
              child: _MemoryVisualization(dartMB: _dartMB, nativeMB: _nativeMB),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatColumn extends StatelessWidget {
  const _StatColumn({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.outline,
          ),
        ),
      ],
    );
  }
}

class _MemoryVisualization extends StatelessWidget {
  const _MemoryVisualization({required this.dartMB, required this.nativeMB});

  final int dartMB;
  final int nativeMB;

  @override
  Widget build(BuildContext context) {
    final totalMB = dartMB + nativeMB;
    if (totalMB == 0) {
      return Center(
        child: Text(
          'No memory allocated yet.\nTap a button above to start.',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 14,
            color: Theme.of(context).colorScheme.outline,
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Total retained: $totalMB MB',
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            height: 32,
            child: Row(
              children: [
                if (dartMB > 0)
                  Expanded(
                    flex: dartMB,
                    child: DecoratedBox(
                      decoration: BoxDecoration(color: Colors.blue.shade400),
                      child: Center(
                        child: Text(
                          'Dart $dartMB MB',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                if (nativeMB > 0)
                  Expanded(
                    flex: nativeMB,
                    child: DecoratedBox(
                      decoration: BoxDecoration(color: Colors.orange.shade400),
                      child: Center(
                        child: Text(
                          'Native $nativeMB MB',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            _LegendDot(color: Colors.blue.shade400, label: 'Dart heap'),
            const SizedBox(width: 16),
            _LegendDot(color: Colors.orange.shade400, label: 'Native (FFI)'),
          ],
        ),
      ],
    );
  }
}

class _LegendDot extends StatelessWidget {
  const _LegendDot({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          child: const SizedBox(width: 10, height: 10),
        ),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }
}
