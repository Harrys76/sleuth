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
    this.coveredStableIds,
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
