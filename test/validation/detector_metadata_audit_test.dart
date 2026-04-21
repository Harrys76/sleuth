// Audit gate for the v0.16 validation-methodology contract.
//
// Walks every detector registered on a default [SleuthController] (minus
// user-authored custom detectors) and asserts the per-detector invariants
// published in [DetectorMetadata]'s doc comment:
//
//   - Each detector mixes in [DetectorMetadataProvider].
//   - `validationMetadata` is non-null and has a non-empty `rationale`.
//   - Tier-appropriate fields are populated:
//       reproducerOnly                   → `reproducerPath` non-null
//       runtimeVerified                  → `reproducerPath` non-null AND
//                                          `profileCapturePaths` non-null
//                                          and length == 3 (v0.16.2
//                                          bracketing rule).
//       externallyCited                  → `citationUrl` (http/https with
//                                          authority), `reproducerPath`,
//                                          and `profileCapturePaths` all
//                                          present; bracket count == 3.
//       any tier > unvalidated           → `coveredStableIds` non-null and
//                                          non-empty.
//   - If a `reproducerPath` is present AND the test is running from the
//     repo root, the file is inside the repo (no absolute paths / `..`
//     traversal / symlink escapes), it contains `test(` /
//     `testWidgets(` outside of line AND block comments (CLAUDE-R4-1),
//     and it references the detector's runtimeType by name.
//   - If `profileCapturePaths` is declared, every path is inside the
//     repo and parses cleanly via `ProfileCaptureSchema.parseFile`.
//
// v0.16.2 post-adversarial-review hardening extracted the five invariant
// checkers into `_support/audit_invariants.dart` so the detector gate and
// the component gate share a single implementation. Individual blockers
// closed by the shared module:
//
//   - CLAUDE-R4-1 — line-AND-block comment stripping via
//     `stripDartComments`.
//   - CODEX-R6-1 — repo-containment check via `isPathInsideRepo` (rejects
//     absolute paths, `../../` traversal, and symlinked files that
//     canonicalise outside the repo root).
//   - CLAUDE-R1-2 — citation-URL validation via `checkCitationUrl`
//     (requires parseable http/https URI with authority).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/sleuth.dart'
    show
        DetectorMetadata,
        DetectorMetadataProvider,
        EvidenceTier,
        ProfileCaptureSchema;
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/base_detector.dart';

import '_support/audit_invariants.dart';

void main() {
  group('Detector metadata audit (v0.16.1 gate)', () {
    late SleuthController controller;

    setUp(() {
      controller = SleuthController();
      controller.initializeDetectorsForTest();
    });

    tearDown(() {
      controller.dispose();
    });

    test('every shipped detector mixes in DetectorMetadataProvider', () {
      final detectors = controller.detectorsForAudit;
      expect(detectors, isNotEmpty,
          reason: 'Default SleuthController should register built-in '
              'detectors via initializeDetectorsForTest().');

      final failures = <String>[];
      for (final d in detectors) {
        if (d is! DetectorMetadataProvider) {
          failures.add('${d.runtimeType} (${d.type.name})');
        }
      }

      expect(failures, isEmpty,
          reason: 'These detectors are missing `with '
              'DetectorMetadataProvider`: $failures. Every shipped '
              'detector must declare its validation metadata — add the '
              'mixin and a const DetectorMetadata(...) getter.');
    });

    test('every detector returns non-null metadata with non-empty rationale',
        () {
      final failures = <String>[];
      for (final d in controller.detectorsForAudit) {
        if (d is! DetectorMetadataProvider) continue;
        final DetectorMetadata meta =
            (d as DetectorMetadataProvider).validationMetadata;
        failures.addAll(checkRationale('${d.runtimeType}', meta.rationale));
      }
      expect(failures, isEmpty,
          reason: 'Metadata rationale must describe what was validated. '
              'Placeholders, empty strings, or one-word fragments are '
              'rejected: $failures');
    });

    test('tier-appropriate fields are populated', () {
      final failures = <String>[];
      for (final d in controller.detectorsForAudit) {
        if (d is! DetectorMetadataProvider) continue;
        final meta = (d as DetectorMetadataProvider).validationMetadata;
        final label = '${d.runtimeType} (tier=${meta.tier.name})';

        switch (meta.tier) {
          case EvidenceTier.unvalidated:
            break;
          case EvidenceTier.reproducerOnly:
            if (meta.reproducerPath == null ||
                meta.reproducerPath!.trim().isEmpty) {
              failures.add('$label: missing reproducerPath');
            }
            break;
          case EvidenceTier.runtimeVerified:
            if (meta.reproducerPath == null ||
                meta.reproducerPath!.trim().isEmpty) {
              failures.add('$label: missing reproducerPath');
            }
            failures.addAll(checkBracketCount(
              label: label,
              tier: meta.tier,
              capturePaths: meta.profileCapturePaths,
            ));
            failures.addAll(checkBracketValidation(
              label: label,
              tier: meta.tier,
              capturePaths: meta.profileCapturePaths,
              bracketThreshold: meta.bracketThreshold,
              bracketUnit: meta.bracketUnit,
            ));
            break;
          case EvidenceTier.externallyCited:
            failures.addAll(
                checkCitationUrl(label, meta.citationUrl, required: true));
            if (meta.reproducerPath == null ||
                meta.reproducerPath!.trim().isEmpty) {
              failures.add('$label: missing reproducerPath');
            }
            failures.addAll(checkBracketCount(
              label: label,
              tier: meta.tier,
              capturePaths: meta.profileCapturePaths,
            ));
            failures.addAll(checkBracketValidation(
              label: label,
              tier: meta.tier,
              capturePaths: meta.profileCapturePaths,
              bracketThreshold: meta.bracketThreshold,
              bracketUnit: meta.bracketUnit,
            ));
            break;
        }

        // CLAUDE-R1-2 tightening also runs on non-externallyCited tiers
        // whenever a citationUrl is set voluntarily — a malformed URL in a
        // `reproducerOnly` metadata is still a bug.
        if (meta.tier != EvidenceTier.externallyCited) {
          failures.addAll(
              checkCitationUrl(label, meta.citationUrl, required: false));
        }

        // Any tier stronger than `unvalidated` must pin the set of stable
        // IDs its evidence covers. A detector that emits multiple issue
        // families cannot inherit a detector-scope tier claim across
        // families the reproducer never exercised (see v0.16.1 AB2).
        if (meta.tier != EvidenceTier.unvalidated) {
          final covered = meta.coveredStableIds;
          if (covered == null) {
            failures.add('$label: missing coveredStableIds — tier > '
                'unvalidated must declare which stable IDs the evidence '
                'covers');
          } else if (covered.isEmpty) {
            failures.add('$label: coveredStableIds is empty — declare the '
                'stable IDs the evidence covers, or demote to unvalidated');
          } else {
            for (final id in covered) {
              if (id.trim().isEmpty) {
                failures.add('$label: coveredStableIds contains an empty '
                    'or whitespace-only entry');
                break;
              }
            }
          }
        }
      }
      expect(failures, isEmpty, reason: 'Tier invariants violated: $failures');
    });

    test(
        'declared reproducer + capture files are inside the repo, exist, '
        'and satisfy the reproducer / schema contracts', () {
      if (!File('pubspec.yaml').existsSync()) {
        markTestSkipped(
          'Cannot resolve reproducerPath values: test CWD is not the '
          'package root (no pubspec.yaml).',
        );
        return;
      }

      final failures = <String>[];
      for (final d in controller.detectorsForAudit) {
        if (d is! DetectorMetadataProvider) continue;
        final meta = (d as DetectorMetadataProvider).validationMetadata;
        final label = '${d.runtimeType}';
        final path = meta.reproducerPath;
        if (path != null && path.trim().isNotEmpty) {
          failures.addAll(checkReproducerFile(
            label: label,
            reproducerPath: path,
            requiredTokens: [d.runtimeType.toString()],
            coveredStableIds: meta.coveredStableIds,
          ));
        }
        failures.addAll(checkCapturePaths(
          label: label,
          capturePaths: meta.profileCapturePaths,
        ));
      }
      expect(failures, isEmpty,
          reason: 'Declared reproducer / capture artifacts failed the '
              'repo-containment + existence + parse contracts. Fix the '
              'metadata or the artifact — a runtimeVerified claim backed '
              'by a malformed capture loses all audit value: $failures');
    });

    test(
        'filesystem walk: every `class X extends BaseDetector` in '
        'lib/src/detectors/ is registered on the controller (CLAUDE-R6-1)', () {
      if (!File('pubspec.yaml').existsSync()) {
        markTestSkipped('CWD is not the package root; skipping.');
        return;
      }
      final detectorsDir = Directory('lib/src/detectors');
      expect(detectorsDir.existsSync(), isTrue,
          reason: 'lib/src/detectors/ must exist for the walk to make sense.');
      final declaredOnDisk = <String>{};
      final classDeclRe = RegExp(
        // Matches `class X extends BaseDetector` or
        // `class X extends BaseDetector with SomeMixin` etc. Filters out
        // `abstract class` and `class X<T> extends ...` is caught via \w+.
        r'^(?:abstract\s+)?class\s+(\w+)\s+extends\s+BaseDetector\b',
        multiLine: true,
      );
      for (final entity in detectorsDir.listSync(recursive: true)) {
        if (entity is! File) continue;
        if (!entity.path.endsWith('.dart')) continue;
        final source = stripDartComments(entity.readAsStringSync());
        for (final m in classDeclRe.allMatches(source)) {
          final name = m.group(1)!;
          // Skip private helpers / test-only stand-ins defensively, though
          // none exist in lib/src/detectors/ today.
          if (name.startsWith('_')) continue;
          // Skip the abstract helper `SimpleStructuralDetector` — it is a
          // base class for user-authored custom detectors and is not
          // itself registered.
          if (name == 'SimpleStructuralDetector') continue;
          declaredOnDisk.add(name);
        }
      }
      final registeredNames = controller.detectorsForAudit
          .map((d) => d.runtimeType.toString())
          .toSet();
      final missing = declaredOnDisk.difference(registeredNames);
      expect(missing, isEmpty,
          reason: 'These detector classes are declared in lib/src/detectors/ '
              'but are NOT registered on SleuthController.detectorsForAudit. '
              'A detector file that ships without being registered never '
              'runs and never appears in the reliability ledger — add it to '
              'the controller or delete the file. Missing: $missing');
    });

    test('NetworkMonitorDetector ships at reproducerOnly (v0.16.1)', () {
      // Anti-tautology anchor: pins the headline v0.16.1 upgrade. If
      // someone demotes NetworkMonitorDetector back to unvalidated without
      // updating this test, the contradiction surfaces here rather than
      // as a silent regression in the reliability ledger.
      final BaseDetector? nm = controller.detectorsForAudit
          .where((d) => d.type == DetectorType.networkMonitor)
          .cast<BaseDetector?>()
          .firstWhere((_) => true, orElse: () => null);
      expect(nm, isNotNull,
          reason: 'NetworkMonitorDetector should be registered by default.');
      expect(nm, isA<DetectorMetadataProvider>());
      final meta = (nm as DetectorMetadataProvider).validationMetadata;
      expect(meta.tier, EvidenceTier.reproducerOnly);
      expect(meta.reproducerPath,
          equals('test/validation/network_monitor_reproducer_test.dart'));
      expect(meta.coveredStableIds, equals(const {'slow_request'}),
          reason: 'The reproducer only covers slow_request boundaries. If '
              'the coverage set was widened, a matching reproducer for the '
              'new family must land with it, not a silent detector-scope '
              'claim.');
    });
  });

  group('Detector metadata audit — dormant-gate regressions (v0.16.2)', () {
    // These tests do NOT walk the real controller. They simulate the audit
    // loop's bucket-accumulation behaviour against synthetic malformed
    // captures so the audit-gate logic stays honest even when no real
    // detector is at `runtimeVerified`.

    test('malformedCapture detection: bad_iso_date fixture fails parseFile',
        () {
      final file = File('test/validation/captures/_fixtures/bad_iso_date.json');
      expect(file.existsSync(), isTrue,
          reason: 'Negative fixture must exist for this regression to be '
              'meaningful.');
      expect(
          () => ProfileCaptureSchema.parseFile(file),
          throwsA(isA<FormatException>()
              .having((e) => e.message, 'message', contains('captureDate'))));
    });

    test('malformedCapture detection: min_gt_observed fixture fails parseFile',
        () {
      final file =
          File('test/validation/captures/_fixtures/min_gt_observed.json');
      expect(file.existsSync(), isTrue);
      expect(
          () => ProfileCaptureSchema.parseFile(file),
          throwsA(isA<FormatException>().having(
              (e) => e.message, 'message', contains('expectedMagnitude'))));
    });

    test(
        'checkCapturePaths populates a failure entry on a malformed capture '
        '(bucket-then-assert pattern)', () {
      final failures = checkCapturePaths(
        label: 'FakeDetector',
        capturePaths: const [
          'test/validation/captures/_fixtures/bad_iso_date.json',
        ],
      );
      expect(failures, isNotEmpty,
          reason: 'checkCapturePaths must surface FormatException as a '
              'failure entry — otherwise malformed captures silently '
              'pass CI.');
      expect(failures.single, contains('bad_iso_date.json'));
    });

    test('checkBracketCount rejects a one-file runtimeVerified claim', () {
      const oneFile = DetectorMetadata(
        tier: EvidenceTier.runtimeVerified,
        rationale: 'Synthetic — should fail bracket-count check.',
        reproducerPath: 'test/validation/fake_reproducer_test.dart',
        coveredStableIds: {'fake_family'},
        profileCapturePaths: [
          'test/validation/captures/_fixtures/'
              'dormant_bracket_at.json'
        ],
      );
      final failures = checkBracketCount(
        label: 'FakeDetector',
        tier: oneFile.tier,
        capturePaths: oneFile.profileCapturePaths,
      );
      expect(failures, isNotEmpty);
      expect(failures.single, contains('exactly 3'));
    });

    test('checkBracketCount rejects a zero-file runtimeVerified claim', () {
      const empty = DetectorMetadata(
        tier: EvidenceTier.runtimeVerified,
        rationale: 'Synthetic — should fail bracket-count check.',
        reproducerPath: 'test/validation/fake_reproducer_test.dart',
        coveredStableIds: {'fake_family'},
        profileCapturePaths: <String>[],
      );
      final failures = checkBracketCount(
        label: 'FakeDetector',
        tier: empty.tier,
        capturePaths: empty.profileCapturePaths,
      );
      expect(failures, isNotEmpty);
      expect(failures.single, contains('missing profileCapturePaths'));
    });

    test('checkBracketCount accepts exactly three captures', () {
      const triad = DetectorMetadata(
        tier: EvidenceTier.runtimeVerified,
        rationale: 'Synthetic — valid triad, should produce zero failures.',
        reproducerPath: 'test/validation/fake_reproducer_test.dart',
        coveredStableIds: {'fake_family'},
        profileCapturePaths: [
          'test/validation/captures/_fixtures/dormant_bracket_below.json',
          'test/validation/captures/_fixtures/dormant_bracket_at.json',
          'test/validation/captures/_fixtures/dormant_bracket_above.json',
        ],
      );
      final failures = checkBracketCount(
        label: 'FakeDetector',
        tier: triad.tier,
        capturePaths: triad.profileCapturePaths,
      );
      expect(failures, isEmpty);
    });

    test(
        'checkBracketValidation rejects runtimeVerified without '
        'bracketThreshold / bracketUnit (CODEX-R1-2)', () {
      const triadNoThreshold = DetectorMetadata(
        tier: EvidenceTier.runtimeVerified,
        rationale: 'Synthetic — valid triad but no bracketThreshold/Unit.',
        reproducerPath: 'test/validation/fake_reproducer_test.dart',
        coveredStableIds: {'fake_family'},
        profileCapturePaths: [
          'test/validation/captures/_fixtures/dormant_bracket_below.json',
          'test/validation/captures/_fixtures/dormant_bracket_at.json',
          'test/validation/captures/_fixtures/dormant_bracket_above.json',
        ],
      );
      final failures = checkBracketValidation(
        label: 'FakeDetector',
        tier: triadNoThreshold.tier,
        capturePaths: triadNoThreshold.profileCapturePaths,
        bracketThreshold: triadNoThreshold.bracketThreshold,
        bracketUnit: triadNoThreshold.bracketUnit,
      );
      expect(failures, isNotEmpty);
      expect(
          failures.any((f) => f.contains('missing bracketThreshold')), isTrue);
      expect(failures.any((f) => f.contains('missing bracketUnit')), isTrue);
    });

    test(
        'checkBracketValidation passes on dormant-bracket triad around '
        'threshold=1000 ms', () {
      const triad = DetectorMetadata(
        tier: EvidenceTier.runtimeVerified,
        rationale: 'Synthetic — valid triad with threshold + unit.',
        reproducerPath: 'test/validation/fake_reproducer_test.dart',
        coveredStableIds: {'fake_family'},
        bracketThreshold: 1000,
        bracketUnit: 'ms',
        profileCapturePaths: [
          'test/validation/captures/_fixtures/dormant_bracket_below.json',
          'test/validation/captures/_fixtures/dormant_bracket_at.json',
          'test/validation/captures/_fixtures/dormant_bracket_above.json',
        ],
      );
      final failures = checkBracketValidation(
        label: 'FakeDetector',
        tier: triad.tier,
        capturePaths: triad.profileCapturePaths,
        bracketThreshold: triad.bracketThreshold,
        bracketUnit: triad.bracketUnit,
      );
      expect(failures, isEmpty);
    });

    test(
        'checkBracketValidation fails when triad does not bracket threshold '
        '(swap below and above)', () {
      // Same fixtures, but below and above files swapped — the observed
      // values no longer bracket the 1000 ms threshold, so
      // ProfileCaptureSchema.validateBracket must surface a violation.
      const swapped = DetectorMetadata(
        tier: EvidenceTier.runtimeVerified,
        rationale: 'Synthetic — swapped bracket; should fail validation.',
        reproducerPath: 'test/validation/fake_reproducer_test.dart',
        coveredStableIds: {'fake_family'},
        bracketThreshold: 1000,
        bracketUnit: 'ms',
        profileCapturePaths: [
          'test/validation/captures/_fixtures/dormant_bracket_above.json',
          'test/validation/captures/_fixtures/dormant_bracket_at.json',
          'test/validation/captures/_fixtures/dormant_bracket_below.json',
        ],
      );
      final failures = checkBracketValidation(
        label: 'FakeDetector',
        tier: swapped.tier,
        capturePaths: swapped.profileCapturePaths,
        bracketThreshold: swapped.bracketThreshold,
        bracketUnit: swapped.bracketUnit,
      );
      expect(failures, isNotEmpty);
      expect(failures.first, contains('bracket validation failed'));
    });

    test('checkBracketValidation is a no-op for unvalidated / reproducerOnly',
        () {
      for (final tier in [
        EvidenceTier.unvalidated,
        EvidenceTier.reproducerOnly
      ]) {
        final failures = checkBracketValidation(
          label: 'FakeDetector',
          tier: tier,
          capturePaths: null,
          bracketThreshold: null,
          bracketUnit: null,
        );
        expect(failures, isEmpty,
            reason: 'Tier $tier should not require bracket validation.');
      }
    });
  });
}
