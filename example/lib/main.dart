import 'package:flutter/material.dart';
import 'package:sleuth/sleuth.dart';

import 'custom_detectors/01_simple_structural_detector.dart';
import 'custom_detectors/02_runtime_callback_detector.dart';
import 'custom_detectors/03_hybrid_vm_structural_detector.dart';
import 'demos/animated_builder_demo.dart';
import 'demos/combined_analytics_dashboard_demo.dart';
import 'demos/combined_chat_demo.dart';
import 'demos/combined_ecommerce_demo.dart';
import 'demos/combined_social_feed_demo.dart';
import 'demos/custom_detector_cookbook_demo.dart';
import 'demos/custom_painter_demo.dart';
import 'demos/font_loading_demo.dart';
import 'demos/fps_stress_test_demo.dart';
import 'demos/global_key_demo.dart';
import 'demos/gpu_pressure_demo.dart';
import 'demos/heavy_compute_demo.dart';
import 'demos/high_level_setstate_demo.dart';
import 'demos/intrinsic_height_demo.dart';
import 'demos/keepalive_demo.dart';
import 'demos/memory_pressure_demo.dart';
import 'demos/nested_scroll_demo.dart';
import 'demos/network_stress_demo.dart';
import 'demos/non_lazy_list_demo.dart';
import 'demos/opacity_zero_demo.dart';
import 'demos/platform_channel_demo.dart';
import 'demos/repaint_boundary_demo.dart';
import 'demos/repaint_stress_demo.dart';
import 'demos/shader_jank_demo.dart';
import 'demos/shallow_rebuild_risk_demo.dart';
import 'demos/uncached_image_demo.dart';

void main() {
  Sleuth.init();
  runApp(
    Sleuth.track(
      child: const SleuthDemoApp(),
      config: SleuthConfig(
        aiChat: AiChatAdapter.openAi(
          apiKey: 'ollama', // Ollama ignores this but the field is required
          baseUrl: 'http://localhost:11434',
          model: 'llama3.2',
        ),
        // Cookbook custom detectors — see example/lib/custom_detectors/.
        // All three are attached to the overlay so the Custom Detector
        // Cookbook demo can exercise them end-to-end.
        customDetectors: [
          TooltipUsageDetector(),
          SlowFrameDetector(),
          RasterHotSpotDetector(),
        ],
      ),
    ),
  );
}

class SleuthDemoApp extends StatelessWidget {
  const SleuthDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sleuth Demo',
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
// Home — categorized navigation to bad-pattern demos
// ───────────────────────────────────────────────
class DemoHome extends StatelessWidget {
  const DemoHome({super.key});

  @override
  Widget build(BuildContext context) {
    final categories = <_DemoCategory>[
      // ── Build ──
      _DemoCategory(
        title: 'Build',
        icon: Icons.construction,
        demos: [
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
            icon: Icons.speed,
            title: 'Heavy Compute on Main Thread',
            subtitle: 'HeavyCompute • FrameTiming detectors',
            color: Colors.purple,
            builder: (_) => const HeavyComputeDemo(),
          ),
        ],
      ),

      // ── Paint ──
      _DemoCategory(
        title: 'Paint',
        icon: Icons.format_paint,
        demos: [
          _DemoRoute(
            icon: Icons.format_paint,
            title: 'Repaint Stress',
            subtitle: 'Repaint detector (VM+/debug)',
            color: Colors.blueGrey,
            builder: (_) => const RepaintStressDemo(),
          ),
          _DemoRoute(
            icon: Icons.brush,
            title: 'Always-Repaint CustomPainter',
            subtitle: 'CustomPainter detector',
            color: Colors.green,
            builder: (_) => const CustomPainterDemo(),
          ),
          _DemoRoute(
            icon: Icons.border_outer,
            title: 'Missing RepaintBoundary',
            subtitle: 'RepaintBoundary detector (structural)',
            color: Colors.deepPurple,
            builder: (_) => const RepaintBoundaryDemo(),
          ),
        ],
      ),

      // ── GPU & Rendering ──
      _DemoCategory(
        title: 'GPU & Rendering',
        icon: Icons.layers,
        demos: [
          _DemoRoute(
            icon: Icons.opacity,
            title: 'Opacity Zero',
            subtitle: 'Opacity detector (invisible widget)',
            color: Colors.brown,
            builder: (_) => const OpacityZeroDemo(),
          ),
          _DemoRoute(
            icon: Icons.memory_outlined,
            title: 'GPU Pressure',
            subtitle: 'GpuPressure detector (hybrid)',
            color: Colors.deepOrange,
            builder: (_) => const GpuPressureDemo(),
          ),
          _DemoRoute(
            icon: Icons.blur_on,
            title: 'Shader Jank',
            subtitle: 'ShaderJank detector (Skia only)',
            color: Colors.indigo,
            builder: (_) => const ShaderJankDemo(),
          ),
          _DemoRoute(
            icon: Icons.local_fire_department,
            title: 'FPS Stress Test (~20 FPS)',
            subtitle: 'Heavy compute + GPU blur every frame',
            color: Colors.red,
            builder: (_) => const FpsStressTestDemo(),
          ),
        ],
      ),

      // ── Layout ──
      _DemoCategory(
        title: 'Layout',
        icon: Icons.grid_on,
        demos: [
          _DemoRoute(
            icon: Icons.height,
            title: 'IntrinsicHeight Abuse',
            subtitle: 'LayoutBottleneck detector',
            color: Colors.amber,
            builder: (_) => const IntrinsicHeightDemo(),
          ),
          _DemoRoute(
            icon: Icons.swap_vert,
            title: 'Nested Scroll',
            subtitle: 'NestedScroll detector',
            color: Colors.indigo,
            builder: (_) => const NestedScrollDemo(),
          ),
        ],
      ),

      // ── Memory ──
      _DemoCategory(
        title: 'Memory',
        icon: Icons.memory,
        demos: [
          _DemoRoute(
            icon: Icons.image,
            title: 'Uncached Images',
            subtitle: 'ImageMemory detector',
            color: Colors.teal,
            builder: (_) => const UncachedImageDemo(),
          ),
          _DemoRoute(
            icon: Icons.data_array,
            title: 'Memory Pressure',
            subtitle: 'MemoryPressure detector (VM-only)',
            color: Colors.purple,
            builder: (_) => const MemoryPressureDemo(),
          ),
          _DemoRoute(
            icon: Icons.all_inclusive,
            title: 'KeepAlive Overuse',
            subtitle: 'KeepAlive detector (>5 alive)',
            color: Colors.pink,
            builder: (_) => const KeepAliveDemo(),
          ),
        ],
      ),

      // ── Network & I/O ──
      _DemoCategory(
        title: 'Network & I/O',
        icon: Icons.cloud,
        demos: [
          _DemoRoute(
            icon: Icons.cloud_download,
            title: 'Network Stress',
            subtitle: 'Network Monitor detector',
            color: Colors.orange,
            builder: (_) => const NetworkStressDemo(),
          ),
          _DemoRoute(
            icon: Icons.settings_input_hdmi,
            title: 'Platform Channel Traffic',
            subtitle: 'PlatformChannel detector (>20/sec)',
            color: Colors.blueGrey,
            builder: (_) => const PlatformChannelDemo(),
          ),
          _DemoRoute(
            icon: Icons.font_download,
            title: 'Font Loading Stress',
            subtitle: 'FontLoading detector (>3 custom fonts)',
            color: Colors.deepOrange,
            builder: (_) => const FontLoadingDemo(),
          ),
        ],
      ),

      // ── Keys & Identity ──
      _DemoCategory(
        title: 'Keys & Identity',
        icon: Icons.key,
        demos: [
          _DemoRoute(
            icon: Icons.key,
            title: 'GlobalKey Overuse',
            subtitle: 'GlobalKey detector (>10 keys)',
            color: Colors.blue,
            builder: (_) => const GlobalKeyDemo(),
          ),
        ],
      ),

      // ── Custom Detectors ──
      _DemoCategory(
        title: 'Custom Detectors',
        icon: Icons.extension,
        demos: [
          _DemoRoute(
            icon: Icons.extension_outlined,
            title: 'Custom Detector Cookbook',
            subtitle: 'Tooltip • Slow frame • Raster hot spot (cookbook)',
            color: Colors.deepPurple,
            builder: (_) => const CustomDetectorCookbookDemo(),
          ),
        ],
      ),

      // ── Combined ──
      _DemoCategory(
        title: 'Combined',
        icon: Icons.dashboard,
        demos: [
          _DemoRoute(
            icon: Icons.dynamic_feed,
            title: 'Combined: Social Feed',
            subtitle: 'Image • Opacity • Layout • setState • Correlator',
            color: Colors.deepPurple,
            builder: (_) => const CombinedSocialFeedDemo(),
          ),
          _DemoRoute(
            icon: Icons.dashboard,
            title: 'Combined: Analytics Dashboard',
            subtitle: 'Painter • AnimBuilder • GlobalKey • Font • Non-lazy',
            color: Colors.teal,
            builder: (_) => const CombinedAnalyticsDashboardDemo(),
          ),
          _DemoRoute(
            icon: Icons.shopping_cart,
            title: 'Combined: E-Commerce Page',
            subtitle: 'Image • Layout • AnimBuilder • ListView • GlobalKey',
            color: Colors.deepOrange,
            builder: (_) => const CombinedEcommerceDemo(),
          ),
          _DemoRoute(
            icon: Icons.chat,
            title: 'Combined: Chat App',
            subtitle:
                'Rebuild • KeepAlive • PlatformChannel • Image • SetState',
            color: Colors.blue,
            builder: (_) => const CombinedChatDemo(),
          ),
        ],
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.pets, size: 20),
            SizedBox(width: 8),
            Text('Sleuth Demo'),
          ],
        ),
        centerTitle: true,
      ),
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: categories.fold<int>(
          0,
          (sum, c) => sum + 1 + c.demos.length,
        ),
        itemBuilder: (context, index) {
          // Map flat index to category header or demo tile.
          var remaining = index;
          for (final category in categories) {
            if (remaining == 0) {
              return _CategoryHeader(
                title: category.title,
                icon: category.icon,
              );
            }
            remaining--;
            if (remaining < category.demos.length) {
              final demo = category.demos[remaining];
              return _DemoTile(demo: demo);
            }
            remaining -= category.demos.length;
          }
          return const SizedBox.shrink();
        },
      ),
    );
  }
}

// ── Category header ──

class _CategoryHeader extends StatelessWidget {
  const _CategoryHeader({required this.title, required this.icon});

  final String title;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      child: Row(
        children: [
          Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
          const SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Demo tile ──

class _DemoTile extends StatelessWidget {
  const _DemoTile({required this.demo});

  final _DemoRoute demo;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
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
          onTap: () =>
              Navigator.push(context, MaterialPageRoute(builder: demo.builder)),
        ),
      ),
    );
  }
}

// ── Data classes ──

class _DemoCategory {
  const _DemoCategory({
    required this.title,
    required this.icon,
    required this.demos,
  });

  final String title;
  final IconData icon;
  final List<_DemoRoute> demos;
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
