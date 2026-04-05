import '../models/performance_issue.dart';

/// Type alias for structured issue explanations used by the encyclopedia.
typedef IssueExplanation = ({
  String displayName,
  IssueCategory category,
  String whatItIs,
  String? readingTheData,
  String whyItMatters,
  String howToFix,
  String? whenToIgnore,
});

/// Provides detailed educational explanations for each issue type.
///
/// Each explanation helps developers understand what a detection means, why it
/// matters for performance, how to fix it beyond the brief hint, and when it
/// might be a false positive they can safely ignore.
///
/// Keyed by [PerformanceIssue.stableId]. Dynamic suffixes (e.g.
/// `excessive_keep_alive:3`, `rebuild_debug_MyWidget`) are stripped to match
/// the base explanation.
class IssueExplanationBuilder {
  IssueExplanationBuilder._();

  /// Returns a structured explanation for the given [stableId], or `null` if
  /// no explanation exists (e.g. custom detector issues).
  static IssueExplanation? explain(String? stableId) {
    if (stableId == null) return null;
    return _explanations[_baseId(stableId)];
  }

  /// All explanations for the encyclopedia page.
  static Map<String, IssueExplanation> get allExplanations => _explanations;

  /// Category display order following the rendering pipeline.
  static const _categoryOrder = [
    IssueCategory.build,
    IssueCategory.layout,
    IssueCategory.paint,
    IssueCategory.raster,
    IssueCategory.memory,
    IssueCategory.network,
    IssueCategory.font,
    IssueCategory.channel,
  ];

  /// Entries grouped by category, ordered by rendering pipeline phase.
  static List<
      ({
        IssueCategory category,
        List<(String stableId, IssueExplanation entry)> entries,
      })> get groupedEntries {
    final grouped = <IssueCategory, List<(String, IssueExplanation)>>{};
    for (final entry in _explanations.entries) {
      (grouped[entry.value.category] ??= []).add((entry.key, entry.value));
    }
    return [
      for (final cat in _categoryOrder)
        if (grouped.containsKey(cat)) (category: cat, entries: grouped[cat]!),
    ];
  }

  /// Strip dynamic suffixes: `foo:3` → `foo`, `rebuild_debug_MyWidget` →
  /// `rebuild_debug`, `repaint_debug_MyWidget` → `repaint_debug`.
  static String _baseId(String id) {
    // Colon-suffixed IDs (excessive_keep_alive:3, excessive_global_keys:0)
    final colonIdx = id.indexOf(':');
    if (colonIdx > 0) return id.substring(0, colonIdx);

    // Debug IDs with dynamic widget type suffix
    for (final prefix in _dynamicPrefixes) {
      if (id.startsWith(prefix) && id.length > prefix.length) {
        return prefix.substring(0, prefix.length - 1); // strip trailing _
      }
    }
    return id;
  }

  static const _dynamicPrefixes = ['rebuild_debug_', 'repaint_debug_'];

  // ---------------------------------------------------------------------------
  // Explanation registry
  // ---------------------------------------------------------------------------

  static const _explanations = <String, IssueExplanation>{
    // ── Frame Timing ──────────────────────────────────────────────────────

    'sustained_jank': (
      displayName: 'Sustained Jank',
      category: IssueCategory.build,
      whatItIs:
          'Multiple consecutive frames exceeded their time budget (16.7ms at '
          '60 FPS). This means your app visibly stuttered — the user saw '
          'dropped frames over a sustained period, not just a single hiccup.',
      readingTheData:
          'Like a car that keeps stalling at every intersection — one '
          'stall is annoying, but repeated stalls make the whole journey '
          'feel unreliable.\n\n'
          '• Severe frames — Frames exceeding 2× the budget (33.3ms at 60 FPS). '
          'Normal: 0. Alert: 3+ severe frames in a burst.\n\n'
          '• Janky % — Percentage of recent frames over budget. '
          'Normal: <5%. Alert: >15%.\n\n'
          '• UI Thread / Raster — Time in each pipeline thread. '
          'Both must stay under 16.7ms. The higher one is your bottleneck '
          '(shown as "UI thread" or "Raster thread").\n\n'
          '• Sub-phases (buildScope, flushLayout, flushPaint) — Where UI thread '
          'time was spent. Largest phase is your optimization target.\n\n'
          '• Source: FrameTiming API + VM Timeline.',
      whyItMatters:
          'Sustained jank is the most user-visible performance problem. Users '
          'perceive it as the app "freezing" or "lagging." Even 3–4 consecutive '
          'dropped frames create a noticeable stutter during scrolling or '
          'animation.',
      howToFix:
          'Look at which phase dominated the slow frames — build, layout, or '
          'raster. If build time is high, reduce widget rebuilds (const '
          'constructors, smaller rebuild scopes). If raster time is high, '
          'check for expensive GPU operations (opacity layers, shader masks, '
          'large images). Profile in profile mode with DevTools Timeline to '
          'pinpoint the exact call stack.',
      whenToIgnore:
          'First frame after app launch or route transition often jitters due '
          'to shader warmup and tree construction. If sustained jank only '
          'appears on first navigation, consider shader warm-up strategies.',
    ),

    'jank_detected': (
      displayName: 'Jank Detected',
      category: IssueCategory.build,
      whatItIs: 'A single frame took longer than its time budget to render. At '
          '60 FPS the budget is 16.7ms — this frame exceeded that threshold.',
      readingTheData: 'Like a single skipped beat in music — noticeable '
          'but brief, unlike sustained jank which is the song repeatedly '
          'skipping.\n\n'
          '• Frame duration — Total time for one frame. '
          'Budget: 16.7ms at 60 FPS. Alert: >16.7ms (warning), >33.3ms (critical).\n\n'
          '• UI duration — Time building and laying out widgets.\n\n'
          '• Raster duration — Time compositing and painting to screen.\n\n'
          '• Source: FrameTiming API.',
      whyItMatters:
          'Individual jank frames cause momentary stutters. One or two per '
          'session are normal, but frequent single-frame jank degrades the '
          'overall smoothness perception.',
      howToFix:
          'Check the frame breakdown: was it build-dominated (expensive widget '
          'tree construction) or raster-dominated (GPU bottleneck)? For '
          'build-heavy frames, look for large setState scopes or expensive '
          'build methods. For raster-heavy frames, check for saveLayer '
          'triggers (Opacity, ClipPath, ShaderMask).',
      whenToIgnore:
          'Occasional single jank frames during complex transitions or first '
          'renders are normal. Focus on sustained patterns rather than '
          'isolated spikes.',
    ),

    'raster_cache_thrashing': (
      displayName: 'Raster Cache Thrashing',
      category: IssueCategory.raster,
      whatItIs: 'The raster cache is rapidly evicting and re-creating entries. '
          'Flutter caches rendered layer images to avoid re-rasterizing them '
          'each frame — thrashing means this cache is not effective.',
      readingTheData:
          'Like a painter who keeps throwing away finished canvases and '
          'repainting them from scratch — the work is wasted and the gallery '
          'never fills up.\n\n'
          '• Cache count fluctuation — Variation in raster cache entries across '
          'consecutive frames. Alert: >20% fluctuation for 15+ frames.\n\n'
          '• Consecutive frames — How long the pattern persisted.\n\n'
          '• Source: FrameTiming API cache fields.',
      whyItMatters:
          'When the raster cache thrashes, the GPU must re-rasterize layers '
          'that should have been cached, increasing raster time per frame. '
          'This often manifests as raster-dominated jank during scrolling.',
      howToFix:
          'Reduce the number of cacheable layers competing for cache space. '
          'Add RepaintBoundary widgets around content that changes frequently '
          'to isolate volatile regions. Avoid animating properties that '
          'invalidate large cached layers (e.g., animating a parent opacity '
          'invalidates the entire subtree cache).',
      whenToIgnore:
          'Brief thrashing during route transitions is expected as old route '
          'layers are evicted and new ones are created.',
    ),

    'raster_cache_growing': (
      displayName: 'Raster Cache Growing',
      category: IssueCategory.raster,
      whatItIs:
          'The raster cache is steadily growing in size, meaning more and '
          'more rendered layers are being cached without eviction.',
      readingTheData:
          'Like a warehouse that keeps accepting deliveries but never ships '
          'anything out — eventually it runs out of floor space.\n\n'
          '• Cache KB — Current raster cache size. Growing means more layers '
          'cached without eviction.\n\n'
          '• Growth frames — Consecutive frames with monotonically increasing '
          'cache size. Alert: 30+ frames.\n\n'
          '• Source: FrameTiming API cache bytes.',
      whyItMatters: 'An ever-growing raster cache consumes GPU memory. On '
          'memory-constrained devices this can trigger system memory pressure, '
          'leading to background app kills or system-level throttling.',
      howToFix:
          'Identify widgets that create new cached layers over time — often '
          'dynamically-created list items or pages that remain in memory. '
          'Ensure off-screen content is properly disposed. Use '
          'RepaintBoundary judiciously — each one creates a cache entry.',
      whenToIgnore:
          'During initial app exploration (navigating to new screens for the '
          'first time), cache growth is expected. Concern arises when growth '
          'continues indefinitely on a single screen.',
    ),

    // ── Shader & Compute ──────────────────────────────────────────────────

    'shader_compilation': (
      displayName: 'Shader Compilation',
      category: IssueCategory.raster,
      whatItIs:
          'The GPU shader compiler ran during this frame. Shaders are small '
          'GPU programs that Flutter compiles on first use — this compilation '
          'is expensive and blocks the raster thread.',
      readingTheData:
          'Like a chef sharpening a new knife before the first cut — slow '
          'the first time, but instant on every use after.\n\n'
          '• Compilation ms — Duration of the shader compile event. '
          'Normal: 0ms. Alert: >100ms (warning), >200ms (critical) '
          '(default, configurable).\n\n'
          '• Cumulative count — Total compilations this session. First-run '
          'sessions have more; subsequent launches should have fewer.\n\n'
          '• Source: VM Timeline shader events.',
      whyItMatters:
          'Shader compilation typically adds 20–200ms to a frame, causing '
          'severe single-frame jank. It only happens once per shader per app '
          'session, so it is most noticeable on first use of a visual effect.',
      howToFix: 'Use Flutter\'s SkSL shader warm-up: run your app through all '
          'visual paths, capture the shader bundle with '
          '--cache-sksl, then include it in your build with '
          '--bundle-sksl-path. This pre-compiles shaders at app startup '
          'rather than during interaction.',
      whenToIgnore:
          'Shader compilation is expected on the very first run after install '
          'or update. If you see it repeatedly on the same screens, your '
          'warm-up bundle may be incomplete.',
    ),

    'heavy_compute': (
      displayName: 'Heavy Computation',
      category: IssueCategory.build,
      whatItIs: 'A long-running synchronous operation was detected on the UI '
          'thread. The main isolate was blocked for longer than the frame '
          'budget, preventing the framework from building or rendering.',
      readingTheData:
          'Like a cashier doing complex math by hand while a long line of '
          'customers waits — everything stops until the calculation '
          'finishes.\n\n'
          '• Block duration ms — How long the UI thread was blocked. '
          'Normal: <8ms. Alert: >8ms (warning), >16ms (critical) '
          '(default, configurable).\n\n'
          '• Dirty widgets — Widget names marked dirty during the heavy build. '
          'These identify what triggered the work.\n\n'
          '• Source: VM Timeline build-phase events.',
      whyItMatters:
          'Any synchronous work on the UI thread that exceeds ~16ms blocks '
          'frame rendering. Users see a freeze — no animation, no scroll '
          'response, no touch feedback until the computation completes.',
      howToFix:
          'Move the heavy work to a background isolate using Isolate.run() '
          'or compute(). Common culprits: JSON parsing of large payloads, '
          'image processing, cryptographic operations, complex data '
          'transformations. If the work cannot be moved off-thread, break it '
          'into smaller chunks scheduled across multiple frames.',
      whenToIgnore: null,
    ),

    // ── Memory ────────────────────────────────────────────────────────────

    'gc_pressure': (
      displayName: 'GC Pressure',
      category: IssueCategory.memory,
      whatItIs: 'The garbage collector is running frequently — more often than '
          'expected for normal app operation. Each GC cycle pauses the Dart '
          'isolate briefly to reclaim unused memory.',
      readingTheData: 'Like a janitor who keeps interrupting a meeting to '
          'empty small trash cans — each visit is brief, but they add up and '
          'break concentration.\n\n'
          '• GC/min — Garbage collection events per minute. '
          'Normal: <10 idle, <20 during interaction. Alert: >30/min.\n\n'
          '• The title number (e.g. "45 GC/min") is the rolling rate over '
          'the monitoring window.\n\n'
          '• Source: VM Timeline GC events.',
      whyItMatters:
          'Frequent GC pauses accumulate within a frame\'s budget. While each '
          'pause is short (1–5ms), multiple pauses per frame can push total '
          'frame time over budget. GC pressure also indicates high allocation '
          'rate, which itself wastes CPU cycles.',
      howToFix:
          'Reduce object allocation rate: cache objects that are recreated '
          'each frame, use const constructors for immutable widgets, avoid '
          'creating closures or lists inside build(). Use DevTools Memory '
          'tab to identify top allocating classes and find the allocation '
          'hot spots.',
      whenToIgnore:
          'Brief GC spikes during route transitions or initial data loading '
          'are normal. Concern arises when GC stays elevated during steady-state '
          'interaction (scrolling, idle).',
    ),

    'heap_growing': (
      displayName: 'Heap Growing',
      category: IssueCategory.memory,
      whatItIs:
          'The Dart heap is steadily increasing in size over time, detected '
          'via linear regression on heap usage samples. This suggests objects '
          'are being allocated faster than they are collected.',
      readingTheData:
          'Like a bathtub filling faster than it drains — eventually the '
          'water overflows unless you fix the imbalance.\n\n'
          '• Growth rate KB/s — Heap increase per second via linear regression '
          'over a 30-second window. Normal: 0 (stable). '
          'Alert: >512 KB/s for 10+ seconds (default, configurable).\n\n'
          '• Sustained duration — How long the growth trend persisted. '
          'Longer duration increases leak confidence.\n\n'
          '• Source: VM Service heap samples every 500ms.',
      whyItMatters:
          'Sustained heap growth is often a memory leak — objects that should '
          'be freed are retained by lingering references (undisposed '
          'controllers, uncancelled stream subscriptions, closures capturing '
          'widget references). Left unchecked, the app will hit memory limits '
          'and be killed by the OS.',
      howToFix:
          'Check for undisposed controllers, uncancelled StreamSubscriptions, '
          'and Timer instances in your StatefulWidgets. Every resource '
          'acquired in initState() or didChangeDependencies() must be '
          'released in dispose(). Use DevTools Memory view to take heap '
          'snapshots before and after a user flow — compare to find retained '
          'objects.',
      whenToIgnore:
          'Heap growth during initial app startup or when loading large '
          'datasets is expected. The concern is growth that continues after '
          'the app reaches steady state.',
    ),

    'heap_near_capacity': (
      displayName: 'Heap Near Capacity',
      category: IssueCategory.memory,
      whatItIs: 'The Dart heap is using more than 80% of its current capacity. '
          'The Dart VM dynamically resizes the heap, but when usage '
          'approaches capacity, GC runs more aggressively and the VM may '
          'need to request more memory from the OS.',
      readingTheData:
          'Like a parking garage at 80% capacity — cars can still park, '
          'but the attendant searches harder and exits get congested.\n\n'
          '• Usage % — Heap used divided by heap capacity. Normal: <60%. '
          'Alert: >80% (default, configurable).\n\n'
          '• Usage / Capacity — Absolute values in MB. Capacity grows '
          'dynamically; high usage at high capacity is concerning.\n\n'
          '• Source: VM Service getMemoryUsage().',
      whyItMatters:
          'Near-capacity heap triggers more frequent and longer GC pauses '
          'as the collector works harder to free space. On memory-constrained '
          'devices, the OS may kill your app or other background apps to '
          'reclaim memory. Users experience this as the app or their music '
          'player being killed unexpectedly.',
      howToFix:
          'Reduce peak memory usage: clear image caches when navigating away '
          'from image-heavy screens (PaintingBinding.instance.imageCache'
          '.clear()), dispose large data structures when no longer needed, '
          'decode images at display size using cacheWidth/cacheHeight rather '
          'than full resolution. If heap stays high at idle, investigate for '
          'memory leaks — objects retained beyond their useful lifetime.',
      whenToIgnore:
          'Small heap sizes (< 100MB capacity) can hit 80% during normal '
          'operation without real concern — the VM will expand. Focus on '
          'apps where capacity is already large (> 200MB) or where heap '
          'usage is growing steadily.',
    ),

    'native_memory_growing': (
      displayName: 'Native Memory Growing',
      category: IssueCategory.memory,
      whatItIs:
          'Memory outside the Dart heap (native/external memory) is growing '
          'steadily. This includes decoded image bitmaps, platform channel '
          'buffers, native plugin allocations, and Skia/Impeller GPU '
          'resources.',
      readingTheData:
          'Like invisible water damage behind walls — you can\'t see it from '
          'inside the room (Dart heap), but the building inspector (OS) '
          'knows and may condemn the structure.\n\n'
          '• Growth rate MB/s — Process memory growth outside the Dart heap. '
          'Normal: 0 (stable). Alert: >1 MB/s for 10+ seconds.\n\n'
          '• Sustained duration — How long native memory has been rising. '
          'Brief spikes during image loading are normal.\n\n'
          '• Source: VM Service RSS minus Dart heap.',
      whyItMatters:
          'Native memory is often the largest contributor to total app memory '
          'and is invisible to Dart\'s garbage collector. Growing native '
          'memory can trigger OS-level kills without any warning from the '
          'Dart VM.',
      howToFix:
          'The most common cause is decoded image bitmaps: each full-resolution '
          'image can consume width × height × 4 bytes (e.g., a 4000×3000 '
          'photo = 48MB). Use cacheWidth/cacheHeight to decode at display '
          'size. Clear the image cache when leaving image-heavy screens. '
          'For plugin-related growth, check that native resources are being '
          'released (e.g., camera, video player dispose).',
      whenToIgnore:
          'Initial image loading causes expected native memory growth. '
          'Concern arises when it grows continuously without plateau.',
    ),

    // ── Rebuild & Repaint ─────────────────────────────────────────────────

    'rebuild_activity': (
      displayName: 'Rebuild Activity',
      category: IssueCategory.build,
      whatItIs:
          'A high number of widget rebuilds were detected in a short time '
          'window. The framework is reconstructing widget subtrees more '
          'frequently than expected for the current interaction.',
      readingTheData:
          'Like a doorbell that rings 30 times a minute — each ring '
          'interrupts what you\'re doing, and at that rate you can\'t get '
          'anything else done.\n\n'
          '• Builds/sec — Widget rebuild count in a 1-second window. '
          'Normal: <10/sec at idle. Alert: >10/sec (warning), >30/sec (critical) '
          '(default, configurable).\n\n'
          '• Top dirty widgets — Widget types with most rebuilds '
          '(e.g. "MyWidget (47×)"). Focus on the top contributor.\n\n'
          '• Source: VM Timeline buildScope events.',
      whyItMatters:
          'Each rebuild runs build() methods, diffs the widget tree, and '
          'potentially triggers layout and paint. Excessive rebuilds waste '
          'CPU cycles and can push frame times over budget, especially when '
          'large subtrees are involved.',
      howToFix:
          'Narrow the rebuild scope: move state closer to the widgets that '
          'use it, use const constructors for static subtrees, split large '
          'widgets into smaller components that rebuild independently. '
          'Consider ValueListenableBuilder, AnimatedBuilder, or '
          'BlocBuilder/Selector to rebuild only the affected subtree.',
      whenToIgnore: 'High rebuild activity during animations is expected — '
          'AnimationController drives 60 rebuilds/sec by design. Focus on '
          'rebuilds during user interactions like typing or scrolling.',
    ),

    'rebuild_debug': (
      displayName: 'Widget Rebuild (Debug)',
      category: IssueCategory.build,
      whatItIs: 'A specific widget type is rebuilding at a high rate. Debug '
          'callbacks identified this widget as a frequent rebuilder during '
          'the monitoring window.',
      readingTheData:
          'Like one student who keeps raising their hand every few seconds '
          '— find out why they need so much attention.\n\n'
          '• Rebuild rate/sec — How many times this specific widget type '
          'rebuilt per second. Normal: 0–1/sec at idle.\n\n'
          '• Widget type — The exact class name being tracked.\n\n'
          '• Debug mode only — values may differ in profile mode.\n\n'
          '• Source: debugOnRebuildDirtyWidget callback.',
      whyItMatters:
          'When a single widget type dominates rebuild counts, it suggests '
          'either the widget\'s state is changing too often or its parent is '
          'triggering unnecessary rebuilds that cascade down.',
      howToFix:
          'Check why this widget rebuilds: is its parent calling setState '
          'too broadly? Is it listening to a stream or notifier that fires '
          'too often? Extract the widget into its own StatelessWidget with '
          'const constructor, or use a targeted state management approach '
          'that rebuilds only this widget when its specific data changes.',
      whenToIgnore:
          'Animation-driven widgets (inside AnimatedBuilder) are expected to '
          'rebuild every frame. Clock/timer widgets also rebuild frequently '
          'by design.',
    ),

    'stateful_density': (
      displayName: 'StatefulWidget Density',
      category: IssueCategory.build,
      whatItIs:
          'A high density of StatefulWidgets was found in the widget tree '
          'relative to the total tree size. Each StatefulWidget maintains '
          'its own State object and lifecycle.',
      readingTheData: null,
      whyItMatters:
          'Many StatefulWidgets in a small area amplifies the cost of '
          'rebuilds — each one independently manages state, runs build(), '
          'and can trigger its own setState. This creates a "rebuild storm" '
          'risk where many widgets rebuild simultaneously.',
      howToFix:
          'Audit whether each StatefulWidget truly needs local state. Many '
          'can be converted to StatelessWidget if they only read inherited '
          'or passed-down state. Consolidate related state into a single '
          'parent StatefulWidget or use a state management solution '
          '(Provider, Riverpod, Cubit) to lift state up.',
      whenToIgnore:
          'Form-heavy screens naturally have high StatefulWidget density '
          '(each TextField is stateful). This is expected and acceptable.',
    ),

    'excessive_repaint': (
      displayName: 'Excessive Repaints',
      category: IssueCategory.paint,
      whatItIs:
          'The paint phase is being triggered at a high frequency. Regions '
          'of the screen are being repainted more often than the content '
          'is visually changing.',
      readingTheData:
          'Like repainting an entire room every time you move a picture '
          'frame — most of the wall hasn\'t changed but you\'re redoing '
          'all the work.\n\n'
          '• Paints/sec — Paint events per second across the render tree. '
          'Normal: <10/sec at idle. Alert: >30/sec (warning), >60/sec (critical) '
          '(default, configurable).\n\n'
          '• Source: VM Timeline paint-phase events.',
      whyItMatters:
          'Excessive repainting wastes GPU resources. Each repaint records '
          'drawing commands and sends them to the raster thread. When '
          'large areas repaint unnecessarily, it increases raster time and '
          'can cause raster-thread jank.',
      howToFix:
          'Add RepaintBoundary widgets to isolate frequently-painting regions '
          'from static content. Check CustomPainter.shouldRepaint() — return '
          'false when the painter\'s inputs haven\'t changed. Avoid '
          'animations that invalidate large parent regions.',
      whenToIgnore:
          'Active animations and scroll-driven content are expected to '
          'repaint frequently. Focus on unexpected repaints during idle or '
          'static screens.',
    ),

    'repaint_debug': (
      displayName: 'Widget Repaint (Debug)',
      category: IssueCategory.paint,
      whatItIs: 'A specific widget type is triggering frequent repaints. Debug '
          'callbacks identified this render object as painting more often '
          'than expected.',
      readingTheData:
          'Like one wall in your house that needs a fresh coat every week '
          '— something about that specific surface keeps getting dirty.\n\n'
          '• Repaint rate/sec — How many times this render object repainted '
          'per second.\n\n'
          '• Widget type — The class name of the repainting widget.\n\n'
          '• Debug mode only — values may differ in profile mode.\n\n'
          '• Source: debugOnRepaintRenderObject callback.',
      whyItMatters: 'When one widget type dominates paint activity, it often '
          'indicates a missing RepaintBoundary or a CustomPainter that '
          'always returns true from shouldRepaint().',
      howToFix: 'Wrap the widget in a RepaintBoundary to prevent its repaints '
          'from propagating to parent layers. If it\'s a CustomPainter, '
          'implement shouldRepaint() to compare relevant fields. If it\'s '
          'an animation, ensure only the animating subtree repaints.',
      whenToIgnore:
          'Widgets inside active animations are expected to repaint every '
          'frame.',
    ),

    'excessive_repaint_debug': (
      displayName: 'Excessive Repaint (Debug)',
      category: IssueCategory.paint,
      whatItIs:
          'Debug-mode paint profiling detected an abnormally high repaint '
          'rate across the render tree. Multiple render objects are being '
          'marked as needing paint each frame.',
      readingTheData:
          'Like a maintenance crew repainting the entire building daily '
          '— most surfaces are still fresh, but nobody checks first.\n\n'
          '• Repaint rate — Aggregate repaint frequency across all tracked '
          'render objects.\n\n'
          '• Debug mode only — rates may differ in profile mode.\n\n'
          '• Source: Debug-mode paint profiling callbacks.',
      whyItMatters:
          'A high overall repaint rate means the raster thread is doing '
          'more work per frame than necessary, consuming GPU time that '
          'could cause raster-thread jank.',
      howToFix: 'Identify the root cause: usually an animation or state change '
          'high in the tree that invalidates many descendants. Insert '
          'RepaintBoundary widgets at natural boundaries (list items, '
          'cards, toolbar) to contain repaint propagation.',
      whenToIgnore:
          'During full-screen transitions or scroll, high repaint rate is '
          'expected.',
    ),

    // ── GPU & Raster ──────────────────────────────────────────────────────

    'raster_dominance': (
      displayName: 'Raster Dominance',
      category: IssueCategory.raster,
      whatItIs: 'The raster thread is consistently taking longer than the UI '
          'thread. Frame time is dominated by GPU work (compositing, '
          'painting to screen) rather than widget building.',
      readingTheData:
          'Like a restaurant where the chef finishes dishes quickly but '
          'the waiter takes forever to serve them — the bottleneck is '
          'delivery, not preparation.\n\n'
          '• Raster/UI ratio — Raster thread time divided by UI thread time '
          '(e.g. "2.3×"). Normal: <1.5×. Alert: >2.0× (warning), >4.0× '
          '(critical) (default, configurable).\n\n'
          '• Raster ms / UI ms — Absolute times for each thread. Both must '
          'stay under 16.7ms to avoid jank.\n\n'
          '• Source: VM Timeline thread durations.',
      whyItMatters: 'Raster-thread bottlenecks cannot be solved by optimizing '
          'build() methods — the GPU is the constraint. Users see jank '
          'even if the UI thread finishes quickly, because both threads '
          'must complete within the frame budget.',
      howToFix: 'Reduce GPU workload: minimize saveLayer triggers (Opacity, '
          'ClipPath, ShaderMask), reduce the number of layers, simplify '
          'clip shapes, and add RepaintBoundary to cache static content. '
          'Decode images at display size to reduce texture upload cost. '
          'Consider simplifying visual effects on lower-end devices.',
      whenToIgnore:
          'GPU-intensive screens (complex animations, many overlapping '
          'transparent layers) may naturally be raster-dominated without '
          'being a problem if frames still meet budget.',
    ),

    'expensive_gpu_nodes': (
      displayName: 'Expensive GPU Nodes',
      category: IssueCategory.raster,
      whatItIs: 'Render tree nodes that trigger expensive GPU operations were '
          'found: saveLayer (Opacity, ShaderMask), complex clips (ClipPath), '
          'or large texture uploads.',
      readingTheData:
          'Like adding extra layers of gift wrapping — each layer looks nice '
          'but the package gets heavier and harder to handle.\n\n'
          '• Node count — Expensive GPU render nodes found (Opacity, ClipPath, '
          'ShaderMask, BackdropFilter).\n\n'
          '• Descendant count — Subtree size under each expensive node. '
          'Alert: >5 descendants under specific node types.\n\n'
          '• Source: Structural render tree walk + VM raster timing.',
      whyItMatters:
          'Each saveLayer allocates an offscreen GPU buffer and requires '
          'an extra compositing pass. Stacking these (e.g., Opacity inside '
          'Opacity) multiplies the GPU cost exponentially. On lower-end '
          'devices this is often the primary cause of raster jank.',
      howToFix:
          'Replace Opacity with Visibility for show/hide (no GPU buffer). '
          'Use FadeTransition instead of AnimatedOpacity when possible. '
          'Replace ClipPath with ClipRRect (cheaper). For color overlays, '
          'use ColorFiltered on the image source rather than a stacked '
          'Opacity widget. Flatten layer trees by removing unnecessary '
          'decorations.',
      whenToIgnore: 'Some visual effects genuinely require saveLayer (e.g., '
          'BackdropFilter for blur). The concern is unnecessary layers '
          'from convenience widgets.',
    ),

    // ── setState Scope ────────────────────────────────────────────────────

    'setstate_scope': (
      displayName: 'setState Scope',
      category: IssueCategory.build,
      whatItIs:
          'A StatefulWidget high in the tree is calling setState(), causing '
          'a large subtree to rebuild. The rebuild cost is proportional to '
          'the number of descendant widgets that must be reconstructed.',
      readingTheData: null,
      whyItMatters: 'When setState is called on a widget near the root, every '
          'descendant\'s build() method runs again — even widgets whose '
          'data hasn\'t changed. This is the most common cause of '
          'unnecessary CPU work in Flutter apps.',
      howToFix: 'Move state down to the smallest widget that needs it. Use '
          'ValueListenableBuilder, AnimatedBuilder, or state management '
          '(Provider.select, BlocSelector, Riverpod select) to rebuild '
          'only the widgets that depend on the changing value. Extract '
          'static portions of the subtree into const widgets that the '
          'framework can skip during diff.',
      whenToIgnore:
          'If the StatefulWidget has a small subtree (< 50 widgets), the '
          'rebuild cost is negligible regardless of scope.',
    ),

    // ── Shallow Rebuild Risk ──────────────────────────────────────────────

    'shallow_rebuild_risk': (
      displayName: 'Shallow Rebuild Risk',
      category: IssueCategory.build,
      whatItIs: 'A StatefulWidget near the top of the tree was found without '
          'targeted state management. If this widget calls setState(), the '
          'entire deep subtree below it will rebuild.',
      readingTheData: null,
      whyItMatters:
          'This is a structural risk — it may not be causing jank yet, but '
          'it creates a "blast radius" problem. As the subtree grows or '
          'setState is called more frequently (e.g., during animations), '
          'rebuild cost will increase.',
      howToFix:
          'Use targeted state access patterns: MediaQuery.sizeOf(context) '
          'instead of MediaQuery.of(context), Theme.of(context).colorScheme '
          'instead of Theme.of(context) when you only need colors. Wrap '
          'expensive subtrees in Builder or dedicated widgets that isolate '
          'them from parent rebuilds.',
      whenToIgnore:
          'If the widget never calls setState() (e.g., it only sets state '
          'in initState), the structural risk does not translate to actual '
          'cost.',
    ),

    // ── Structural: ListView ──────────────────────────────────────────────

    'non_lazy_list': (
      displayName: 'Non-Lazy List',
      category: IssueCategory.build,
      whatItIs: 'A ListView (or Column/Row with many children) was found that '
          'builds all its children eagerly instead of lazily. This means '
          'every item in the list is constructed and laid out immediately, '
          'even items far off-screen.',
      readingTheData: null,
      whyItMatters:
          'Eager list construction wastes memory and CPU. A list with 1,000 '
          'items builds all 1,000 widgets upfront, even though only ~10 are '
          'visible. This causes slow initial render and high memory usage.',
      howToFix:
          'Replace ListView(children: [...]) with ListView.builder() which '
          'lazily constructs only visible items plus a small buffer. For '
          'lists with separators, use ListView.separated(). For grids, '
          'use GridView.builder() or SliverGrid with a delegate.',
      whenToIgnore:
          'Lists with fewer than ~20 small items have negligible eager-build '
          'cost. Static menus and option lists are fine as non-lazy.',
    ),

    // ── Structural: Image Memory ──────────────────────────────────────────

    'uncached_images': (
      displayName: 'Uncached Images',
      category: IssueCategory.memory,
      whatItIs: 'Image widgets were found without cacheWidth or cacheHeight '
          'parameters. The image codec will decode the full-resolution '
          'image into memory, regardless of how small it is displayed.',
      readingTheData: null,
      whyItMatters:
          'A 4000×3000 photo decoded at full resolution consumes ~48MB of '
          'memory (width × height × 4 bytes). If displayed in a 200×150 '
          'widget, 47.5MB is wasted. In a list with many images, this can '
          'consume hundreds of megabytes of native memory.',
      howToFix:
          'Add cacheWidth and/or cacheHeight to Image widgets to decode at '
          'display size: Image.network(url, cacheWidth: 400). Use the '
          'device pixel ratio for sharp rendering: '
          'cacheWidth: (200 * MediaQuery.devicePixelRatioOf(context)).round(). '
          'For CachedNetworkImage, use memCacheWidth/memCacheHeight.',
      whenToIgnore:
          'Small images (icons, avatars under 100×100) have negligible '
          'full-resolution cost. SVG and vector images are not affected.',
    ),

    // ── Structural: GlobalKey ─────────────────────────────────────────────

    'excessive_global_keys': (
      displayName: 'Excessive GlobalKeys',
      category: IssueCategory.build,
      whatItIs:
          'A large number of GlobalKey instances were found, particularly '
          'inside scrollable containers. Each GlobalKey maintains a '
          'persistent reference to its Element across the entire app.',
      readingTheData: null,
      whyItMatters: 'GlobalKeys are expensive: they prevent the framework from '
          'efficiently recycling Elements during scroll, force global '
          'registry lookups, and can cause subtle bugs when two widgets '
          'try to use the same GlobalKey simultaneously.',
      howToFix: 'Replace GlobalKey with ValueKey or ObjectKey for list item '
          'identification. Use GlobalKey only when you genuinely need '
          'cross-tree state preservation (e.g., moving a widget between '
          'parents). For form validation, use a single GlobalKey<FormState> '
          'rather than individual field keys.',
      whenToIgnore:
          'A small number of GlobalKeys (< 5) at the page level is normal '
          'and expected (Form, Navigator, Scaffold).',
    ),

    // ── Structural: Nested Scroll ─────────────────────────────────────────

    'nested_scroll': (
      displayName: 'Nested Scrollables',
      category: IssueCategory.build,
      whatItIs:
          'A scrollable widget was found nested inside another scrollable '
          'widget. The inner scroll view receives gesture events that the '
          'outer one also wants to handle.',
      readingTheData: null,
      whyItMatters:
          'Nested scrollables with conflicting axes create confusing UX — '
          'users struggle to predict which scroll view will respond. Same-axis '
          'nesting causes the inner list to eagerly build all children '
          '(losing lazy benefits) or causes scroll physics conflicts.',
      howToFix: 'For same-axis nesting, convert inner ListView to SliverList '
          'inside a CustomScrollView. For cross-axis nesting '
          '(horizontal inside vertical), set a fixed height on the inner '
          'scrollable and use NeverScrollableScrollPhysics if the inner '
          'list shouldn\'t scroll independently.',
      whenToIgnore:
          'Intentional cross-axis scrolling (e.g., horizontal carousel '
          'inside vertical page) with explicit height constraints is fine.',
    ),

    'nested_scroll_same_axis': (
      displayName: 'Same-Axis Nested Scroll',
      category: IssueCategory.build,
      whatItIs:
          'Two scrollable widgets with the same scroll axis (both vertical '
          'or both horizontal) are nested. This is a stronger signal than '
          'general nested scrolling because same-axis nesting almost always '
          'indicates a structural problem.',
      readingTheData: null,
      whyItMatters:
          'Same-axis nested scrollables cause: (1) the inner list builds '
          'all children eagerly (ShrinkWrap), defeating lazy construction, '
          '(2) confusing scroll physics where the user can\'t tell which '
          'list is scrolling, and (3) potential infinite height constraint '
          'errors.',
      howToFix: 'Migrate to CustomScrollView with Slivers: replace the outer '
          'ListView with CustomScrollView, and convert inner lists to '
          'SliverList or SliverGrid. This gives a single scroll controller '
          'and maintains lazy building throughout.',
      whenToIgnore: null,
    ),

    // ── Structural: Opacity ───────────────────────────────────────────────

    'opacity_zero': (
      displayName: 'Opacity Zero',
      category: IssueCategory.layout,
      whatItIs:
          'An Opacity or AnimatedOpacity widget with value 0.0 was found. '
          'Despite being fully invisible, the child widget is still built, '
          'laid out, painted, hit-tested, and included in the semantics tree.',
      readingTheData: null,
      whyItMatters:
          'An invisible Opacity widget wastes all four pipeline phases '
          '(build, layout, paint, raster) plus allocates a saveLayer GPU '
          'buffer. It also confuses screen readers, which announce invisible '
          'content to accessibility users.',
      howToFix: 'Replace Opacity(opacity: 0.0) with Visibility(visible: false) '
          'to skip paint and hit-testing. If you also want to skip layout '
          '(collapse the space), use Visibility(visible: false, '
          'maintainSize: false). For animated show/hide, use '
          'AnimatedSwitcher or FadeTransition which can remove the child '
          'entirely when opacity reaches zero.',
      whenToIgnore:
          'Mid-animation opacity values near 0 are expected during fade '
          'transitions. This detection targets static 0.0 values only.',
    ),

    // ── Structural: Layout ────────────────────────────────────────────────

    'layout_bottleneck': (
      displayName: 'Layout Bottleneck',
      category: IssueCategory.layout,
      whatItIs:
          'IntrinsicHeight or IntrinsicWidth widgets were found in the tree. '
          'These widgets force a two-pass layout: first measuring the '
          'child\'s intrinsic dimensions, then laying out with those '
          'constraints.',
      readingTheData: null,
      whyItMatters:
          'Two-pass layout doubles the layout cost for the affected subtree. '
          'When nested (IntrinsicHeight containing IntrinsicWidth), the cost '
          'grows exponentially — O(2^N) for N nesting levels.',
      howToFix: 'Replace IntrinsicHeight with explicit height constraints from '
          'the parent (SizedBox, ConstrainedBox). For equal-height rows, '
          'use Table or CrossAxisAlignment.stretch in a Row with Expanded '
          'children. For text-dependent heights, measure text once with '
          'TextPainter and pass the result as a constraint.',
      whenToIgnore:
          'A single IntrinsicHeight wrapping a small subtree (< 20 widgets) '
          'has negligible cost. The concern is nesting or wrapping large '
          'subtrees.',
    ),

    // ── Structural: CustomPainter ─────────────────────────────────────────

    'always_repaint_painter': (
      displayName: 'Always-Repaint Painter',
      category: IssueCategory.paint,
      whatItIs:
          'A CustomPainter was found whose shouldRepaint() always returns '
          'true. This forces the framework to repaint this widget every '
          'single frame, regardless of whether its visual state changed.',
      readingTheData: null,
      whyItMatters:
          'Always-repaint painters generate unnecessary paint work every '
          'frame. For complex painters with many drawing operations, this '
          'wastes significant GPU time and prevents the raster cache from '
          'being effective.',
      howToFix: 'Override shouldRepaint() to compare the fields that affect '
          'painting: return old.color != color || old.progress != progress. '
          'Only return true when the visual output would actually change. '
          'If the painter is driven by an animation, use AnimatedBuilder '
          'with a child parameter to separate animated and static content.',
      whenToIgnore: 'Painters that genuinely change every frame (real-time '
          'visualizations, particle systems) need shouldRepaint → true.',
    ),

    'frequent_repaint_painter': (
      displayName: 'Frequent Repaint Painter',
      category: IssueCategory.paint,
      whatItIs: 'A CustomPainter is repainting at a high frequency. While '
          'shouldRepaint() may be implemented, it is returning true too '
          'often — the painter\'s inputs are changing rapidly.',
      readingTheData: null,
      whyItMatters:
          'Frequent repainting of complex painters can dominate raster '
          'thread time. Each repaint records all drawing commands and '
          'sends them through the rendering pipeline.',
      howToFix:
          'Reduce the frequency of input changes to the painter. If driven '
          'by an animation, consider whether the animation tick rate can be '
          'reduced or whether some paint operations can be cached. Use '
          'RepaintBoundary to prevent the painter\'s repaints from '
          'propagating to parent layers.',
      whenToIgnore: 'Painters used for active animations (progress indicators, '
          'waveforms) are expected to repaint frequently.',
    ),

    // ── Structural: Keep Alive ────────────────────────────────────────────

    'excessive_keep_alive': (
      displayName: 'Excessive KeepAlive',
      category: IssueCategory.memory,
      whatItIs:
          'Many pages or tab contents are using AutomaticKeepAliveClientMixin '
          'to stay alive when scrolled off-screen or when tabs switch. Each '
          'kept-alive subtree remains in memory with its full State.',
      readingTheData: null,
      whyItMatters:
          'Keep-alive subtrees consume memory even when invisible. With many '
          'tabs or pages kept alive, the app retains large widget/element '
          'trees, image caches, and controller state that would otherwise be '
          'freed.',
      howToFix:
          'Remove KeepAlive from pages that are cheap to rebuild. Keep it '
          'only for pages with expensive initialization (network-loaded '
          'content, complex scroll positions). Consider lazy initialization '
          'patterns where pages load data only when first viewed and rely '
          'on a cache layer rather than keeping the widget alive.',
      whenToIgnore:
          'A small number of keep-alive tabs (2–3) is a reasonable trade-off '
          'between memory and user experience (instant tab switching).',
    ),

    // ── Structural: AnimatedBuilder ───────────────────────────────────────

    'animated_builder_no_child': (
      displayName: 'AnimatedBuilder Without Child',
      category: IssueCategory.build,
      whatItIs: 'An AnimatedBuilder (or similar transition widget) was found '
          'without using the child parameter. The entire subtree inside '
          'the builder callback is rebuilt on every animation tick (60x/sec).',
      readingTheData: null,
      whyItMatters:
          'Without the child optimization, every animation frame rebuilds '
          'the entire widget subtree inside the builder — even static '
          'content that doesn\'t depend on the animation value. For complex '
          'subtrees, this creates 60 expensive rebuilds per second.',
      howToFix:
          'Pass static widgets via the child parameter. The child is built '
          'once and passed to the builder callback as a pre-built widget:\n'
          'AnimatedBuilder(\n'
          '  animation: controller,\n'
          '  child: const ExpensiveChild(), // built once\n'
          '  builder: (context, child) => Transform.rotate(\n'
          '    angle: controller.value,\n'
          '    child: child, // reused each frame\n'
          '  ),\n'
          ')',
      whenToIgnore:
          'If the entire subtree truly depends on the animation value '
          '(e.g., a canvas that redraws based on progress), the child '
          'parameter provides no benefit.',
    ),

    // ── Structural: Font Loading ──────────────────────────────────────────

    'multiple_custom_fonts': (
      displayName: 'Multiple Custom Fonts',
      category: IssueCategory.font,
      whatItIs:
          'Multiple custom (non-system) fonts are in use. Custom fonts must '
          'be loaded from assets or network before they can render — until '
          'loaded, Flutter shows invisible text (FOIT) or a fallback font.',
      readingTheData: null,
      whyItMatters:
          'Each custom font adds to app bundle size and initial load time. '
          'If fonts load asynchronously, text flashes from fallback to '
          'custom font (FOUT), creating a jarring visual experience. '
          'Multiple fonts multiply this effect.',
      howToFix:
          'Minimize the number of custom font families. Use font subsetting '
          'in pubspec.yaml to include only the characters you need. Preload '
          'fonts at app startup using FontLoader. Consider using system '
          'fonts for body text and reserving custom fonts for headings only.',
      whenToIgnore:
          'Apps with strong brand requirements may need multiple custom '
          'fonts. If fonts are bundled in the app (not network-loaded), '
          'the runtime cost is minimal after first render.',
    ),

    // ── Structural: RepaintBoundary ───────────────────────────────────────

    'missing_repaint_boundary': (
      displayName: 'Missing RepaintBoundary',
      category: IssueCategory.paint,
      whatItIs:
          'An expensive GPU widget (CustomPainter, BackdropFilter, ShaderMask, '
          'or similar) was found without a RepaintBoundary ancestor. '
          'Without the boundary, repaints propagate up to the nearest '
          'existing boundary, potentially repainting a large parent region.',
      readingTheData: null,
      whyItMatters:
          'When expensive paint operations share a repaint boundary with '
          'cheaper content, any change to either region repaints everything. '
          'A RepaintBoundary isolates the expensive region so it only '
          'repaints when its own content changes.',
      howToFix: 'Wrap the expensive widget in a RepaintBoundary:\n'
          'RepaintBoundary(\n'
          '  child: CustomPaint(painter: myExpensivePainter),\n'
          ')\n'
          'This creates a separate compositing layer that is cached and '
          'only re-rasterized when the painter marks itself as needing '
          'repaint.',
      whenToIgnore:
          'If the expensive widget already repaints rarely (static content) '
          'or if the parent boundary is already small, adding another '
          'RepaintBoundary adds layer overhead without benefit.',
    ),

    // ── Network ───────────────────────────────────────────────────────────

    'slow_request': (
      displayName: 'Slow Request',
      category: IssueCategory.network,
      whatItIs: 'An HTTP request took longer than the configured threshold '
          '(default: 2 seconds) to complete. The total time includes DNS '
          'resolution, TCP handshake, TLS negotiation, server processing, '
          'and response transfer.',
      readingTheData:
          'Like ordering food and waiting 20 minutes for the waiter to '
          'return — the kitchen might be slow, or the waiter took a '
          'detour.\n\n'
          '• Request duration — Total time from request start to response '
          'complete. Normal: <500ms. Alert: >2000ms (warning, default, '
          'configurable), >5000ms (critical).\n\n'
          '• Worst request — Slowest URL and duration shown in the title.\n\n'
          '• Source: HTTP client instrumentation.',
      whyItMatters: 'Slow network requests block UI updates that depend on the '
          'response. Users see loading spinners, empty screens, or stale '
          'data. If the request is made during a frame callback (bad '
          'practice), it can directly cause jank.',
      howToFix:
          'Investigate whether the slowness is server-side or network-side. '
          'Add response caching to avoid repeated slow requests. Implement '
          'optimistic UI updates where possible. For large payloads, '
          'consider pagination or streaming. Use a timeout with fallback '
          'UI to prevent indefinite loading states.',
      whenToIgnore:
          'Initial cold-start requests (first request after app launch) '
          'are often slower due to DNS and connection setup. File uploads '
          'naturally take longer.',
    ),

    'large_response': (
      displayName: 'Large Response',
      category: IssueCategory.network,
      whatItIs:
          'An HTTP response exceeded the configured size threshold (default: '
          '1MB). Large responses consume memory during download and require '
          'significant CPU time to parse.',
      readingTheData:
          'Like ordering a single book and receiving the entire encyclopedia '
          '— you got what you needed, buried under data you\'ll never '
          'read.\n\n'
          '• Response size — Content-Length or measured body bytes. '
          'Normal: <200KB for API responses. '
          'Alert: >1MB (default, configurable).\n\n'
          '• The title shows the count and largest. Detail lists each URL.\n\n'
          '• Source: HTTP client instrumentation.',
      whyItMatters:
          'Large JSON payloads parsed on the main isolate cause jank — a '
          '1MB JSON response can take 50–200ms to decode, blocking multiple '
          'frames. The raw response bytes also contribute to memory pressure '
          'during download.',
      howToFix:
          'Request only the data you need: use pagination, field filtering, '
          'or GraphQL to reduce payload size. Parse large responses in a '
          'background isolate using Isolate.run() or compute(). For image '
          'or file downloads, stream to disk rather than buffering in '
          'memory.',
      whenToIgnore:
          'File downloads and media streaming responses are expected to be '
          'large. Focus on API/JSON responses that could be trimmed.',
    ),

    'request_frequency': (
      displayName: 'Request Frequency',
      category: IssueCategory.network,
      whatItIs:
          'HTTP requests are being made at a rate exceeding the configured '
          'threshold (default: 30 per 5-second window). This suggests '
          'rapid-fire API calls — possibly unbatched list loading, polling '
          'without throttling, or duplicate requests.',
      readingTheData:
          'Like calling the same store 30 times in 5 minutes to ask about '
          'different items — one call with a list would be far faster.\n\n'
          '• Requests per window — HTTP requests in a 5-second sliding window. '
          'Normal: <10/window. Alert: >30 per 5 seconds '
          '(default, configurable).\n\n'
          '• Bursts during page load are expected; sustained high '
          'frequency is the concern.\n\n'
          '• Source: HTTP client instrumentation.',
      whyItMatters: 'High request frequency wastes battery and bandwidth. Each '
          'request has connection overhead, and the response processing '
          'competes with UI work for CPU time. Servers may also rate-limit '
          'or throttle aggressive clients.',
      howToFix: 'Batch or debounce repeated requests: combine multiple item '
          'fetches into a single list endpoint. Add request deduplication '
          'to prevent identical in-flight requests. For polling, use '
          'exponential backoff or WebSocket/SSE for real-time updates '
          'instead.',
      whenToIgnore:
          'Initial screen loads that fetch multiple independent resources '
          'in parallel may briefly spike request frequency. This is '
          'acceptable as a one-time burst.',
    ),

    // ── Platform Channel ──────────────────────────────────────────────────

    'platform_channel_traffic': (
      displayName: 'Platform Channel Traffic',
      category: IssueCategory.channel,
      whatItIs: 'High-frequency platform channel calls were detected. Platform '
          'channels are the bridge between Dart and native code (Android/'
          'iOS) — each call involves serialization, thread switching, and '
          'deserialization.',
      readingTheData:
          'Like passing notes between two classrooms through a narrow '
          'hallway — each trip takes time, and too many at once creates '
          'a traffic jam.\n\n'
          '• Calls/sec — Platform channel invocations per second. Normal: '
          '<5/sec. Alert: >20/sec or >8ms cumulative duration '
          '(default, configurable).\n\n'
          '• Cumulative duration — Total time on channel calls per window. '
          'High duration means calls are slow, not just frequent.\n\n'
          '• Source: VM Timeline channel events.',
      whyItMatters: 'Each platform channel message has ~0.1ms overhead for '
          'serialization and thread marshaling. At high frequency (100+/sec), '
          'this overhead becomes significant and can contribute to frame '
          'budget pressure. Channel calls also block the UI thread while '
          'awaiting the native response.',
      howToFix: 'Batch multiple values into a single channel call rather than '
          'sending one message per value. For continuous data streams '
          '(sensor data, location updates), use EventChannel with native-side '
          'throttling rather than polling via MethodChannel. Cache native '
          'values on the Dart side to avoid repeated round-trips.',
      whenToIgnore:
          'Brief spikes during initialization (plugin setup, permission '
          'checks) are normal. Concern arises when high traffic persists '
          'during steady-state interaction.',
    ),
  };
}
