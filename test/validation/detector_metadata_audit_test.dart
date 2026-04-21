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
// v0.16.2 hardening extracted the five invariant checkers into
// `_support/audit_invariants.dart` so the detector gate and the
// component gate share a single implementation. Gaps closed by the
// shared module:
//
//   - Line-AND-block comment stripping via `stripDartComments`.
//   - Repo-containment check via `isPathInsideRepo` (rejects absolute
//     paths, `../../` traversal, and symlinked files that canonicalise
//     outside the repo root).
//   - Citation-URL validation via `checkCitationUrl` (requires
//     parseable http/https URI with authority).

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
            failures.addAll(checkCoveredThresholds(
              label: label,
              tier: meta.tier,
              coveredThresholds: meta.coveredThresholds,
              coveredStableIds: meta.coveredStableIds,
              bracketThreshold: meta.bracketThreshold,
            ));
            failures.addAll(checkSeverityScopedCeiling(
              label: label,
              tier: meta.tier,
              coveredThresholds: meta.coveredThresholds,
              aboveCeilingMultiplier: meta.aboveCeilingMultiplier,
            ));
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
              aboveCeilingMultiplier: meta.aboveCeilingMultiplier,
            ));
            break;
          case EvidenceTier.externallyCited:
            failures.addAll(
                checkCitationUrl(label, meta.citationUrl, required: true));
            if (meta.reproducerPath == null ||
                meta.reproducerPath!.trim().isEmpty) {
              failures.add('$label: missing reproducerPath');
            }
            failures.addAll(checkCoveredThresholds(
              label: label,
              tier: meta.tier,
              coveredThresholds: meta.coveredThresholds,
              coveredStableIds: meta.coveredStableIds,
              bracketThreshold: meta.bracketThreshold,
            ));
            failures.addAll(checkSeverityScopedCeiling(
              label: label,
              tier: meta.tier,
              coveredThresholds: meta.coveredThresholds,
              aboveCeilingMultiplier: meta.aboveCeilingMultiplier,
            ));
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
              aboveCeilingMultiplier: meta.aboveCeilingMultiplier,
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

    test('NetworkMonitorDetector ships at reproducerOnly (v0.16.4)', () {
      // Anti-tautology anchor. v0.16.4 staged an `externallyCited` raise
      // on the `slow_request` WARNING tier (1000 ms NNG citation) and
      // reverted in the same release: the `above` capture at 3117 ms
      // ambiently brackets the 3000 ms critical tier, providing dual-use
      // evidence the prose scope boundary cannot un-bracket. Re-raise is
      // deferred to v0.16.5 once the `above` capture is re-recorded
      // within [1000, 2000), severity-scoped `coveredThresholds` metadata
      // is wired through the audit + ledger, and the `aboveCeilingMultiplier`
      // schema guard (landed in v0.16.4) mechanically blocks drift.
      // Tier history: v0.16.1 reproducerOnly → v0.16.4 reproducerOnly
      // (externallyCited staged + reverted in same release).
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
      expect(meta.citationUrl, isNull,
          reason:
              'reproducerOnly does not populate citationUrl — reverted in v0.16.4 '
              'pending re-raise.');
      expect(meta.profileCapturePaths, isNull,
          reason: 'reproducerOnly does not ship profileCapturePaths — reverted '
              'in v0.16.4 pending re-raise.');
      expect(meta.bracketThreshold, isNull);
      expect(meta.bracketUnit, isNull);
      expect(meta.coveredStableIds, equals(const {'slow_request'}),
          reason: 'The reproducer still covers slow_request at both '
              'warning and critical tiers (reproducerOnly does not '
              'distinguish severities).');
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

  group('Orphan capture audit', () {
    // Walks `test/validation/captures/` (excluding `_fixtures/`) and
    // fails if any committed `.json` capture is neither referenced by a
    // detector's `profileCapturePaths` nor listed in the retained-
    // orphan allowlist below. Closes the v0.16.4 revert gap — two
    // below/at capture files were kept on disk for v0.16.5 re-raise
    // reuse after NetworkMonitorDetector demoted back to
    // `reproducerOnly` with `profileCapturePaths = null`. Without this
    // audit, a future drift that forgets those files (or deletes the
    // wrong one) passes CI silently because the metadata cross-check
    // only fires for captures referenced by live metadata.
    //
    // Retained-orphan allowlist: every entry must carry a rationale
    // linking to the milestone where the orphan acquires a live claim.
    // When a milestone consumes an entry, the entry moves from the
    // allowlist into the matching detector/component's
    // `profileCapturePaths` in the same PR — the list never grows
    // unbounded.
    // Typed manifest replaces the freeform `Map<String, String>`
    // allowlist. Each entry pins device / OS / Flutter / unit /
    // observed band / consumeBy release / owning claim so the audit
    // can parse every file on disk and cross-check it against the
    // manifest, and so expired entries (consumeBy release reached)
    // fail automatically rather than sitting dormant indefinitely.
    const retainedOrphans = <String, RetainedOrphanEntry>{
      'test/validation/captures/network_monitor/slow_request_below.json':
          RetainedOrphanEntry(
        role: 'below',
        device: 'iPhone 12',
        deviceOsVersion: 'iOS 17.5',
        flutterMajorMinor: '3.41',
        unit: 'ms',
        observedMin: 750,
        observedMax: 950,
        consumeBy: '0.16.5',
        owningClaim: 'NetworkMonitorDetector.slow_request.warning',
        rationale: 'v0.16.5 re-raise reuse — below bracket (812 ms, '
            'captured iPhone 12 iOS 17.5).',
      ),
      'test/validation/captures/network_monitor/slow_request_at.json':
          RetainedOrphanEntry(
        role: 'at',
        device: 'iPhone 12',
        deviceOsVersion: 'iOS 17.5',
        flutterMajorMinor: '3.41',
        unit: 'ms',
        observedMin: 1000,
        observedMax: 1100,
        consumeBy: '0.16.5',
        owningClaim: 'NetworkMonitorDetector.slow_request.warning',
        rationale: 'v0.16.5 re-raise reuse — at bracket (1035 ms, '
            'captured iPhone 12 iOS 17.5).',
      ),
    };

    test('no unreferenced captures on disk', () {
      if (!File('pubspec.yaml').existsSync()) {
        markTestSkipped('CWD is not the package root; skipping.');
        return;
      }
      final controller = SleuthController();
      try {
        controller.initializeDetectorsForTest();
        final referencedPaths = <String>{};
        for (final d in controller.detectorsForAudit) {
          if (d is! DetectorMetadataProvider) continue;
          final meta = (d as DetectorMetadataProvider).validationMetadata;
          final paths = meta.profileCapturePaths;
          if (paths == null) continue;
          for (final pth in paths) {
            if (pth.trim().isEmpty) continue;
            referencedPaths.add(pth);
          }
        }
        final failures = checkCaptureOrphans(
          capturesRoot: Directory('test/validation/captures'),
          referencedPaths: referencedPaths,
          allowlist: retainedOrphans.keys.toSet(),
        );
        expect(failures, isEmpty,
            reason: 'Orphan captures found on disk. If the capture is '
                'deliberately retained for a future milestone, add it '
                'to `retainedOrphans` above with a rationale linking '
                'to the milestone. Otherwise delete the file or wire '
                'it into a detector\'s profileCapturePaths. Orphans: '
                '$failures');
      } finally {
        controller.dispose();
      }
    });

    test('retained-orphan allowlist entries actually exist on disk', () {
      if (!File('pubspec.yaml').existsSync()) {
        markTestSkipped('CWD is not the package root; skipping.');
        return;
      }
      // Anti-rot: an allowlist that references deleted files silently
      // drifts into stale-promise territory. Assert every allowlist
      // entry resolves to a real file so the list cannot outlive the
      // artifacts it is meant to protect.
      final missing = <String>[];
      for (final relative in retainedOrphans.keys) {
        if (!File(relative).existsSync()) {
          missing.add(relative);
        }
      }
      expect(missing, isEmpty,
          reason: 'Retained-orphan allowlist entries reference missing '
              'files. A deleted file no longer needs an allowlist '
              'entry — either restore the file (if it was deleted in '
              'error) or remove the allowlist entry. Missing: $missing');
    });

    test('retained-orphan manifest parses + cross-checks + lifecycle', () {
      if (!File('pubspec.yaml').existsSync()) {
        markTestSkipped('CWD is not the package root; skipping.');
        return;
      }
      // Parse `version: X.Y.Z` from pubspec.yaml — the audit
      // compares it against each entry's `consumeBy` and fails
      // entries whose consume release has been reached or passed.
      final pubspecText = File('pubspec.yaml').readAsStringSync();
      final versionMatch = RegExp(r'^version:\s*(\S+)\s*$', multiLine: true)
          .firstMatch(pubspecText);
      expect(versionMatch, isNotNull,
          reason: 'pubspec.yaml is missing a top-level `version:` line');
      final currentVersion = versionMatch!.group(1)!;
      final failures = checkRetainedOrphanManifest(
        manifest: retainedOrphans,
        currentReleaseVersion: currentVersion,
      );
      expect(failures, isEmpty,
          reason: 'Retained-orphan manifest audit failed. Either (a) '
              'fix the capture on disk so it matches the manifest '
              'declaration, (b) update the manifest entry to match '
              'the true recording, (c) consume the capture in its '
              'owning claim, or (d) remove the file + manifest entry '
              'together if the milestone was skipped. Failures: '
              '$failures');
    });
  });
}
