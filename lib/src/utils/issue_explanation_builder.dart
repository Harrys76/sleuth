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
  List<String>? relatedIssues,
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

  /// Substitute contextual placeholders in an explanation template against a
  /// concrete issue. Supported placeholders (all optional — missing data is
  /// replaced with a sensible fallback so templates never break):
  ///
  /// - `{widgetName}`   → `issue.widgetName` or `'the widget'`
  /// - `{routeName}`    → `issue.routeDisplayName` (includes `(tab-N)` suffix
  ///                       for tab 2+ visits) or `'the current route'`
  /// - `{severity}`     → `'critical' | 'warning'`
  /// - `{count}`        → the first integer parsed from `issue.title`, or
  ///                       `'several'`. Best-effort — only use in templates
  ///                       where the first integer IS the count semantic.
  /// - `{title}`        → `issue.title`
  /// - `{stableId}`     → `issue.stableId ?? ''`
  ///
  /// Unknown placeholders are left untouched (not replaced with an empty
  /// string) so a typo is visible in-app instead of silently blank.
  static IssueExplanation substitute(
    IssueExplanation template,
    PerformanceIssue issue,
  ) {
    String apply(String text) => _substitutePlaceholders(text, issue);
    return (
      displayName: template.displayName,
      category: template.category,
      whatItIs: apply(template.whatItIs),
      readingTheData: template.readingTheData == null
          ? null
          : apply(template.readingTheData!),
      whyItMatters: apply(template.whyItMatters),
      howToFix: apply(template.howToFix),
      whenToIgnore:
          template.whenToIgnore == null ? null : apply(template.whenToIgnore!),
      relatedIssues: template.relatedIssues,
    );
  }

  static final RegExp _countExtractor = RegExp(r'(\d+)');

  static String _substitutePlaceholders(String text, PerformanceIssue issue) {
    final widgetName = issue.widgetName ?? 'the widget';
    final routeName = issue.routeDisplayName ?? 'the current route';
    final severity =
        issue.severity == IssueSeverity.critical ? 'critical' : 'warning';
    final countMatch = _countExtractor.firstMatch(issue.title);
    final count = countMatch?.group(1) ?? 'several';
    return text
        .replaceAll('{widgetName}', widgetName)
        .replaceAll('{routeName}', routeName)
        .replaceAll('{severity}', severity)
        .replaceAll('{count}', count)
        .replaceAll('{title}', issue.title)
        .replaceAll('{stableId}', issue.stableId ?? '');
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
    IssueCategory.startup,
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
      relatedIssues: [
        'gc_pressure',
        'layout_bottleneck',
        'multiple_custom_fonts',
        'runtime_font_loading',
        'shader_compilation'
      ],
    ),

    'jank_detected': (
      displayName: 'Jank Detected',
      category: IssueCategory.build,
      whatItIs: 'A single frame took longer than its time budget to render. At '
          '60 FPS the budget is 16.7ms — this frame exceeded that threshold. '
          'Unlike sustained jank, this is an isolated spike that may or may '
          'not indicate a systemic problem depending on frequency.',
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
      relatedIssues: [
        'layout_bottleneck',
        'multiple_custom_fonts',
        'runtime_font_loading',
        'shader_compilation',
        'slow_startup_ttff',
      ],
    ),

    'raster_cache_thrashing': (
      displayName: 'Raster Cache Thrashing',
      category: IssueCategory.raster,
      whatItIs: 'The raster cache is rapidly evicting and re-creating entries. '
          'Flutter caches rendered layer images to avoid re-rasterizing them '
          'each frame — thrashing means this cache is not effective and '
          'the GPU must redo work it already completed.',
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
      relatedIssues: ['raster_dominance'],
    ),

    'raster_cache_growing': (
      displayName: 'Raster Cache Growing',
      category: IssueCategory.raster,
      whatItIs:
          'The raster cache is steadily growing in size, meaning more and '
          'more rendered layers are being cached without eviction. This '
          'unbounded growth consumes GPU memory progressively, and if left '
          'unchecked the device may start evicting useful entries or '
          'trigger memory pressure warnings from the operating system.',
      readingTheData:
          'Like a warehouse that keeps accepting deliveries but never ships '
          'anything out — eventually it runs out of floor space.\n\n'
          '• Cache size — Current raster cache in KB. Normal: <500 KB and '
          'stable. Alert: monotonic growth over 30 frames.\n\n'
          '• Growth frames — Consecutive frames with increasing cache size. '
          'Normal: 0 (stable). Alert: 30+ consecutive growth frames.\n\n'
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
      relatedIssues: ['raster_dominance'],
    ),

    // ── Shader & Compute ──────────────────────────────────────────────────

    'shader_compilation': (
      displayName: 'Shader Compilation',
      category: IssueCategory.raster,
      whatItIs:
          'The GPU shader compiler ran during this frame. Shaders are small '
          'GPU programs that Flutter compiles on first use — this compilation '
          'is expensive and blocks the raster thread. On Impeller (default '
          'on iOS since Flutter 3.16), shaders are pre-compiled at build '
          'time, making this detection Skia-specific.',
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
          'warm-up bundle may be incomplete. On Impeller-enabled builds '
          '(iOS default), this detection should not fire — if it does, '
          'verify you are running with Impeller enabled.',
      relatedIssues: ['jank_detected', 'sustained_jank'],
    ),

    'heavy_compute': (
      displayName: 'Heavy Computation',
      category: IssueCategory.build,
      whatItIs: 'A long-running synchronous operation was detected on the UI '
          'thread in {routeName}. The main isolate was blocked for longer '
          'than the frame budget, preventing the framework from building, '
          'laying out, or rendering any widgets until the computation '
          'completes.',
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
          'transformations.\n\n'
          'Before (blocks UI thread):\n'
          '  final data = jsonDecode(hugeJsonString);\n\n'
          'After (runs in background isolate):\n'
          '  final data = await Isolate.run(\n'
          '    () => jsonDecode(hugeJsonString),\n'
          '  );\n\n'
          'Isolate.run() (Dart 2.19+) is the modern API; compute() is a '
          'convenience wrapper with identical behavior. Both require a '
          'top-level or static function — closures capturing local state '
          'will fail at runtime. If the work cannot be moved off-thread, '
          'break it into smaller chunks scheduled across multiple frames.',
      whenToIgnore: null,
      relatedIssues: [
        'large_response',
        'non_lazy_list',
        'platform_channel_traffic',
        'rebuild_activity',
        'setstate_scope',
        'slow_request',
        'slow_startup_ttff',
      ],
    ),

    // ── Memory ────────────────────────────────────────────────────────────

    'gc_pressure': (
      displayName: 'GC Pressure',
      category: IssueCategory.memory,
      whatItIs: 'The garbage collector is running frequently — more often than '
          'expected for normal app operation. Each GC cycle pauses the Dart '
          'isolate briefly to reclaim unused memory, and when collections '
          'happen back-to-back the cumulative pauses become noticeable as '
          'micro-stutters.',
      readingTheData: 'Like a janitor who keeps interrupting a meeting to '
          'empty small trash cans — each visit is brief, but they add up and '
          'break concentration.\n\n'
          '• GC/min — Garbage collection events per minute. '
          'Normal: <10 idle, <20 during interaction. Alert: >30/min.\n\n'
          '• The title number (e.g. "45 GC/min") is the rolling rate over '
          'the monitoring window.\n\n'
          '• Source: VM Timeline GC events.',
      whyItMatters:
          'Frequent GC pauses cause micro-stutters — brief freezes under '
          '5ms that individually seem harmless but accumulate within a '
          'frame\'s budget. Multiple pauses per frame can push total frame '
          'time over budget. GC pressure also indicates high allocation '
          'rate, which itself wastes CPU cycles.',
      howToFix:
          'Reduce object allocation rate: cache objects that are recreated '
          'each frame, use const constructors for immutable widgets, avoid '
          'creating closures or lists inside build(). Migrate static '
          'widgets to const constructors so the framework can reuse them '
          'without allocation:\n\n'
          'Before: Container(color: Colors.blue)\n'
          'After: const ColoredBox(color: Colors.blue)\n\n'
          'Use DevTools Memory tab to identify top allocating classes and '
          'find the allocation hot spots.',
      whenToIgnore:
          'Brief GC spikes during route transitions or initial data loading '
          'are normal. Concern arises when GC stays elevated during steady-state '
          'interaction (scrolling, idle).',
      relatedIssues: [
        'excessive_keep_alive',
        'heap_growing',
        'sustained_jank',
        'uncached_images'
      ],
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
          'released in dispose().\n\n'
          'DevTools snapshot walkthrough:\n'
          '1. Open DevTools Memory tab\n'
          '2. Take a heap snapshot (baseline)\n'
          '3. Perform the user flow that triggers growth\n'
          '4. Take a second snapshot\n'
          '5. Diff the two snapshots — sort by retained size\n\n'
          'Retained size is the total memory freed if the object were '
          'collected (includes everything it references). Shallow size is '
          'just the object itself. A 100-byte object retaining a 10MB '
          'image has 100B shallow but ~10MB retained — retained size '
          'reveals the true leak cost.',
      whenToIgnore:
          'Heap growth during initial app startup or when loading large '
          'datasets is expected. The concern is growth that continues after '
          'the app reaches steady state.',
      relatedIssues: [
        'excessive_keep_alive',
        'gc_pressure',
        'heap_near_capacity',
        'uncached_images'
      ],
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
      relatedIssues: [
        'excessive_keep_alive',
        'heap_growing',
        'native_memory_growing',
        'uncached_images'
      ],
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
      relatedIssues: ['heap_near_capacity', 'uncached_images'],
    ),

    // ── Rebuild & Repaint ─────────────────────────────────────────────────

    'rebuild_activity': (
      displayName: 'Rebuild Activity',
      category: IssueCategory.build,
      whatItIs: '{count} widget rebuilds were detected in a short time window '
          'around {widgetName}. The framework is reconstructing widget '
          'subtrees more frequently than expected for the current '
          'interaction.',
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
          'BlocBuilder/Selector to rebuild only the affected subtree. '
          'Use DevTools Widget Inspector to identify which widgets are '
          'rebuilding and trace the rebuild source.',
      whenToIgnore: 'High rebuild activity during animations is expected — '
          'AnimationController drives 60 rebuilds/sec by design. Focus on '
          'rebuilds during user interactions like typing or scrolling.',
      relatedIssues: [
        'animated_builder_no_child',
        'heavy_compute',
        'high_frequency_same_path',
        'layout_bottleneck',
        'nested_scroll',
        'nested_scroll_same_axis',
        'non_lazy_list',
        'request_frequency',
        'setstate_scope',
        'shallow_rebuild_risk',
        'stateful_density'
      ],
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
      relatedIssues: ['setstate_scope'],
    ),

    'stateful_density': (
      displayName: 'StatefulWidget Density',
      category: IssueCategory.build,
      whatItIs:
          'A high density of StatefulWidgets was found in the widget tree '
          'relative to the total tree size. Each StatefulWidget maintains '
          'its own State object and lifecycle.',
      readingTheData:
          'Like an office where every employee has their own private '
          'assistant — each assistant tracks independent state, and '
          'coordinating them all adds overhead.\n\n'
          '• Density ratio — StatefulWidgets as a percentage of total widgets '
          'in the scanned subtree. Normal: <20%. Alert: >30% '
          '(default, configurable).\n\n'
          '• Stateful count / Total count — Absolute numbers. A ratio of '
          '45/100 is more concerning than 5/15.\n\n'
          '• Source: Structural tree walk.',
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
      relatedIssues: ['rebuild_activity', 'setstate_scope'],
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
          'Add RepaintBoundary widgets to create repaint island boundaries — '
          'each boundary creates an isolated compositing layer that repaints '
          'independently without affecting its parent or siblings. Place '
          'boundaries at natural isolation points: list items, cards, '
          'animated widgets, and toolbar regions.\n\n'
          'Check CustomPainter.shouldRepaint() — return false when the '
          'painter\'s inputs haven\'t changed. Avoid animations that '
          'invalidate large parent regions. Use DevTools Performance '
          'overlay or debugPaintLayerBordersEnabled to visualize layer '
          'boundaries and verify that repaint islands are correctly '
          'isolated.',
      whenToIgnore:
          'Active animations and scroll-driven content are expected to '
          'repaint frequently. Focus on unexpected repaints during idle or '
          'static screens.\n\n'
          'Sleuth v0.15.3+ automatically attributes each paint event to a '
          'known frame-rate animation owner — at paint-callback time it '
          'inspects the live element via three checks: (1) the cached '
          'ancestor chain, (2) a typed ancestor walk up to depth 16, and '
          '(3) a typed descendant walk up to depth 4. The recognised owner '
          'set covers 21 widgets: progress indicators '
          '(CircularProgressIndicator, LinearProgressIndicator, '
          'RefreshProgressIndicator, RefreshIndicator, '
          'CupertinoActivityIndicator), generic builders '
          '(AnimatedBuilder, ValueListenableBuilder, TweenAnimationBuilder), '
          'every Animated* implicit-animation widget '
          '(AnimatedContainer, AnimatedOpacity, AnimatedSwitcher, etc.), '
          'and Hero. Owned paints are subtracted from the aggregate before '
          'the threshold check, so a spinning indicator or active implicit '
          'animation in your app bar will not fire this issue. If you see '
          'this fire near a busy animation that is not in that set, '
          'consider wrapping the animation in a RepaintBoundary to '
          'isolate it.',
      relatedIssues: [
        'always_repaint_painter',
        'animated_builder_no_child',
        'excessive_repaint_boundary',
        'frequent_repaint_painter',
        'missing_repaint_boundary',
        'repaint_debug'
      ],
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
          '• Repaint rate — How many times this render object repainted '
          'per second. Normal: 0–1/sec at idle. Alert: >10/sec.\n\n'
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
          'frame. Sleuth v0.15.3+ skips per-widget repaint reporting when '
          'a per-paint walk attributes the painted element to one of 21 '
          'known animation owners — progress indicators '
          '(CircularProgressIndicator and family), generic builders '
          '(AnimatedBuilder, ValueListenableBuilder, TweenAnimationBuilder), '
          'every Animated* implicit-animation widget, RefreshIndicator, '
          'and Hero. The walk runs against the live element with three '
          'legs (chain regex, typed ancestor walk to depth 16, typed '
          'descendant walk to depth 4), so it catches owners that sit '
          'either above or below the painted leaf in the element tree. '
          'If this issue still fires next to an animation, the owning '
          'widget is probably custom — wrap it in an AnimatedBuilder or '
          'a RepaintBoundary to make the animation explicit.',
      relatedIssues: [
        'excessive_repaint',
        'excessive_repaint_debug',
        'missing_repaint_boundary'
      ],
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
          'render objects. Normal: 0–2/sec at idle. Alert: >10/sec.\n\n'
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
          'expected.\n\n'
          'Sleuth v0.15.3+ subtracts known animation-owned paints from '
          'the aggregate before checking the threshold. If this issue '
          'fires alongside an active animation, the issue detail will '
          'show "Excludes N animation-owned paints" — the residual is '
          'genuinely above threshold even after accounting for the '
          'animation. Look for non-animation paint sources first.',
      relatedIssues: [
        'always_repaint_painter',
        'animated_builder_no_child',
        'missing_repaint_boundary',
        'repaint_debug'
      ],
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
      relatedIssues: [
        'always_repaint_painter',
        'frequent_repaint_painter',
        'missing_repaint_boundary',
        'raster_cache_growing',
        'raster_cache_thrashing'
      ],
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
          'ShaderMask, BackdropFilter). Each saveLayer can add 2–4ms per '
          'frame on mid-range devices.\n\n'
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
      relatedIssues: ['opacity_zero'],
    ),

    // ── setState Scope ────────────────────────────────────────────────────

    'setstate_scope': (
      displayName: 'setState Scope',
      category: IssueCategory.build,
      whatItIs:
          'A StatefulWidget high in the tree is calling setState(), causing '
          'a large subtree to rebuild. The rebuild cost is proportional to '
          'the number of descendant widgets that must be reconstructed.',
      readingTheData:
          'Like a fire alarm that evacuates the entire building when only '
          'one room has smoke — the scope of the response far exceeds the '
          'scope of the problem.\n\n'
          '• Descendant count — Widgets below the setState caller. '
          'Normal: <50. Alert: >200 descendants '
          '(default, configurable).\n\n'
          '• Depth — How far above the leaf widgets the setState caller sits. '
          'Higher depth means wider blast radius.\n\n'
          '• Source: Structural tree walk.',
      whyItMatters: 'When setState is called on a widget near the root, every '
          'descendant\'s build() method runs again — even widgets whose '
          'data hasn\'t changed. This is the most common cause of '
          'unnecessary CPU work in Flutter apps.',
      howToFix: 'Move state down to the smallest widget that needs it. '
          'Extract the changing value into a ValueNotifier and use '
          'ValueListenableBuilder to rebuild only the dependent widget:\n\n'
          'Before (rebuilds entire subtree):\n'
          '  setState(() => _count++);\n\n'
          'After (rebuilds only the Text):\n'
          '  final _count = ValueNotifier(0);\n'
          '  ValueListenableBuilder<int>(\n'
          '    valueListenable: _count,\n'
          '    builder: (_, val, __) => Text("\$val"),\n'
          '  )\n\n'
          'For state management solutions, use Riverpod select(), '
          'BlocSelector, or Provider.select() to rebuild only the '
          'widgets that depend on the changing value. Extract static '
          'portions of the subtree into const widgets that the framework '
          'can skip during diff.',
      whenToIgnore:
          'If the StatefulWidget has a small subtree (< 50 widgets), the '
          'rebuild cost is negligible regardless of scope.',
      relatedIssues: [
        'heavy_compute',
        'layout_bottleneck',
        'rebuild_activity',
        'rebuild_debug',
        'shallow_rebuild_risk',
        'stateful_density'
      ],
    ),

    // ── Shallow Rebuild Risk ──────────────────────────────────────────────

    'shallow_rebuild_risk': (
      displayName: 'Shallow Rebuild Risk',
      category: IssueCategory.build,
      whatItIs: 'A StatefulWidget near the top of the tree was found without '
          'targeted state management. If this widget calls setState(), the '
          'entire deep subtree below it will rebuild.',
      readingTheData:
          'Like a dam with a hairline crack — no flooding yet, but the '
          'potential damage grows with every meter of water behind it.\n\n'
          '• Subtree depth — How deep the tree extends below this widget. '
          'Normal: <100 descendants. Alert: >200 descendants.\n\n'
          '• Risk level — Based on subtree size and absence of targeted '
          'state patterns (no ValueListenableBuilder, BlocBuilder, etc.).\n\n'
          '• Source: Structural tree walk.',
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
      relatedIssues: ['rebuild_activity', 'setstate_scope'],
    ),

    // ── Structural: ListView ──────────────────────────────────────────────

    'non_lazy_list': (
      displayName: 'Non-Lazy List',
      category: IssueCategory.build,
      whatItIs: '{widgetName} was found with {count} children built eagerly '
          'instead of lazily. This means every item in the list is '
          'constructed and laid out immediately, even items far off-screen.',
      readingTheData:
          'Like a restaurant that cooks every menu item before any customer '
          'orders — most of the food goes to waste.\n\n'
          '• Child count — Number of eagerly-built children. Normal: <20. '
          'Alert: >50 children (default, configurable).\n\n'
          '• Widget type — Whether it is a ListView, Column, or Row. '
          'ListView(children: [...]) is the most common offender.\n\n'
          '• Source: Structural tree walk.',
      whyItMatters:
          'Eager list construction wastes memory and CPU. A list with 1,000 '
          'items builds all 1,000 widgets upfront, even though only ~10 are '
          'visible. This causes slow initial render and high memory usage.',
      howToFix: 'Replace ListView(children: [...]) with ListView.builder():\n\n'
          'Before (eager — builds all items):\n'
          '  ListView(children: items.map((i) => ItemTile(i)).toList())\n\n'
          'After (lazy — builds only visible items):\n'
          '  ListView.builder(\n'
          '    itemCount: items.length,\n'
          '    itemBuilder: (_, i) => ItemTile(items[i]),\n'
          '  )\n\n'
          'If all items have the same height, add itemExtent for an extra '
          'performance boost — the framework skips measuring each child '
          'and can jump directly to any scroll offset. For lists with '
          'separators, use ListView.separated(). For grids, use '
          'GridView.builder() or SliverGrid with a delegate.',
      whenToIgnore:
          'Lists with fewer than ~20 small items have negligible eager-build '
          'cost. Static menus and option lists are fine as non-lazy.',
      relatedIssues: [
        'heavy_compute',
        'layout_bottleneck',
        'rebuild_activity',
        'sliver_to_box_adapter_large',
        'sliver_to_box_adapter_shrinkwrap'
      ],
    ),

    // ── Structural: Image Memory ──────────────────────────────────────────

    'uncached_images': (
      displayName: 'Uncached Images',
      category: IssueCategory.memory,
      whatItIs: 'Image widgets were found without cacheWidth or cacheHeight '
          'parameters. The image codec will decode the full-resolution '
          'image into memory, regardless of how small it is displayed.',
      readingTheData:
          'Like printing a billboard-sized poster to hang on a fridge — '
          'the resolution is wasted and the paper costs a fortune.\n\n'
          '• Image count — Number of Image widgets without cacheWidth/'
          'cacheHeight. Alert: ≥1 uncached image.\n\n'
          '• Memory waste estimate — A 4000×3000 image at full resolution '
          'uses ~48MB; at 200×150 display size it needs only ~120KB.\n\n'
          '• Source: Structural tree walk.',
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
          'For CachedNetworkImage, use memCacheWidth/memCacheHeight.\n\n'
          'Alternatively, wrap the ImageProvider with ResizeImage for '
          'provider-level resizing:\n'
          '  Image(image: ResizeImage(NetworkImage(url), width: 400))\n\n'
          'ResizeImage works with any ImageProvider and applies resize '
          'before caching, saving both memory and decode time.',
      whenToIgnore: 'Small images (icons, avatars under 100×100 pixels) have '
          'negligible full-resolution cost. SVG and vector images are '
          'not affected.',
      relatedIssues: [
        'gc_pressure',
        'heap_growing',
        'heap_near_capacity',
        'native_memory_growing'
      ],
    ),

    // ── Structural: GlobalKey ─────────────────────────────────────────────

    'excessive_global_keys': (
      displayName: 'Excessive GlobalKeys',
      category: IssueCategory.build,
      whatItIs: '{count} GlobalKey instances were found inside {widgetName}. '
          'Each GlobalKey maintains a persistent reference to its Element '
          'across the entire app.',
      readingTheData:
          'Like giving every student in a school a master key — each key '
          'grants global access, and managing hundreds of them becomes a '
          'security and logistics nightmare.\n\n'
          '• GlobalKey count — Total GlobalKeys found in the scanned subtree. '
          'Normal: <5. Alert: >10 GlobalKeys '
          '(default, configurable).\n\n'
          '• Location — Whether keys are inside a scrollable (worse) or '
          'at page level (expected).\n\n'
          '• Source: Structural tree walk.',
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
      relatedIssues: ['global_key_recreation'],
    ),

    // ── Structural: Nested Scroll ─────────────────────────────────────────

    'nested_scroll': (
      displayName: 'Nested Scrollables',
      category: IssueCategory.build,
      whatItIs:
          '{widgetName} was found nested inside another scrollable widget. '
          'The inner scroll view receives gesture events that the outer '
          'one also wants to handle.',
      readingTheData:
          'Like putting a treadmill on a moving sidewalk — both are '
          'trying to control your direction, and the result is '
          'unpredictable.\n\n'
          '• Nesting depth — Number of scrollable ancestors. Normal: 1 '
          '(single scroll). Alert: ≥2 nested scrollables.\n\n'
          '• Axis relationship — Same-axis (both vertical) is worse than '
          'cross-axis (horizontal inside vertical).\n\n'
          '• Source: Structural tree walk.',
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
      relatedIssues: ['layout_bottleneck', 'rebuild_activity'],
    ),

    'nested_scroll_same_axis': (
      displayName: 'Same-Axis Nested Scroll',
      category: IssueCategory.build,
      whatItIs:
          'Two scrollable widgets with the same scroll axis (both vertical '
          'or both horizontal) are nested. This is a stronger signal than '
          'general nested scrolling because same-axis nesting almost always '
          'indicates a structural problem.',
      readingTheData:
          'Like two escalators stacked vertically where both try to carry '
          'you in the same direction — the inner one fights the outer one '
          'for control.\n\n'
          '• Inner list type — The nested scrollable widget (ListView, '
          'SingleChildScrollView, GridView). ShrinkWrap is often forced.\n\n'
          '• Axis — Both scrollables share the same axis (vertical/vertical '
          'or horizontal/horizontal). Alert: any same-axis nesting.\n\n'
          '• Source: Structural tree walk.',
      whyItMatters:
          'Same-axis nested scrollables cause: (1) the inner list builds '
          'all children eagerly (ShrinkWrap), defeating lazy construction, '
          '(2) confusing scroll physics where the user can\'t tell which '
          'list is scrolling, and (3) potential infinite height constraint '
          'errors.',
      howToFix: 'Migrate to CustomScrollView with Slivers:\n\n'
          'Before (nested same-axis):\n'
          '  ListView(children: [\n'
          '    Header(),\n'
          '    ListView(shrinkWrap: true, children: items),\n'
          '  ])\n\n'
          'After (flat slivers):\n'
          '  CustomScrollView(slivers: [\n'
          '    SliverToBoxAdapter(child: Header()),\n'
          '    SliverList.builder(\n'
          '      itemCount: items.length,\n'
          '      itemBuilder: (_, i) => items[i],\n'
          '    ),\n'
          '  ])\n\n'
          'If the inner list must remain a separate widget, add '
          'NeverScrollableScrollPhysics() to disable its independent '
          'scrolling and let the outer controller drive it.',
      whenToIgnore: null,
      relatedIssues: [
        'layout_bottleneck',
        'rebuild_activity',
        'sliver_fill_remaining_scrollable'
      ],
    ),

    // ── Structural: Opacity ───────────────────────────────────────────────

    'opacity_zero': (
      displayName: 'Opacity Zero',
      category: IssueCategory.layout,
      whatItIs:
          'An Opacity or AnimatedOpacity widget with value 0.0 was found. '
          'Despite being fully invisible, the child widget is still built, '
          'laid out, painted, hit-tested, and included in the semantics tree.',
      readingTheData:
          'Like paying a full-time employee to sit in an office with the '
          'lights off — they are doing all the work but producing no '
          'visible output.\n\n'
          '• Opacity value — The literal opacity. Alert: exactly 0.0.\n\n'
          '• Child subtree cost — Descendant count below the Opacity widget. '
          'Larger subtrees waste more resources when invisible. Normal '
          'waste: 0 widgets. Alert: any subtree at opacity 0.0.\n\n'
          '• Source: Structural tree walk.',
      whyItMatters:
          'An invisible Opacity widget wastes all four pipeline phases '
          '(build, layout, paint, raster) plus allocates a saveLayer GPU '
          'buffer. It also confuses screen readers, which announce invisible '
          'content to accessibility users.',
      howToFix: 'Replace Opacity(opacity: 0.0) with Visibility(visible: false) '
          'to skip paint and hit-testing. Visibility provides granular '
          'control via flags:\n\n'
          '• maintainSize: true — keeps the widget\'s space in layout '
          '(like CSS visibility: hidden). false collapses the space.\n'
          '• maintainState: true — keeps the State object alive so it '
          'resumes where it left off when made visible again.\n'
          '• maintainAnimation: true — keeps animations ticking while '
          'invisible so they are at the correct frame when revealed.\n\n'
          'For animated show/hide, use AnimatedSwitcher or FadeTransition '
          'which can remove the child entirely when opacity reaches zero.',
      whenToIgnore:
          'Mid-animation opacity values near 0 are expected during fade '
          'transitions. This detection targets static 0.0 values only.',
      relatedIssues: ['expensive_gpu_nodes'],
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
      readingTheData:
          'Like measuring a room twice before placing each piece of '
          'furniture — the extra measurement pass doubles the work.\n\n'
          '• Nesting depth — IntrinsicHeight/Width nesting levels. Cost is '
          'O(2^N) for N levels. Normal: 1 level. Alert: ≥2 nested levels.\n\n'
          '• Subtree size — Descendants under the intrinsic widget. Larger '
          'subtrees amplify the two-pass cost. Alert: >50 descendants.\n\n'
          '• Source: Structural tree walk.',
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
      relatedIssues: [
        'jank_detected',
        'nested_scroll',
        'nested_scroll_same_axis',
        'non_lazy_list',
        'rebuild_activity',
        'setstate_scope',
        'sustained_jank',
        'wrap_layout_bottleneck'
      ],
    ),

    // ── Structural: CustomPainter ─────────────────────────────────────────

    'always_repaint_painter': (
      displayName: 'Always-Repaint Painter',
      category: IssueCategory.paint,
      whatItIs:
          'A CustomPainter was found whose shouldRepaint() always returns '
          'true. This forces the framework to repaint this widget every '
          'single frame, regardless of whether its visual state changed.',
      readingTheData:
          'Like a security camera that records 24/7 even when nothing is '
          'moving — it fills up storage with identical frames.\n\n'
          '• shouldRepaint — Always returns true. Normal: returns false '
          'when inputs unchanged. Alert: unconditional true.\n\n'
          '• Paint complexity — Number of drawing operations in the '
          'painter. More operations means more wasted GPU work per '
          'unnecessary repaint. Alert: any always-repaint painter.\n\n'
          '• Source: Structural tree walk.',
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
      relatedIssues: [
        'excessive_repaint',
        'excessive_repaint_debug',
        'raster_dominance'
      ],
    ),

    'frequent_repaint_painter': (
      displayName: 'Frequent Repaint Painter',
      category: IssueCategory.paint,
      whatItIs: 'A CustomPainter is repainting at a high frequency. While '
          'shouldRepaint() may be implemented, it is returning true too '
          'often — the painter\'s inputs are changing rapidly.',
      readingTheData:
          'Like a painter who checks their work every 5 seconds and touches '
          'up something each time — the constant small changes add up to '
          'significant effort.\n\n'
          '• Repaint rate — How often shouldRepaint returns true. Normal: '
          '<10/sec. Alert: >30/sec (default, configurable).\n\n'
          '• Input change rate — How rapidly the painter\'s Listenable or '
          'fields change. Fast-changing inputs drive high repaint rate.\n\n'
          '• Source: Structural tree walk.',
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
      relatedIssues: ['excessive_repaint', 'raster_dominance'],
    ),

    // ── Structural: Keep Alive ────────────────────────────────────────────

    'excessive_keep_alive': (
      displayName: 'Excessive KeepAlive',
      category: IssueCategory.memory,
      whatItIs: '{count} pages or tab contents are using '
          'AutomaticKeepAliveClientMixin to stay alive when scrolled '
          'off-screen or when tabs switch. Each kept-alive subtree '
          'remains in memory with its full State.',
      readingTheData:
          'Like keeping every room in a hotel fully lit and heated even '
          'when only 2 of 20 rooms have guests — the energy bill grows '
          'with every empty room kept "ready."\n\n'
          '• KeepAlive count — Number of kept-alive tabs or pages. '
          'Normal: 2–3. Alert: >5 kept-alive subtrees '
          '(default, configurable).\n\n'
          '• Memory per subtree — Each kept-alive page retains its full '
          'widget/element tree, controllers, and cached data.\n\n'
          '• Source: Structural tree walk.',
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
      relatedIssues: ['gc_pressure', 'heap_growing', 'heap_near_capacity'],
    ),

    // ── Structural: AnimatedBuilder ───────────────────────────────────────

    'animated_builder_no_child': (
      displayName: 'AnimatedBuilder Without Child',
      category: IssueCategory.build,
      whatItIs: '{widgetName} was found without using the child parameter. '
          'The entire subtree inside the builder callback is rebuilt on '
          'every animation tick (60x/sec).',
      readingTheData:
          'Like reprinting an entire newspaper every hour just to update '
          'the clock in the corner — 99% of the content is unchanged.\n\n'
          '• Subtree size — Descendants rebuilt on every animation tick. '
          'Normal: 0 (child parameter used). Alert: >5 descendants '
          'rebuilt per tick without child.\n\n'
          '• Animation rate — Typically 60 ticks/sec, meaning the subtree '
          'rebuilds 60 times per second.\n\n'
          '• Source: Structural tree walk.',
      whyItMatters:
          'Without the child optimization, every animation frame rebuilds '
          'the entire widget subtree inside the builder — even static '
          'content that doesn\'t depend on the animation value. For complex '
          'subtrees, this creates 60 expensive rebuilds per second.',
      howToFix: 'Pass static widgets via the child parameter. The framework '
          'builds the child widget once, caches the resulting Element '
          'subtree, and passes the pre-built widget to the builder '
          'callback on every animation tick. Because the same widget '
          'instance is reused, the framework skips the diff and rebuild '
          'for that entire subtree — only the wrapping transform/opacity/'
          'alignment is updated each frame:\n\n'
          'AnimatedBuilder(\n'
          '  animation: controller,\n'
          '  child: const ExpensiveChild(), // built once, cached\n'
          '  builder: (context, child) => Transform.rotate(\n'
          '    angle: controller.value,\n'
          '    child: child, // reused each frame — no rebuild\n'
          '  ),\n'
          ')',
      whenToIgnore:
          'If the entire subtree truly depends on the animation value '
          '(e.g., a canvas that redraws based on progress), the child '
          'parameter provides no benefit.',
      relatedIssues: [
        'excessive_repaint',
        'excessive_repaint_debug',
        'rebuild_activity'
      ],
    ),

    // ── Structural: Font Loading ──────────────────────────────────────────

    'multiple_custom_fonts': (
      displayName: 'Multiple Custom Fonts',
      category: IssueCategory.font,
      whatItIs:
          'Multiple custom (non-system) fonts are in use. Custom fonts must '
          'be loaded from assets or network before they can render — until '
          'loaded, Flutter shows invisible text (FOIT) or a fallback font.',
      readingTheData:
          'Like a printing press that needs a different set of metal type '
          'for each language — loading and switching between sets takes '
          'time and storage.\n\n'
          '• Font family count — Distinct custom font families detected. '
          'Normal: 1–2. Alert: ≥3 custom font families.\n\n'
          '• Bundle size impact — Each font file is typically 50–500KB. '
          'Multiple weights multiply the cost.\n\n'
          '• Source: Structural tree walk.',
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
      relatedIssues: ['jank_detected', 'sustained_jank'],
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
      readingTheData: 'Like a paint spill with no containment — without a tarp '
          '(boundary), the spill spreads across the entire floor.\n\n'
          '• Expensive widget type — The GPU-heavy widget missing a boundary '
          '(CustomPainter, BackdropFilter, ShaderMask). Alert: any '
          'expensive widget without a nearby RepaintBoundary.\n\n'
          '• Propagation distance — How far repaints travel up the tree '
          'before hitting an existing boundary. Farther = more wasted work.\n\n'
          '• Source: Structural tree walk.',
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
          'repaint.\n\n'
          'When NOT to add a RepaintBoundary: each boundary allocates a '
          'GPU-backed layer (~100KB+ memory). Adding boundaries around '
          'static content that rarely repaints wastes GPU memory with no '
          'benefit. Verify with debugPaintLayerBordersEnabled before and '
          'after to confirm the boundary actually reduces repaint area.',
      whenToIgnore:
          'If the expensive widget already repaints rarely (static content) '
          'or if the parent boundary is already small, adding another '
          'RepaintBoundary adds layer overhead without benefit.',
      relatedIssues: [
        'excessive_repaint',
        'excessive_repaint_boundary',
        'excessive_repaint_debug',
        'raster_dominance',
        'repaint_debug'
      ],
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
      relatedIssues: ['heavy_compute'],
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
      relatedIssues: ['heavy_compute'],
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
      relatedIssues: ['http_error_spike', 'rebuild_activity'],
    ),

    'http_error_spike': (
      displayName: 'HTTP Error Spike',
      category: IssueCategory.network,
      whatItIs:
          'Multiple HTTP requests failed (4xx/5xx status codes) or could not '
          'connect (transport failures) within a 5-second window. This '
          'suggests backend issues, network problems, or retry storms.',
      readingTheData:
          'Like a delivery truck that keeps returning to the warehouse '
          'because the address is wrong — each failed trip wastes fuel and '
          'time.\n\n'
          '• Error count — HTTP responses with status ≥400 or connection '
          'failures (status -1) in a 5-second window. Alert: ≥3 errors.\n\n'
          '• Transport failures — Requests that never received a response '
          '(DNS failure, timeout, connection refused). These are worse than '
          '4xx/5xx because there is no server-side processing.\n\n'
          '• Server errors (5xx) — The server received the request but '
          'failed to process it. Often transient and retriable.\n\n'
          '• Source: HTTP client instrumentation.',
      whyItMatters:
          'Failed requests that trigger automatic retries can create retry '
          'storms — exponentially increasing network traffic that wastes '
          'battery, bandwidth, and CPU time. Each retry attempt also blocks '
          'the HTTP client connection pool, potentially delaying legitimate '
          'requests. On metered connections, this wastes user data.',
      howToFix:
          'Add exponential backoff with jitter to retry logic — never retry '
          'immediately or at fixed intervals. Implement a circuit breaker '
          'that stops retrying after N consecutive failures and checks again '
          'after a cooldown period. Cache successful responses so the app '
          'can serve stale data during outages. For transport failures, '
          'check connectivity before retrying.',
      whenToIgnore:
          'A brief spike during network transitions (WiFi → cellular) is '
          'expected. Single 4xx errors from user input (404 from a bad URL, '
          '401 from expired auth) are not concerning on their own.',
      relatedIssues: ['request_frequency'],
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
          'values on the Dart side to avoid repeated round-trips.\n\n'
          'For any non-trivial channel usage, use Pigeon (code-gen) to '
          'generate type-safe Dart + Kotlin/Swift bindings. Pigeon '
          'eliminates stringly-typed method names that cause silent '
          'failures when either side renames a method.',
      whenToIgnore:
          'Brief spikes during initialization (plugin setup, permission '
          'checks) are normal. Concern arises when high traffic persists '
          'during steady-state interaction.',
      relatedIssues: ['heavy_compute'],
    ),

    // ── v11.20: Missing entries ──────────────────────────────────────────

    'high_frequency_same_path': (
      displayName: 'High-Frequency Same-Path Requests',
      category: IssueCategory.network,
      whatItIs:
          'Three or more requests were issued to the same endpoint within '
          '500 ms. Sleuth groups records by HTTP method and normalized URL '
          '(query strings stripped) so that search-typeahead traffic and '
          'pagination bursts cluster under a single finding. Only idempotent '
          'methods (GET, HEAD, OPTIONS) are considered — POST/PUT/PATCH '
          'bursts are intentionally ignored because they frequently carry '
          'different payloads to the same URL.',
      readingTheData:
          'Like hitting a doorbell three times in a second because the bell '
          'didn\'t ring quickly enough — the server side did the same work '
          'three times, and the network paid for it.\n\n'
          '• Count — Number of requests that clustered within the 500 ms '
          'window. Normal: 1–2. Alert: ≥3. Critical: ≥5.\n\n'
          '• Fingerprint — Method + normalized URL hash identifying the '
          'cluster. All requests in the cluster share this fingerprint, so '
          'the issue is stable across scans.\n\n'
          '• Source: HTTP client instrumentation (startedAt timestamps).',
      whyItMatters:
          'High-frequency same-path traffic wastes bandwidth, battery, and '
          'server resources. It also amplifies rebuilds — if each response '
          'triggers setState, the widget rebuilds N times with nearly '
          'identical data. On metered connections this directly costs the '
          'user money. Common root causes are un-debounced typeahead / '
          'search input, rebuild-triggered fetches in build() or '
          'didChangeDependencies() without a guard, double-tap pull-to-'
          'refresh, and pagination that re-requests the same page during '
          'fast scroll.',
      howToFix:
          'Pick the fix that matches the root cause: debounce user-driven '
          'input (300 ms Timer or rxdart throttleTime), cache responses so '
          'subsequent callers get the cached result, share a single Future '
          'across widgets (FutureProvider / AsyncNotifier), or deduplicate '
          'at the repository layer with an in-flight request map keyed by '
          'fingerprint.',
      whenToIgnore:
          'Legitimate bursts exist — analytics beacons, poll loops intended '
          'to run at high frequency, or a streaming replacement that falls '
          'back to short-interval polling. In those cases suppress the issue '
          'via `SleuthConfig.ignoredStableIds`. The detector already '
          'excludes POST/PUT/PATCH so non-idempotent writes are never '
          'flagged.',
      relatedIssues: ['rebuild_activity'],
    ),

    'wrap_layout_bottleneck': (
      displayName: 'Wrap Layout Bottleneck',
      category: IssueCategory.layout,
      whatItIs: 'A Wrap widget was found with a large number of children. Wrap '
          'performs O(N) layout passes to flow-position each child, measuring '
          'every child to determine line breaks.',
      readingTheData:
          'Like a shelf stocker who must try every item in every slot to '
          'find the best arrangement — more items means exponentially more '
          'trial placements.\n\n'
          '• Child count — Number of children in the Wrap. Normal: <30. '
          'Alert: >50 children (default, configurable).\n\n'
          '• Layout cost — Each child is measured and positioned sequentially; '
          'no lazy skipping of off-screen items.\n\n'
          '• Source: Structural tree walk.',
      whyItMatters:
          'Wrap layout cost scales linearly with child count, but unlike '
          'ListView it cannot lazily skip off-screen children. A Wrap with '
          '100+ children lays out all of them every frame, even those '
          'scrolled out of view, making it a hidden layout bottleneck.',
      howToFix: 'For large collections of chips, tags, or badges, consider a '
          'lazy alternative: place items in a ListView with rows computed '
          'manually, or use a flow-layout package that supports lazy '
          'rendering. For static content, ensure the Wrap is wrapped in a '
          'RepaintBoundary so layout cost does not propagate upward.',
      whenToIgnore:
          'Wrap widgets with fewer than ~30 small children (chips, icons) '
          'have negligible layout cost and are fine as-is.',
      relatedIssues: ['layout_bottleneck'],
    ),

    'sliver_to_box_adapter_large': (
      displayName: 'Large SliverToBoxAdapter',
      category: IssueCategory.build,
      whatItIs:
          'A SliverToBoxAdapter wrapping a large subtree was found inside a '
          'CustomScrollView. SliverToBoxAdapter converts a box widget into a '
          'sliver, but it builds the entire subtree eagerly — no lazy '
          'construction.',
      readingTheData:
          'Like stuffing an entire filing cabinet into a single folder — '
          'the folder system was designed for quick access, but one '
          'giant folder defeats the purpose.\n\n'
          '• Descendant count — Widgets inside the SliverToBoxAdapter. '
          'Normal: <50. Alert: >100 descendants.\n\n'
          '• Lazy alternative — SliverList.builder would lazily construct '
          'only visible items instead of all descendants.\n\n'
          '• Source: Structural tree walk.',
      whyItMatters: 'Unlike SliverList which lazily builds only visible items, '
          'SliverToBoxAdapter builds its entire child subtree upfront. A '
          'large subtree (100+ descendants) defeats the purpose of using '
          'slivers for lazy rendering, causing slow initial build and '
          'high memory usage.',
      howToFix: 'If the content is a list of items, replace SliverToBoxAdapter('
          'child: Column(children: items)) with SliverList.builder() for '
          'lazy construction. If it is a single large widget, consider '
          'breaking it into multiple smaller slivers so only visible '
          'portions are built.',
      whenToIgnore:
          'SliverToBoxAdapter wrapping a small, fixed-size widget (header, '
          'footer, banner) is the intended use case and is perfectly fine.',
      relatedIssues: ['non_lazy_list'],
    ),

    'sliver_fill_remaining_scrollable': (
      displayName: 'SliverFillRemaining Scrollable',
      category: IssueCategory.build,
      whatItIs: 'A SliverFillRemaining was found containing a scrollable child '
          '(ListView, SingleChildScrollView, etc.). SliverFillRemaining '
          'sizes its child to fill the remaining viewport space, creating '
          'a nested scroll conflict.',
      readingTheData:
          'Like two steering wheels in one car — both can turn, but the '
          'driver never knows which one is in control.\n\n'
          '• Inner scrollable type — The scrollable widget inside '
          'SliverFillRemaining (ListView, SingleChildScrollView, etc.).\n\n'
          '• hasScrollBody — Whether the sliver expects a scrollable child. '
          'Alert: scrollable child present regardless of flag setting.\n\n'
          '• Source: Structural tree walk.',
      whyItMatters:
          'A scrollable inside SliverFillRemaining creates competing scroll '
          'physics — the inner scrollable fights with the outer '
          'CustomScrollView for gesture ownership. Users experience '
          'unpredictable scroll behavior where sometimes the inner list '
          'scrolls and sometimes the outer one does.',
      howToFix: 'Replace SliverFillRemaining(child: ListView(...)) with a '
          'SliverList that directly contains the items. If you need the '
          '"fill remaining space" behavior, use SliverFillRemaining with '
          'hasScrollBody: false for non-scrollable content, or restructure '
          'so the inner content participates in the outer scroll via slivers.',
      whenToIgnore:
          'SliverFillRemaining with hasScrollBody: true is intentional '
          'when you want the inner scrollable to take over scrolling after '
          'outer slivers are fully scrolled.',
      relatedIssues: ['nested_scroll_same_axis'],
    ),

    'sliver_to_box_adapter_shrinkwrap': (
      displayName: 'ShrinkWrap Inside Sliver',
      category: IssueCategory.build,
      whatItIs:
          'A ListView or GridView with shrinkWrap: true was found inside a '
          'SliverToBoxAdapter. ShrinkWrap forces the list to measure all '
          'children to determine its own size, eliminating lazy construction.',
      readingTheData:
          'Like using a tape measure on every book to figure out the shelf '
          'height — instead of just stacking books as they fit.\n\n'
          '• Child count — Items in the shrinkWrapped list. Normal: <10. '
          'Alert: >20 items with shrinkWrap inside a sliver.\n\n'
          '• Build cost — All children are built and measured upfront, '
          'defeating the lazy rendering that slivers are designed for.\n\n'
          '• Source: Structural tree walk.',
      whyItMatters:
          'shrinkWrap: true builds and measures every child to compute the '
          'list\'s total height. Inside a sliver context this is doubly '
          'wasteful — you chose slivers for lazy rendering but shrinkWrap '
          'defeats it. A 500-item shrinkWrapped list builds all 500 items.',
      howToFix: 'Replace SliverToBoxAdapter(child: ListView(shrinkWrap: true, '
          'children: items)) with SliverList.builder(itemBuilder: ..., '
          'itemCount: items.length). This gives true lazy construction '
          'within the CustomScrollView\'s viewport. If the items have a '
          'known fixed height, add itemExtent for an additional performance '
          'boost — the framework can skip child measurement entirely and '
          'jump directly to any scroll offset.',
      whenToIgnore:
          'Very small lists (< 10 items) with fixed-height items have '
          'negligible shrinkWrap cost.',
      relatedIssues: ['non_lazy_list'],
    ),

    'global_key_recreation': (
      displayName: 'GlobalKey Recreation',
      category: IssueCategory.build,
      whatItIs: 'A GlobalKey is being created inside a build() method or other '
          'frequently-called code path. Each call creates a new GlobalKey '
          'instance, which unregisters the old key and re-registers the '
          'new one in the global registry.',
      readingTheData:
          'Like giving someone a new passport every time they cross a '
          'border — the old one is invalidated, the new one must be '
          'registered, and their travel history is lost.\n\n'
          '• Recreation frequency — How often the GlobalKey is recreated. '
          'Normal: 0 (created once). Alert: any recreation detected.\n\n'
          '• State loss — Each recreation destroys the associated State '
          'object, losing scroll position, form input, and animation '
          'progress.\n\n'
          '• Source: Structural tree walk.',
      whyItMatters:
          'GlobalKey recreation forces the framework to detach and reattach '
          'the Element on every rebuild, destroying all State (including '
          'scroll position, animation progress, and form input). It also '
          'triggers a full subtree rebuild rather than a diff-based update, '
          'and can cause "Multiple widgets used the same GlobalKey" errors.',
      howToFix:
          'Move GlobalKey creation to a final instance field on the State '
          'class or to initState(). Never create GlobalKeys inside build(), '
          'loops, or callbacks that run more than once:\n'
          '// Bad: recreated every build\n'
          'Widget build(context) {\n'
          '  final key = GlobalKey(); // new key each frame!\n'
          '  ...\n'
          '}\n'
          '// Good: created once\n'
          'final _formKey = GlobalKey<FormState>();',
      whenToIgnore: null,
      relatedIssues: ['excessive_global_keys'],
    ),

    'excessive_repaint_boundary': (
      displayName: 'Excessive RepaintBoundary',
      category: IssueCategory.paint,
      whatItIs:
          'Too many RepaintBoundary widgets were found in close proximity. '
          'Each RepaintBoundary creates a separate compositing layer that '
          'the GPU must manage independently.',
      readingTheData:
          'Like dividing a house into 50 separate climate zones — each '
          'zone needs its own thermostat and ductwork, and the overhead '
          'of managing them all exceeds the energy savings.\n\n'
          '• Boundary count — RepaintBoundary widgets in the visible region. '
          'Normal: <15. Alert: >20 boundaries in proximity.\n\n'
          '• GPU layer cost — Each boundary creates a compositing layer '
          'that consumes GPU memory (~100KB+ per layer).\n\n'
          '• Source: Structural tree walk.',
      whyItMatters:
          'Each RepaintBoundary allocates a GPU-backed compositing layer. '
          'Too many layers increase GPU memory usage and compositing cost — '
          'the raster thread must composite all layers each frame. Beyond '
          '~15-20 boundaries in a visible region, the overhead of managing '
          'layers can exceed the savings from isolated repainting.',
      howToFix:
          'Audit RepaintBoundary placement: keep them at natural isolation '
          'points (list items, cards, animated regions) rather than wrapping '
          'every widget. Remove boundaries around static content that rarely '
          'or never repaints — they add layer overhead with no benefit. Use '
          'debugPaintLayerBordersEnabled to visualize layer boundaries and '
          'identify excessive layering.',
      whenToIgnore:
          'Scrollable list items automatically get RepaintBoundary from '
          'the framework — these are expected and beneficial.',
      relatedIssues: ['excessive_repaint', 'missing_repaint_boundary'],
    ),

    'runtime_font_loading': (
      displayName: 'Runtime Font Loading',
      category: IssueCategory.font,
      whatItIs: 'A custom font is being loaded at runtime (via FontLoader or '
          'network) rather than being bundled in the app assets. The font '
          'is unavailable until the download and parsing completes.',
      readingTheData:
          'Like a sign painter who only starts painting the shop sign '
          'after the grand opening — customers see a blank storefront '
          'until the work is done.\n\n'
          '• Load time — Duration from font request to availability. '
          'Normal: 0ms (bundled). Alert: >0ms (runtime loading detected).\n\n'
          '• Font file size — Typically 50–500KB per font file. Larger '
          'files take longer to download on slow connections.\n\n'
          '• Source: Structural tree walk.',
      whyItMatters:
          'Runtime font loading causes Flash of Invisible Text (FOIT) or '
          'Flash of Unstyled Text (FOUT) — text using the font is either '
          'invisible or rendered in a fallback font until loading completes. '
          'On slow networks this can last several seconds, creating a '
          'jarring visual experience. Each font file is typically 50–500KB.',
      howToFix: 'Bundle fonts in the app assets via pubspec.yaml rather than '
          'loading them at runtime. If runtime loading is required (e.g., '
          'user-selected fonts), preload fonts during a splash screen or '
          'loading state before navigating to content that uses them. Use '
          'FontLoader.load() in an initialization step and show a fallback '
          'font with a smooth transition when the custom font becomes '
          'available.',
      whenToIgnore:
          'Apps that support user-customizable fonts (e.g., e-readers, '
          'design tools) need runtime loading by design. The concern is '
          'unexpected runtime loading of fonts that could be bundled.',
      relatedIssues: ['jank_detected', 'sustained_jank'],
    ),

    // ── Startup ────────────────────────────────────────────────────────

    'slow_startup_ttff': (
      displayName: 'Slow Startup (TTFF)',
      category: IssueCategory.startup,
      whatItIs: 'The time from Dart entry point (Sleuth.init()) to the first '
          'frame raster completion exceeds the configured threshold. This is '
          'the cold-start Time-to-First-Frame (TTFF) — how long the user '
          'stares at a splash screen or blank canvas before seeing content.',
      readingTheData:
          'Like measuring how long a restaurant takes from unlocking the '
          'door to seating the first customer — every step from lights-on '
          'to table-ready adds up.\n\n'
          '• TTFF — Wall-clock duration from Sleuth.init() to the first '
          'FrameTiming raster-end timestamp. Normal: <1500ms. Warning: '
          '1500–3000ms. Critical: >3000ms.\n\n'
          '• First frame breakdown — Vsync overhead, build phase, and raster '
          'phase durations from FrameTiming. The dominant phase indicates '
          'where optimization effort should focus.\n\n'
          '• VM sub-phases — When VM timeline is connected, buildScope, '
          'flushLayout, flushPaint, and raster sub-durations provide deeper '
          'insight into the first frame pipeline.\n\n'
          '• Measurement window — ttffMs starts at Sleuth.init() (Dart '
          'entry), not at process start. The native pre-Dart phase before '
          'Sleuth.init() is deliberately excluded: iOS cold start adds '
          '~400–1200ms (dyld, UIApplicationMain, FlutterEngine, VM '
          'bootstrap); Android cold start adds ~300–900ms on mid-range '
          'devices and >1500ms on budget / Android Go (Zygote fork, '
          'Application.onCreate, ContentProvider init, FlutterActivity, '
          'FlutterEngine, VM bootstrap).\n\n'
          '• Compared to `flutter run --trace-startup` — `--trace-startup` '
          'measures from engine C++ entry, so its numbers are larger than '
          'ttffMs by the pre-Dart overhead. For the apples-to-apples '
          'value read StartupMetrics.engineTtffMs (engine → first frame '
          'rasterized); for the native-phase gap alone read '
          'StartupMetrics.preDartOverheadMs. Both populate when VM '
          'timeline enrichment runs before the ring buffer evicts the '
          'FlutterEngineMainEnter event.\n\n'
          '• Source: SchedulerBinding.addTimingsCallback (one-shot).',
      whyItMatters: 'Mobile users expect apps to launch in under 2 seconds. '
          'A 3+ second cold start is a retention risk — studies show 25% of '
          'users abandon apps that take more than 3 seconds to load. The '
          'first frame is also when the system decides whether to show an '
          'ANR dialog (Android) or terminate the app (iOS watchdog).',
      howToFix: 'Optimize based on the dominant phase:\n\n'
          'Build-dominant: Reduce initial widget tree complexity. Defer '
          'below-fold content with FutureBuilder or lazy initialization. '
          'Move expensive init logic (database setup, large JSON parsing) '
          'to background isolates.\n\n'
          'Raster-dominant: Reduce first-frame painting complexity. Pre-cache '
          'large images with precacheImage() in a splash screen. Avoid '
          'shader-heavy effects (blur, gradient) on the initial route.\n\n'
          'Vsync-dominant: Minimize synchronous work before runApp(). Defer '
          'non-critical plugin initialization to post-first-frame callbacks '
          'using WidgetsBinding.instance.addPostFrameCallback.',
      whenToIgnore: 'Debug mode cold starts are 3–10x slower than profile '
          'mode due to JIT compilation, asserts, and debug checks. Always '
          'measure in profile mode (flutter run --profile). Warm restarts '
          '(hot restart) are also misleading — the VM is already initialized.',
      relatedIssues: [
        'jank_detected',
        'heavy_compute',
      ],
    ),
  };
}
