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

  /// When true, the demo is in "bounded pool" fixed mode: allocations are
  /// capped to [_fixedPoolCapMB] and GC churn is suppressed.
  bool _isFixedMode = false;
  static const int _fixedPoolCapMB = 20;

  int get _dartMB => _dartBatchKB.fold(0, (s, kb) => s + kb) ~/ 1024;

  int get _nativeMB => (_ffiBuffers.length * _ffiBufferBytes) ~/ (1024 * 1024);

  int get _totalAllocations => _dartObjects.length + _ffiBuffers.length;

  int get _totalMB => _dartMB + _nativeMB;

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
    if (_isFixedMode) _enforcePoolCap();
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
    if (_isFixedMode) _enforcePoolCap();
  }

  // ── GC Churn ──

  void _toggleChurn() {
    if (_churning) {
      _churnTimer?.cancel();
      _churnTimer = null;
      setState(() => _churning = false);
    } else {
      // In fixed mode, churn is suppressed (the "pool" simulates reuse).
      if (_isFixedMode) return;
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

  /// In fixed mode, auto-release the oldest allocations whenever total
  /// retained memory exceeds the 20 MB cap. This is the "bounded pool"
  /// fix: the pool keeps its size under control even under heavy use.
  void _enforcePoolCap() {
    var released = false;
    // Dart heap: drop oldest batches first.
    while (_totalMB > _fixedPoolCapMB && _dartObjects.isNotEmpty) {
      _dartObjects.removeAt(0);
      _dartBatchKB.removeAt(0);
      released = true;
    }
    // Native: free oldest FFI buffers.
    while (_totalMB > _fixedPoolCapMB && _ffiBuffers.isNotEmpty) {
      final buffer = _ffiBuffers.removeAt(0);
      calloc.free(buffer);
      released = true;
    }
    if (released) setState(() {});
  }

  /// Called from DemoScaffold.onToggle when the user flips the segmented
  /// control. Stops the churn timer and applies the pool cap on entry to
  /// fixed mode; leaves existing state alone on return to bad mode.
  void _handleToggle(bool isFixed) {
    setState(() => _isFixedMode = isFixed);
    if (isFixed) {
      // Stop the churn timer — bounded pools never generate garbage.
      if (_churning) {
        _churnTimer?.cancel();
        _churnTimer = null;
        _churning = false;
      }
      _enforcePoolCap();
    }
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
          '▶ Flip to Fixed Pattern — retained memory is capped at '
          '${_fixedPoolCapMB}MB and churn is replaced with a reusable pool.\n\n'
          'Requires VM service connection (profile mode). Heap/native trend '
          'signals have a 3s warmup before evaluation begins.',
      metricsBar: MetricsBar(
        chips: [
          MetricChip(label: 'Retained (Dart)', value: '$_dartMB', unit: ' MB'),
          MetricChip(label: 'Native', value: '$_nativeMB', unit: ' MB'),
          MetricChip(label: 'Allocations', value: '$_totalAllocations'),
          if (_isFixedMode)
            const MetricChip(
              label: 'Cap',
              value: '$_fixedPoolCapMB',
              unit: ' MB',
            ),
        ],
      ),
      onToggle: _handleToggle,
      body: _buildControls(isFixed: false),
      fixedBody: _buildControls(isFixed: true),
    );
  }

  Widget _buildControls({required bool isFixed}) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
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
          if (isFixed) ...[
            const SizedBox(height: 12),
            DecoratedBox(
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Icon(
                      Icons.lock_clock,
                      size: 20,
                      color: colorScheme.onPrimaryContainer,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Bounded pool active — cap: $_fixedPoolCapMB MB. '
                        'Allocations beyond the cap auto-release oldest batches '
                        'and FFI buffers. GC churn is suppressed.',
                        style: TextStyle(
                          fontSize: 12,
                          color: colorScheme.onPrimaryContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
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
                // In fixed mode, churn is disabled — a pool never generates
                // garbage. Grey out the button to signal the behavior change.
                onPressed: isFixed ? null : _toggleChurn,
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
