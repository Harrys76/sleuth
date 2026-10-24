/// Semantic version `major.minor.patch` with optional `-prerelease` and
/// `+build` suffixes (semver.org 2.0.0 grammar; numeric identifiers carry
/// no leading zeros).
final RegExp _semver = RegExp(
  r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)'
  r'(?:-(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)'
  r'(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*)?'
  r'(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$',
);

/// Returns the compatibility lineage of a sleuth [version]: the major from
/// 1.0.0 on (`1.4.2` gives `1`), where a breaking change takes a major
/// release, and `major.minor` below 1.0.0 (`0.38.1` gives `0.38`), where a
/// minor release could break. A prerelease or build of a version stays in
/// that version's lineage (`1.0.0-dev.1` gives `1`). Returns null when
/// [version] is not a semver `major.minor.patch` with optional
/// `-prerelease` and `+build`.
String? versionLineage(String version) {
  final match = _semver.firstMatch(version);
  if (match == null) return null;
  final major = match[1]!;
  return major == '0' ? '$major.${match[2]}' : major;
}

/// Lineages this sidecar tolerates alongside its own pin. Each entry
/// represents a prior-release `major.minor` whose envelope shape is
/// known to be wire-compatible with the current sidecar. Drift across
/// the boundary surfaces as `version_skew_prior_lineage` (warning), not
/// `version_skew_major` (refusal), so users mid-upgrade don't lose
/// access to sleuth_mcp while one side rolls out.
///
/// Drop the entry one release after the matching app version stops
/// being supported. Each entry has a deadline-style comment for that.
const Set<String> acceptedPriorLineages = {
  // One-cycle fallback for apps still on the previous sleuth lineage
  // while the sidecar pin has advanced. Drop the entry one release
  // after the matching app version stops being supported.
  '0.38',
};
