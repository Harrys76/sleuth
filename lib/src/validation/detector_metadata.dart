import 'evidence_tier.dart';

/// Metadata describing how a detector's threshold or heuristic was validated.
///
/// Each detector is expected to expose a [DetectorMetadata] describing the
/// strongest evidence supporting its current numbers. The metadata is surfaced
/// in docs and consumed by the `detector_metadata_audit_test.dart` CI gate
/// (live since v0.16.1) which walks the [SleuthController]'s registered
/// detector instances and enforces that every shipped detector mixes in
/// [DetectorMetadataProvider] and returns a non-null metadata entry with a
/// non-empty rationale and tier-appropriate fields (`reproducerOnly` and
/// above require a `reproducerPath`; `externallyCited` requires a
/// `citationUrl`).
///
/// Prefer constructing instances as `const` so detectors can return them from
/// [DetectorMetadataProvider.validationMetadata] without allocation at scan
/// time.
class DetectorMetadata {
  const DetectorMetadata({
    required this.tier,
    required this.rationale,
    this.citationUrl,
    this.reproducerPath,
    this.profileCapturePaths,
    this.bracketThreshold,
    this.bracketUnit,
    this.bracketStableId,
    this.bracketSeverityLabel,
    this.coveredStableIds,
    this.parametricFamilies,
    this.perStableIdTier,
    this.coveredThresholds,
    this.aboveCeilingMultiplier,
    this.bracketAtTolerance,
    this.bracketRequireUniqueDetectedAtMicros = false,
    this.observedAxisArgKey,
    this.observedAxisTolerance = 0.25,
    this.observedAxisReduction = 'max',
  });

  /// Strongest evidence tier that applies to this detector's numbers.
  final EvidenceTier tier;

  /// Human-readable summary of *what* was validated and *how*. One or two
  /// sentences — full methodology lives in the validation spec doc.
  final String rationale;

  /// For [EvidenceTier.externallyCited], a URL pointing at the source of
  /// truth (Flutter SDK constant, dart-lang issue, published benchmark).
  /// Null for tiers below [EvidenceTier.externallyCited].
  final String? citationUrl;

  /// For [EvidenceTier.reproducerOnly] and above, a repo-relative path to
  /// the test or demo that exercises the detector deterministically.
  final String? reproducerPath;

  /// For [EvidenceTier.runtimeVerified] and above, repo-relative paths to
  /// the checked-in profile-mode captures (timeline JSON, DevTools export,
  /// recorded frame batch) that back the claim that the detector's numbers
  /// hold against a real engine in profile mode — not only against
  /// unit-test stubs driving the detector's inputs directly.
  /// `reproducerOnly` tests prove the detector reacts correctly to inputs
  /// at the boundary; `runtimeVerified` additionally proves those inputs
  /// actually occur on a reference device with the claimed magnitude.
  ///
  /// The bracketing rule (below / at / above threshold, observed ±10%) that
  /// `runtimeVerified` imposes requires three captures per claim, so this
  /// field is a `List<String>` rather than a single path. The audit gate
  /// enforces non-empty content when [tier] is [EvidenceTier.runtimeVerified]
  /// or stronger, closing the AB4 artifact-contract gap: without it, a tier
  /// raise to `runtimeVerified` would be indistinguishable from
  /// `reproducerOnly`. Each path in the list is additionally run through
  /// `ProfileCaptureSchema.parseFile` so a malformed capture fails the gate.
  final List<String>? profileCapturePaths;

  /// For [EvidenceTier.runtimeVerified] and above, the numeric threshold the
  /// three captures in [profileCapturePaths] are required to bracket. The
  /// audit gate calls `ProfileCaptureSchema.validateBracket(threshold:
  /// bracketThreshold, unit: bracketUnit, ...)` on the triad, which enforces
  /// `below.observed < threshold`, `threshold <= at.observed <= threshold *
  /// 1.1`, and `above.observed > threshold`. Without this field the audit
  /// can confirm the three captures exist and parse cleanly but cannot
  /// verify the bracketing rule itself — a tier raise could ship with three
  /// captures all recorded well below (or well above) the threshold.
  ///
  /// Required when [tier] is [EvidenceTier.runtimeVerified] or stronger;
  /// null otherwise.
  final num? bracketThreshold;

  /// Unit label for [bracketThreshold] (e.g. `'ms'`, `'bytes'`, `'frames'`).
  /// Required alongside [bracketThreshold].
  final String? bracketUnit;

  /// The stableId whose `sleuth.issue.<stableId>.<severity>` trace record
  /// the audit gate requires inside the at+above captures. Required when
  /// [tier] is [EvidenceTier.runtimeVerified] or stronger — without it
  /// the schema cannot prove the detector actually fired during the
  /// captured scenario; the bracket alone proves only that the captured
  /// magnitudes flank the threshold, not that the detector reacted.
  ///
  /// Pinned to ONE stableId per metadata block: a tier raise covers a
  /// specific severity threshold of a specific issue family, and the
  /// captured scenario must have produced THAT issue. Detectors that
  /// emit multiple issue families at runtimeVerified-quality evidence
  /// each get their own metadata entry (or per-family declaration on a
  /// future schema extension).
  final String? bracketStableId;

  /// Severity label (`'warning'` or `'critical'`, the wire-format string
  /// from `IssueSeverity.<label>.name`) that the audit gate's
  /// trace-record check must match. Required alongside [bracketStableId]
  /// when [tier] is [EvidenceTier.runtimeVerified] or stronger.
  ///
  /// Same severity must be the one [bracketThreshold] represents: an
  /// 8 ms warning bracket pairs with `bracketSeverityLabel: 'warning'`;
  /// a `.critical` event would not satisfy that audit and vice versa.
  /// This pairing is what prevents a tier raise from claiming evidence
  /// for one severity tier while the captures actually exercised the
  /// adjacent tier.
  final String? bracketSeverityLabel;

  /// The set of stable issue IDs this [tier] claim covers, for detectors
  /// that emit more than one family of issue. `NetworkMonitorDetector`, for
  /// example, emits `slow_request`, `large_response`, `request_frequency`,
  /// `http_error_spike`, and `high_frequency_same_path`; v0.16.1's
  /// reproducer only validates `slow_request`, so its metadata pins
  /// `coveredStableIds: {'slow_request'}` and the remaining families are
  /// implicitly [EvidenceTier.unvalidated].
  ///
  /// Required (non-null, non-empty) when [tier] is stronger than
  /// [EvidenceTier.unvalidated]. The audit gate enforces this so a
  /// detector-scope `reproducerOnly` badge cannot silently overclaim
  /// coverage of issue families the reproducer never exercised.
  ///
  /// For parameterized stable IDs (e.g. `high_frequency_same_path:<hash>`),
  /// name the family prefix up to the `:` separator until canonical
  /// issue-family identifiers land (targeted for v0.16.2+ or the next
  /// multi-family tier raise).
  final Set<String>? coveredStableIds;

  /// Underscore-parametric family prefixes. Each entry is a family name
  /// without trailing separator; the audit matcher credits emitted
  /// stableIds that start with `'<family>_'` AND have a non-empty suffix.
  ///
  /// Example: declaring `{'repaint_debug'}` credits literals like
  /// `'repaint_debug_CustomPaint'` (`<family>_<typeName>`). A bare
  /// `'repaint_debug_'` (empty suffix) is rejected — empty-suffix matches
  /// are treated as invalid parametric instances.
  ///
  /// Peer namespace to [coveredStableIds] — the two declaration sets are
  /// tracked independently by the audit's reproducer walker. A literal
  /// credited under one namespace does NOT satisfy declarations in the
  /// other. Every declared family here must be matched by at least one
  /// credited literal of the form `<family>_<non-empty-suffix>` in the
  /// reproducer.
  ///
  /// Used for parametric stableIds that use `_` as their family-separator
  /// (e.g., `repaint_debug_<typeName>`, `rebuild_debug_<typeName>`),
  /// which do not fit the `:` prefix convention of [coveredStableIds].
  ///
  /// Contract rules enforced by the audit metadata gate:
  /// - At least one of [coveredStableIds] or [parametricFamilies] must
  ///   be non-empty when [tier] is stronger than
  ///   [EvidenceTier.unvalidated] — either namespace satisfies the
  ///   "must pin stable IDs" invariant on its own.
  /// - Declaring the same name in both namespaces is rejected at audit
  ///   time. Pick one: exact (or `<family>:<param>`) for bare families,
  ///   `_`-prefix for underscore-parametric families.
  /// - Entries are trim/empty validated; a blank or whitespace-only
  ///   entry fails the metadata gate.
  final Set<String>? parametricFamilies;

  /// Per-family evidence-tier overrides (since v0.18.3). Lets a detector
  /// honestly declare a mixed-tier ledger: e.g. `NetworkMonitor` covers 5
  /// stable IDs (`slow_request`, `large_response`, `request_frequency`,
  /// `http_error_spike`, `high_frequency_same_path`) of which only
  /// `slow_request.warning` is backed by on-device captures. Without this
  /// field the metadata model forced an all-or-nothing choice: either
  /// over-claim by tagging the whole detector `runtimeVerified`, or
  /// under-claim by holding the whole detector at `reproducerOnly`.
  ///
  /// Semantics:
  /// - The detector's [tier] field is the *base* (minimum) tier — every
  ///   covered family is at least at [tier].
  /// - Each entry in [perStableIdTier] *raises* a specific family above
  ///   the base. Effective per-family tier = `perStableIdTier[id] ?? tier`.
  /// - The audit gate's tier-specific field requirements
  ///   (`profileCapturePaths`, `bracketThreshold`, `bracketStableId`,
  ///   etc.) trigger off the *effective max tier* across all declared
  ///   families, so a detector that raises one family to
  ///   `runtimeVerified` still has to provide its capture triad.
  ///
  /// Audit invariants enforced when non-null:
  /// - Every key must be present in [coveredStableIds] (parametric family
  ///   declarations are not eligible for per-family raises since they
  ///   describe a literal-prefix family, not a single stableId).
  /// - Every value must be `>= tier` — entries are raises only, never
  ///   downgrades. A downgrade would conflict with the base-as-minimum
  ///   semantics and is rejected at audit time.
  /// - When bracket fields are set, the `bracketStableId` must have an
  ///   effective tier of `runtimeVerified` or stronger; otherwise the
  ///   bracket evidence is unmoored from any family it claims to validate.
  /// - The map must be non-empty when non-null. An empty map is
  ///   functionally a no-op and rejected as misconfiguration (signals
  ///   an in-progress edit or copy-paste error).
  ///
  /// **Convention for single-family detectors**: a detector that emits
  /// exactly one family does NOT need [perStableIdTier]. Set [tier] to
  /// the family's true evidence level directly. The pattern exists for
  /// detectors with multiple families where a single base tier would
  /// over- or under-claim. Single-family detectors using base-tier
  /// raises (e.g. `tier: EvidenceTier.runtimeVerified` covering one
  /// stableId) are correct and audit-clean — no perStableIdTier
  /// indirection required.
  final Map<String, EvidenceTier>? perStableIdTier;

  /// Severity-scoped evidence boundaries for detectors that emit multiple
  /// severity tiers on the same stable ID. Entries use the form
  /// `<stableId>.<severity>` (e.g. `'slow_request.warning'`). When null,
  /// the [coveredStableIds] entries apply to every severity the detector
  /// can emit for that family — correct for single-severity detectors
  /// but overclaims when a detector has per-severity threshold semantics.
  ///
  /// Added in v0.16.4 after the NetworkMonitor tier raise demonstrated
  /// the gap: the same `slow_request` stable ID
  /// is emitted at both 1000 ms warning and 3000 ms critical, and the
  /// external NNG citation covers only the warning boundary. Without a
  /// severity dimension, a detector-level `externallyCited` tier with
  /// `coveredStableIds: {'slow_request'}` mechanically attributes the
  /// external evidence to the critical threshold too.
  final Set<String>? coveredThresholds;

  /// For [EvidenceTier.runtimeVerified] and above, the upper bound
  /// multiplier applied to the `above` capture's observed magnitude.
  /// `ProfileCaptureSchema.validateBracket` rejects the triad when
  /// `aboveObs > threshold * aboveCeilingMultiplier`. Defaults to 2.0
  /// schema-side when null. Tighten per-detector when the `above`
  /// capture must stay well below an adjacent critical tier threshold
  /// (e.g. a 1000 ms warning bracket whose `above` must stay under the
  /// 3000 ms critical to avoid dual-use evidence).
  final double? aboveCeilingMultiplier;

  /// For [EvidenceTier.runtimeVerified] and above, the relative tolerance
  /// applied to the `at` capture's observed magnitude when bracketing
  /// the threshold. `ProfileCaptureSchema.validateBracket` accepts
  /// `at.observed` in `[threshold, threshold × (1 + bracketAtTolerance)]`.
  /// Defaults to 0.10 schema-side when null (a 10 % at-band).
  ///
  /// Widen for detectors whose magnitude is hard to land precisely on
  /// device — HeavyCompute on iPhone exhibits ±60 % thermal/JIT drift
  /// between calibration and the actual scenario run, so a 10 % band is
  /// unreachable. Widening to 0.30 yields a [8, 10.4] ms at-band that
  /// still proves "at threshold" semantics with realistic recording
  /// noise. Tighten only when the magnitude is naturally stable
  /// (network latency to a loopback server, fixed-size memory
  /// allocations, etc.) — a wider band weakens the boundary claim.
  ///
  /// Must coexist with [aboveCeilingMultiplier]: the at-upper-bound
  /// (`threshold × (1 + bracketAtTolerance)`) must remain strictly
  /// below the above-ceiling (`threshold × aboveCeilingMultiplier`),
  /// otherwise the at + above bands collapse and the triad is
  /// unsatisfiable. The schema rejects this at call time.
  final double? bracketAtTolerance;

  /// Opt-in stronger schema check (since v0.18.1): when true, every
  /// in-span `sleuth.issue.<stableId>.<severity>` trace record in the
  /// at + above captures must carry a distinct `detectedAtMicros` arg.
  /// Rejects single-issue replay (N records all stamped with one
  /// microsecond) and pre-v0.18.1 capture binaries that lacked
  /// producer-side dedup.
  ///
  /// Default `false` so v0.18.0-recorded captures (which inflate
  /// naturally because their producer did not yet dedupe) keep
  /// passing the standard `requireDetectorTraceRecord` check.
  /// runtimeVerified raises whose captures were recorded under
  /// v0.18.1+ producer dedup should set this to `true` to lock in
  /// the strong evidence guarantee.
  final bool bracketRequireUniqueDetectedAtMicros;

  /// Trace-event arg key holding the detector-observed axis value,
  /// stamped by the detector via [PerformanceIssue.extraTraceArgs] (e.g.
  /// `'observedCount'` for PlatformChannelDetector's frequency axis).
  /// When non-null, the audit gate cross-checks the capture's
  /// `expectedMagnitude.observed` (a SEND-side estimate computed by
  /// the capture-helper screen) against this trace-event arg using
  /// [observedAxisTolerance], rejecting captures whose send-side and
  /// detector-observed magnitudes diverge enough to cross a bracket
  /// band boundary. Null when the detector does not export a
  /// cross-checkable observed value (most non-frequency detectors).
  ///
  /// Backward compatibility: pre-v0.19.5 captures recorded before
  /// detectors started exporting observed-axis values lack the arg
  /// and the cross-check is skipped per-record. The metadata setting
  /// stays harmless for legacy captures.
  final String? observedAxisArgKey;

  /// Tolerance for the [observedAxisArgKey] cross-check, expressed as
  /// a fraction of `expectedMagnitude.observed` (e.g. `0.25` allows
  /// observed within ±25% of expected). Default `0.25` absorbs iOS
  /// `MethodChannel` coalescing variance plus parser dedup slack.
  /// Tighten when device variance is known to be smaller; loosen for
  /// hot/throttled devices.
  final double observedAxisTolerance;

  /// Reduction strategy for selecting a single observed value when
  /// [observedAxisArgKey] cross-check finds multiple in-span trace
  /// records.
  ///
  /// Values:
  /// - `'max'` (default): pick the maximum across all in-span records.
  ///   Sound for monotone-per-emission axes (e.g.
  ///   `NetworkMonitorDetector.slow_request` per-request duration ms,
  ///   `MemoryPressureDetector.heap_growing` regression slope) and for
  ///   detectors with cooldown semantics that collapse to one fire per
  ///   scenario (`PlatformChannelDetector` frequency,
  ///   `MemoryPressureDetector.heap_growing` sustained-window).
  /// - `'last'`: pick the highest-`ts` (last) in-span record. Required
  ///   for windowed-aggregate axes whose observable is non-monotone as
  ///   the buffer grows and slides — e.g.
  ///   `FrameTimingDetector.jank_detected` percent-jank-frames over a
  ///   rolling 240-frame buffer. Early small-sample-size ratios can
  ///   spike high, settle lower as the buffer fills, then drift down on
  ///   eviction; MAX picks the early transient instead of the
  ///   operator-intended steady-state band.
  ///
  /// Default `'max'` preserves the v0.19.5 behavior of every existing
  /// runtimeVerified detector. Opt into `'last'` only for windowed-
  /// aggregate observables. The accompanying audit-anchor test should
  /// pin the chosen reduction per detector so a future drift cannot
  /// silently change semantics.
  final String observedAxisReduction;

  /// Returns the effective evidence tier for a specific stable ID,
  /// applying any [perStableIdTier] override on top of the detector's
  /// base [tier]. Returns [tier] when no override is set.
  EvidenceTier effectiveTierFor(String stableId) =>
      perStableIdTier?[stableId] ?? tier;

  /// The strongest effective tier across the base [tier] and all
  /// [perStableIdTier] entries. Drives the audit gate's
  /// tier-specific field-presence requirements when [perStableIdTier]
  /// is set: a detector at base `reproducerOnly` that raises one family
  /// to `runtimeVerified` must still satisfy the runtimeVerified
  /// field-presence checks (`profileCapturePaths`, `bracketThreshold`,
  /// etc.).
  EvidenceTier get effectiveMaxTier {
    var max = tier;
    final overrides = perStableIdTier;
    if (overrides != null) {
      for (final t in overrides.values) {
        if (t.index > max.index) max = t;
      }
    }
    return max;
  }
}

/// Mixin that lets a detector declare its validation metadata.
///
/// Detectors implement [validationMetadata] as an instance getter backed by a
/// `const DetectorMetadata(...)` literal so there is no per-scan allocation.
/// Dart does not treat static members as part of a class interface, so the
/// contract is necessarily instance-level: the audit test
/// (`detector_metadata_audit_test.dart`, live since v0.16.1) walks the
/// [SleuthController]'s registered detector instances via
/// `detectorsForAudit` — the same construction path the runtime already
/// exercises — rather than reflecting on types directly. Keep detector
/// constructors side-effect-free (field initialization only, no I/O or
/// scheduler binding) so the audit can construct them in isolation if
/// needed.
///
/// v0.16.1 seeds every shipped detector with this mixin. Most entries start
/// at [EvidenceTier.unvalidated]; subsequent milestones (v0.16.2…v0.16.N)
/// raise one detector at a time to [EvidenceTier.reproducerOnly],
/// [EvidenceTier.runtimeVerified], or [EvidenceTier.externallyCited] with
/// the supporting reproducer, profile-mode capture, or cited source
/// committed alongside the tier raise. `NetworkMonitorDetector` is the
/// first detector to ship at `reproducerOnly` (v0.16.1).
mixin DetectorMetadataProvider {
  /// Metadata for this detector. Must be non-null on shipping detectors —
  /// the audit test gates this.
  DetectorMetadata get validationMetadata;
}
