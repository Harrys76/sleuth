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
//                                          `profileCapturePath` non-null
//                                          (v0.16.1 AB4 fix — closes the
//                                          "runtimeVerified has no stronger
//                                          artifact contract than
//                                          reproducerOnly" gap).
//       externallyCited                  → `citationUrl`, `reproducerPath`,
//                                          and `profileCapturePath` all
//                                          non-null (citation + reproducer
//                                          + capture of the cited number
//                                          actually occurring).
//       any tier > unvalidated           → `coveredStableIds` non-null and
//                                          non-empty (pins which issue
//                                          families the evidence covers
//                                          for multi-family detectors —
//                                          v0.16.1 AB2 fix).
//   - If a `reproducerPath` is present AND the test is running from the
//     repo root, the file actually exists on disk (catches typos and
//     files that get moved without updating the metadata), the file
//     contains `test(` / `testWidgets(` outside of line comments, AND
//     the file references the detector's runtimeType by name (v0.16.1
//     AB3 fix — prevents a tier raise from pointing at a stub or an
//     unrelated test file that just happens to contain a test token).
//
// v0.16.1 seeds every shipped detector at [EvidenceTier.unvalidated]
// except [NetworkMonitorDetector], which ships at
// [EvidenceTier.reproducerOnly] with a hermetic reproducer. Subsequent
// milestones raise one detector at a time; this gate ensures any tier
// raise either ships with the required supporting artifact or fails CI.
//
// This test imports `src/` directly (not the public barrel) because
// [SleuthController.detectorsForAudit] is a `@visibleForTesting` getter.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/sleuth.dart'
    show DetectorMetadata, DetectorMetadataProvider, EvidenceTier;
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/base_detector.dart';

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
      // Reject empty/whitespace plus trivially-short or un-punctuated
      // strings. A one-character "x" used to pass the prior `trim().isEmpty`
      // check; that defeated the premise of the audit (every metadata
      // entry carries a human-readable justification).
      const minRationaleLength = 20;
      final failures = <String>[];
      for (final d in controller.detectorsForAudit) {
        if (d is! DetectorMetadataProvider) continue;
        final DetectorMetadata meta =
            (d as DetectorMetadataProvider).validationMetadata;
        final trimmed = meta.rationale.trim();
        if (trimmed.isEmpty) {
          failures.add('${d.runtimeType}: empty rationale');
          continue;
        }
        if (trimmed.length < minRationaleLength) {
          failures.add('${d.runtimeType}: rationale too short '
              '(${trimmed.length} chars, need >= $minRationaleLength)');
          continue;
        }
        if (!trimmed.contains('.')) {
          failures.add(
              '${d.runtimeType}: rationale must contain at least one period '
              '(should read as one or more sentences)');
        }
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
            // No required fields beyond rationale — covered above.
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
            // AB4 (v0.16.1): `runtimeVerified` must carry a profile-mode
            // capture artifact on top of the reproducer — without it the
            // tier is indistinguishable from `reproducerOnly` and the
            // "runs on a real engine in profile mode" claim is unbacked.
            if (meta.profileCapturePath == null ||
                meta.profileCapturePath!.trim().isEmpty) {
              failures.add('$label: missing profileCapturePath — '
                  'runtimeVerified requires a captured profile-mode '
                  'artifact (timeline JSON / DevTools snapshot) in '
                  'addition to the reproducer');
            }
            break;
          case EvidenceTier.externallyCited:
            if (meta.citationUrl == null || meta.citationUrl!.trim().isEmpty) {
              failures.add('$label: missing citationUrl');
            }
            if (meta.reproducerPath == null ||
                meta.reproducerPath!.trim().isEmpty) {
              failures.add('$label: missing reproducerPath');
            }
            if (meta.profileCapturePath == null ||
                meta.profileCapturePath!.trim().isEmpty) {
              failures.add('$label: missing profileCapturePath — '
                  'externallyCited requires the profile-mode capture '
                  'demonstrating the cited threshold in practice, in '
                  'addition to the citation URL and the reproducer');
            }
            break;
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

    test('declared reproducer files exist on disk and contain tests', () {
      // Soft check: `flutter test` always runs from the package root, but
      // be defensive — if the working directory does not contain
      // `pubspec.yaml`, the repo-relative path cannot be resolved and the
      // existence check is meaningless. Skip rather than false-fail.
      if (!File('pubspec.yaml').existsSync()) {
        markTestSkipped(
          'Cannot resolve reproducerPath values: test CWD is not the '
          'package root (no pubspec.yaml).',
        );
        return;
      }

      // Require not just file existence but also that the file contains
      // actual test declarations. Prevents a tier promotion from shipping
      // with an empty stub — `touch test/validation/foo_test.dart` used
      // to satisfy the gate.
      final testInvocation = RegExp(r'\b(test|testWidgets)\s*\(');

      // AB3 (v0.16.1): the reproducer file must also reference the detector's
      // runtime type by name. Prevents a tier raise from pointing at a
      // shared/unrelated test file that just happens to contain a `test(`
      // token, or at a file whose `test()` blocks are all line-commented.
      // Line comments are stripped before matching so `// test(...)` does
      // not satisfy the invocation regex.
      final lineComment = RegExp(r'//[^\n]*');

      final missing = <String>[];
      final empty = <String>[];
      final unrelated = <String>[];
      final missingCapture = <String>[];
      for (final d in controller.detectorsForAudit) {
        if (d is! DetectorMetadataProvider) continue;
        final meta = (d as DetectorMetadataProvider).validationMetadata;
        final path = meta.reproducerPath;
        if (path == null || path.trim().isEmpty) continue;
        final file = File(path);
        if (!file.existsSync()) {
          missing.add('${d.runtimeType}: $path');
          continue;
        }
        final rawContents = file.readAsStringSync();
        final codeOnly = rawContents.replaceAll(lineComment, '');
        if (!testInvocation.hasMatch(codeOnly)) {
          empty.add('${d.runtimeType}: $path (no test()/testWidgets() calls '
              'outside of line comments)');
          continue;
        }
        final typeName = d.runtimeType.toString();
        if (!codeOnly.contains(typeName)) {
          unrelated.add('${d.runtimeType}: $path (file contains tests but '
              'does not reference $typeName by name — the reproducer must '
              'exercise the detector it is cited for)');
        }
        // AB4 (v0.16.1): when a profileCapturePath is declared, the file
        // must actually exist on disk. Required for `runtimeVerified` +
        // `externallyCited` per the tier-fields test above; optional for
        // weaker tiers but still file-exists-checked when present so a
        // stale path cannot rot unnoticed.
        final capture = meta.profileCapturePath;
        if (capture != null && capture.trim().isNotEmpty) {
          if (!File(capture).existsSync()) {
            missingCapture.add('${d.runtimeType}: $capture');
          }
        }
      }
      expect(missing, isEmpty,
          reason: 'Declared reproducer paths do not exist on disk — either '
              'the file was renamed/moved without updating the metadata, '
              'or the path contains a typo: $missing');
      expect(empty, isEmpty,
          reason: 'Declared reproducer files exist but contain no test '
              'declarations. A tier promotion must be backed by a real '
              'test, not an empty stub: $empty');
      expect(unrelated, isEmpty,
          reason: 'Declared reproducer files do not reference the detector '
              'under promotion by runtimeType name. A tier raise must cite '
              'a test that actually exercises the detector, not an '
              'unrelated file that happens to contain a test() token: '
              '$unrelated');
      expect(missingCapture, isEmpty,
          reason: 'Declared profileCapturePath values do not exist on disk. '
              'Either the capture file was renamed/moved without updating '
              'the metadata, the path contains a typo, or the capture was '
              'never committed: $missingCapture');
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
      // AB2 (v0.16.1): the reproducer exercises only the slow_request
      // thresholds. The other four issue families this detector emits
      // remain implicitly unvalidated. Pin the coverage set so a silent
      // widening to "whole detector" fails this test.
      expect(meta.coveredStableIds, equals(const {'slow_request'}),
          reason: 'The reproducer only covers slow_request boundaries. If '
              'the coverage set was widened, a matching reproducer for the '
              'new family must land with it, not a silent detector-scope '
              'claim.');
    });
  });
}
