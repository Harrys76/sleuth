/// Returns the `major.minor` pair that defines a sleuth pre-1.0
/// compatibility lineage. Pre-1.0 semver treats minor bumps as breaking,
/// so the lineage boundary sits at the minor level. Once sleuth reaches
/// 1.0, switch this to return `parts[0]` only.
String versionLineage(String semver) {
  final parts = semver.split('.');
  if (parts.length < 2) return semver;
  return '${parts[0]}.${parts[1]}';
}
