import 'package:flutter/material.dart';
import 'package:sleuth/sleuth.dart';

import 'demos/animated_builder_demo.dart';
import 'demos/combined_analytics_dashboard_demo.dart';
import 'demos/combined_social_feed_demo.dart';
import 'demos/custom_painter_demo.dart';
import 'demos/font_loading_demo.dart';
import 'demos/fps_stress_test_demo.dart';
import 'demos/global_key_demo.dart';
import 'demos/heavy_compute_demo.dart';
import 'demos/high_level_setstate_demo.dart';
import 'demos/intrinsic_height_demo.dart';
import 'demos/keepalive_demo.dart';
import 'demos/nested_scroll_demo.dart';
import 'demos/network_stress_demo.dart';
import 'demos/non_lazy_list_demo.dart';
import 'demos/opacity_zero_demo.dart';
import 'demos/repaint_stress_demo.dart';
import 'demos/shallow_rebuild_risk_demo.dart';
import 'demos/uncached_image_demo.dart';

void main() => runApp(
  Sleuth.track(
    child: const SleuthDemoApp(),
    config: SleuthConfig(
      aiChat: AiChatAdapter.openAi(
        apiKey: 'ollama', // Ollama ignores this but the field is required
        baseUrl: 'http://localhost:11434',
        model: 'llama3.2',
      ),
    ),
  ),
);

class SleuthDemoApp extends StatelessWidget {
  const SleuthDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '🐕 Sleuth Demo',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF3B82F6),
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFF3B82F6),
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const DemoHome(),
    );
  }
}

// ───────────────────────────────────────────────
// Home — navigation to each bad-pattern demo
// ───────────────────────────────────────────────
class DemoHome extends StatelessWidget {
  const DemoHome({super.key});

  @override
  Widget build(BuildContext context) {
    final demos = <_DemoRoute>[
      _DemoRoute(
        icon: Icons.refresh,
        title: 'High-Level setState',
        subtitle: 'Rebuild • SetStateScope detectors',
        color: Colors.red,
        builder: (_) => const HighLevelSetStateDemo(),
      ),
      _DemoRoute(
        icon: Icons.list,
        title: 'Non-Lazy ListView',
        subtitle: 'ListView detector',
        color: Colors.orange,
        builder: (_) => const NonLazyListDemo(),
      ),
      _DemoRoute(
        icon: Icons.height,
        title: 'IntrinsicHeight Abuse',
        subtitle: 'LayoutBottleneck detector',
        color: Colors.amber,
        builder: (_) => const IntrinsicHeightDemo(),
      ),
      _DemoRoute(
        icon: Icons.brush,
        title: 'Always-Repaint CustomPainter',
        subtitle: 'CustomPainter detector',
        color: Colors.green,
        builder: (_) => const CustomPainterDemo(),
      ),
      _DemoRoute(
        icon: Icons.image,
        title: 'Uncached Images',
        subtitle: 'ImageMemory detector',
        color: Colors.teal,
        builder: (_) => const UncachedImageDemo(),
      ),
      _DemoRoute(
        icon: Icons.key,
        title: 'GlobalKey Overuse',
        subtitle: 'GlobalKey detector (>10 keys)',
        color: Colors.blue,
        builder: (_) => const GlobalKeyDemo(),
      ),
      _DemoRoute(
        icon: Icons.swap_vert,
        title: 'Nested Scroll',
        subtitle: 'NestedScroll detector',
        color: Colors.indigo,
        builder: (_) => const NestedScrollDemo(),
      ),
      _DemoRoute(
        icon: Icons.speed,
        title: 'Heavy Compute on Main Thread',
        subtitle: 'HeavyCompute • FrameTiming detectors',
        color: Colors.purple,
        builder: (_) => const HeavyComputeDemo(),
      ),
      _DemoRoute(
        icon: Icons.all_inclusive,
        title: 'KeepAlive Overuse',
        subtitle: 'KeepAlive detector (>5 alive)',
        color: Colors.pink,
        builder: (_) => const KeepAliveDemo(),
      ),
      _DemoRoute(
        icon: Icons.opacity,
        title: 'Opacity Zero',
        subtitle: 'Opacity detector (invisible widget)',
        color: Colors.brown,
        builder: (_) => const OpacityZeroDemo(),
      ),
      _DemoRoute(
        icon: Icons.animation,
        title: 'AnimatedBuilder No Child',
        subtitle: 'AnimatedBuilder detector',
        color: Colors.cyan,
        builder: (_) => const AnimatedBuilderDemo(),
      ),
      _DemoRoute(
        icon: Icons.account_tree,
        title: 'Shallow Rebuild Risk',
        subtitle: 'ShallowRebuildRisk detector',
        color: Colors.lime,
        builder: (_) => const ShallowRebuildRiskDemo(),
      ),
      _DemoRoute(
        icon: Icons.font_download,
        title: 'Font Loading Stress',
        subtitle: 'FontLoading detector (>3 custom fonts)',
        color: Colors.deepOrange,
        builder: (_) => const FontLoadingDemo(),
      ),
      _DemoRoute(
        icon: Icons.format_paint,
        title: 'Repaint Stress',
        subtitle: 'Repaint detector (VM+/debug)',
        color: Colors.blueGrey,
        builder: (_) => const RepaintStressDemo(),
      ),
      _DemoRoute(
        icon: Icons.cloud_download,
        title: 'Network Stress',
        subtitle: 'Network Monitor detector',
        color: Colors.orange,
        builder: (_) => const NetworkStressDemo(),
      ),
      _DemoRoute(
        icon: Icons.local_fire_department,
        title: 'FPS Stress Test (~20 FPS)',
        subtitle: 'Heavy compute + GPU blur every frame',
        color: Colors.red,
        builder: (_) => const FpsStressTestDemo(),
      ),
      // ── Combined multi-detector demos ──
      _DemoRoute(
        icon: Icons.dynamic_feed,
        title: 'Combined: Social Feed',
        subtitle: 'Image • Opacity • Layout • setState • Correlator escalation',
        color: Colors.deepPurple,
        builder: (_) => const CombinedSocialFeedDemo(),
      ),
      _DemoRoute(
        icon: Icons.dashboard,
        title: 'Combined: Analytics Dashboard',
        subtitle: 'Painter • AnimBuilder • GlobalKey • Font • Non-lazy list',
        color: Colors.teal,
        builder: (_) => const CombinedAnalyticsDashboardDemo(),
      ),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('🐕 Sleuth Demo'), centerTitle: true),
      body: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: demos.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final demo = demos[index];
          return Card(
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: demo.color.withValues(alpha: 0.15),
                child: Icon(demo.icon, color: demo.color),
              ),
              title: Text(
                demo.title,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                demo.subtitle,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.outline,
                ),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: demo.builder),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _DemoRoute {
  const _DemoRoute({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.builder,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final WidgetBuilder builder;
}
