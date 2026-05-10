// IDE analyzer false-positive: dart:core RegExp uses @Deprecated.implement
// (fires only on subclassing). Remove when analyzer-server recognizes the
// implement-only kind.
// ignore_for_file: deprecated_member_use
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
        BracketSpec,
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
  DetectorType.customPainter: (
    'test/validation/custom_painter_reproducer_test.dart',
    {'always_repaint_painter', 'frequent_repaint_painter'},
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

/// v0.17.2 initial raise from unvalidated → reproducerOnly for the
/// 8-detector vmOnly + hybrid batch. v0.17.4–v0.17.6 tier-quality audit
/// rewrote the reproducers per detector (tier unchanged, evidence
/// strengthened): vmOnly + structural reproducers now feed raw
/// `List<TimelineEvent>` through `TimelineParser.parse()` into the
/// detector, exercising the VM → parser → detector boundary that the
/// original v0.17.2 fixtures bypassed. Paths flip patch-by-patch — a
/// detector still pointing at `test/detectors/*_detector_test.dart`
/// carries the pre-rewrite reproducer shape.
///
/// Expectations tuple is `(reproducerPath, coveredStableIds,
/// parametricFamilies?)`. Last element is null for detectors that don't
/// declare parametric families; repaint + rebuild declare
/// `{'repaint_debug'}` / `{'rebuild_debug'}` since v0.17.3.
const _v0174Expectations = <DetectorType, (String, Set<String>, Set<String>?)>{
  DetectorType.shaderJank: (
    'test/validation/shader_jank_reproducer_test.dart',
    {'shader_compilation'},
    null,
  ),
  // HeavyCompute removed from this anchor block in v0.18.2 — raised
  // from `reproducerOnly` to `runtimeVerified` (warning tier, 8 ms
  // threshold). See the dedicated "HeavyComputeDetector pinned at
  // runtimeVerified (v0.18.2)" anchor below for the replacement
  // tier-pin assertions.
  // PlatformChannelDetector removed from this anchor block in v0.19.4 —
  // base tier raised from `reproducerOnly` to `runtimeVerified` (warning
  // tier, 20 calls/sec frequency axis) backed by three on-device
  // captures. The 41 calls/sec critical tier and the 8 ms cumulative-
  // duration axis remain implicitly reproducerOnly. See the dedicated
  // `PlatformChannelDetector pinned at runtimeVerified (v0.19.4)`
  // anchor block below for the tier-pin assertions + critical-tier and
  // duration-axis prose-drift guards.
  // MemoryPressureDetector lifted out of the v0.17.4 reproducerOnly batch
  // in v0.19.3 — its `heap_growing` family raised to runtimeVerified via
  // perStableIdTier with three on-device captures. Other 3 families
  // (gc_pressure, heap_near_capacity, native_memory_growing) remain at
  // base reproducerOnly. See the dedicated `MemoryPressureDetector
  // pinned at runtimeVerified for heap_growing (v0.19.3)` anchor block
  // below for the per-family-tier invariants.
  // RebuildDetector lifted out of the v0.17.4 reproducerOnly batch in
  // v0.19.12 — `rebuild_activity` family raised to runtimeVerified via
  // perStableIdTier with three on-device captures bracketing 11
  // BUILDs/sec under baseline-subtraction (capture-mode operator
  // measures ambient inline before each leg and calls
  // `setBaseline(int)`). Other family `stateful_density` remains at
  // base reproducerOnly. See the dedicated `RebuildDetector pinned at
  // runtimeVerified for rebuild_activity (v0.19.12)` anchor block
  // below for the per-family-tier + bracket-field invariants.
  DetectorType.gpuPressure: (
    'test/validation/gpu_pressure_reproducer_test.dart',
    {'raster_dominance', 'expensive_gpu_nodes'},
    null,
  ),
  // StreamResourceDetector — base reproducerOnly + perStableIdTier raise
  // on `stream_resource_growth.warning`; pinned by dedicated anchor
  // below.
  // RepaintDetector lifted out of the v0.17.4 reproducerOnly batch:
  // base stays reproducerOnly but the `excessive_repaint.warning`
  // family is raised to runtimeVerified via perStableIdTier on top of
  // an iPhone 12 / iOS 17.5 / Flutter 3.41.4 capture triad. The
  // remaining families (`excessive_repaint_debug`,
  // `repaint_debug_<typeName>`) stay reproducerOnly. See the dedicated
  // `RepaintDetector pinned at runtimeVerified for excessive_repaint`
  // anchor block below for the per-family-tier + bracket-field
  // invariants.
};

/// Detectors anchored by NetworkMonitor + FrameTiming single-detector
/// anchors (not batch blocks). These are enumerated explicitly because
/// the v0.16.5 / v0.16.6 anchor tests assert against the detector's
/// `validationMetadata` directly rather than a shared expectations map.
/// Allowlist of runtimeVerified+ brackets whose declared
/// `observedAxisArgKey` is dormant pending capture re-record. Each
/// entry forces the audit to skip the per-record cross-check fidelity
/// invariant for the named bracket; the `consumeBy` deadline forces
/// re-record (or explicit allowlist extension) by the named release.
///
/// Entries here are debt — review the `LegacyObservedAxisEntry`
/// rationale before adding or extending.
const legacyObservedAxisAllowlist = <String, LegacyObservedAxisEntry>{};

const _singleDetectorAnchors = <DetectorType>{
  DetectorType.networkMonitor,
  DetectorType.frameTiming,
  DetectorType.heavyCompute,
  DetectorType.memoryPressure,
  DetectorType.platformChannel,
  DetectorType.rebuild,
  DetectorType.repaint,
  DetectorType.streamResource,
  DetectorType.trackedResource,
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

    // CI audit gate for runtimeVerified `profileCapturePaths`. The
    // `checkBracketValidation(... requireTraceRecord: true)` invocation
    // inside the runtimeVerified / externallyCited branches below IS
    // the gate the v0.18.0 hardening commitment relies on. Every PR
    // that touches a runtimeVerified detector's metadata or its
    // capture artefacts re-runs `validateBracket` against the captures
    // on disk, so tree-state vs claim drift fails CI before merge.
    //
    // Removing or weakening these `checkBracketValidation` calls
    // defeats v0.18.0+ runtimeVerified evidence guarantees. See the
    // accompanying "audit gate is wired for every runtimeVerified
    // detector" regression-guard test below for the structural pin.
    test('tier-appropriate fields are populated', () {
      final failures = <String>[];
      for (final d in controller.detectorsForAudit) {
        if (d is! DetectorMetadataProvider) continue;
        final meta = (d as DetectorMetadataProvider).validationMetadata;
        final label = '${d.runtimeType} (tier=${meta.tier.name})';

        // Audit walks effective max tier so a detector with a per-family
        // raise (e.g. base reproducerOnly + perStableIdTier{id:
        // runtimeVerified}) still satisfies the runtimeVerified field
        // requirements. When perStableIdTier is null, this collapses to
        // meta.tier.
        switch (meta.effectiveMaxTier) {
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
            failures.addAll(runRuntimeTierAudit(
              label: label,
              meta: meta,
              legacyObservedAxisAllowlist:
                  legacyObservedAxisAllowlist.keys.toSet(),
            ));
            break;
          case EvidenceTier.externallyCited:
            failures.addAll(
                checkCitationUrl(label, meta.citationUrl, required: true));
            if (meta.reproducerPath == null ||
                meta.reproducerPath!.trim().isEmpty) {
              failures.add('$label: missing reproducerPath');
            }
            failures.addAll(runRuntimeTierAudit(
              label: label,
              meta: meta,
              legacyObservedAxisAllowlist:
                  legacyObservedAxisAllowlist.keys.toSet(),
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

        // Any effective tier stronger than `unvalidated` must pin the set
        // of stable IDs its evidence covers. `coveredStableIds` and
        // `parametricFamilies` are peer namespaces — at least one must be
        // non-empty, entries are trim/empty validated, and overlap
        // between the two is rejected so a single literal can't discharge
        // two obligations. Gate uses `effectiveMaxTier` (not base `tier`)
        // so a base-`unvalidated` detector that raises one family via
        // `perStableIdTier` still has to declare its stable IDs — closes
        // the audit-bypass where perStableIdTier could mint runtimeVerified
        // evidence on an otherwise-unvalidated detector with no covered
        // family declarations.
        final covered = meta.coveredStableIds;
        final parametric = meta.parametricFamilies;
        if (meta.effectiveMaxTier != EvidenceTier.unvalidated) {
          final hasCovered = covered != null && covered.isNotEmpty;
          final hasParametric = parametric != null && parametric.isNotEmpty;
          if (!hasCovered && !hasParametric) {
            failures.add('$label: missing coveredStableIds AND '
                'parametricFamilies — effective tier > unvalidated must '
                'declare at least one non-empty namespace of stable IDs '
                'the evidence covers (exact / `<family>:<param>` in '
                'coveredStableIds, or `<family>_<typeName>` prefix in '
                'parametricFamilies)');
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

        // perStableIdTier — per-family raise overrides. Runs
        // independently of the base-tier guard above so a detector at
        // base `unvalidated` cannot use perStableIdTier to bypass
        // field-presence validation. The accompanying `effectiveMaxTier`
        // switch routes to the raised tier's branch and runs the
        // bracket / capture-path checks; this block enforces the
        // per-family raise contract itself via checkPerStableIdTier.
        failures.addAll(checkPerStableIdTier(
          label: label,
          tier: meta.tier,
          perStableIdTier: meta.perStableIdTier,
          coveredStableIds: meta.coveredStableIds,
          bracketStableId: meta.bracketStableId,
          additionalBrackets: meta.additionalBrackets,
          topLevelCoveredThresholds: meta.coveredThresholds,
        ));
        failures.addAll(checkCanonicalCoveredThresholdBacking(
          label: label,
          tier: meta.effectiveMaxTier,
          topLevelStableId: meta.bracketStableId,
          topLevelSeverityLabel: meta.bracketSeverityLabel,
          topLevelCoveredThresholds: meta.coveredThresholds,
          additionalBrackets: meta.additionalBrackets,
        ));
        failures.addAll(checkRuntimeVerifiedRequiresObservedAxisArgKey(
          label: label,
          tier: meta.effectiveMaxTier,
          topLevelStableId: meta.bracketStableId,
          topLevelObservedAxisArgKey: meta.observedAxisArgKey,
          additionalBrackets: meta.additionalBrackets,
        ));
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

    test(
        'NetworkMonitorDetector pinned at reproducerOnly base + '
        'slow_request tier-stack (warning + critical) raise', () {
      // Anti-tautology anchor. NetworkMonitor base tier stays
      // `reproducerOnly` so the two unraised families
      // (http_error_spike, high_frequency_same_path) are not
      // mechanically over-claimed. Per-family raises live in
      // `perStableIdTier` and `additionalBrackets`:
      //
      //  - slow_request: warning (canonical bracket, 1000 ms) + critical
      //    (additionalBrackets[2], 3000 ms) — first NetworkMonitor
      //    tier-stack raise. Both brackets carry
      //    `observedAxisArgKey: 'observedDurationMs'` so the audit gate
      //    cross-checks operator-Stopwatch observed against detector-
      //    measured worstMs. Cross-spec uniqueness tuple
      //    (stableId, severityLabel, argKey) distinguishes the pair via
      //    severityLabel even though they share argKey.
      //  - large_response.warning: bytes axis (additionalBrackets[0]).
      //  - request_frequency.warning: events-per-window axis
      //    (additionalBrackets[1]).
      final BaseDetector? nm = controller.detectorsForAudit
          .where((d) => d.type == DetectorType.networkMonitor)
          .cast<BaseDetector?>()
          .firstWhere((_) => true, orElse: () => null);
      expect(nm, isNotNull,
          reason: 'NetworkMonitorDetector should be registered by default.');
      expect(nm, isA<DetectorMetadataProvider>());
      final meta = (nm as DetectorMetadataProvider).validationMetadata;
      expect(meta.tier, EvidenceTier.reproducerOnly,
          reason: 'Base tier stays reproducerOnly. The 3 raised families '
              'live in perStableIdTier so the two still-unraised families '
              '(http_error_spike, high_frequency_same_path) are not '
              'mechanically over-claimed at runtimeVerified.');
      expect(
          meta.perStableIdTier?['slow_request'], EvidenceTier.runtimeVerified,
          reason: 'v0.18.0 slow_request raise; canonical bracket axis.');
      expect(
          meta.perStableIdTier?['large_response'], EvidenceTier.runtimeVerified,
          reason: 'v0.19.9 raises large_response warning via on-device '
              'captures on the bytes axis; backed by additionalBrackets[0].');
      expect(meta.perStableIdTier?['request_frequency'],
          EvidenceTier.runtimeVerified,
          reason: 'v0.19.9 raises request_frequency warning via on-device '
              'captures on the events-per-window axis; backed by '
              'additionalBrackets[1].');
      expect(
          meta.effectiveTierFor('slow_request'), EvidenceTier.runtimeVerified,
          reason: 'Effective tier per family must surface runtimeVerified '
              'for slow_request; the audit gate routes off effectiveMaxTier '
              'so the bracket fields still trigger their checks.');
      expect(meta.effectiveTierFor('large_response'),
          EvidenceTier.runtimeVerified);
      expect(meta.effectiveTierFor('request_frequency'),
          EvidenceTier.runtimeVerified);
      expect(meta.effectiveTierFor('http_error_spike'),
          EvidenceTier.reproducerOnly,
          reason: 'http_error_spike stays at base reproducerOnly; not '
              'covered by any BracketSpec.');
      expect(meta.effectiveTierFor('high_frequency_same_path'),
          EvidenceTier.reproducerOnly,
          reason: 'high_frequency_same_path stays at base reproducerOnly; '
              'not covered by any BracketSpec.');
      expect(meta.effectiveMaxTier, EvidenceTier.runtimeVerified,
          reason: 'effectiveMaxTier drives the audit switch; must remain '
              'runtimeVerified after the v0.18.3 base-tier drop so '
              'profileCapturePaths/bracketThreshold continue to be enforced.');
      expect(meta.reproducerPath,
          equals('test/validation/network_monitor_reproducer_test.dart'));
      expect(meta.citationUrl, isNull,
          reason: 'runtimeVerified does not require an external citation; '
              'evidence is the captured detector behaviour itself.');
      expect(
          meta.profileCapturePaths,
          equals(const [
            'test/validation/captures/network_monitor/slow_request_below.json',
            'test/validation/captures/network_monitor/slow_request_at.json',
            'test/validation/captures/network_monitor/slow_request_above.json',
          ]),
          reason: 'Three on-device captures back the runtimeVerified raise.');
      expect(meta.bracketThreshold, equals(1000));
      expect(meta.bracketUnit, equals('ms'));
      expect(meta.bracketStableId, equals('slow_request'));
      expect(meta.bracketSeverityLabel, equals('warning'));
      expect(
          meta.coveredThresholds,
          equals(const {
            'slow_request.warning',
            'slow_request.critical',
          }),
          reason: 'Severity-scoped: warning covered by canonical bracket, '
              'critical covered by additionalBrackets[2]. Tier-stack raise '
              'expands coveredThresholds union to both severities.');
      expect(meta.aboveCeilingMultiplier, equals(2.0),
          reason: 'Canonical bracket above-band (1000, 2000] sits well below '
              'the 3000 ms critical threshold so it cannot ambiently bracket '
              'the critical tier; explicit declaration required by the '
              'severity-scoped-coveredThresholds invariant.');
      expect(meta.observedAxisArgKey, equals('observedDurationMs'),
          reason: 'Detector stamps worstMs into `extraTraceArgs` so the audit '
              'gate cross-checks operator-Stopwatch observed against '
              'detector-side measurement on the canonical bracket.');
      expect(meta.parametricFamilies, isNull,
          reason: 'NetworkMonitor does not declare parametric families.');
      expect(
          meta.coveredStableIds,
          equals(const {
            'slow_request',
            'large_response',
            'request_frequency',
            'http_error_spike',
            'high_frequency_same_path',
          }),
          reason: 'v0.18.3: coveredStableIds expanded to all five emitted '
              'families since the base tier (reproducerOnly) honestly '
              'covers them via the layer-2 reproducer. perStableIdTier '
              'raises only slow_request to runtimeVerified.');

      // Critical-tier bracket evidence is now captured in
      // additionalBrackets[2] (slow_request critical at threshold 3000).
      // The earlier negative-claim guard against piggyback critical
      // mentions is retired alongside the legitimate critical bracket
      // backed by its own capture triad below.

      // AB4 default-drift cross-check: when `bracketThreshold`
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
      // additionalBrackets pin. Three BracketSpec entries cover the
      // bytes axis (large_response.warning at index 0), the
      // events-per-window axis (request_frequency.warning at index 1),
      // and the slow_request critical-tier raise (index 2). Each spec's
      // coveredThresholds, threshold, unit, and provenance fields are
      // pinned literally so a future diff that drops or rewires a spec
      // must update this anchor.
      expect(meta.additionalBrackets, isNotNull);
      expect(meta.additionalBrackets, hasLength(3),
          reason: 'Three additional brackets: large_response[0], '
              'request_frequency[1], slow_request critical-tier[2]. '
              'http_error_spike and high_frequency_same_path stay at '
              'base reproducerOnly until they have their own captures.');

      final largeSpec = meta.additionalBrackets!
          .firstWhere((s) => s.stableId == 'large_response');
      expect(largeSpec.severityLabel, equals('warning'));
      expect(largeSpec.threshold, equals(1048576),
          reason: '1 MiB warning threshold tracks NetworkMonitorDetector\'s '
              'largeResponseBytes default.');
      expect(largeSpec.unit, equals('bytes'));
      expect(
          largeSpec.coveredThresholds, equals(const {'large_response.warning'}),
          reason: 'Severity-scoped to warning; critical stays '
              'reproducerOnly.');
      expect(
          largeSpec.profileCapturePaths,
          equals(const [
            'test/validation/captures/network_monitor/large_response_below.json',
            'test/validation/captures/network_monitor/large_response_at.json',
            'test/validation/captures/network_monitor/large_response_above.json',
          ]));
      expect(largeSpec.atTolerance, equals(0.10),
          reason: 'Bytes axis is deterministic on loopback HTTP; default '
              '±10% band is reachable.');
      expect(largeSpec.aboveCeilingMultiplier, equals(2.0),
          reason: 'Above-band ceiling 2 MiB is well below the 5 MiB '
              'critical threshold.');
      expect(largeSpec.observedAxisArgKey, equals('observedResponseBytes'));
      expect(largeSpec.requireUniqueDetectedAtMicros, isTrue);
      expect(largeSpec.requireDetectorTraceRecord, isTrue,
          reason: 'BracketSpec defaults requireDetectorTraceRecord to true; '
              'audit gate enforces presence of detector trace record per '
              'spec.');

      final freqSpec = meta.additionalBrackets!
          .firstWhere((s) => s.stableId == 'request_frequency');
      expect(freqSpec.severityLabel, equals('warning'));
      expect(freqSpec.threshold, equals(30),
          reason: 'NetworkMonitorDetector frequency warning threshold is '
              '30 requests per 5s sliding window; raise pins the same '
              'value to prevent silent drift.');
      expect(freqSpec.unit, equals('events'));
      expect(freqSpec.coveredThresholds,
          equals(const {'request_frequency.warning'}),
          reason: 'Severity-scoped to warning; 50/window critical stays '
              'reproducerOnly.');
      expect(
          freqSpec.profileCapturePaths,
          equals(const [
            'test/validation/captures/network_monitor/request_frequency_below.json',
            'test/validation/captures/network_monitor/request_frequency_at.json',
            'test/validation/captures/network_monitor/request_frequency_above.json',
          ]));
      expect(freqSpec.atTolerance, equals(0.50),
          reason: 'iOS scheduling jitter widens the band; mirrors '
              'PlatformChannel frequency axis (v0.19.4).');
      expect(freqSpec.aboveCeilingMultiplier, equals(2.0),
          reason: 'Above-band ceiling 60 for the warning tier. '
              'NetworkMonitorDetector emits request_frequency at warning '
              'severity only — there is no critical emission today. The '
              'schema filters trace records by event-name match '
              '(`sleuth.issue.<stableId>.<severity>`) so a future '
              'detector update that adds critical-severity emission '
              'would correctly scope warning-only events into this '
              'bracket without metadata change.');
      expect(freqSpec.observedAxisArgKey, equals('observedRequestCount'));
      expect(freqSpec.requireUniqueDetectedAtMicros, isTrue);
      expect(freqSpec.requireDetectorTraceRecord, isTrue);

      final criticalSpec = meta.additionalBrackets!.firstWhere(
        (s) => s.stableId == 'slow_request' && s.severityLabel == 'critical',
      );
      expect(criticalSpec.threshold, equals(3000),
          reason: '3× warning threshold; matches NetworkMonitorDetector\'s '
              'criticalSlowThresholdMs default.');
      expect(criticalSpec.unit, equals('ms'));
      expect(criticalSpec.coveredThresholds,
          equals(const {'slow_request.critical'}),
          reason: 'Severity-scoped to critical only.');
      expect(
          criticalSpec.profileCapturePaths,
          equals(const [
            'test/validation/captures/network_monitor/slow_request_critical_below.json',
            'test/validation/captures/network_monitor/slow_request_critical_at.json',
            'test/validation/captures/network_monitor/slow_request_critical_above.json',
          ]),
          reason: 'Critical capture triad lives at distinct file paths so '
              'capture-path disjointness check passes against the warning '
              'triad.');
      expect(criticalSpec.atTolerance, equals(0.40),
          reason: 'Wider than warning\'s 0.10 because the operator targets '
              '3000+ ms on a stub HTTP server with iOS scheduler + network '
              'RTT variance; ±15% drift on at-target=3600 lands [3060, 4140] '
              '— both edges in band [3000, 4200]. Tighter than HeavyCompute\'s '
              '0.60 critical because network-bound work is more deterministic '
              'than CPU-bound thermal drift. Forward-compat re-record '
              'headroom, NOT a device-physics claim.');
      expect(criticalSpec.aboveCeilingMultiplier, equals(2.0),
          reason: 'Above-ceiling 6000 ms; no super-critical tier above so '
              'the above-leg has no adjacent threshold to ambient-bracket. '
              'iOS NSURLSession 60 s default leaves comfortable margin.');
      expect(criticalSpec.observedAxisArgKey, equals('observedDurationMs'),
          reason: 'Same arg key as canonical warning bracket; cross-spec '
              'uniqueness tuple (stableId, severityLabel, argKey) '
              'distinguishes the pair via severityLabel.');
      expect(criticalSpec.requireUniqueDetectedAtMicros, isTrue);
      expect(criticalSpec.requireDetectorTraceRecord, isTrue);

      // Cross-spec uniqueness: (stableId, severityLabel, argKey) tuples
      // must not collide. `checkAdditionalBrackets` enforces this in the
      // walker; the anchor pins it explicitly so a future diff that
      // shares all three across specs is caught here too. The
      // slow_request warning + critical pair shares stableId AND argKey
      // — distinguished only by severityLabel — and must remain disjoint
      // under the 3-tuple.
      final tuples = <String>{};
      // Top-level (canonical) bracket counts as logical spec #0.
      tuples.add(
        '${meta.bracketStableId}|${meta.bracketSeverityLabel}'
        '|${meta.observedAxisArgKey ?? ''}',
      );
      for (final spec in meta.additionalBrackets!) {
        tuples.add(
          '${spec.stableId}|${spec.severityLabel}'
          '|${spec.observedAxisArgKey ?? ''}',
        );
      }
      expect(tuples, hasLength(4),
          reason: '4 distinct (stableId, severityLabel, argKey) tuples '
              'across canonical + 3 additionalBrackets.');
    });

    test(
        'HeavyComputeDetector pinned at runtimeVerified for warning + '
        'critical (v0.19.13 tier-stack raise)', () {
      // Anti-tautology anchor for the tier-stack raise. HeavyCompute
      // brackets both the 8 ms warning threshold (canonical bracket) and
      // the 16 ms critical threshold (additionalBrackets[0]). Six
      // on-device captures (iPhone 12 / iOS 17.5 / Flutter 3.41.x) under
      // producer-side dedup with stable per-BUILD `detectedAt` from
      // `event.timestampUs`.
      //
      // Both brackets declare `observedAxisArgKey: 'observedDurationMs'`
      // and the detector stamps BUILD ms into `extraTraceArgs` so the
      // audit cross-checks operator-Stopwatch observed against detector-
      // measured value. Cross-spec uniqueness key
      // `(stableId, severityLabel, argKey)` distinguishes the warning +
      // critical pair via severityLabel even though they share one
      // argKey — trace event names `sleuth.issue.<id>.<severity>`
      // differ by severity so no double-counting occurs.
      final BaseDetector? hc = controller.detectorsForAudit
          .where((d) => d.type == DetectorType.heavyCompute)
          .cast<BaseDetector?>()
          .firstWhere((_) => true, orElse: () => null);
      expect(hc, isNotNull,
          reason: 'HeavyComputeDetector should be registered by default.');
      expect(hc, isA<DetectorMetadataProvider>());
      final meta = (hc as DetectorMetadataProvider).validationMetadata;

      // Pin 1: base tier remains runtimeVerified (single-stableId
      // detector — both severity tiers ship at the same evidence level).
      expect(meta.tier, EvidenceTier.runtimeVerified,
          reason: 'Single-stableId detector with both severities '
              'runtimeVerified-backed; base tier carries it directly.');

      // Pin 2: reproducer path unchanged.
      expect(meta.reproducerPath,
          equals('test/validation/heavy_compute_reproducer_test.dart'));
      expect(meta.citationUrl, isNull,
          reason: 'runtimeVerified does not require an external citation; '
              'evidence is the captured detector behaviour itself.');

      // Pin 3: canonical bracket capture triad (warning tier, 8 ms).
      expect(
          meta.profileCapturePaths,
          equals(const [
            'test/validation/captures/heavy_compute/heavy_compute_below.json',
            'test/validation/captures/heavy_compute/heavy_compute_at.json',
            'test/validation/captures/heavy_compute/heavy_compute_above.json',
          ]),
          reason: 'Canonical bracket triad backs the warning tier (8 ms).');
      expect(meta.bracketThreshold, equals(8));
      expect(meta.bracketUnit, equals('ms'));
      expect(meta.bracketStableId, equals('heavy_compute'));
      expect(meta.bracketSeverityLabel, equals('warning'));
      expect(meta.bracketAtTolerance, equals(0.50),
          reason: 'iPhone CPU/thermal variance makes the default ±10% band '
              'unreachable; ±50% gives at-band [8, 12] ms.');
      expect(meta.aboveCeilingMultiplier, equals(1.875),
          reason: 'Above-ceiling 15 ms (1.875 × 8) clears the 16 ms '
              'critical threshold so above-leg cannot ambiently bracket '
              'critical.');

      // Pin 4: severity-scoped coverage union — both warning + critical
      // are explicitly covered; any future add must expand this set.
      expect(
          meta.coveredThresholds,
          equals(const {
            'heavy_compute.warning',
            'heavy_compute.critical',
          }),
          reason: 'Both severity tiers covered: warning by canonical '
              'bracket (v0.18.2) + critical by additionalBrackets[0] '
              '(v0.19.13). perStableIdTier coverage check requires '
              'every runtimeVerified family appear in either canonical '
              'or additional coveredThresholds.');

      // Pin 5: producer-dedup uniqueness opt-in on canonical bracket.
      expect(meta.bracketRequireUniqueDetectedAtMicros, isTrue,
          reason: 'Captures recorded under v0.18.1+ producer dedup with '
              'stable per-BUILD detectedAt; opt into the strong invariant '
              'so audit gate rejects single-issue replay forgery.');

      // Pin 6: observedAxisArgKey on canonical bracket. HeavyCompute
      // stamps BUILD ms via extraTraceArgs so the audit gate cross-checks
      // operator-Stopwatch observed against detector-side measurement.
      // Closes the certify-wrong-magnitude gap that magnitudeSourceEventName=''
      // would otherwise leave open. Cross-spec uniqueness tuple
      // (stableId, severityLabel, argKey) distinguishes warning + critical
      // by severityLabel even though both share the same argKey.
      expect(meta.observedAxisArgKey, equals('observedDurationMs'),
          reason: 'HeavyCompute stamps BUILD `ms` into `extraTraceArgs` '
              'as `observedDurationMs`; the schema cross-checks this '
              'against `expectedMagnitude.observed` so a detector-side '
              'duration miscompute cannot certify the wrong magnitude.');

      // Pin 7: additionalBrackets non-null with exactly one entry.
      expect(meta.additionalBrackets, isNotNull,
          reason: 'v0.19.13 raises critical tier via additionalBrackets[0]. '
              'A null here would mean the critical bracket is not declared '
              'and the perStableIdTier coverage check would reject the '
              'critical entry in coveredThresholds.');
      expect(meta.additionalBrackets, hasLength(1),
          reason: 'Exactly one additional bracket: critical tier. Future '
              'multi-axis raises on the same family would extend this.');

      final critical = meta.additionalBrackets!.single;

      // Pin 8: critical bracket identifies the right (stableId, severity).
      expect(critical.stableId, equals('heavy_compute'));
      expect(critical.severityLabel, equals('critical'));

      // Pin 9: critical bracket threshold + unit pin the 16 ms boundary.
      expect(critical.threshold, equals(16),
          reason: '2× warning threshold; matches the strict-greater '
              'critical fire condition in `_createIssue`.');
      expect(critical.unit, equals('ms'));

      // Pin 10: critical bracket capture triad lives in critical-named
      // files, distinct from canonical warning triad.
      expect(
          critical.profileCapturePaths,
          equals(const [
            'test/validation/captures/heavy_compute/heavy_compute_critical_below.json',
            'test/validation/captures/heavy_compute/heavy_compute_critical_at.json',
            'test/validation/captures/heavy_compute/heavy_compute_critical_above.json',
          ]),
          reason: 'Distinct triad files — capture-path disjointness check '
              'enforces independence between canonical and additional '
              'brackets.');

      // Pin 11: critical bracket band tolerances. atTolerance widened
      // beyond the warning bracket's 0.50 because higher-magnitude
      // compute on iPhone 12 exhibits a wider thermal/JIT drift
      // envelope than the warning band — recordings landed +30 % above
      // the calibration-derived target. 0.60 → at-band [16, 25.6].
      // above-ceiling 30 ms (no super-critical tier above).
      expect(critical.atTolerance, equals(0.60),
          reason: 'Wider iPhone variance budget than warning tier (0.60 vs '
              '0.50) because higher-magnitude compute drifts further past '
              'calibration; ±60% gives at-band [16, 25.6] ms.');
      expect(critical.aboveCeilingMultiplier, equals(1.875),
          reason: 'Above-ceiling 30 ms (1.875 × 16). No super-critical '
              'tier above so the above-leg has no adjacent threshold to '
              'ambient-bracket; the multiplier mirrors the warning '
              'bracket for symmetry.');

      // Pin 12: critical bracket coveredThresholds is severity-scoped to
      // critical only — declares what `perStableIdTier` coverage proof
      // this spec contributes.
      expect(
          critical.coveredThresholds, equals(const {'heavy_compute.critical'}),
          reason: 'Severity-scoped coverage. The audit gate matches this '
              'against any perStableIdTier raise on heavy_compute.critical '
              '(here: implicit via base-tier runtimeVerified + canonical '
              'coveredThresholds union including .critical).');

      // Pin 13: critical bracket schema strictness. observedAxisArgKey
      // matches canonical bracket; cross-spec tuple (stableId, severity,
      // argKey) makes warning + critical disjoint via severityLabel.
      // requireUniqueDetectedAtMicros true (v0.18.1+ dedup);
      // requireDetectorTraceRecord true (default for BracketSpec — proves
      // detector actually fired at .critical).
      expect(critical.observedAxisArgKey, equals('observedDurationMs'),
          reason: 'Same arg key as canonical warning bracket; severityLabel '
              'disambiguates the cross-spec uniqueness tuple. Audit cross-'
              'checks operator-Stopwatch observed against detector-stamped '
              '`observedDurationMs` for both warning + critical brackets.');
      expect(critical.requireUniqueDetectedAtMicros, isTrue,
          reason: 'Captures recorded under v0.18.1+ producer dedup; opt '
              'into the strong replay-forgery rejection on critical too.');
      expect(critical.requireDetectorTraceRecord, isTrue,
          reason: 'BracketSpec default; proves detector actually emitted '
              '.critical inside the scenario span. Without this the at + '
              'above captures could pass without an actual critical fire.');
    });

    test(
        'MemoryPressureDetector pinned at runtimeVerified for heap_growing '
        '(v0.19.3)', () {
      // Anti-tautology anchor: heap_growing raised from base reproducerOnly
      // to runtimeVerified via perStableIdTier (warning tier, 512 KB/s
      // sustained ≥10s) backed by three on-device captures (iPhone 12 /
      // iOS 17.5 / Flutter 3.41.x). Other 3 families (gc_pressure,
      // heap_near_capacity, native_memory_growing) stay at base
      // reproducerOnly — each requires a separate capture campaign with
      // multi-axis brackets the current single-bracket schema cannot
      // express.
      final BaseDetector? mp = controller.detectorsForAudit
          .where((d) => d.type == DetectorType.memoryPressure)
          .cast<BaseDetector?>()
          .firstWhere((_) => true, orElse: () => null);
      expect(mp, isNotNull,
          reason: 'MemoryPressureDetector should be registered by default.');
      expect(mp, isA<DetectorMetadataProvider>());
      final meta = (mp as DetectorMetadataProvider).validationMetadata;
      expect(meta.tier, EvidenceTier.reproducerOnly,
          reason: 'Base tier stays reproducerOnly — heap_growing raise '
              'lives in perStableIdTier so unraised families are not '
              'mechanically over-claimed at runtimeVerified.');
      expect(
          meta.perStableIdTier?['heap_growing'], EvidenceTier.runtimeVerified,
          reason: 'v0.19.3 raises heap_growing warning via on-device '
              'captures; the raise lives in perStableIdTier so the audit '
              'gate routes off effectiveMaxTier.');
      expect(
          meta.effectiveTierFor('heap_growing'), EvidenceTier.runtimeVerified);
      expect(meta.effectiveMaxTier, EvidenceTier.runtimeVerified,
          reason: 'effectiveMaxTier drives the audit switch; must surface '
              'runtimeVerified so profileCapturePaths/bracketThreshold '
              'continue to be enforced.');
      expect(meta.reproducerPath,
          equals('test/validation/memory_pressure_reproducer_test.dart'));
      expect(meta.citationUrl, isNull);
      expect(
          meta.profileCapturePaths,
          equals(const [
            'test/validation/captures/memory_pressure/heap_growing_below.json',
            'test/validation/captures/memory_pressure/heap_growing_at.json',
            'test/validation/captures/memory_pressure/heap_growing_above.json',
          ]),
          reason: 'Three on-device captures back the heap_growing raise.');
      expect(meta.bracketThreshold, equals(512000));
      expect(meta.bracketUnit, equals('bytes/sec'));
      expect(meta.bracketStableId, equals('heap_growing'));
      expect(meta.bracketSeverityLabel, equals('warning'));
      expect(meta.bracketAtTolerance, equals(0.50),
          reason: 'iPhone GC variance widens band; ±50% gives at-band '
              '[512000, 768000] bytes/sec.');
      expect(meta.aboveCeilingMultiplier, equals(2.0),
          reason: 'heap_growing has only a warning tier (no critical), so '
              'above-ceiling 2.0× threshold has no critical-tier collision '
              'risk; explicit declaration required by the severity-scoped-'
              'coveredThresholds invariant.');
      expect(meta.coveredThresholds, equals(const {'heap_growing.warning'}),
          reason: 'Severity-scoped to warning; the only severity '
              'heap_growing emits at.');
      expect(meta.bracketRequireUniqueDetectedAtMicros, isTrue,
          reason: 'Captures recorded with dedupIdentityMicros derived from '
              '_sustainedGrowthStart.microsecondsSinceEpoch; opt into the '
              'strong invariant so audit gate rejects sustained-window-'
              'break forgery (multiple trace records inside one scenario '
              'span with distinct identities).');
      expect(meta.observedAxisArgKey, equals('observedSlopeBytesPerSec'),
          reason: 'Canonical heap_growing bracket carries the observed-'
              'axis cross-check. Captures must stamp '
              'observedSlopeBytesPerSec on every in-span warning event; '
              'the schema rejects bracket triads without it once the '
              'detector is runtimeVerified.');
      // Pin the schema-default tolerance. The capture-screen post-
      // process step rewrites `expectedMagnitude.observed` to the
      // detector-stamped slope so the cross-check has near-zero
      // divergence by construction; anchor catches any future drift
      // away from the default that would re-introduce operator-vs-
      // detector slack.
      expect(meta.observedAxisTolerance, equals(0.25),
          reason: 'Schema default 0.25; capture screen makes operator '
              'value identical to detector slope so wider tolerance is '
              'unnecessary.');
      // Pinning the reduction DEFAULT — falls through from spec
      // (BracketSpec default 'max'). Anchor catches schema-default
      // drift; intentional if the contract ever changes.
      expect(meta.observedAxisReduction, equals('max'),
          reason: 'Default reduction; detector emits at most one issue per '
              'sustained-growth window, so MAX picks the single in-span '
              'sample.');
      expect(
          meta.coveredStableIds,
          equals(const {
            'gc_pressure',
            'heap_growing',
            'heap_near_capacity',
            'native_memory_growing',
          }),
          reason: 'All four emitted families covered by the layer-2 '
              'reproducer; perStableIdTier raises only heap_growing.');

      // Prose-drift guard. heap_growing currently emits ONLY warning
      // severity in the detector code (no critical branch). A future
      // PR that adds a critical-tier raise must include its own bracket
      // triad + capture campaign — not piggyback on the warning raise's
      // evidence. This guard rejects rationale prose claiming a
      // critical-tier raise without the corresponding metadata
      // (coveredThresholds entry).
      final stripped =
          meta.rationale.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
      final collapsed = stripped.replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
      final claimsHeapGrowingCritical =
          collapsed.contains('heap_growing.critical') ||
              collapsed.contains('heap_growing critical');
      expect(claimsHeapGrowingCritical, isFalse,
          reason: 'Rationale prose claims a heap_growing critical-tier '
              'raise. Critical cannot piggyback on the warning raise — '
              'add coveredThresholds entry + dedicated capture triad, or '
              'remove the prose claim.');
      final hasCriticalThresholdEntry =
          (meta.coveredThresholds ?? const <String>{})
              .contains('heap_growing.critical');
      expect(hasCriticalThresholdEntry, isFalse,
          reason: 'heap_growing.critical not yet a covered threshold; '
              'detector emits only warning severity. Adding this entry '
              'requires a critical-tier capture campaign + bracket triad.');
      expect(meta.additionalBrackets, isNull,
          reason: 'heap_growing brackets a single axis (slope bytes/sec); '
              'other 3 families (gc_pressure, heap_near_capacity, '
              'native_memory_growing) stay base reproducerOnly. Multi-axis '
              'raises across families would populate additionalBrackets.');
      expect(meta.perStableIdTier?['gc_pressure'], isNull,
          reason: 'gc_pressure stays at base reproducerOnly. Detector '
              'emission carries observedGcEvents + dedupIdentityMicros '
              'as preparatory plumbing (improves dedup quality of ambient '
              'gc_pressure noise in unrelated captures) but no '
              'runtimeVerified bracket evidence is committed.');
    });

    test(
        'RebuildDetector pinned at runtimeVerified for rebuild_activity '
        '(v0.19.12)', () {
      // Anti-tautology anchor: rebuild_activity raised from base
      // reproducerOnly to runtimeVerified via perStableIdTier (warning
      // tier, 11 BUILDs/sec under baseline-subtraction) backed by three
      // on-device captures (iPhone 12 / iOS 17.5 / Flutter 3.41.x).
      // Other family `stateful_density` stays at base reproducerOnly.
      // Captures use the detector's adjusted (raw - baseline) BUILD
      // count so iOS profile-mode framework ambient (~10–15/sec from
      // Material animations) does not inflate the magnitude.
      final BaseDetector? rb = controller.detectorsForAudit
          .where((d) => d.type == DetectorType.rebuild)
          .cast<BaseDetector?>()
          .firstWhere((_) => true, orElse: () => null);
      expect(rb, isNotNull,
          reason: 'RebuildDetector should be registered by default.');
      expect(rb, isA<DetectorMetadataProvider>());
      final meta = (rb as DetectorMetadataProvider).validationMetadata;
      expect(meta.tier, EvidenceTier.reproducerOnly,
          reason: 'Base tier stays reproducerOnly — rebuild_activity raise '
              'lives in perStableIdTier so stateful_density is not '
              'mechanically over-claimed at runtimeVerified.');
      expect(meta.perStableIdTier?['rebuild_activity'],
          EvidenceTier.runtimeVerified,
          reason: 'v0.19.12 raises rebuild_activity warning via on-device '
              'captures; the raise lives in perStableIdTier so the audit '
              'gate routes off effectiveMaxTier.');
      expect(meta.effectiveTierFor('rebuild_activity'),
          EvidenceTier.runtimeVerified);
      expect(meta.effectiveMaxTier, EvidenceTier.runtimeVerified);
      expect(meta.reproducerPath,
          equals('test/validation/rebuild_reproducer_test.dart'));
      expect(meta.citationUrl, isNull);
      expect(
          meta.profileCapturePaths,
          equals(const [
            'test/validation/captures/rebuild_detector/below.json',
            'test/validation/captures/rebuild_detector/at.json',
            'test/validation/captures/rebuild_detector/above.json',
          ]));
      expect(meta.bracketThreshold, equals(11),
          reason: 'Detector gate is `buildCount > 10` (default '
              'rebuildsPerSecThreshold); first integer firing is 11.');
      expect(meta.bracketUnit, equals('rebuilds'));
      expect(meta.bracketStableId, equals('rebuild_activity'));
      expect(meta.bracketSeverityLabel, equals('warning'));
      expect(meta.bracketAtTolerance, equals(0.65),
          reason: 'at-band [11, 18.15]; wider than v0.19.7 jank (0.50) '
              'because Material framework noise plus baseline-subtraction '
              'jitter widens variance even with `setBaseline` applied.');
      expect(meta.aboveCeilingMultiplier, equals(2.7),
          reason: 'above-band ceiling 11 × 2.7 = 29.7 strictly under the '
              '`> threshold * 3 = 30` critical-tier fire boundary so the '
              'above leg cannot ambiently bracket critical. The 2.7 '
              'multiplier (vs 2.5) gives re-record headroom: window '
              'variance on this metric is ±3-4 units, so a tighter '
              'ceiling rejects on day-to-day noise. 0.3 unit margin to '
              'critical is intentional.');
      expect(meta.observedAxisArgKey, equals('observedRebuildRate'),
          reason: 'Detector stamps `extraTraceArgs.observedRebuildRate` '
              '(the adjusted, baseline-subtracted value) on every '
              'rebuild_activity emission for the schema cross-check.');
      expect(meta.observedAxisReduction, equals('max'),
          reason: 'Multiple in-span emissions per leg (one per 1s window '
              'crossing threshold); max-reduction picks the worst signal '
              'rather than the tail-off final window.');
      expect(meta.bracketRequireUniqueDetectedAtMicros, isTrue);
      expect(
          meta.coveredThresholds,
          equals(
              const {'rebuild_activity.warning', 'rebuild_activity.critical'}),
          reason: 'Warning covered by canonical bracket; critical covered '
              'by additionalBrackets[0] (>30 BUILDs/sec) backed by a '
              'dedicated capture triad under critical_*.json.');
      expect(meta.coveredStableIds,
          equals(const {'stateful_density', 'rebuild_activity'}),
          reason: 'Both layer-2 reproducer-covered families; '
              'perStableIdTier raises only rebuild_activity.');
      expect(meta.parametricFamilies, equals(const {'rebuild_debug'}),
          reason: 'Parametric `rebuild_debug_<typeName>` family '
              'unchanged — debug-callback path stays at base '
              'reproducerOnly.');
      // Critical-tier bracket pin. additionalBrackets[0] adds the
      // tier-stack raise without disturbing the canonical warning bracket.
      expect(meta.additionalBrackets, isNotNull,
          reason: 'additionalBrackets carries the critical tier raise; '
              'a future PR removing it would silently drop critical '
              'from audit coverage.');
      // Look up by (stableId, severityLabel) so a future PR adding a
      // second additionalBrackets entry (e.g. a different stableId
      // raise) does not fail this anchor with a misleading length
      // mismatch — the field-literal assertions below would be the
      // real diagnostic surface.
      final critical = meta.additionalBrackets!.firstWhere(
        (b) =>
            b.stableId == 'rebuild_activity' && b.severityLabel == 'critical',
        orElse: () => throw StateError(
          'additionalBrackets must contain a (rebuild_activity, critical) '
          'spec; found severityLabels: '
          '${meta.additionalBrackets!.map((b) => "${b.stableId}.${b.severityLabel}").join(", ")}.',
        ),
      );
      expect(critical.stableId, equals('rebuild_activity'));
      expect(critical.severityLabel, equals('critical'));
      expect(critical.threshold, equals(31),
          reason: 'Detector gate is `adjusted > 30` (rebuildsPerSecThreshold '
              '* 3); first integer firing critical is 31.');
      expect(critical.unit, equals('rebuilds'));
      expect(critical.atTolerance, equals(0.65));
      expect(critical.aboveCeilingMultiplier, equals(2.7));
      expect(critical.observedAxisArgKey, equals('observedRebuildRate'));
      expect(critical.observedAxisReduction, equals('max'));
      expect(critical.requireUniqueDetectedAtMicros, isTrue);
      expect(critical.coveredThresholds,
          equals(const {'rebuild_activity.critical'}));
      expect(
          critical.profileCapturePaths,
          equals(const [
            'test/validation/captures/rebuild_detector/critical_below.json',
            'test/validation/captures/rebuild_detector/critical_at.json',
            'test/validation/captures/rebuild_detector/critical_above.json',
          ]));
      expect(critical.minInBandSamples, equals(2),
          reason: 'critical bracket requires >=2 in-band detector samples '
              'per leg (at + above). iPhone thermal throttling on a 6 s '
              'sustained leg routinely produces a mix of in-band + '
              'sub-band emissions; opting in turns the redundancy '
              'property of the committed capture into an enforced '
              'contract — a future re-record with only one in-band peak '
              'fails the audit gate instead of silently shipping fragile '
              'evidence.');
    });

    test(
        'RepaintDetector pinned at runtimeVerified for excessive_repaint '
        '(v0.21.0)', () {
      // Anti-tautology anchor: excessive_repaint raised from base
      // reproducerOnly to runtimeVerified via perStableIdTier (warning
      // tier, > 30 paints/sec aggregate over a 1 s VM window) backed
      // by three on-device captures (iPhone 12 / iOS 17.5 /
      // Flutter 3.41.4). Other families `excessive_repaint_debug` and
      // parametric `repaint_debug_<typeName>` stay at base
      // reproducerOnly. Captures use a 32-distinct-CustomPainter
      // workload so the per-widget debug gate stays sub-threshold and
      // emission flows through the VM aggregate path.
      final BaseDetector? rp = controller.detectorsForAudit
          .where((d) => d.type == DetectorType.repaint)
          .cast<BaseDetector?>()
          .firstWhere((_) => true, orElse: () => null);
      expect(rp, isNotNull,
          reason: 'RepaintDetector should be registered by default.');
      expect(rp, isA<DetectorMetadataProvider>());
      final meta = (rp as DetectorMetadataProvider).validationMetadata;
      expect(meta.tier, EvidenceTier.reproducerOnly,
          reason: 'Base tier stays reproducerOnly — excessive_repaint raise '
              'lives in perStableIdTier so the debug-path families are not '
              'mechanically over-claimed at runtimeVerified.');
      expect(meta.perStableIdTier?['excessive_repaint'],
          EvidenceTier.runtimeVerified,
          reason: 'v0.21.0 raises excessive_repaint warning via on-device '
              'captures; the raise lives in perStableIdTier so the audit '
              'gate routes off effectiveMaxTier.');
      expect(meta.effectiveTierFor('excessive_repaint'),
          EvidenceTier.runtimeVerified);
      expect(meta.effectiveMaxTier, EvidenceTier.runtimeVerified);
      expect(meta.reproducerPath,
          equals('test/validation/repaint_reproducer_test.dart'));
      expect(meta.citationUrl, isNull);
      expect(
          meta.profileCapturePaths,
          equals(const [
            'test/validation/captures/repaint/excessive_repaint_below.json',
            'test/validation/captures/repaint/excessive_repaint_at.json',
            'test/validation/captures/repaint/excessive_repaint_above.json',
          ]));
      expect(meta.bracketThreshold, equals(30),
          reason: 'Detector gate is `paintCount > paintFrequencyThreshold` '
              '(default 30); first integer firing is 31.');
      expect(meta.bracketUnit, equals('paints'));
      expect(meta.bracketStableId, equals('excessive_repaint'));
      expect(meta.bracketSeverityLabel, equals('warning'));
      expect(meta.bracketAtTolerance, equals(0.50),
          reason: 'at-band [30, 45]; matches the 0.50 atTolerance used by '
              'jank_detected and request_frequency. iOS 60Hz scheduler '
              'jitter on staggered Timer ticks across 32 widget types '
              'varies by ±10 paints/sec window-to-window — the band must '
              'be wide enough to absorb that variance without overlapping '
              'the above-band.');
      expect(meta.aboveCeilingMultiplier, equals(2.0),
          reason: 'above-band ceiling 30 × 2.0 = 60 strictly under the '
              '`> threshold * 2 = 60` critical-tier fire boundary; above '
              'leg targets warning emissions in (45, 60) so the audit '
              'sees pure warning evidence without ambient critical fire.');
      expect(meta.observedAxisArgKey, equals('observedPaintCount'),
          reason: 'Detector stamps `extraTraceArgs.observedPaintCount` (the '
              '1 s window aggregate count) on every excessive_repaint '
              'emission for the schema cross-check.');
      expect(meta.observedAxisReduction, equals('max'),
          reason: 'Multiple in-span emissions per leg (one per 1 s window '
              'crossing threshold); max-reduction picks the worst signal '
              'rather than the tail-off final window when widgets unmount.');
      expect(
          meta.coveredThresholds, equals(const {'excessive_repaint.warning'}),
          reason: 'Severity-scoped to warning only; critical (>60 paints/sec) '
              'stays implicitly reproducerOnly.');
      expect(meta.coveredStableIds,
          equals(const {'excessive_repaint', 'excessive_repaint_debug'}),
          reason: 'Both VM and debug-aggregate families exist on the '
              'detector; perStableIdTier raises only excessive_repaint.');
      expect(meta.parametricFamilies, equals(const {'repaint_debug'}),
          reason: 'Parametric `repaint_debug_<typeName>` family unchanged — '
              'debug per-widget path stays at base reproducerOnly.');
    });

    test(
        'StreamResourceDetector pinned at runtimeVerified for '
        'stream_resource_growth', () {
      // Base reproducerOnly + perStableIdTier raise on warning. Single-
      // family — perStableIdTier sits beside the canonical tier so the
      // audit walks `effectiveMaxTier` for bracket-field requirements.
      final BaseDetector? sr = controller.detectorsForAudit
          .where((d) => d.type == DetectorType.streamResource)
          .cast<BaseDetector?>()
          .firstWhere((_) => true, orElse: () => null);
      expect(sr, isNotNull);
      expect(sr, isA<DetectorMetadataProvider>());
      final meta = (sr as DetectorMetadataProvider).validationMetadata;
      expect(meta.tier, EvidenceTier.reproducerOnly);
      expect(meta.perStableIdTier?['stream_resource_growth'],
          EvidenceTier.runtimeVerified);
      expect(meta.effectiveTierFor('stream_resource_growth'),
          EvidenceTier.runtimeVerified);
      expect(meta.effectiveMaxTier, EvidenceTier.runtimeVerified);
      expect(meta.reproducerPath,
          equals('test/validation/stream_resource_reproducer_test.dart'));
      expect(meta.citationUrl, isNull);
      expect(
          meta.profileCapturePaths,
          equals(const [
            'test/validation/captures/stream_resource_growth/below.json',
            'test/validation/captures/stream_resource_growth/at.json',
            'test/validation/captures/stream_resource_growth/above.json',
          ]));
      expect(meta.bracketThreshold, equals(50));
      expect(meta.bracketUnit, equals('instances'));
      expect(meta.bracketStableId, equals('stream_resource_growth'));
      expect(meta.bracketSeverityLabel, equals('warning'));
      expect(meta.bracketAtTolerance, equals(0.6),
          reason: 'at-band [50, 80] absorbs in-scenario heap_growing '
              'readiness-wait variance without overlapping ceiling.');
      expect(meta.aboveCeilingMultiplier, equals(3.0),
          reason: 'ceiling 150; single-tier family bounds via schema '
              'sanity bound, not adjacent severity.');
      expect(meta.observedAxisArgKey, equals('topGrowthDelta'));
      expect(meta.coveredThresholds,
          equals(const {'stream_resource_growth.warning'}));
      expect(meta.coveredStableIds, equals(const {'stream_resource_growth'}));
      expect(meta.parametricFamilies, isNull);
      expect(meta.bracketRequireUniqueDetectedAtMicros, isTrue);
      expect(meta.additionalBrackets, isNull);
    });

    test('TrackedResourceDetector pinned at reproducerOnly', () {
      // Pure-Dart detector. Two stableIds (concurrent + long_lived);
      // confirmed confidence; no perStableIdTier raise. Reproducer
      // is hermetic via internal simulateFinalizerForTest seam — no
      // dependency on real Finalizer timing.
      final BaseDetector? tr = controller.detectorsForAudit
          .where((d) => d.type == DetectorType.trackedResource)
          .cast<BaseDetector?>()
          .firstWhere((_) => true, orElse: () => null);
      expect(tr, isNotNull);
      expect(tr, isA<DetectorMetadataProvider>());
      final meta = (tr as DetectorMetadataProvider).validationMetadata;
      expect(meta.tier, EvidenceTier.reproducerOnly);
      expect(meta.effectiveMaxTier, EvidenceTier.reproducerOnly);
      expect(meta.reproducerPath,
          equals('test/validation/tracked_resource_reproducer_test.dart'));
      expect(meta.citationUrl, isNull);
      expect(meta.profileCapturePaths, isNull);
      expect(meta.bracketThreshold, isNull);
      expect(meta.bracketUnit, isNull);
      expect(meta.bracketStableId, isNull);
      expect(meta.bracketSeverityLabel, isNull);
      expect(meta.bracketAtTolerance, isNull);
      expect(meta.aboveCeilingMultiplier, isNull);
      expect(meta.observedAxisArgKey, isNull);
      expect(meta.coveredThresholds, isNull);
      expect(
          meta.coveredStableIds,
          equals(const {
            'tracked_resource_concurrent',
            'tracked_resource_long_lived',
          }));
      expect(meta.parametricFamilies, isNull);
      expect(meta.perStableIdTier, isNull);
      expect(meta.additionalBrackets, isNull);
    });

    test('PlatformChannelDetector pinned at runtimeVerified (v0.19.4)', () {
      // Anti-tautology anchor for the v0.19.4 raise. PlatformChannel
      // moved from `reproducerOnly` to `runtimeVerified` (warning tier,
      // 20 calls/sec frequency axis) backed by three on-device captures
      // (iPhone 12 / iOS 17.5 / Flutter 3.41.x) recorded under v0.19.4
      // producer-side dedup with stable per-window dedupIdentityMicros
      // derived from `_windowStart.microsecondsSinceEpoch`. Critical
      // tier (41 calls/sec) AND the 8 ms cumulative-duration axis stay
      // implicitly reproducerOnly — neither has a checked-in capture
      // bracket. The above-band ceiling 1.95× → 39 calls/sec stays
      // strictly under the 41-call critical-escalation boundary so the
      // above-leg cannot ambiently bracket the critical tier.
      final BaseDetector? pc = controller.detectorsForAudit
          .where((d) => d.type == DetectorType.platformChannel)
          .cast<BaseDetector?>()
          .firstWhere((_) => true, orElse: () => null);
      expect(pc, isNotNull,
          reason: 'PlatformChannelDetector should be registered by default.');
      expect(pc, isA<DetectorMetadataProvider>());
      final meta = (pc as DetectorMetadataProvider).validationMetadata;
      expect(meta.tier, EvidenceTier.runtimeVerified,
          reason: 'v0.19.4 raises platform_channel_traffic warning to '
              'runtimeVerified with three on-device captures backing the '
              'frequency-axis bracket. debugProfilePlatformChannels=true '
              'per-leg routes real MethodChannel.invokeMethod calls '
              'through the parser-accepted lowercase async path.');
      expect(meta.reproducerPath,
          equals('test/validation/platform_channel_reproducer_test.dart'));
      expect(meta.citationUrl, isNull,
          reason: 'runtimeVerified does not require an external citation; '
              'evidence is the captured detector behaviour itself.');
      expect(
          meta.profileCapturePaths,
          equals(const [
            'test/validation/captures/platform_channel/'
                'platform_channel_traffic_below.json',
            'test/validation/captures/platform_channel/'
                'platform_channel_traffic_at.json',
            'test/validation/captures/platform_channel/'
                'platform_channel_traffic_above.json',
          ]),
          reason: 'Three on-device captures back the runtimeVerified raise.');
      expect(meta.bracketThreshold, equals(20));
      expect(meta.bracketUnit, equals('events'));
      expect(meta.bracketStableId, equals('platform_channel_traffic'));
      expect(meta.bracketSeverityLabel, equals('warning'));
      expect(meta.bracketAtTolerance, equals(0.50),
          reason: 'iOS scheduling jitter on platform-channel send path '
              'widens default ±10% band unreachable; ±50% gives at-band '
              '[20, 30] calls/sec.');
      expect(meta.aboveCeilingMultiplier, equals(1.95),
          reason: 'Above-ceiling 39 calls/sec (1.95 × 20) stays strictly '
              'under the 41-call (>20×2) critical-escalation boundary so '
              'above-leg cannot ambiently bracket the critical tier.');
      expect(meta.coveredThresholds,
          equals(const {'platform_channel_traffic.warning'}),
          reason: 'Severity-scoped to warning; critical (41 calls/sec) '
              'stays implicitly reproducerOnly.');
      expect(meta.coveredStableIds, equals(const {'platform_channel_traffic'}),
          reason: 'Single-family detector — only platform_channel_traffic.');
      expect(meta.bracketRequireUniqueDetectedAtMicros, isTrue,
          reason: 'Captures recorded with dedupIdentityMicros derived from '
              '_windowStart.microsecondsSinceEpoch; opt into the strong '
              'invariant so audit gate rejects single-issue replay '
              'forgery and multi-fire-window forgery.');

      // Prose-drift guards. Two implicit-tier axes must NOT be claimed
      // as bracketed by captures without backing metadata:
      //   (1) critical tier (41 calls/sec, 2× threshold).
      //   (2) duration axis (8 ms cumulative per 1 s window).
      // Either claim without metadata is the same anti-tautology trap
      // the heap_growing.critical guard catches.
      //
      // Positive structural assertion (not substring match):
      //   - If rationale claims captures bracket the critical tier OR
      //     the duration axis, `coveredThresholds` MUST contain the
      //     corresponding entry, OR `bracketUnit` must match the axis.
      //   - Substring-only guards miss plausible drift like
      //     "captures bracket the critical band" (no
      //     `platform_channel_traffic` qualifier). Positive check
      //     ensures any "captured-bracket" claim has matching metadata.
      final stripped =
          meta.rationale.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
      final collapsed = stripped.replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

      // Phrase fragments that indicate a CAPTURED-bracket claim
      // (vs. an explicit "reproducer-pinned" or "implicitly
      // reproducer-only" admission). When present together with the
      // axis name, escalate to positive metadata check.
      const capturedBracketPhrases = [
        'captures bracket the',
        'captures back the',
        'captured bracket',
        'on-device capture brackets the',
        'three captures back',
        'profile bracket',
        'is runtime-verified',
        'is runtime verified',
      ];

      bool mentions(List<String> phrases) => phrases.any(collapsed.contains);

      // Critical-tier guard (positive).
      final claimsCriticalCaptured = mentions(capturedBracketPhrases) &&
          (collapsed.contains('critical tier') ||
              collapsed.contains('critical band') ||
              collapsed.contains('critical threshold') ||
              collapsed.contains('41 calls/sec') ||
              collapsed.contains('2× threshold') ||
              collapsed.contains('platform_channel_traffic.critical'));
      final hasCriticalThresholdEntry =
          (meta.coveredThresholds ?? const <String>{})
              .contains('platform_channel_traffic.critical');
      if (claimsCriticalCaptured) {
        expect(hasCriticalThresholdEntry, isTrue,
            reason: 'Rationale claims captures bracket the critical tier '
                'but `coveredThresholds` does not include '
                '`platform_channel_traffic.critical`. Add the threshold '
                'entry + capture triad bracketing 41 calls/sec, or rewrite '
                'the prose to explicitly say the critical tier remains '
                'reproducer-pinned.');
      }
      // Independent of prose: critical-threshold metadata entry must
      // not appear unless a critical-tier capture campaign exists.
      // Currently no such captures → entry must remain absent.
      expect(hasCriticalThresholdEntry, isFalse,
          reason: 'platform_channel_traffic.critical not yet a covered '
              'threshold. Adding this entry requires a critical-tier '
              'capture campaign bracketing 41 calls/sec.');

      // Duration-axis guard (positive).
      final claimsDurationAxisCaptured = mentions(capturedBracketPhrases) &&
          (collapsed.contains('duration axis') ||
              collapsed.contains('cumulative duration') ||
              collapsed.contains('cumulative-duration') ||
              collapsed.contains('8 ms cumulative') ||
              collapsed.contains('8000 us') ||
              collapsed.contains('8000us') ||
              collapsed.contains('8000µs'));
      final bracketUnitIsDuration = const {
        'ms',
        'us',
        'µs',
        's',
        'ns',
      }.contains(meta.bracketUnit);
      if (claimsDurationAxisCaptured) {
        expect(bracketUnitIsDuration, isTrue,
            reason: 'Rationale claims captures bracket the duration axis '
                'but `bracketUnit` (${meta.bracketUnit}) is not a duration '
                'unit. Either record a duration-axis capture triad '
                '(unit: ms / us) and update bracket fields, or rewrite '
                'the prose to explicitly say the duration axis remains '
                'reproducer-pinned.');
      }
      expect(meta.additionalBrackets, isNull,
          reason: 'PlatformChannel currently brackets only the frequency '
              'axis (20 calls/sec). The 8 ms cumulative-duration axis stays '
              'implicitly reproducerOnly — a future raise of that axis '
              'would populate additionalBrackets with a second BracketSpec.');
    });

    test(
        'FrameTimingDetector pinned: base reproducerOnly + jank_detected '
        'runtimeVerified via perStableIdTier (v0.19.7); sustained_jank '
        'stays reproducerOnly (v0.19.17 raise withdrawn)', () {
      // Anti-tautology anchor. Base tier stays reproducerOnly — the
      // hermetic reproducer still backs raster_cache_thrashing /
      // raster_cache_growing and the non-bracketed evaluation paths
      // of jank_detected. One perStableIdTier raise: jank_detected.warning
      // (jankPercent gate) backed by three on-device captures.
      // sustained_jank stays at base reproducerOnly: the bracket axis
      // (sliding-window severeCount) is non-composable with operator-
      // claimed K under any current schema reduction.
      final BaseDetector? ft = controller.detectorsForAudit
          .where((d) => d.type == DetectorType.frameTiming)
          .cast<BaseDetector?>()
          .firstWhere((_) => true, orElse: () => null);
      expect(ft, isNotNull,
          reason: 'FrameTimingDetector should be registered by default.');
      expect(ft, isA<DetectorMetadataProvider>());
      final meta = (ft as DetectorMetadataProvider).validationMetadata;

      // Base tier stays reproducerOnly.
      expect(meta.tier, EvidenceTier.reproducerOnly,
          reason: 'v0.19.7 raises jank_detected via perStableIdTier; the '
              'base detector tier stays reproducerOnly so the other 3 '
              'stableIds and non-bracketed jank_detected paths remain '
              'reproducer-pinned.');
      expect(meta.reproducerPath,
          equals('test/validation/frame_timing_reproducer_test.dart'));
      expect(meta.citationUrl, isNull,
          reason: 'runtimeVerified does not require an external citation; '
              'evidence is the captured detector behaviour itself.');

      // perStableIdTier raise — single family (jank_detected only).
      expect(
          meta.perStableIdTier,
          equals(const {
            'jank_detected': EvidenceTier.runtimeVerified,
          }),
          reason: 'v0.19.7 raises jank_detected.warning. sustained_jank '
              'stays at base reproducerOnly: a v0.19.17 raise via '
              'additionalBrackets[0] was withdrawn before ship after the '
              'severeCount axis was found non-composable with operator-'
              'claimed K under any current schema reduction.');
      expect(
          meta.effectiveTierFor('jank_detected'), EvidenceTier.runtimeVerified,
          reason:
              'effectiveTierFor must reflect the perStableIdTier override.');
      expect(
          meta.effectiveTierFor('sustained_jank'), EvidenceTier.reproducerOnly,
          reason: 'sustained_jank stays at the detector\'s base tier.');

      // Three on-device captures.
      expect(
          meta.profileCapturePaths,
          equals(const [
            'test/validation/captures/frame_timing/jank_detected_below.json',
            'test/validation/captures/frame_timing/jank_detected_at.json',
            'test/validation/captures/frame_timing/jank_detected_above.json',
          ]),
          reason: 'Three on-device captures back the runtimeVerified raise '
              'on jank_detected.warning.');

      // Bracket axis — denominator-independent jankPercent.
      expect(meta.bracketStableId, equals('jank_detected'));
      expect(meta.bracketSeverityLabel, equals('warning'),
          reason: 'Trace-record check matches the bracket axis (jankPercent '
              'gate fires at warning severity); a sustained_jank.critical '
              'event must NOT satisfy the warning audit.');
      expect(meta.bracketThreshold, equals(16),
          reason: 'Detector rounds jankPercent to int + uses strict > 15. '
              'First reachable observed value is 16 — bracketThreshold=15 '
              'would accept a 15.x% capture the detector cannot emit.');
      expect(meta.bracketUnit, equals('percent'),
          reason: 'Denominator-independent axis — robust to buffer underfill '
              'on rate-based jank injection. AB-1 cross-check skips for '
              'non-time units; the percent axis is certified instead via '
              'observedAxisArgKey.');
      expect(meta.bracketAtTolerance, equals(0.50),
          reason: 'Wide ±50% band absorbs frame-delivery jitter. '
              'At-band [16, 24].');
      expect(meta.aboveCeilingMultiplier, equals(1.85),
          reason: 'Above-band (24, 29.6]; ceiling stays well under any '
              'critical co-fire boundary.');
      expect(
          meta.coveredThresholds,
          equals(const {
            'jank_detected.warning',
          }),
          reason: 'Single severity-scoped entry — canonical jank_detected '
              'warning. The v0.19.17 sustained_jank.critical raise was '
              'withdrawn; the entry was removed from coveredThresholds.');
      expect(meta.observedAxisArgKey, equals('observedJankPercent'),
          reason: 'Audit gate cross-checks operator-claimed magnitude '
              'against detector-emitted observedJankPercent within ±25%.');
      expect(meta.observedAxisTolerance, equals(0.25));
      expect(meta.observedAxisReduction, equals('last'),
          reason: 'jankPercent over a rolling buffer is non-monotone — '
              'early small-sample-size ratios spike high before settling. '
              'MAX picks early transient instead of operator-intended '
              'steady-state band; LAST picks terminal observation.');
      expect(meta.bracketRequireUniqueDetectedAtMicros, isTrue,
          reason: 'Captures recorded with `_emissionSeq` tie-broken '
              'dedupIdentityMicros; opt into the strong invariant so audit '
              'gate rejects single-issue replay forgery.');
      expect(meta.parametricFamilies, isNull,
          reason: 'FrameTiming does not declare parametric families.');

      // Coverage of the 4 stableIds is unchanged.
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

      // Constructor side-effect check.
      expect(() => FrameTimingDetector(), returnsNormally,
          reason: 'FrameTimingDetector() must be side-effect-free so the '
              'audit can construct it in isolation.');
      expect(() => FrameTimingDetector(captureMode: true), returnsNormally,
          reason: 'captureMode constructor surface must remain wired; the '
              'in-app capture screen depends on it short-circuiting warmup.');

      // No additionalBrackets — the v0.19.17 sustained_jank.critical
      // bracket was removed before ship.
      expect(meta.additionalBrackets, isNull,
          reason: 'v0.19.17 attempted a sustained_jank.critical raise via '
              'additionalBrackets[0]; the bracket was removed before ship '
              'because sliding-window severeCount cannot be cross-checked '
              'against operator-claimed K under any current schema '
              'reduction. Captures retained as reproducer-tier provisional '
              'evidence; bracket spec withdrawn.');
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

    test('v0.17.4+ reproducer-rewrite batch pinned at reproducerOnly', () {
      // Anti-tautology anchor for the 8-detector vmOnly + hybrid batch
      // originally raised in v0.17.2 and reproducer-rewritten in
      // v0.17.4–v0.17.6. Each entry pins the (type → reproducerPath →
      // coveredStableIds → parametricFamilies?) tuple. All 8 stay at
      // `reproducerOnly`; extended-claim fields (citationUrl,
      // profileCapturePaths, bracketThreshold, bracketUnit,
      // coveredThresholds, aboveCeilingMultiplier) MUST remain null.
      const expectations = _v0174Expectations;

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
          reason: 'v0.17.4+ reproducer-rewrite batch anchor drift: '
              '$failures');
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
        ..._v0174Expectations.keys,
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

    test('audit gate is wired for every runtimeVerified detector', () {
      // Regression guard for the v0.18.0 hardening commitment. If a
      // refactor of `tier-appropriate fields are populated` ever drops
      // the `checkBracketValidation(... requireTraceRecord: true)`
      // invocation from the runtimeVerified branch, this test fails so
      // the gap is caught at PR review instead of allowing a forged
      // `runtimeVerified` claim to slip through unverified.
      final runtimeVerifiedDetectors = <String>[];
      for (final d in controller.detectorsForAudit) {
        if (d is! DetectorMetadataProvider) continue;
        final meta = (d as DetectorMetadataProvider).validationMetadata;
        if (meta.tier != EvidenceTier.runtimeVerified) continue;
        runtimeVerifiedDetectors.add(d.runtimeType.toString());
        expect(meta.profileCapturePaths, isNotNull,
            reason: '${d.runtimeType}: runtimeVerified detector must declare '
                'profileCapturePaths so the CI audit gate can run '
                'validateBracket against the captures on disk.');
        expect(meta.profileCapturePaths!.length, 3,
            reason: '${d.runtimeType}: runtimeVerified evidence requires the '
                'below/at/above triad — the audit gate iterates all three '
                'and the trace-record check applies to the at + above legs.');
        expect(meta.bracketStableId, isNotNull,
            reason: '${d.runtimeType}: runtimeVerified detector must declare '
                'bracketStableId so the audit gate knows which '
                'sleuth.issue.<id>.<severity> trace record to require.');
        expect(meta.bracketSeverityLabel, isNotNull,
            reason: '${d.runtimeType}: runtimeVerified detector must declare '
                'bracketSeverityLabel — a `.critical` event does not '
                'satisfy a `warning`-tier audit and vice versa.');
        // Replay protection (v0.18.1+): runtimeVerified captures recorded
        // under producer-side dedup must opt into the strong uniqueness
        // invariant. Without this assertion a future tier raise could
        // ship runtimeVerified with replay protection silently OFF —
        // the audit gate would still accept N records sharing one
        // `detectedAtMicros`. Pin the opt-in here so the strongest new
        // hardening guarantee cannot regress unnoticed.
        expect(meta.bracketRequireUniqueDetectedAtMicros, isTrue,
            reason: '${d.runtimeType}: runtimeVerified detector must opt '
                'into bracketRequireUniqueDetectedAtMicros: true. The '
                'audit gate then rejects any capture whose in-span trace '
                'records are inflated (single-issue replay). v0.18.0 '
                'captures recorded before producer dedup landed must be '
                're-recorded under v0.18.1+ before opting in.');
      }
      // Sanity: the v0.18.x ledger has at least NetworkMonitor at this
      // tier. If this list is empty the regression guard is vacuous.
      expect(runtimeVerifiedDetectors, isNotEmpty,
          reason: 'No runtimeVerified detectors found. Either every '
              'detector regressed to a lower tier (real bug — investigate) '
              'or the audit walker is broken (delete this test if the '
              'tier was intentionally retired).');
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

    // When requireTraceRecord is true the gate must reject
    // runtimeVerified metadata that omits bracketStableId or
    // bracketSeverityLabel — without those, the schema cannot prove the
    // detector fired at the claimed severity.
    test(
        'checkBracketValidation with requireTraceRecord rejects '
        'missing bracketStableId / bracketSeverityLabel', () {
      final failures = checkBracketValidation(
        label: 'FakeDetector',
        tier: EvidenceTier.runtimeVerified,
        capturePaths: const [
          'test/validation/captures/_fixtures/dormant_bracket_below.json',
          'test/validation/captures/_fixtures/dormant_bracket_at.json',
          'test/validation/captures/_fixtures/dormant_bracket_above.json',
        ],
        bracketThreshold: 1000,
        bracketUnit: 'ms',
        // bracketStableId + bracketSeverityLabel intentionally omitted.
        requireTraceRecord: true,
      );
      expect(failures, isNotEmpty);
      expect(failures.any((f) => f.contains('bracketStableId')), isTrue);
      expect(failures.any((f) => f.contains('bracketSeverityLabel')), isTrue);
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
    //
    // v0.18.0 consumed the prior NetworkMonitor orphans
    // (slow_request_below.json / slow_request_at.json /
    // slow_request_above.json) when NetworkMonitorDetector flipped to
    // `runtimeVerified` for the slow_request warning tier. The three
    // captures are now referenced by `profileCapturePaths` and exit
    // the orphan manifest as a result.
    const retainedOrphans = <String, RetainedOrphanEntry>{};

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
          if (paths != null) {
            for (final pth in paths) {
              if (pth.trim().isEmpty) continue;
              referencedPaths.add(pth);
            }
          }
          // additionalBrackets capture paths must also be walked or the
          // first multi-axis raise lands triad files that the orphan
          // audit rejects as unreferenced. Iterates each spec; null /
          // empty handled implicitly.
          final extras = meta.additionalBrackets;
          if (extras != null) {
            for (final spec in extras) {
              for (final pth in spec.profileCapturePaths) {
                if (pth.trim().isEmpty) continue;
                referencedPaths.add(pth);
              }
            }
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

    test(
        'per-directory capture-name pattern is uniform '
        '(scenario ↔ basename relationship)', () {
      if (!File('pubspec.yaml').existsSync()) {
        markTestSkipped('CWD is not the package root; skipping.');
        return;
      }
      final failures = checkCapturePathPerDirectoryNamingUniformity(
        capturesRoot: Directory('test/validation/captures'),
      );
      expect(failures, isEmpty,
          reason: 'Mixed scenario-name patterns within a capture directory. '
              'Every file under captures/<dir> must use the same '
              'relationship between sleuthMetadata.scenario and the file '
              'basename (either scenario == basename, or scenario == '
              '"<dir>_<basename>"). Mixing patterns inside one directory '
              'is unmaintainable. Drift: $failures');
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
              'together if the multi-release was skipped. Failures: '
              '$failures');
    });

    test('legacy observed-axis allowlist manifest lifecycle', () {
      if (!File('pubspec.yaml').existsSync()) {
        markTestSkipped('CWD is not the package root; skipping.');
        return;
      }
      // Mirrors the retained-orphan lifecycle audit: parses pubspec
      // version, fails entries whose `consumeBy` has been reached or
      // passed. Forces re-record (or explicit allowlist extension)
      // by the named release.
      final pubspecText = File('pubspec.yaml').readAsStringSync();
      final versionMatch = RegExp(r'^version:\s*(\S+)\s*$', multiLine: true)
          .firstMatch(pubspecText);
      expect(versionMatch, isNotNull,
          reason: 'pubspec.yaml is missing a top-level `version:` line');
      final currentVersion = versionMatch!.group(1)!;
      final failures = checkLegacyObservedAxisManifest(
        manifest: legacyObservedAxisAllowlist,
        currentReleaseVersion: currentVersion,
      );
      expect(failures, isEmpty,
          reason: 'Legacy observed-axis allowlist audit failed. Either '
              're-record the relevant captures so the per-record cross-'
              'check activates, or extend the consumeBy with a documented '
              'reason. Failures: $failures');
    });
  });

  group('Multi-axis audit pipeline (v0.19.8)', () {
    // Calls the SAME factored helper sequence the production walker
    // runs (`runRuntimeTierAudit`) so any drift in walker wiring fails
    // CI here even when no shipped detector populates additionalBrackets.
    // Adds checkPerStableIdTier (walker calls it outside the tier
    // switch) so the E2E group covers the full multi-axis verification
    // path.
    //
    // `repoRoot` points at a tempdir without `pubspec.yaml` so file-
    // system helpers (`checkBracketValidation`,
    // `checkAdditionalCapturePaths`, `checkAdditionalBracketValidation`)
    // early-return. Structural checks (covered-thresholds, severity-
    // scoped-ceiling, bracket-count, structural per-spec, cross-spec
    // collision, path overlap) still run on synthetic metadata.
    late Directory tempRoot;
    setUpAll(() {
      tempRoot = Directory.systemTemp.createTempSync('sleuth_e2e_audit_root_');
    });
    tearDownAll(() {
      if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
    });

    List<String> walkRuntimeVerifiedHelpers(DetectorMetadata meta) {
      const label = 'FakeMultiAxisDetector';
      final failures = <String>[
        ...runRuntimeTierAudit(
          label: label,
          meta: meta,
          repoRoot: tempRoot.path,
        ),
        ...checkPerStableIdTier(
          label: label,
          tier: meta.tier,
          perStableIdTier: meta.perStableIdTier,
          coveredStableIds: meta.coveredStableIds,
          bracketStableId: meta.bracketStableId,
          additionalBrackets: meta.additionalBrackets,
          topLevelCoveredThresholds: meta.coveredThresholds,
        ),
        ...checkCanonicalCoveredThresholdBacking(
          label: label,
          tier: meta.effectiveMaxTier,
          topLevelStableId: meta.bracketStableId,
          topLevelSeverityLabel: meta.bracketSeverityLabel,
          topLevelCoveredThresholds: meta.coveredThresholds,
          additionalBrackets: meta.additionalBrackets,
        ),
        ...checkRuntimeVerifiedRequiresObservedAxisArgKey(
          label: label,
          tier: meta.effectiveMaxTier,
          topLevelStableId: meta.bracketStableId,
          topLevelObservedAxisArgKey: meta.observedAxisArgKey,
          additionalBrackets: meta.additionalBrackets,
        ),
      ];
      return failures;
    }

    BracketSpec mkSpec({
      String stableId = 'foo',
      String severityLabel = 'warning',
      String? argKey,
      List<String>? paths,
      double? aboveCeilingMultiplier = 1.5,
      Set<String>? coveredThresholds,
    }) =>
        BracketSpec(
          stableId: stableId,
          severityLabel: severityLabel,
          threshold: 8,
          unit: 'ms',
          coveredThresholds: coveredThresholds ?? {'$stableId.$severityLabel'},
          profileCapturePaths: paths ??
              const [
                'test/validation/captures/x/below.json',
                'test/validation/captures/x/at.json',
                'test/validation/captures/x/above.json',
              ],
          observedAxisArgKey: argKey,
          aboveCeilingMultiplier: aboveCeilingMultiplier,
        );

    DetectorMetadata mkMeta({
      Set<String>? coveredStableIds,
      Set<String>? coveredThresholds,
      Map<String, EvidenceTier>? perStableIdTier,
      List<BracketSpec>? additionalBrackets,
      String? bracketStableId = 'foo',
      String? observedAxisArgKey = 'observedCount',
    }) =>
        DetectorMetadata(
          tier: EvidenceTier.reproducerOnly,
          rationale: 'fake rationale that is long enough to satisfy gate.',
          reproducerPath: 'test/validation/fake.dart',
          bracketStableId: bracketStableId,
          bracketSeverityLabel: 'warning',
          bracketThreshold: 20,
          bracketUnit: 'events',
          aboveCeilingMultiplier: 1.5,
          observedAxisArgKey: observedAxisArgKey,
          coveredStableIds: coveredStableIds ?? const {'foo'},
          coveredThresholds: coveredThresholds ?? const {'foo.warning'},
          perStableIdTier: perStableIdTier,
          additionalBrackets: additionalBrackets,
          profileCapturePaths: const [
            'test/validation/captures/canonical/below.json',
            'test/validation/captures/canonical/at.json',
            'test/validation/captures/canonical/above.json',
          ],
        );

    test('properly-configured multi-axis metadata passes structural helpers',
        () {
      final meta = mkMeta(
        coveredStableIds: const {'foo', 'bar'},
        coveredThresholds: const {'foo.warning', 'bar.warning'},
        perStableIdTier: const {
          'foo': EvidenceTier.runtimeVerified,
          'bar': EvidenceTier.runtimeVerified,
        },
        additionalBrackets: [
          mkSpec(stableId: 'bar', argKey: 'cumulativeDurationUs'),
        ],
      );
      final failures = walkRuntimeVerifiedHelpers(meta);
      expect(failures, isEmpty,
          reason: 'A correctly-shaped multi-axis declaration must clear '
              'the structural helpers (no collision, every raised family '
              'covered by canonical bracket OR additionalBrackets spec). '
              'Failures: $failures');
    });

    test('cross-spec collision in additionalBrackets surfaces failure', () {
      final meta = mkMeta(
        additionalBrackets: [
          mkSpec(stableId: 'foo', argKey: 'observedCount'),
        ],
      );
      final failures = walkRuntimeVerifiedHelpers(meta);
      expect(failures.any((f) => f.contains('cross-spec collision')), isTrue,
          reason: 'top-level (spec #0) and additionalBrackets[0] both target '
              '("foo", "observedCount") and must collide.');
    });

    test('mixed-mode: top-level + spec with distinct argKeys passes', () {
      final meta = mkMeta(
        additionalBrackets: [
          mkSpec(stableId: 'foo', argKey: 'cumulativeDurationUs'),
        ],
      );
      final failures = walkRuntimeVerifiedHelpers(meta);
      expect(failures, isEmpty,
          reason: 'Same stableId with distinct argKeys is the intended '
              'multi-axis pattern. Failures: $failures');
    });

    test('perStableIdTier raise without bracket coverage surfaces failure', () {
      final meta = mkMeta(
        coveredStableIds: const {'foo', 'unmoored'},
        coveredThresholds: const {'foo.warning'},
        perStableIdTier: const {
          'foo': EvidenceTier.runtimeVerified,
          'unmoored': EvidenceTier.runtimeVerified,
        },
        additionalBrackets: null,
      );
      final failures = walkRuntimeVerifiedHelpers(meta);
      expect(
          failures.any((f) =>
              f.contains('"unmoored"') &&
              f.contains('no coveredThresholds entry')),
          isTrue,
          reason: 'A runtimeVerified raise on "unmoored" not covered by any '
              'coveredThresholds entry must fail. Failures: $failures');
    });

    test('perStableIdTier raise covered ONLY by additionalBrackets passes', () {
      // Exercises the audit-walker wiring that proves coverage through
      // coveredThresholds (not stableId match). Spec covers "bar" via
      // its own coveredThresholds; canonical bracket points at "foo".
      final meta = mkMeta(
        coveredStableIds: const {'foo', 'bar'},
        coveredThresholds: const {'foo.warning'},
        perStableIdTier: const {
          'foo': EvidenceTier.runtimeVerified,
          'bar': EvidenceTier.runtimeVerified,
        },
        additionalBrackets: [
          mkSpec(stableId: 'bar', argKey: 'observedSlope'),
        ],
      );
      final failures = walkRuntimeVerifiedHelpers(meta);
      expect(failures, isEmpty,
          reason: 'A spec whose coveredThresholds contains "bar.warning" '
              'must satisfy the perStableIdTier coverage rule for "bar" '
              'even when canonical bracket targets a different family. '
              'Failures: $failures');
    });

    test(
        'spec.coveredThresholds with cross-family entry rejected (drift '
        'guard)', () {
      // Spec declares stableId='bar' but its coveredThresholds claims
      // foo.warning — the schema field that exists for severity-scoping
      // must align with the spec's own family, not silently overclaim.
      final meta = mkMeta(
        coveredStableIds: const {'foo', 'bar'},
        coveredThresholds: const {'foo.warning'},
        perStableIdTier: const {
          'foo': EvidenceTier.runtimeVerified,
          'bar': EvidenceTier.runtimeVerified,
        },
        additionalBrackets: [
          mkSpec(
            stableId: 'bar',
            argKey: 'observedSlope',
            coveredThresholds: const {'foo.warning'},
          ),
        ],
      );
      final failures = walkRuntimeVerifiedHelpers(meta);
      expect(
          failures.any((f) =>
              f.contains('coveredThresholds entry') &&
              f.contains('does not match spec.stableId')),
          isTrue,
          reason: 'Cross-family coveredThresholds entry must fail. '
              'Failures: $failures');
    });

    test('spec.coveredThresholds with malformed entry rejected', () {
      final meta = mkMeta(
        additionalBrackets: [
          mkSpec(
            stableId: 'foo',
            argKey: 'cumulativeDurationUs',
            coveredThresholds: const {'foo.warn'},
          ),
        ],
      );
      final failures = walkRuntimeVerifiedHelpers(meta);
      expect(
          failures.any((f) =>
              f.contains('unrecognised severity') && f.contains('"warn"')),
          isTrue,
          reason: 'Severity typo must be rejected. Failures: $failures');
    });

    test('empty additionalBrackets list rejected by structural helper', () {
      final meta = mkMeta(additionalBrackets: const <BracketSpec>[]);
      final failures = walkRuntimeVerifiedHelpers(meta);
      expect(failures.any((f) => f.contains('empty list')), isTrue,
          reason: 'Encode "no additional axes" as null, not [].');
    });

    test('per-spec wrong-length profileCapturePaths surfaces failure', () {
      final meta = mkMeta(
        additionalBrackets: [
          mkSpec(
            stableId: 'foo',
            argKey: 'cumulativeDurationUs',
            paths: const ['only/one.json'],
          ),
        ],
      );
      final failures = walkRuntimeVerifiedHelpers(meta);
      expect(
          failures.any(
              (f) => f.contains('profileCapturePaths must contain exactly 3')),
          isTrue,
          reason: 'A spec with 1 path must fail the structural check.');
    });

    test(
        'per-spec aboveCeilingMultiplier null with severity-scoped scope '
        'surfaces failure', () {
      final meta = mkMeta(
        additionalBrackets: [
          mkSpec(
            stableId: 'foo',
            argKey: 'cumulativeDurationUs',
            aboveCeilingMultiplier: null,
          ),
        ],
      );
      final failures = walkRuntimeVerifiedHelpers(meta);
      expect(
          failures.any((f) =>
              f.contains('additionalBrackets[0]') &&
              f.contains('explicit aboveCeilingMultiplier')),
          isTrue,
          reason: 'Severity-scoped spec with null aboveCeilingMultiplier '
              'must fail to prevent default-2.0 inheritance. Failures: '
              '$failures');
    });

    test('capture-path overlap between top-level and spec surfaces failure',
        () {
      final meta = mkMeta(
        coveredStableIds: const {'foo', 'bar'},
        coveredThresholds: const {'foo.warning', 'bar.warning'},
        additionalBrackets: [
          mkSpec(
            stableId: 'bar',
            argKey: 'observedSlope',
            paths: const [
              'test/validation/captures/canonical/below.json',
              'test/validation/captures/canonical/at.json',
              'test/validation/captures/canonical/above.json',
            ],
          ),
        ],
      );
      final failures = walkRuntimeVerifiedHelpers(meta);
      expect(
          failures.any((f) =>
              f.contains('capture path') && f.contains('shared between')),
          isTrue,
          reason: 'Spec sharing canonical triad must fail path-overlap '
              'check. Failures: $failures');
    });

    test('whitespace argKey collision detected after canonicalization', () {
      final meta = mkMeta(
        observedAxisArgKey: 'observedCount',
        additionalBrackets: [
          mkSpec(stableId: 'foo', argKey: '  observedCount  '),
        ],
      );
      final failures = walkRuntimeVerifiedHelpers(meta);
      expect(failures.any((f) => f.contains('cross-spec collision')), isTrue,
          reason: 'Whitespace-padded argKey must canonicalize and collide '
              'with same stableId+argKey on top-level. Failures: $failures');
    });
  });
}
