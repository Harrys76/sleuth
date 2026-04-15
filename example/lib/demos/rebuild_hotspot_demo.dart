import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../demo_scaffold.dart';

// ─────────────────────────────────────────
// Demo: Rebuild Hotspot (Dashboard)
// Triggers: Rebuild Stats rollup (profile mode)
//           + per-type rebuild issues (debug mode)
// ─────────────────────────────────────────

/// Showcases v0.15.0 "Rebuild Stats" — a `Timer.periodic` drives a
/// top-level `ValueNotifier` at 10 Hz, and the bad path listens for the
/// change at the root of a fake metrics dashboard. Every tick rebuilds
/// five distinct widget types (header, metric cards, chart bars,
/// activity rows, tag chips) so the Sleuth drilldown has a varied
/// sorted list to surface.
///
/// **Run in profile mode** (`fvm flutter run --profile`) for the full
/// Rebuild Stats experience:
///
///   1. Open the Sleuth overlay (paw icon).
///   2. Tap "Start Ticker" and wait ~2 seconds.
///   3. A "Build Hotspot" rollup card appears once the session sustains
///      at least 20 builds/sec over a 1.5 s window (v0.15.1 rate-based
///      threshold — the ticker's 30 builds/tick × 10 ticks/s gets there
///      immediately).
///   4. Tap "See all rebuilds →" on the rollup card to open the
///      [RebuildStatsPage] drilldown, which lists every widget type
///      rebuilt during the session, sorted descending by count.
///
/// In debug mode the rollup card is suppressed (profile-path only) but
/// per-type `rebuild_debug_*` issue cards still fire for each of the
/// five types. Both modes validate that the widgets are real rebuilds,
/// not static inflations.
class RebuildHotspotDemo extends StatefulWidget {
  const RebuildHotspotDemo({super.key});

  @override
  State<RebuildHotspotDemo> createState() => _RebuildHotspotDemoState();
}

class _RebuildHotspotDemoState extends State<RebuildHotspotDemo> {
  // Drives the whole demo. Bumped on every tick by `_timer`. Nothing
  // else is allowed to mutate it — the point of the demo is that a
  // single broadcast source fans out to many widgets in the bad path
  // and stays scoped in the fixed path.
  final ValueNotifier<int> _tick = ValueNotifier<int>(0);

  Timer? _timer;
  bool _running = false;

  // Visible rebuild counters. Bumped from inside each path's build
  // method via a microtask so we don't mutate a listenable during its
  // own notify cycle.
  final ValueNotifier<int> _badRebuildCount = ValueNotifier<int>(0);
  final ValueNotifier<int> _fixedRebuildCount = ValueNotifier<int>(0);

  @override
  void dispose() {
    _timer?.cancel();
    _tick.dispose();
    _badRebuildCount.dispose();
    _fixedRebuildCount.dispose();
    super.dispose();
  }

  void _toggleTicker() {
    if (_running) {
      _timer?.cancel();
      _timer = null;
      setState(() => _running = false);
    } else {
      _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
        if (!mounted) return;
        _tick.value++;
      });
      setState(() => _running = true);
    }
  }

  void _handleToggle(bool _) {
    // Reset the visible counters so the user can compare the two paths
    // on equal footing. The `_tick` counter keeps climbing — the whole
    // point of the fixed path is that it still sees every tick but only
    // one widget rebuilds.
    _badRebuildCount.value = 0;
    _fixedRebuildCount.value = 0;
  }

  @override
  Widget build(BuildContext context) {
    return DemoScaffold(
      title: 'Rebuild Hotspot (Dashboard)',
      description:
          '❌ BAD: A ValueListenableBuilder wraps the ENTIRE fake dashboard. '
          'Every 100 ms tick rebuilds 5 distinct widget types: 1 header, '
          '4 metric cards, 8 chart bars, 12 activity rows, 5 tag chips '
          '(30 builds per tick).\n'
          '✅ FIX: The dashboard is const. Only a tiny "Last updated" chip '
          'subscribes to the tick notifier — 1 rebuild per tick.\n\n'
          '▶ Tap "Start Ticker". Open the Sleuth overlay (paw icon) and wait '
          '~2 s. In PROFILE mode a "Build Hotspot" rollup card surfaces once '
          'the session sustains at least 20 builds/sec — tap '
          '"See all rebuilds →" to open the Rebuild Stats drilldown. In DEBUG '
          'mode you get per-type issue cards instead (the rollup is '
          'profile-only).',
      metricsBar: MetricsBar(
        chips: [
          ValueListenableBuilder<int>(
            valueListenable: _tick,
            builder: (_, v, _) => MetricChip(label: 'Ticks', value: '$v'),
          ),
          ValueListenableBuilder<int>(
            valueListenable: _badRebuildCount,
            builder: (_, v, _) =>
                MetricChip(label: 'Bad rebuilds', value: '$v'),
          ),
          ValueListenableBuilder<int>(
            valueListenable: _fixedRebuildCount,
            builder: (_, v, _) =>
                MetricChip(label: 'Fixed rebuilds', value: '$v'),
          ),
        ],
      ),
      onToggle: _handleToggle,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _toggleTicker,
        icon: Icon(_running ? Icons.stop : Icons.play_arrow),
        label: Text(_running ? 'Stop Ticker' : 'Start Ticker'),
      ),
      body: _BadDashboard(tick: _tick, rebuildCount: _badRebuildCount),
      fixedBody: _FixedDashboard(tick: _tick, rebuildCount: _fixedRebuildCount),
    );
  }
}

// ───────────────────────────────────────────────
// ❌ Bad: a broad ValueListenableBuilder at the root rebuilds every
//    subtree on every tick.
// ───────────────────────────────────────────────

class _BadDashboard extends StatelessWidget {
  const _BadDashboard({required this.tick, required this.rebuildCount});

  final ValueListenable<int> tick;
  final ValueNotifier<int> rebuildCount;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: tick,
      builder: (_, t, _) {
        // Count each rebuild of the bad subtree. The real per-type
        // totals that the Sleuth overlay reports are driven by the
        // framework's BUILD timeline events — this counter is just
        // user-facing visual feedback.
        Future.microtask(() => rebuildCount.value += 1);
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _DashHeader(tick: t),
            const SizedBox(height: 12),
            _MetricGrid(tick: t),
            const SizedBox(height: 12),
            _MiniChart(tick: t),
            const SizedBox(height: 12),
            _ActivityLog(tick: t),
            const SizedBox(height: 12),
            _TagStrip(tick: t),
          ],
        );
      },
    );
  }
}

// ───────────────────────────────────────────────
// ✅ Fixed: the dashboard is const. Only a tiny `_LiveTickBadge`
//    subscribes to the tick notifier, so only it rebuilds per tick.
// ───────────────────────────────────────────────

class _FixedDashboard extends StatelessWidget {
  const _FixedDashboard({required this.tick, required this.rebuildCount});

  final ValueListenable<int> tick;
  final ValueNotifier<int> rebuildCount;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // ✅ Only the badge rebuilds — the dashboard below stays const.
        _LiveTickBadge(tick: tick, rebuildCount: rebuildCount),
        const SizedBox(height: 12),
        const _DashHeader(tick: 0),
        const SizedBox(height: 12),
        const _MetricGrid(tick: 0),
        const SizedBox(height: 12),
        const _MiniChart(tick: 0),
        const SizedBox(height: 12),
        const _ActivityLog(tick: 0),
        const SizedBox(height: 12),
        const _TagStrip(tick: 0),
      ],
    );
  }
}

class _LiveTickBadge extends StatelessWidget {
  const _LiveTickBadge({required this.tick, required this.rebuildCount});

  final ValueListenable<int> tick;
  final ValueNotifier<int> rebuildCount;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<int>(
      valueListenable: tick,
      builder: (_, t, _) {
        Future.microtask(() => rebuildCount.value += 1);
        return DecoratedBox(
          decoration: BoxDecoration(
            color: colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.circle, size: 8, color: colorScheme.primary),
                const SizedBox(width: 6),
                Text(
                  'Last updated: tick #$t',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: colorScheme.onPrimaryContainer,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ───────────────────────────────────────────────
// 5 distinct widget types — each one becomes a separate row in the
// RebuildStatsPage drilldown, sorted by count descending.
// ───────────────────────────────────────────────

class _DashHeader extends StatelessWidget {
  const _DashHeader({required this.tick});

  final int tick;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(Icons.dashboard_customize, color: colorScheme.primary),
        const SizedBox(width: 8),
        const Expanded(
          child: Text(
            'Metrics Dashboard',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
        ),
        Text(
          'updated #$tick',
          style: TextStyle(fontSize: 11, color: colorScheme.outline),
        ),
      ],
    );
  }
}

class _MetricGrid extends StatelessWidget {
  const _MetricGrid({required this.tick});

  final int tick;

  @override
  Widget build(BuildContext context) {
    // 4 metric cards — a 2×2 grid.
    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisCount: 2,
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 2.2,
      children: [
        _MetricCard(
          label: 'Requests',
          value: '${1200 + tick * 3}',
          icon: Icons.language,
          color: Colors.blue,
        ),
        _MetricCard(
          label: 'Users',
          value: '${48 + (tick ~/ 10)}',
          icon: Icons.group,
          color: Colors.green,
        ),
        _MetricCard(
          label: 'Errors',
          value: '${tick ~/ 5}',
          icon: Icons.error_outline,
          color: Colors.red,
        ),
        _MetricCard(
          label: 'Latency',
          value: '${80 + (tick % 30)}ms',
          icon: Icons.timer_outlined,
          color: Colors.orange,
        ),
      ],
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 18),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    color: colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            Text(
              value,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniChart extends StatelessWidget {
  const _MiniChart({required this.tick});

  final int tick;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // 8 chart bars — the drilldown will count `_ChartBar` × 8 per tick.
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Throughput (last 8)',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 48,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: List.generate(8, (i) {
                  // Deterministic "signal" derived from the tick so the
                  // bars shimmy visibly without any randomness.
                  final v = ((tick + i * 7) % 40) / 40.0;
                  return Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: _ChartBar(
                        fraction: 0.2 + v * 0.8,
                        color: colorScheme.primary,
                      ),
                    ),
                  );
                }),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChartBar extends StatelessWidget {
  const _ChartBar({required this.fraction, required this.color});

  final double fraction;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      heightFactor: fraction,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: color,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(2)),
        ),
      ),
    );
  }
}

class _ActivityLog extends StatelessWidget {
  const _ActivityLog({required this.tick});

  final int tick;

  @override
  Widget build(BuildContext context) {
    // 12 activity rows — the drilldown's heaviest rebuilder at 12/tick.
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Recent Activity',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            for (int i = 0; i < 12; i++) _ActivityRow(index: i, tick: tick),
          ],
        ),
      ),
    );
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({required this.index, required this.tick});

  final int index;
  final int tick;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            child: Text(
              '#$index',
              style: TextStyle(
                fontSize: 11,
                color: colorScheme.outline,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          Expanded(
            child: Text(
              'event ${(tick + index * 3) % 1000}',
              style: const TextStyle(fontSize: 12),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Icon(
            index.isEven ? Icons.check_circle : Icons.pending,
            size: 12,
            color: index.isEven ? Colors.green : colorScheme.outline,
          ),
        ],
      ),
    );
  }
}

class _TagStrip extends StatelessWidget {
  const _TagStrip({required this.tick});

  final int tick;

  @override
  Widget build(BuildContext context) {
    // 5 tag chips.
    const labels = ['api', 'db', 'cache', 'queue', 'ws'];
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (int i = 0; i < labels.length; i++)
          _TagChip(label: labels[i], highlighted: (tick + i) % 5 == 0),
      ],
    );
  }
}

class _TagChip extends StatelessWidget {
  const _TagChip({required this.label, required this.highlighted});

  final String label;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: highlighted
            ? colorScheme.primary.withValues(alpha: 0.15)
            : colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: highlighted ? colorScheme.primary : colorScheme.outlineVariant,
          width: highlighted ? 1.2 : 0.6,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: highlighted ? colorScheme.primary : colorScheme.onSurface,
          ),
        ),
      ),
    );
  }
}
