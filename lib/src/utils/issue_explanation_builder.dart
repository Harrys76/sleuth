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

/// Provides an explanation for each issue type.
///
/// Each explanation tells developers what a detection means, why it matters
/// for performance, how to fix it beyond the brief hint, and when it may be a
/// false positive they can ignore.
///
/// Keyed by [PerformanceIssue.stableId]. Lookups strip dynamic suffixes (such
/// as `excessive_keep_alive:PageView~1` or `rebuild_debug_MyWidget`) to match
/// the base explanation.
class IssueExplanationBuilder {
  IssueExplanationBuilder._();

  /// Returns a structured explanation for the given [stableId], or `null` if
  /// no explanation exists (for example, for custom detector issues).
  static IssueExplanation? explain(String? stableId) {
    if (stableId == null) return null;
    return _explanations[_baseId(stableId)];
  }

  /// Substitute contextual placeholders in an explanation template against a
  /// concrete issue. Every placeholder is optional. Missing data falls back
  /// to a default, so templates never break:
  ///
  /// - `{widgetName}`: `issue.widgetName` or `'the widget'`
  /// - `{routeName}`: `issue.routeDisplayName` (with the `(tab-N)` suffix
  ///   for visits to tab 2 and later) or `'the current route'`
  /// - `{severity}`: `'critical'` or `'warning'`
  /// - `{count}`: the first integer parsed from `issue.title`, or
  ///   `'several'`. This is best effort, so use it only in templates where
  ///   the first integer in the title is the count.
  /// - `{title}`: `issue.title`
  /// - `{stableId}`: `issue.stableId ?? ''`
  ///
  /// Unknown placeholders are left untouched (not replaced with an empty
  /// string) so a typo is visible in-app instead of silently blank.
  static IssueExplanation substitute(
    IssueExplanation template,
    PerformanceIssue issue,
  ) {
    final countMatch = _countExtractor.firstMatch(issue.title);
    return _applyReplacements(template, {
      '{widgetName}': issue.widgetName ?? 'the widget',
      '{routeName}': issue.routeDisplayName ?? 'the current route',
      '{severity}': issue.severity == IssueSeverity.critical
          ? 'critical'
          : 'warning',
      '{count}': countMatch?.group(1) ?? 'several',
      '{title}': issue.title,
      '{stableId}': issue.stableId ?? '',
    });
  }

  /// Substitute placeholders with neutral wording when no concrete issue is
  /// available (encyclopedia-wide payloads, explanations requested by id):
  ///
  /// - `{widgetName}`: `'the widget'`
  /// - `{routeName}`: `'the current route'`
  /// - `{count}`: `'N'`
  /// - `{severity}`: `'this'`
  /// - `{title}`: the entry's `displayName`
  /// - `{stableId}`: the entry's canonical key, or `''` if the template is
  ///   not a registered entry
  static IssueExplanation substituteNeutral(IssueExplanation template) {
    var key = '';
    for (final entry in _explanations.entries) {
      if (identical(entry.value, template) || entry.value == template) {
        key = entry.key;
        break;
      }
    }
    return _applyReplacements(template, {
      '{widgetName}': 'the widget',
      '{routeName}': 'the current route',
      '{count}': 'N',
      '{severity}': 'this',
      '{title}': template.displayName,
      '{stableId}': key,
    });
  }

  // IDE analyzer false-positive: dart:core RegExp uses @Deprecated.implement
  // (fires only on subclassing). Remove when analyzer-server recognizes the
  // implement-only kind.
  // ignore: deprecated_member_use
  static final RegExp _countExtractor = RegExp(r'(\d+)');

  static IssueExplanation _applyReplacements(
    IssueExplanation template,
    Map<String, String> replacements,
  ) {
    String apply(String text) {
      var out = text;
      for (final r in replacements.entries) {
        out = out.replaceAll(r.key, r.value);
      }
      return out;
    }

    return (
      displayName: template.displayName,
      category: template.category,
      whatItIs: apply(template.whatItIs),
      readingTheData: template.readingTheData == null
          ? null
          : apply(template.readingTheData!),
      whyItMatters: apply(template.whyItMatters),
      howToFix: apply(template.howToFix),
      whenToIgnore: template.whenToIgnore == null
          ? null
          : apply(template.whenToIgnore!),
      relatedIssues: template.relatedIssues,
    );
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
    })
  >
  get groupedEntries {
    final grouped = <IssueCategory, List<(String, IssueExplanation)>>{};
    for (final entry in _explanations.entries) {
      (grouped[entry.value.category] ??= []).add((entry.key, entry.value));
    }
    return [
      for (final cat in _categoryOrder)
        if (grouped.containsKey(cat)) (category: cat, entries: grouped[cat]!),
    ];
  }

  /// Normalises a [PerformanceIssue.stableId] to the encyclopedia key. It
  /// strips a parametric colon suffix (`tracked_resource_concurrent:foo`
  /// becomes `tracked_resource_concurrent`) and a dynamic widget-type suffix
  /// (`repaint_debug_MyWidget` becomes `repaint_debug`), and maps the
  /// non-lazy family (`non_lazy_listview`, `non_lazy_gridview`,
  /// `non_lazy_sliver_list`, `non_lazy_sliver_grid`) to `non_lazy_list`.
  /// Use this before looking up keys in [allExplanations] or before
  /// passing a stableId to [IssueEncyclopediaPage.scrollToStableId].
  static String canonicalId(String id) => _baseId(id);

  /// Emitted stableIds that share one encyclopedia entry. Exact match only.
  static const _aliases = <String, String>{
    'non_lazy_listview': 'non_lazy_list',
    'non_lazy_gridview': 'non_lazy_list',
    'non_lazy_sliver_list': 'non_lazy_list',
    'non_lazy_sliver_grid': 'non_lazy_list',
  };

  static String _baseId(String id) {
    final alias = _aliases[id];
    if (alias != null) return alias;

    // Colon-suffixed IDs (excessive_keep_alive:PageView~1, excessive_global_keys:0)
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
      displayName: 'Sustained jank',
      category: IssueCategory.build,
      whatItIs:
          'At least 3 severe frames (over 2 times the 16.7ms budget at 60 '
          'FPS) landed within the 240-frame buffer. The app visibly '
          'stuttered. The user saw dropped frames again and again over a '
          'sustained period, not a single hiccup.',
      readingTheData:
          'Like a car that stalls at every intersection. One stall is '
          'annoying, but repeated stalls make the whole trip feel '
          'unreliable.\n\n'
          '• Severe frames are frames over 2 times the budget (33.3ms at 60 '
          'FPS). A healthy app has 0. Sleuth raises the issue at 3 or more '
          'severe frames within the 240-frame buffer.\n\n'
          '• Janky % is the share of recent frames over budget. Under 5% is '
          'normal.\n\n'
          '• UI thread and Raster show the time spent in each pipeline '
          'thread. Both must stay under 16.7ms. The higher one is the '
          'bottleneck, shown as "UI thread" or "Raster thread".\n\n'
          '• Sub-phases (buildScope, flushLayout, flushPaint) show where the '
          'UI thread spent its time. The largest phase is the one to '
          'optimize.\n\n'
          '• The data comes from the FrameTiming API and the VM timeline.',
      whyItMatters:
          'Sustained jank is the most visible performance problem. Users '
          'perceive it as the app "freezing" or "lagging." Even 3 or 4 '
          'dropped frames in a row cause a noticeable stutter during '
          'scrolling or animation.',
      howToFix:
          'Look at which phase dominated the slow frames: build, layout, or '
          'raster. If build time is high, reduce widget rebuilds with const '
          'constructors and smaller rebuild scopes. If raster time is high, '
          'check for expensive GPU operations such as opacity layers, '
          'shader masks and large images. Profile in profile mode with the '
          'DevTools Timeline to find the exact call stack.',
      whenToIgnore:
          'The first frame after app launch or a route transition often '
          'jitters because of shader warm-up and tree construction. If '
          'sustained jank appears only on the first navigation, consider '
          'shader warm-up strategies.',
      relatedIssues: [
        'gc_pressure',
        'layout_bottleneck',
        'multiple_custom_fonts',
        'runtime_font_loading',
        'shader_compilation',
      ],
    ),

    'jank_detected': (
      displayName: 'Jank detected',
      category: IssueCategory.build,
      whatItIs:
          'More than 15% of the buffered frames (with at least 5 frames '
          'sampled) exceeded their time budget. At 60 FPS the budget is '
          '16.7ms. Sustained jank counts severe frames. This issue tracks '
          'how often ordinary frames run over budget, and Sleuth reports it '
          'as a warning only.',
      readingTheData:
          'Like a single skipped beat in music. It is noticeable but brief, '
          'unlike sustained jank, where the song keeps skipping.\n\n'
          '• Frame duration is the total time for one frame. The budget is '
          '16.7ms at 60 FPS.\n\n'
          '• Janky % is the share of buffered frames over budget. Sleuth '
          'raises a warning above 15%, once at least 5 frames are '
          'sampled.\n\n'
          '• UI duration is the time spent building and laying out '
          'widgets.\n\n'
          '• Raster duration is the time spent compositing and painting to '
          'the screen.\n\n'
          '• The data comes from the FrameTiming API.',
      whyItMatters:
          'Each jank frame causes a short stutter. One or two per session '
          'are normal. Frequent single-frame jank makes the app feel less '
          'smooth overall.',
      howToFix:
          'Check the frame breakdown. Was it build-dominated (expensive '
          'widget tree construction) or raster-dominated (a GPU '
          'bottleneck)? For build-heavy frames, look for large setState '
          'scopes or expensive build methods. For raster-heavy frames, '
          'check for saveLayer triggers (Opacity, ClipPath, ShaderMask).',
      whenToIgnore:
          'Occasional single jank frames during complex transitions or '
          'first renders are normal. Focus on sustained patterns, not '
          'isolated spikes.',
      relatedIssues: [
        'layout_bottleneck',
        'multiple_custom_fonts',
        'non_lazy_shrinkwrap',
        'runtime_font_loading',
        'shader_compilation',
        'slow_startup_ttff',
      ],
    ),

    'raster_cache_thrashing': (
      displayName: 'Raster cache thrashing',
      category: IssueCategory.raster,
      whatItIs:
          'The raster cache is evicting and re-creating entries rapidly. '
          'Flutter caches rendered layer images so it does not have to '
          'rasterize them again each frame. Thrashing means the cache is not '
          'working, and the GPU redoes work it already completed.',
      readingTheData:
          'Like a painter who keeps throwing away finished canvases and '
          'painting them again from scratch. The work is wasted and the '
          'gallery never fills up.\n\n'
          '• Cache count fluctuation is the variation in raster cache '
          'entries across consecutive frames. Sleuth raises the issue when '
          'it fluctuates more than 20% for 15 or more frames.\n\n'
          '• Consecutive frames shows how long the pattern lasted.\n\n'
          '• The data comes from the FrameTiming API cache fields.',
      whyItMatters:
          'When the raster cache thrashes, the GPU must re-rasterize layers '
          'that should have stayed cached, which raises raster time per '
          'frame. This often shows up as raster-dominated jank during '
          'scrolling.',
      howToFix:
          'Reduce the number of cacheable layers competing for cache space. '
          'Add RepaintBoundary widgets around content that changes often to '
          'isolate volatile regions. Avoid animating properties that '
          'invalidate large cached layers. For example, animating a parent '
          'opacity invalidates the cache for the entire subtree.',
      whenToIgnore:
          'Brief thrashing during route transitions is expected, because '
          'Flutter evicts the layers of the old route and creates new '
          'ones.',
      relatedIssues: ['raster_dominance'],
    ),

    'raster_cache_growing': (
      displayName: 'Raster cache growing',
      category: IssueCategory.raster,
      whatItIs:
          'The raster cache keeps growing, which means more and more '
          'rendered layers are cached and none are evicted. This unbounded '
          'growth uses more GPU memory over time. Left unchecked, the device '
          'may start evicting useful entries, or the operating system may '
          'send memory pressure warnings.',
      readingTheData:
          'Like a warehouse that keeps accepting deliveries but never ships '
          'anything out. Eventually it runs out of floor space.\n\n'
          '• Cache size is the current raster cache in KB. Under 500 KB and '
          'stable is normal. Monotonic growth over 30 frames raises the '
          'issue.\n\n'
          '• Growth frames counts consecutive frames where the cache size '
          'increased. 0 (stable) is normal. Sleuth raises the issue at 30 '
          'or more consecutive growth frames.\n\n'
          '• The data comes from the FrameTiming API cache bytes.',
      whyItMatters:
          'A raster cache that keeps growing uses more and more GPU memory. '
          'On devices with little memory this can trigger system memory '
          'pressure, which leads to background app kills or system-level '
          'throttling.',
      howToFix:
          'Find the widgets that create new cached layers over time. These '
          'are often list items created at runtime or pages that stay in '
          'memory. Dispose off-screen content when you no longer need it. '
          'Add RepaintBoundary only where it helps, because each one '
          'creates a cache entry.',
      whenToIgnore:
          'Cache growth is expected while the user first explores the app '
          'and opens new screens. It is a concern when growth continues '
          'without end on a single screen.',
      relatedIssues: ['raster_dominance'],
    ),

    // ── Shader & Compute ──────────────────────────────────────────────────
    'shader_compilation': (
      displayName: 'Shader compilation',
      category: IssueCategory.raster,
      whatItIs:
          'The engine built a GPU pipeline or shader at runtime. On Impeller '
          'Vulkan (Android), each new combination of effect and render '
          'state builds a pipeline the first time it is drawn. On Skia, the '
          'shader compiler runs on first use. Sleuth reports both. Impeller '
          'Metal (iOS) precompiles pipelines at build time, so this issue '
          'does not appear there.',
      readingTheData:
          'Like a chef sharpening a new knife before the first cut. It is '
          'slow the first time and instant on every use after.\n\n'
          '• Build ms is the duration of the pipeline or shader build event. '
          'Sleuth warns at 100ms or more and marks it critical at 200ms or '
          'more (default, configurable).\n\n'
          '• Cumulative count is the total number of builds this session. '
          'First-run sessions have more. Later launches should have '
          'fewer.\n\n'
          '• The data comes from VM timeline begin and end events '
          '(`PipelineVK::Create`, `CreateComputePipeline`, Skia shader '
          'events).',
      whyItMatters:
          'The build runs on a worker thread, but a frame that needs the '
          'pipeline waits for it. A 100ms build can stall the first frame '
          'that uses a new effect. It happens once per pipeline per app '
          'session, so it is most noticeable the first time the app shows a '
          'visual effect.',
      howToFix:
          'Trigger the first use of heavy effects (BackdropFilter, '
          'ShaderMask, custom FragmentProgram) during a warm-up or splash '
          'frame, so the build does not land on a user interaction. Avoid '
          'introducing new effect types in the middle of an animation. On '
          'devices still on Skia, prefer Impeller.',
      whenToIgnore:
          'Cold-start builds under 100ms are normal, and Sleuth does not '
          'report them. Repeated builds on the same screen in one session '
          'are worth a look. A single build at first launch usually is '
          'not.',
      relatedIssues: ['jank_detected', 'sustained_jank'],
    ),

    'heavy_compute': (
      displayName: 'Heavy computation',
      category: IssueCategory.build,
      whatItIs:
          'A widget build pass on the UI thread in {routeName} ran longer '
          'than the threshold. At 60 Hz, more than 8 ms is a warning and '
          'more than 16 ms is critical, and the threshold scales with the '
          'measured frame rate. The detector measures BUILD-phase duration '
          'from the VM timeline. While that pass runs, the framework cannot '
          'lay out or render the frame, so expensive build methods and the '
          'synchronous work they call both show up here.',
      readingTheData:
          'Like a cashier doing complex math by hand while a long line of '
          'customers waits. Everything stops until the calculation '
          'finishes.\n\n'
          '• Build duration ms is how long the BUILD pass ran. Under 8ms is '
          'normal. Sleuth reports above 8ms (warning) and above 16ms '
          '(critical). These defaults apply at 60 Hz, use half the frame '
          'budget on faster displays, and are configurable.\n\n'
          '• Dirty widgets lists the widgets marked dirty during the heavy '
          'build. They show what triggered the work.\n\n'
          '• The data comes from VM timeline build-phase events.',
      whyItMatters:
          'Any synchronous work on the UI thread that takes longer than '
          'about 16ms blocks frame rendering. Users see a freeze. Animations '
          'stop, scrolling does not respond, and touches get no feedback '
          'until the computation completes.',
      howToFix:
          'Start with the build itself. Split large widgets so a change '
          'rebuilds a smaller subtree, mark static subtrees const, and defer '
          'below-the-fold work (lazy builders, deferred loading). If the '
          'build calls real non-UI computation, such as parsing large JSON '
          'payloads, image processing, cryptographic operations or complex '
          'data transformations, move it to a background isolate with '
          'Isolate.run().\n\n'
          'Before (blocks UI thread):\n'
          '  final data = jsonDecode(hugeJsonString);\n\n'
          'After (runs in background isolate):\n'
          '  final data = await Isolate.run(\n'
          '    () => jsonDecode(hugeJsonString),\n'
          '  );\n\n'
          'Isolate.run() (Dart 2.19 or later) is the modern API. compute() '
          'is a Flutter convenience wrapper over Isolate.run. Dart copies '
          'the values the closure captures to the new isolate, so keep '
          'captures small and sendable. If the work cannot move off the UI '
          'thread, break it into smaller chunks scheduled across several '
          'frames.',
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
      displayName: 'GC pressure',
      category: IssueCategory.memory,
      whatItIs:
          'The garbage collector is running more often than normal app '
          'operation needs. Each GC cycle pauses the Dart isolate briefly to '
          'reclaim unused memory. When collections happen back to back, the '
          'pauses add up to noticeable micro-stutters.',
      readingTheData:
          'Like a janitor who keeps interrupting a meeting to empty small '
          'trash cans. Each visit is brief, but they add up and break '
          'concentration.\n\n'
          '• GC/min is the number of garbage collection cycles per minute, '
          'scavenges included. An idle app with Sleuth attached runs about '
          '60 to 140/min, because the VM service polling itself allocates. '
          'Sleuth raises the issue above 180/min (default, configurable via '
          'SleuthConfig.gcRateThresholdPerMin), that is, more than 30 cycles '
          'in 10 seconds. Allocation churn runs at thousands per minute.\n\n'
          '• The title number (for example "240 GC/min") is the rate over '
          'the last 10 seconds. The detail splits it into scavenges (young '
          'generation, cheap) and old-generation collections (mark-sweep or '
          'mark-compact, with longer pauses).\n\n'
          '• The data comes from the VM service GC event stream, with one '
          'event per completed collection.',
      whyItMatters:
          'Frequent GC pauses cause micro-stutters. These are brief freezes '
          'under 5ms that seem harmless alone but add up within a frame\'s '
          'budget. Several pauses in one frame can push total frame time '
          'over budget. GC pressure also points to a high allocation rate, '
          'which wastes CPU cycles on its own.',
      howToFix:
          'Reduce the allocation rate. Cache objects that are recreated each '
          'frame, use const constructors for immutable widgets, and avoid '
          'creating closures or lists inside build(). Move static widgets to '
          'const constructors so the framework can reuse them without '
          'allocating:\n\n'
          'Before: Container(color: Colors.blue)\n'
          'After: const ColoredBox(color: Colors.blue)\n\n'
          'Use the DevTools Memory tab to find the classes that allocate the '
          'most and the allocation hot spots.',
      whenToIgnore:
          'Brief GC spikes during route transitions or initial data loading '
          'are normal. It is a concern when GC stays high during '
          'steady-state interaction (scrolling, idle).',
      relatedIssues: [
        'heap_growing',
        'stream_resource_growth',
        'sustained_jank',
        'uncached_images',
      ],
    ),

    'heap_growing': (
      displayName: 'Heap growing',
      category: IssueCategory.memory,
      whatItIs:
          'The Dart heap keeps growing over time. Sleuth detects this with a '
          'linear regression on heap usage samples. It suggests the app '
          'allocates objects faster than GC reclaims them.',
      readingTheData:
          'Like a bathtub filling faster than it drains. Eventually the '
          'water overflows unless you fix the imbalance.\n\n'
          '• Growth rate KB/s is the heap increase per second, from a linear '
          'regression over a 30-second window. 0 (stable) is normal. Sleuth '
          'raises the issue above 512 KB/s for 10 seconds or more (default, '
          'configurable).\n\n'
          '• Sustained duration is how long the growth trend has lasted. A '
          'longer duration raises confidence that it is a leak.\n\n'
          '• The data comes from VM service heap samples every 500ms.',
      whyItMatters:
          'Sustained heap growth is often a memory leak. Objects that should '
          'be freed stay alive through lingering references: undisposed '
          'controllers, uncancelled stream subscriptions, or closures that '
          'capture widget references. Left unchecked, the app hits its '
          'memory limit and the OS kills it.',
      howToFix:
          'Check your StatefulWidgets for undisposed controllers, uncancelled '
          'StreamSubscriptions and Timer instances. Release every resource '
          'acquired in initState() or didChangeDependencies() in '
          'dispose().\n\n'
          'DevTools snapshot walkthrough:\n'
          '1. Open the DevTools Memory tab\n'
          '2. Take a heap snapshot (baseline)\n'
          '3. Perform the user flow that triggers growth\n'
          '4. Take a second snapshot\n'
          '5. Diff the two snapshots and sort by retained size\n\n'
          'Retained size is the total memory freed if the object were '
          'collected, including everything it references. Shallow size is '
          'the object alone. A 100-byte object that retains a 10MB image has '
          'a 100B shallow size but about 10MB retained. Retained size shows '
          'the real cost of the leak.',
      whenToIgnore:
          'Heap growth during app startup or while loading large datasets is '
          'expected. The concern is growth that continues after the app '
          'reaches steady state.',
      relatedIssues: [
        'excessive_keep_alive',
        'gc_pressure',
        'heap_near_capacity',
        'stream_resource_growth',
        'tracked_resource_concurrent',
        'tracked_resource_long_lived',
        'uncached_images',
      ],
    ),

    'stream_resource_growth': (
      displayName: 'Stream resources growing',
      category: IssueCategory.memory,
      whatItIs:
          'Watchlist async resource classes (StreamSubscription, '
          'StreamController, WebSocketChannel, optional rxdart Subjects) are '
          'accumulating across a 4-sample VM allocation profile window, and '
          '`heap_growing` is active at the same time. The pattern suggests '
          'retained subscriptions, undisposed StreamControllers or open '
          'WebSocket channels. The VM cannot prove ownership intent, so '
          'confidence is "likely" rather than "confirmed".',
      readingTheData:
          'Like noticing a rising water bill and a growing list of newly '
          'installed taps at the same time. Either one alone is suggestive. '
          'Together they point strongly to a leak.\n\n'
          '• Top growth class is the watchlist class with the largest '
          'instance delta across the window. Sleuth raises the issue at a '
          'delta of at least 50 instances (default, configurable).\n\n'
          '• Watchlist classes growing is a comma-separated list of the '
          'suffixes that showed monotonic growth.\n\n'
          '• Samples in window defaults to 4, which is about 40 s of history '
          'at a 10 s cadence.\n\n'
          '• The data comes from the VM service `getAllocationProfile`, '
          'polled at most once per `streamResourceSampleSeconds` (default '
          '10 s).',
      whyItMatters:
          'Stream resource leaks are among the most common Flutter memory '
          'bugs. A forgotten `cancel()` on a `StreamSubscription` or '
          '`close()` on a `StreamController` keeps every closure and '
          'captured widget reference along the subscription chain alive. The '
          'leak grows as users navigate between routes, and it can end in a '
          'crash or an OS kill on devices with little memory.',
      howToFix:
          'Check the dispose and cancel paths in recently visited routes:\n\n'
          '• For a `StreamSubscription` returned by `Stream.listen()`, call '
          '`cancel()` in `State.dispose()`.\n'
          '• For a `StreamController`, call `close()` when ownership ends.\n'
          '• For a `WebSocketChannel`, call `sink.close()`.\n'
          '• For the rxdart `Subject` family, call `close()` when ownership '
          'ends.\n'
          '• For a Cubit or Bloc scoped to a widget, close it in '
          '`State.dispose()`.\n\n'
          'If the listed classes are retained on purpose (long-lived service '
          'singletons, app-scoped event buses), check `heap_growing` and '
          '`native_memory_growing` for other causes of memory pressure '
          '(cache bloat, image decode, GPU textures).',
      whenToIgnore:
          'A small, steady retention of broadcast subscriptions (route '
          'observers, animation tickers, app-scoped streams) is normal. It '
          'becomes a concern when growth continues after the app reaches '
          'steady state, or when the top growth class points to a feature '
          'you recently opened.',
      relatedIssues: ['heap_growing', 'native_memory_growing', 'gc_pressure'],
    ),

    'tracked_resource_concurrent': (
      displayName: 'Tracked resource concurrent',
      category: IssueCategory.memory,
      whatItIs:
          'More live instances are registered under one name through '
          '`Sleuth.trackResource(name, resource)` than the configured '
          'concurrent threshold allows (default: more than 5 live '
          'instances). The tracker holds only a `WeakReference`, so '
          'something outside Sleuth keeps each counted instance reachable. '
          'That makes the retention confirmed.',
      readingTheData:
          'Like signing a guest book on entry. If the book shows 8 guests '
          'still inside an hour after the meeting ended, someone forgot to '
          'leave.\n\n'
          '• Resource name is the string passed to `Sleuth.trackResource`. '
          'The intended use is a stable naming scheme, one name per service '
          'class.\n\n'
          '• Live instance count is the number of registered targets the GC '
          'has not finalised yet.\n\n'
          '• The data comes from pure Dart `WeakReference` and `Finalizer`. '
          'No VM service is required.',
      whyItMatters:
          'This is a confirmed leak. The user opted in to tracking this '
          'name, so the live count reflects a real ownership claim. Each '
          'retained instance keeps its captured closures alive. Common '
          'offenders are HTTP clients with connection pools, repository '
          'singletons stacked across feature scopes, and chat-socket-style '
          'services kept alive after their flow ends.',
      howToFix:
          'Check the dispose and cancel paths for the named resource:\n\n'
          '• Find every `Sleuth.trackResource(name, ...)` call site.\n'
          '• Check that each one has a matching `Sleuth.untrackResource` or '
          'a clear ownership boundary (state.dispose, scope close, isolate '
          'death) where the GC will reclaim it.\n'
          '• If the resource is pooled on purpose (HTTP connection pool, '
          'isolate worker pool), raise the threshold. Set it globally with '
          '`SleuthConfig.thresholds.trackedResourceMaxConcurrent` or per '
          'name with `Sleuth.setResourceThreshold(name, maxConcurrent: N)`. '
          'Per-name overrides survive bucket eviction.',
      whenToIgnore:
          'Ignore it for a pooled resource where the count is the design, '
          'such as a database connection pool or a prerendered tile cache. '
          'Tune the threshold instead of disposing what should stay.',
      relatedIssues: ['heap_growing', 'tracked_resource_long_lived'],
    ),

    'tracked_resource_long_lived': (
      displayName: 'Tracked resource long-lived',
      category: IssueCategory.memory,
      whatItIs:
          'A single instance registered through `Sleuth.trackResource` has '
          'been alive longer than the configured long-lived threshold '
          '(default 300 s, 5 minutes of wall-clock time). The Finalizer has '
          'not run, so the GC has not reclaimed the target. Something '
          'outside the tracker is holding it.',
      readingTheData:
          'Like a meeting room booking that never gets released. If a "30 '
          'minute" booking is still active 5 hours later, either the '
          'booking system is wrong or someone forgot to check out.\n\n'
          '• Resource name is the string passed to '
          '`Sleuth.trackResource`.\n\n'
          '• Oldest instance age is the wall-clock time in seconds since the '
          'first surviving registration.\n\n'
          '• The data comes from pure Dart `WeakReference` and `Finalizer` '
          'on the user-tracked target.',
      whyItMatters:
          'Long-lived retention is a confirmed ownership claim. If the '
          'resource was meant to be scope-bound (a per-route service, a '
          'per-feature subscription), the long lifetime means the owning '
          'scope never released it. If the resource was meant to last the '
          'whole session (a DI singleton, an app-scope event bus), the '
          'warning is noise, and you should stop tracking that name.',
      howToFix:
          'Decide how long the resource should live:\n\n'
          '• If it is scope-bound (route, feature, screen), find the missing '
          'dispose call. Ownership boundaries are `State.dispose`, '
          '`Cubit.close`, `provider` autoDispose and isolate teardown.\n\n'
          '• If it is session-long (singleton, app scope), stop tracking '
          'that name or raise the threshold past the longest legitimate '
          'session. Raise it globally with '
          '`SleuthConfig.thresholds.trackedResourceLongLivedSeconds` or per '
          'name with `Sleuth.setResourceThreshold(name, '
          'longLivedSeconds: N)`.',
      whenToIgnore:
          'Ignore it for singletons. Tracking is opt-in by name. If a name '
          'is always meant to live for the whole session, untrack it after '
          'the deliberate construction. One-shot tracking still catches '
          'accidental re-construction.',
      relatedIssues: ['heap_growing', 'tracked_resource_concurrent'],
    ),

    'heap_near_capacity': (
      displayName: 'Memory near budget',
      category: IssueCategory.memory,
      whatItIs:
          'Process memory (RSS) has reached 80% or more of the memory '
          'budget you configured, and the Dart heap is still growing. '
          'The budget is opt-in (DetectorThresholds.memoryBudgetBytes); '
          'without one this issue never fires.',
      readingTheData:
          'Like a fuel gauge with the reserve light on while the engine '
          'still burns fuel faster than usual.\n\n'
          '• RSS is the resident memory of the whole process: Dart heap, '
          'decoded images, GPU resources and native plugin memory. The OS '
          'compares this number against its kill limit.\n\n'
          '• Budget % is RSS divided by memoryBudgetBytes. Sleuth raises the '
          'issue at 80% or more (default, '
          'DetectorThresholds.memoryCapacityPercent) for 4 of the last 5 '
          'memory polls while heap_growing is active.\n\n'
          '• Sleuth does not use the Dart heap ratio. Dart grows heap '
          'capacity with usage, so used/capacity sits at 85 to 97% in a '
          'healthy app and says nothing about how close the process is to '
          'being killed.\n\n'
          '• To choose a budget, note that iOS terminates foreground apps at '
          'roughly half of physical RAM on 2 to 4 GB devices '
          '(os_proc_available_memory() reports the remaining headroom). On '
          'Android, the low-memory killer counts native memory too. A figure '
          'measured on your lowest-end target device is the safest '
          'budget.\n\n'
          '• The data comes from VM service getMemoryUsage() for the heap '
          'trend and ProcessInfo.currentRss for RSS (unavailable on web).',
      whyItMatters:
          'Above its memory limit, the OS kills the app without warning (iOS '
          'jetsam, Android low-memory killer). Users see the app vanish or '
          'restart from scratch. With the heap still growing, the app is '
          'using up its remaining headroom right now.',
      howToFix:
          'First find what is growing (see heap_growing and the DevTools '
          'Memory view). Then reduce peak memory. Clear image caches when '
          'leaving image-heavy screens '
          '(PaintingBinding.instance.imageCache.clear()), decode images at '
          'display size with cacheWidth/cacheHeight, dispose large data '
          'structures, and paginate big lists.',
      whenToIgnore:
          'If you set the budget below what the device allows, this fires '
          'early. Raise memoryBudgetBytes or memoryCapacityPercent. A short '
          'climb while a screen loads its images settles once heap_growing '
          'stops.',
      relatedIssues: [
        'excessive_keep_alive',
        'heap_growing',
        'native_memory_growing',
        'uncached_images',
      ],
    ),

    'native_memory_growing': (
      displayName: 'Native memory growing',
      category: IssueCategory.memory,
      whatItIs:
          'Memory outside the Dart heap (native or external memory) keeps '
          'growing. This includes decoded image bitmaps, platform channel '
          'buffers, native plugin allocations, and Skia or Impeller GPU '
          'resources.',
      readingTheData:
          'Like hidden water damage behind walls. You cannot see it from '
          'inside the room (the Dart heap), but the building inspector (the '
          'OS) knows and may condemn the building.\n\n'
          '• Growth rate MB/s is process memory growth outside the Dart '
          'heap. 0 (stable) is normal. Sleuth raises the issue above 1 MB/s '
          'for 10 seconds or more.\n\n'
          '• Sustained duration is how long native memory has been rising. '
          'Brief spikes during image loading are normal.\n\n'
          '• The data comes from VM service RSS minus the Dart heap.',
      whyItMatters:
          'Native memory is often the largest part of total app memory, and '
          'Dart\'s garbage collector cannot see it. Growing native memory can '
          'trigger an OS kill without any warning from the Dart VM.',
      howToFix:
          'The most common cause is decoded image bitmaps. Each '
          'full-resolution image can take width times height times 4 bytes. '
          'A 4000 by 3000 photo, for example, takes 48MB. Use '
          'cacheWidth/cacheHeight to decode at display size. Clear the image '
          'cache when leaving image-heavy screens. For plugin-related '
          'growth, check that native resources get released, for example by '
          'disposing a camera or video player.',
      whenToIgnore:
          'Initial image loading causes expected native memory growth. It is '
          'a concern when memory grows continuously and never levels off.',
      relatedIssues: [
        'heap_near_capacity',
        'stream_resource_growth',
        'uncached_images',
      ],
    ),

    // ── Rebuild & Repaint ─────────────────────────────────────────────────
    'rebuild_activity': (
      displayName: 'Rebuild activity',
      category: IssueCategory.build,
      whatItIs:
          'Rebuilding widgets is taking a large share of the UI thread. '
          'The framework spends so much of each second rebuilding widget '
          'subtrees that little time is left for layout, paint, and your '
          'own code.',
      readingTheData:
          'Like a doorbell that rings 30 times a minute. Each ring '
          'interrupts what you are doing, and at that rate you cannot get '
          'anything else done.\n\n'
          '• Build share is, in profile mode, the share of UI-thread time '
          'spent inside BUILD scopes per window of about 1 s, measured from '
          'VM timeline durations. One small animated widget stays well under '
          '1%. Sleuth raises the issue above 10% of UI-thread time (warning) '
          'and above 30% (critical). Both are defaults, configurable via '
          'DetectorThresholds.buildTimePercentThreshold.\n\n'
          '• Top dirty widgets lists the widget types with the most '
          'rebuilds, for example "MyWidget (47x)". Focus on the top one.\n\n'
          '• The data comes from VM timeline buildScope durations.',
      whyItMatters:
          'Each rebuild runs build() methods, diffs the widget tree, and can '
          'trigger layout and paint. Excessive rebuilds waste CPU cycles and '
          'can push frame times over budget, especially when large subtrees '
          'are involved.',
      howToFix:
          'Narrow the rebuild scope. Move state closer to the widgets that '
          'use it, use const constructors for static subtrees, and split '
          'large widgets into smaller components that rebuild on their own. '
          'Use ValueListenableBuilder, AnimatedBuilder, or '
          'BlocBuilder/Selector to rebuild only the affected subtree. Use '
          'the DevTools Widget Inspector to find which widgets rebuild and '
          'trace the source.',
      whenToIgnore:
          'Animations rebuild every frame by design, but a small animated '
          'subtree costs far less than the threshold. When an animation '
          'does cross it, the animated subtree is too large. Move static '
          'content into the builder\'s child or behind const widgets.',
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
        'stateful_density',
      ],
    ),

    'rebuild_debug': (
      displayName: 'Widget rebuild (debug)',
      category: IssueCategory.build,
      whatItIs:
          'A specific widget type is rebuilding at a high rate. Debug '
          'callbacks identified this widget as a frequent rebuilder during '
          'the monitoring window.',
      readingTheData:
          'Like one student who keeps raising a hand every few seconds. Find '
          'out why they need so much attention.\n\n'
          '• Rebuild rate/sec is how many times this widget type rebuilt per '
          'second. 0 to 1/sec at idle is normal. Sleuth raises the issue at '
          '10/sec or more (default, configurable). Builder widgets such as '
          'StreamBuilder or ValueListenableBuilder alert at 3 times that '
          'rate. The issue turns critical above 3 times the alert rate.\n\n'
          '• Widget type is the exact class name being tracked. Only widgets '
          'your code creates count, and only rebuilds they start themselves '
          '(setState, a changed dependency, a listenable). The detail names '
          'the widgets their build then updates. Sleuth does not report '
          'those on their own.\n\n'
          '• This is debug mode only. Values may differ in profile mode.\n\n'
          '• The data comes from the debugOnRebuildDirtyWidget callback.',
      whyItMatters:
          'When a single widget type dominates rebuild counts, either its '
          'state changes too often or its parent triggers unnecessary '
          'rebuilds that cascade down.',
      howToFix:
          'Check why this widget rebuilds. Is its parent calling setState '
          'too broadly? Is it listening to a stream or notifier that fires '
          'too often? Extract the widget into its own StatelessWidget with a '
          'const constructor, or use targeted state management that '
          'rebuilds only this widget when its data changes.',
      whenToIgnore:
          'Animation-driven widgets (inside AnimatedBuilder) rebuild every '
          'frame by design. Clock and timer widgets also rebuild often by '
          'design.',
      relatedIssues: ['setstate_scope'],
    ),

    'stateful_density': (
      displayName: 'StatefulWidget density',
      category: IssueCategory.build,
      whatItIs:
          'At least 10 public StatefulWidget instances are on screen, and '
          'Sleuth had no VM connection or debug callbacks, so it could not '
          'measure the real rebuild rate. Each StatefulWidget keeps its own '
          'State object and lifecycle.',
      readingTheData:
          'Like an office where every employee has a private assistant. Each '
          'assistant tracks separate state, and coordinating them all adds '
          'overhead.\n\n'
          '• Stateful count is the number of public StatefulWidget instances '
          'on screen, excluding framework and private types. Sleuth raises '
          'the issue at 10 or more public StatefulWidget instances on screen '
          'while no VM connection or debug callbacks are available (default, '
          'separate from the rebuild rate threshold).\n\n'
          '• Most common is the StatefulWidget type with the most instances '
          'on screen. Start the audit there.\n\n'
          '• Sleuth finds this with a structural tree walk.',
      whyItMatters:
          'Many StatefulWidgets in a small area make rebuilds cost more. '
          'Each one manages its own state, runs build(), and can call its '
          'own setState. That creates a risk of a "rebuild storm", where '
          'many widgets rebuild at the same time.',
      howToFix:
          'Check whether each StatefulWidget needs local state. Many can '
          'become StatelessWidgets if they only read inherited or '
          'passed-down state. Consolidate related state into a single parent '
          'StatefulWidget, or use a state management solution (Provider, '
          'Riverpod, Cubit) to lift state up.',
      whenToIgnore:
          'Form-heavy screens have high StatefulWidget density because each '
          'TextField is stateful. This is expected.',
      relatedIssues: ['rebuild_activity', 'setstate_scope'],
    ),

    'excessive_repaint': (
      displayName: 'Excessive repaints',
      category: IssueCategory.paint,
      whatItIs:
          'Painting is taking a large share of the UI thread. The app '
          're-records parts of the screen so often, or they cost so much to '
          'record, that paint work crowds out the rest of the frame.',
      readingTheData:
          'Like repainting a whole room every time you move a picture frame. '
          'Most of the wall has not changed, but you redo all the work.\n\n'
          '• Paint share is, in profile mode, the share of UI-thread time '
          'spent inside PAINT scopes per window of about 1 s, measured from '
          'VM timeline durations. A small animated layer stays well under '
          '1%. Sleuth raises the issue above 10% of UI-thread time (warning) '
          'and above 30% (critical). Both are defaults, configurable via '
          'DetectorThresholds.paintTimePercentThreshold.\n\n'
          '• The data comes from VM timeline paint-phase durations.',
      whyItMatters:
          'Excessive repainting wastes GPU resources. Each repaint records '
          'drawing commands and sends them to the raster thread. When large '
          'areas repaint without need, raster time goes up and the raster '
          'thread can jank.',
      howToFix:
          'Add RepaintBoundary widgets to create repaint island boundaries. '
          'Each boundary creates an isolated compositing layer that repaints '
          'without affecting its parent or siblings. Place boundaries at '
          'natural isolation points: list items, cards, animated widgets, '
          'and toolbar regions.\n\n'
          'Check CustomPainter.shouldRepaint() and return false when the '
          'painter\'s inputs have not changed. Avoid animations that '
          'invalidate large parent regions. Use the DevTools Performance '
          'overlay or debugPaintLayerBordersEnabled to see layer boundaries '
          'and check that repaint islands are isolated.',
      whenToIgnore:
          'Active animations and scroll-driven content repaint often by '
          'design. Focus on unexpected repaints on idle or static '
          'screens.\n\n'
          'Since v0.15.3, Sleuth attributes each paint event to a known '
          'frame-rate animation owner. At paint-callback time it inspects '
          'the live element with three checks: (1) the cached ancestor '
          'chain, (2) a typed ancestor walk up to depth 16, and (3) a typed '
          'descendant walk up to depth 4. The recognised owner set covers 21 '
          'widgets: progress indicators (CircularProgressIndicator, '
          'LinearProgressIndicator, RefreshProgressIndicator, '
          'RefreshIndicator, CupertinoActivityIndicator), generic builders '
          '(AnimatedBuilder, ValueListenableBuilder, TweenAnimationBuilder), '
          'every Animated* implicit-animation widget (AnimatedContainer, '
          'AnimatedOpacity, AnimatedSwitcher, and others), and Hero. That '
          'filter applies to the per-widget paint counts from debug '
          'instrumentation. The UI-thread time share counts every PAINT '
          'scope, so the paint time of a spinning indicator counts in full. '
          'A small animation stays far below 10 %. If the share climbs near '
          'a busy animation, wrap it in a RepaintBoundary so the rest of the '
          'screen stops repainting with it.',
      relatedIssues: [
        'always_repaint_painter',
        'animated_builder_no_child',
        'excessive_repaint_boundary',
        'frequent_repaint_painter',
        'missing_repaint_boundary',
        'repaint_debug',
      ],
    ),

    'repaint_debug': (
      displayName: 'Widget repaint (debug)',
      category: IssueCategory.paint,
      whatItIs:
          'A widget is the likely origin of frequent repaints. In each '
          'frame, debug callbacks see which render objects were marked as '
          'needing paint. The deepest marked one in a layer is where the '
          'repaint most likely started. Sleuth does not report widgets that '
          'repaint only because they share that layer.',
      readingTheData:
          'Like one wall in your house that needs a fresh coat every week. '
          'Something about that surface keeps getting dirty, and the rest of '
          'the room gets repainted with it.\n\n'
          '• Repaint rate is how many frames per second the busiest instance '
          'of this widget type was the likely origin of a repaint, leaving '
          'out repaints driven by an animation owner. Rates are per '
          'instance, never summed across instances. The detail says how many '
          'instances were origins. 0 to 1/sec at idle is normal. Sleuth '
          'raises the issue at 30/sec or more, and it turns critical above 2 '
          'times that (more than 60/sec).\n\n'
          '• Widget type is the nearest widget your code created at or above '
          'the render object that changed. A Text whose content changes '
          'reports as Text, although the framework creates the render object '
          'that paints it.\n\n'
          '• The result is likely, not certain. An ancestor that marked '
          'itself in the same frame as the reported widget looks the same as '
          'one marked through it.\n\n'
          '• This is debug mode only. Values may differ in profile mode.\n\n'
          '• The data comes from the debugOnProfilePaint callback.',
      whyItMatters:
          'Each repaint re-records every widget in the same layer, so one '
          'widget that changes every frame makes everything around it '
          'repaint too. That usually means a missing RepaintBoundary, an '
          'animation placed too high in the tree, or a CustomPainter that '
          'returns true from shouldRepaint() more often than its output '
          'changes.',
      howToFix:
          'Isolate the part that changes. Wrap the reported widget itself, '
          'or the smallest subtree around it, in a RepaintBoundary, so the '
          'rest of its layer stops repainting with it. Wrapping a sibling '
          'does not help, because the sibling\'s layer is reused but the '
          'reported widget still repaints its own layer. You can also move '
          'the animation or listenable lower in the tree. A boundary makes '
          'each repaint cheaper, not rarer. To repaint less often, check '
          'what marks the widget as needing paint: a setState or listenable '
          'that fires every frame, or a CustomPainter whose shouldRepaint() '
          'should compare the fields it draws.',
      whenToIgnore:
          'Widgets inside active animations repaint every frame by design. '
          'Since v0.15.3, Sleuth skips per-widget repaint reporting when a '
          'per-paint walk attributes the painted element to one of 21 known '
          'animation owners: progress indicators (CircularProgressIndicator '
          'and family), generic builders (AnimatedBuilder, '
          'ValueListenableBuilder, TweenAnimationBuilder), every Animated* '
          'implicit-animation widget, RefreshIndicator, and Hero. The walk '
          'runs against the live element with three legs (chain regex, '
          'typed ancestor walk to depth 16, typed descendant walk to depth '
          '4), so it catches owners above or below the painted leaf in the '
          'element tree. If this issue still fires next to an animation, the '
          'owning widget is probably custom. Wrap it in an AnimatedBuilder '
          'or a RepaintBoundary to make the animation explicit.\n\n'
          'Sleuth does not report repaints that follow a scroll (the scroll '
          'view itself, or a collapsing app bar while the user scrolls), or '
          'the framework\'s own control painters (a scrollbar thumb, a '
          'toggle, a tab indicator).',
      relatedIssues: [
        'excessive_repaint',
        'excessive_repaint_debug',
        'missing_repaint_boundary',
      ],
    ),

    'excessive_repaint_debug': (
      displayName: 'Excessive repaint (debug)',
      category: IssueCategory.paint,
      whatItIs:
          'Debug-mode paint profiling found an abnormally high repaint rate '
          'across the render tree. Several render objects are marked as '
          'needing paint each frame.',
      readingTheData:
          'Like a maintenance crew that repaints the whole building every '
          'day. Most surfaces are still fresh, but nobody checks first.\n\n'
          '• Repaint rate is the total repaint frequency across all tracked '
          'render objects, leaving out paints driven by animations. 0 to '
          '2/sec at idle is normal. Sleuth raises the issue at 30/sec or '
          'more, and it turns critical above 2 times that (more than '
          '60/sec).\n\n'
          '• This is debug mode only. Rates may differ in profile mode.\n\n'
          '• The data comes from debug-mode paint profiling callbacks.',
      whyItMatters:
          'A high overall repaint rate means the raster thread does more '
          'work per frame than it needs to. That uses GPU time and can cause '
          'raster-thread jank.',
      howToFix:
          'Find the root cause. It is usually an animation or state change '
          'high in the tree that invalidates many descendants. Insert '
          'RepaintBoundary widgets at natural boundaries (list items, cards, '
          'toolbar) to stop repaints from spreading.',
      whenToIgnore:
          'A high repaint rate is expected during full-screen transitions or '
          'scrolling.\n\n'
          'Since v0.15.3, Sleuth subtracts known animation-owned paints from '
          'the total before it checks the threshold. If this issue fires '
          'alongside an active animation, the issue detail shows "Excludes N '
          'animation-owned paints". The rest is still above the threshold '
          'after the animation is taken out. Look for paint sources other '
          'than the animation first.',
      relatedIssues: [
        'always_repaint_painter',
        'animated_builder_no_child',
        'missing_repaint_boundary',
        'repaint_debug',
      ],
    ),

    // ── GPU & Raster ──────────────────────────────────────────────────────
    'raster_dominance': (
      displayName: 'Raster dominance',
      category: IssueCategory.raster,
      whatItIs:
          'The raster thread is consistently taking longer than the UI '
          'thread. GPU work (compositing, painting to the screen) dominates '
          'frame time, not widget building.',
      readingTheData:
          'Like a restaurant where the chef finishes dishes quickly but the '
          'waiter takes forever to serve them. The bottleneck is delivery, '
          'not preparation.\n\n'
          '• Raster/UI ratio is a frame\'s raster time divided by its UI time '
          '(build, layout and paint). The title shows it as a multiple, such '
          'as 2.3. Under 1.5 times is normal. A frame counts as '
          'raster-dominant above 2.0 times when its raster time also exceeds '
          'half the frame budget (8 ms at 60 Hz). These defaults are '
          'configurable.\n\n'
          '• Under the sustained rule, 3 raster-dominant frames within one '
          'second since the last scan raise the issue as likely. It turns '
          'critical when those frames also exceeded the frame budget. Sleuth '
          'ignores frames in the first seconds after launch.\n\n'
          '• When the VM timeline is connected, Sleuth confirms it by '
          'comparing the worst raster frame with the UI thread total: '
          'above 2.0 times (warning) or above 4.0 times (critical).\n\n'
          '• Raster ms and UI ms are the absolute times for each thread. Both '
          'must stay under the frame budget (16.7ms at 60 Hz) to avoid '
          'jank.\n\n'
          '• The data comes from per-frame FrameTiming raster and UI '
          'durations, and the VM timeline corroborates it.',
      whyItMatters:
          'Optimizing build() methods cannot fix a raster-thread bottleneck, '
          'because the GPU is the constraint. Users see jank even when the '
          'UI thread finishes quickly, because both threads must finish '
          'within the frame budget.',
      howToFix:
          'Reduce GPU work. Use fewer saveLayer triggers (Opacity, ClipPath, '
          'ShaderMask), reduce the number of layers, simplify clip shapes, '
          'and add RepaintBoundary to cache static content. Decode images at '
          'display size to reduce texture upload cost. Consider simpler '
          'visual effects on lower-end devices.',
      whenToIgnore:
          'GPU-heavy screens (complex animations, many overlapping '
          'transparent layers) can be raster-dominated without a problem if '
          'frames still meet the budget.',
      relatedIssues: [
        'always_repaint_painter',
        'frequent_repaint_painter',
        'missing_repaint_boundary',
        'raster_cache_growing',
        'raster_cache_thrashing',
      ],
    ),

    'expensive_gpu_nodes': (
      displayName: 'Expensive GPU nodes',
      category: IssueCategory.raster,
      whatItIs:
          'Sleuth found render tree nodes that trigger expensive GPU '
          'operations: saveLayer (Opacity, ShaderMask), complex clips '
          '(ClipPath), or large texture uploads.',
      readingTheData:
          'Like adding extra layers of gift wrap. Each layer looks nice, but '
          'the package gets heavier and harder to handle.\n\n'
          '• Node count is the number of expensive GPU render nodes found '
          '(Opacity, ClipPath, ShaderMask, BackdropFilter). Each saveLayer '
          'can add 2 to 4ms per frame on mid-range devices.\n\n'
          '• Descendant count is the subtree size under each expensive node. '
          'Sleuth raises the issue above 5 descendants under specific node '
          'types.\n\n'
          '• Sleuth finds this with a structural render tree walk, '
          'corroborated by raster-dominant frames (FrameTiming or VM '
          'timeline).',
      whyItMatters:
          'Each saveLayer allocates an offscreen GPU buffer and needs an '
          'extra compositing pass. Stacking them (for example, Opacity '
          'inside Opacity) multiplies the cost, because each extra layer '
          'adds another full-screen pass. On lower-end devices this is often '
          'the main cause of raster jank.',
      howToFix:
          'Replace Opacity with Visibility for show and hide (no GPU '
          'buffer). Use FadeTransition instead of AnimatedOpacity when '
          'possible. Replace ClipPath with ClipRRect, which costs less. For '
          'color overlays, use ColorFiltered on the image source instead of '
          'a stacked Opacity widget. Flatten layer trees by removing '
          'unnecessary decorations.',
      whenToIgnore:
          'Some visual effects need saveLayer, such as BackdropFilter for '
          'blur. The concern is unnecessary layers from convenience '
          'widgets.',
      relatedIssues: ['opacity_zero'],
    ),

    // ── setState Scope ────────────────────────────────────────────────────
    'setstate_scope': (
      displayName: 'setState scope',
      category: IssueCategory.build,
      whatItIs:
          'A StatefulWidget high in the tree calls setState(), which '
          'rebuilds a large subtree. The rebuild cost grows with the number '
          'of descendant widgets that must be rebuilt.',
      readingTheData:
          'Like a fire alarm that clears the whole building when only one '
          'room has smoke. The response is far larger than the problem.\n\n'
          '• Ownership ratio is the share of the scanned tree inside the '
          'StatefulWidget\'s subtree. Sleuth raises the issue above 50% with '
          'a subtree of at least 50 elements (default, configurable). It '
          'turns critical when the ratio exceeds 1.5 times the configured '
          'threshold (above 75% by default).\n\n'
          '• Rebuild evidence is required. Sleuth must see the owner '
          'rebuild: its child widget identity changes in at least 2 scans '
          'within a 5 s window, or debug rebuild callbacks count it. Sleuth '
          'never reports a wide but static page. It skips builder-style '
          'owners (FutureBuilder, StreamBuilder, ValueListenableBuilder, '
          'Form, Focus).\n\n'
          '• Depth is how far above the leaf widgets the setState caller '
          'sits. A higher depth means a wider blast radius.\n\n'
          '• Sleuth finds this with a structural tree walk plus rebuild '
          'observation.',
      whyItMatters:
          'When a widget near the root calls setState, the build() method of '
          'every descendant runs again, even for widgets whose data has not '
          'changed. This is the most common cause of unnecessary CPU work in '
          'Flutter apps.',
      howToFix:
          'Move state down to the smallest widget that needs it. Put the '
          'changing value in a ValueNotifier and use ValueListenableBuilder '
          'to rebuild only the dependent widget:\n\n'
          'Before (rebuilds entire subtree):\n'
          '  setState(() => _count++);\n\n'
          'After (rebuilds only the Text):\n'
          '  final _count = ValueNotifier(0);\n'
          '  ValueListenableBuilder<int>(\n'
          '    valueListenable: _count,\n'
          '    builder: (_, val, __) => Text("\$val"),\n'
          '  )\n\n'
          'With a state management package, use Riverpod select(), '
          'BlocSelector, or Provider.select() to rebuild only the widgets '
          'that depend on the changing value. Extract static parts of the '
          'subtree into const widgets that the framework can skip during '
          'the diff.',
      whenToIgnore:
          'If the StatefulWidget has a small subtree (under 50 widgets), the '
          'rebuild cost is negligible regardless of scope.',
      relatedIssues: [
        'heavy_compute',
        'layout_bottleneck',
        'rebuild_activity',
        'rebuild_debug',
        'shallow_rebuild_risk',
        'stateful_density',
      ],
    ),

    // The entries below cover stableIds whose source detectors were removed
    // in v0.20.0 (animated_builder, opacity, shallow_rebuild_risk,
    // nested_scroll, global_key). They remain so v0.19 saved snapshots
    // replay with full explanation context. Do not delete without bumping
    // snapshot schemaVersion.

    // ── Shallow Rebuild Risk ──────────────────────────────────────────────
    'shallow_rebuild_risk': (
      displayName: 'Shallow rebuild risk (legacy)',
      category: IssueCategory.build,
      whatItIs:
          'Sleuth no longer detects this issue. Its detector was removed in '
          '0.20.0, and this entry stays so snapshots from earlier versions '
          'keep their explanation. '
          'A StatefulWidget near the top of the tree had no targeted state '
          'management. If this widget calls setState(), the whole deep '
          'subtree below it rebuilds.',
      readingTheData:
          'Like a dam with a hairline crack. Nothing floods yet, but the '
          'potential damage grows with every meter of water behind it.\n\n'
          '• Subtree depth is how deep the tree extends below this widget. '
          'Under 100 descendants is normal. The threshold is more than 200 '
          'descendants.\n\n'
          '• Risk level is based on subtree size and the absence of targeted '
          'state patterns (no ValueListenableBuilder, BlocBuilder, and so '
          'on).\n\n'
          '• Sleuth found this with a structural tree walk.',
      whyItMatters:
          'This is a structural risk. It may not cause jank yet, but it '
          'creates a "blast radius" problem. As the subtree grows or '
          'setState runs more often (during animations, for example), the '
          'rebuild cost increases.',
      howToFix:
          'Use targeted state access patterns: MediaQuery.sizeOf(context) '
          'instead of MediaQuery.of(context), and '
          'Theme.of(context).colorScheme instead of Theme.of(context) when '
          'you only need colors. Wrap expensive subtrees in Builder or '
          'dedicated widgets that isolate them from parent rebuilds.',
      whenToIgnore:
          'If the widget never calls setState() (for example, it only sets '
          'state in initState), the structural risk has no real cost.',
      relatedIssues: ['rebuild_activity', 'setstate_scope'],
    ),

    // ── Structural: ListView ──────────────────────────────────────────────
    'non_lazy_list': (
      displayName: 'Non-lazy list',
      category: IssueCategory.build,
      whatItIs:
          'Sleuth found {widgetName} with {count} children passed as a '
          'list. Flutter allocates every child widget on each parent '
          'rebuild, which bypasses lazy construction. Under a SingleChildScrollView '
          'with a Column or Row, every child is also built and laid out, '
          'even far off-screen.',
      readingTheData:
          'Like a restaurant that cooks every menu item before any customer '
          'orders. Most of the food goes to waste.\n\n'
          '• Child count is the number of children allocated up front. Under '
          '20 is normal. Sleuth raises the issue above 50 children (default, '
          'configurable), and it turns critical above 3 times the threshold '
          '(more than 150).\n\n'
          '• Widget type shows whether it is a ListView, Column, or Row. '
          'ListView(children: [...]) is the most common offender.\n\n'
          '• Sleuth finds this with a structural tree walk.',
      whyItMatters:
          'Eager list construction wastes memory and CPU. A list with 1,000 '
          'items allocates all 1,000 child widgets on every parent rebuild, '
          'even though only about 10 are visible. The result is a slow first '
          'render and high memory use.',
      howToFix:
          'Replace ListView(children: [...]) with ListView.builder():\n\n'
          'Before (eager, allocates every item on each rebuild):\n'
          '  ListView(children: items.map((i) => ItemTile(i)).toList())\n\n'
          'After (lazy, builds only visible items):\n'
          '  ListView.builder(\n'
          '    itemCount: items.length,\n'
          '    itemBuilder: (_, i) => ItemTile(items[i]),\n'
          '  )\n\n'
          'If all items have the same height, add itemExtent. The framework '
          'then skips measuring each child and can jump straight to any '
          'scroll offset. For lists with separators, use '
          'ListView.separated(). For grids, use GridView.builder() or '
          'SliverGrid with a delegate.',
      whenToIgnore:
          'Lists with fewer than about 20 small items have negligible '
          'eager-build cost. Static menus and option lists are fine as '
          'non-lazy lists.',
      relatedIssues: [
        'heavy_compute',
        'layout_bottleneck',
        'non_lazy_shrinkwrap',
        'rebuild_activity',
        'sliver_to_box_adapter_large',
        'sliver_to_box_adapter_shrinkwrap',
      ],
    ),

    'non_lazy_shrinkwrap': (
      displayName: 'ShrinkWrap list in Column',
      category: IssueCategory.build,
      whatItIs:
          'Sleuth found a ListView or GridView with shrinkWrap: true inside a '
          'Column or Row. ShrinkWrap sizes the list to its content, so every '
          'child is built and laid out up front, even far off-screen and '
          'even when the list uses a builder.',
      readingTheData:
          'Like unpacking every box in a moving truck to measure how much '
          'floor space they need.\n\n'
          '• Child count is the number of items in the shrinkWrapped list. '
          'Sleuth raises the issue above 20 items, or for a builder with no '
          'itemCount. It turns critical above 100.\n\n'
          '• Widget type shows ListView or GridView, and whether the enclosing '
          'Flex is a Column or a Row.\n\n'
          '• Sleuth finds this with a structural tree walk.',
      whyItMatters:
          'This pattern usually comes from a header above a list in a '
          'scrolling Column. It works, but a 500-item list builds all 500 '
          'items on first layout and on every relayout. Users see a slow '
          'screen entry and dropped frames while scrolling.',
      howToFix:
          'Turn the Column into a sliver list. Use a CustomScrollView with '
          'the header in a SliverToBoxAdapter and the items in a '
          'SliverList.builder:\n'
          '  CustomScrollView(slivers: [\n'
          '    SliverToBoxAdapter(child: Header()),\n'
          '    SliverList.builder(itemCount: items.length, '
          'itemBuilder: (_, i) => ItemTile(items[i])),\n'
          '  ])\n\n'
          'Or put the header as item 0 of one ListView.builder and drop '
          'shrinkWrap.',
      whenToIgnore:
          'Short lists (20 items or fewer) cost little to build eagerly. A '
          'shrinkWrap list with a bounded height (inside Expanded or a sized '
          'box) builds only what fits, and Sleuth does not report it.',
      relatedIssues: [
        'jank_detected',
        'non_lazy_list',
        'sliver_to_box_adapter_shrinkwrap',
      ],
    ),

    // ── Structural: Image Memory ──────────────────────────────────────────
    'uncached_images': (
      displayName: 'Oversized images',
      category: IssueCategory.memory,
      whatItIs:
          'The app decoded images at a higher resolution than their display '
          'box needs. Sleuth pairs each Image with the picture it renders and '
          'compares the decoded pixel size with the box size times the '
          'device pixel ratio.',
      readingTheData:
          'Like printing a billboard-sized poster to hang on a fridge. The '
          'resolution is wasted and the paper costs a fortune.\n\n'
          '• Ratio is decoded pixels over needed pixels on the smaller axis, '
          'so a BoxFit.cover crop does not count as waste. An image counts '
          'at 1.5 times or more.\n\n'
          '• Widgets that show the same image cache entry share one decode. '
          'Sleuth counts that decode once, against the largest size any of '
          'those widgets needs, and the entry says how many widgets show '
          'it.\n\n'
          '• Wasted memory is 4 bytes for each pixel decoded beyond the '
          'pixels needed, summed over the distinct decodes counted. The '
          'alert starts at 1 MiB of total waste and turns critical at 16 '
          'MiB.\n\n'
          '• Each entry lists the decoded size in pixels and the display '
          'size in dp with the device pixel ratio.\n\n'
          '• Sleuth finds this with a structural tree walk over decoded '
          'images.',
      whyItMatters:
          'A 4000 by 3000 photo decoded at full resolution uses about 48MB '
          'of memory (width times height times 4 bytes). Shown in a 200 by '
          '150 widget at a device pixel ratio of 3, it needs about 1MB, so '
          'about 47MB is wasted. In a list of many different images, this '
          'can use hundreds of megabytes of native memory.',
      howToFix:
          'Add cacheWidth, cacheHeight or both to decode at display size. '
          'Use the device pixel ratio for sharp rendering: '
          'cacheWidth: (200 * MediaQuery.devicePixelRatioOf(context)).round(). '
          'For CachedNetworkImage, use memCacheWidth/memCacheHeight.\n\n'
          'You can also wrap the ImageProvider in ResizeImage to resize at '
          'the provider level:\n'
          '  Image(image: ResizeImage(NetworkImage(url), width: 600))\n\n'
          'ResizeImage works with any ImageProvider and resizes before '
          'caching, which saves both memory and decode time.',
      whenToIgnore:
          'Images that will be shown larger later (zoom, a hero transition '
          'to a full-screen view) may need the full decode. Sleuth does not '
          'report images drawn with BoxFit.none, centerSlice or repeat, '
          'ResizeImage providers, or BoxDecoration images. SVG and vector '
          'images are not affected.',
      relatedIssues: [
        'gc_pressure',
        'heap_growing',
        'heap_near_capacity',
        'native_memory_growing',
      ],
    ),

    // ── Structural: GlobalKey ─────────────────────────────────────────────
    'excessive_global_keys': (
      displayName: 'Excessive GlobalKeys (legacy)',
      category: IssueCategory.build,
      whatItIs:
          'Sleuth no longer detects this issue. Its detector was removed in '
          '0.20.0, and this entry stays so snapshots from earlier versions '
          'keep their explanation. '
          'Sleuth found {count} GlobalKey instances inside {widgetName}. '
          'Each GlobalKey holds a persistent reference to its Element across '
          'the whole app.',
      readingTheData:
          'Like giving every student in a school a master key. Each key '
          'grants global access, and managing hundreds of them becomes a '
          'security and logistics nightmare.\n\n'
          '• GlobalKey count is the total number of GlobalKeys in the '
          'scanned subtree. Under 5 is normal. The threshold is more than 10 '
          'GlobalKeys (default, configurable).\n\n'
          '• Location shows whether the keys are inside a scrollable (worse) '
          'or at page level (expected).\n\n'
          '• Sleuth found this with a structural tree walk.',
      whyItMatters:
          'GlobalKeys are expensive. They stop the framework from recycling '
          'Elements efficiently during scroll, force global registry '
          'lookups, and can cause subtle bugs when two widgets try to use '
          'the same GlobalKey at once.',
      howToFix:
          'Replace GlobalKey with ValueKey or ObjectKey to identify list '
          'items. Use GlobalKey only when you need to preserve state across '
          'the tree, for example when moving a widget between parents. For '
          'form validation, use a single GlobalKey<FormState> instead of a '
          'key per field.',
      whenToIgnore:
          'A few GlobalKeys (under 5) at the page level are normal and '
          'expected (Form, Navigator, Scaffold).',
      relatedIssues: ['global_key_recreation'],
    ),

    // ── Structural: Nested Scroll ─────────────────────────────────────────
    'nested_scroll': (
      displayName: 'Nested scrollables (legacy)',
      category: IssueCategory.build,
      whatItIs:
          'Sleuth no longer detects this issue. Its detector was removed in '
          '0.20.0, and this entry stays so snapshots from earlier versions '
          'keep their explanation. '
          '{widgetName} is nested inside another scrollable widget. The '
          'inner scroll view receives gesture events that the outer one also '
          'wants to handle.',
      readingTheData:
          'Like putting a treadmill on a moving walkway. Both try to control '
          'your direction, and the result is unpredictable.\n\n'
          '• Nesting depth is the number of scrollable ancestors. 1 (a '
          'single scroll) is normal. The threshold is 2 or more nested '
          'scrollables.\n\n'
          '• For the axis relationship, same-axis nesting (both vertical) is '
          'worse than cross-axis nesting (horizontal inside vertical).\n\n'
          '• Sleuth found this with a structural tree walk.',
      whyItMatters:
          'Nested scrollables with conflicting axes confuse users, who '
          'cannot predict which scroll view will respond. Same-axis nesting '
          'makes the inner list build all its children eagerly, which loses '
          'the lazy benefits, or causes scroll physics conflicts.',
      howToFix:
          'For same-axis nesting, convert the inner ListView to a SliverList '
          'inside a CustomScrollView. For cross-axis nesting (horizontal '
          'inside vertical), give the inner scrollable a fixed height, and '
          'use NeverScrollableScrollPhysics if the inner list should not '
          'scroll on its own.',
      whenToIgnore:
          'Intentional cross-axis scrolling (for example, a horizontal '
          'carousel inside a vertical page) with explicit height constraints '
          'is fine.',
      relatedIssues: ['layout_bottleneck', 'rebuild_activity'],
    ),

    'nested_scroll_same_axis': (
      displayName: 'Same-axis nested scroll (legacy)',
      category: IssueCategory.build,
      whatItIs:
          'Sleuth no longer detects this issue. Its detector was removed in '
          '0.20.0, and this entry stays so snapshots from earlier versions '
          'keep their explanation. '
          'Two scrollable widgets with the same scroll axis (both vertical '
          'or both horizontal) are nested. This is a stronger signal than '
          'general nested scrolling, because same-axis nesting almost always '
          'points to a structural problem.',
      readingTheData:
          'Like two escalators stacked on top of each other that both try to '
          'carry you in the same direction. The inner one fights the outer '
          'one for control.\n\n'
          '• Inner list type is the nested scrollable widget (ListView, '
          'SingleChildScrollView, GridView). ShrinkWrap is often forced.\n\n'
          '• Both scrollables share the same axis (vertical in vertical, or '
          'horizontal in horizontal). Any same-axis nesting counts.\n\n'
          '• Sleuth found this with a structural tree walk.',
      whyItMatters:
          'Same-axis nested scrollables cause three problems. The inner list '
          'builds all children eagerly (ShrinkWrap), which defeats lazy '
          'construction. Scroll physics get confusing, and the user cannot '
          'tell which list is scrolling. Infinite height constraint errors '
          'can also occur.',
      howToFix:
          'Move to a CustomScrollView with slivers:\n\n'
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
          'If the inner list must stay a separate widget, add '
          'NeverScrollableScrollPhysics() to turn off its own scrolling and '
          'let the outer controller drive it.',
      whenToIgnore: null,
      relatedIssues: [
        'layout_bottleneck',
        'rebuild_activity',
        'sliver_fill_remaining_scrollable',
      ],
    ),

    // ── Structural: Opacity ───────────────────────────────────────────────
    'opacity_zero': (
      displayName: 'Opacity zero (legacy)',
      category: IssueCategory.layout,
      whatItIs:
          'Sleuth no longer detects this issue. Its detector was removed in '
          '0.20.0, and this entry stays so snapshots from earlier versions '
          'keep their explanation. '
          'Sleuth found an Opacity or AnimatedOpacity widget with value 0.0. '
          'Although it is fully invisible, the child widget is still built, '
          'laid out, painted, hit-tested, and included in the semantics '
          'tree.',
      readingTheData:
          'Like paying a full-time employee to sit in an office with the '
          'lights off. They do all the work but produce nothing anyone can '
          'see.\n\n'
          '• Opacity value is the literal opacity. The threshold is exactly '
          '0.0.\n\n'
          '• Child subtree cost is the descendant count below the Opacity '
          'widget. Larger subtrees waste more resources when invisible. The '
          'normal waste is 0 widgets, and any subtree at opacity 0.0 '
          'counts.\n\n'
          '• Sleuth found this with a structural tree walk.',
      whyItMatters:
          'An invisible Opacity widget wastes all four pipeline phases '
          '(build, layout, paint, raster) and allocates a saveLayer GPU '
          'buffer. Screen readers also announce the invisible content to '
          'accessibility users.',
      howToFix:
          'Replace Opacity(opacity: 0.0) with Visibility(visible: false) to '
          'skip paint and hit-testing. Visibility gives fine-grained control '
          'through flags:\n\n'
          '• maintainSize: true keeps the widget\'s space in layout (like CSS '
          'visibility: hidden). false collapses the space.\n'
          '• maintainState: true keeps the State object alive, so it resumes '
          'where it left off when it becomes visible again.\n'
          '• maintainAnimation: true keeps animations ticking while '
          'invisible, so they are at the correct frame when revealed.\n\n'
          'For animated show and hide, use AnimatedSwitcher or '
          'FadeTransition, which can remove the child entirely when opacity '
          'reaches zero.',
      whenToIgnore:
          'Opacity values near 0 in the middle of an animation are expected '
          'during fade transitions. This detection targets static 0.0 values '
          'only.',
      relatedIssues: ['expensive_gpu_nodes'],
    ),

    // ── Structural: Layout ────────────────────────────────────────────────
    'layout_bottleneck': (
      displayName: 'Layout bottleneck',
      category: IssueCategory.layout,
      whatItIs:
          'Sleuth found IntrinsicHeight or IntrinsicWidth widgets in the '
          'tree. These widgets force a two-pass layout. The first pass '
          'measures the child\'s intrinsic dimensions, and the second lays '
          'it out with those constraints.',
      readingTheData:
          'Like measuring a room twice before placing each piece of '
          'furniture. The extra measuring pass adds work every time.\n\n'
          '• A single IntrinsicHeight or IntrinsicWidth is a warning with '
          'possible confidence, because its cost depends on subtree size. '
          'Nesting one inside another is critical with likely confidence. '
          'Frame jank on the same screen lifts a single intrinsic to likely. '
          'There is no subtree-size gate.\n\n'
          '• Sleuth does not report the IntrinsicWidth and IntrinsicHeight '
          'widgets that the framework builds for ToggleButtons, MenuBar, '
          'linear landscape BottomNavigationBar labels, AlertDialog, '
          'SimpleDialog, popup menus, CupertinoContextMenu, and Scaffold '
          'footer buttons, and they do not count toward nesting.\n\n'
          '• Subtree size is the number of descendants under the intrinsic '
          'widget. Larger subtrees make the extra measuring pass cost '
          'more.\n\n'
          '• Sleuth finds this with a structural tree walk.',
      whyItMatters:
          'Intrinsic sizing adds a speculative measuring pass on top of '
          'normal layout for the affected subtree. When nested '
          '(IntrinsicHeight containing IntrinsicWidth), each level measures '
          'the levels below it again, so the cost grows with depth.',
      howToFix:
          'Replace IntrinsicHeight with explicit height constraints from '
          'the parent (SizedBox, ConstrainedBox). For equal-height rows, '
          'use Table or CrossAxisAlignment.stretch in a Row with Expanded '
          'children. For text-dependent heights, measure text once with '
          'TextPainter and pass the result as a constraint.',
      whenToIgnore:
          'A single IntrinsicHeight around a small subtree (under 20 '
          'widgets) has negligible cost. The concern is nesting or wrapping '
          'large subtrees.',
      relatedIssues: [
        'jank_detected',
        'nested_scroll',
        'nested_scroll_same_axis',
        'non_lazy_list',
        'rebuild_activity',
        'setstate_scope',
        'sustained_jank',
        'wrap_layout_bottleneck',
      ],
    ),

    // ── Structural: CustomPainter ─────────────────────────────────────────
    'always_repaint_painter': (
      displayName: 'Always-repaint painter',
      category: IssueCategory.paint,
      whatItIs:
          'Sleuth found a CustomPainter whose shouldRepaint() always returns '
          'true. This forces the framework to repaint the widget every '
          'frame, whether or not its visual state changed.',
      readingTheData:
          'Like a security camera that records around the clock even when '
          'nothing moves. It fills storage with identical frames.\n\n'
          '• shouldRepaint always returns true here. A well-behaved painter '
          'returns false when its inputs are unchanged. Sleuth reports any '
          'unconditional true.\n\n'
          '• Paint complexity is the number of drawing operations in the '
          'painter. More operations mean more wasted GPU work per '
          'unnecessary repaint. Sleuth reports every always-repaint '
          'painter.\n\n'
          '• Sleuth finds this with a structural tree walk.',
      whyItMatters:
          'Always-repaint painters create unnecessary paint work every '
          'frame. For complex painters with many drawing operations, this '
          'wastes GPU time and keeps the raster cache from working.',
      howToFix:
          'Override shouldRepaint() to compare the fields that affect '
          'painting: return old.color != color || old.progress != progress. '
          'Return true only when the visual output would change. If an '
          'animation drives the painter, use AnimatedBuilder with a child '
          'parameter to separate animated and static content.',
      whenToIgnore:
          'Painters that change every frame (real-time visualizations, '
          'particle systems) need shouldRepaint to return true.',
      relatedIssues: [
        'excessive_repaint',
        'excessive_repaint_debug',
        'raster_dominance',
      ],
    ),

    'frequent_repaint_painter': (
      displayName: 'Frequent repaint painter',
      category: IssueCategory.paint,
      whatItIs:
          'A CustomPainter is repainting at a high frequency. Its '
          'shouldRepaint() may be implemented, but it returns true too '
          'often because the painter\'s inputs change rapidly.',
      readingTheData:
          'Like a painter who checks their work every 5 seconds and touches '
          'something up each time. The constant small changes add up to a '
          'lot of effort.\n\n'
          '• Repaint rate is how many frames per second the busiest '
          'CustomPaint was the likely origin of a repaint (debug callbacks), '
          'excluding repaints driven by an animation owner. Sleuth does not '
          'count paints the CustomPaint made only because something else '
          'in its layer repainted, since those never reach shouldRepaint(). Under 10/sec '
          'is normal. Sleuth raises the issue above 30/sec (fixed '
          'threshold).\n\n'
          '• Input change rate is how fast the painter\'s Listenable or '
          'fields change. Fast-changing inputs drive a high repaint '
          'rate.\n\n'
          '• Sleuth finds this with a structural tree walk.',
      whyItMatters:
          'Frequent repainting of complex painters can dominate raster '
          'thread time. Each repaint records all drawing commands and sends '
          'them through the rendering pipeline.',
      howToFix:
          'Change the painter\'s inputs less often. If an animation drives '
          'it, check whether the animation tick rate can be lower or whether '
          'some paint operations can be cached. Use RepaintBoundary to keep '
          'the painter\'s repaints from spreading to parent layers.',
      whenToIgnore:
          'Painters used for active animations (progress indicators, '
          'waveforms) repaint often by design.',
      relatedIssues: ['excessive_repaint', 'raster_dominance'],
    ),

    // ── Structural: Keep Alive ────────────────────────────────────────────
    'excessive_keep_alive': (
      displayName: 'Excessive KeepAlive',
      category: IssueCategory.memory,
      whatItIs:
          '{count} pages or tab contents use AutomaticKeepAliveClientMixin '
          'to stay alive when scrolled off-screen or when tabs switch. Each '
          'kept-alive subtree stays in memory with its full State.',
      readingTheData:
          'Like keeping every room in a hotel lit and heated when only 2 of '
          '20 rooms have guests. The energy bill grows with every empty room '
          'kept "ready."\n\n'
          '• KeepAlive count is the number of kept-alive tabs or pages. 2 or '
          '3 is normal. Sleuth raises the issue at more than 5 kept-alive '
          'subtrees (default, configurable).\n\n'
          '• Each kept-alive page keeps its full widget and element tree, '
          'controllers and cached data in memory.\n\n'
          '• The issue id `excessive_keep_alive:<Type>~<part>` names the '
          'PageView or TabBarView. The part is `k-` plus its string or '
          'number ValueKey (`~k-feed`), or its position among unkeyed '
          'scrollables of that type (`~1` is the first in the tree). Two '
          'with the same part get `-2`, `-3`. With a ValueKey, the id and '
          'any hide stay stable when the layout changes.\n\n'
          '• Sleuth finds this with a structural tree walk.',
      whyItMatters:
          'Keep-alive subtrees use memory even when invisible. With many '
          'tabs or pages kept alive, the app holds on to large widget and '
          'element trees, image caches and controller state that it would '
          'otherwise free.',
      howToFix:
          'Remove KeepAlive from pages that are cheap to rebuild. Keep it '
          'only for pages with expensive initialization (network-loaded '
          'content, complex scroll positions). Consider lazy initialization, '
          'where pages load data only when first viewed and rely on a cache '
          'layer instead of keeping the widget alive.',
      whenToIgnore:
          'A few keep-alive tabs (2 or 3) are a reasonable trade-off between '
          'memory and user experience (instant tab switching).',
      relatedIssues: ['heap_growing', 'heap_near_capacity'],
    ),

    // ── Structural: AnimatedBuilder ───────────────────────────────────────
    'animated_builder_no_child': (
      displayName: 'AnimatedBuilder without child (legacy)',
      category: IssueCategory.build,
      whatItIs:
          'Sleuth no longer detects this issue. Its detector was removed in '
          '0.20.0, and this entry stays so snapshots from earlier versions '
          'keep their explanation. '
          '{widgetName} does not use the child parameter. The whole subtree '
          'inside the builder callback rebuilds on every animation tick (60 '
          'times per second).',
      readingTheData:
          'Like reprinting a whole newspaper every hour to update the clock '
          'in the corner. 99% of the content is unchanged.\n\n'
          '• Subtree size is the number of descendants rebuilt on every '
          'animation tick. 0 (child parameter used) is normal. The threshold '
          'is more than 5 descendants rebuilt per tick without a child.\n\n'
          '• Animation rate is typically 60 ticks/sec, so the subtree '
          'rebuilds 60 times per second.\n\n'
          '• Sleuth found this with a structural tree walk.',
      whyItMatters:
          'Without the child optimization, every animation frame rebuilds '
          'the whole widget subtree inside the builder, including static '
          'content that does not depend on the animation value. For complex '
          'subtrees, that means 60 expensive rebuilds per second.',
      howToFix:
          'Pass static widgets through the child parameter. The framework '
          'builds the child widget once, caches the resulting Element '
          'subtree, and passes the pre-built widget to the builder callback '
          'on every animation tick. Because the same widget instance is '
          'reused, the framework skips the diff and rebuild for that whole '
          'subtree. Only the wrapping transform, opacity or alignment '
          'updates each frame:\n\n'
          'AnimatedBuilder(\n'
          '  animation: controller,\n'
          '  child: const ExpensiveChild(), // built once, cached\n'
          '  builder: (context, child) => Transform.rotate(\n'
          '    angle: controller.value,\n'
          '    child: child, // reused each frame, no rebuild\n'
          '  ),\n'
          ')',
      whenToIgnore:
          'If the whole subtree depends on the animation value (for example, '
          'a canvas that redraws based on progress), the child parameter '
          'gives no benefit.',
      relatedIssues: [
        'excessive_repaint',
        'excessive_repaint_debug',
        'rebuild_activity',
      ],
    ),

    // ── Structural: Font Loading ──────────────────────────────────────────
    'multiple_custom_fonts': (
      displayName: 'Multiple custom fonts',
      category: IssueCategory.font,
      whatItIs:
          'The app uses several custom (non-system) fonts. A custom font '
          'must load from assets or the network before it can render. Until '
          'it loads, Flutter shows invisible text (FOIT) or a fallback '
          'font.',
      readingTheData:
          'Like a printing press that needs a different set of metal type '
          'for each language. Loading and switching between sets takes time '
          'and storage.\n\n'
          '• Font family count is the number of distinct custom font '
          'families. 1 or 2 is normal. Sleuth raises the issue at more than '
          '3 custom font families. It does not count platform system '
          'families (Roboto, SF Pro, CupertinoSystemText, Segoe UI) or icon '
          'fonts. A `packages/<pkg>/` family and its bare name count once, '
          'and so do google_fonts weight variants of one family.\n\n'
          '• Each font file is typically 50 to 500KB, and each extra weight '
          'adds to the cost.\n\n'
          '• Sleuth finds this with a structural tree walk.',
      whyItMatters:
          'Each custom font adds to app bundle size and initial load time. '
          'If fonts load asynchronously, text flashes from the fallback to '
          'the custom font (FOUT), which is jarring. More fonts make this '
          'worse.',
      howToFix:
          'Use as few custom font families as you can. Use font subsetting '
          'in pubspec.yaml to include only the characters you need. Preload '
          'fonts at app startup with FontLoader. Consider system fonts for '
          'body text and custom fonts for headings only.',
      whenToIgnore:
          'Apps with strong brand requirements may need several custom '
          'fonts. If the fonts are bundled in the app (not loaded over the '
          'network), the runtime cost after first render is small.',
      relatedIssues: ['jank_detected', 'sustained_jank'],
    ),

    // ── Structural: RepaintBoundary ───────────────────────────────────────
    'missing_repaint_boundary': (
      displayName: 'Missing RepaintBoundary',
      category: IssueCategory.paint,
      whatItIs:
          'Sleuth found an expensive GPU widget (CustomPainter, '
          'BackdropFilter, ShaderMask, or similar) without a RepaintBoundary '
          'ancestor. Without the boundary, repaints spread up to the nearest '
          'existing boundary and can repaint a large parent region.',
      readingTheData:
          'Like a paint spill with no containment. Without a tarp (the '
          'boundary), the spill spreads across the whole floor.\n\n'
          '• Expensive widget type is the GPU-heavy widget that lacks a '
          'boundary (CustomPainter, BackdropFilter, ShaderMask). Sleuth '
          'reports any expensive widget without a nearby '
          'RepaintBoundary.\n\n'
          '• Propagation distance is how far repaints travel up the tree '
          'before they reach an existing boundary. The farther they travel, '
          'the more work is wasted.\n\n'
          '• Confidence is possible from the tree walk, and likely when debug '
          'callbacks show more than 10 paints/sec for the same widget type. '
          'It is never confirmed, because paint counts are per type and '
          'cannot be tied to the specific unprotected instance.\n\n'
          '• Sleuth finds this with a structural tree walk.',
      whyItMatters:
          'When expensive paint operations share a repaint boundary with '
          'cheaper content, any change to either region repaints everything. '
          'A RepaintBoundary isolates the expensive region so it repaints '
          'only when its own content changes.',
      howToFix:
          'Wrap the expensive widget in a RepaintBoundary:\n'
          'RepaintBoundary(\n'
          '  child: CustomPaint(painter: myExpensivePainter),\n'
          ')\n'
          'This creates a separate compositing layer. The engine caches it '
          'and re-rasterizes it only when the painter marks itself as '
          'needing repaint.\n\n'
          'Do not add a RepaintBoundary everywhere. Each boundary is a '
          'separate layer that costs compositing work every frame, and it '
          'pays off only when the subtree repaints independently of its '
          'parent. Boundaries around static content that rarely repaints '
          'add that cost with no benefit. Check with '
          'debugPaintLayerBordersEnabled before and after to confirm the '
          'boundary reduces the repaint area.',
      whenToIgnore:
          'If the expensive widget already repaints rarely (static '
          'content), or the parent boundary is already small, another '
          'RepaintBoundary adds layer overhead with no benefit.',
      relatedIssues: [
        'excessive_repaint',
        'excessive_repaint_boundary',
        'excessive_repaint_debug',
        'raster_dominance',
        'repaint_debug',
      ],
    ),

    // ── Network ───────────────────────────────────────────────────────────
    'slow_request': (
      displayName: 'Slow request',
      category: IssueCategory.network,
      whatItIs:
          'An HTTP request took longer than the configured threshold '
          '(default: 1000 ms warning, 3000 ms critical) to complete. The '
          'total time includes DNS resolution, TCP handshake, TLS '
          'negotiation, server processing, and response transfer.',
      readingTheData:
          'Like ordering food and waiting 20 minutes for the waiter to come '
          'back. The kitchen might be slow, or the waiter took a '
          'detour.\n\n'
          '• Request duration is the total time from request start to '
          'response complete. Under 500ms is normal. Sleuth warns at 1000ms '
          'or more and marks it critical at 3000ms or more (defaults, '
          'configurable via SleuthConfig.slowRequestThresholdMs and '
          'criticalSlowRequestThresholdMs).\n\n'
          '• The title shows the slowest URL and its duration.\n\n'
          '• The data comes from HTTP client instrumentation.',
      whyItMatters:
          'Slow network requests block UI updates that depend on the '
          'response. Users see loading spinners, empty screens or stale '
          'data. If the app makes the request during a frame callback (bad '
          'practice), it can cause jank directly.',
      howToFix:
          'Find out whether the slowness is on the server or the network. '
          'Add response caching to avoid repeated slow requests. Use '
          'optimistic UI updates where possible. For large payloads, '
          'consider pagination or streaming. Use a timeout with a fallback '
          'UI so the screen never stays in a loading state forever.',
      whenToIgnore:
          'Cold-start requests (the first request after app launch) are '
          'often slower because of DNS and connection setup. File uploads '
          'take longer by nature.',
      relatedIssues: ['heavy_compute'],
    ),

    'large_response': (
      displayName: 'Large response',
      category: IssueCategory.network,
      whatItIs:
          'An HTTP response exceeded the configured size threshold (default: '
          '1MB). Large responses use memory during download and take a lot '
          'of CPU time to parse.',
      readingTheData:
          'Like ordering a single book and receiving the whole encyclopedia. '
          'You got what you needed, buried under data you will never '
          'read.\n\n'
          '• Response size is the measured body bytes as received. Under '
          '200KB is normal for API responses. Sleuth raises the issue above '
          '1MB (default, configurable).\n\n'
          '• The title shows the count and the largest response. The detail '
          'lists each URL.\n\n'
          '• The data comes from HTTP client instrumentation.',
      whyItMatters:
          'Large JSON payloads parsed on the main isolate cause jank. A 1MB '
          'JSON response can take 50 to 200ms to decode, which blocks '
          'several frames. The raw response bytes also add to memory '
          'pressure during download.',
      howToFix:
          'Request only the data you need. Use pagination, field filtering '
          'or GraphQL to reduce payload size. Parse large responses in a '
          'background isolate with Isolate.run() or compute(). For image or '
          'file downloads, stream to disk instead of buffering in memory.',
      whenToIgnore:
          'Sleuth skips image, video, audio and font responses. Other file '
          'downloads (for example, application/octet-stream) are expected '
          'to be large. Focus on API and JSON responses that you could '
          'trim.',
      relatedIssues: ['heavy_compute'],
    ),

    'request_frequency': (
      displayName: 'Request frequency',
      category: IssueCategory.network,
      whatItIs:
          'The app is making HTTP requests at a rate above the configured '
          'threshold (default: 30 per 5-second window). This suggests '
          'rapid-fire API calls, such as unbatched list loading, polling '
          'without throttling, or duplicate requests.',
      readingTheData:
          'Like calling the same store 30 times in 5 minutes to ask about '
          'different items, when one call with a list would be far '
          'faster.\n\n'
          '• Requests per window is the number of HTTP requests in a '
          '5-second sliding window. Under 10 per window is normal. Sleuth '
          'raises the issue at more than 30 per 5 seconds (default, '
          'configurable).\n\n'
          '• Bursts during page load are expected. Sustained high frequency '
          'is the concern.\n\n'
          '• The data comes from HTTP client instrumentation.',
      whyItMatters:
          'High request frequency wastes battery and bandwidth. Each request '
          'has connection overhead, and response processing competes with '
          'UI work for CPU time. Servers may also rate-limit or throttle '
          'aggressive clients.',
      howToFix:
          'Batch or debounce repeated requests. Combine multiple item '
          'fetches into a single list endpoint. Add request deduplication so '
          'identical requests are never in flight at the same time. For '
          'polling, use exponential backoff, or use WebSocket or SSE for '
          'real-time updates instead.',
      whenToIgnore:
          'Initial screen loads that fetch several independent resources in '
          'parallel may spike request frequency briefly. A one-time burst '
          'like this is acceptable.',
      relatedIssues: ['http_error_spike', 'rebuild_activity'],
    ),

    'http_error_spike': (
      displayName: 'HTTP error spike',
      category: IssueCategory.network,
      whatItIs:
          'Several HTTP requests failed (4xx or 5xx status codes) or could '
          'not connect (transport failures) within a 5-second window. This '
          'suggests backend issues, network problems or retry storms.',
      readingTheData:
          'Like a delivery truck that keeps returning to the warehouse '
          'because the address is wrong. Each failed trip wastes fuel and '
          'time.\n\n'
          '• Error count is the number of HTTP responses with status 400 or '
          'higher, or connection failures (status -1), in a 5-second window. '
          'Sleuth raises the issue at 3 or more errors.\n\n'
          '• Transport failures are requests that never received a response '
          '(DNS failure, timeout, connection refused). They are worse than '
          '4xx or 5xx errors because the server did no processing.\n\n'
          '• Server errors (5xx) mean the server received the request but '
          'failed to process it. They are often transient and can be '
          'retried.\n\n'
          '• The data comes from HTTP client instrumentation.',
      whyItMatters:
          'Failed requests that trigger automatic retries can create retry '
          'storms, where network traffic grows exponentially and wastes '
          'battery, bandwidth and CPU time. Each retry also holds a '
          'connection from the HTTP client pool, which can delay legitimate '
          'requests. On metered connections, this wastes user data.',
      howToFix:
          'Add exponential backoff with jitter to retry logic. Never retry '
          'immediately or at fixed intervals. Add a circuit breaker that '
          'stops retrying after N consecutive failures and tries again after '
          'a cooldown period. Cache successful responses so the app can '
          'serve stale data during outages. For transport failures, check '
          'connectivity before retrying.',
      whenToIgnore:
          'A brief spike during network transitions (WiFi to cellular) is '
          'expected. Single 4xx errors from user input (a 404 from a bad '
          'URL, a 401 from expired auth) are not a concern on their own.',
      relatedIssues: ['request_frequency'],
    ),

    // ── Platform Channel ──────────────────────────────────────────────────
    'platform_channel_traffic': (
      displayName: 'Platform channel traffic',
      category: IssueCategory.channel,
      whatItIs:
          'Sleuth detected high-frequency platform channel calls. Platform '
          'channels are the bridge between Dart and native code (Android and '
          'iOS). Each call involves serialization, thread switching, and '
          'deserialization.',
      readingTheData:
          'Like passing notes between two classrooms through a narrow '
          'hallway. Each trip takes time, and too many at once create a '
          'traffic jam.\n\n'
          '• Calls/sec is the number of platform channel invocations per '
          'second. Under 5/sec is normal. Sleuth raises the issue above '
          '20/sec (default, configurable) and marks it critical above 2 '
          'times that (more than 40/sec by default). The title counts the '
          'second that raised the card. The card stays for 10 seconds so you '
          'can still read a short burst.\n\n'
          '• Per-call duration shows the max and p95 send-to-reply time in '
          'the window, plus how many calls took more than 8 ms (default, '
          'configurable). It is shown for context and does not trigger the '
          'issue.\n\n'
          '• The data comes from VM timeline channel events (requires '
          '`SleuthConfig(profilePlatformChannels: true)`).',
      whyItMatters:
          'Each platform channel message has about 0.1ms of overhead for '
          'serialization and thread marshaling. At high frequency (100/sec '
          'or more), this overhead adds up and uses part of the frame '
          'budget. Channel calls also block the UI thread while awaiting the '
          'native response.',
      howToFix:
          'Batch multiple values into a single channel call instead of '
          'sending one message per value. For continuous data streams '
          '(sensor data, location updates), use EventChannel with '
          'native-side throttling instead of polling through MethodChannel. '
          'Cache native values on the Dart side to avoid repeated round '
          'trips.\n\n'
          'For any non-trivial channel usage, use Pigeon (code generation) '
          'to generate type-safe Dart and Kotlin or Swift bindings. Pigeon '
          'removes stringly-typed method names, which cause silent failures '
          'when either side renames a method.',
      whenToIgnore:
          'Brief spikes during initialization (plugin setup, permission '
          'checks) are normal. It becomes a concern when high traffic '
          'continues during steady-state interaction.',
      relatedIssues: ['heavy_compute'],
    ),

    // ── v11.20: Missing entries ──────────────────────────────────────────
    'high_frequency_same_path': (
      displayName: 'High-frequency same-path requests',
      category: IssueCategory.network,
      whatItIs:
          'Three or more requests went to the same endpoint within 500 ms. '
          'Sleuth groups records by HTTP method and normalized URL (query '
          'strings stripped), so search-typeahead traffic and pagination '
          'bursts cluster under a single finding. Only idempotent methods '
          '(GET, HEAD, OPTIONS) count. Sleuth ignores POST, PUT and PATCH '
          'bursts on purpose, because they often carry different payloads '
          'to the same URL.',
      readingTheData:
          'Like pressing a doorbell three times in a second because the bell '
          'did not ring fast enough. The server did the same work three '
          'times, and the network paid for it.\n\n'
          '• Count is the number of requests that clustered within the 500 '
          'ms window. 1 or 2 is normal. Sleuth raises the issue at 3 or more '
          'and marks it critical at 10 or more, or when 5 or more of them '
          'got a 5xx status.\n\n'
          '• Fingerprint is the method plus a normalized URL hash that '
          'identifies the cluster. All requests in the cluster share this '
          'fingerprint, so the issue stays stable across scans.\n\n'
          '• The data comes from HTTP client instrumentation (startedAt '
          'timestamps).',
      whyItMatters:
          'High-frequency same-path traffic wastes bandwidth, battery and '
          'server resources. It also multiplies rebuilds. If each response '
          'triggers setState, the widget rebuilds N times with nearly '
          'identical data. On metered connections this costs the user '
          'money. Common root causes are un-debounced typeahead or search '
          'input, fetches triggered from build() or didChangeDependencies() '
          'without a guard, double-tap pull-to-refresh, and pagination that '
          'requests the same page again during fast scroll.',
      howToFix:
          'Pick the fix that matches the root cause. Debounce user-driven '
          'input (300 ms Timer or rxdart throttleTime). Cache responses so '
          'later callers get the cached result. Share a single Future across '
          'widgets (FutureProvider, AsyncNotifier). Or deduplicate at the '
          'repository layer with an in-flight request map keyed by '
          'fingerprint.',
      whenToIgnore:
          'Some bursts are legitimate: analytics beacons, poll loops meant '
          'to run at high frequency, or a streaming replacement that falls '
          'back to short-interval polling. In those cases, suppress the '
          'issue with `SleuthConfig.suppressedIssues`. The detector already '
          'excludes POST, PUT and PATCH, so it never flags non-idempotent '
          'writes.',
      relatedIssues: ['rebuild_activity'],
    ),

    'wrap_layout_bottleneck': (
      displayName: 'Wrap layout bottleneck',
      category: IssueCategory.layout,
      whatItIs:
          'Sleuth found a Wrap widget with many children. Wrap performs O(N) '
          'layout passes to position each child in the flow, and it measures '
          'every child to find the line breaks.',
      readingTheData:
          'Like a shelf stocker who must try every item in every slot to '
          'find the best arrangement. Every extra item means another trial '
          'placement.\n\n'
          '• Child count is the number of children in the Wrap. Sleuth '
          'raises the issue above 30 children (a fixed threshold).\n\n'
          '• Wrap measures and positions each child in sequence and never '
          'skips off-screen items.\n\n'
          '• Sleuth finds this with a structural tree walk.',
      whyItMatters:
          'Wrap layout cost grows linearly with child count, and unlike '
          'ListView, Wrap cannot skip off-screen children. A Wrap with 100 '
          'or more children lays out all of them every frame, even those '
          'scrolled out of view, which makes it a hidden layout bottleneck.',
      howToFix:
          'For large collections of chips, tags or badges, consider a lazy '
          'alternative. Place items in a ListView with rows you compute '
          'yourself, or use a flow-layout package that supports lazy '
          'rendering. For static content, put the Wrap inside a '
          'RepaintBoundary so layout cost does not spread upward.',
      whenToIgnore:
          'Wrap widgets with fewer than about 30 small children (chips, '
          'icons) have negligible layout cost and are fine as they are.',
      relatedIssues: ['layout_bottleneck'],
    ),

    'sliver_to_box_adapter_large': (
      displayName: 'Large SliverToBoxAdapter',
      category: IssueCategory.build,
      whatItIs:
          'Sleuth found a SliverToBoxAdapter wrapping a large subtree inside '
          'a CustomScrollView. SliverToBoxAdapter turns a box widget into a '
          'sliver, but it builds the whole subtree eagerly, with no lazy '
          'construction.',
      readingTheData:
          'Like stuffing a whole filing cabinet into a single folder. The '
          'folder system exists for quick access, and one giant folder '
          'defeats the purpose.\n\n'
          '• Child count is the number of children of the Column (or Row) '
          'inside the SliverToBoxAdapter. Sleuth raises the issue above 50 '
          'children.\n\n'
          '• SliverList.builder is the lazy alternative. It builds only the '
          'visible items instead of all descendants.\n\n'
          '• Sleuth finds this with a structural tree walk.',
      whyItMatters:
          'Unlike SliverList, which builds only visible items, '
          'SliverToBoxAdapter builds its whole child subtree up front. A '
          'large subtree (more than 50 children) defeats the purpose of '
          'using slivers for lazy rendering, and causes a slow first build '
          'and high memory use.',
      howToFix:
          'If the content is a list of items, replace SliverToBoxAdapter('
          'child: Column(children: items)) with SliverList.builder() for '
          'lazy construction. If it is a single large widget, consider '
          'breaking it into several smaller slivers so only the visible '
          'parts are built.',
      whenToIgnore:
          'A SliverToBoxAdapter around a small, fixed-size widget (header, '
          'footer, banner) is the intended use and is fine.',
      relatedIssues: ['non_lazy_list'],
    ),

    'sliver_fill_remaining_scrollable': (
      displayName: 'SliverFillRemaining scrollable',
      category: IssueCategory.build,
      whatItIs:
          'Sleuth found a SliverFillRemaining with a scrollable child '
          '(ListView, SingleChildScrollView, and so on). SliverFillRemaining '
          'sizes its child to fill the remaining viewport space, which '
          'creates a nested scroll conflict.',
      readingTheData:
          'Like two steering wheels in one car. Both can turn, and the '
          'driver never knows which one is in control.\n\n'
          '• Inner scrollable type is the scrollable widget inside '
          'SliverFillRemaining (ListView, SingleChildScrollView, and so '
          'on).\n\n'
          '• hasScrollBody tells whether the sliver expects a scrollable '
          'child. Sleuth reports any scrollable child, whatever the flag '
          'says.\n\n'
          '• Sleuth finds this with a structural tree walk.',
      whyItMatters:
          'A scrollable inside SliverFillRemaining creates competing scroll '
          'physics. The inner scrollable fights the outer CustomScrollView '
          'for gesture ownership. Users see unpredictable scrolling, where '
          'sometimes the inner list scrolls and sometimes the outer one '
          'does.',
      howToFix:
          'Replace SliverFillRemaining(child: ListView(...)) with a '
          'SliverList that contains the items. If you need the "fill '
          'remaining space" behavior, use SliverFillRemaining with '
          'hasScrollBody: false for non-scrollable content, or restructure '
          'so the inner content takes part in the outer scroll through '
          'slivers.',
      whenToIgnore:
          'SliverFillRemaining with hasScrollBody: true is intentional when '
          'you want the inner scrollable to take over scrolling after the '
          'outer slivers finish scrolling.',
      relatedIssues: ['nested_scroll_same_axis'],
    ),

    'sliver_to_box_adapter_shrinkwrap': (
      displayName: 'ShrinkWrap inside sliver',
      category: IssueCategory.build,
      whatItIs:
          'Sleuth found a ListView or GridView with shrinkWrap: true inside a '
          'SliverToBoxAdapter. ShrinkWrap forces the list to measure all '
          'children to find its own size, which removes lazy construction.',
      readingTheData:
          'Like measuring every book with a tape measure to work out the '
          'shelf height, instead of stacking the books as they fit.\n\n'
          '• Child count is the number of items in the shrinkWrapped list. '
          'Under 10 is normal. Sleuth raises the issue above 20 items with '
          'shrinkWrap inside a sliver, or for a builder with no '
          'itemCount.\n\n'
          '• All children are built and measured up front, which defeats the '
          'lazy rendering that slivers are designed for.\n\n'
          '• Sleuth finds this with a structural tree walk.',
      whyItMatters:
          'shrinkWrap: true builds and measures every child to compute the '
          'list\'s total height. Inside a sliver this is doubly wasteful. You '
          'chose slivers for lazy rendering, and shrinkWrap defeats it. A '
          '500-item shrinkWrapped list builds all 500 items.',
      howToFix:
          'Replace SliverToBoxAdapter(child: ListView(shrinkWrap: true, '
          'children: items)) with SliverList.builder(itemBuilder: ..., '
          'itemCount: items.length). This gives real lazy construction '
          'within the CustomScrollView\'s viewport. If the items have a '
          'known fixed height, add itemExtent. The framework can then skip '
          'child measurement entirely and jump straight to any scroll '
          'offset.',
      whenToIgnore:
          'Very small lists (under 10 items) with fixed-height items have '
          'negligible shrinkWrap cost.',
      relatedIssues: ['non_lazy_list', 'non_lazy_shrinkwrap'],
    ),

    'global_key_recreation': (
      displayName: 'GlobalKey recreation (legacy)',
      category: IssueCategory.build,
      whatItIs:
          'Sleuth no longer detects this issue. Its detector was removed in '
          '0.20.0, and this entry stays so snapshots from earlier versions '
          'keep their explanation. '
          'The code creates a GlobalKey inside a build() method or another '
          'frequently called code path. Each call creates a new GlobalKey '
          'instance, which unregisters the old key and registers the new one '
          'in the global registry.',
      readingTheData:
          'Like issuing someone a new passport every time they cross a '
          'border. The old one becomes invalid, the new one must be '
          'registered, and their travel history is lost.\n\n'
          '• Recreation frequency is how often the GlobalKey is recreated. 0 '
          '(created once) is normal. Any recreation counts.\n\n'
          '• Each recreation destroys the associated State object and loses '
          'scroll position, form input and animation progress.\n\n'
          '• Sleuth found this with a structural tree walk.',
      whyItMatters:
          'GlobalKey recreation forces the framework to detach and reattach '
          'the Element on every rebuild, which destroys all State (including '
          'scroll position, animation progress and form input). It also '
          'triggers a full subtree rebuild instead of a diff-based update, '
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
          'Sleuth found too many RepaintBoundary widgets close together. '
          'Each RepaintBoundary creates a separate compositing layer that '
          'the GPU must manage on its own.',
      readingTheData:
          'Like dividing a house into 50 separate climate zones. Each zone '
          'needs its own thermostat and ductwork, and the cost of managing '
          'them all exceeds the energy savings.\n\n'
          '• Boundary count is the number of RepaintBoundary widgets in the '
          'visible region. Under 15 is normal. Sleuth raises the issue above '
          '20 boundaries close together.\n\n'
          '• Each boundary isolates a repaint region in its own layer, and '
          'the raster thread composites that layer every frame on both Skia '
          'and Impeller.\n\n'
          '• Sleuth finds this with a structural tree walk.',
      whyItMatters:
          'Each RepaintBoundary isolates a repaint region in its own '
          'compositing layer. That isolation pays off only when the region '
          'repaints independently. Otherwise each extra layer is pure '
          'compositing cost that the raster thread pays every frame. Beyond '
          'about 15 to 20 boundaries in a visible region, the cost of '
          'managing layers can exceed the savings from isolated '
          'repainting.',
      howToFix:
          'Review where you place RepaintBoundary. Keep boundaries at '
          'natural isolation points (list items, cards, animated regions) '
          'instead of wrapping every widget. Remove boundaries around static '
          'content that rarely or never repaints, because they add layer '
          'overhead with no benefit. Use debugPaintLayerBordersEnabled to '
          'see layer boundaries and find excessive layering.',
      whenToIgnore:
          'The framework adds a RepaintBoundary to scrollable list items '
          'automatically. Those are expected and useful.',
      relatedIssues: ['excessive_repaint', 'missing_repaint_boundary'],
    ),

    'runtime_font_loading': (
      displayName: 'Runtime font loading',
      category: IssueCategory.font,
      whatItIs:
          'A custom font loads at runtime (through FontLoader or the '
          'network) instead of being bundled in the app assets. The font is '
          'unavailable until the download and parsing complete.',
      readingTheData:
          'Like a sign painter who starts on the shop sign only after the '
          'grand opening. Customers see a blank storefront until the work '
          'is done.\n\n'
          '• Load time is the duration from font request to availability. '
          '0ms (bundled) is normal. Sleuth reports any runtime loading '
          '(above 0ms).\n\n'
          '• Font file size is typically 50 to 500KB per font file. Larger '
          'files take longer to download on slow connections.\n\n'
          '• Severity is always a warning with possible confidence. The '
          'signal is a non-empty fontFamilyFallback. A tree scan cannot tell '
          'whether the font is already cached, so more families do not '
          'escalate it.\n\n'
          '• Sleuth finds this with a structural tree walk.',
      whyItMatters:
          'Runtime font loading causes a Flash of Invisible Text (FOIT) or a '
          'Flash of Unstyled Text (FOUT). Text in that font is invisible or '
          'shown in a fallback font until loading completes. On slow '
          'networks this can last several seconds, which is jarring. Each '
          'font file is typically 50 to 500KB.',
      howToFix:
          'Bundle fonts in the app assets through pubspec.yaml instead of '
          'loading them at runtime. If runtime loading is required (for '
          'example, user-selected fonts), preload fonts during a splash '
          'screen or loading state before navigating to content that uses '
          'them. Call FontLoader.load() in an initialization step, and show '
          'a fallback font with a smooth transition when the custom font '
          'becomes available.',
      whenToIgnore:
          'Apps that let users pick fonts (e-readers, design tools) need '
          'runtime loading by design. The concern is unexpected runtime '
          'loading of fonts that could be bundled.',
      relatedIssues: ['jank_detected', 'sustained_jank'],
    ),

    // ── Startup ────────────────────────────────────────────────────────
    'slow_startup_ttff': (
      displayName: 'Slow startup (TTFF)',
      category: IssueCategory.startup,
      whatItIs:
          'The time from the Dart entry point (Sleuth.init()) to the first '
          'frame\'s raster completion exceeds the configured threshold. This '
          'is the cold-start Time-to-First-Frame (TTFF), the time the user '
          'stares at a splash screen or blank canvas before content '
          'appears.',
      readingTheData:
          'Like measuring how long a restaurant takes from unlocking the '
          'door to seating the first customer. Every step from lights-on to '
          'table-ready adds up.\n\n'
          '• TTFF is the wall-clock duration from Sleuth.init() to the first '
          'FrameTiming raster-end timestamp. Under 1500ms is normal. 1500 to '
          '3000ms is a warning, and above 3000ms is critical.\n\n'
          '• First frame breakdown shows the vsync overhead, build phase and '
          'raster phase durations from FrameTiming. The dominant phase shows '
          'where to focus optimization.\n\n'
          '• When the VM timeline is connected, the buildScope, flushLayout, '
          'flushPaint and raster sub-durations give more detail on the first '
          'frame pipeline.\n\n'
          '• ttffMs starts at Sleuth.init() (Dart entry), not at process '
          'start. It leaves out the native phase before Sleuth.init() on '
          'purpose. iOS cold start adds about 400 to 1200ms (dyld, '
          'UIApplicationMain, FlutterEngine, VM bootstrap). Android cold '
          'start adds about 300 to 900ms on mid-range devices and more than '
          '1500ms on budget or Android Go devices (Zygote fork, '
          'Application.onCreate, ContentProvider init, FlutterActivity, '
          'FlutterEngine, VM bootstrap).\n\n'
          '• `flutter run --trace-startup` measures from the engine C++ '
          'entry, so its numbers are larger than ttffMs by the pre-Dart '
          'overhead. For a like-for-like value, read '
          'StartupMetrics.engineTtffMs (from engine start to the first '
          'rasterized frame). For the native-phase gap alone, read '
          'StartupMetrics.preDartOverheadMs. Both are filled in when VM '
          'timeline enrichment runs before the ring buffer evicts the '
          'FlutterEngineMainEnter event.\n\n'
          '• The data comes from SchedulerBinding.addTimingsCallback '
          '(one-shot).',
      whyItMatters:
          'Mobile users expect apps to launch in under 2 seconds. A cold '
          'start of 3 seconds or more is a retention risk. The first frame '
          'is also when the system decides whether to show an '
          'ANR dialog (Android) or terminate the app (iOS watchdog).',
      howToFix:
          'Optimize based on the dominant phase.\n\n'
          'If the build phase dominates, reduce the complexity of the '
          'initial widget tree. Defer below-the-fold content with '
          'FutureBuilder or lazy initialization. Move expensive init logic '
          '(database setup, large JSON parsing) to background isolates.\n\n'
          'If the raster phase dominates, reduce first-frame painting '
          'complexity. Pre-cache large images with precacheImage() in a '
          'splash screen. Avoid shader-heavy effects (blur, gradient) on the '
          'initial route.\n\n'
          'If vsync dominates, do less synchronous work before runApp(). '
          'Defer non-critical plugin initialization to post-first-frame '
          'callbacks with WidgetsBinding.instance.addPostFrameCallback.',
      whenToIgnore:
          'Debug mode cold starts are 3 to 10 times slower than profile mode '
          'because of JIT compilation, asserts and debug checks. Always '
          'measure in profile mode (flutter run --profile). Warm restarts '
          '(hot restart) are also misleading, because the VM is already '
          'initialized.',
      relatedIssues: ['jank_detected', 'heavy_compute'],
    ),
  };
}
