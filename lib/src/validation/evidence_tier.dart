/// Evidence tier for a detector's threshold or heuristic.
///
/// Each detector and feature in Sleuth ships with a claimed tier documenting
/// how its numbers were validated. The tiers are deliberately coarse — a four-
/// valued ordinal lets a reader see at a glance how much to trust a number
/// without having to interpret a free-form sentence.
///
/// Ordering (lowest → highest): [unvalidated] < [reproducerOnly] <
/// [runtimeVerified] < [externallyCited].
///
/// The enum is **frozen** — new tiers require a semver major bump because
/// downstream consumers (docs, validation tooling, external dashboards) key
/// presentation and gating logic off the four values.
enum EvidenceTier {
  /// No validation beyond the author's intuition or a passing unit test.
  /// Surface this transparently in docs so users know to calibrate.
  unvalidated,

  /// A synthetic reproducer (test or demo app) fires the detector deterministically.
  /// Proves the detector emits on the intended pattern but does not prove the
  /// threshold is calibrated against real-world traffic.
  reproducerOnly,

  /// The detector was exercised on a real device / profile-mode run with real
  /// data, and the threshold was tuned against that observation. This is the
  /// default target tier for shipping detectors.
  runtimeVerified,

  /// The threshold traces back to an external cited source — Flutter SDK
  /// constant, dart-lang issue, Material/Cupertino spec, published benchmark,
  /// WCAG / Material Design a11y guideline. Numbers in this tier have a
  /// reference URL in their metadata.
  externallyCited,
}
