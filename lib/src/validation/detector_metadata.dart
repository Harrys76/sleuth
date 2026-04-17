import 'evidence_tier.dart';

/// Metadata describing how a detector's threshold or heuristic was validated.
///
/// Each detector is expected to expose a [DetectorMetadata] describing the
/// strongest evidence supporting its current numbers. The metadata is surfaced
/// in docs and consumed by the `detector_metadata_audit_test.dart` CI gate
/// which enforces that every detector ships with a non-null metadata entry.
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
}

/// Mixin that lets a detector declare its validation metadata.
///
/// Detectors implement [validationMetadata] as an instance getter backed by a
/// `const DetectorMetadata(...)` literal so there is no per-scan allocation.
/// Dart does not treat static members as part of a class interface, so the
/// contract is necessarily instance-level: the audit test
/// (`detector_metadata_audit_test.dart`, landing with the first per-detector
/// validation PR) walks the [SleuthController]'s registered detector
/// instances — the same construction path the runtime already exercises —
/// rather than reflecting on types directly. Keep detector constructors
/// side-effect-free (field initialization only, no I/O or scheduler binding)
/// so the audit can construct them in isolation if needed.
mixin DetectorMetadataProvider {
  /// Metadata for this detector. Must be non-null on shipping detectors —
  /// the audit test gates this.
  DetectorMetadata get validationMetadata;
}
