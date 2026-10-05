import 'dart:async' show unawaited;
import 'dart:convert' show base64Encode, jsonEncode;
import 'dart:ui' as ui;
import 'dart:developer' as developer;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart'
    show Clipboard, DeviceOrientation, SystemChrome;
import 'package:sleuth/sleuth.dart';

import 'custom_detectors/01_simple_structural_detector.dart';
import 'custom_detectors/02_runtime_callback_detector.dart';
import 'custom_detectors/03_hybrid_vm_structural_detector.dart';
import 'demos/combined_chat_demo.dart';
import 'demos/capture_driver.dart';
import 'demos/combined_social_feed_demo.dart';
import 'demos/custom_detector_cookbook_demo.dart';
import 'demos/custom_painter_demo.dart';
import 'demos/font_loading_demo.dart';
import 'demos/fps_stress_test_demo.dart';
import 'demos/frame_timing_capture_screen.dart';
import 'demos/gpu_pressure_demo.dart';
import 'demos/heavy_compute_capture_screen.dart';
import 'demos/heavy_compute_demo.dart';
import 'demos/high_level_setstate_demo.dart';
import 'demos/intrinsic_height_demo.dart';
import 'demos/keepalive_demo.dart';
import 'demos/memory_pressure_capture_screen.dart';
import 'demos/memory_pressure_demo.dart';
import 'demos/network_monitor_capture_screen.dart';
import 'demos/network_stress_demo.dart';
import 'demos/non_lazy_list_demo.dart';
import 'demos/platform_channel_capture_screen.dart';
import 'demos/repaint_capture_screen.dart';
import 'demos/platform_channel_demo.dart';
import 'demos/rebuild_activity_capture_screen.dart';
import 'demos/rebuild_hotspot_demo.dart';
import 'demos/repaint_boundary_demo.dart';
import 'demos/repaint_stress_demo.dart';
import 'demos/stream_resource_capture_screen.dart';
import 'demos/tabbed_shell_demo.dart';
import 'demos/stream_resource_demo.dart';
import 'demos/tracked_resource_capture_screen.dart';
import 'demos/tracked_resource_demo.dart';
import 'demos/shader_jank_demo.dart';
import 'demos/uncached_image_demo.dart';
import 'fake_ai_adapter.dart';
import 'file_state_store.dart';

void main() {
  Sleuth.init();
  _countOverflowErrors();
  _registerDemoExtensions();
  // Capture mode gated behind a dart-define so ordinary profile-mode runs
  // see no extra Timeline.instantSync traffic. Flip on for the
  // runtimeVerified capture procedure:
  //   fvm flutter run --profile --dart-define=SLEUTH_CAPTURE_MODE=true
  // Capture screens emit `sleuth.scenario.{begin,end}` +
  // `sleuth.issue.<id>.<severity>` instant events while enabled.
  const captureMode = bool.fromEnvironment('SLEUTH_CAPTURE_MODE');
  runApp(
    Sleuth.track(
      child: const SleuthDemoApp(),
      config: SleuthConfig(
        captureMode: captureMode,
        // Overlay state (trigger edge, card geometry, hidden issues,
        // severity filter) survives restarts through a JSON file.
        stateStore: FileSleuthStateStore(),
        // Ask AI in the overlay. See [_aiChatAdapter] for the local
        // Ollama default, `SLEUTH_AI_BASE_URL` and `SLEUTH_AI_FAKE`.
        aiChat: _aiChatAdapter(),
        // Rebuild-detector data sources (off by default to keep the
        // minimal install cheap). Both are needed for the Rebuild
        // Hotspot demo — and for every other rebuild-related issue:
        //
        //   • `enableDebugCallbacks: true` wires `debugOnRebuildDirtyWidget`
        //     so the detector can attribute per-type rebuild counts in
        //     DEBUG mode (produces `rebuild_debug_*` issue cards).
        //
        //   • `enableDeepDebugInstrumentation: true` flips
        //     `debugProfileBuildsEnabledUserWidgets` + installs the
        //     `FlutterTimeline.debugCollect()` drain, so PROFILE mode
        //     populates `RouteSession.rebuildCountsByType`. That powers
        //     the always-on `_RebuildStatsBanner` panel on the floating
        //     issues card and the `RebuildStatsPage` drilldown. The
        //     per-widget
        //     events are recorded inside the BUILD scopes, so the
        //     VM-timeline `rebuild_activity` build-time share includes
        //     that instrumentation cost.
        //
        // Without either flag the detector has no data to evaluate,
        // so no rebuild issue of any kind will ever surface — including
        // the Rebuild Hotspot (Dashboard) demo.
        //
        // Capture-mode caveat: deep debug instrumentation flips
        // `debugProfileBuildsEnabledUserWidgets`, which records a timeline
        // event for every user-widget build. That instrumentation runs
        // inside the BUILD scopes, so it inflates the build-time share
        // `rebuild_activity` measures and the BUILD durations
        // HeavyComputeDetector reads, and it multiplies the timeline
        // volume a capture exports. Disable it under captureMode so
        // captures measure the app's own build cost.
        enableDebugCallbacks: !captureMode,
        enableDeepDebugInstrumentation: !captureMode,
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

/// The overlay's AI chat adapter.
///
/// Defaults to a local Ollama server through its OpenAI-compatible API
/// (Ollama ignores the API key, which the adapter requires). On a device,
/// `localhost` is the device itself: point the app at the machine running
/// Ollama with
///
///     --dart-define=SLEUTH_AI_BASE_URL=http://192.168.1.20:11434
///
/// `--dart-define=SLEUTH_AI_FAKE=ok|fail|stall|partial|slow|empty` swaps
/// in [FakeAiChatAdapter], a scripted reply for checking the chat's
/// reply, failure, stall, partial-reply, slow-first-token (8 s) and
/// empty-reply states without a model.
AiChatAdapter _aiChatAdapter() {
  const fakeMode = String.fromEnvironment('SLEUTH_AI_FAKE');
  final fake = FakeAiChatAdapter.forMode(fakeMode);
  if (fake != null) return fake;
  if (fakeMode.isNotEmpty) {
    debugPrint('Sleuth demo: unknown SLEUTH_AI_FAKE=$fakeMode');
  }
  const baseUrl = String.fromEnvironment(
    'SLEUTH_AI_BASE_URL',
    defaultValue: 'http://localhost:11434',
  );
  return AiChatAdapter.openAi(
    apiKey: 'ollama',
    baseUrl: baseUrl,
    model: 'llama3.2',
  );
}

class SleuthDemoApp extends StatelessWidget {
  const SleuthDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
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
class DemoHome extends StatefulWidget {
  const DemoHome({super.key});

  @override
  State<DemoHome> createState() => _DemoHomeState();
}

class _DemoHomeState extends State<DemoHome> {
  bool _startDemoHandled = false;

  /// Opens one demo right after the first frame when the launch asks for
  /// it, so a profile build can be driven without touching the screen.
  /// The request comes from the process environment
  /// (`SLEUTH_START_DEMO=gpu_pressure`, for example through
  /// `xcrun devicectl device process launch --environment-variables
  /// '{"SLEUTH_START_DEMO":"gpu_pressure"}'`) or from
  /// `--dart-define=SLEUTH_START_DEMO=gpu_pressure`. The value is the demo
  /// title lower-cased with runs of non-alphanumerics folded to `_`.
  void _openStartDemo(List<_DemoCategory> categories) {
    if (_startDemoHandled) return;
    _startDemoHandled = true;
    final request = _startDemoRequest();
    if (request == null) return;
    final demo = _demoForSlug(request);
    if (demo == null) {
      debugPrint('Sleuth demo: no demo matches SLEUTH_START_DEMO=$request');
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _pushDemo(Navigator.of(context), demo);
    });
  }

  @override
  Widget build(BuildContext context) {
    final categories = _demoCategories();
    _openStartDemo(categories);

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

  /// Drawn in the theme's primary color, which keeps 3:1 contrast on the
  /// page surface; the demo tiles keep their own colors.
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      child: Row(
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 8),
          Text(
            title,
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

/// Every demo, grouped as the home screen shows them. Shared by the home
/// list, the launch hook, and the `ext.sleuthDemo.*` service extensions.
List<_DemoCategory> _demoCategories() => <_DemoCategory>[
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
        icon: Icons.insights,
        title: 'Rebuild Hotspot (Dashboard)',
        subtitle: 'Rebuild Stats rollup + drilldown',
        color: Colors.pink,
        builder: (_) => const RebuildHotspotDemo(),
      ),
      _DemoRoute(
        icon: Icons.list,
        title: 'Non-Lazy ListView',
        subtitle: 'ListView detector',
        color: Colors.orange,
        builder: (_) => const NonLazyListDemo(),
      ),
      _DemoRoute(
        icon: Icons.upload_file,
        title: 'CSV Import',
        subtitle: 'HeavyCompute warning + critical',
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
        icon: Icons.graphic_eq,
        title: 'Live Waveform',
        subtitle: 'Repaint: aggregate + per-widget',
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
        icon: Icons.memory_outlined,
        title: 'GPU Pressure',
        subtitle: 'GpuPressure detector (hybrid)',
        color: Colors.deepOrange,
        builder: (_) => const GpuPressureDemo(),
      ),
      _DemoRoute(
        icon: Icons.blur_on,
        title: 'Shader Jank',
        subtitle: 'Pipeline builds (Vulkan, Skia)',
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
      _DemoRoute(
        icon: Icons.stream,
        title: 'Stream Resource Leaks',
        subtitle: 'StreamResource: Timer + Controller leaks',
        color: Colors.deepPurple,
        builder: (_) => const StreamResourceDemo(),
      ),
      _DemoRoute(
        icon: Icons.bookmark_added,
        title: 'Tracked Resource Leaks',
        subtitle: 'Sleuth.trackResource retention tracking',
        color: Colors.indigo,
        builder: (_) => const TrackedResourceDemo(),
      ),
    ],
  ),

  // ── Network & I/O ──
  _DemoCategory(
    title: 'Network & I/O',
    icon: Icons.cloud,
    demos: [
      _DemoRoute(
        icon: Icons.search,
        title: 'Search + Gallery',
        subtitle: 'NetworkMonitor: slow / frequency / large',
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

  // ── Navigation ──
  _DemoCategory(
    title: 'Navigation',
    icon: Icons.tab,
    demos: [
      _DemoRoute(
        icon: Icons.view_carousel,
        title: 'Tabbed Shell',
        subtitle: 'IndexedStack tabs: one pattern each',
        color: Colors.cyan,
        builder: (_) => const TabbedShellDemo(),
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
        subtitle: 'Tooltip • Slow frame • Raster hot spot',
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
        subtitle: 'Image • Layout • setState • Correlator',
        color: Colors.deepPurple,
        builder: (_) => const CombinedSocialFeedDemo(),
      ),
      _DemoRoute(
        icon: Icons.chat,
        title: 'Combined: Chat App',
        subtitle: 'Rebuild + KeepAlive + Channel + SetState',
        color: Colors.blue,
        builder: (_) => const CombinedChatDemo(),
      ),
    ],
  ),

  // ── Capture Helpers ──
  // Operator-only tooling for the runtimeVerified bracket-recording
  // procedure (see doc/capture_procedure.md). Each helper drives
  // Sleuth.markScenarioBegin/End around a workload at known magnitude
  // (below / at / above the bracket band) so detectors emit captured
  // trace records on real devices.
  _DemoCategory(
    title: 'Capture Helpers',
    icon: Icons.videocam,
    demos: [
      _DemoRoute(
        icon: Icons.speed,
        title: 'HeavyCompute',
        subtitle: 'heavy_compute warning + critical',
        color: Colors.purple,
        builder: (_) => const HeavyComputeCaptureScreen(),
      ),
      _DemoRoute(
        icon: Icons.refresh,
        title: 'RebuildActivity',
        subtitle: 'rebuild_activity warning + critical',
        color: Colors.teal,
        builder: (_) => const RebuildActivityCaptureScreen(),
      ),
      _DemoRoute(
        icon: Icons.timeline,
        title: 'FrameTiming (jank_detected)',
        subtitle: 'jank_detected warning bracket (60Hz)',
        color: Colors.indigo,
        builder: (_) => const FrameTimingCaptureScreen(),
      ),
      _DemoRoute(
        icon: Icons.data_array,
        title: 'MemoryPressure',
        subtitle: 'heap_growing warning bracket',
        color: Colors.purple,
        builder: (_) => const MemoryPressureCaptureScreen(),
      ),
      _DemoRoute(
        icon: Icons.cloud_download,
        title: 'NetworkMonitor',
        subtitle: 'slow_request warning + critical brackets',
        color: Colors.orange,
        builder: (_) => const NetworkMonitorCaptureScreen(),
      ),
      _DemoRoute(
        icon: Icons.settings_input_hdmi,
        title: 'PlatformChannel',
        subtitle: 'platform_channel_traffic warning bracket',
        color: Colors.blueGrey,
        builder: (_) => const PlatformChannelCaptureScreen(),
      ),
      _DemoRoute(
        icon: Icons.brush,
        title: 'Repaint',
        subtitle: 'excessive_repaint warning bracket',
        color: Colors.pink,
        builder: (_) => const RepaintCaptureScreen(),
      ),
      _DemoRoute(
        icon: Icons.stream,
        title: 'StreamResource',
        subtitle: 'stream_resource_growth warning bracket',
        color: Colors.deepPurple,
        builder: (_) => const StreamResourceCaptureScreen(),
      ),
      _DemoRoute(
        icon: Icons.track_changes,
        title: 'TrackedResource',
        subtitle: 'tracked_resource_concurrent warning',
        color: Colors.teal,
        builder: (_) => const TrackedResourceCaptureScreen(),
      ),
    ],
  ),
];

final _navigatorKey = GlobalKey<NavigatorState>();

_DemoRoute? _demoForSlug(String request) {
  final wanted = _demoSlug(request);
  for (final category in _demoCategories()) {
    for (final demo in category.demos) {
      if (_demoSlug(demo.title) == wanted) return demo;
    }
  }
  return null;
}

void _pushDemo(NavigatorState navigator, _DemoRoute demo) {
  navigator.push(
    MaterialPageRoute<void>(
      settings: RouteSettings(name: '/demo/${demo.title}'),
      builder: demo.builder,
    ),
  );
}

/// `ext.sleuthDemo.open` (`demo: <slug>`) pushes a demo and
/// `ext.sleuthDemo.pop` returns to the home screen, so a profile build can
/// be walked from a VM service client without touching the screen.
void _registerDemoExtensions() {
  developer.registerExtension('ext.sleuthDemo.open', (method, params) async {
    final request = params['demo'] ?? '';
    final demo = _demoForSlug(request);
    final navigator = _navigatorKey.currentState;
    if (demo == null || navigator == null) {
      return developer.ServiceExtensionResponse.error(
        developer.ServiceExtensionResponse.extensionError,
        jsonEncode({
          'error': demo == null ? 'unknown_demo' : 'no_navigator',
          'demo': request,
        }),
      );
    }
    _pushDemo(navigator, demo);
    return developer.ServiceExtensionResponse.result(
      jsonEncode({'opened': demo.title, 'route': '/demo/${demo.title}'}),
    );
  });
  // Remote interaction for profile-build walks: synthetic pointer events
  // go through the real gesture arena, scrolls through the real
  // ScrollPosition, so detectors see what a finger would produce.
  developer.registerExtension('ext.sleuthDemo.tap', (method, params) async {
    final text = params['text'] ?? '';
    final label = params['label'];
    final element = label != null
        ? _findSemanticsLabel(label)
        : _findText(text);
    if (element != null) {
      // A control below the fold would miss the hit test.
      try {
        await Scrollable.ensureVisible(
          element,
          alignment: 0.5,
          duration: const Duration(milliseconds: 150),
        );
        await WidgetsBinding.instance.endOfFrame;
      } catch (_) {
        // Not inside a scrollable, or already disposed.
      }
    }
    final center = element == null ? null : _centerOf(element);
    if (center == null) {
      return developer.ServiceExtensionResponse.error(
        developer.ServiceExtensionResponse.extensionError,
        jsonEncode({'error': 'not_found', 'text': text}),
      );
    }
    await _tapAt(center);
    return developer.ServiceExtensionResponse.result(
      jsonEncode({'tapped': text, 'x': center.dx, 'y': center.dy}),
    );
  });
  developer.registerExtension('ext.sleuthDemo.type', (method, params) async {
    final text = params['text'] ?? '';
    final element = _findElement((e) => e.widget is EditableText);
    if (element == null) {
      return developer.ServiceExtensionResponse.error(
        developer.ServiceExtensionResponse.extensionError,
        jsonEncode({'error': 'no_text_field'}),
      );
    }
    final field = element.widget as EditableText;
    field.controller.text = text;
    field.onChanged?.call(text);
    if (params['submit'] == 'true') field.onSubmitted?.call(text);
    await WidgetsBinding.instance.endOfFrame;
    return developer.ServiceExtensionResponse.result(
      jsonEncode({'typed': text, 'submitted': params['submit'] == 'true'}),
    );
  });
  developer.registerExtension('ext.sleuthDemo.scroll', (method, params) async {
    final pixels = double.tryParse(params['pixels'] ?? '') ?? 600;
    final ms = int.tryParse(params['ms'] ?? '') ?? 600;
    final horizontal = params['axis'] == 'horizontal';
    final state = _findScrollable(horizontal);
    if (state == null) {
      return developer.ServiceExtensionResponse.error(
        developer.ServiceExtensionResponse.extensionError,
        jsonEncode({'error': 'no_scrollable'}),
      );
    }
    final position = state.position;
    final target = (position.pixels + pixels).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    await position.animateTo(
      target,
      duration: Duration(milliseconds: ms),
      curve: Curves.easeOutCubic,
    );
    return developer.ServiceExtensionResponse.result(
      jsonEncode({
        'from': position.pixels - (target - position.pixels),
        'to': target,
      }),
    );
  });
  developer.registerExtension('ext.sleuthDemo.fling', (method, params) async {
    final dy = double.tryParse(params['dy'] ?? '') ?? -500;
    final dx = double.tryParse(params['dx'] ?? '') ?? 0;
    final ms = int.tryParse(params['ms'] ?? '') ?? 120;
    final horizontal = dx.abs() > dy.abs();
    final state = _findScrollable(horizontal);
    final element = state?.context as Element?;
    final center = element == null ? null : _centerOf(element);
    if (center == null) {
      return developer.ServiceExtensionResponse.error(
        developer.ServiceExtensionResponse.extensionError,
        jsonEncode({'error': 'no_scrollable'}),
      );
    }
    await _dragFrom(center, Offset(dx, dy), ms);
    return developer.ServiceExtensionResponse.result(
      jsonEncode({'flung': true, 'dx': dx, 'dy': dy}),
    );
  });
  developer.registerExtension('ext.sleuthDemo.pop', (method, params) async {
    final navigator = _navigatorKey.currentState;
    final popped = navigator != null && navigator.canPop();
    if (popped) navigator.pop();
    return developer.ServiceExtensionResponse.result(
      jsonEncode({'popped': popped}),
    );
  });
  // Hands-free capture legs for the time-share brackets
  // (doc/capture_procedure.md). `captureLeg` starts a leg and returns at
  // once; `captureResult` polls it.
  developer.registerExtension('ext.sleuthDemo.captureLeg', (
    method,
    params,
  ) async {
    final response = await startCaptureLeg(
      detector: params['detector'] ?? '',
      tier: params['tier'] ?? 'warning',
      role: params['leg'] ?? '',
    );
    return developer.ServiceExtensionResponse.result(jsonEncode(response));
  });
  developer.registerExtension('ext.sleuthDemo.captureResult', (
    method,
    params,
  ) async {
    return developer.ServiceExtensionResponse.result(
      jsonEncode(
        CaptureDriver.instance.result(consume: params['consume'] == 'true'),
      ),
    );
  });
  developer.registerExtension('ext.sleuthDemo.vmAxes', (method, params) async {
    return developer.ServiceExtensionResponse.result(
      jsonEncode(readVmAxes(reset: params['reset'] == 'true')),
    );
  });
  // System back as the Android back button sends it: the Sleuth overlay
  // closes its innermost layer first; `handled: false` means the app
  // (or the OS) got it.
  developer.registerExtension('ext.sleuthDemo.back', (method, params) async {
    // handlePopRoute is the binding entry point for the platform back
    // message; calling it here reproduces a hardware back press.
    // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
    final handled = await WidgetsBinding.instance.handlePopRoute();
    await WidgetsBinding.instance.endOfFrame;
    return developer.ServiceExtensionResponse.result(
      jsonEncode({'handled': handled}),
    );
  });
  developer.registerExtension('ext.sleuthDemo.clipboard', (
    method,
    params,
  ) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    return developer.ServiceExtensionResponse.result(
      jsonEncode({'text': data?.text}),
    );
  });
  // Drives the overlay through its state: `action` = open | close | hide |
  // undo | restoreAll | toggleSeverity (with `severity` = critical |
  // warning | ok) | setTheme (with `preset` = hc_dark | hc_light |
  // seed:<hex> | none). `hide` hides the first visible card; `undo`
  // restores the most recently hidden key.
  developer.registerExtension('ext.sleuthDemo.overlay', (method, params) async {
    final state = Sleuth.overlayUiState;
    if (state == null) return _demoError({'error': 'no_controller'});
    final action = params['action'] ?? '';
    final result = <String, Object?>{'action': action};
    switch (action) {
      case 'open':
        state.dashboardOpen = true;
      case 'close':
        state.dashboardOpen = false;
      case 'hide':
        final visible = state.visibleIssues(_currentIssues());
        if (visible.isEmpty) return _demoError({'error': 'no_visible_issue'});
        final key = OverlayUiState.hideKeyFor(visible.first);
        state.hide(key);
        result['hidden'] = key;
      case 'undo':
        if (state.hiddenKeys.isEmpty) {
          return _demoError({'error': 'nothing_hidden'});
        }
        final key = state.hiddenKeys.last;
        state.unhide(key);
        result['restored'] = key;
      case 'restoreAll':
        state.restoreAll();
      case 'setTheme':
        final preset = params['preset'] ?? '';
        if (preset == 'none') {
          Sleuth.updateTheme(null);
        } else {
          final theme = _themePreset(preset);
          if (theme == null) {
            return _demoError({'error': 'bad_preset', 'preset': preset});
          }
          Sleuth.updateTheme(theme);
        }
        result['preset'] = preset;
      case 'toggleSeverity':
        final severity = IssueSeverity.values
            .where((s) => s.name == params['severity'])
            .firstOrNull;
        if (severity == null) {
          return _demoError({
            'error': 'bad_severity',
            'severity': params['severity'],
          });
        }
        result['toggled'] = state.toggleSeverity(severity);
      default:
        return _demoError({'error': 'unknown_action', 'action': action});
    }
    await WidgetsBinding.instance.endOfFrame;
    return developer.ServiceExtensionResponse.result(
      jsonEncode({...result, ..._overlayStateJson(state)}),
    );
  });
  // Theme mode as the header toggle sets it: `mode` = system | light |
  // dark. An `updateTheme` override is kept and shows under System.
  developer.registerExtension('ext.sleuthDemo.theme', (method, params) async {
    final state = Sleuth.overlayUiState;
    if (state == null) return _demoError({'error': 'no_controller'});
    final mode = SleuthThemeMode.values
        .where((m) => m.name == params['mode'])
        .firstOrNull;
    if (mode == null) {
      return _demoError({'error': 'bad_mode', 'mode': params['mode']});
    }
    state.themeMode = mode;
    await WidgetsBinding.instance.endOfFrame;
    return developer.ServiceExtensionResponse.result(
      jsonEncode({'themeMode': state.themeMode.name}),
    );
  });
  // Accessibility state for the device pass: platform settings, the text
  // scale the overlay uses, overflow reports since launch, and every
  // labelled or actionable semantics node with its size and actions.
  //
  // The semantics tree is built for the dump only and released after it,
  // so the dump does not leave semantics on (which changes what Sleuth's
  // debug paint counts include).
  developer.registerExtension('ext.sleuthDemo.a11y', (method, params) async {
    final handle = SemanticsBinding.instance.ensureSemantics();
    try {
      await WidgetsBinding.instance.endOfFrame;
      final dispatcher = WidgetsBinding.instance.platformDispatcher;
      final features = dispatcher.accessibilityFeatures;
      return developer.ServiceExtensionResponse.result(
        jsonEncode({
          'textScale': dispatcher.textScaleFactor,
          'overlayTextScale':
              _textScaleAt('FloatingIssuesCard') ??
              _textScaleAt('TriggerButton'),
          'highContrast': features.highContrast,
          'disableAnimations': features.disableAnimations,
          'reduceMotion': features.reduceMotion,
          'boldText': features.boldText,
          'accessibleNavigation': features.accessibleNavigation,
          'overflowErrors': _overflowErrors,
          'semantics': _semanticsNodes(),
        }),
      );
    } finally {
      handle.dispose();
    }
  });
  // PNG of the whole screen (base64) for hands-free visual checks. Uses
  // the root layer, so it includes the overlay.
  developer.registerExtension('ext.sleuthDemo.screenshot', (
    method,
    params,
  ) async {
    await WidgetsBinding.instance.endOfFrame;
    final view = RendererBinding.instance.renderViews.first;
    // The root layer is the only whole-screen surface; `debugLayer` is
    // debug-only and this must work in profile too.
    // ignore: invalid_use_of_protected_member
    final layer = view.layer;
    if (layer is! OffsetLayer) return _demoError({'error': 'no_layer'});
    final bounds = Offset.zero & view.flutterView.physicalSize;
    final image = await layer.toImage(bounds);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (bytes == null) return _demoError({'error': 'no_bytes'});
    return developer.ServiceExtensionResponse.result(
      jsonEncode({
        'png': base64Encode(bytes.buffer.asUint8List()),
        'width': image.width,
        'height': image.height,
      }),
    );
  });
  // Orientation for a hands-free rotation check: `value` = portrait |
  // landscape | all. iOS 16+ and Android rotate the app to a forced
  // orientation even when the device is held the other way.
  developer.registerExtension('ext.sleuthDemo.orientation', (
    method,
    params,
  ) async {
    final value = params['value'] ?? '';
    final orientations = switch (value) {
      'portrait' => const [DeviceOrientation.portraitUp],
      'landscape' => const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ],
      'all' => const <DeviceOrientation>[],
      _ => null,
    };
    if (orientations == null) {
      return _demoError({'error': 'bad_value', 'value': value});
    }
    await SystemChrome.setPreferredOrientations(orientations);
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    return developer.ServiceExtensionResponse.result(
      jsonEncode({
        'value': value,
        'width': view.physicalSize.width / view.devicePixelRatio,
        'height': view.physicalSize.height / view.devicePixelRatio,
      }),
    );
  });
  developer.registerExtension('ext.sleuthDemo.overlayState', (
    method,
    params,
  ) async {
    final state = Sleuth.overlayUiState;
    if (state == null) return _demoError({'error': 'no_controller'});
    return developer.ServiceExtensionResponse.result(
      jsonEncode(_overlayStateJson(state)),
    );
  });
}

/// RenderFlex overflow reports seen since launch, for
/// `ext.sleuthDemo.a11y`. Overflow reports are assert-gated, so only debug
/// builds count them.
int _overflowErrors = 0;

/// Counts overflow reports, then hands every error to the previous
/// handler.
void _countOverflowErrors() {
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.summary.toString().contains('overflowed')) _overflowErrors++;
    (previous ?? FlutterError.presentError)(details);
  };
}

/// Text scale at the first element whose widget type is [typeName]
/// (an overlay widget), or null when none is mounted.
double? _textScaleAt(String typeName) {
  double? found;
  void visit(Element element) {
    if (found != null) return;
    if (element.widget.runtimeType.toString() == typeName) {
      // Read without registering a dependency: this runs from a service
      // extension, outside any build.
      final scaler = element
          .getInheritedWidgetOfExactType<MediaQuery>()
          ?.data
          .textScaler;
      found = scaler == null ? null : scaler.scale(10) / 10;
      return;
    }
    element.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(visit);
  return found;
}

/// Labelled or actionable semantics nodes with their logical size.
List<Map<String, Object?>> _semanticsNodes() {
  final nodes = <Map<String, Object?>>[];
  for (final view in RendererBinding.instance.renderViews) {
    final root = view.owner?.semanticsOwner?.rootSemanticsNode;
    if (root == null) continue;
    final dpr = view.flutterView.devicePixelRatio;
    void visit(SemanticsNode node) {
      final data = node.getSemanticsData();
      final actions = [
        for (final action in SemanticsAction.values)
          if (data.hasAction(action) && action != SemanticsAction.customAction)
            action.name,
        for (final id in data.customSemanticsActionIds ?? const <int>[])
          ?CustomSemanticsAction.getAction(id)?.label,
      ];
      if (!node.isMergedIntoParent &&
          (data.label.isNotEmpty || actions.isNotEmpty)) {
        var rect = node.rect;
        for (SemanticsNode? n = node; n != null; n = n.parent) {
          final t = n.transform;
          if (t != null) rect = MatrixUtils.transformRect(t, rect);
        }
        nodes.add({
          'label': data.label,
          'value': data.value,
          'y': double.parse((rect.top / dpr).toStringAsFixed(1)),
          'w': double.parse((rect.width / dpr).toStringAsFixed(1)),
          'h': double.parse((rect.height / dpr).toStringAsFixed(1)),
          'button': data.flagsCollection.isButton,
          'actions': actions,
        });
      }
      node.visitChildren((child) {
        visit(child);
        return true;
      });
    }

    visit(root);
  }
  return nodes;
}

/// `SleuthThemeData` for `ext.sleuthDemo.overlay action=setTheme`:
/// `hc_dark`, `hc_light`, `seed:<hex>` (e.g. `seed:0xFF00838F`) or
/// `none` (clears the override).
SleuthThemeData? _themePreset(String preset) {
  if (preset == 'hc_dark') return const SleuthThemeData.highContrastDark();
  if (preset == 'hc_light') return const SleuthThemeData.highContrastLight();
  if (preset.startsWith('seed:')) {
    final value = int.tryParse(preset.substring(5));
    if (value == null) return null;
    final brightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;
    return _seedThemes.putIfAbsent(
      (value, brightness),
      () => SleuthThemeData.fromSeed(
        Color(value | 0xFF000000),
        brightness: brightness,
      ),
    );
  }
  return null;
}

/// Built once per seed and brightness: the overlay compares themes by
/// identity.
final Map<(int, Brightness), SleuthThemeData> _seedThemes = {};

developer.ServiceExtensionResponse _demoError(Map<String, Object?> body) =>
    developer.ServiceExtensionResponse.error(
      developer.ServiceExtensionResponse.extensionError,
      jsonEncode(body),
    );

List<PerformanceIssue> _currentIssues() =>
    Sleuth.exportSnapshot()?.currentIssues ?? const [];

/// Persisted overlay state plus `dashboardOpen`, `uiStateReady` and the
/// number of cards the overlay shows.
Map<String, Object?> _overlayStateJson(OverlayUiState state) => {
  ...state.toJson(),
  'dashboardOpen': state.dashboardOpen,
  'uiStateReady': Sleuth.isOverlayUiStateReady,
  'visibleIssueCount': state.visibleIssues(_currentIssues()).length,
};

/// Demo slug of the capture screen for each `captureLeg` detector.
const Map<String, String> _captureScreenSlugs = {
  'rebuild': 'rebuildactivity',
  'repaint': 'repaint',
};

const Set<String> _captureTiers = {'warning', 'critical'};
const Set<String> _captureRoles = {'below', 'at', 'above'};

/// Starts a capture leg for `ext.sleuthDemo.captureLeg`: opens the
/// detector's capture screen when it is not mounted, waits up to 3 s for
/// it to register, and starts the same leg its buttons run. Returns
/// `{started: true}` without waiting for the leg, or `{error: ...}`
/// (`busy`, `not_capture_mode`, `vm_disconnected`, `bad_args`,
/// `no_navigator`, `screen_not_ready`).
@visibleForTesting
Future<Map<String, Object?>> startCaptureLeg({
  required String detector,
  required String tier,
  required String role,
  Duration readyTimeout = const Duration(seconds: 3),
}) async {
  final slug = _captureScreenSlugs[detector];
  if (slug == null ||
      !_captureTiers.contains(tier) ||
      !_captureRoles.contains(role) ||
      (detector == 'repaint' && tier != 'warning')) {
    return {'error': 'bad_args'};
  }
  final driver = CaptureDriver.instance;
  if (driver.isBusy) return {'error': 'busy'};
  final capture = Sleuth.diagnoseCaptureState();
  if (!capture.captureMode) return {'error': 'not_capture_mode'};
  if (!capture.vmConnected) return {'error': 'vm_disconnected'};

  var runner = driver.runnerFor(detector);
  if (runner == null) {
    final navigator = _navigatorKey.currentState;
    final demo = _demoForSlug(slug);
    if (navigator == null || demo == null) return {'error': 'no_navigator'};
    _pushDemo(navigator, demo);
    final deadline = DateTime.now().add(readyTimeout);
    while ((runner = driver.runnerFor(detector)) == null &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (runner == null) return {'error': 'screen_not_ready'};
  }
  if (!driver.begin('$detector/$tier/$role')) return {'error': 'busy'};
  unawaited(driver.runLeg(runner, tier, role));
  return {'started': true, 'leg': '$detector/$tier/$role'};
}

/// Detector last/peak time shares for `ext.sleuthDemo.vmAxes`. With
/// [reset] both detectors' capture state is cleared after the read; a
/// reset while a capture leg runs returns `{error: busy}` and leaves the
/// leg's peak alone.
@visibleForTesting
Map<String, Object?> readVmAxes({bool reset = false}) {
  if (reset && CaptureDriver.instance.isBusy) return {'error': 'busy'};
  final rebuild = Sleuth.rebuildDetector;
  final repaint = Sleuth.repaintDetector;
  final axes = <String, Object?>{
    'buildLast': rebuild?.lastObservedBuildPercent ?? 0.0,
    'buildPeak': rebuild?.peakObservedBuildPercent ?? 0.0,
    'paintLast': repaint?.lastObservedPaintPercent ?? 0.0,
    'paintPeak': repaint?.peakObservedPaintPercent ?? 0.0,
    'vmConnected': Sleuth.diagnoseCaptureState().vmConnected,
  };
  if (reset) {
    rebuild?.resetCaptureState();
    repaint?.resetCaptureState();
  }
  return axes;
}

// ── Demo tile ──

class _DemoTile extends StatelessWidget {
  const _DemoTile({required this.demo});

  final _DemoRoute demo;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          leading: CircleAvatar(
            backgroundColor: demo.color.withValues(alpha: 0.15),
            child: Icon(demo.icon, color: demo.color),
          ),
          title: Text(demo.title, style: theme.textTheme.titleMedium),
          subtitle: Text(
            demo.subtitle,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              settings: RouteSettings(name: '/demo/${demo.title}'),
              builder: demo.builder,
            ),
          ),
        ),
      ),
    );
  }
}

/// First element whose [Semantics] widget carries [label] (exact, then
/// prefix match), for icon-only controls that have no text.
Element? _findSemanticsLabel(String label) {
  String? of(Widget w) => w is Semantics ? w.properties.label : null;
  return _findElement((e) => of(e.widget) == label) ??
      _findElement((e) => of(e.widget)?.startsWith(label) ?? false);
}

Element? _findElement(bool Function(Element) test) {
  Element? found;
  void visit(Element element) {
    if (found != null) return;
    if (test(element)) {
      found = element;
      return;
    }
    element.visitChildren(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(visit);
  return found;
}

/// Exact label first (a button), then any text containing it, so a
/// description paragraph that quotes a button label does not win.
Element? _findText(String text) {
  String? label(Widget widget) {
    if (widget is Text) {
      return widget.data ?? widget.textSpan?.toPlainText();
    }
    if (widget is Tooltip) return widget.message;
    return null;
  }

  return _findElement((e) => label(e.widget)?.trim() == text) ??
      _findElement((e) => label(e.widget)?.contains(text) ?? false);
}

/// The largest scrollable on the [horizontal] or vertical axis that can
/// scroll and whose tickers run. A route below the current one keeps its
/// scrollables mounted with tickers off, where an animated scroll never
/// finishes; a small header scroll view loses to the demo's own list.
ScrollableState? _findScrollable(bool horizontal) {
  ScrollableState? best;
  var bestArea = 0.0;
  _findElement((element) {
    if (element is StatefulElement && element.state is ScrollableState) {
      final state = element.state as ScrollableState;
      final axis = state.widget.axis;
      final matches = horizontal
          ? axis == Axis.horizontal
          : axis == Axis.vertical;
      final box = element.renderObject;
      if (matches &&
          state.position.hasContentDimensions &&
          state.position.maxScrollExtent > 0 &&
          TickerMode.getValuesNotifier(element).value.enabled &&
          box is RenderBox &&
          box.hasSize &&
          box.size.width * box.size.height > bestArea) {
        best = state;
        bestArea = box.size.width * box.size.height;
      }
    }
    return false;
  });
  return best;
}

Offset? _centerOf(Element element) {
  final ro = element.renderObject;
  if (ro is! RenderBox || !ro.hasSize || !ro.attached) return null;
  return ro.localToGlobal(ro.size.center(Offset.zero));
}

int _syntheticPointer = 900;

Future<void> _tapAt(Offset position) async {
  final binding = WidgetsBinding.instance;
  final pointer = _syntheticPointer++;
  binding.handlePointerEvent(
    PointerDownEvent(pointer: pointer, position: position),
  );
  await Future<void>.delayed(const Duration(milliseconds: 60));
  binding.handlePointerEvent(
    PointerUpEvent(pointer: pointer, position: position),
  );
  await binding.endOfFrame;
}

Future<void> _dragFrom(Offset start, Offset delta, int ms) async {
  final binding = WidgetsBinding.instance;
  final pointer = _syntheticPointer++;
  const stepMs = 16;
  final steps = (ms / stepMs).clamp(2, 60).round();
  var clock = Duration(milliseconds: DateTime.now().millisecondsSinceEpoch);
  var position = start;
  binding.handlePointerEvent(
    PointerDownEvent(pointer: pointer, position: position, timeStamp: clock),
  );
  for (var i = 1; i <= steps; i++) {
    await Future<void>.delayed(const Duration(milliseconds: stepMs));
    clock += const Duration(milliseconds: stepMs);
    final next = start + delta * (i / steps);
    binding.handlePointerEvent(
      PointerMoveEvent(
        pointer: pointer,
        position: next,
        delta: next - position,
        timeStamp: clock,
      ),
    );
    position = next;
  }
  binding.handlePointerEvent(
    PointerUpEvent(pointer: pointer, position: position, timeStamp: clock),
  );
  await binding.endOfFrame;
}

String? _startDemoRequest() {
  const defined = String.fromEnvironment('SLEUTH_START_DEMO');
  final fromEnvironment = kIsWeb
      ? null
      : Platform.environment['SLEUTH_START_DEMO'];
  final value = fromEnvironment != null && fromEnvironment.isNotEmpty
      ? fromEnvironment
      : defined;
  return value.isEmpty ? null : value;
}

String _demoSlug(String title) => title
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
    .replaceAll(RegExp(r'^_+|_+$'), '');

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
