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

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/sleuth.dart'
    show
        DetectorMetadata,
        DetectorMetadataProvider,
        EvidenceTier,
        ProfileCaptureSchema;
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/detectors/frame_timing_detector.dart';
import 'package:sleuth/src/detectors/network_monitor_detector.dart';
import 'package:sleuth/src/models/base_detector.dart';

import '_support/audit_invariants.dart';

// Anchor expectations per batch. Single source of truth: `anchoredTypes`
// below derives its entries from these maps' keys, so deleting an anchor
// block removes its detectors from `anchoredTypes` and fires the ratchet.
const _v0163Expectations = <DetectorType, (String, Set<String>)>{
  DetectorType.imageMemory: (
    'test/validation/image_memory_reproducer_test.dart',
    {'uncached_images'},
  ),
  DetectorType.opacity: (
    'test/validation/opacity_reproducer_test.dart',
    {'opacity_zero'},
  ),
  DetectorType.globalKey: (
    'test/validation/global_key_reproducer_test.dart',
    {'excessive_global_keys', 'global_key_recreation'},
  ),
  DetectorType.listview: (
    'test/validation/listview_reproducer_test.dart',
    {
      'non_lazy_listview',
      'non_lazy_gridview',
      'non_lazy_sliver_list',
      'non_lazy_sliver_grid',
      'non_lazy_list',
      'sliver_to_box_adapter_large',
      'sliver_to_box_adapter_shrinkwrap',
      'sliver_fill_remaining_scrollable',
    },
  ),
};

const _v0171Expectations = <DetectorType, (String, Set<String>)>{
  DetectorType.layoutBottleneck: (
    'test/validation/layout_bottleneck_reproducer_test.dart',
    {'layout_bottleneck', 'wrap_layout_bottleneck'},
  ),
  DetectorType.nestedScroll: (
    'test/validation/nested_scroll_reproducer_test.dart',
    {'nested_scroll', 'nested_scroll_same_axis'},
  ),
  DetectorType.customPainter: (
    'test/validation/custom_painter_reproducer_test.dart',
    {'always_repaint_painter', 'frequent_repaint_painter'},
  ),
  DetectorType.animatedBuilder: (
    'test/validation/animated_builder_reproducer_test.dart',
    {'animated_builder_no_child'},
  ),
  DetectorType.keepAlive: (
    'test/validation/keep_alive_reproducer_test.dart',
    {'excessive_keep_alive'},
  ),
  DetectorType.fontLoading: (
    'test/validation/font_loading_reproducer_test.dart',
    {'runtime_font_loading', 'multiple_custom_fonts'},
  ),
  DetectorType.repaintBoundary: (
    'test/validation/repaint_boundary_reproducer_test.dart',
    {'missing_repaint_boundary', 'excessive_repaint_boundary'},
  ),
  DetectorType.setStateScope: (
    'test/validation/setstate_scope_reproducer_test.dart',
    {'setstate_scope'},
  ),
  DetectorType.startup: (
    'test/validation/startup_reproducer_test.dart',
    {'slow_startup_ttff'},
  ),
};

/// v0.17.2 expectations tuple is `(reproducerPath, coveredStableIds,
/// parametricFamilies?)`. Last element is null for detectors that don't
/// declare parametric families; repaint + rebuild declare `{'repaint_debug'}`
/// / `{'rebuild_debug'}` since v0.17.3.
const _v0172Expectations = <DetectorType, (String, Set<String>, Set<String>?)>{
  DetectorType.shaderJank: (
    'test/detectors/shader_jank_detector_test.dart',
    {'shader_compilation'},
    null,
  ),
  DetectorType.heavyCompute: (
    'test/detectors/heavy_compute_detector_test.dart',
    {'heavy_compute'},
    null,
  ),
  DetectorType.platformChannel: (
    'test/detectors/platform_channel_detector_test.dart',
    {'platform_channel_traffic'},
    null,
  ),
  DetectorType.memoryPressure: (
    'test/detectors/memory_pressure_detector_test.dart',
    {
      'gc_pressure',
      'heap_growing',
      'heap_near_capacity',
      'native_memory_growing',
    },
    null,
  ),
  DetectorType.gpuPressure: (
    'test/detectors/gpu_pressure_detector_test.dart',
    {'raster_dominance', 'expensive_gpu_nodes'},
    null,
  ),
  DetectorType.repaint: (
    'test/detectors/repaint_detector_test.dart',
    {'excessive_repaint', 'excessive_repaint_debug'},
    {'repaint_debug'},
  ),
  DetectorType.rebuild: (
    'test/detectors/rebuild_detector_test.dart',
    {'stateful_density', 'rebuild_activity'},
    {'rebuild_debug'},
  ),
  DetectorType.shallowRebuildRisk: (
    'test/detectors/shallow_rebuild_risk_detector_test.dart',
    {'shallow_rebuild_risk'},
    null,
  ),
};

/// Detectors anchored by NetworkMonitor + FrameTiming single-detector
/// anchors (not batch blocks). These are enumerated explicitly because
/// the v0.16.5 / v0.16.6 anchor tests assert against the detector's
/// `validationMetadata` directly rather than a shared expectations map.
const _singleDetectorAnchors = <DetectorType>{
  DetectorType.networkMonitor,
  DetectorType.frameTiming,
};

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
              parametricFamilies: meta.parametricFamilies,
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
              parametricFamilies: meta.parametricFamilies,
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
        // IDs its evidence covers. `coveredStableIds` and
        // `parametricFamilies` are peer namespaces — at least one must be
        // non-empty, entries are trim/empty validated, and overlap
        // between the two is rejected so a single literal can't discharge
        // two obligations.
        if (meta.tier != EvidenceTier.unvalidated) {
          final covered = meta.coveredStableIds;
          final parametric = meta.parametricFamilies;
          final hasCovered = covered != null && covered.isNotEmpty;
          final hasParametric = parametric != null && parametric.isNotEmpty;
          if (!hasCovered && !hasParametric) {
            failures.add('$label: missing coveredStableIds AND '
                'parametricFamilies — tier > unvalidated must declare at '
                'least one non-empty namespace of stable IDs the evidence '
                'covers (exact / `<family>:<param>` in coveredStableIds, or '
                '`<family>_<typeName>` prefix in parametricFamilies)');
          }
          if (covered != null) {
            for (final id in covered) {
              if (id.trim().isEmpty) {
                failures.add('$label: coveredStableIds contains an empty '
                    'or whitespace-only entry');
                break;
              }
            }
          }
          if (parametric != null) {
            for (final fam in parametric) {
              if (fam.trim().isEmpty) {
                failures.add('$label: parametricFamilies contains an empty '
                    'or whitespace-only entry');
                break;
              }
            }
          }
          if (covered != null && parametric != null) {
            final overlap = covered.intersection(parametric);
            if (overlap.isNotEmpty) {
              failures.add('$label: coveredStableIds and parametricFamilies '
                  'share entries $overlap — declaring the same name in '
                  'both namespaces is rejected; pick one (exact/`:` for '
                  'bare families, `_` prefix for underscore-parametric)');
            }
          }
          // Reject prefix-collision within parametricFamilies. When two
          // entries share a `<prefix>_` relationship (e.g. `{'foo',
          // 'foo_bar'}`), a literal like `foo_bar_baz` would match both
          // families and let one assertion discharge two obligations.
          if (parametric != null && parametric.length > 1) {
            final list = parametric.toList();
            final collisions = <String>{};
            for (var i = 0; i < list.length; i++) {
              for (var j = i + 1; j < list.length; j++) {
                final a = list[i];
                final b = list[j];
                if (a.isEmpty || b.isEmpty) continue;
                if (a.startsWith('${b}_') || b.startsWith('${a}_')) {
                  collisions.add(a);
                  collisions.add(b);
                }
              }
            }
            if (collisions.isNotEmpty) {
              failures.add('$label: parametricFamilies entries collide on '
                  '`_`-prefix: $collisions. A literal matching the longer '
                  'family necessarily matches the shorter too, letting '
                  'one assertion credit both. Narrow the declaration so '
                  'no entry is a prefix of another.');
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
            parametricFamilies: meta.parametricFamilies,
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

    test('NetworkMonitorDetector pinned at reproducerOnly (v0.16.5)', () {
      // Anti-tautology anchor. v0.16.5's second `externallyCited` raise
      // REVERTED on two grounds: (1) NN/g 1.0 s is a UI feedback
      // guideline, not a generic HTTP latency threshold; (2) profile
      // captures verify scenario marker span only, not detector emission.
      // Tier history: v0.16.1 reproducerOnly → v0.16.4 reproducerOnly
      // (externallyCited staged+reverted) → v0.16.5 reproducerOnly
      // (second externallyCited staged+reverted). L2 negative assertion
      // + mechanism-4 prose-drift guard below stay wired so the v0.16.7
      // re-raise cannot silently regress.
      final BaseDetector? nm = controller.detectorsForAudit
          .where((d) => d.type == DetectorType.networkMonitor)
          .cast<BaseDetector?>()
          .firstWhere((_) => true, orElse: () => null);
      expect(nm, isNotNull,
          reason: 'NetworkMonitorDetector should be registered by default.');
      expect(nm, isA<DetectorMetadataProvider>());
      final meta = (nm as DetectorMetadataProvider).validationMetadata;
      expect(meta.tier, EvidenceTier.reproducerOnly,
          reason: 'v0.16.5 shipped at reproducerOnly — second staged '
              'externallyCited raise reverted on NN/g semantic mismatch '
              '+ capture-proves-helper-not-detector grounds.');
      expect(meta.reproducerPath,
          equals('test/validation/network_monitor_reproducer_test.dart'));
      expect(meta.citationUrl, isNull,
          reason: 'No external citation at reproducerOnly tier.');
      expect(meta.profileCapturePaths, isNull,
          reason: 'profileCapturePaths is first-class on externallyCited / '
              'runtimeVerified only — the three capture files on disk are '
              'retained orphans for v0.16.7 re-raise reuse, tracked in the '
              'orphan manifest below, not live metadata.');
      expect(meta.bracketThreshold, isNull);
      expect(meta.bracketUnit, isNull);
      expect(meta.coveredThresholds, isNull,
          reason: 'No severity-scoped claim at reproducerOnly.');
      expect(meta.aboveCeilingMultiplier, isNull);
      expect(meta.parametricFamilies, isNull,
          reason: 'NetworkMonitor does not declare parametric families.');
      expect(meta.coveredStableIds, equals(const {'slow_request'}),
          reason: 'Reproducer still covers the `slow_request` family; '
              'preserved from v0.16.1.');

      // L2 negative assertion (v0.16.5). Dormant at reproducerOnly.
      // Fires when a re-raise populates `coveredThresholds`: a diff that
      // adds `slow_request.critical` without its own citation + bracket
      // triad fails CI. Critical cannot piggyback on a warning-tier raise.
      final covered = meta.coveredThresholds ?? const <String>{};
      final criticalClaims =
          covered.where((t) => t.endsWith('.critical')).toList();
      expect(criticalClaims, isEmpty,
          reason: 'L2: no coveredThresholds entry may claim the critical '
              'tier without its own citation + bracket triad. Offending '
              'entries: $criticalClaims.');

      // Rationale prose making an externally-grounded claim about the
      // critical tier without metadata backing is prohibited. Block
      // comments stripped first; inline backticks normalised to
      // whitespace BEFORE lowercasing so identifier fragments like
      // `` stays `reproducerOnly` `` don't mask the phrase match.
      final stripped =
          meta.rationale.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
      final normalised = stripped.replaceAll('`', ' ');
      final collapsed =
          normalised.replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
      final mentionsCitationSource = collapsed.contains('nn/g') ||
          collapsed.contains('nielsen norman') ||
          collapsed.contains('response-times') ||
          collapsed.contains('response times');
      final hasCriticalAndCitation =
          collapsed.contains('critical') && mentionsCitationSource;
      if (hasCriticalAndCitation) {
        // Allowed only if the critical mention is explicitly an exclusion.
        final hasExclusion = collapsed.contains('stays reproduceronly') ||
            collapsed.contains('not covered') ||
            collapsed.contains('scoped out') ||
            collapsed.contains('only the warning') ||
            collapsed.contains('warning threshold only') ||
            collapsed.contains('warning tier only');
        expect(hasExclusion, isTrue,
            reason: 'Symptom-persistence mechanism 4: rationale co-mentions '
                'the NN/g citation source and the critical tier without an '
                'explicit exclusion. Prose must make clear critical is NOT '
                'externally grounded.');
      }

      // AB4 default-drift cross-check (v0.16.5): when `bracketThreshold`
      // is set, it must match the detector's runtime default — otherwise
      // a change adjusting one but not the other creates silent drift.
      // Dormant at reproducerOnly; fires on v0.16.7 re-raise.
      if (meta.bracketThreshold != null) {
        final detector = NetworkMonitorDetector();
        expect(detector.slowThresholdMs, equals(meta.bracketThreshold),
            reason: 'AB4: metadata bracketThreshold (${meta.bracketThreshold} '
                '${meta.bracketUnit}) must track the detector\'s runtime '
                'default (slowThresholdMs = ${detector.slowThresholdMs}). A '
                'mismatch means the externally-cited bracket claims a '
                'different threshold than the detector actually uses.');
      }
    });

    test('FrameTimingDetector pinned at reproducerOnly (v0.16.6)', () {
      // Anti-tautology anchor (B30). v0.16.6 raises FrameTimingDetector
      // unvalidated → reproducerOnly with four stableIds pinned by the
      // hermetic reproducer at `test/validation/frame_timing_reproducer_test.dart`:
      // `sustained_jank`, `jank_detected`, `raster_cache_thrashing`,
      // `raster_cache_growing`. All extended-claim fields (citationUrl /
      // profileCapturePaths / bracketThreshold / bracketUnit /
      // coveredThresholds / aboveCeilingMultiplier) MUST remain null —
      // none of them are load-bearing at reproducerOnly, and a future
      // externallyCited raise populates them deliberately. Pinning every
      // field blocks silent drift in either direction.
      final BaseDetector? ft = controller.detectorsForAudit
          .where((d) => d.type == DetectorType.frameTiming)
          .cast<BaseDetector?>()
          .firstWhere((_) => true, orElse: () => null);
      expect(ft, isNotNull,
          reason: 'FrameTimingDetector should be registered by default.');
      expect(ft, isA<DetectorMetadataProvider>());
      final meta = (ft as DetectorMetadataProvider).validationMetadata;
      expect(meta.tier, EvidenceTier.reproducerOnly,
          reason: 'v0.16.6 raised FrameTimingDetector to reproducerOnly via '
              'a hermetic reproducer bypassing warmup and exercising both '
              'synthetic FrameStats and real-pipeline FrameTiming paths.');
      expect(meta.reproducerPath,
          equals('test/validation/frame_timing_reproducer_test.dart'));
      expect(meta.citationUrl, isNull,
          reason: 'No external citation at reproducerOnly tier.');
      expect(meta.profileCapturePaths, isNull,
          reason: 'profileCapturePaths is first-class on externallyCited / '
              'runtimeVerified only.');
      expect(meta.bracketThreshold, isNull);
      expect(meta.bracketUnit, isNull);
      expect(meta.coveredThresholds, isNull,
          reason: 'No severity-scoped claim at reproducerOnly.');
      expect(meta.aboveCeilingMultiplier, isNull);
      expect(meta.parametricFamilies, isNull,
          reason: 'FrameTiming does not declare parametric families.');
      expect(
          meta.coveredStableIds,
          equals(const {
            'sustained_jank',
            'jank_detected',
            'raster_cache_thrashing',
            'raster_cache_growing',
          }),
          reason: 'v0.16.6 pins exactly four FrameTiming stableIds. Any '
              'addition or removal must land alongside a reproducer change.');

      // Constructor side-effect check: the audit walks real controller
      // detectors, so FrameTimingDetector must be constructible without
      // side effects (matches the v0.16.0 F1 fix).
      expect(() => FrameTimingDetector(), returnsNormally,
          reason: 'FrameTimingDetector() must be side-effect-free so the '
              'audit can construct it in isolation.');
    });

    test('v0.17.1 structural batch pinned at reproducerOnly', () {
      // Anti-tautology anchor for the 9-detector bulk tier raise. Each
      // entry pins the (type → reproducerPath → coveredStableIds) triple
      // so a silent rename, stableId drift, or path-churn trips CI.
      // Every raise here is reproducerOnly — all extended-claim fields
      // (citationUrl, profileCapturePaths, bracketThreshold, bracketUnit,
      // coveredThresholds, aboveCeilingMultiplier) MUST remain null.
      const expectations = _v0171Expectations;

      final failures = <String>[];
      for (final entry in expectations.entries) {
        final type = entry.key;
        final (expectedPath, expectedIds) = entry.value;
        final BaseDetector? d = controller.detectorsForAudit
            .where((d) => d.type == type)
            .cast<BaseDetector?>()
            .firstWhere((_) => true, orElse: () => null);
        if (d == null) {
          failures.add('${type.name}: not registered on controller');
          continue;
        }
        if (d is! DetectorMetadataProvider) {
          failures.add('${type.name}: missing DetectorMetadataProvider');
          continue;
        }
        final meta = (d as DetectorMetadataProvider).validationMetadata;
        if (meta.tier != EvidenceTier.reproducerOnly) {
          failures.add('${type.name}: tier=${meta.tier.name}, expected '
              'reproducerOnly');
        }
        if (meta.reproducerPath != expectedPath) {
          failures.add('${type.name}: reproducerPath='
              '${meta.reproducerPath}, expected $expectedPath');
        }
        if (meta.coveredStableIds == null ||
            !setEquals(meta.coveredStableIds, expectedIds)) {
          failures.add('${type.name}: coveredStableIds='
              '${meta.coveredStableIds}, expected $expectedIds');
        }
        if (meta.citationUrl != null) {
          failures.add('${type.name}: citationUrl=${meta.citationUrl}, '
              'expected null at reproducerOnly');
        }
        if (meta.profileCapturePaths != null) {
          failures.add('${type.name}: profileCapturePaths='
              '${meta.profileCapturePaths}, expected null at reproducerOnly');
        }
        if (meta.bracketThreshold != null) {
          failures.add('${type.name}: bracketThreshold='
              '${meta.bracketThreshold}, expected null at reproducerOnly');
        }
        if (meta.bracketUnit != null) {
          failures.add('${type.name}: bracketUnit=${meta.bracketUnit}, '
              'expected null at reproducerOnly');
        }
        if (meta.coveredThresholds != null) {
          failures.add('${type.name}: coveredThresholds='
              '${meta.coveredThresholds}, expected null at reproducerOnly');
        }
        if (meta.aboveCeilingMultiplier != null) {
          failures.add('${type.name}: aboveCeilingMultiplier='
              '${meta.aboveCeilingMultiplier}, expected null at '
              'reproducerOnly');
        }
        if (meta.parametricFamilies != null) {
          failures.add('${type.name}: parametricFamilies='
              '${meta.parametricFamilies}, expected null — v0.17.1 '
              'structural batch does not declare parametric families');
        }
      }

      expect(failures, isEmpty,
          reason: 'v0.17.1 structural batch anchor drift — one of the 9 '
              'bulk-raised detectors has diverged from the pinned triple '
              '(tier, reproducerPath, coveredStableIds): $failures');
    });

    test('v0.16.3 pre-ratchet anchor block', () {
      // Anchor the 4 v0.16.3 detectors with the same (type →
      // reproducerPath → coveredStableIds) triple the v0.17.1 structural
      // batch uses. All four are `reproducerOnly`; extended-claim fields
      // (citationUrl, profileCapturePaths, bracketThreshold, bracketUnit,
      // coveredThresholds, aboveCeilingMultiplier) MUST remain null.
      const expectations = _v0163Expectations;

      final failures = <String>[];
      for (final entry in expectations.entries) {
        final type = entry.key;
        final (expectedPath, expectedIds) = entry.value;
        final BaseDetector? d = controller.detectorsForAudit
            .where((d) => d.type == type)
            .cast<BaseDetector?>()
            .firstWhere((_) => true, orElse: () => null);
        if (d == null) {
          failures.add('${type.name}: not registered on controller');
          continue;
        }
        if (d is! DetectorMetadataProvider) {
          failures.add('${type.name}: missing DetectorMetadataProvider');
          continue;
        }
        final meta = (d as DetectorMetadataProvider).validationMetadata;
        if (meta.tier != EvidenceTier.reproducerOnly) {
          failures.add('${type.name}: tier=${meta.tier.name}, expected '
              'reproducerOnly');
        }
        if (meta.reproducerPath != expectedPath) {
          failures.add('${type.name}: reproducerPath=${meta.reproducerPath}, '
              'expected $expectedPath');
        }
        if (meta.coveredStableIds == null ||
            !setEquals(meta.coveredStableIds, expectedIds)) {
          failures.add('${type.name}: coveredStableIds='
              '${meta.coveredStableIds}, expected $expectedIds');
        }
        if (meta.citationUrl != null ||
            meta.profileCapturePaths != null ||
            meta.bracketThreshold != null ||
            meta.bracketUnit != null ||
            meta.coveredThresholds != null ||
            meta.aboveCeilingMultiplier != null) {
          failures.add('${type.name}: extended-claim field populated but '
              'tier is reproducerOnly');
        }
        if (meta.parametricFamilies != null) {
          failures.add('${type.name}: parametricFamilies='
              '${meta.parametricFamilies}, expected null — v0.16.3 '
              'pre-ratchet batch does not declare parametric families');
        }
      }

      expect(failures, isEmpty,
          reason: 'v0.16.3 pre-ratchet anchor drift: $failures');
    });

    test('v0.17.2 vmOnly + hybrid batch pinned at reproducerOnly', () {
      // Anti-tautology anchor for the 8-detector vmOnly + hybrid batch.
      // Each entry pins the (type → reproducerPath → coveredStableIds)
      // triple. All 8 raises are `reproducerOnly`; extended-claim fields
      // (citationUrl, profileCapturePaths, bracketThreshold, bracketUnit,
      // coveredThresholds, aboveCeilingMultiplier) MUST remain null.
      const expectations = _v0172Expectations;

      final failures = <String>[];
      for (final entry in expectations.entries) {
        final type = entry.key;
        final (expectedPath, expectedIds, expectedParametric) = entry.value;
        final BaseDetector? d = controller.detectorsForAudit
            .where((d) => d.type == type)
            .cast<BaseDetector?>()
            .firstWhere((_) => true, orElse: () => null);
        if (d == null) {
          failures.add('${type.name}: not registered on controller');
          continue;
        }
        if (d is! DetectorMetadataProvider) {
          failures.add('${type.name}: missing DetectorMetadataProvider');
          continue;
        }
        final meta = (d as DetectorMetadataProvider).validationMetadata;
        if (meta.tier != EvidenceTier.reproducerOnly) {
          failures.add('${type.name}: tier=${meta.tier.name}, expected '
              'reproducerOnly');
        }
        if (meta.reproducerPath != expectedPath) {
          failures.add('${type.name}: reproducerPath=${meta.reproducerPath}, '
              'expected $expectedPath');
        }
        if (meta.coveredStableIds == null ||
            !setEquals(meta.coveredStableIds, expectedIds)) {
          failures.add('${type.name}: coveredStableIds='
              '${meta.coveredStableIds}, expected $expectedIds');
        }
        if (!setEquals(meta.parametricFamilies, expectedParametric)) {
          failures.add('${type.name}: parametricFamilies='
              '${meta.parametricFamilies}, expected $expectedParametric');
        }
        if (meta.citationUrl != null ||
            meta.profileCapturePaths != null ||
            meta.bracketThreshold != null ||
            meta.bracketUnit != null ||
            meta.coveredThresholds != null ||
            meta.aboveCeilingMultiplier != null) {
          failures.add('${type.name}: extended-claim field populated but '
              'tier is reproducerOnly');
        }
      }

      expect(failures, isEmpty,
          reason: 'v0.17.2 vmOnly + hybrid batch anchor drift: $failures');
    });

    test('every reproducerOnly+ detector appears in an anchor block', () {
      // Ratchet invariant. Every detector shipped at `reproducerOnly` or
      // stronger must be named in an anchor block. `anchoredTypes` is
      // DERIVED from the file-scope expectations maps' keys plus the
      // single-detector anchor set — deleting an anchor block removes
      // entries from `anchoredTypes` automatically and fires the ratchet.
      // Single source of truth; no hand-maintained allowlist drift.
      final anchoredTypes = <DetectorType>{
        ..._singleDetectorAnchors,
        ..._v0163Expectations.keys,
        ..._v0171Expectations.keys,
        ..._v0172Expectations.keys,
      };

      final shippedAboveUnvalidated = <DetectorType>{};
      for (final d in controller.detectorsForAudit) {
        if (d is! DetectorMetadataProvider) continue;
        final meta = (d as DetectorMetadataProvider).validationMetadata;
        if (meta.tier != EvidenceTier.unvalidated) {
          shippedAboveUnvalidated.add(d.type);
        }
      }

      final unanchored = shippedAboveUnvalidated.difference(anchoredTypes);
      expect(unanchored, isEmpty,
          reason: 'These detectors are shipped above `unvalidated` but no '
              'anchor block in detector_metadata_audit_test.dart names them '
              'by `DetectorType.<value>`. An anchor block pins the '
              '(type, reproducerPath, coveredStableIds) triple so silent '
              'rename / path churn / stableId drift fails CI. Add an anchor '
              'block and extend the `anchoredTypes` set to include: '
              '$unanchored');

      // Symmetric check: anchors referencing detectors NOT registered on
      // the controller would indicate a stale allowlist (detector was
      // removed but anchor kept).
      final registeredTypes =
          controller.detectorsForAudit.map((d) => d.type).toSet();
      final stale = anchoredTypes.difference(registeredTypes);
      expect(stale, isEmpty,
          reason: 'These anchored DetectorTypes are no longer registered on '
              'the controller — remove the stale anchor allowlist entry: '
              '$stale');
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
    // v0.16.5 second `externallyCited` raise REVERTED on (a) NN/g 1.0 s
    // is a UI feedback guideline, not a generic HTTP latency threshold
    // and (b) profile captures verify scenario marker span only, not
    // detector emission. Detector metadata nulled `profileCapturePaths`
    // in the revert, so all three captures become orphans on disk.
    // Retained — not deleted — because the v0.16.7 re-raise reuses the
    // on-device recording (re-recording across the Flutter 3.41.4 pin
    // + iPhone 12 exception is expensive without reason). Manifest
    // cross-check enforces device / OS / Flutter / unit / observed band.
    const retainedOrphans = <String, RetainedOrphanEntry>{
      'test/validation/captures/network_monitor/slow_request_below.json':
          RetainedOrphanEntry(
        role: 'below',
        device: 'iPhone 12',
        deviceOsVersion: 'iOS 17.5',
        flutterMajorMinor: '3.41',
        unit: 'ms',
        observedMin: 720,
        observedMax: 900,
        consumeBy: '0.18.0',
        owningClaim:
            'NetworkMonitorDetector.slow_request.warning externallyCited '
            're-raise (v0.16.7)',
        rationale: 'Below bracket (812 ms) captured on iPhone 12 / iOS 17.5 / '
            'Flutter 3.41.4 via the example app NetworkMonitor Capture '
            'Helper screen. Retained from v0.16.5 revert; v0.16.6 shipped '
            'FrameTiming + ListView tier raises instead and deferred the '
            'NetworkMonitor re-raise — wiring now slated for v0.16.7 once '
            'citation + detector-emission gate blockers are resolved.',
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
        consumeBy: '0.18.0',
        owningClaim:
            'NetworkMonitorDetector.slow_request.warning externallyCited '
            're-raise (v0.16.7)',
        rationale: 'At bracket (1035 ms, within ±10% of 1000 ms threshold) '
            'captured on iPhone 12 / iOS 17.5 / Flutter 3.41.4. Retained '
            'from v0.16.5 revert; v0.16.6 deferred the re-raise so '
            'reuse shifts to v0.16.7.',
      ),
      'test/validation/captures/network_monitor/slow_request_above.json':
          RetainedOrphanEntry(
        role: 'above',
        device: 'iPhone 12',
        deviceOsVersion: 'iOS 17.5',
        flutterMajorMinor: '3.41',
        unit: 'ms',
        observedMin: 1450,
        observedMax: 1800,
        consumeBy: '0.18.0',
        owningClaim:
            'NetworkMonitorDetector.slow_request.warning externallyCited '
            're-raise (v0.16.7)',
        rationale: 'Above bracket (1515 ms) within `[1000, 2000)` band so the '
            '`aboveCeilingMultiplier: 2.0` ceiling fires dormantly until '
            'v0.16.7 wires the raise. Retained from v0.16.5 revert; '
            'v0.16.6 deferred the re-raise.',
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
