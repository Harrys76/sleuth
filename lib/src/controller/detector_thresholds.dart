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
    this.startupPhaseWindowSeconds = 5,
    this.streamResourceSampleSeconds = 10,
    this.streamResourceMinDelta = 50,
    this.streamResourceWarmupSeconds = 20,
    this.streamResourceHeapGrowingRecencyMicros = 30000000,
    this.streamResourcePollFailureBackoffSeconds = 60,
    this.trackedResourceMaxConcurrent = 5,
    this.trackedResourceLongLivedSeconds = 300,
    this.trackedResourceMaxDistinctNames = 1000,
    this.trackedResourceSweepIntervalSeconds = 10,
  })  : assert(
          trackedResourceMaxConcurrent >= 1,
          'trackedResourceMaxConcurrent must be >= 1.',
        ),
        assert(
          trackedResourceLongLivedSeconds > 0,
          'trackedResourceLongLivedSeconds must be > 0.',
        ),
        assert(
          trackedResourceMaxDistinctNames >= 1,
          'trackedResourceMaxDistinctNames must be >= 1.',
        ),
        assert(
          trackedResourceSweepIntervalSeconds > 0,
          'trackedResourceSweepIntervalSeconds must be > 0.',
        ),
        assert(
          streamResourceSampleSeconds > 0,
          'streamResourceSampleSeconds must be > 0.',
        ),
        assert(
          streamResourceMinDelta > 0,
          'streamResourceMinDelta must be > 0.',
        ),
        assert(
          streamResourceWarmupSeconds >= 0,
          'streamResourceWarmupSeconds must be >= 0.',
        ),
        assert(
          streamResourceHeapGrowingRecencyMicros > 0,
          'streamResourceHeapGrowingRecencyMicros must be > 0.',
        ),
        assert(
          streamResourcePollFailureBackoffSeconds > 0,
          'streamResourcePollFailureBackoffSeconds must be > 0.',
        ),
        assert(
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
          startupPhaseWindowSeconds >= 1,
          'startupPhaseWindowSeconds must be >= 1.',
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

  /// Window in seconds after Dart entry within which `FrameTimingDetector`
  /// and `RebuildDetector` stamp `extraTraceArgs.lifecyclePhase: 'startup'`
  /// on emitted issues; emissions outside the window stamp `'steady'`.
  /// Operators use the tag in capture-mode trace records and audit-gate
  /// replay to filter startup-phase artefacts from steady-state regressions.
  ///
  /// **Default:** 5 seconds. Mirrors `coldStartShaderWindowSeconds` so the
  /// two lifecycle attributions stay aligned by default.
  ///
  /// **Raise this** for apps with extended initialization (heavy splash
  /// screen, runtime font loading, large asset bundles). **Lower this**
  /// for stricter steady-state attribution on snappy startup paths.
  final int startupPhaseWindowSeconds;

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

  /// Polling cadence in seconds for `StreamResourceDetector`.
  /// `getAllocationProfile` is called at most once per this interval.
  ///
  /// **Default:** 10 seconds. Low enough to detect leaks within a
  /// minute, high enough to keep the VM-service request rate
  /// sub-percent of frame budget.
  ///
  /// **Raise this** (e.g. 20 s) on slower devices where the VM
  /// AllocationProfile request adds measurable overhead. **Lower
  /// this** (e.g. 5 s) for faster detection in dev workflows.
  final int streamResourceSampleSeconds;

  /// Minimum sum of per-class instance growth (across watchlist
  /// classes that monotone-up across the sample window) above which
  /// `StreamResourceDetector` emits `stream_resource_growth.warning`.
  ///
  /// **Default:** 50 instances. Below this, growth is indistinguishable
  /// from normal route-stack subscription churn.
  ///
  /// **Raise this** for noisy apps with many legitimate broadcast
  /// streams. **Lower this** for stricter leak hunts.
  final int streamResourceMinDelta;

  /// Warmup window in seconds during which `StreamResourceDetector`
  /// suppresses emissions, measured from the detector's first
  /// post-init evaluation tick. Resets on `pause()`/`resume()` and
  /// `resetCaptureState()`.
  ///
  /// **Default:** 20 seconds. Cold-start subscription accumulation
  /// (route observers, animation tickers, image streams) inflates
  /// every watchlist class above the at-band purely from app boot.
  /// 20 s is enough to reach steady-state on most devices.
  ///
  /// **Raise this** for apps with extended initialization. **Lower
  /// this** for snappy startup paths where leak signal can dominate
  /// boot growth sooner.
  final int streamResourceWarmupSeconds;

  /// Recency window in microseconds within which a `heap_growing`
  /// emission is considered "active" for `StreamResourceDetector`'s
  /// co-fire gate. `MemoryPressureDetector.isHeapGrowingActive`
  /// returns true iff the last heap_growing emission landed within
  /// this window.
  ///
  /// **Default:** 30_000_000 µs (30 s). Longer than any single
  /// `MemoryPressureDetector` evaluation cycle so a transient
  /// no-growth tick does not flip the gate; shorter than typical
  /// session minutes so a long-resolved heap_growing does not
  /// permanently latch the stream-resource gate.
  final int streamResourceHeapGrowingRecencyMicros;

  /// Backoff in seconds applied to `StreamResourceDetector` polling
  /// after consecutive AllocationProfile fetch failures. Three
  /// consecutive null returns (VmService disconnect, isolate sentinel,
  /// timeout) pause polling for this duration.
  ///
  /// **Default:** 60 seconds. Long enough to ride out a typical hot
  /// restart; short enough that a transient disconnect does not
  /// silence the detector for the rest of the session.
  final int streamResourcePollFailureBackoffSeconds;

  /// Maximum concurrent live instances of a tracked-resource name
  /// before `TrackedResourceDetector` emits
  /// `tracked_resource_concurrent.warning`. Counts only registrations
  /// the GC has not yet finalised.
  ///
  /// **Default:** 5. Most leak patterns concentrate on a single
  /// service / subscription / socket — 5 concurrent instances
  /// indicates 5× the expected lifetime overlap.
  ///
  /// **Raise this** for apps that legitimately retain N pooled
  /// instances (e.g. connection-pool size). **Lower this** for
  /// stricter leak hunts.
  final int trackedResourceMaxConcurrent;

  /// Wall-clock seconds a tracked instance must remain alive before
  /// `TrackedResourceDetector` emits `tracked_resource_long_lived.warning`.
  ///
  /// **Default:** 300 seconds (5 minutes). Distinguishes legitimate
  /// session-long resources (DI singletons, app-scope services) from
  /// scope-bound resources that should have been disposed by now.
  ///
  /// **Raise this** for apps with long-lived feature flows (24h
  /// chat session, multi-hour video editor). **Lower this** for
  /// stricter scope-bound discipline.
  final int trackedResourceLongLivedSeconds;

  /// Maximum distinct names retained in the tracker map. When
  /// exceeded, the least-recently-emitted bucket is evicted to
  /// bound memory under name-fuzz misuse (e.g. `track('item-${i++}')`).
  ///
  /// **Default:** 1000. Real apps should have <100 distinct
  /// stable names (one per service class). The cap defends against
  /// per-instance-identity name patterns that would grow the map
  /// unboundedly.
  ///
  /// **Lower this** for memory-tight apps. **Raise this** only when
  /// a legitimate use case has >1000 stable names.
  final int trackedResourceMaxDistinctNames;

  /// Sweep cadence in seconds for `TrackedResourceDetector`. Each
  /// sweep prunes finalised references and evaluates concurrent /
  /// long-lived thresholds.
  ///
  /// **Default:** 10 seconds. Low enough to detect a leak within a
  /// minute, high enough that the sweep cost is sub-millisecond on
  /// any realistic tracker size.
  final int trackedResourceSweepIntervalSeconds;
}
