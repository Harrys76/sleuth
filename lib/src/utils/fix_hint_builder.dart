import '../models/performance_issue.dart';

/// Centralised builder for context-aware fix hints.
///
/// Each static method corresponds to a unique issue stableId. When widget-level
/// context (name, ancestor chain, interaction) is available the hint references
/// the specific widget; otherwise it falls back to generic actionable advice.
///
/// Every method returns a `(String hint, FixEffort effort)` record.
class FixHintBuilder {
  FixHintBuilder._();

  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------

  static (String, FixEffort) animatedBuilderNoChild({
    String? widgetName,
    String? ancestorChain,
  }) {
    final location = _locationSuffix(widgetName, ancestorChain);
    return (
      'Pass static widgets via the child parameter$location:\n'
          'AnimatedBuilder(\n'
          '  animation: _controller,\n'
          '  child: const ExpensiveWidget(), // built once\n'
          '  builder: (context, child) => Transform.rotate(\n'
          '    angle: _controller.value,\n'
          '    child: child, // reused, not rebuilt\n'
          '  ),\n'
          ')',
      FixEffort.quick,
    );
  }

  // ---------------------------------------------------------------------------
  // CustomPainterDetector
  // ---------------------------------------------------------------------------

  static (String, FixEffort) alwaysRepaintPainter({
    String? widgetName,
    String? ancestorChain,
  }) {
    final ctx = _contextPrefix(widgetName, ancestorChain);
    return (
      '${ctx}Override shouldRepaint() to compare relevant fields:\n'
          'bool shouldRepaint(MyPainter old) => old.color != color;',
      FixEffort.quick,
    );
  }

  static (String, FixEffort) frequentRepaintPainter({
    String? widgetName,
    String? ancestorChain,
  }) {
    final ctx = _contextPrefix(widgetName, ancestorChain);
    return (
      '${ctx}Override shouldRepaint() to compare only fields that affect '
          'painting:\n'
          'bool shouldRepaint(MyPainter old) => old.color != color;',
      FixEffort.quick,
    );
  }

  // ---------------------------------------------------------------------------
  // FontLoadingDetector
  // ---------------------------------------------------------------------------

  static (String, FixEffort) multipleCustomFonts({
    required int fontCount,
    List<String>? families,
  }) {
    final familyInfo = families != null && families.isNotEmpty
        ? ' (${families.take(3).join(", ")})'
        : '';
    return (
      'Using $fontCount custom font families$familyInfo. '
          'Limit custom fonts to 2-3 families max. '
          "Pre-load fonts using FontLoader or ensure they're "
          'bundled in pubspec.yaml.',
      FixEffort.quick,
    );
  }

  static (String, FixEffort) runtimeFontLoading({
    required int fontCount,
    List<String>? families,
  }) {
    final familyInfo = families != null && families.isNotEmpty
        ? ' (${families.take(3).join(", ")})'
        : '';
    return (
      '$fontCount font${fontCount == 1 ? '' : 's'} loaded at runtime$familyInfo. '
          'Runtime-loaded fonts (e.g. google_fonts) trigger HTTP requests '
          'during first render, causing text flicker.\n'
          'Pre-download with GoogleFonts.pendingFonts() in main(), '
          'or bundle fonts in pubspec.yaml assets.',
      FixEffort.medium,
    );
  }

  // ---------------------------------------------------------------------------
  // FrameTimingDetector
  // ---------------------------------------------------------------------------

  static (String, FixEffort) sustainedJank() {
    return (
      'Check for heavy computations in build(), setState() scope, '
          'or offscreen painting. Run in profile mode:\n'
          'flutter run --profile\n'
          'Then open DevTools > Performance to identify expensive frames.',
      FixEffort.medium,
    );
  }

  static (String, FixEffort) jankDetected() {
    return (
      'Minor jank detected. Use const constructors for static widgets:\n'
          'const MyWidget({super.key});\n'
          'Add RepaintBoundary around expensive subtrees, '
          'or reduce widget tree depth.',
      FixEffort.quick,
    );
  }

  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------

  static (String, FixEffort) excessiveGlobalKeys({required int count}) {
    return (
      '$count GlobalKey instances in scrollable children. '
          'Replace with ValueKey where possible:\n'
          '// Before: key: GlobalKey()\n'
          '// After:  key: ValueKey(item.id)\n'
          'Only use GlobalKey when you need to access widget state '
          'across different parts of the tree.',
      FixEffort.quick,
    );
  }

  static (String, FixEffort) globalKeyRecreation({required int churnCount}) {
    return (
      '$churnCount GlobalKeys recreated between scans.\n'
          'Fixes:\n'
          '  • Store GlobalKeys in State fields, not in build()\n'
          '  • Use late final or initialize in initState()\n'
          '  • Consider ValueKey(item.id) if you only need identity, '
          'not state access',
      FixEffort.quick,
    );
  }

  // ---------------------------------------------------------------------------
  // GpuPressureDetector
  // ---------------------------------------------------------------------------

  static (String, FixEffort) rasterDominance() {
    return (
      'Reduce GPU work per frame:\n'
          '- Replace ClipRRect/ClipPath with Container borderRadius\n'
          '- Avoid overlapping semi-transparent layers\n'
          '- Add RepaintBoundary around animated subtrees\n'
          '- Simplify shadows and gradients',
      FixEffort.involved,
    );
  }

  static (String, FixEffort) expensiveGpuNodes({
    String? widgetName,
    String? ancestorChain,
  }) {
    final ctx = _contextPrefix(widgetName, ancestorChain);
    return (
      '${ctx}Wrap expensive subtrees in RepaintBoundary:\n'
          'RepaintBoundary(child: ${widgetName ?? "ComplexWidget"}(...))\n'
          'Simplify visual effects (shadows, clips, opacity layers).',
      FixEffort.medium,
    );
  }

  // ---------------------------------------------------------------------------
  // FrameTimingDetector — Raster Cache Trends
  // ---------------------------------------------------------------------------

  static (String, FixEffort) rasterCacheThrashing() {
    return (
      'The raster cache is repeatedly allocating and evicting entries. '
          'Use const constructors for stable widgets:\n'
          'const MyWidget({super.key});\n'
          'Avoid rebuilding CustomPainter canvases every frame and '
          'use RepaintBoundary around complex static subtrees.',
      FixEffort.involved,
    );
  }

  static (String, FixEffort) rasterCacheGrowing() {
    return (
      'Raster cache bytes are growing without bound. Check for '
          'dynamically-created widgets with unique paint output, or '
          'animations that create new cache entries per frame. '
          'Limit cache scope:\n'
          'RepaintBoundary(child: DynamicContent(...))\n'
          'Use const constructors for static portions of the tree.',
      FixEffort.involved,
    );
  }

  // ---------------------------------------------------------------------------
  // HeavyComputeDetector
  // ---------------------------------------------------------------------------

  static (String, FixEffort) heavyCompute({
    double? durationMs,
    List<String>? dirtyWidgets,
  }) {
    final prefix = dirtyWidgets != null && dirtyWidgets.isNotEmpty
        ? 'Heavy build involving ${dirtyWidgets.take(3).join(", ")}'
            '${durationMs != null ? " (${durationMs.toStringAsFixed(1)}ms)" : ""}. '
        : '';
    return (
      '${prefix}Move heavy work to a background isolate '
          'using Isolate.run() or compute():\n'
          'final result = await Isolate.run(() => parseJson(data));\n'
          'Avoid synchronous JSON parsing, image processing, '
          'or complex calculations in build().',
      FixEffort.involved,
    );
  }

  // ---------------------------------------------------------------------------
  // ImageMemoryDetector
  // ---------------------------------------------------------------------------

  static (String, FixEffort) uncachedImages({
    required int count,
    String? widgetName,
    String? ancestorChain,
  }) {
    if (widgetName != null) {
      final chain = ancestorChain != null ? ' (via $ancestorChain)' : '';
      return (
        '$count uncached image${count > 1 ? "s" : ""} in $widgetName$chain. '
            'Add cacheWidth and/or cacheHeight to Image widgets in $widgetName:\n'
            'Image.asset("photo.jpg", cacheWidth: 300)',
        FixEffort.quick,
      );
    }
    return (
      'Add cacheWidth and/or cacheHeight to decode images at display size:\n'
          'Image.asset("photo.jpg", cacheWidth: 300)\n'
          'Image.network(url, cacheWidth: 300)\n'
          'Or wrap the provider: ResizeImage(imageProvider, width: 300)',
      FixEffort.quick,
    );
  }

  // ---------------------------------------------------------------------------
  // KeepAliveDetector
  // ---------------------------------------------------------------------------

  static (String, FixEffort) excessiveKeepAlive({
    required int count,
    String? ancestorChain,
  }) {
    final location = ancestorChain != null ? ' in $ancestorChain' : '';
    return (
      '$count keep-alive widgets$location. '
          'Remove AutomaticKeepAliveClientMixin from most items:\n'
          '// Remove: with AutomaticKeepAliveClientMixin\n'
          '// Remove: bool get wantKeepAlive => true;\n'
          'Only keep alive items with expensive state that is '
          'costly to recreate.',
      FixEffort.quick,
    );
  }

  // ---------------------------------------------------------------------------
  // LayoutBottleneckDetector
  // ---------------------------------------------------------------------------

  static (String, FixEffort) layoutBottleneck({
    String? widgetName,
    String? ancestorChain,
  }) {
    if (widgetName != null && ancestorChain != null) {
      return (
        'IntrinsicHeight/Width found in $widgetName ancestor chain '
            '($ancestorChain). Replace with explicit sizing:\n'
            '// Before: IntrinsicHeight(child: Row(...))\n'
            '// After:  Row(crossAxisAlignment: CrossAxisAlignment.stretch, ...)\n'
            'Or use SizedBox/Expanded with known dimensions.',
        FixEffort.medium,
      );
    }
    return (
      'Replace IntrinsicHeight/Width with explicit sizing:\n'
          '// Before: IntrinsicHeight(child: Row(...))\n'
          '// After:  Row(crossAxisAlignment: CrossAxisAlignment.stretch, ...)\n'
          'Or use SizedBox/Expanded with known dimensions.',
      FixEffort.medium,
    );
  }

  // ---------------------------------------------------------------------------
  // LayoutBottleneckDetector — Wrap
  // ---------------------------------------------------------------------------

  static (String, FixEffort) wrapBottleneck({
    required int childCount,
    String? ancestorChain,
  }) {
    final location = ancestorChain != null ? ' ($ancestorChain)' : '';
    return (
      'Wrap with $childCount children is non-virtualized$location. '
          'Consider chunking items into rows manually or using a '
          'GridView.builder for large item counts.',
      FixEffort.medium,
    );
  }

  // ---------------------------------------------------------------------------
  // ListviewDetector
  // ---------------------------------------------------------------------------

  static (String, FixEffort) nonLazyList({
    required int childCount,
    String? widgetName,
    String? ancestorChain,
  }) {
    final location = _locationSuffix(widgetName, ancestorChain);
    return (
      '$childCount children built eagerly$location. '
          'Use ListView.builder() or ListView.separated() '
          'to lazily build visible items only.',
      FixEffort.quick,
    );
  }

  static (String, FixEffort) sliverToBoxAdapterLarge({
    required int childCount,
    required String childType,
    String? ancestorChain,
  }) {
    final location = _locationSuffix(null, ancestorChain);
    return (
      'Replace SliverToBoxAdapter + $childType ($childCount children) with '
          'SliverList.builder for lazy loading$location.',
      FixEffort.medium,
    );
  }

  static (String, FixEffort) sliverFillRemainingScrollable({
    String? ancestorChain,
  }) {
    final location = _locationSuffix(null, ancestorChain);
    return (
      'Use SliverFillRemaining(hasScrollBody: true) when the child is a '
          'scrollable$location. hasScrollBody: false gives unconstrained '
          'height, forcing the scrollable child to shrinkWrap and build '
          'all children eagerly.',
      FixEffort.quick,
    );
  }

  static (String, FixEffort) sliverToBoxAdapterShrinkWrap({
    required String scrollableType,
    String? ancestorChain,
  }) {
    final location = _locationSuffix(null, ancestorChain);
    return (
      'Replace SliverToBoxAdapter + $scrollableType(shrinkWrap: true) with '
          'SliverList.builder/SliverGrid.builder$location. shrinkWrap forces '
          'eager measurement of all children, defeating lazy loading.',
      FixEffort.medium,
    );
  }

  static (String, FixEffort) nonLazySliver({
    required int childCount,
    required String widgetName,
    String? ancestorChain,
  }) {
    final location = _locationSuffix(widgetName, ancestorChain);
    return (
      '$childCount children built eagerly$location. '
          'Use $widgetName.builder() with SliverChildBuilderDelegate '
          'to lazily build visible items only.',
      FixEffort.quick,
    );
  }

  // ---------------------------------------------------------------------------
  // MemoryPressureDetector
  // ---------------------------------------------------------------------------

  static (String, FixEffort) gcPressure() {
    return (
      'Reduce object allocations in hot paths:\n'
          '// Before: padding: EdgeInsets.all(8) — new object every build\n'
          '// After:  padding: const EdgeInsets.all(8)\n'
          'Use const constructors and cache objects that are '
          'recreated in build().',
      FixEffort.medium,
    );
  }

  static (String, FixEffort) heapGrowing() {
    return (
      'Memory is growing steadily. Check for undisposed controllers:\n'
          'void dispose() {\n'
          '  _controller.dispose();\n'
          '  _subscription.cancel();\n'
          '  super.dispose();\n'
          '}\n'
          'Also check for growing caches or full-resolution image decodes. '
          'Use DevTools Memory view for per-object investigation.',
      FixEffort.involved,
    );
  }

  static (String, FixEffort) heapNearCapacity() {
    return (
      'Heap near capacity. Release image caches:\n'
          'PaintingBinding.instance.imageCache.clear();\n'
          'Dispose unused controllers and paginate large data sets. '
          'Use DevTools Memory view for per-object investigation.',
      FixEffort.involved,
    );
  }

  static (String, FixEffort) nativeMemoryGrowth() {
    return (
      'Process memory outside the Dart heap is growing. '
          'Decode images at display size:\n'
          'Image.asset("photo.jpg", cacheWidth: 300, cacheHeight: 300)\n'
          'Check for undisposed GPU textures, platform channel buffers, '
          'or native plugin allocations. Compare RSS vs Dart heap '
          'in DevTools Memory view.',
      FixEffort.involved,
    );
  }

  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------

  static (String, FixEffort) nestedScrollChildren({
    required int childCount,
    String? widgetName,
    String? ancestorChain,
  }) {
    final location = _locationSuffix(widgetName, ancestorChain);
    return (
      '$childCount children inside nested scroll$location. '
          'Use CustomScrollView with slivers, or '
          'NestedScrollView to coordinate scrolling.',
      FixEffort.medium,
    );
  }

  static (String, FixEffort) nestedScrollGeneric({
    String? widgetName,
    String? ancestorChain,
  }) {
    final ctx = _contextPrefix(widgetName, ancestorChain);
    return (
      '${ctx}Use CustomScrollView with slivers, or set '
          'physics: NeverScrollableScrollPhysics() on the inner scroll.',
      FixEffort.medium,
    );
  }

  // ---------------------------------------------------------------------------
  // NetworkMonitorDetector
  // ---------------------------------------------------------------------------

  static (String, FixEffort) slowRequest({String? worstUrl}) {
    final urlCtx = worstUrl != null ? 'Slow response from $worstUrl. ' : '';
    return (
      '${urlCtx}Consider caching responses locally:\n'
          'final cached = _cache[url];\n'
          'if (cached != null) return cached;\n'
          'Or add pagination, move to app startup, or add a loading '
          'indicator to mask latency.',
      FixEffort.medium,
    );
  }

  static (String, FixEffort) largeResponse({String? worstUrl}) {
    final urlCtx = worstUrl != null ? 'Large response from $worstUrl. ' : '';
    return (
      '${urlCtx}Request only needed fields:\n'
          'GET /api/users?fields=id,name,email\n'
          'Paginate large collections and enable response '
          'compression (gzip).',
      FixEffort.involved,
    );
  }

  static (String, FixEffort) httpErrorSpike({
    required int errorCount,
    int transportFailures = 0,
  }) {
    final buffer = StringBuffer()
      ..writeln('$errorCount HTTP errors detected in a 5-second window.')
      ..writeln()
      ..writeln('Common causes:')
      ..writeln(
          '  1. Retry storms — failed requests triggering exponential retries')
      ..writeln('  2. Backend outage — server returning 5xx errors')
      ..writeln('  3. Network connectivity — device losing connection');
    if (transportFailures > 0) {
      buffer
        ..writeln()
        ..writeln(
            'Transport failures ($transportFailures) suggest network/DNS issues.');
    }
    buffer
      ..writeln()
      ..writeln('Fixes:')
      ..writeln('  • Add exponential backoff with jitter to retry logic')
      ..writeln('  • Implement circuit breaker pattern for repeated failures')
      ..writeln('  • Cache successful responses to reduce retry impact');
    return (buffer.toString(), FixEffort.medium);
  }

  static (String, FixEffort) requestFrequency() {
    return (
      'Batch or debounce repeated requests:\n'
          '_debounce?.cancel();\n'
          '_debounce = Timer(Duration(milliseconds: 300), () => fetch(q));\n'
          'Consider caching responses or using a single stream '
          'subscription instead of polling.',
      FixEffort.medium,
    );
  }

  static (String, FixEffort) highFrequencySamePath({
    required String url,
    required int count,
  }) {
    return (
      '$count requests to the same endpoint (query strings ignored) in '
          '<500ms.\n'
          'Fixes:\n'
          '  • Debounce user-driven fetches (typeahead search, pagination)\n'
          '  • Cache responses — subsequent callers get the cached result\n'
          '  • Share a single Future across widgets (e.g. FutureProvider)\n'
          '  • Deduplicate at the repository layer with an in-flight map\n'
          '  • Check if multiple widgets independently fetch the same data',
      FixEffort.medium,
    );
  }

  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------

  static (String, FixEffort) opacityZero({
    String? widgetName,
    String? ancestorChain,
  }) {
    final ctx = _contextPrefix(widgetName, ancestorChain);
    return (
      '${ctx}Replace Opacity(opacity: 0) with Visibility:\n'
          'Visibility(\n'
          '  visible: false,\n'
          '  maintainSize: true,    // keep layout space\n'
          '  maintainAnimation: true,\n'
          '  maintainState: true,   // keep State alive\n'
          '  child: MyWidget(),\n'
          ')\n'
          'Or remove the widget from the tree entirely with an '
          'if condition.',
      FixEffort.quick,
    );
  }

  // ---------------------------------------------------------------------------
  // PlatformChannelDetector
  // ---------------------------------------------------------------------------

  static (String, FixEffort) platformChannelTraffic({String? topMethod}) {
    final methodCtx = topMethod != null ? 'Heavy traffic on $topMethod. ' : '';
    return (
      '${methodCtx}Batch platform channel calls:\n'
          '// Before: 10 separate invokeMethod() calls\n'
          '// After:  1 batched call with list of IDs\n'
          'final results = await channel.invokeMethod("batchGet", ids);\n'
          'Consider using Pigeon for type-safe communication.',
      FixEffort.medium,
    );
  }

  // ---------------------------------------------------------------------------
  // RebuildDetector
  // ---------------------------------------------------------------------------

  static (String, FixEffort) rebuildDebug({
    required String typeName,
    required int rate,
    String? ancestorChain,
    InteractionContext? interactionContext,
  }) {
    final scroll = interactionContext == InteractionContext.scrolling
        ? ' during scrolling'
        : '';
    final location = ancestorChain != null ? ' ($ancestorChain)' : '';
    return (
      '$typeName rebuilds $rate\u00d7/sec$scroll$location. '
          'Extract child widgets and use const constructors:\n'
          'const ChildWidget({super.key});\n'
          'Or scope rebuilds with Selector/Consumer instead of '
          'full BlocBuilder/Provider.of.',
      FixEffort.medium,
    );
  }

  static (String, FixEffort) rebuildActivity({
    required int buildCount,
    List<String>? enrichedNames,
    InteractionContext? interactionContext,
  }) {
    final scroll = interactionContext == InteractionContext.scrolling
        ? ' during scrolling'
        : '';
    final widgets = enrichedNames != null && enrichedNames.isNotEmpty
        ? ' (${enrichedNames.take(3).join(", ")})'
        : '';
    return (
      'High rebuild activity: $buildCount builds/sec$scroll$widgets. '
          'Use const constructors for static widgets:\n'
          'const MyWidget({super.key});\n'
          'Extract child widgets or scope rebuilds with '
          'Selector/Consumer instead of BlocBuilder/Provider.of.',
      FixEffort.medium,
    );
  }

  static (String, FixEffort) statefulDensity({String? topWidget}) {
    final widgetInfo = topWidget != null ? 'Most common: $topWidget. ' : '';
    return (
      '${widgetInfo}Extract child widgets and use const constructors:\n'
          'const ChildWidget({super.key});\n'
          'Scope rebuilds with Selector/Consumer instead of '
          'BlocBuilder/Provider.of. Run in profile mode with VM '
          'for exact counts.',
      FixEffort.medium,
    );
  }

  // ---------------------------------------------------------------------------
  // RepaintDetector
  // ---------------------------------------------------------------------------

  static (String, FixEffort) excessiveRepaintVm({
    InteractionContext? interactionContext,
  }) {
    final scroll = interactionContext == InteractionContext.scrolling
        ? ' This is happening during scrolling.'
        : '';
    return (
      'Isolate frequently repainting subtrees:\n'
          'RepaintBoundary(child: AnimatedWidget(...))\n'
          'Check for animations that trigger unnecessary repaints '
          'in parent widgets.$scroll',
      FixEffort.quick,
    );
  }

  static (String, FixEffort) repaintDebugType({
    required String typeName,
    required int rate,
    String? ancestorChain,
  }) {
    final location = ancestorChain != null ? ' ($ancestorChain)' : '';
    return (
      'Isolate $typeName repaints from parent widgets:\n'
          'RepaintBoundary(\n'
          '  child: $typeName(...),\n'
          ')\n'
          '$typeName is repainting at $rate/sec$location.',
      FixEffort.quick,
    );
  }

  static (String, FixEffort) excessiveRepaintDebug() {
    return (
      'Isolate frequently repainting subtrees:\n'
          'RepaintBoundary(child: FrequentlyUpdatedWidget(...))\n'
          'Check for animations that trigger unnecessary repaints '
          'in parent widgets.',
      FixEffort.quick,
    );
  }

  // ---------------------------------------------------------------------------
  // SetStateScopeDetector
  // ---------------------------------------------------------------------------

  static (String, FixEffort) setStateScope({
    required String widgetName,
    required int subtreePercent,
    String? ancestorChain,
  }) {
    final location = ancestorChain != null ? ' ($ancestorChain)' : '';
    return (
      '$widgetName owns ~$subtreePercent% of the tree$location. '
          'Scope rebuilds with ValueListenableBuilder:\n'
          'ValueListenableBuilder<int>(\n'
          '  valueListenable: _counter,\n'
          '  builder: (_, value, child) => Text("\$value"),\n'
          ')\n'
          'Extract stateful logic into the lowest possible subtree.',
      FixEffort.medium,
    );
  }

  // ---------------------------------------------------------------------------
  // ShaderJankDetector
  // ---------------------------------------------------------------------------

  static (String, FixEffort) shaderCompilation() {
    return (
      'Use "flutter run --profile --cache-sksl" to warm up shaders, '
          'then "flutter build --bundle-sksl-path" to pre-compile them.',
      FixEffort.involved,
    );
  }

  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------

  static (String, FixEffort) shallowRebuildRisk({
    required String widgetName,
    bool hasVmData = false,
  }) {
    final vmSuffix =
        hasVmData ? '' : ' Run in profile mode with VM for build counts.';
    return (
      '$widgetName is high in the widget tree. '
          'Use specific inherited widget accessors:\n'
          '// Before: MediaQuery.of(context) — rebuilds on ANY change\n'
          '// After:  MediaQuery.sizeOf(context) — only on size change\n'
          'Move state-dependent logic to leaf widgets.$vmSuffix',
      FixEffort.medium,
    );
  }

  // ---------------------------------------------------------------------------
  // RepaintBoundaryDetector
  // ---------------------------------------------------------------------------

  static (String, FixEffort) excessiveRepaintBoundary({
    required int boundaryCount,
    String? ancestorChain,
  }) {
    final location = ancestorChain != null ? ' ($ancestorChain)' : '';
    return (
      '$boundaryCount RepaintBoundary widgets in a single scrollable$location. '
          'Each creates a compositing layer consuming GPU memory. '
          'Remove unnecessary boundaries — ListView and GridView already '
          'add RepaintBoundary for each child by default.',
      FixEffort.quick,
    );
  }

  static (String, FixEffort) missingRepaintBoundary({
    String? widgetName,
    String? ancestorChain,
  }) {
    final ctx = _contextPrefix(widgetName, ancestorChain);
    final name = widgetName ?? 'ExpensiveWidget';
    return (
      '${ctx}Wrap the expensive subtree in a RepaintBoundary to isolate '
          'its repaints from parent layers:\n'
          'RepaintBoundary(\n'
          '  child: $name(...),\n'
          ')\n'
          'This prevents repaint propagation up the render tree when '
          'the subtree updates.',
      FixEffort.quick,
    );
  }

  // ---------------------------------------------------------------------------
  // StartupDetector
  // ---------------------------------------------------------------------------

  static (String, FixEffort) slowStartupTtff({
    required double ttffMs,
    required String dominantPhase,
  }) {
    final buffer = StringBuffer()
      ..writeln(
          'Time-to-first-frame is ${ttffMs.toStringAsFixed(0)} ms — users '
          'perceive anything above 1.5 s as slow.')
      ..writeln()
      ..writeln('Fixes by dominant phase:');

    if (dominantPhase == 'build') {
      buffer
        ..writeln('  • Defer heavy widget construction (use FutureBuilder or')
        ..writeln('    lazy initialization for below-fold content)')
        ..writeln('  • Reduce initial route widget tree depth')
        ..writeln('  • Move expensive init logic to isolates');
    } else if (dominantPhase == 'raster') {
      buffer
        ..writeln('  • Reduce first-frame painting complexity')
        ..writeln('  • Pre-cache large images with precacheImage()')
        ..writeln('  • Avoid shader-heavy effects on the splash screen');
    } else if (dominantPhase == 'vsync') {
      buffer
        ..writeln('  • Minimize plugin initialization before runApp()')
        ..writeln('  • Defer non-critical plugin init to post-first-frame')
        ..writeln('  • Check for blocking platform channel calls in main()');
    } else {
      buffer
        ..writeln('  • Profile with --profile and check DevTools timeline')
        ..writeln('  • Move heavy initialization to isolates')
        ..writeln('  • Defer non-visible widget construction');
    }

    return (
      buffer.toString().trimRight(),
      ttffMs >= 3000 ? FixEffort.involved : FixEffort.medium,
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Returns " in WidgetName (AncestorChain)" or "" when unavailable.
  static String _locationSuffix(String? widgetName, String? ancestorChain) {
    if (widgetName == null && ancestorChain == null) return '';
    if (widgetName != null && ancestorChain != null) {
      return ' in $widgetName ($ancestorChain)';
    }
    if (widgetName != null) return ' in $widgetName';
    return ' at $ancestorChain';
  }

  /// Returns "In WidgetName (AncestorChain): " or "" when unavailable.
  static String _contextPrefix(String? widgetName, String? ancestorChain) {
    if (widgetName == null && ancestorChain == null) return '';
    if (widgetName != null && ancestorChain != null) {
      return 'In $widgetName ($ancestorChain): ';
    }
    if (widgetName != null) return 'In $widgetName: ';
    return 'At $ancestorChain: ';
  }
}
