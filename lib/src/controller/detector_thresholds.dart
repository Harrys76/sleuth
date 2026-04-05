/// Detector-specific thresholds for fine-tuning performance detection.
///
/// All fields have sensible defaults matching the built-in heuristics.
/// Override individual values to adjust sensitivity for your app:
///
/// ```dart
/// SleuthConfig(
///   thresholds: DetectorThresholds(
///     shaderJankMs: 50,         // Flag shaders >50ms (default 100)
///     keepAliveMax: 10,         // Allow up to 10 keep-alives (default 5)
///     gpuPressureRatio: 3.0,    // Tolerate higher raster/UI ratio (default 2.0)
///   ),
/// )
/// ```
class DetectorThresholds {
  const DetectorThresholds({
    this.shaderJankMs = 100,
    this.heavyComputeGapMs = 8,
    this.gpuPressureRatio = 2.0,
    this.memoryGrowthBytesPerSec = 512000,
    this.memoryCapacityPercent = 0.80,
    this.shallowRebuildMaxDepth = 3,
    this.setStateScopeOwnershipPercent = 0.5,
    this.keepAliveMax = 5,
    this.animatedBuilderMinSubtreeSize = 50,
    this.fontLoadingMaxFamilies = 3,
  });

  /// Shader compilation duration (ms) above which the detector fires.
  /// Critical severity at 2× this value.
  final int shaderJankMs;

  /// UI thread gap duration (ms) indicating heavy compute.
  /// Detection triggers at 2× this value (default 16ms).
  final int heavyComputeGapMs;

  /// Raster-to-UI time ratio above which GPU pressure is flagged.
  /// Critical severity at 2× this value.
  final double gpuPressureRatio;

  /// Heap growth rate (bytes/sec) above which memory pressure is flagged.
  /// Default ~512 KB/sec.
  final int memoryGrowthBytesPerSec;

  /// Heap usage as fraction of capacity (0.0–1.0) above which near-capacity
  /// warnings fire. Default 0.80 (80%).
  final double memoryCapacityPercent;

  /// Maximum widget tree depth for shallow rebuild risk detection.
  /// StatefulWidgets at or above this depth are flagged.
  final int shallowRebuildMaxDepth;

  /// Minimum subtree ownership ratio (0.0–1.0) for setState scope detection.
  /// Fires when a StatefulWidget's subtree exceeds this fraction of the tree.
  final double setStateScopeOwnershipPercent;

  /// Maximum AutomaticKeepAlive widgets before the detector fires.
  /// Critical severity at 2× this value.
  final int keepAliveMax;

  /// Minimum AnimatedBuilder subtree size (widget count) to flag missing
  /// `child` parameter. Smaller subtrees are ignored as low-impact.
  final int animatedBuilderMinSubtreeSize;

  /// Maximum custom font families on a single screen before the detector fires.
  final int fontLoadingMaxFamilies;
}
