## v10 Roadmap: Performance, Accuracy & Enrichment

Origin: Deep codebase audit (2026-04-06) across all 22 detectors, controller, correlator, causal graph, and ranking systems. 14 initial findings identified; 2 dropped after source-level verification (GpuPressureDetector already has `is RenderOpacity` value guard from v9.1; original ultraplan's alternate child-counting approach was unnecessary since `SliverChildListDelegate.children` IS public). 12 verified findings remain across 3 tiers.

**Tiers:**
- **Tier 1 — Accuracy** (v10.1–v10.5): Missed signals, false positives, and hot-path type checks.
- **Tier 2 — Enrichment** (v10.6–v10.9): Cross-detector correlation rules and new detection signals.
- **Tier 3 — Performance** (v10.10–v10.12): Scan-path overhead and allocation reduction.

---

### v10.1: ListviewDetector Misses Non-Builder ListView/GridView

**Effort:** Medium | **Theme:** Accuracy | **Impact:** Missed signal — `ListView(children: [...100 items...])` never flagged

**Problem:** `ListviewDetector` (`listview_detector.dart:45-52`) only catches `SingleChildScrollView + Column/Row`. A `ListView(children: [...])` uses `SliverChildListDelegate` internally (not lazy `SliverChildBuilderDelegate`), but this detector never sees it. The description claims "Detects non-lazy ListView with >50 items" but the implementation only handles SingleChildScrollView.

Current `checkElement`:

```dart
void checkElement(Element element) {
  final widget = element.widget;
  // Detect SingleChildScrollView + Column/Row pattern (non-lazy list)
  if (widget is SingleChildScrollView) {
    _checkForNonLazyList(element);
  }
}
```

**Fix:** In `checkElement`, add detection for `ListView`/`GridView` with non-builder delegates. `SliverChildListDelegate.children` is a public `final List<Widget>` field — use `delegate.children.length` directly:

```dart
@override
void checkElement(Element element) {
  final widget = element.widget;

  if (widget is SingleChildScrollView) {
    _checkForNonLazyList(element);
    return;
  }

  // Detect non-builder ListView/GridView (uses SliverChildListDelegate)
  if (widget is ListView || widget is GridView) {
    final delegate = widget is ListView
        ? widget.childrenDelegate
        : (widget as GridView).childrenDelegate;
    if (delegate is SliverChildListDelegate &&
        delegate.children.length > childThreshold) {
      _emitNonLazyScrollViewIssue(element, widget, delegate.children.length);
    }
  }
}
```

```dart
void _emitNonLazyScrollViewIssue(
    Element scrollElement, Widget widget, int childCount) {
  final widgetName = widget is ListView ? 'ListView' : 'GridView';
  final stableId =
      widget is ListView ? 'non_lazy_listview' : 'non_lazy_gridview';
  final location = buildAncestorChain(scrollElement);

  final ro = scrollElement.renderObject;
  if (ro != null) {
    final rect = getGlobalRect(ro);
    if (rect != null) {
      _highlights.add(WidgetHighlight(
        rect: rect,
        widgetName: widgetName,
        severity: childCount > childThreshold * 2
            ? IssueSeverity.critical
            : IssueSeverity.warning,
        detectorName: 'Non-lazy',
        detail: '$childCount children built eagerly',
      ));
    }
  }
  final (hint, effort) = FixHintBuilder.nonLazyList(
    childCount: childCount,
    widgetName: widgetName,
    ancestorChain: location,
  );
  _issues.add(PerformanceIssue(
    stableId: stableId,
    severity: childCount > childThreshold * 3
        ? IssueSeverity.critical
        : IssueSeverity.warning,
    category: IssueCategory.build,
    confidence: IssueConfidence.possible,
    title: 'Non-lazy $widgetName: $childCount children',
    detail: '$widgetName with $childCount children builds all items at '
        'once instead of lazily. Use $widgetName.builder for '
        'virtualized rendering.\n\n  • $location',
    fixHint: hint,
    fixEffort: effort,
    widgetName: widgetName,
    ancestorChain: location,
    observationSource: ObservationSource.structural,
    detectedAt: DateTime.now(),
  ));
}
```

Also add `non_lazy_listview` and `non_lazy_gridview` to causal graph rules alongside existing `non_lazy_list`:

```dart
CausalRule('non_lazy_listview', 'rebuild_activity'),
CausalRule('non_lazy_listview', 'rebuild_debug_*'),
CausalRule('non_lazy_listview', 'heavy_compute'),
CausalRule('non_lazy_listview', 'layout_bottleneck'),
CausalRule('non_lazy_gridview', 'rebuild_activity'),
CausalRule('non_lazy_gridview', 'rebuild_debug_*'),
CausalRule('non_lazy_gridview', 'heavy_compute'),
CausalRule('non_lazy_gridview', 'layout_bottleneck'),
```

**Files:** `lib/src/detectors/listview_detector.dart`, `lib/src/analyzer/causal_graph.dart`, corresponding tests.

**Risk:** Low. Additive detection — existing `SingleChildScrollView` detection unchanged. New stableIds won't conflict with existing suppression rules.

---

### v10.2: NestedScrollDetector False Positives on NeverScrollableScrollPhysics

**Effort:** Small | **Theme:** Accuracy | **Impact:** Eliminates false positives for intentionally non-scrollable nested scrollables

**Problem:** `NestedScrollDetector` (`nested_scroll_detector.dart:58-65`) flags any same-axis scroll nesting. But `ListView(physics: NeverScrollableScrollPhysics(), shrinkWrap: true)` inside a `SingleChildScrollView` is a standard Flutter pattern — the inner list delegates scrolling entirely to the parent. This is explicitly recommended in Flutter docs and never causes scroll conflicts.

Current `checkElement` at line 58:

```dart
if (scrollAxis != null && parentAxis != null) {
  if (scrollAxis == parentAxis) {
    // Same-axis nesting — always flag
    _checkNestedScroll(element, widget);
  }
}
```

No filtering for `NeverScrollableScrollPhysics`. Every same-axis nesting fires.

**Fix:** In `checkElement`, before entering the same-axis branch, check if the inner scrollable uses `NeverScrollableScrollPhysics`. These widgets intentionally opt out of scroll conflict:

```dart
if (scrollAxis != null && parentAxis != null) {
  if (scrollAxis == parentAxis) {
    // NeverScrollableScrollPhysics means the inner widget intentionally
    // delegates scrolling to the parent — standard Flutter pattern.
    if (!_hasNeverScrollablePhysics(widget)) {
      _checkNestedScroll(element, widget);
    }
  }
}
```

Add helper:

```dart
static bool _hasNeverScrollablePhysics(Widget widget) {
  if (widget is ScrollView) return widget.physics is NeverScrollableScrollPhysics;
  if (widget is SingleChildScrollView) {
    return widget.physics is NeverScrollableScrollPhysics;
  }
  return false;
}
```

**Why this is correct:** `NeverScrollableScrollPhysics` prevents the inner scrollable from consuming scroll gestures. Combined with `shrinkWrap: true`, the inner list sizes itself to its content and the outer scrollable handles all scrolling. No scroll conflict, no performance issue.

**Edge case:** `ScrollPhysics` has a `parent` chain. A developer could write `ClampingScrollPhysics(parent: NeverScrollableScrollPhysics())`, where `widget.physics is NeverScrollableScrollPhysics` returns `false`. In practice this pattern is extremely rare — Flutter docs always show `NeverScrollableScrollPhysics()` as the direct value. Add a code comment documenting this limitation.

**Files:** `lib/src/detectors/nested_scroll_detector.dart`, corresponding tests.

**Risk:** Very low. Strictly reduces false positives. All legitimate nested scroll warnings remain. The `ScrollPhysics.parent` chain edge case is negligible in practice.

---

### v10.3: ImageMemoryDetector Misses DecorationImage in BoxDecoration

**Effort:** Small | **Theme:** Accuracy | **Impact:** Missed signal — images loaded via `BoxDecoration.image` never checked for decode-time resizing

**Problem:** `ImageMemoryDetector` (`image_memory_detector.dart:66-93`) only checks `widget is Image`. Images loaded through `DecorationImage` in `BoxDecoration` (via `DecoratedBox` or `Container`) are a common Flutter pattern but are completely invisible to this detector.

A `Container(decoration: BoxDecoration(image: DecorationImage(image: NetworkImage(...))))` loads a full-resolution image into memory with no `ResizeImage` wrapping, but is never flagged.

Current `checkElement`:

```dart
void checkElement(Element element) {
  final widget = element.widget;
  if (widget is Image) {
    // ... only checks Image widgets
  }
}
```

**Fix:** Add `DecoratedBox` inspection after the existing `Image` check:

```dart
void checkElement(Element element) {
  final widget = element.widget;

  if (widget is Image) {
    final provider = widget.image;
    final isResized = provider is ResizeImage;
    if (!isResized) {
      _recordUncachedImage(element, provider);
    }
    return;
  }

  // DecorationImage in BoxDecoration — separate image loading path
  if (widget is DecoratedBox) {
    _checkDecorationImage(element, widget.decoration);
  }
}

void _checkDecorationImage(Element element, Decoration decoration) {
  if (decoration is! BoxDecoration) return;
  final image = decoration.image;
  if (image == null) return;
  final provider = image.image;
  if (provider is ResizeImage) return;

  _recordUncachedImage(element, provider);
}
```

Extract common image recording logic into `_recordUncachedImage` (currently inline in `checkElement`):

```dart
void _recordUncachedImage(Element element, ImageProvider provider) {
  final sourceName = extractSourceName(provider);
  _uncachedImages.add(UncachedImageInfo(
    sourceName: sourceName,
    ancestorChain: buildAncestorChain(element),
  ));
  final ro = element.renderObject;
  if (ro != null) {
    final rect = getGlobalRect(ro);
    if (rect != null) {
      final widgetName = element.widget is Image ? 'Image' : 'DecoratedBox';
      _highlights.add(WidgetHighlight(
        rect: rect,
        widgetName: widgetName,
        severity: IssueSeverity.warning,
        detectorName: 'Image',
        detail: 'Uncached ${_providerTypeName(provider)}: $sourceName\n'
            'Add cacheWidth/cacheHeight or wrap in ResizeImage',
      ));
    }
  }
}
```

**Note:** `Container` is not checked separately — `Container` with `decoration` internally creates a `DecoratedBox`, so the tree walk will encounter the `DecoratedBox` element directly.

**Files:** `lib/src/detectors/image_memory_detector.dart`, corresponding tests.

**Risk:** Very low. Additive detection — existing `Image` detection unchanged. Same stableId (`uncached_images`) so existing suppression rules apply.

---

### v10.4: GpuPressureDetector runtimeType.toString() on Hot Path

**Effort:** Small | **Theme:** Accuracy + Performance | **Impact:** Eliminates `runtimeType.toString()` allocation for every element with a renderObject, and for every highlight

**Problem:** `GpuPressureDetector` (`gpu_pressure_detector.dart:102-129`) uses `ro.runtimeType.toString()` with `contains()` for type matching on every element in `afterElement`. This allocates a `String` per element even though only 4 specific render object types matter. The v9.1 fix added a correct `is RenderOpacity` guard for the opacity value check, but the initial type matching still uses the string approach.

Additionally, the highlight at line 122 uses `element.widget.runtimeType.toString()` when the widget type is already known from the render object type.

Current code at line 102-128:

```dart
final typeName = ro.runtimeType.toString();
if (typeName.contains('RenderOpacity') ||
    typeName.contains('RenderClipPath') ||
    typeName.contains('RenderBackdropFilter') ||
    typeName.contains('RenderShaderMask')) {
  if (ro is RenderOpacity) {
    final val = ro.opacity;
    if (val >= 1.0 || val <= 0.0) return;
  }
  if (subtreeSize > 5) {
    _expensiveNodes.add('$typeName ($subtreeSize descendants)');
    final rect = getGlobalRect(ro);
    if (rect != null) {
      _highlights.add(WidgetHighlight(
        rect: rect,
        widgetName: element.widget.runtimeType.toString(), // ← line 122
        // ...
```

**Fix:** Replace string-based matching with direct `is` checks. `RenderClipPath`, `RenderBackdropFilter`, and `RenderShaderMask` are all public classes exported from `package:flutter/rendering.dart` (already imported at line 1).

```dart
void afterElement(Element element) {
  final subtreeSize = _subtreeSizeStack.removeLast();
  if (_subtreeSizeStack.isNotEmpty) {
    _subtreeSizeStack.last += subtreeSize + 1;
  }

  final ro = element.renderObject;
  if (ro == null) return;

  // Direct type checks — no runtimeType.toString() allocation.
  String? typeName;
  if (ro is RenderOpacity) {
    final val = ro.opacity;
    if (val >= 1.0 || val <= 0.0) return; // no-op or short-circuit
    typeName = 'RenderOpacity';
  } else if (ro is RenderClipPath) {
    typeName = 'RenderClipPath';
  } else if (ro is RenderBackdropFilter) {
    typeName = 'RenderBackdropFilter';
  } else if (ro is RenderShaderMask) {
    typeName = 'RenderShaderMask';
  }

  if (typeName == null) return;

  if (subtreeSize > 5) {
    _expensiveNodes.add('$typeName ($subtreeSize descendants)');
    final rect = getGlobalRect(ro);
    if (rect != null) {
      _highlights.add(WidgetHighlight(
        rect: rect,
        widgetName: typeName, // known from type check — no toString()
        severity: IssueSeverity.warning,
        detectorName: 'GPU',
        detail: '$typeName with $subtreeSize descendants',
      ));
    }
  }
}
```

**Files:** `lib/src/detectors/gpu_pressure_detector.dart`, corresponding tests.

**Risk:** Very low. Behavioral change: the `contains()` approach matched any render object whose type name *contains* one of the target strings. Notably, `contains('RenderOpacity')` also matched `RenderAnimatedOpacity` — but `RenderAnimatedOpacity` extends `RenderProxyBox` (NOT `RenderOpacity`) and uses composited layer opacity rather than `saveLayer`. It also sets `isRepaintBoundary = true` when animating, so it already isolates its subtree. The current `contains()` match on `RenderAnimatedOpacity` was a **false positive**. The `is RenderOpacity` change improves accuracy by correctly excluding it.

---

### v10.5: LayoutBottleneckDetector runtimeType.toString() on Hot Path

**Effort:** Small | **Theme:** Accuracy + Performance | **Impact:** Eliminates `runtimeType.toString()` in both `checkElement` and `afterElement` for every element with a renderObject

**Problem:** `LayoutBottleneckDetector` (`layout_bottleneck_detector.dart:50-54, 77-82`) uses `ro.runtimeType.toString()` with `contains('RenderIntrinsicHeight')` / `contains('RenderIntrinsicWidth')` in both `checkElement` and `afterElement`. This means two `toString()` allocations per element that has a renderObject.

Current `checkElement` at line 50-54:

```dart
final ro = element.renderObject;
if (ro != null) {
  final typeName = ro.runtimeType.toString();
  if (typeName.contains('RenderIntrinsicHeight') ||
      typeName.contains('RenderIntrinsicWidth')) {
```

Current `afterElement` at line 77-82 — identical pattern, second `toString()` per element.

**Fix:** Check at widget level instead of render object level. `IntrinsicHeight` and `IntrinsicWidth` are public widget classes — there's a 1:1 mapping to `RenderIntrinsicHeight`/`RenderIntrinsicWidth`. Widget-level checks avoid renderObject access entirely.

```dart
@override
void checkElement(Element element) {
  final widget = element.widget;
  if (widget is IntrinsicHeight || widget is IntrinsicWidth) {
    final isNested = _intrinsicDepth > 0;
    final widgetName = widget is IntrinsicHeight
        ? 'IntrinsicHeight'
        : 'IntrinsicWidth';
    _found.add((name: widgetName, nested: isNested));
    _intrinsicDepth++;
    final ro = element.renderObject;
    if (ro != null) {
      final rect = getGlobalRect(ro);
      if (rect != null) {
        _highlights.add(WidgetHighlight(
          rect: rect,
          widgetName: widgetName,
          severity: isNested ? IssueSeverity.critical : IssueSeverity.warning,
          detectorName: 'Layout',
          detail: isNested
              ? 'Nested intrinsic — O(N²+) layout'
              : 'Causes O(N^2) layout passes',
        ));
      }
    }
  }
}

@override
void afterElement(Element element) {
  final widget = element.widget;
  if (widget is IntrinsicHeight || widget is IntrinsicWidth) {
    _intrinsicDepth--;
  }
}
```

This also eliminates the `element.widget.runtimeType.toString()` call at line 56 — `widgetName` is now a string literal.

**Files:** `lib/src/detectors/layout_bottleneck_detector.dart`, corresponding tests.

**Risk:** Very low. `IntrinsicHeight` creates `RenderIntrinsicHeight` and `IntrinsicWidth` creates `RenderIntrinsicWidth` — this is a framework guarantee. Widget-level check is strictly equivalent and faster.

---

### v10.6: Correlator Rule — KeepAlive + MemoryPressure Escalation

**Effort:** Small | **Theme:** Enrichment | **Impact:** Cross-detector intelligence — excessive keep-alives holding pages in memory while heap is growing

**Problem:** `excessive_keep_alive:*` (from `KeepAliveDetector`, stableIds like `excessive_keep_alive:0`, `excessive_keep_alive:1` — indexed by scrollable occurrence order) and `heap_growing` / `heap_near_capacity` (from `MemoryPressureDetector`) co-occurrence is a strong signal that kept-alive pages are contributing to memory pressure. No correlation rule or causal rule connects them.

Current state: The correlator has 6 rules (suppress → merge → escalate × 2 → deduplicate → causal graph). The causal graph has 23 rules. Neither covers the keep-alive ↔ memory relationship.

**Fix — Part 1:** Add `EscalateKeepAliveMemoryRule` to `detector_correlator.dart` as Rule 5 (between existing `EscalateMemoryImageRule` and `DeduplicateRebuildRepaintRule`):

```dart
class EscalateKeepAliveMemoryRule extends CorrelationRule {
  const EscalateKeepAliveMemoryRule();

  @override
  String get name => 'EscalateKeepAliveMemory';

  @override
  List<PerformanceIssue> apply(List<PerformanceIssue> issues) {
    final hasHeapPressure = issues.any((i) =>
        i.stableId == 'heap_growing' || i.stableId == 'heap_near_capacity');
    if (!hasHeapPressure) return issues;

    // Find keep-alive issues (prefix match — stableId is 'excessive_keep_alive:$route')
    final keepAliveIndices = <int>[];
    for (var i = 0; i < issues.length; i++) {
      final id = issues[i].stableId;
      if (id != null && id.startsWith('excessive_keep_alive:')) {
        if (issues[i].confidence == IssueConfidence.possible) {
          keepAliveIndices.add(i);
        }
      }
    }
    if (keepAliveIndices.isEmpty) return issues;

    return [
      for (var i = 0; i < issues.length; i++)
        if (keepAliveIndices.contains(i))
          issues[i].copyWith(
            confidence: IssueConfidence.likely,
            detail: '${issues[i].detail}\n\n'
                '[Correlated] Heap pressure detected — '
                'kept-alive pages may be contributing to memory growth.',
          )
        else
          issues[i],
    ];
  }
}
```

Update `_rules` list order:

```dart
static const List<CorrelationRule> _rules = [
  SuppressAnimatedBuilderRule(),     // 1. suppress
  MergeRebuildSetStateRule(),        // 2. merge
  EscalateGpuCustomPainterRule(),    // 3. escalate
  EscalateMemoryImageRule(),         // 4. escalate
  EscalateKeepAliveMemoryRule(),     // 5. escalate (NEW)
  DeduplicateRebuildRepaintRule(),   // 6. deduplicate
  CausalGraphRule(),                 // 7. causal graph
];
```

**Fix — Part 2:** Add causal rules to `causal_graph.dart`:

```dart
CausalRule('excessive_keep_alive:*', 'heap_growing'),
CausalRule('excessive_keep_alive:*', 'heap_near_capacity'),
```

**Files:** `lib/src/analyzer/detector_correlator.dart`, `lib/src/analyzer/causal_graph.dart`, `test/analyzer/detector_correlator_test.dart`, `test/analyzer/causal_graph_test.dart`.

**Risk:** None. Additive rules — no existing behavior modified.

---

### v10.7: Correlator Rule — NestedScroll + LayoutBottleneck Escalation

**Effort:** Small | **Theme:** Enrichment | **Impact:** Cross-detector intelligence — nested scrolls compounding layout passes

**Problem:** `nested_scroll` / `nested_scroll_same_axis` (from `NestedScrollDetector`) inside a tree with `layout_bottleneck` (from `LayoutBottleneckDetector`) is a compounding problem — nested scrolling forces relayout of the inner scrollable's viewport, and IntrinsicHeight/Width widgets inside that subtree multiply the layout cost. No causal rule connects them.

Similarly, nested scrolling patterns often cause excessive rebuild activity when scroll notifications propagate up the tree.

**Fix:** Add causal rules to `causal_graph.dart`:

```dart
// Nested scroll → layout/rebuild chains
CausalRule('nested_scroll', 'layout_bottleneck'),
CausalRule('nested_scroll_same_axis', 'layout_bottleneck'),
CausalRule('nested_scroll', 'rebuild_activity'),
CausalRule('nested_scroll_same_axis', 'rebuild_activity'),
```

**Dependency note:** Benefits from v10.1 and v10.2 being done first — the nested scroll issues that these rules correlate should be accurate (v10.2 removes false positives, v10.1 ensures the related listview detection is complete).

**Files:** `lib/src/analyzer/causal_graph.dart`, `test/analyzer/causal_graph_test.dart`.

**Risk:** None. Additive rules.

---

### v10.8: NetworkMonitorDetector — Failed Request Detection

**Effort:** Medium | **Theme:** Enrichment | **Impact:** New signal — HTTP errors (4xx/5xx) and transport failures are invisible today

**Problem:** `NetworkMonitorDetector` (`network_monitor_detector.dart:118-136`) tracks slow, large, and frequent requests but never examines `statusCode`. Failed requests that trigger retries are a common performance pattern (retry storms) that compounds with frequency spikes. The `RequestRecord` already captures `statusCode` (including `-1` for transport failures), but no evaluation uses it.

Current `_evaluate()`:

```dart
void _evaluate() {
  _issues.clear();
  _evaluateSlowRequests();
  _evaluateLargeResponses();
  _evaluateFrequency();
  // ... no error check
}
```

**Fix — Part 1:** Add `_evaluateErrors()` to the `_evaluate()` method:

```dart
void _evaluate() {
  if (!_isEnabled) {
    _issues.clear();
    return;
  }
  _issues.clear();
  _evaluateSlowRequests();
  _evaluateLargeResponses();
  _evaluateFrequency();
  _evaluateErrors(); // NEW
  // ... existing timer cancel logic
}
```

```dart
void _evaluateErrors() {
  final now = _clock();
  final windowStart =
      now.subtract(const Duration(milliseconds: _frequencyWindowMs));
  final recentErrors = _records.where((r) =>
      r.startedAt.isAfter(windowStart) &&
      (r.statusCode >= 400 || r.statusCode == -1)).toList();

  if (recentErrors.length < 3) return;

  final errorCount = recentErrors.length;
  final transportFailures = recentErrors.where((r) => r.statusCode == -1).length;
  final serverErrors = recentErrors.where((r) => r.statusCode >= 500).length;

  final severity = errorCount >= 10 || serverErrors >= 5
      ? IssueSeverity.critical
      : IssueSeverity.warning;

  final urlDetails = recentErrors
      .take(5)
      .map((r) => '${r.method.toUpperCase()} ${_shortenUrl(r.url)} — '
          '${r.statusCode == -1 ? 'FAILED' : r.statusCode}')
      .join('\n');

  final (hint, effort) = FixHintBuilder.httpErrorSpike(
    errorCount: errorCount,
    transportFailures: transportFailures,
  );

  _issues.add(PerformanceIssue(
    stableId: 'http_error_spike',
    severity: severity,
    category: IssueCategory.network,
    confidence: IssueConfidence.confirmed,
    title: 'HTTP Error Spike: $errorCount errors in 5s',
    detail: '$errorCount HTTP errors in the last 5 seconds'
        '${transportFailures > 0 ? ' ($transportFailures transport failures)' : ''}'
        '${serverErrors > 0 ? ' ($serverErrors server errors)' : ''}.\n\n'
        '$urlDetails',
    fixHint: hint,
    fixEffort: effort,
    detectedAt: _clock(),
  ));
}
```

**Fix — Part 2:** Add `FixHintBuilder.httpErrorSpike()` to `fix_hint_builder.dart`:

```dart
static (String, FixEffort) httpErrorSpike({
  required int errorCount,
  int transportFailures = 0,
}) {
  final buffer = StringBuffer()
    ..writeln('$errorCount HTTP errors detected in a 5-second window.')
    ..writeln()
    ..writeln('Common causes:')
    ..writeln('  1. Retry storms — failed requests triggering exponential retries')
    ..writeln('  2. Backend outage — server returning 5xx errors')
    ..writeln('  3. Network connectivity — device losing connection');
  if (transportFailures > 0) {
    buffer
      ..writeln()
      ..writeln('Transport failures ($transportFailures) suggest network/DNS issues.');
  }
  buffer
    ..writeln()
    ..writeln('Fixes:')
    ..writeln('  • Add exponential backoff with jitter to retry logic')
    ..writeln('  • Implement circuit breaker pattern for repeated failures')
    ..writeln('  • Cache successful responses to reduce retry impact');
  return (buffer.toString(), FixEffort.medium);
}
```

**Fix — Part 3:** Add causal rule to `causal_graph.dart`:

```dart
CausalRule('http_error_spike', 'request_frequency'),
```

**Fix — Part 4:** Add encyclopedia entry for `http_error_spike` in `lib/src/utils/issue_explanation_builder.dart` (alongside existing `slow_request`, `large_response`, `request_frequency` entries). Follow the same `IssueExplanation` structure with `title`, `category`, `whatItMeans`, `whyItMatters`, `howToFix`, and `learnMore` fields.

**Files:** `lib/src/detectors/network_monitor_detector.dart`, `lib/src/utils/fix_hint_builder.dart`, `lib/src/utils/issue_explanation_builder.dart`, `lib/src/analyzer/causal_graph.dart`, corresponding tests.

**Risk:** Low. Additive detection — existing slow/large/frequency evaluations unchanged. New stableId `http_error_spike`.

---

### v10.9: Rebuild + RepaintBoundary Cross-Detector Enrichment

**Effort:** Small | **Theme:** Enrichment | **Impact:** Informational correlation — when high rebuild activity coincides with missing RepaintBoundary, annotate the rebuild issue

**Problem:** When `rebuild_activity` or `rebuild_debug_*` co-occurs with `missing_repaint_boundary`, the rebuild cost may be amplified by unnecessary repaint propagation. Currently no correlation rule connects these — the user sees two independent issues without understanding the compounding effect.

**Fix:** Add `EnrichRebuildRepaintBoundaryRule` to `detector_correlator.dart` as Rule 6 (before `DeduplicateRebuildRepaintRule`):

```dart
class EnrichRebuildRepaintBoundaryRule extends CorrelationRule {
  const EnrichRebuildRepaintBoundaryRule();

  @override
  String get name => 'EnrichRebuildRepaintBoundary';

  @override
  List<PerformanceIssue> apply(List<PerformanceIssue> issues) {
    final hasMissingBoundary =
        issues.any((i) => i.stableId == 'missing_repaint_boundary');
    if (!hasMissingBoundary) return issues;

    // Find rebuild issues to annotate
    final rebuildIndices = <int>[];
    for (var i = 0; i < issues.length; i++) {
      final id = issues[i].stableId;
      if (id == 'rebuild_activity' ||
          (id != null && id.startsWith('rebuild_debug_'))) {
        rebuildIndices.add(i);
      }
    }
    if (rebuildIndices.isEmpty) return issues;

    return [
      for (var i = 0; i < issues.length; i++)
        if (rebuildIndices.contains(i))
          issues[i].copyWith(
            detail: '${issues[i].detail}\n\n'
                '[Correlated] Missing RepaintBoundary detected — '
                'rebuilds may propagate unnecessary repaints.',
          )
        else
          issues[i],
    ];
  }
}
```

Update `_rules` list (after v10.6):

```dart
static const List<CorrelationRule> _rules = [
  SuppressAnimatedBuilderRule(),           // 1. suppress
  MergeRebuildSetStateRule(),              // 2. merge
  EscalateGpuCustomPainterRule(),         // 3. escalate
  EscalateMemoryImageRule(),              // 4. escalate
  EscalateKeepAliveMemoryRule(),          // 5. escalate (v10.6)
  EnrichRebuildRepaintBoundaryRule(),     // 6. enrich (v10.9)
  DeduplicateRebuildRepaintRule(),        // 7. deduplicate
  CausalGraphRule(),                      // 8. causal graph
];
```

**Note:** This is purely informational — no confidence change. The annotation helps users connect the dots between two independent findings.

**Files:** `lib/src/analyzer/detector_correlator.dart`, `test/analyzer/detector_correlator_test.dart`.

**Risk:** None. Detail-only annotation — no confidence or severity changes.

---

### v10.10: CustomPainterDetector runtimeType.toString() in Highlight

**Effort:** Small | **Theme:** Performance | **Impact:** Eliminates `element.widget.runtimeType.toString()` allocation in highlight creation for every always-repaint painter

**Problem:** `CustomPainterDetector._checkPainter()` (`custom_painter_detector.dart:79`) calls `element.widget.runtimeType.toString()` for the highlight `widgetName`. The widget type is already known — the `checkElement` guard is `widget is CustomPaint`, so the type is always `CustomPaint`.

Current code at line 78-80:

```dart
_highlights.add(WidgetHighlight(
  rect: rect,
  widgetName: element.widget.runtimeType.toString(), // ← unnecessary allocation
```

**Fix:**

```dart
_highlights.add(WidgetHighlight(
  rect: rect,
  widgetName: 'CustomPaint',
```

**Files:** `lib/src/detectors/custom_painter_detector.dart`.

**Risk:** None. The widget is always `CustomPaint` at this point — the caller (`checkElement`) already checked `widget is CustomPaint`.

---

### v10.11: RepaintDetector Unnecessary _hotCounts Map Allocation

**Effort:** Small | **Theme:** Performance | **Impact:** Eliminates new `Map` allocation in `prepareScan` every scan cycle

**Problem:** `RepaintDetector.prepareScan()` (`repaint_detector.dart:129`) allocates a new `Map` every scan cycle:

```dart
_hotCounts = {};
```

This discards the existing map and forces GC to collect it. The field type is `Map<String, int>` — `.clear()` reuses the internal hash table's memory.

**Fix:**

```dart
_hotCounts.clear();
```

**Files:** `lib/src/detectors/repaint_detector.dart`.

**Risk:** None. Behavioral equivalent — both result in an empty map. `.clear()` avoids allocation and is the pattern used by other detectors (e.g., `_issues.clear()`, `_highlights.clear()` on lines 127-128 of the same method).

---

### v10.12: NestedScrollDetector Stack Re-creation

**Effort:** Small | **Theme:** Performance | **Impact:** Eliminates new `List` allocation in `prepareScan` every scan cycle

**Problem:** `NestedScrollDetector.prepareScan()` (`nested_scroll_detector.dart:47`) creates a new `List` every scan:

```dart
_scrollAxisStack = [null];
```

This discards the existing list (with whatever capacity it grew to) and allocates a fresh one.

**Fix:**

```dart
_scrollAxisStack.clear();
_scrollAxisStack.add(null);
```

This reuses the existing list's backing store, which has already grown to accommodate the tree depth from previous scans.

**Files:** `lib/src/detectors/nested_scroll_detector.dart`.

**Risk:** None. Behavioral equivalent. The sentinel `null` value is preserved as the initial stack entry.

---

## Dependency Order

```
Tier 1 — Accuracy (all independent):
  v10.1  ListView SliverChildListDelegate detection
  v10.2  NeverScrollableScrollPhysics suppression
  v10.3  DecorationImage detection
  v10.4  GpuPressure is-checks
  v10.5  LayoutBottleneck is-checks

Tier 2 — Enrichment:
  v10.6  KeepAlive+Memory rule          (independent)
  v10.7  NestedScroll+Layout rule       (benefits from v10.1, v10.2)
  v10.8  HTTP error detection           (independent)
  v10.9  Rebuild+RepaintBoundary note   (independent)

Tier 3 — Performance (all independent):
  v10.10 CustomPainter toString
  v10.11 RepaintDetector map alloc
  v10.12 NestedScroll stack alloc
```

All milestones are independent except v10.7 (causal rules for nested scroll) which benefits from v10.1/v10.2 being done first so the issues it correlates are accurate.

## Verification

For each milestone:
1. `fvm flutter analyze` — 0 issues
2. `fvm flutter test` — all ~1,490+ tests pass
3. Add tests mirroring existing detector test structure in `test/detectors/`
4. For accuracy fixes (v10.1–v10.5): write tests with both true-positive and false-positive scenarios
5. For enrichment (v10.6–v10.9): write correlator/causal graph tests
6. For performance (v10.10–v10.12): verify behavior unchanged via existing tests
