import 'evidence_tier.dart';

/// Metadata describing how a non-detector component's reliability claim
/// was validated.
///
/// Sleuth's reliability ledger covers two populations:
///
/// 1. **Detectors** (23 shipped) — each carries a [DetectorMetadata] and
///    is walked by `detector_metadata_audit_test.dart` via
///    `SleuthController.detectorsForAudit`.
/// 2. **Non-detector components** — helpers, heuristic registries, const
///    rule lists, and lifecycle machinery that make per-test threshold
///    claims without being detectors themselves (e.g. `IssueRanker`,
///    `CausalGraphRule`, VM reconnect ladder, `_frameworkWidgetDenyList`).
///    These cannot be walked through a controller; they publish
///    [ComponentMetadata] via [ValidatedComponentRegistry] and are walked
///    by `component_metadata_audit_test.dart`.
///
/// The two frameworks are intentionally parallel in shape so contributors
/// can transfer intuition. The only deliberate divergence is
/// [componentName] — detectors are named by their `runtimeType`; components
/// are `const` or utility classes with no uniform naming source.
///
/// Prefer constructing instances as `const` so components can expose them
/// from a `static const` field and register once at program start without
/// per-scan allocation.
class ComponentMetadata {
  const ComponentMetadata({
    required this.componentName,
    required this.tier,
    required this.rationale,
    this.citationUrl,
    this.reproducerPath,
    this.profileCapturePaths,
    this.bracketThreshold,
    this.bracketUnit,
    this.coveredClaimIds,
  });

  /// Canonical human-readable name for the component. Used as the registry
  /// dedupe key — registering two [ComponentMetadata] instances with the
  /// same [componentName] is idempotent (first write wins).
  ///
  /// Conventions: use the class or registry name as it appears in the
  /// source (e.g. `'IssueRanker'`, `'CausalGraphRule'`, `'_frameworkWidgetDenyList'`).
  final String componentName;

  /// Strongest evidence tier that applies to this component's numbers or
  /// heuristic.
  final EvidenceTier tier;

  /// Human-readable summary of what was validated and how. One or two
  /// sentences — full methodology lives in the validation-sprint spec.
  final String rationale;

  /// For [EvidenceTier.externallyCited], a URL pointing at the source of
  /// truth (Flutter SDK constant, dart-lang issue, published benchmark).
  /// Null for tiers below [EvidenceTier.externallyCited].
  final String? citationUrl;

  /// For [EvidenceTier.reproducerOnly] and above, a repo-relative path to
  /// the test or demo that exercises the component deterministically.
  final String? reproducerPath;

  /// For [EvidenceTier.runtimeVerified] and above, repo-relative paths to
  /// the checked-in profile-mode captures that back the claim.
  ///
  /// The plural form mirrors [DetectorMetadata.profileCapturePaths]: the
  /// bracketing rule (below / at / above) requires three captures per
  /// `runtimeVerified` claim, and singular `String?` could not express
  /// the triad without encoding a list in the string.
  final List<String>? profileCapturePaths;

  /// Numeric threshold the three captures bracket, in [bracketUnit]. Parallels
  /// [DetectorMetadata.bracketThreshold]; same audit-gate semantics. Required
  /// when [tier] is [EvidenceTier.runtimeVerified] or stronger.
  final num? bracketThreshold;

  /// Unit label for [bracketThreshold] (e.g. `'ms'`, `'bytes'`, `'frames'`).
  /// Required alongside [bracketThreshold].
  final String? bracketUnit;

  /// The set of per-claim identifiers this [tier] claim covers, for
  /// components whose evidence may cover only a subset of the claims they
  /// make. Parallels [DetectorMetadata.coveredStableIds].
  ///
  /// Required (non-null, non-empty) when [tier] is stronger than
  /// [EvidenceTier.unvalidated]. The audit gate enforces this so a
  /// component-scope `reproducerOnly` badge cannot silently overclaim
  /// coverage of claims the reproducer never exercised.
  final Set<String>? coveredClaimIds;

  // CLAUDE-R1-1: value semantics are required so
  // [ValidatedComponentRegistry.register] can detect whether a second
  // call for the same [componentName] carries *identical* metadata
  // (idempotent no-op) or *different* metadata (collision — throw).
  // Without these overrides, two const instances with the same fields
  // from different compilation units compared as non-equal via
  // `identical`, and two structurally divergent metadata claims
  // registered under the same name silently kept the first — a
  // first-write-wins footgun.

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ComponentMetadata &&
        other.componentName == componentName &&
        other.tier == tier &&
        other.rationale == rationale &&
        other.citationUrl == citationUrl &&
        other.reproducerPath == reproducerPath &&
        _listEq(other.profileCapturePaths, profileCapturePaths) &&
        other.bracketThreshold == bracketThreshold &&
        other.bracketUnit == bracketUnit &&
        _setEq(other.coveredClaimIds, coveredClaimIds);
  }

  @override
  int get hashCode => Object.hash(
        componentName,
        tier,
        rationale,
        citationUrl,
        reproducerPath,
        profileCapturePaths == null
            ? null
            : Object.hashAll(profileCapturePaths!),
        bracketThreshold,
        bracketUnit,
        coveredClaimIds == null
            ? null
            : Object.hashAllUnordered(coveredClaimIds!),
      );

  static bool _listEq(List<String>? a, List<String>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static bool _setEq(Set<String>? a, Set<String>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    if (a.length != b.length) return false;
    return a.containsAll(b);
  }

  // Surface every discriminating field so a
  // `ValidatedComponentRegistry.register` collision StateError is
  // self-diagnosing. Without this override, the default
  // `Instance of 'ComponentMetadata'` renders on both operands and the
  // operator has to hand-diff two const literals in source to find which
  // field diverged.
  @override
  String toString() {
    final buf = StringBuffer('ComponentMetadata(')
      ..write('componentName: $componentName, ')
      ..write('tier: ${tier.name}, ')
      ..write('rationale: ${_quote(rationale)}');
    if (citationUrl != null) {
      buf.write(', citationUrl: ${_quote(citationUrl!)}');
    }
    if (reproducerPath != null) {
      buf.write(', reproducerPath: ${_quote(reproducerPath!)}');
    }
    if (profileCapturePaths != null) {
      buf.write(', profileCapturePaths: $profileCapturePaths');
    }
    if (bracketThreshold != null) {
      buf.write(', bracketThreshold: $bracketThreshold');
    }
    if (bracketUnit != null) {
      buf.write(', bracketUnit: ${_quote(bracketUnit!)}');
    }
    if (coveredClaimIds != null) {
      final sorted = coveredClaimIds!.toList()..sort();
      buf.write(', coveredClaimIds: $sorted');
    }
    buf.write(')');
    return buf.toString();
  }

  static String _quote(String s) => "'${s.replaceAll("'", r"\'")}'";
}

/// Mixin that lets a non-detector component declare its validation
/// metadata in a parallel shape to [DetectorMetadataProvider].
///
/// Use this mixin for components that DO have a natural class with
/// instances (e.g. `IssueRanker`). For `const` registries and top-level
/// utilities that lack an instance, publish metadata by passing a
/// `const ComponentMetadata(...)` directly to
/// [ValidatedComponentRegistry.instance.register] from a
/// `static void registerMetadata()` entry point.
mixin ComponentMetadataProvider {
  /// Metadata for this component. Must be non-null on shipping components
  /// that register themselves.
  ComponentMetadata get validationMetadata;
}
