/// Detector-specific thresholds for fine-tuning performance detection.
///
/// All fields have sensible defaults matching the built-in heuristics.
/// Every field carries a "what / default / raise / lower" doc comment so
/// you can tune with intention instead of guessing.
///
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
    this.setStateScopeOwnershipPercent = 0.5,
    this.keepAliveMax = 5,
    this.fontLoadingMaxFamilies = 3,
    this.startupTtffWarningMs = 1500,
    this.startupTtffCriticalMs = 3000,
    this.coldStartShaderWindowSeconds = 5,
    this.shaderKeyframeWindowMs = 100,
  })  : assert(
          shaderJankMs >= 0,
          'shaderJankMs must be >= 0 (got a negative value).',
        ),
        assert(
          coldStartShaderWindowSeconds >= 1,
          'coldStartShaderWindowSeconds must be >= 1.',
        ),
        assert(
          shaderKeyframeWindowMs >= 1,
          'shaderKeyframeWindowMs must be >= 1.',
        ),
        assert(
          heavyComputeGapMs >= 0,
          'heavyComputeGapMs must be >= 0 (got a negative value).',
        ),
        assert(
          gpuPressureRatio > 0,
          'gpuPressureRatio must be > 0 (ratios must be positive).',
        ),
        assert(
          memoryGrowthBytesPerSec >= 0,
          'memoryGrowthBytesPerSec must be >= 0 (got a negative value).',
        ),
        assert(
          memoryCapacityPercent >= 0.0 && memoryCapacityPercent <= 1.0,
          'memoryCapacityPercent must be in the range 0.0..1.0.',
        ),
        assert(
          setStateScopeOwnershipPercent >= 0.0 &&
              setStateScopeOwnershipPercent <= 1.0,
          'setStateScopeOwnershipPercent must be in the range 0.0..1.0.',
        ),
        assert(
          keepAliveMax >= 1,
          'keepAliveMax must be >= 1 (zero would flag every keep-alive).',
        ),
        assert(
          fontLoadingMaxFamilies >= 1,
          'fontLoadingMaxFamilies must be >= 1 (zero would flag every screen).',
        ),
        assert(
          startupTtffWarningMs >= 0,
          'startupTtffWarningMs must be >= 0.',
        ),
        assert(
          startupTtffCriticalMs >= startupTtffWarningMs,
          'startupTtffCriticalMs must be >= startupTtffWarningMs.',
        );

  /// Shader compilation duration in milliseconds above which
  /// [ShaderJankDetector] fires. Critical severity at 2× this value.
  ///
  /// **Default:** 100 ms. Shader warmup stalls are typically multi-frame
  /// events; 100 ms reliably filters cold-start compilations without
  /// misattributing ordinary long builds.
  ///
  /// **Raise this** (e.g. 150 ms) on GPU-constrained devices where 100 ms
  /// shader compiles are common and expected.
  ///
  /// **Lower this** (e.g. 50 ms) for a stricter shader-warmup audit on
  /// Impeller-enabled iOS where shader jank should be rare.
  final int shaderJankMs;

  /// Window in seconds after Dart entry within which `ShaderJankDetector`
  /// classifies a shader compile as `'cold_start'` (expected app-launch
  /// warmup). Shaders compiled outside this window classify as
  /// `'hot_path'` or `'keyframe'` depending on build-event coincidence.
  ///
  /// **Default:** 5 seconds. Covers typical app cold-start shader-warmup
  /// (2–4 s) with safety margin for slower devices.
  ///
  /// **Raise this** for apps with extended initialization (heavy splash
  /// screen, many fonts, large asset bundles). **Lower this** for stricter
  /// hot-path attribution on snappy startup paths.
  final int coldStartShaderWindowSeconds;

  /// Window in milliseconds within which a build event preceding a shader
  /// compile classifies the shader as `'keyframe'` (animation-driven /
  /// frame-triggered) rather than `'hot_path'`. The window is one-sided
  /// causal — build must come BEFORE shader.
  ///
  /// **Default:** 100 ms. Most synchronous compile-on-demand stalls happen
  /// within one or two frame budgets of the build that triggered them.
  ///
  /// **Raise this** to attribute looser correlations as keyframes (longer
  /// async pipeline). **Lower this** to require tighter causal coupling.
  final int shaderKeyframeWindowMs;

  /// UI-thread gap duration in milliseconds indicating heavy compute on
  /// the main isolate. [HeavyComputeDetector] fires at 2× this value
  /// (default fire threshold: 16 ms).
  ///
  /// **Default:** 8 ms (half a 16 ms frame budget). Fires at 16 ms, which
  /// is the point where a frame is definitively lost.
  ///
  /// **Raise this** to quiet the detector on slower devices. **Lower
  /// this** (e.g. 4 ms) for a stricter main-isolate budget audit.
  final int heavyComputeGapMs;

  /// Raster-to-UI time ratio above which [GpuPressureDetector] flags a
  /// frame as GPU-bound. Critical severity at 2× this value.
  ///
  /// **Default:** 2.0. Raster time is normally a small fraction of UI
  /// time; a ratio above 2 means the GPU is the bottleneck (excess
  /// layers, saveLayer calls, or expensive shaders).
  ///
  /// **Raise this** (e.g. 3.0) for games or intentionally GPU-heavy
  /// scenes. **Lower this** (e.g. 1.5) to catch GPU pressure earlier.
  final double gpuPressureRatio;

  /// Heap growth rate in bytes per second above which
  /// [MemoryPressureDetector] flags sustained growth.
  ///
  /// **Default:** 512 KB/sec (512,000). Evaluated over a 10 s sliding
  /// window to avoid latching on brief allocation bursts (e.g. a single
  /// image decode).
  ///
  /// **Raise this** (e.g. 2 MB/sec) for apps with legitimately bursty
  /// allocation (image-heavy feeds). **Lower this** (e.g. 128 KB/sec)
  /// for a stricter leak hunt.
  final int memoryGrowthBytesPerSec;

  /// Heap usage as a fraction of capacity (0.0–1.0) above which
  /// [MemoryPressureDetector] fires a near-capacity warning.
  ///
  /// **Default:** 0.80 (80 %). Once the Dart heap exceeds 80 % of
  /// capacity, GC frequency rises sharply and the app is one allocation
  /// burst away from a stall.
  ///
  /// **Raise this** (e.g. 0.90) for memory-tight apps that intentionally
  /// run close to the limit. **Lower this** (e.g. 0.70) for an earlier
  /// warning.
  final double memoryCapacityPercent;

  /// Minimum proportion of the owning subtree that must be dirty for
  /// [SetStateScopeDetector] to promote a rebuild hot spot into an issue.
  /// Value is a fraction in the range 0.0–1.0.
  ///
  /// **Default:** 0.5 (50 %). Chosen to suppress the 5 %–20 % "normal
  /// chatter" you see during scrolling while keeping obvious top-level
  /// setState storms (≥60 %) detectable.
  ///
  /// **Raise this** (e.g. 0.80) to only flag the most egregious
  /// scope-violations. **Lower this** (e.g. 0.30) for stricter
  /// setState-scope hygiene — expect more false positives in legitimate
  /// reactive UIs.
  final double setStateScopeOwnershipPercent;

  /// Maximum active `AutomaticKeepAlive` entries in a scrollable before
  /// [KeepAliveDetector] fires. Critical severity at 2× this value.
  ///
  /// **Default:** 5. Above this, keep-alive hoarding defeats the
  /// lazy-list memory model — every preserved item is permanently
  /// resident in RAM.
  ///
  /// **Raise this** (e.g. 15) if your UI genuinely needs many keep-alive
  /// items (a tab bar with preserved state). **Lower this** (e.g. 3)
  /// for stricter lazy-list hygiene.
  final int keepAliveMax;

  /// Maximum distinct custom font families observed on a single screen
  /// before [FontLoadingDetector] fires.
  ///
  /// **Default:** 3. Every additional family requires a glyph atlas
  /// upload; 3 families covers a typical design system (regular / medium
  /// / display) with no waste.
  ///
  /// **Raise this** (e.g. 8) for design systems with many weights or
  /// foreign-script fallbacks. **Lower this** (e.g. 2) to enforce strict
  /// font discipline.
  final int fontLoadingMaxFamilies;

  /// Time-to-first-frame in milliseconds above which [StartupDetector]
  /// fires a warning-level issue.
  ///
  /// **Default:** 1500 ms. Cold starts under 1.5 s feel instant on most
  /// devices; above this threshold the splash screen lingers noticeably.
  ///
  /// **Raise this** (e.g. 2500 ms) for complex apps with heavy
  /// initialization. **Lower this** (e.g. 800 ms) for a stricter
  /// cold-start budget.
  final int startupTtffWarningMs;

  /// Time-to-first-frame in milliseconds above which [StartupDetector]
  /// escalates to critical severity.
  ///
  /// **Default:** 3000 ms. A 3 s cold start is a retention risk on
  /// mobile — users may abandon before the first frame renders.
  ///
  /// **Raise this** (e.g. 5000 ms) for apps with known heavy init
  /// (database migrations, large asset loads). **Lower this** (e.g.
  /// 2000 ms) for stricter startup audits.
  final int startupTtffCriticalMs;
}
