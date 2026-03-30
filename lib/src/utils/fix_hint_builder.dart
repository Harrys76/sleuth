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
  // AnimatedBuilderDetector
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

  // ---------------------------------------------------------------------------
  // FrameTimingDetector
  // ---------------------------------------------------------------------------

  static (String, FixEffort) sustainedJank() {
    return (
      'Check for heavy computations in build(), setState() scope, '
          'or offscreen painting. Use profile mode for exact breakdown.',
      FixEffort.medium,
    );
  }

  static (String, FixEffort) jankDetected() {
    return (
      'Minor jank detected. Consider const constructors, '
          'RepaintBoundary, or reducing widget tree depth.',
      FixEffort.quick,
    );
  }

  // ---------------------------------------------------------------------------
  // GlobalKeyDetector
  // ---------------------------------------------------------------------------

  static (String, FixEffort) excessiveGlobalKeys({required int count}) {
    return (
      '$count GlobalKey instances in scrollable children. '
          'Replace GlobalKey with ValueKey or UniqueKey where possible. '
          'Only use GlobalKey when you need to access widget state '
          'across different parts of the tree.',
      FixEffort.quick,
    );
  }

  // ---------------------------------------------------------------------------
  // GpuPressureDetector
  // ---------------------------------------------------------------------------

  static (String, FixEffort) rasterDominance() {
    return (
      'Reduce the amount of work done during rasterization or '
          'simplify the scene so the GPU has less to draw each frame.',
      FixEffort.involved,
    );
  }

  static (String, FixEffort) expensiveGpuNodes({
    String? widgetName,
    String? ancestorChain,
  }) {
    final ctx = _contextPrefix(widgetName, ancestorChain);
    return (
      '${ctx}Consider simplifying visual effects or adding '
          'RepaintBoundary around expensive subtrees.',
      FixEffort.medium,
    );
  }

  // ---------------------------------------------------------------------------
  // FrameTimingDetector — Raster Cache Trends
  // ---------------------------------------------------------------------------

  static (String, FixEffort) rasterCacheThrashing() {
    return (
      'The raster cache is repeatedly allocating and evicting entries. '
          'Ensure painted widgets use const constructors where possible, '
          'avoid rebuilding CustomPainter canvases every frame, and check '
          'that RepaintBoundary is used around complex static subtrees. '
          'Use DevTools Performance overlay to visualize cache behavior.',
      FixEffort.involved,
    );
  }

  static (String, FixEffort) rasterCacheGrowing() {
    return (
      'Raster cache bytes are growing without bound. This may indicate '
          'that cached layers or pictures are never evicted. Check for '
          'an ever-growing number of unique visual elements (e.g., '
          'dynamically-created widgets with unique paint), or animations '
          'that create new cache entries per frame. Consider using '
          'RepaintBoundary strategically to limit cache scope.',
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
      '${prefix}Move heavy work to a background isolate using '
          'Isolate.run() or compute(). Avoid synchronous '
          'JSON parsing, image processing, or complex calculations in build().',
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
      'Add cacheWidth and/or cacheHeight to Image widgets:\n'
          'Image.asset("photo.jpg", cacheWidth: 300)',
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
          'Remove AutomaticKeepAliveClientMixin from most items. '
          'Only keep alive items with expensive state. Let others '
          'rebuild naturally when scrolled back to.',
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
            '($ancestorChain). Measure $widgetName\'s actual size and replace '
            'IntrinsicHeight/Width with SizedBox or Expanded. '
            'Use Row/Column crossAxisAlignment instead.',
        FixEffort.medium,
      );
    }
    return (
      'Replace IntrinsicHeight/Width with fixed sizes, '
          'Expanded, or SizedBox where possible. '
          'Use Row/Column crossAxisAlignment instead.',
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

  // ---------------------------------------------------------------------------
  // MemoryPressureDetector
  // ---------------------------------------------------------------------------

  static (String, FixEffort) gcPressure() {
    return (
      'Reduce object allocations in hot paths. '
          'Reuse objects, use const constructors, '
          'and avoid creating objects in build().',
      FixEffort.medium,
    );
  }

  static (String, FixEffort) heapGrowing() {
    return (
      'Memory is growing steadily. Check for undisposed controllers, '
          'uncancelled streams, growing caches, or images decoded at full '
          'resolution. Use DevTools Memory view for per-object investigation.',
      FixEffort.involved,
    );
  }

  static (String, FixEffort) heapNearCapacity() {
    return (
      'Consider releasing image caches, disposing unused '
          'controllers, or paginating large data sets. '
          'Use DevTools Memory view for per-object investigation.',
      FixEffort.involved,
    );
  }

  static (String, FixEffort) nativeMemoryGrowth() {
    return (
      'Process memory outside the Dart heap is growing. Check for '
          'undisposed GPU textures (Image.dispose()), images decoded at full '
          'resolution (use cacheWidth/cacheHeight), platform channel buffers, '
          'or native plugin allocations. Use DevTools Memory view to compare '
          'RSS vs Dart heap.',
      FixEffort.involved,
    );
  }

  // ---------------------------------------------------------------------------
  // NestedScrollDetector
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
      '${urlCtx}Consider pagination, caching, or moving this request to app '
          'startup. If the endpoint is slow, add a loading indicator to mask '
          'latency.',
      FixEffort.medium,
    );
  }

  static (String, FixEffort) largeResponse({String? worstUrl}) {
    final urlCtx = worstUrl != null ? 'Large response from $worstUrl. ' : '';
    return (
      '${urlCtx}Request only needed fields (sparse fieldsets / GraphQL). '
          'Paginate large collections. Compress responses (gzip).',
      FixEffort.involved,
    );
  }

  static (String, FixEffort) requestFrequency() {
    return (
      'Batch or debounce repeated requests. Consider caching '
          'responses or using a single stream subscription instead of polling.',
      FixEffort.medium,
    );
  }

  // ---------------------------------------------------------------------------
  // OpacityDetector
  // ---------------------------------------------------------------------------

  static (String, FixEffort) opacityZero({
    String? widgetName,
    String? ancestorChain,
  }) {
    final ctx = _contextPrefix(widgetName, ancestorChain);
    return (
      '${ctx}If the widget should disappear entirely, remove it from '
          'the tree. If it should stay in layout, use Visibility with the '
          'maintain* flags chosen intentionally. Add IgnorePointer or '
          'ExcludeSemantics if hidden content should also stop receiving '
          'taps or accessibility focus.',
      FixEffort.quick,
    );
  }

  // ---------------------------------------------------------------------------
  // PlatformChannelDetector
  // ---------------------------------------------------------------------------

  static (String, FixEffort) platformChannelTraffic({String? topMethod}) {
    final methodCtx = topMethod != null ? 'Heavy traffic on $topMethod. ' : '';
    return (
      '${methodCtx}Batch platform channel calls where possible. '
          'Consider using Pigeon for type-safe communication '
          'or cache results to reduce call frequency.',
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
          'Check if $typeName\'s children use const constructors. '
          'Extract child widgets into separate StatelessWidgets or use '
          'Selector/Consumer for targeted rebuilds.',
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
          'Use const constructors, extract child widgets, or use '
          'Selector/Consumer instead of BlocBuilder/Provider.of for '
          'targeted rebuilds.',
      FixEffort.medium,
    );
  }

  static (String, FixEffort) statefulDensity({String? topWidget}) {
    final widgetInfo = topWidget != null ? 'Most common: $topWidget. ' : '';
    return (
      '${widgetInfo}Use const constructors, extract child widgets, or use '
          'Selector/Consumer instead of BlocBuilder/Provider.of for '
          'targeted rebuilds. Run in profile mode with VM for exact counts.',
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
      'Add RepaintBoundary widgets to isolate frequently '
          'repainting subtrees. Check for animations that '
          'trigger unnecessary repaints in parent widgets.$scroll',
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
      'Add RepaintBoundary above $typeName$location to isolate its '
          'repaints from parent widgets. '
          '$typeName is repainting at $rate/sec.',
      FixEffort.quick,
    );
  }

  static (String, FixEffort) excessiveRepaintDebug() {
    return (
      'Add RepaintBoundary widgets to isolate frequently '
          'repainting subtrees. Check for animations that '
          'trigger unnecessary repaints in parent widgets.',
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
          'Move setState() calls to smaller, focused widgets. '
          'Use Builder or ValueListenableBuilder to scope rebuilds. '
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
  // ShallowRebuildRiskDetector
  // ---------------------------------------------------------------------------

  static (String, FixEffort) shallowRebuildRisk({
    required String widgetName,
    bool hasVmData = false,
  }) {
    final vmSuffix =
        hasVmData ? '' : ' Run in profile mode with VM for build counts.';
    return (
      '$widgetName is high in the widget tree. '
          'Use specific inherited widget accessors (e.g. '
          'MediaQuery.sizeOf instead of MediaQuery.of) to reduce '
          'rebuild scope. Move state-dependent logic to leaf widgets.$vmSuffix',
      FixEffort.medium,
    );
  }

  // ---------------------------------------------------------------------------
  // RepaintBoundaryDetector
  // ---------------------------------------------------------------------------

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
