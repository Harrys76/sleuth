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
    this.profileCapturePath,
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

  /// For [EvidenceTier.runtimeVerified] and above, a repo-relative path to
  /// a captured profile-mode artifact (timeline JSON, DevTools snapshot,
  /// recorded frame batch) that backs the claim that the detector's
  /// numbers hold against a real engine in profile mode — not only against
  /// unit-test stubs driving `processRecord` directly. `reproducerOnly`
  /// tests prove the detector reacts correctly to inputs at the boundary;
  /// `runtimeVerified` additionally proves those inputs actually occur on
  /// a reference device with the claimed magnitude. The audit gate
  /// enforces this field for any detector shipping at `runtimeVerified`
  /// or stronger, closing the AB4 artifact-contract gap: without it, a
  /// tier raise to `runtimeVerified` would be indistinguishable from
  /// `reproducerOnly`.
  ///
  /// The audit gate currently only asserts file existence for this path.
  /// The first tier raise to [EvidenceTier.runtimeVerified] is expected to
  /// also add a format/parse validation step for the checked-in capture
  /// (e.g. timeline-JSON schema check) — file existence alone is
  /// insufficient for the contract.
  final String? profileCapturePath;

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
