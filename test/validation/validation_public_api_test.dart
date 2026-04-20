// Guards Codex post-impl review finding 3: the v0.16.0 validation
// methodology infrastructure (`EvidenceTier`, `DetectorMetadata`,
// `DetectorMetadataProvider`) must be reachable through the public
// `package:sleuth/sleuth.dart` barrel. Shipping these under `src/`
// without exporting them makes the headline 0.16.0 contract unusable
// unless callers reach into `package:sleuth/src/...`.
//
// v0.16.2 extends this guard (CODEX-R4-2) to the component surface
// (`ComponentMetadata`, `ComponentMetadataProvider`) and the capture
// schema (`ProfileCaptureSchema`) — the audit gate for non-detector
// components relies on all three being reachable without a `src/`
// import, and `ProfileCaptureSchema` is what downstream forks run their
// own captures through.
//
// This test imports ONLY the public barrel — adding it back as a direct
// `src/` import would silently mask a missing export.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/sleuth.dart';

void main() {
  group('Validation public API is exported from package:sleuth/sleuth.dart',
      () {
    test('EvidenceTier enum values are reachable', () {
      expect(EvidenceTier.values, hasLength(4));
      expect(EvidenceTier.unvalidated.index, 0);
      expect(EvidenceTier.externallyCited.index, 3);
    });

    // Codex post-impl meta-review finding C4: pin the full ordinal +
    // name sequence so any reorder or rename of the stable-contract
    // enum fails a test instead of shipping silently.
    test('EvidenceTier ordering is pinned weakest-to-strongest', () {
      expect(
        EvidenceTier.values.map((t) => t.name).toList(),
        equals([
          'unvalidated',
          'reproducerOnly',
          'runtimeVerified',
          'externallyCited',
        ]),
      );
      expect(
        EvidenceTier.values.map((t) => t.index).toList(),
        equals([0, 1, 2, 3]),
      );
    });

    test('DetectorMetadata can be constructed via the public API', () {
      const metadata = DetectorMetadata(
        tier: EvidenceTier.externallyCited,
        rationale: 'Material spec reference',
        citationUrl: 'https://m3.material.io',
        reproducerPath: 'test/detectors/example_test.dart',
      );
      expect(metadata.tier, EvidenceTier.externallyCited);
      expect(metadata.rationale, contains('Material'));
      expect(metadata.citationUrl, isNotNull);
    });

    test('DetectorMetadataProvider mixin is reachable for implementers', () {
      final provider = _ExampleDetectorMetadataProvider();
      expect(provider.validationMetadata.tier, EvidenceTier.reproducerOnly);
    });

    // CODEX-R4-2: v0.16.2 adds the parallel component surface plus the
    // capture-schema parser. All three must be reachable through the
    // public barrel so downstream users and forks don't have to import
    // `package:sleuth/src/...`.
    test(
        'ComponentMetadata can be constructed via the public API '
        '(CODEX-R4-2)', () {
      const metadata = ComponentMetadata(
        componentName: 'ExampleComponent',
        tier: EvidenceTier.reproducerOnly,
        rationale: 'Reachable via package:sleuth/sleuth.dart barrel.',
        reproducerPath: 'test/example_component_test.dart',
        coveredClaimIds: {'x'},
      );
      expect(metadata.componentName, 'ExampleComponent');
      expect(metadata.tier, EvidenceTier.reproducerOnly);
      expect(metadata.coveredClaimIds, contains('x'));
    });

    test(
        'ComponentMetadataProvider mixin is reachable for implementers '
        '(CODEX-R4-2)', () {
      final provider = _ExampleComponentMetadataProvider();
      expect(provider.validationMetadata.componentName, 'ExampleComponent');
      expect(provider.validationMetadata.tier, EvidenceTier.reproducerOnly);
    });

    test(
        'ProfileCaptureSchema.parseFile is reachable via the public API '
        '(CODEX-R4-2)', () {
      final anchor = File(
          'test/validation/captures/_fixtures/anchor_devtools_export.json');
      if (!anchor.existsSync()) {
        markTestSkipped('anchor fixture not available (non-repo-root CWD)');
        return;
      }
      // The smoke path: it's the public type, callable, and returns
      // a Map with the canonical metadata keys.
      final meta = ProfileCaptureSchema.parseFile(anchor);
      expect(meta, isA<Map<String, Object?>>());
      expect(meta, containsPair('device', isA<String>()));
      expect(ProfileCaptureSchema.approvedFlutterMajorMinor, isNotEmpty,
          reason: 'approvedFlutterMajorMinor constant is part of the '
              'public contract; a fork that pins its own major.minor '
              'reads this.');
    });
  });
}

class _ExampleDetectorMetadataProvider with DetectorMetadataProvider {
  @override
  DetectorMetadata get validationMetadata => const DetectorMetadata(
        tier: EvidenceTier.reproducerOnly,
        rationale: 'Reproducer lives at test/example_test.dart',
        reproducerPath: 'test/example_test.dart',
      );
}

class _ExampleComponentMetadataProvider with ComponentMetadataProvider {
  @override
  ComponentMetadata get validationMetadata => const ComponentMetadata(
        componentName: 'ExampleComponent',
        tier: EvidenceTier.reproducerOnly,
        rationale: 'Reproducer lives at test/example_component_test.dart',
        reproducerPath: 'test/example_component_test.dart',
        coveredClaimIds: {'x'},
      );
}
