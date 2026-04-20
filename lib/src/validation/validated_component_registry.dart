import 'package:meta/meta.dart';

import 'component_metadata.dart';

/// Package-internal registry of [ComponentMetadata] for non-detector
/// components that make per-test reliability claims.
///
/// Detectors expose their metadata through
/// `SleuthController.detectorsForAudit` — a concrete, enumerable list.
/// Non-detector components (const registries, singleton helpers, rule
/// tables) have no such enumeration surface, so they publish their
/// metadata here instead. `component_metadata_audit_test.dart` reads
/// [all] to enforce the same 5 invariants the detector audit gate does.
///
/// ## Registration model: explicit + append-only + idempotent
///
/// Dart top-level and `static final` initializers are lazy — they fire
/// only on first read. A registry that self-populates from a list of
/// `ComponentMetadata._register()` top-level invocations would silently
/// miss entries whose owning files are never imported by the test
/// target. Each component must instead expose a
/// `static void registerMetadata()` entry point that is called from the
/// audit test's `setUpAll`. The audit test thus names every expected
/// component explicitly, making "forgot to register" a compile-time
/// error instead of a silent gate bypass.
///
/// [register] is idempotent — calling it twice for the same
/// [ComponentMetadata.componentName] is a no-op, so calling
/// `registerMetadata()` from multiple test entry points (or re-running
/// inside the same isolate) does not throw or duplicate entries. The
/// registry is append-only: there is no `clear()` or `unregister()`,
/// because `flutter test` runs each test file in a fresh isolate, so
/// registry state cannot leak across files.
///
/// ## Why `@internal`
///
/// Only the audit test and Sleuth's own components should touch this
/// registry. Third-party callers who want to expose validation claims
/// about their own code should do so through their own surfaces — the
/// Sleuth package's reliability ledger covers Sleuth's components, not
/// arbitrary downstream ones. The `@internal` annotation lets
/// `package:meta` lint-flag cross-package usage.
class ValidatedComponentRegistry {
  ValidatedComponentRegistry._();

  /// The single package-wide registry instance.
  static final ValidatedComponentRegistry instance =
      ValidatedComponentRegistry._();

  final List<ComponentMetadata> _components = [];
  final Map<String, ComponentMetadata> _byName = {};

  /// Records [metadata] in the registry.
  ///
  /// Idempotent on value-equal metadata: calling twice for the same
  /// [ComponentMetadata.componentName] with a metadata instance that
  /// compares `==` to the previous one is a no-op.
  ///
  /// Throws [StateError] on **collision**: two registrations under the
  /// same [ComponentMetadata.componentName] that differ in any field.
  /// Without this check, the old first-write-wins no-op silently kept
  /// stale metadata when a second caller registered a diverged claim
  /// (e.g. a tier raise applied only in one compilation unit's const
  /// literal). Value-equality on [ComponentMetadata] (see its
  /// `operator ==` / `hashCode`) makes the comparison robust across
  /// compilation units that build structurally identical `const`
  /// literals.
  @internal
  void register(ComponentMetadata metadata) {
    final existing = _byName[metadata.componentName];
    if (existing != null) {
      if (existing == metadata) return;
      throw StateError(
        'ValidatedComponentRegistry collision for '
        '"${metadata.componentName}": a different ComponentMetadata is '
        'already registered under this name. Existing=$existing, '
        'incoming=$metadata. Fix: pick one canonical declaration and '
        'register from a single entry point.',
      );
    }
    _byName[metadata.componentName] = metadata;
    _components.add(metadata);
  }

  /// All registered [ComponentMetadata], in registration order.
  /// Returned as an unmodifiable view so callers cannot mutate the
  /// underlying registry state.
  List<ComponentMetadata> get all => List.unmodifiable(_components);

  /// The set of [ComponentMetadata.componentName] values registered so
  /// far. Exposed for tests that want to assert on presence/absence
  /// without walking the full [all] list.
  @visibleForTesting
  Set<String> get registeredNamesForTest => Set.unmodifiable(_byName.keys);
}
