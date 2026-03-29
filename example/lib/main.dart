import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:widget_watchdog/widget_watchdog.dart';

void main() => runApp(WidgetWatchdog.wrap(child: const WatchdogDemoApp()));

class WatchdogDemoApp extends StatelessWidget {
  const WatchdogDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '🐕 Watchdog Demo',
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
      appBar: AppBar(title: const Text('🐕 Watchdog Demo'), centerTitle: true),
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

// ─────────────────────────────────────────
// Demo 1: High-Level setState
// Triggers: Rebuild, SetStateScope
// ─────────────────────────────────────────
class HighLevelSetStateDemo extends StatefulWidget {
  const HighLevelSetStateDemo({super.key});

  @override
  State<HighLevelSetStateDemo> createState() => _HighLevelSetStateDemoState();
}

class _HighLevelSetStateDemoState extends State<HighLevelSetStateDemo> {
  int _counter = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('High-Level setState')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Counter: $_counter',
              style: Theme.of(context).textTheme.displaySmall,
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '❌ BAD: setState at top level rebuilds 50+ widgets below.\n'
              '✅ FIX: Move counter into a small sub-widget.',
              style: TextStyle(fontSize: 13),
            ),
          ),
          const SizedBox(height: 16),
          // ❌ 50 widgets that all rebuild on setState
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(8),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 5,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
              ),
              itemCount: 50,
              itemBuilder: (_, i) => Container(
                decoration: BoxDecoration(
                  color: Colors.primaries[i % Colors.primaries.length]
                      .withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.center,
                child: Text('${_counter + i}'),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => setState(() => _counter++),
        icon: const Icon(Icons.add),
        label: const Text('setState (top)'),
      ),
    );
  }
}

// ─────────────────────────────────────────
// Demo 2: Non-Lazy ListView
// Triggers: ListView detector (>20 children)
// ─────────────────────────────────────────
class NonLazyListDemo extends StatelessWidget {
  const NonLazyListDemo({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Non-Lazy ListView')),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '❌ BAD: SingleChildScrollView + Column with 40 children\n'
              '✅ FIX: Use ListView.builder for lazy rendering',
              style: TextStyle(fontSize: 13),
            ),
          ),
          // ❌ Non-lazy: all 40 items built immediately
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                children: List.generate(
                  40,
                  (i) => ListTile(
                    leading: CircleAvatar(child: Text('$i')),
                    title: Text('Non-lazy item $i'),
                    subtitle: const Text('This was built eagerly at startup'),
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

// ─────────────────────────────────────────
// Demo 3: IntrinsicHeight Abuse
// Triggers: LayoutBottleneck detector
// ─────────────────────────────────────────
class IntrinsicHeightDemo extends StatelessWidget {
  const IntrinsicHeightDemo({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('IntrinsicHeight Abuse')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            const Text(
              '❌ BAD: IntrinsicHeight causes O(n²) layout passes\n'
              '✅ FIX: Use Expanded/Flexible or fixed-height containers',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 16),
            // ❌ IntrinsicHeight — slow layout
            ...List.generate(
              8,
              (i) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: IntrinsicHeight(
                  child: Row(
                    children: [
                      Expanded(
                        child: Container(
                          color: Colors.blue.withValues(alpha: 0.1 + i * 0.05),
                          padding: const EdgeInsets.all(16),
                          child: Text('Left cell $i\nMulti-line\ncontent'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Container(
                          color: Colors.red.withValues(alpha: 0.1 + i * 0.05),
                          padding: const EdgeInsets.all(16),
                          child: Text('Right $i\n${"Extra line\n" * i}'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────
// Demo 4: Always-Repaint CustomPainter
// Triggers: CustomPainter detector
// ─────────────────────────────────────────
class CustomPainterDemo extends StatefulWidget {
  const CustomPainterDemo({super.key});

  @override
  State<CustomPainterDemo> createState() => _CustomPainterDemoState();
}

class _CustomPainterDemoState extends State<CustomPainterDemo>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Always-Repaint Painter')),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '❌ BAD: shouldRepaint always returns true\n'
              '✅ FIX: Compare old vs new painter properties',
              style: TextStyle(fontSize: 13),
            ),
          ),
          // ❌ Animating with always-true shouldRepaint
          Expanded(
            child: AnimatedBuilder(
              animation: _anim,
              builder: (_, _) => CustomPaint(
                painter: _BadCirclePainter(_anim.value),
                size: Size.infinite,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BadCirclePainter extends CustomPainter {
  _BadCirclePainter(this.progress);
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Color.lerp(Colors.blue, Colors.purple, progress)!
      ..style = PaintingStyle.fill;
    canvas.drawCircle(
      Offset(size.width / 2, size.height / 2),
      50 + progress * 80,
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true; // ❌ Always
}

// ─────────────────────────────────────────
// Demo 5: Uncached Images
// Triggers: ImageMemory detector
// ─────────────────────────────────────────
class UncachedImageDemo extends StatelessWidget {
  const UncachedImageDemo({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Uncached Images')),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '❌ BAD: Network images without cacheWidth/cacheHeight\n'
              '✅ FIX: Add cacheWidth: 300 to decode at display size',
              style: TextStyle(fontSize: 13),
            ),
          ),
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(8),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
              ),
              itemCount: 12,
              itemBuilder: (_, i) => ClipRRect(
                borderRadius: BorderRadius.circular(8),
                // ❌ No cacheWidth — full resolution decoded into memory
                child: Image.network(
                  'https://picsum.photos/seed/$i/800/800',
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => Container(
                    color: Colors.grey.shade200,
                    alignment: Alignment.center,
                    child: const Icon(Icons.broken_image),
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

// ─────────────────────────────────────────
// Demo 6: GlobalKey Overuse
// Triggers: GlobalKey detector (>10 keys)
// ─────────────────────────────────────────
class GlobalKeyDemo extends StatefulWidget {
  const GlobalKeyDemo({super.key});

  @override
  State<GlobalKeyDemo> createState() => _GlobalKeyDemoState();
}

class _GlobalKeyDemoState extends State<GlobalKeyDemo> {
  // ❌ 15 GlobalKeys — way too many
  final _keys = List.generate(15, (_) => GlobalKey());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('GlobalKey Overuse')),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '❌ BAD: 15 GlobalKeys (threshold is 10)\n'
              '✅ FIX: Use ValueKey or UniqueKey instead where possible',
              style: TextStyle(fontSize: 13),
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(8),
              itemCount: _keys.length,
              itemBuilder: (_, i) => Card(
                key: _keys[i], // ❌ GlobalKey
                child: ListTile(
                  title: Text('Item with GlobalKey #$i'),
                  leading: Icon(Icons.key, color: Colors.blue.shade400),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────
// Demo 7: Nested Scroll
// Triggers: NestedScroll detector
// ─────────────────────────────────────────
class NestedScrollDemo extends StatelessWidget {
  const NestedScrollDemo({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Nested Scroll')),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '❌ BAD: SingleChildScrollView > Column with 30 children\n'
              '   inside another ScrollView\n'
              '✅ FIX: Use CustomScrollView with slivers',
              style: TextStyle(fontSize: 13),
            ),
          ),
          // ❌ Nested scrolling
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                children: List.generate(
                  30,
                  (i) => Container(
                    height: 60,
                    margin: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.indigo.withValues(alpha: 0.05 + i * 0.02),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    alignment: Alignment.center,
                    child: Text('Nested scroll item $i'),
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

// ─────────────────────────────────────────
// Demo 8: Heavy Compute on Main Thread
// Triggers: HeavyCompute, FrameTiming
// ─────────────────────────────────────────
class HeavyComputeDemo extends StatefulWidget {
  const HeavyComputeDemo({super.key});

  @override
  State<HeavyComputeDemo> createState() => _HeavyComputeDemoState();
}

class _HeavyComputeDemoState extends State<HeavyComputeDemo> {
  String _result = 'Tap the button to compute on main thread';
  bool _computing = false;

  void _heavyCompute() {
    setState(() {
      _computing = true;
      _result = 'Computing...';
    });

    // ❌ BAD: heavy compute blocks the main isolate
    final random = Random();
    var sum = 0.0;
    for (var i = 0; i < 5000000; i++) {
      sum += random.nextDouble() * random.nextDouble();
    }

    setState(() {
      _computing = false;
      _result =
          'Result: ${sum.toStringAsFixed(2)}\n(UI was frozen during this!)';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Heavy Compute')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                '❌ BAD: 5M iterations on the main isolate\n'
                '✅ FIX: Use Isolate.run() or compute()',
                style: TextStyle(fontSize: 13),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              Text(
                _result,
                style: Theme.of(context).textTheme.bodyLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              // Animated spinner to show UI freeze
              if (_computing) const CircularProgressIndicator(),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _computing ? null : _heavyCompute,
                icon: const Icon(Icons.speed),
                label: const Text('Run Heavy Compute'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────
// Demo 9: KeepAlive Overuse
// Triggers: KeepAlive detector (>5)
// ─────────────────────────────────────────
class KeepAliveDemo extends StatelessWidget {
  const KeepAliveDemo({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('KeepAlive Overuse'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Tab 1'),
              Tab(text: 'Tab 2'),
              Tab(text: 'Tab 3'),
            ],
          ),
        ),
        body: Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                '❌ BAD: All tabs use AutomaticKeepAlive\n'
                '✅ FIX: Only keep alive tabs with expensive state',
                style: TextStyle(fontSize: 13),
              ),
            ),
            Expanded(
              child: TabBarView(
                children: List.generate(
                  3,
                  (tab) => ListView.builder(
                    itemCount: 20,
                    itemBuilder: (_, i) =>
                        _KeepAliveItem(label: 'Tab $tab — Item $i'),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _KeepAliveItem extends StatefulWidget {
  const _KeepAliveItem({required this.label});
  final String label;

  @override
  State<_KeepAliveItem> createState() => _KeepAliveItemState();
}

class _KeepAliveItemState extends State<_KeepAliveItem>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true; // ❌ Every item stays alive

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ListTile(
      leading: const Icon(Icons.all_inclusive),
      title: Text(widget.label),
      subtitle: const Text('wantKeepAlive: true (never GC\'d)'),
    );
  }
}

// ─────────────────────────────────────────
// Demo 10: Opacity Zero
// Triggers: Opacity detector
// ─────────────────────────────────────────
class OpacityZeroDemo extends StatelessWidget {
  const OpacityZeroDemo({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Opacity Zero')),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '❌ BAD: Opacity(opacity: 0.0) still lays out, paints, and hit-tests.\n'
              '✅ FIX: Use Visibility or conditional rendering to skip the subtree.',
              style: TextStyle(fontSize: 13),
            ),
          ),
          const SizedBox(height: 16),
          // ❌ Invisible but still occupying layout + hit testing
          Opacity(
            opacity: 0.0,
            child: Column(
              children: List.generate(
                10,
                (i) => ListTile(
                  title: Text('Invisible item $i'),
                  subtitle: const Text('Still laid out and painted!'),
                ),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '⬆ 10 invisible items above (you can\'t see them but they exist)',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────
// Demo 11: AnimatedBuilder without child
// Triggers: AnimatedBuilder detector
// ─────────────────────────────────────────
class AnimatedBuilderDemo extends StatefulWidget {
  const AnimatedBuilderDemo({super.key});

  @override
  State<AnimatedBuilderDemo> createState() => _AnimatedBuilderDemoState();
}

class _AnimatedBuilderDemoState extends State<AnimatedBuilderDemo>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
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
      appBar: AppBar(title: const Text('AnimatedBuilder No Child')),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '❌ BAD: AnimatedBuilder without child rebuilds entire subtree every tick.\n'
              '✅ FIX: Pass static subtree as child parameter.',
              style: TextStyle(fontSize: 13),
            ),
          ),
          const SizedBox(height: 16),
          // ❌ No child parameter — rebuilds 8 children on every animation tick
          AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              return Column(
                children: [
                  Text(
                    'Value: ${_controller.value.toStringAsFixed(2)}',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 8),
                  ...List.generate(
                    6,
                    (i) => Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 32,
                        vertical: 4,
                      ),
                      child: LinearProgressIndicator(
                        value: (_controller.value + i * 0.1) % 1.0,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────
// Demo 12: Shallow Rebuild Risk
// Triggers: ShallowRebuildRisk detector
// ─────────────────────────────────────────
class ShallowRebuildRiskDemo extends StatefulWidget {
  const ShallowRebuildRiskDemo({super.key});

  @override
  State<ShallowRebuildRiskDemo> createState() => _ShallowRebuildRiskDemoState();
}

class _ShallowRebuildRiskDemoState extends State<ShallowRebuildRiskDemo> {
  int _counter = 0;

  @override
  Widget build(BuildContext context) {
    // ❌ This StatefulWidget is at depth ≤3 and rebuilds frequently
    return Scaffold(
      appBar: AppBar(title: const Text('Shallow Rebuild Risk')),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '❌ BAD: StatefulWidget near root with frequent setState.\n'
              '✅ FIX: Push setState down to a small child widget.',
              style: TextStyle(fontSize: 13),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Counter: $_counter',
              style: Theme.of(context).textTheme.displaySmall,
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: 30,
              itemBuilder: (_, i) => ListTile(
                title: Text('Row $i — rebuild #$_counter'),
                leading: Icon(
                  Icons.circle,
                  color: Colors.primaries[i % Colors.primaries.length],
                ),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => setState(() => _counter++),
        child: const Icon(Icons.add),
      ),
    );
  }
}

// ─────────────────────────────────────────
// Demo 13: Font Loading Stress
// Triggers: FontLoading detector (>3 custom fonts)
// ─────────────────────────────────────────
class FontLoadingDemo extends StatelessWidget {
  const FontLoadingDemo({super.key});

  @override
  Widget build(BuildContext context) {
    // ❌ 5 distinct custom font families — triggers threshold of >3
    const customFonts = [
      'Lobster',
      'Pacifico',
      'DancingScript',
      'IndieFlower',
      'GreatVibes',
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Font Loading Stress')),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '❌ BAD: 5 different custom font families loaded simultaneously.\n'
              '✅ FIX: Limit to 1-2 font families or pre-cache with FontLoader.',
              style: TextStyle(fontSize: 13),
            ),
          ),
          const SizedBox(height: 16),
          ...customFonts.map(
            (font) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  SizedBox(
                    width: 120,
                    child: Text(
                      font,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      'The quick brown fox jumps over the lazy dog',
                      style: TextStyle(fontFamily: font, fontSize: 16),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────
// Demo 14: Repaint Stress
// Triggers: Repaint detector (VM+ or debug callbacks)
// ─────────────────────────────────────────
class RepaintStressDemo extends StatefulWidget {
  const RepaintStressDemo({super.key});

  @override
  State<RepaintStressDemo> createState() => _RepaintStressDemoState();
}

class _RepaintStressDemoState extends State<RepaintStressDemo>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

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
      appBar: AppBar(title: const Text('Repaint Stress')),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '❌ BAD: Continuous repainting without RepaintBoundary.\n'
              '✅ FIX: Wrap animated content in RepaintBoundary.\n'
              '(Detected in VM+ or debug callback mode)',
              style: TextStyle(fontSize: 13),
            ),
          ),
          // ❌ No RepaintBoundary — repaints propagate up the tree
          Expanded(
            child: AnimatedBuilder(
              animation: _controller,
              child: null, // intentionally no child
              builder: (context, _) {
                return CustomPaint(
                  painter: _WavePainter(_controller.value),
                  child: Center(
                    child: Text(
                      '${(_controller.value * 360).toInt()}°',
                      style: Theme.of(context).textTheme.displayMedium,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter(this.progress);
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color =
          Color.lerp(
            const Color(0xFF3B82F6),
            const Color(0xFFEF4444),
            progress,
          ) ??
          const Color(0xFF3B82F6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;

    for (int i = 0; i < 8; i++) {
      final radius = 30.0 + i * 20 + progress * 40;
      canvas.drawCircle(Offset(size.width / 2, size.height / 2), radius, paint);
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) => true; // ❌ Always repaints
}

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
    _addLog('--- All done. Check the Watchdog overlay. ---');
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

// ───────────────────────────────────────────────
// Combined Demo 1: Social Feed
// ───────────────────────────────────────────────
// Triggers: ImageMemory, Opacity, LayoutBottleneck, Rebuild/SetStateScope
// Correlation: Rule 2 (merge rebuild+setState), Rule 4 (escalate image+memory)

class CombinedSocialFeedDemo extends StatefulWidget {
  const CombinedSocialFeedDemo({super.key});

  @override
  State<CombinedSocialFeedDemo> createState() => _CombinedSocialFeedDemoState();
}

class _CombinedSocialFeedDemoState extends State<CombinedSocialFeedDemo> {
  int _likeCount = 0;

  @override
  Widget build(BuildContext context) {
    // ❌ setState at top level rebuilds entire feed
    return Scaffold(
      appBar: AppBar(title: const Text('Social Feed (Combined)')),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            color: Colors.deepPurple.withValues(alpha: 0.05),
            child: const Text(
              'This screen combines 4+ anti-patterns you\'d find in a '
              'real social media feed. Open the Watchdog overlay to see '
              'how issues are correlated, merged, and ranked.',
              style: TextStyle(fontSize: 12),
            ),
          ),

          // ❌ Opacity(0.0) hides a "load more" banner — invisible but
          //    still laid out, hit-tested, and painted.
          Opacity(
            opacity: 0.0,
            child: Container(
              height: 48,
              alignment: Alignment.center,
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 8),
                  Text('Loading more posts…'),
                ],
              ),
            ),
          ),

          // ❌ Feed items
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: List.generate(8, (i) => _buildFeedCard(i)),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        // ❌ Top-level setState rebuilds all 8 cards + images
        onPressed: () => setState(() => _likeCount++),
        icon: const Icon(Icons.favorite),
        label: Text('Like ($_likeCount)'),
      ),
    );
  }

  Widget _buildFeedCard(int index) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ❌ IntrinsicHeight forces two-pass layout for the header row
          IntrinsicHeight(
            child: Row(
              children: [
                const SizedBox(width: 12),
                // ❌ Avatar — no cacheWidth
                ClipOval(
                  child: Image.network(
                    'https://picsum.photos/seed/avatar$index/200/200',
                    width: 40,
                    height: 40,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Container(
                      width: 40,
                      height: 40,
                      color: Colors.grey.shade300,
                      child: const Icon(Icons.person, size: 20),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'User ${index + 1}',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        '${index + 1}h ago',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  width: 3,
                  color: Colors.deepPurple.withValues(alpha: 0.3),
                ),
              ],
            ),
          ),

          // ❌ Post image — no cacheWidth, full 800×600 decoded
          Image.network(
            'https://picsum.photos/seed/post$index/800/600',
            height: 200,
            width: double.infinity,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => Container(
              height: 200,
              color: Colors.grey.shade200,
              alignment: Alignment.center,
              child: const Icon(Icons.broken_image, size: 40),
            ),
          ),

          // Caption and like count
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$_likeCount likes',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  'Post #${index + 1} — a beautiful scene captured on '
                  'a sunny afternoon. #photography #nature',
                  style: const TextStyle(fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────────────────────────────
// Combined Demo 2: Analytics Dashboard
// ───────────────────────────────────────────────
// Triggers: CustomPainter, AnimatedBuilder, GlobalKey, FontLoading, ListView
// Correlation: Rule 1 (suppress AnimBuilder if no paint), Rule 3 (escalate GPU+Painter)

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
  final _tileKeys = List.generate(12, (_) => GlobalKey());

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
      appBar: AppBar(title: const Text('Analytics (Combined)')),
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

          // ❌ Non-lazy list: all 12 tiles built eagerly
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: List.generate(12, (i) {
                  return Card(
                    // ❌ GlobalKey on every tile
                    key: _tileKeys[i],
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: Colors
                            .primaries[i % Colors.primaries.length]
                            .withValues(alpha: 0.15),
                        child: Text('${i + 1}'),
                      ),
                      title: Text('Metric ${i + 1}'),
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
