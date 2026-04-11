import 'package:flutter/widgets.dart';

import '../debug/debug_snapshot.dart';
import '../vm/timeline_parser.dart';
import 'performance_issue.dart';
import 'widget_highlight.dart';

/// Available detector types for configuration via [SleuthConfig.enabledDetectors].
///
/// Each value corresponds to one of the 23 performance detectors.
/// Pass a subset to [SleuthConfig] to enable only specific detectors.
enum DetectorType {
  frameTiming,
  shaderJank,
  heavyCompute,
  platformChannel,
  memoryPressure,
  repaint,
  rebuild,
  setStateScope,
  gpuPressure,
  shallowRebuildRisk,
  layoutBottleneck,
  listview,
  imageMemory,
  globalKey,
  nestedScroll,
  customPainter,
  keepAlive,
  animatedBuilder,
  opacity,
  fontLoading,
  networkMonitor,
  repaintBoundary,
  startup,
  custom,
}

/// Lifecycle classification for detectors.
///
/// Determines what data sources a detector needs to function.
enum DetectorLifecycle {
  /// Uses always-available runtime APIs (e.g. SchedulerBinding).
  /// Optionally enriched by VM Timeline data when connected.
  /// Always active regardless of VM connectivity.
  runtime,

  /// Processes VM Timeline data only (no tree scanning).
  /// Disabled when VM service is unavailable.
  vmOnly,

  /// Combines VM Timeline data with widget/render tree scanning.
  /// Degrades to structural-only evidence when VM is unavailable.
  hybrid,

  /// Scans widget/render tree only (no VM data needed).
  /// Always available regardless of VM connectivity.
  structural,
}

/// Base class for all performance detectors.
///
/// Detectors are categorized into 4 lifecycle tiers:
/// - **[DetectorLifecycle.runtime]**: Always-available runtime APIs, optionally enriched by VM data.
/// - **[DetectorLifecycle.vmOnly]**: Use exact data from VM Timeline events.
/// - **[DetectorLifecycle.hybrid]**: Combine VM Timeline data with post-frame tree walks.
/// - **[DetectorLifecycle.structural]**: Use post-frame tree walks only (1x/sec throttled).
abstract class BaseDetector {
  const BaseDetector({
    required this.type,
    required this.lifecycle,
    required this.name,
    required this.description,
    this.key,
  });

  /// Stable identifier for config-driven gating of **custom** detectors.
  ///
  /// When a custom detector sets this to a non-null string, the controller
  /// consults [SleuthConfig.disabledCustomDetectorKeys] during
  /// initialization: if the key is present, the detector is constructed
  /// but starts with `isEnabled == false`.
  ///
  /// Built-in detectors leave this null — their on/off state is controlled
  /// via [SleuthConfig.enabledDetectors] (by [DetectorType]), not by key.
  /// A null key means "I don't participate in config-driven gating."
  ///
  /// Keys should be unique per logical detector. If two detectors share a
  /// key and that key is in the disabled set, both are disabled.
  final String? key;

  /// The detector type identifier used for configuration.
  final DetectorType type;

  /// Lifecycle classification determining data source requirements.
  final DetectorLifecycle lifecycle;

  /// Human-readable name of this detector (e.g., "Frame Timing").
  final String name;

  /// Short description of what this detector checks.
  final String description;

  /// Whether this detector needs VM service data to function.
  /// [DetectorLifecycle.runtime] detectors benefit from VM data but don't require it.
  bool get requiresVm => lifecycle == DetectorLifecycle.vmOnly;

  /// Whether this detector scans the widget/render tree.
  bool get requiresTreeScan =>
      lifecycle == DetectorLifecycle.hybrid ||
      lifecycle == DetectorLifecycle.structural;

  /// Prepare for a new scan cycle. Called once before the unified tree walk.
  ///
  /// Override to clear accumulated state, issues, highlights, and
  /// initialise per-scan accumulators.
  void prepareScan(BuildContext context) {}

  /// Check a single element during the unified tree walk.
  ///
  /// Called once per element in depth-first order. Detectors inspect the
  /// element's widget/render object and accumulate findings. Local nested
  /// walks (e.g. counting children) are permitted within this method.
  void checkElement(Element element) {}

  /// Called after an element's children have all been visited.
  ///
  /// Override only if you need depth or nesting tracking (e.g. scroll-axis
  /// stack, depth counter). Default is a no-op.
  void afterElement(Element element) {}

  /// Finalise the scan: process accumulated data and create issues.
  ///
  /// Called once after the unified tree walk completes.
  void finalizeScan() {}

  /// Called when the tree walk completed without exceptions.
  ///
  /// Detectors that track cross-scan state (e.g. rebuild baselines) can
  /// override this to gate state promotion on walk completeness, rather
  /// than inferring it from internal bookkeeping. Default is a no-op.
  void notifyWalkCompleted() {}

  /// Scan the widget/render tree for issues.
  ///
  /// Default implementation runs a single-detector walk using the unified
  /// walk methods ([prepareScan], [checkElement], [afterElement],
  /// [finalizeScan]). The controller bypasses this and calls those methods
  /// directly in a unified walk for better performance.
  ///
  /// Custom detectors may override this directly for backward compatibility.
  void scanTree(BuildContext context) {
    if (!isEnabled) return;
    prepareScan(context);
    void visitor(Element element) {
      checkElement(element);
      element.visitChildren(visitor);
      afterElement(element);
    }

    try {
      context.visitChildElements(visitor);
      notifyWalkCompleted();
    } catch (e, s) {
      assert(() {
        debugPrint('Sleuth: detector tree walk failed: $e\n$s');
        return true;
      }());
    }
    finalizeScan();
  }

  /// Current list of detected issues. Reset each analysis cycle.
  List<PerformanceIssue> get issues;

  /// Highlight candidates collected during the last scan.
  /// Empty for detectors that don't produce visual highlights.
  List<WidgetHighlight> get highlights => const [];

  /// Whether this detector is currently active.
  bool get isEnabled;

  /// Enable or disable this detector.
  set isEnabled(bool value);

  /// Called with debug callback data when available.
  ///
  /// Only invoked in debug mode when `enableDebugCallbacks` is true.
  /// Detectors MUST use [DebugSnapshot.elapsed] to normalize counts
  /// to per-second rates before applying thresholds.
  void updateDebugSnapshot(DebugSnapshot snapshot) {}

  /// Triggers issue evaluation using whatever data has been staged.
  ///
  /// Unlike [scanTree], this does NOT walk the element tree — it only
  /// evaluates already-accumulated data (VM window counts, debug snapshots).
  /// Called by the controller in `_onTimelineData` so that full-mode
  /// verdicts see up-to-date rebuild/repaint issues without waiting for
  /// the next scan tick.
  void evaluateNow() {}

  /// Update VM connectivity state.
  ///
  /// Hybrid detectors override this to degrade analysis when VM disconnects.
  set vmConnected(bool value) {}

  /// Process VM timeline data.
  ///
  /// No-op for [DetectorLifecycle.structural] detectors.
  /// Override in vmOnly and hybrid detectors.
  void processTimelineData(ParsedTimelineData data) {}

  /// Dispose of any resources held by this detector.
  void dispose();
}
