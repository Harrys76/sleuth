/// Returns the `major.minor` pair that defines a sleuth pre-1.0
/// compatibility lineage. Pre-1.0 semver treats minor bumps as breaking,
/// so the lineage boundary sits at the minor level. Once sleuth reaches
/// 1.0, switch this to return `parts[0]` only.
String versionLineage(String semver) {
  final parts = semver.split('.');
  if (parts.length < 2) return semver;
  return '${parts[0]}.${parts[1]}';
}

/// Lineages this sidecar tolerates alongside its own pin. Each entry
/// represents a prior-release `major.minor` whose envelope shape is
/// known to be wire-compatible with the current sidecar. Drift across
/// the boundary surfaces as `version_skew_minor` (warning), not
/// `version_skew_major` (refusal), so users mid-upgrade don't lose
/// access to sleuth_mcp while one side rolls out.
///
/// Drop the entry one release after the matching app version stops
/// being supported. Each entry has a deadline-style comment for that.
const Set<String> acceptedPriorLineages = {
  // One-cycle fallback for apps still on the previous sleuth lineage
  // while the sidecar pin has advanced. Drop the entry one release
  // after the matching app version stops being supported.
  '0.33',
};
