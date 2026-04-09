import 'dart:math';

import 'package:flutter/material.dart';

import '../demo_scaffold.dart';

// ───────────────────────────────────────────────
// Combined Demo 2: Analytics Dashboard
// ───────────────────────────────────────────────
// Triggers: CustomPainter, AnimatedBuilder, GlobalKey, FontLoading, ListView,
//           SetStateScope, LayoutBottleneck
// Correlation: Rule 1 (suppress AnimBuilder if no paint), Rule 3 (escalate GPU+Painter)
// Causal chains: non_lazy_list → layout_bottleneck, setstate_scope → layout_bottleneck

/// Analytics dashboard that stacks 5+ anti-patterns common in this screen
/// shape: always-repainting CustomPainter, AnimatedBuilder without `child`,
/// 25 GlobalKeys on list tiles, 4 custom font families, a non-lazy
/// 25-item list, IntrinsicHeight per row, and a top-level setState
/// refresh counter that rebuilds the whole screen. The fix replaces each.
class CombinedAnalyticsDashboardDemo extends StatefulWidget {
  const CombinedAnalyticsDashboardDemo({super.key});

  @override
  State<CombinedAnalyticsDashboardDemo> createState() =>
      _CombinedAnalyticsDashboardDemoState();
}

class _CombinedAnalyticsDashboardDemoState
    extends State<CombinedAnalyticsDashboardDemo>
    with SingleTickerProviderStateMixin {
  // 60 tiles — must exceed ListviewDetector's default `childThreshold`
  // of 50 so the bad path's SingleChildScrollView + Column actually
  // trips the non-lazy-list detector. 25 was below threshold and the
  // pattern was silently passing.
  static const _tileCount = 60;

  late final AnimationController _controller;

  /// Bad path refresh counter — wide setState rebuilds the entire screen.
  int _badRefreshCount = 0;

  /// Fixed path refresh counter — isolated into a ValueNotifier so only
  /// the version badge rebuilds.
  final ValueNotifier<int> _fixedRefreshCount = ValueNotifier<int>(0);

  /// Tracks which path DemoScaffold is currently showing so the FAB can
  /// route its refresh to the correct mechanism. Without this, a shared
  /// `setState + _fixedRefreshCount.value++` handler would call setState
  /// even while the fixed path is mounted — neutralising the fix and
  /// making the demo misleading.
  bool _isFixed = false;

  void _handleToggle(bool isFixed) => _isFixed = isFixed;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    _fixedRefreshCount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DemoScaffold(
      title: 'Analytics (Combined)',
      description:
          '❌ BAD: CustomPainter with shouldRepaint=true, AnimatedBuilder '
          'without child (rebuilds chart + labels per tick), $_tileCount '
          'GlobalKeys reallocated on every refresh, 4 custom font '
          'families, a non-lazy $_tileCount-item list in a '
          'SingleChildScrollView, IntrinsicHeight per row, and a refresh '
          'IconButton that calls top-level setState.\n'
          '✅ FIX: CustomPainter compares progress, AnimatedBuilder uses '
          'a static child, ValueKey replaces GlobalKey, a single default '
          'font, ListView.builder lazily renders tiles, a plain stretch '
          'Row replaces IntrinsicHeight, and the refresh counter lives '
          'in a ValueNotifier so only the badge rebuilds.\n\n'
          '▶ Tap the Refresh FAB. In the bad path every tile rebuilds '
          'and the GlobalKey identity set churns (recreation detector '
          'fires); in the fixed path only the version badge updates.',
      metricsBar: MetricsBar(
        chips: [
          ValueListenableBuilder<int>(
            valueListenable: _fixedRefreshCount,
            builder: (_, v, _) => MetricChip(label: 'Refreshes', value: '$v'),
          ),
          const MetricChip(label: 'Tiles', value: '$_tileCount'),
        ],
      ),
      onToggle: _handleToggle,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          // Both counters stay in sync so toggling doesn't lose state,
          // but setState only fires in the bad path — otherwise the
          // fixed path's isolated rebuild would be buried under a
          // whole-screen rebuild from the outer State.
          _badRefreshCount++;
          _fixedRefreshCount.value++;
          if (!_isFixed) {
            setState(() {});
          }
        },
        icon: const Icon(Icons.refresh),
        label: const Text('Refresh'),
      ),
      // ❌ Wrap _BadDashboard in an outer AnimatedBuilder so the entire
      //    dashboard rebuilds on every animation tick. This forces the
      //    in-build GlobalKey allocation to churn between detector
      //    scans, exercising GlobalKeyDetector's recreation path
      //    (threshold = 5) without requiring the user to tap Refresh
      //    first. Mirrors the pattern used by combined_ecommerce_demo.
      body: AnimatedBuilder(
        animation: _controller,
        builder: (_, _) => _BadDashboard(
          controller: _controller,
          refreshCount: _badRefreshCount,
        ),
      ),
      fixedBody: _FixedDashboard(
        controller: _controller,
        refreshCount: _fixedRefreshCount,
      ),
    );
  }
}

// ─── Bad path ────────────────────────────────────────────────

class _BadDashboard extends StatelessWidget {
  const _BadDashboard({required this.controller, required this.refreshCount});

  final AnimationController controller;
  final int refreshCount;

  @override
  Widget build(BuildContext context) {
    // ❌ GlobalKeys allocated fresh on every build of `_BadDashboard`.
    //    Combined with the FAB-driven setState above, this trips
    //    GlobalKeyDetector's `recreationThreshold` (default 5) — the
    //    detector compares key identity sets across scans and sees the
    //    entire batch churn whenever the user taps Refresh. Hoisting
    //    these onto the State (the prior pattern) was both more
    //    realistic *and* invisible to the detector, so the demo never
    //    actually flagged.
    final tileKeys = List<GlobalKey>.generate(
      _CombinedAnalyticsDashboardDemoState._tileCount,
      (_) => GlobalKey(),
    );
    return Column(
      children: [
        // ❌ AnimatedBuilder without child — rebuilds the chart + all labels
        //    on every animation tick.
        SizedBox(
          height: 200,
          child: AnimatedBuilder(
            animation: controller,
            builder: (context, _) {
              return CustomPaint(
                // ❌ shouldRepaint always true
                painter: _BadDashboardChartPainter(controller.value),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      // ❌ 4 custom font families on one screen
                      Text(
                        'Revenue',
                        style: TextStyle(
                          fontFamily: 'Lobster',
                          fontSize: 18,
                          color: Colors.white.withValues(alpha: 0.9),
                        ),
                      ),
                      Text(
                        '\$${(12450 * (1 + controller.value * 0.1)).toStringAsFixed(0)}',
                        style: TextStyle(
                          fontFamily: 'Pacifico',
                          fontSize: 24,
                          color: Colors.white.withValues(alpha: 0.9),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        // Stats row with more custom fonts
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  children: [
                    Text(
                      'Users',
                      style: TextStyle(
                        fontFamily: 'DancingScript',
                        fontSize: 14,
                        color: Colors.grey.shade600,
                      ),
                    ),
                    const Text(
                      '3,842',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  children: [
                    Text(
                      'Sessions',
                      style: TextStyle(
                        fontFamily: 'IndieFlower',
                        fontSize: 14,
                        color: Colors.grey.shade600,
                      ),
                    ),
                    const Text(
                      '12,091',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const Divider(),
        // ❌ Non-lazy list: all 60 tiles built eagerly. Above
        //    ListviewDetector's default childThreshold of 50.
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: List.generate(
                _CombinedAnalyticsDashboardDemoState._tileCount,
                (i) {
                  // ❌ IntrinsicHeight forces two-pass layout
                  return IntrinsicHeight(
                    child: Card(
                      // ❌ GlobalKey on every tile
                      key: tileKeys[i],
                      margin: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Container(
                            width: 4,
                            color: Colors.primaries[i % Colors.primaries.length]
                                .withValues(alpha: 0.3),
                          ),
                          Expanded(
                            child: ListTile(
                              leading: CircleAvatar(
                                backgroundColor: Colors
                                    .primaries[i % Colors.primaries.length]
                                    .withValues(alpha: 0.15),
                                child: Text('${i + 1}'),
                              ),
                              title: Text(
                                'Metric ${i + 1}'
                                '${refreshCount > 0 ? ' (v$refreshCount)' : ''}',
                              ),
                              subtitle: Text(
                                'Value: ${(Random(i).nextDouble() * 1000).toStringAsFixed(1)}',
                              ),
                              trailing: Icon(
                                i % 3 == 0
                                    ? Icons.trending_up
                                    : i % 3 == 1
                                    ? Icons.trending_down
                                    : Icons.trending_flat,
                                color: i % 3 == 0
                                    ? Colors.green
                                    : i % 3 == 1
                                    ? Colors.red
                                    : Colors.grey,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Fixed path ──────────────────────────────────────────────

class _FixedDashboard extends StatelessWidget {
  const _FixedDashboard({required this.controller, required this.refreshCount});

  final AnimationController controller;
  final ValueNotifier<int> refreshCount;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // ✅ AnimatedBuilder with a static child — the labels subtree is
        //    passed in and reused across ticks.
        SizedBox(
          height: 200,
          child: AnimatedBuilder(
            animation: controller,
            child: const _FixedChartLabels(),
            builder: (context, child) {
              return CustomPaint(
                // ✅ Painter compares progress in shouldRepaint.
                painter: _GoodDashboardChartPainter(controller.value),
                child: child,
              );
            },
          ),
        ),
        // ✅ Default font, same weight family — no custom font loads.
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  children: [
                    Text(
                      'Users',
                      style: TextStyle(fontSize: 14, color: Colors.grey),
                    ),
                    Text(
                      '3,842',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  children: [
                    Text(
                      'Sessions',
                      style: TextStyle(fontSize: 14, color: Colors.grey),
                    ),
                    Text(
                      '12,091',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const Divider(),
        // ✅ ListView.builder — lazy, recyclable, no GlobalKeys.
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: _CombinedAnalyticsDashboardDemoState._tileCount,
            itemBuilder: (_, i) =>
                _FixedTile(index: i, refreshCount: refreshCount),
          ),
        ),
      ],
    );
  }
}

/// Static chart labels — passed as `child:` to AnimatedBuilder so they
/// are built once and reused across every animation tick.
class _FixedChartLabels extends StatelessWidget {
  const _FixedChartLabels();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            'Revenue',
            style: TextStyle(
              fontSize: 18,
              color: Colors.white.withValues(alpha: 0.9),
            ),
          ),
          Text(
            '\$12,450',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: Colors.white.withValues(alpha: 0.9),
            ),
          ),
        ],
      ),
    );
  }
}

class _FixedTile extends StatelessWidget {
  const _FixedTile({required this.index, required this.refreshCount});

  final int index;
  final ValueNotifier<int> refreshCount;

  @override
  Widget build(BuildContext context) {
    return Card(
      key: ValueKey<int>(index),
      margin: const EdgeInsets.only(bottom: 8),
      // ✅ Plain stretch Row — no IntrinsicHeight.
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 4,
            child: ColoredBox(
              color: Colors.primaries[index % Colors.primaries.length]
                  .withValues(alpha: 0.3),
            ),
          ),
          Expanded(
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: Colors
                    .primaries[index % Colors.primaries.length]
                    .withValues(alpha: 0.15),
                child: Text('${index + 1}'),
              ),
              // ✅ Only the version badge rebuilds via ValueListenableBuilder —
              //    the rest of the tile is stable.
              title: ValueListenableBuilder<int>(
                valueListenable: refreshCount,
                builder: (_, v, _) =>
                    Text('Metric ${index + 1}${v > 0 ? ' (v$v)' : ''}'),
              ),
              subtitle: Text(
                'Value: ${(Random(index).nextDouble() * 1000).toStringAsFixed(1)}',
              ),
              trailing: Icon(
                index % 3 == 0
                    ? Icons.trending_up
                    : index % 3 == 1
                    ? Icons.trending_down
                    : Icons.trending_flat,
                color: index % 3 == 0
                    ? Colors.green
                    : index % 3 == 1
                    ? Colors.red
                    : Colors.grey,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Painters ────────────────────────────────────────────────

class _BadDashboardChartPainter extends CustomPainter {
  _BadDashboardChartPainter(this.progress);
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    _paintChart(canvas, size, progress);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true; // ❌ Always
}

class _GoodDashboardChartPainter extends CustomPainter {
  _GoodDashboardChartPainter(this.progress);
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    _paintChart(canvas, size, progress);
  }

  @override
  bool shouldRepaint(covariant _GoodDashboardChartPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

void _paintChart(Canvas canvas, Size size, double progress) {
  // Background gradient
  final bgPaint = Paint()
    ..shader = const LinearGradient(
      colors: [Color(0xFF0D9488), Color(0xFF0891B2)],
    ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
  canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), bgPaint);

  // Animated bar chart
  final barPaint = Paint()
    ..color = Colors.white.withValues(alpha: 0.3)
    ..style = PaintingStyle.fill;

  const barCount = 12;
  final barWidth = (size.width - 32) / barCount - 4;
  for (var i = 0; i < barCount; i++) {
    final barHeight =
        (sin((progress * 2 * pi) + i * 0.5) * 0.3 + 0.5) * size.height;
    final x = 16.0 + i * (barWidth + 4);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(x, size.height - barHeight, barWidth, barHeight),
        const Radius.circular(3),
      ),
      barPaint,
    );
  }
}
