// Guards Codex post-impl review finding 3: the v0.16.0 validation
// methodology infrastructure (`EvidenceTier`, `DetectorMetadata`,
// `DetectorMetadataProvider`) must be reachable through the public
// `package:sleuth/sleuth.dart` barrel. Shipping these under `src/`
// without exporting them makes the headline 0.16.0 contract unusable
// unless callers reach into `package:sleuth/src/...`.
//
// This test imports ONLY the public barrel — adding it back as a direct
// `src/` import would silently mask a missing export.
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
