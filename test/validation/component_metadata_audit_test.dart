// IDE analyzer false-positive: dart:core RegExp uses @Deprecated.implement
// (fires only on subclassing). Remove when analyzer-server recognizes the
// implement-only kind.
// ignore_for_file: deprecated_member_use
// Audit gate for non-detector components that publish a per-test
// reliability claim via `ValidatedComponentRegistry`. Mirrors the five
// invariants enforced by `detector_metadata_audit_test.dart`:
//
//   1. Every expected component is registered (explicit name list —
//      "forgot to register" is a test failure, not a silent no-op).
//   2. Metadata is non-null with a rationale of reasonable length.
//   3. Tier-appropriate fields are populated:
//        reproducerOnly   → `reproducerPath` non-null
//        runtimeVerified  → `reproducerPath` AND 3-capture bracket
//        externallyCited  → `citationUrl` (http/https + authority),
//                           `reproducerPath`, and 3-capture bracket
//        any tier > unvalidated → non-empty `coveredClaimIds`.
//   4. If a `reproducerPath` is present AND the test is running from
//      the repo root: the path resolves inside the repo (no absolute
//      paths / `..` traversal / symlink escapes), the file exists, it
//      contains `test(` / `testWidgets(` outside of line AND block
//      comments (CLAUDE-R4-1), AND the file references the component's
//      `componentName` by name (AB3 parity with the detector gate —
//      CODEX-R3-2).
//   5. If `profileCapturePaths` is non-empty: every file is inside the
//      repo, exists on disk, AND parses cleanly via
//      `ProfileCaptureSchema.parseFile`.
//
// v0.16.2 hardening extracted these checkers into
// `_support/audit_invariants.dart` so the detector gate and the
// component gate share a single implementation. Gaps closed: the
// component audit had no bracket-count check and no reproducer-token
// check; both sides lacked block-comment stripping and path-traversal
// rejection; citation-URL validation was only a non-empty check.
//
// v0.16.2 ships the framework with **zero** real non-detector components
// registered. The first registration lands in v0.16.6. The real-registry
// test below therefore passes trivially on an empty list; the dormant-
// gate invariant tests exercise the gate logic against synthetic
// `ComponentMetadata` so the code path is battle-tested before the
// first real registration arrives.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/sleuth.dart';
import 'package:sleuth/src/validation/validated_component_registry.dart';

import '_support/audit_invariants.dart';

/// Components expected to appear in the registry after all
/// `registerMetadata()` entry points have fired. Grows by one entry per
/// v0.16.N milestone that raises a non-detector component's tier.
/// Empty for v0.16.2 — the first real entry lands in v0.16.6.
const List<String> _expectedRegisteredComponents = <String>[];

void main() {
  group('ComponentMetadata audit gate (v0.16.2)', () {
    test('expected components are present and no extras are registered', () {
      // Force every expected component's `registerMetadata()` entry
      // point to run here. Loop is a no-op in v0.16.2 (empty list);
      // becomes the canonical "did you forget to register?" gate as
      // components land in v0.16.6+.
      for (final name in _expectedRegisteredComponents) {
        fail('Unknown expected component: $name — dispatch not wired.');
      }

      final registered =
          ValidatedComponentRegistry.instance.registeredNamesForTest;
      expect(registered, unorderedEquals(_expectedRegisteredComponents),
          reason: 'Registry state diverges from the expected component '
              'list. Either a component registered without being added to '
              'the expected list, or an expected component did not call '
              'its registerMetadata() entry point above.');
    });

    test('invariant 2: non-null metadata with rationale >= 20 chars + period',
        () {
      final failures = _runInvariants([
        const ComponentMetadata(
          componentName: 'EmptyRationale',
          tier: EvidenceTier.unvalidated,
          rationale: '',
        ),
        const ComponentMetadata(
          componentName: 'ShortRationale',
          tier: EvidenceTier.unvalidated,
          rationale: 'too short',
        ),
        const ComponentMetadata(
          componentName: 'NoPeriod',
          tier: EvidenceTier.unvalidated,
          rationale: 'Long enough but no terminating period anywhere',
        ),
      ]);
      expect(failures, isNotEmpty,
          reason: 'Invariant 2 should flag empty / short / un-punctuated '
              'rationales.');
      expect(failures.join('\n'), contains('EmptyRationale'));
      expect(failures.join('\n'), contains('ShortRationale'));
      expect(failures.join('\n'), contains('NoPeriod'));
    });

    test('invariant 3a: reproducerOnly requires a reproducerPath', () {
      final failures = _runInvariants([
        const ComponentMetadata(
          componentName: 'MissingReproducer',
          tier: EvidenceTier.reproducerOnly,
          rationale: 'Claim without supporting reproducer, should fail.',
          coveredClaimIds: {'x'},
        ),
      ]);
      expect(failures.join('\n'), contains('missing reproducerPath'));
    });

    test(
        'invariant 3b: runtimeVerified requires 3-capture bracket '
        '(CODEX-R2-1 parity)', () {
      final failures = _runInvariants([
        const ComponentMetadata(
          componentName: 'RuntimeVerifiedNoCaptures',
          tier: EvidenceTier.runtimeVerified,
          rationale: 'runtimeVerified claim missing capture artifacts.',
          reproducerPath: 'test/validation/profile_capture_schema_test.dart',
          coveredClaimIds: {'x'},
        ),
        const ComponentMetadata(
          componentName: 'RuntimeVerifiedEmptyCaptures',
          tier: EvidenceTier.runtimeVerified,
          rationale: 'runtimeVerified claim with explicit empty list.',
          reproducerPath: 'test/validation/profile_capture_schema_test.dart',
          profileCapturePaths: [],
          coveredClaimIds: {'x'},
        ),
        ComponentMetadata(
          componentName: 'RuntimeVerifiedOneCapture',
          tier: EvidenceTier.runtimeVerified,
          rationale: 'runtimeVerified claim with single capture, not a triad.',
          reproducerPath: 'test/validation/profile_capture_schema_test.dart',
          profileCapturePaths: const [
            'test/validation/captures/_fixtures/dormant_bracket_at.json',
          ],
          coveredClaimIds: const {'x'},
        ),
      ]);
      final joined = failures.join('\n');
      expect(joined, contains('RuntimeVerifiedNoCaptures'));
      expect(joined, contains('RuntimeVerifiedEmptyCaptures'));
      expect(joined, contains('RuntimeVerifiedOneCapture'));
      expect(joined, contains('exactly 3'),
          reason: 'One-capture claim must be rejected by the 3-capture '
              'bracketing rule (CODEX-R2-1 parity with detector gate).');
    });

    test('invariant 3c: externallyCited requires valid http/https citationUrl',
        () {
      final failures = _runInvariants([
        const ComponentMetadata(
          componentName: 'ExternallyCitedNoUrl',
          tier: EvidenceTier.externallyCited,
          rationale: 'externallyCited claim missing citation URL.',
          reproducerPath: 'test/validation/profile_capture_schema_test.dart',
          profileCapturePaths: [
            'test/validation/captures/_fixtures/dormant_bracket_below.json',
            'test/validation/captures/_fixtures/dormant_bracket_at.json',
            'test/validation/captures/_fixtures/dormant_bracket_above.json',
          ],
          coveredClaimIds: {'x'},
        ),
        const ComponentMetadata(
          componentName: 'ExternallyCitedBadUrl',
          tier: EvidenceTier.externallyCited,
          rationale: 'citationUrl is a non-empty string but not a real URL.',
          citationUrl: 'see spec',
          reproducerPath: 'test/validation/profile_capture_schema_test.dart',
          profileCapturePaths: [
            'test/validation/captures/_fixtures/dormant_bracket_below.json',
            'test/validation/captures/_fixtures/dormant_bracket_at.json',
            'test/validation/captures/_fixtures/dormant_bracket_above.json',
          ],
          coveredClaimIds: {'x'},
        ),
        const ComponentMetadata(
          componentName: 'ExternallyCitedFtp',
          tier: EvidenceTier.externallyCited,
          rationale: 'citationUrl is parseable but wrong scheme (ftp).',
          citationUrl: 'ftp://example.com/spec',
          reproducerPath: 'test/validation/profile_capture_schema_test.dart',
          profileCapturePaths: [
            'test/validation/captures/_fixtures/dormant_bracket_below.json',
            'test/validation/captures/_fixtures/dormant_bracket_at.json',
            'test/validation/captures/_fixtures/dormant_bracket_above.json',
          ],
          coveredClaimIds: {'x'},
        ),
      ]);
      final joined = failures.join('\n');
      expect(joined, contains('ExternallyCitedNoUrl'));
      expect(joined, contains('ExternallyCitedBadUrl'));
      expect(joined, contains('ExternallyCitedFtp'));
      expect(joined, contains('citationUrl'),
          reason: 'CLAUDE-R1-2: non-empty check is not enough — must be '
              'a parseable http/https URI with an authority.');
    });

    test('invariant 3d: any tier > unvalidated requires coveredClaimIds', () {
      final failures = _runInvariants([
        const ComponentMetadata(
          componentName: 'NoCoveredClaims',
          tier: EvidenceTier.reproducerOnly,
          rationale: 'reproducerOnly claim without coveredClaimIds.',
          reproducerPath: 'test/validation/profile_capture_schema_test.dart',
        ),
        const ComponentMetadata(
          componentName: 'EmptyCoveredClaims',
          tier: EvidenceTier.reproducerOnly,
          rationale: 'reproducerOnly claim with empty coveredClaimIds.',
          reproducerPath: 'test/validation/profile_capture_schema_test.dart',
          coveredClaimIds: {},
        ),
      ]);
      final joined = failures.join('\n');
      expect(joined, contains('NoCoveredClaims'));
      expect(joined, contains('EmptyCoveredClaims'));
      expect(joined, contains('coveredClaimIds'));
    });

    test('invariant 4: reproducer file must exist and contain tests', () {
      if (!File('pubspec.yaml').existsSync()) {
        markTestSkipped('CWD is not the package root; skipping.');
        return;
      }
      final failures = _runInvariants([
        const ComponentMetadata(
          componentName: 'NonExistentReproducer',
          tier: EvidenceTier.reproducerOnly,
          rationale: 'Reproducer path that does not exist on disk.',
          reproducerPath:
              'test/validation/definitely_does_not_exist_repro.dart',
          coveredClaimIds: {'x'},
        ),
      ]);
      expect(failures.join('\n'), contains('NonExistentReproducer'));
    });

    test(
        'invariant 4 AB3: reproducer file must reference the component by '
        'name (CODEX-R3-2 parity)', () {
      if (!File('pubspec.yaml').existsSync()) {
        markTestSkipped('CWD is not the package root; skipping.');
        return;
      }
      final failures = _runInvariants([
        const ComponentMetadata(
          // The existing schema test file does not contain the token
          // "ComponentThatIsNotMentionedAnywhere", so the AB3 check
          // must fail.
          componentName: 'ComponentThatIsNotMentionedAnywhere',
          tier: EvidenceTier.reproducerOnly,
          rationale: 'Reproducer exists but does not reference componentName.',
          reproducerPath: 'test/validation/profile_capture_schema_test.dart',
          coveredClaimIds: {'x'},
        ),
      ]);
      final joined = failures.join('\n');
      expect(joined, contains('ComponentThatIsNotMentionedAnywhere'));
      expect(joined, contains('by name'),
          reason: 'CODEX-R3-2: the component audit must require that the '
              'reproducer references the componentName textually, same as '
              'the detector gate does with runtimeType.');
    });

    test('invariant 5: every declared capture must parse cleanly', () {
      if (!File('pubspec.yaml').existsSync()) {
        markTestSkipped('CWD is not the package root; skipping.');
        return;
      }
      final failures = _runInvariants([
        ComponentMetadata(
          componentName: 'MalformedCapture',
          tier: EvidenceTier.runtimeVerified,
          rationale: 'runtimeVerified claim pointing at a malformed capture.',
          reproducerPath: 'test/validation/profile_capture_schema_test.dart',
          profileCapturePaths: const [
            // 3 entries so bracket-count passes and invariant 5 is the
            // failure surface actually under test. All three point at
            // the same negative fixture so every entry fails parseFile.
            'test/validation/captures/_fixtures/missing_device.json',
            'test/validation/captures/_fixtures/missing_device.json',
            'test/validation/captures/_fixtures/missing_device.json',
          ],
          coveredClaimIds: const {'x'},
        ),
      ]);
      expect(failures.join('\n'), contains('MalformedCapture'));
      expect(failures.join('\n'), contains('missing_device.json'));
    });

    test(
        'filesystem walk: every `with ComponentMetadataProvider` class in '
        'lib/src/ appears in _expectedRegisteredComponents (CODEX-R1-1)', () {
      if (!File('pubspec.yaml').existsSync()) {
        markTestSkipped('CWD is not the package root; skipping.');
        return;
      }
      final libSrc = Directory('lib/src');
      expect(libSrc.existsSync(), isTrue,
          reason: 'lib/src/ must exist for the walk to make sense.');
      final declaredOnDisk = <String>{};
      // Matches `class X ... with A, ComponentMetadataProvider, B ...`
      // across line wraps — `with` can list multiple mixins separated by
      // commas, so we capture the class name and then grep the `with`
      // clause for the mixin token. Also matches `implements`.
      final classDeclRe = RegExp(
        r'class\s+(\w+)(?:<[^>]*>)?\s+[^{]*?\bComponentMetadataProvider\b',
        multiLine: true,
      );
      // AB-4: `ComponentMetadata`'s docstring documents a second
      // registration pattern — `const` registries and top-level utilities
      // that lack an instance publish metadata by calling
      // `ValidatedComponentRegistry.instance.register(const
      // ComponentMetadata(componentName: 'X', ...))` directly from a
      // `static void registerMetadata()` entry point. Those call sites
      // never declare `with ComponentMetadataProvider`, so the mixin
      // walk missed them entirely. A direct-register component that was
      // added without also landing in `_expectedRegisteredComponents`
      // would ship unwalked by the audit gate. Walk for the call pattern
      // and extract the `componentName:` literal to close that gap.
      final directRegisterRe = RegExp(
        r'''ValidatedComponentRegistry\.instance\.register\s*\(\s*'''
        r'''(?:const\s+)?ComponentMetadata\s*\(\s*'''
        r'''(?:[^)]*?\bcomponentName\s*:\s*(?:'([^']+)'|"([^"]+)"))''',
        multiLine: true,
        dotAll: true,
      );
      for (final entity in libSrc.listSync(recursive: true)) {
        if (entity is! File) continue;
        if (!entity.path.endsWith('.dart')) continue;
        // Skip the definition file itself.
        if (entity.path.endsWith('component_metadata.dart')) continue;
        final source = stripDartComments(entity.readAsStringSync());
        for (final m in classDeclRe.allMatches(source)) {
          final name = m.group(1)!;
          if (name.startsWith('_')) continue;
          declaredOnDisk.add(name);
        }
        for (final m in directRegisterRe.allMatches(source)) {
          final name = m.group(1) ?? m.group(2);
          if (name == null || name.isEmpty) continue;
          // Private direct-register names (convention: `_foo`) are still
          // captured — a direct-register site is always at file scope
          // and the registry dedupe key is the literal `componentName`,
          // which is free to start with `_`. Skipping them here would
          // let a private component slip past the audit.
          declaredOnDisk.add(name);
        }
      }
      // Every class on disk that declares ComponentMetadataProvider must
      // appear in the expected-registered list, OR the audit test's
      // setUpAll must be dispatching its registerMetadata() explicitly.
      // Empty in v0.16.2, becomes the canonical registration gate in
      // v0.16.6 when the first real component lands.
      final expected = _expectedRegisteredComponents.toSet();
      final missing = declaredOnDisk.difference(expected);
      expect(missing, isEmpty,
          reason: 'These components are defined in lib/src/ (via mixin or '
              'direct ValidatedComponentRegistry.instance.register call) '
              'but are NOT in _expectedRegisteredComponents. A component '
              'that publishes metadata but never has its registerMetadata() '
              'called is invisible to the audit gate and silently drops '
              'out of the reliability ledger. Add the name to '
              '_expectedRegisteredComponents and wire its registerMetadata() '
              'dispatch in setUpAll. Missing: $missing');
    });

    test(
        'filesystem walk matches `ValidatedComponentRegistry.instance.register` '
        'direct-call pattern (AB-4 regression)', () {
      // Inline snapshot of the regex the filesystem walk uses. If this
      // regression fails, the walk has regressed in a way that would let
      // a direct-register component ship without appearing in
      // `_expectedRegisteredComponents`.
      final directRegisterRe = RegExp(
        r'''ValidatedComponentRegistry\.instance\.register\s*\(\s*'''
        r'''(?:const\s+)?ComponentMetadata\s*\(\s*'''
        r'''(?:[^)]*?\bcomponentName\s*:\s*(?:'([^']+)'|"([^"]+)"))''',
        multiLine: true,
        dotAll: true,
      );
      const singleLine = '''
static void registerMetadata() {
  ValidatedComponentRegistry.instance.register(const ComponentMetadata(
      componentName: 'SingleLineDirectRegister',
      tier: EvidenceTier.unvalidated,
      rationale: 'example'));
}
''';
      const multiLine = '''
static void registerMetadata() {
  ValidatedComponentRegistry.instance.register(
    const ComponentMetadata(
      componentName: "MultiLineDirectRegister",
      tier: EvidenceTier.unvalidated,
      rationale: 'example',
    ),
  );
}
''';
      const privateName = '''
void _registerFrameworkWidgetDenyList() {
  ValidatedComponentRegistry.instance.register(
    const ComponentMetadata(
      componentName: '_frameworkWidgetDenyList',
      tier: EvidenceTier.unvalidated,
      rationale: 'example',
    ),
  );
}
''';
      final singleName = directRegisterRe.firstMatch(singleLine);
      expect(singleName?.group(1), 'SingleLineDirectRegister');
      final multiName = directRegisterRe.firstMatch(multiLine);
      expect(multiName?.group(2), 'MultiLineDirectRegister');
      final privName = directRegisterRe.firstMatch(privateName);
      expect(privName?.group(1), '_frameworkWidgetDenyList');
    });

    test(
        'registry: register same metadata twice under the same name is '
        'a no-op (CLAUDE-R1-1)', () {
      const metadata = ComponentMetadata(
        componentName: 'CollisionTestSameValue',
        tier: EvidenceTier.unvalidated,
        rationale: 'Sentinel entry used by the registry collision test.',
      );
      final registry = ValidatedComponentRegistry.instance;
      final before = registry.registeredNamesForTest.length;
      registry.register(metadata);
      registry.register(metadata);
      final after = registry.registeredNamesForTest.length;
      expect(after - before, 1,
          reason: 'Value-equal re-registration must be a silent no-op; '
              'the registry should not grow on the second call.');
    });

    test(
        'registry: register differing metadata under the same name throws '
        'StateError (CLAUDE-R1-1)', () {
      const first = ComponentMetadata(
        componentName: 'CollisionTestDifferingValues',
        tier: EvidenceTier.unvalidated,
        rationale: 'First registration — baseline rationale for the name.',
      );
      const second = ComponentMetadata(
        componentName: 'CollisionTestDifferingValues',
        tier: EvidenceTier.reproducerOnly,
        rationale: 'Second registration — divergent tier/rationale.',
        reproducerPath: 'test/validation/profile_capture_schema_test.dart',
        coveredClaimIds: {'x'},
      );
      final registry = ValidatedComponentRegistry.instance;
      registry.register(first);
      expect(
        () => registry.register(second),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(
            contains('CollisionTestDifferingValues'),
            contains('collision'),
          ),
        )),
        reason: 'Differing metadata under the same componentName must '
            'throw — otherwise the first-write-wins no-op silently kept '
            'stale metadata when a second caller registered a diverged '
            'claim.',
      );
    });

    test(
        'registry: collision StateError names the diverging field values '
        'on both operands (AB-5 / CLAUDE-R1-1 completion)', () {
      // The prior CLAUDE-R1-1 test asserts that the StateError is
      // raised and that its message contains the component name. But
      // it does not assert that the message is actually *useful* —
      // without a `ComponentMetadata.toString()` override, both
      // `$existing` and `$metadata` rendered as
      // `Instance of 'ComponentMetadata'` and an operator had to diff
      // two const literals in source to find the diverging field.
      // This test pins the human-facing diagnostic: the message must
      // contain both tier names and both rationales in verbatim form.
      const first = ComponentMetadata(
        componentName: 'CollisionDiagnosticTest',
        tier: EvidenceTier.unvalidated,
        rationale: 'Alpha rationale for the diagnostic-coverage regression.',
      );
      const second = ComponentMetadata(
        componentName: 'CollisionDiagnosticTest',
        tier: EvidenceTier.reproducerOnly,
        rationale: 'Beta rationale for the diagnostic-coverage regression.',
        reproducerPath: 'test/validation/profile_capture_schema_test.dart',
        coveredClaimIds: {'collision_diagnostic'},
      );
      final registry = ValidatedComponentRegistry.instance;
      registry.register(first);
      expect(
        () => registry.register(second),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(
            // Existing operand's discriminating fields.
            contains('unvalidated'),
            contains('Alpha rationale'),
            // Incoming operand's discriminating fields.
            contains('reproducerOnly'),
            contains('Beta rationale'),
            contains('profile_capture_schema_test.dart'),
            contains('collision_diagnostic'),
            // Neither operand must render as the default.
            isNot(contains("Instance of 'ComponentMetadata'")),
          ),
        )),
        reason: 'Collision StateError must surface the diverging field '
            'values on both operands so the fix is a one-look operation.',
      );
    });

    test('dormant-gate happy path: well-formed entries produce no failures',
        () {
      final failures = _runInvariants([
        const ComponentMetadata(
          componentName: 'WellFormedUnvalidated',
          tier: EvidenceTier.unvalidated,
          rationale: 'Baseline unvalidated entry with a sufficient rationale.',
        ),
        const ComponentMetadata(
          // Use a token we know appears in the target reproducer file so
          // AB3 passes. `profile_capture_schema_test.dart` contains the
          // literal string `ProfileCaptureSchema` many times.
          componentName: 'ProfileCaptureSchema',
          tier: EvidenceTier.reproducerOnly,
          rationale: 'Supported by a reproducer test that exercises it.',
          reproducerPath: 'test/validation/profile_capture_schema_test.dart',
          coveredClaimIds: {'dormant_gate_fake'},
        ),
        const ComponentMetadata(
          componentName: 'ProfileCaptureSchema',
          tier: EvidenceTier.runtimeVerified,
          rationale:
              'Supported by a reproducer plus three bracketing captures.',
          reproducerPath: 'test/validation/profile_capture_schema_test.dart',
          profileCapturePaths: [
            'test/validation/captures/_fixtures/dormant_bracket_below.json',
            'test/validation/captures/_fixtures/dormant_bracket_at.json',
            'test/validation/captures/_fixtures/dormant_bracket_above.json',
          ],
          bracketThreshold: 1000,
          bracketUnit: 'ms',
          coveredClaimIds: {'dormant_gate_fake'},
        ),
      ]);
      expect(failures, isEmpty,
          reason: 'Well-formed entries should pass every invariant: '
              '$failures');
    });
  });
}

// ---------------------------------------------------------------------
// Audit-invariant helper — delegates to the shared module so the
// detector gate and the component gate cannot drift.
// ---------------------------------------------------------------------

List<String> _runInvariants(List<ComponentMetadata> components) {
  final failures = <String>[];
  for (final m in components) {
    final label = '${m.componentName} (tier=${m.tier.name})';

    failures.addAll(checkRationale(label, m.rationale));

    switch (m.tier) {
      case EvidenceTier.unvalidated:
        break;
      case EvidenceTier.reproducerOnly:
        if (m.reproducerPath == null || m.reproducerPath!.trim().isEmpty) {
          failures.add('$label: missing reproducerPath');
        }
        break;
      case EvidenceTier.runtimeVerified:
        if (m.reproducerPath == null || m.reproducerPath!.trim().isEmpty) {
          failures.add('$label: missing reproducerPath');
        }
        failures.addAll(checkBracketCount(
          label: label,
          tier: m.tier,
          capturePaths: m.profileCapturePaths,
        ));
        failures.addAll(checkBracketValidation(
          label: label,
          tier: m.tier,
          capturePaths: m.profileCapturePaths,
          bracketThreshold: m.bracketThreshold,
          bracketUnit: m.bracketUnit,
        ));
        break;
      case EvidenceTier.externallyCited:
        failures.addAll(checkCitationUrl(label, m.citationUrl, required: true));
        if (m.reproducerPath == null || m.reproducerPath!.trim().isEmpty) {
          failures.add('$label: missing reproducerPath');
        }
        failures.addAll(checkBracketCount(
          label: label,
          tier: m.tier,
          capturePaths: m.profileCapturePaths,
        ));
        failures.addAll(checkBracketValidation(
          label: label,
          tier: m.tier,
          capturePaths: m.profileCapturePaths,
          bracketThreshold: m.bracketThreshold,
          bracketUnit: m.bracketUnit,
        ));
        break;
    }

    if (m.tier != EvidenceTier.externallyCited) {
      failures.addAll(checkCitationUrl(label, m.citationUrl, required: false));
    }

    if (m.tier != EvidenceTier.unvalidated) {
      final covered = m.coveredClaimIds;
      if (covered == null) {
        failures.add('$label: missing coveredClaimIds — tier > unvalidated '
            'must declare which claims the evidence covers');
      } else if (covered.isEmpty) {
        failures.add('$label: coveredClaimIds is empty');
      } else {
        for (final id in covered) {
          if (id.trim().isEmpty) {
            failures.add('$label: coveredClaimIds contains an empty entry');
            break;
          }
        }
      }
    }

    final reproducer = m.reproducerPath;
    if (reproducer != null && reproducer.trim().isNotEmpty) {
      failures.addAll(checkReproducerFile(
        label: label,
        reproducerPath: reproducer,
        // CODEX-R3-2 parity with the detector gate: the reproducer must
        // textually reference the componentName by name.
        requiredTokens: [m.componentName],
        // Components cover non-detector entities (schemas, validators,
        // utility classes) — many have only static methods and are
        // never constructed from the reproducer. The detector gate's
        // instantiation requirement does not transfer; a component's
        // reproducer exercises the component through whatever its
        // actual API shape is (e.g. `ProfileCaptureSchema.parseFile`).
        requireInstantiation: false,
      ));
    }

    failures.addAll(checkCapturePaths(
      label: label,
      capturePaths: m.profileCapturePaths,
    ));
  }
  return failures;
}
