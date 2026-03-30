import 'dart:math';

import 'package:flutter/material.dart';

// ───────────────────────────────────────────────
// Combined Demo 2: Analytics Dashboard
// ───────────────────────────────────────────────
// Triggers: CustomPainter, AnimatedBuilder, GlobalKey, FontLoading, ListView,
//           SetStateScope, LayoutBottleneck
// Correlation: Rule 1 (suppress AnimBuilder if no paint), Rule 3 (escalate GPU+Painter)
// Causal chains: non_lazy_list → layout_bottleneck, setstate_scope → layout_bottleneck

class CombinedAnalyticsDashboardDemo extends StatefulWidget {
  const CombinedAnalyticsDashboardDemo({super.key});

  @override
  State<CombinedAnalyticsDashboardDemo> createState() =>
      _CombinedAnalyticsDashboardDemoState();
}

class _CombinedAnalyticsDashboardDemoState
    extends State<CombinedAnalyticsDashboardDemo>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  // ❌ GlobalKeys on dashboard tiles — unnecessary
  final _tileKeys = List.generate(25, (_) => GlobalKey());

  // ❌ Counter forces wide setState — rebuilds entire screen
  int _refreshCount = 0;

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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Analytics (Combined)'),
        actions: [
          // ❌ Wide setState — triggers setstate_scope detector
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(() => _refreshCount++),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            color: Colors.teal.withValues(alpha: 0.05),
            child: const Text(
              'This screen combines 5 anti-patterns common in analytics '
              'dashboards. The Watchdog correlator may suppress or '
              'escalate issues based on cross-detector evidence.',
              style: TextStyle(fontSize: 12),
            ),
          ),

          // ❌ AnimatedBuilder without child — rebuilds the chart + all
          //    labels on every animation tick
          SizedBox(
            height: 200,
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, _) {
                return CustomPaint(
                  // ❌ shouldRepaint always true
                  painter: _DashboardChartPainter(_controller.value),
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
                          '\$${(12450 * (1 + _controller.value * 0.1)).toStringAsFixed(0)}',
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

          // ❌ Non-lazy list: all 25 tiles built eagerly (>20 threshold)
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: List.generate(25, (i) {
                  // ❌ IntrinsicHeight forces two-pass layout
                  return IntrinsicHeight(
                    child: Card(
                      // ❌ GlobalKey on every tile
                      key: _tileKeys[i],
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
                                '${_refreshCount > 0 ? ' (v$_refreshCount)' : ''}',
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
                }),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DashboardChartPainter extends CustomPainter {
  _DashboardChartPainter(this.progress);
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
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

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true; // ❌ Always
}
