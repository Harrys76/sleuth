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
      'The app uses $fontCount custom font families$familyInfo. '
          'Keep custom fonts to 2 or 3 families. '
          'Preload them with FontLoader, or bundle them in pubspec.yaml.',
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
          'Fonts loaded at runtime, for example by google_fonts, send HTTP '
          'requests during the first render, and the text flickers.\n'
          'Download them ahead of time with GoogleFonts.pendingFonts() in '
          'main(), or bundle the fonts as assets in pubspec.yaml.',
      FixEffort.medium,
    );
  }

  // ---------------------------------------------------------------------------
  // FrameTimingDetector
  // ---------------------------------------------------------------------------

  static (String, FixEffort) sustainedJank() {
    return (
      'Look for heavy computation in build(), setState() calls with a '
          'wide scope, and offscreen painting. Run in profile mode:\n'
          'flutter run --profile\n'
          'Then open DevTools > Performance to find the expensive frames.',
      FixEffort.medium,
    );
  }

  static (String, FixEffort) jankDetected() {
    return (
      'Some frames show minor jank. Use const constructors for static '
          'widgets:\n'
          'const MyWidget({super.key});\n'
          'Add a RepaintBoundary around expensive subtrees, or make the '
          'widget tree shallower.',
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
          'Use GlobalKey only when you need widget state from another '
          'part of the tree.',
      FixEffort.quick,
    );
  }

  static (String, FixEffort) globalKeyRecreation({required int churnCount}) {
    return (
      '$churnCount GlobalKeys recreated between scans.\n'
          'Fixes:\n'
          '  • Store GlobalKeys in State fields, not in build()\n'
          '  • Use late final or initialize in initState()\n'
          '  • Use ValueKey(item.id) if you need identity but not '
          'state access',
      FixEffort.quick,
    );
  }

  // ---------------------------------------------------------------------------
  // GpuPressureDetector
  // ---------------------------------------------------------------------------

  static (String, FixEffort) rasterDominance() {
    return (
      'Reduce GPU work per frame:\n'
          '- Prefer ClipRRect with Clip.hardEdge over ClipPath (a '
          'BoxDecoration borderRadius does not clip children)\n'
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
      'The raster cache keeps allocating and evicting entries. '
          'Use const constructors for stable widgets:\n'
          'const MyWidget({super.key});\n'
          'Do not rebuild CustomPainter canvases every frame. Put a '
          'RepaintBoundary around complex static subtrees.',
      FixEffort.involved,
    );
  }

  static (String, FixEffort) rasterCacheGrowing() {
    return (
      'Raster cache bytes are growing without bound. Look for '
          'dynamically created widgets with unique paint output, or for '
          'animations that create new cache entries every frame. '
          'Limit the cache scope:\n'
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
        ? 'The heavy build involved ${dirtyWidgets.take(3).join(", ")}'
              '${durationMs != null ? " (${durationMs.toStringAsFixed(1)}ms)" : ""}. '
        : '';
    return (
      '${prefix}Split the widget so changes rebuild a smaller subtree, '
          'mark static subtrees const, and defer below-the-fold work. '
          'Move non-UI work (JSON parsing, image processing, complex '
          'calculations) off the UI thread with Isolate.run() or '
          'compute():\n'
          'final result = await Isolate.run(() => parseJson(data));',
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
        '$count oversized image${count > 1 ? "s" : ""} in $widgetName$chain. '
            'Decode them at display size with cacheWidth, cacheHeight or '
            'both, set to the displayed size times the device pixel ratio:\n'
            'Image.asset("photo.jpg", cacheWidth: '
            '(56 * MediaQuery.devicePixelRatioOf(context)).round())',
        FixEffort.quick,
      );
    }
    return (
      'Decode images at display size. Set cacheWidth, cacheHeight or both '
          'to the displayed size times the device pixel ratio:\n'
          'Image.network(url, cacheWidth: '
          '(56 * MediaQuery.devicePixelRatioOf(context)).round())\n'
          'Or wrap the provider:\n'
          'ResizeImage(imageProvider, width: 168)',
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
          'Keep alive only the items whose state is expensive to '
          'recreate.',
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
        'The ancestor chain of $widgetName ($ancestorChain) has an '
            'IntrinsicHeight or IntrinsicWidth. Replace it with explicit '
            'sizing:\n'
            '// Before: IntrinsicHeight(child: Row(...))\n'
            '// After:  Row(crossAxisAlignment: CrossAxisAlignment.stretch, ...)\n'
            'Stretch needs a bounded cross axis, such as a fixed-height '
            'parent. Or use SizedBox or Expanded with known dimensions.',
        FixEffort.medium,
      );
    }
    return (
      'Replace IntrinsicHeight or IntrinsicWidth with explicit sizing:\n'
          '// Before: IntrinsicHeight(child: Row(...))\n'
          '// After:  Row(crossAxisAlignment: CrossAxisAlignment.stretch, ...)\n'
          'Stretch needs a bounded cross axis, such as a fixed-height '
          'parent. Or use SizedBox or Expanded with known dimensions.',
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
      'This Wrap lays out all $childCount children with no '
          'virtualization$location. For large item counts, split the items '
          'into rows yourself or use GridView.builder.',
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
      '$childCount children are built eagerly$location. '
          'Use ListView.builder() or ListView.separated() so only the '
          'visible items are built.',
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
      'Replace the SliverToBoxAdapter that holds a $childType '
          '($childCount children) with SliverList.builder so the items load '
          'lazily$location.',
      FixEffort.medium,
    );
  }

  static (String, FixEffort) sliverFillRemainingScrollable({
    String? ancestorChain,
  }) {
    final location = _locationSuffix(null, ancestorChain);
    return (
      'Use SliverFillRemaining(hasScrollBody: true) when the child is a '
          'scrollable$location. With hasScrollBody: false the child gets '
          'unconstrained height, so the scrollable child has to shrinkWrap '
          'and builds all its children eagerly.',
      FixEffort.quick,
    );
  }

  static (String, FixEffort) sliverToBoxAdapterShrinkWrap({
    required String scrollableType,
    String? ancestorChain,
  }) {
    final location = _locationSuffix(null, ancestorChain);
    return (
      'Replace the SliverToBoxAdapter that holds '
          '$scrollableType(shrinkWrap: true) with SliverList.builder or '
          'SliverGrid.builder$location. shrinkWrap measures every child up '
          'front, so nothing loads lazily.',
      FixEffort.medium,
    );
  }

  static (String, FixEffort) nonLazyShrinkWrap({
    required String scrollableType,
    required String flexType,
    String? ancestorChain,
  }) {
    final location = _locationSuffix(null, ancestorChain);
    return (
      '$scrollableType(shrinkWrap: true) inside a $flexType builds every '
          'child up front$location. Make the $flexType a sliver list: a '
          'CustomScrollView with a SliverToBoxAdapter header and a '
          'SliverList.builder, or put the header as item 0 of one '
          '$scrollableType.builder.',
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
      '$childCount children are built eagerly$location. '
          'Use $widgetName.builder() with SliverChildBuilderDelegate so only '
          'the visible items are built.',
      FixEffort.quick,
    );
  }

  // ---------------------------------------------------------------------------
  // MemoryPressureDetector
  // ---------------------------------------------------------------------------

  static (String, FixEffort) gcPressure() {
    return (
      'Reduce object allocations in hot paths:\n'
          '// Before: padding: EdgeInsets.all(8), a new object every build\n'
          '// After:  padding: const EdgeInsets.all(8)\n'
          'Use const constructors, and cache objects that build() '
          'recreates.',
      FixEffort.medium,
    );
  }

  static (String, FixEffort) heapGrowing() {
    return (
      'Memory keeps growing. Check for undisposed controllers:\n'
          'void dispose() {\n'
          '  _controller.dispose();\n'
          '  _subscription.cancel();\n'
          '  super.dispose();\n'
          '}\n'
          'Also look for growing caches and images decoded at full '
          'resolution. Use the DevTools Memory view to inspect individual '
          'objects.',
      FixEffort.involved,
    );
  }

  static (String, FixEffort) heapNearCapacity() {
    return (
      'Process memory is near the configured budget and still growing. '
          'Find the growth in the DevTools Memory view, then release image '
          'caches:\n'
          'PaintingBinding.instance.imageCache.clear();\n'
          'Decode images at display size (cacheWidth/cacheHeight), dispose '
          'unused controllers and paginate large data sets.',
      FixEffort.involved,
    );
  }

  static (String, FixEffort) streamResourceGrowth({
    required List<String> growingClassSuffixes,
    int? topGrowthDelta,
  }) {
    final suffixList = growingClassSuffixes.take(3).join(', ');
    final deltaInfo = topGrowthDelta != null
        ? ' (top class +$topGrowthDelta instances)'
        : '';
    return (
      'Async resources are accumulating: $suffixList$deltaInfo. '
          'Audit the dispose and cancel paths in recently visited routes:\n'
          '  • Call cancel() on the StreamSubscription from Stream.listen()\n'
          '  • Call close() on a StreamController in dispose()\n'
          '  • Call sink.close() on a WebSocketChannel\n'
          '  • Call close() on an rxdart Subject when ownership ends\n'
          '  • Close a Cubit or Bloc in State.dispose()\n'
          'If the app keeps these objects on purpose, check heap_growing '
          'and native_memory_growing for other causes of memory pressure, '
          'such as cache bloat, image decodes or GPU textures.',
      FixEffort.medium,
    );
  }

  static (String, FixEffort) nativeMemoryGrowth() {
    return (
      'Process memory outside the Dart heap is growing. '
          'Decode images at display size:\n'
          'Image.asset("photo.jpg", cacheWidth: 300, cacheHeight: 300)\n'
          'Check for undisposed GPU textures, platform channel buffers '
          'and native plugin allocations. Compare RSS with the Dart heap '
          'in the DevTools Memory view.',
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
          'NestedScrollView, to coordinate scrolling.',
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
      '${urlCtx}Avoid repeat requests by caching responses locally:\n'
          'final cached = _cache[url];\n'
          'if (cached != null) return cached;\n'
          'Or paginate, make the request at app startup, or show a loading '
          'indicator while it runs.',
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
        '  1. Retry storms, where failed requests trigger exponential retries',
      )
      ..writeln('  2. A backend outage, with the server returning 5xx errors')
      ..writeln('  3. The device losing its network connection');
    if (transportFailures > 0) {
      buffer
        ..writeln()
        ..writeln(
          '$transportFailures transport failures point to network or DNS '
          'problems.',
        );
    }
    buffer
      ..writeln()
      ..writeln('Fixes:')
      ..writeln('  • Add exponential backoff with jitter to retry logic')
      ..writeln('  • Use a circuit breaker for repeated failures')
      ..writeln('  • Cache successful responses to reduce retry impact');
    return (buffer.toString(), FixEffort.medium);
  }

  static (String, FixEffort) requestFrequency() {
    return (
      'Batch or debounce repeated requests:\n'
          '_debounce?.cancel();\n'
          '_debounce = Timer(Duration(milliseconds: 300), () => fetch(q));\n'
          'Cache responses, or use a single stream subscription instead '
          'of polling.',
      FixEffort.medium,
    );
  }

  static (String, FixEffort) highFrequencySamePath({
    required String url,
    required int count,
  }) {
    return (
      '$count requests went to the same endpoint (query strings ignored) '
          'in under 500ms.\n'
          'Fixes:\n'
          '  • Debounce user-driven fetches (typeahead search, pagination)\n'
          '  • Cache responses so later callers get the cached result\n'
          '  • Share one Future across widgets, for example with '
          'FutureProvider\n'
          '  • Deduplicate at the repository layer with an in-flight map\n'
          '  • Check whether several widgets fetch the same data on their own',
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
          'Or remove the widget from the tree with an if condition.',
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
          '// After:  1 batched call with a list of IDs\n'
          'final results = await channel.invokeMethod("batchGet", ids);\n'
          'Use Pigeon for type-safe channel calls.',
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
      '$typeName rebuilds $rate times per second$scroll$location. '
          'Extract child widgets and use const constructors:\n'
          'const ChildWidget({super.key});\n'
          'Or scope rebuilds with Selector or Consumer instead of a full '
          'BlocBuilder or Provider.of.',
      FixEffort.medium,
    );
  }

  static (String, FixEffort) rebuildActivity({
    required double buildPercent,
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
      'Rebuilding widgets took ${buildPercent.toStringAsFixed(1)}% of '
          'UI-thread time$scroll$widgets. Shrink what rebuilds each frame. '
          'Use const constructors for static widgets:\n'
          'const MyWidget({super.key});\n'
          'Extract child widgets, or scope rebuilds with Selector or '
          'Consumer instead of BlocBuilder or Provider.of.',
      FixEffort.medium,
    );
  }

  static (String, FixEffort) statefulDensity({String? topWidget}) {
    final widgetInfo = topWidget != null
        ? 'The most common one is $topWidget. '
        : '';
    return (
      '${widgetInfo}Extract child widgets and use const constructors:\n'
          'const ChildWidget({super.key});\n'
          'Scope rebuilds with Selector or Consumer instead of '
          'BlocBuilder or Provider.of. Run in profile mode with the VM '
          'connected for exact counts.',
      FixEffort.medium,
    );
  }

  // ---------------------------------------------------------------------------
  // RepaintDetector
  // ---------------------------------------------------------------------------

  static (String, FixEffort) excessiveRepaintVm({
    required double paintPercent,
    InteractionContext? interactionContext,
  }) {
    final scroll = interactionContext == InteractionContext.scrolling
        ? ' The repaints happen during scrolling.'
        : '';
    return (
      'Painting took ${paintPercent.toStringAsFixed(1)}% of UI-thread '
          'time. Wrap subtrees that repaint often in a RepaintBoundary so '
          'Flutter does not re-record the rest of the layer:\n'
          'RepaintBoundary(child: AnimatedWidget(...))\n'
          'Check for animations that trigger needless repaints in parent '
          'widgets. Cache expensive drawing in a Picture or an '
          'image.$scroll',
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
      '$typeName is the likely origin of repaints in its layer at '
          '$rate/sec$location. Isolate the part that changes. Wrap '
          '$typeName itself, or the smallest subtree around it, in a '
          'RepaintBoundary so the rest of the layer stops repainting with '
          'it:\n'
          'RepaintBoundary(\n'
          '  child: $typeName(...),\n'
          ')\n'
          'Wrapping a sibling does not help. You can also move the '
          'animation or listenable that changes it lower in the tree. A '
          'boundary makes each repaint cheaper, but repaints happen just as '
          'often. To repaint less often, check what marks $typeName as '
          'needing paint (setState, a repaint listenable, shouldRepaint).',
      FixEffort.quick,
    );
  }

  static (String, FixEffort) excessiveRepaintDebug() {
    return (
      'Wrap subtrees that repaint often in a RepaintBoundary:\n'
          'RepaintBoundary(child: FrequentlyUpdatedWidget(...))\n'
          'Check for animations that trigger needless repaints in parent '
          'widgets.',
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
      '$widgetName owns about $subtreePercent% of the tree$location. '
          'Scope rebuilds with ValueListenableBuilder:\n'
          'ValueListenableBuilder<int>(\n'
          '  valueListenable: _counter,\n'
          '  builder: (_, value, child) => Text("\$value"),\n'
          ')\n'
          'Move stateful logic into the lowest subtree that needs it.',
      FixEffort.medium,
    );
  }

  // ---------------------------------------------------------------------------
  // ShaderJankDetector
  // ---------------------------------------------------------------------------

  static (String, FixEffort) shaderCompilation() {
    return (
      'Trigger the first use of heavy effects (BackdropFilter, '
          'ShaderMask, custom FragmentProgram) during a warm-up or splash '
          'frame so the pipeline build does not land on a user '
          'interaction. Avoid introducing new effect types mid-animation. '
          'On devices still on Skia, prefer Impeller.',
      FixEffort.involved,
    );
  }

  // ---------------------------------------------------------------------------
  // ---------------------------------------------------------------------------

  static (String, FixEffort) shallowRebuildRisk({
    required String widgetName,
    bool hasVmData = false,
  }) {
    final vmSuffix = hasVmData
        ? ''
        : ' Run in profile mode with the VM connected for build counts.';
    return (
      '$widgetName is high in the widget tree. '
          'Use specific inherited widget accessors:\n'
          '// Before: MediaQuery.of(context) rebuilds on any change\n'
          '// After:  MediaQuery.sizeOf(context) rebuilds only on size changes\n'
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
          'Each boundary is a separate layer with its own compositing '
          'cost. A boundary pays off only when its subtree repaints on its '
          'own. Remove the extra boundaries. ListView and GridView already '
          'add a RepaintBoundary around each child by default.',
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
          'Then a repaint in the subtree no longer spreads up the render '
          'tree.',
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
        'Time to first frame is ${ttffMs.toStringAsFixed(0)} ms. Users '
        'perceive anything above 1.5 s as slow.',
      )
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
        ..writeln(
          '  • Defer non-critical plugin init until after the first frame',
        )
        ..writeln('  • Check for blocking platform channel calls in main()');
    } else {
      buffer
        ..writeln('  • Profile with --profile and check the DevTools timeline')
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

  static (String, FixEffort) trackedResourceConcurrent({
    required String name,
    required int liveCount,
  }) {
    return (
      '$liveCount live "$name" instances are reachable from app code. '
          'The tracker holds only WeakReferences, so something outside '
          'Sleuth retains each one. Audit the dispose and cancel paths for '
          '"$name" in recently visited routes. If "$name" is a pool '
          '(connection pool, worker pool) and $liveCount is expected, '
          'raise the threshold for every name with '
          '`SleuthConfig.thresholds.trackedResourceMaxConcurrent`, raise it '
          'for this name with `Sleuth.setResourceThreshold("$name", '
          'maxConcurrent: N)`, or untrack the pooled instances.',
      FixEffort.medium,
    );
  }

  static (String, FixEffort) trackedResourceLongLived({
    required String name,
    required int ageSeconds,
  }) {
    return (
      'Instance of "$name" has been alive for $ageSeconds seconds. '
          'Its WeakReference and Finalizer show that the GC has not '
          'reclaimed it, so something outside the tracker still holds it. '
          'If it is meant to live for the whole session (a DI singleton or '
          'an app-scope service), stop tracking "$name", raise the '
          'threshold for every name with '
          '`SleuthConfig.thresholds.trackedResourceLongLivedSeconds`, or '
          'raise it for this name with `Sleuth.setResourceThreshold("$name", '
          'longLivedSeconds: N)`.',
      FixEffort.medium,
    );
  }
}
