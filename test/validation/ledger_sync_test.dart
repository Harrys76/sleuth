// CODEX-R4-1: ledger-sync gate.
//
// `doc/validation_ledger.md` is the public reliability statement — it
// lists every built-in detector with its current `EvidenceTier`. The
// source of truth is each detector's `validationMetadata`, but the
// ledger is what users read. Without a CI gate, the two drift: a tier
// raise lands in code and the ledger still says `unvalidated`, or the
// ledger is hand-edited to promise a stronger tier than the detector
// actually carries.
//
// This test counts detectors at each tier from
// `SleuthController.detectorsForAudit` and cross-checks the counts
// against the ledger's per-tier totals (the "X / 23 at `reproducerOnly`"
// summary plus the per-tier row counts in each category section). Any
// mismatch fires here, naming the tier that diverged so the fix is
// obvious.
//
// This is a *coarse* gate — it does not cross-check which *specific*
// detector is at which tier (that would require a programmatic
// name mapping between `runtimeType` and the human-facing display name
// in the ledger, which we don't have). A coarse gate is deliberate:
// it catches the class of error this sprint is most worried about
// (a raise landing in code but not in the doc, or vice versa) without
// coupling the test to the ledger's prose formatting.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/sleuth.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/validation/validated_component_registry.dart';

void main() {
  group('validation_ledger.md is in sync with detector metadata', () {
    late SleuthController controller;

    setUp(() {
      controller = SleuthController();
      controller.initializeDetectorsForTest();
    });

    tearDown(() {
      controller.dispose();
    });

    test(
        'ledger per-tier counts match controller.detectorsForAudit '
        'tier counts', () {
      final ledgerFile = File('doc/validation_ledger.md');
      if (!ledgerFile.existsSync()) {
        markTestSkipped('CWD is not the package root; skipping.');
        return;
      }
      final source = ledgerFile.readAsStringSync();

      // Build the tier-count map from the real detector metadata.
      final fromMetadata = <EvidenceTier, int>{
        for (final t in EvidenceTier.values) t: 0,
      };
      for (final d in controller.detectorsForAudit) {
        if (d is! DetectorMetadataProvider) continue;
        final tier = (d as DetectorMetadataProvider).validationMetadata.tier;
        fromMetadata[tier] = fromMetadata[tier]! + 1;
      }

      // Count ledger rows per tier by scanning for table cells of the
      // form `| ... | `tierName` | ...`. The detector sections live
      // between the `## Ledger` heading and the `## Non-Detector
      // Components` heading; the earlier "Evidence tiers" table shares
      // the tier vocabulary and must be excluded.
      final startOfDetectors = source.indexOf('## Ledger');
      final endOfDetectors = source.indexOf('## Non-Detector Components');
      expect(startOfDetectors, greaterThan(0),
          reason: 'Ledger must have a `## Ledger` heading.');
      expect(endOfDetectors, greaterThan(startOfDetectors),
          reason: 'Ledger must have a Non-Detector Components section to '
              'bound the detector count; not finding it likely means the '
              'ledger was restructured and this test needs updating.');
      final detectorSection =
          source.substring(startOfDetectors, endOfDetectors);

      final fromLedger = <EvidenceTier, int>{
        for (final t in EvidenceTier.values) t: 0,
      };
      for (final tier in EvidenceTier.values) {
        // e.g. `` | `unvalidated` | ``
        final pattern = RegExp('\\|\\s*`${tier.name}`\\s*\\|');
        fromLedger[tier] = pattern.allMatches(detectorSection).length;
      }

      expect(fromLedger, equals(fromMetadata),
          reason: 'Ledger detector rows diverge from detector metadata.\n'
              'Ledger counts: $fromLedger\n'
              'Metadata counts: $fromMetadata\n'
              'If a detector tier was raised in code, update '
              'doc/validation_ledger.md to match. If the ledger already '
              'promises a tier the detector does not carry, raise the '
              'detector or roll the ledger back.');
    });

    test(
        'ledger summary line matches the total detector count for the '
        'dominant tier', () {
      final ledgerFile = File('doc/validation_ledger.md');
      if (!ledgerFile.existsSync()) {
        markTestSkipped('CWD is not the package root; skipping.');
        return;
      }
      final source = ledgerFile.readAsStringSync();

      // Scope the denominator scan to the detector section's Summary
      // line. Previously the pattern scanned the full document, which
      // meant any illustrative prose elsewhere in the ledger (e.g. a
      // roadmap bullet reading "target: 5 / 23 at `reproducerOnly`")
      // would either break the test or inflate the match count. We
      // bind the match to a single line that must (a) live inside the
      // `## Ledger` → `## Non-Detector Components` slice and (b) start
      // with a `**Summary:**` anchor.
      final startOfDetectors = source.indexOf('## Ledger');
      final endOfDetectors = source.indexOf('## Non-Detector Components');
      expect(startOfDetectors, greaterThan(0),
          reason: 'Ledger must have a `## Ledger` heading.');
      expect(endOfDetectors, greaterThan(startOfDetectors),
          reason: 'Ledger must have a Non-Detector Components section '
              'to bound the detector summary line.');
      final detectorSection =
          source.substring(startOfDetectors, endOfDetectors);

      // Multiline match on a single line anchored by `**Summary:**`.
      final summaryLinePattern =
          RegExp(r'^\*\*Summary:\*\*\s+(.+)$', multiLine: true);
      final summaryMatch = summaryLinePattern.firstMatch(detectorSection);
      expect(summaryMatch, isNotNull,
          reason: 'Detector section must have a `**Summary:** ...` line '
              'as the first prose after the `## Ledger` heading; not '
              'finding it likely means the ledger was restructured and '
              'this test needs updating.');
      final summaryLine = summaryMatch!.group(1)!;

      final totalDetectors = controller.detectorsForAudit.length;
      // Within that single line, every "N / TOTAL at `tier`" must use
      // `totalDetectors` as the denominator.
      final denominatorPattern = RegExp(r'/\s*(\d+)\s+at\s+`');
      final matches = denominatorPattern.allMatches(summaryLine).toList();
      expect(matches, isNotEmpty,
          reason: 'Ledger summary line did not contain any '
              '"N / TOTAL at `tier`" fragments; summary prose must have '
              'been restructured.');
      for (final m in matches) {
        final denom = int.parse(m.group(1)!);
        expect(denom, equals(totalDetectors),
            reason: 'Ledger summary denominator ($denom) does not match '
                'the actual detector count ($totalDetectors). A detector '
                'was added or removed without updating the ledger summary.');
      }
    });

    test(
        'pinned detector-row assertion — NetworkMonitorDetector is on '
        'the ledger at reproducerOnly with slow_request raised via '
        'perStableIdTier (v0.19.0)', () {
      // AB-9: The tier-counts test above is coarse — it proves "N
      // detectors are at runtimeVerified" but cannot catch a ledger
      // edit that swaps which specific detector holds a given tier
      // without changing the count. Pin the specific row so a silent
      // swap fails loudly.
      //
      // Tier history: v0.16.1 reproducerOnly → v0.16.4 reproducerOnly
      // (externallyCited staged + reverted in same release) → v0.16.5
      // reproducerOnly (second externallyCited staged + reverted) →
      // v0.18.0 runtimeVerified (slow_request warning tier; three
      // on-device captures via the in-app capture procedure) →
      // v0.19.0 base reproducerOnly + perStableIdTier raise of
      // slow_request to runtimeVerified (per-family-tier extension
      // so the four other emitted families stop being mechanically
      // over-claimed).
      final ledgerFile = File('doc/validation_ledger.md');
      if (!ledgerFile.existsSync()) {
        markTestSkipped('CWD is not the package root; skipping.');
        return;
      }
      final source = ledgerFile.readAsStringSync();

      final startOfDetectors = source.indexOf('## Ledger');
      final endOfDetectors = source.indexOf('## Non-Detector Components');
      final detectorSection =
          source.substring(startOfDetectors, endOfDetectors);

      // Pin both halves of the v0.18.3 representation: the row's tier
      // cell must show the base tier, and the row's Notes cell must
      // declare the perStableIdTier raise. A silent edit removing the
      // raise (which would put NetworkMonitor's slow_request claim back
      // into base-tier territory and re-introduce the over-claim of the
      // four other families) fails on the second match.
      final pinnedRow = RegExp(
        r'\|\s*Network Monitor\s*\|\s*`reproducerOnly`\s*\|',
      );
      expect(pinnedRow.hasMatch(detectorSection), isTrue,
          reason: 'Ledger must carry a pinned row `| Network Monitor | '
              '`reproducerOnly` | ...` — a silent tier swap would '
              'otherwise pass the tier-count gate.');
      expect(detectorSection,
          contains('perStableIdTier{slow_request: runtimeVerified}'),
          reason: 'Ledger Notes column for NetworkMonitor must declare '
              'the perStableIdTier raise of slow_request — this is the '
              'evidence that the runtimeVerified bracket is still being '
              'enforced after the v0.18.3 base-tier drop.');
    });

    // AB-7: the detector-side gates slice out everything under
    // `## Non-Detector Components`, so any row in the component section
    // had zero CI coverage — the ledger could promise a `reproducerOnly`
    // component without the registry carrying a matching entry. Mirror
    // the per-tier and summary-line checks against the component section
    // and the `ValidatedComponentRegistry` so component-ledger drift
    // fails loudly.
    //
    // The registry is append-only and has no test-scoped clear, so this
    // file reads `all` directly. `flutter test` runs each file in its
    // own isolate and nothing in this file registers metadata, so the
    // registry is empty when these tests observe it in v0.16.2. When
    // the first real registration lands (v0.16.6), this test file is
    // the canonical place to dispatch `registerMetadata()` from
    // `setUpAll` so the registry reflects the post-dispatch state.
    test(
        'component-ledger per-tier counts match ValidatedComponentRegistry '
        'tier counts (AB-7)', () {
      final ledgerFile = File('doc/validation_ledger.md');
      if (!ledgerFile.existsSync()) {
        markTestSkipped('CWD is not the package root; skipping.');
        return;
      }
      final source = ledgerFile.readAsStringSync();

      final startOfComponents = source.indexOf('## Non-Detector Components');
      final endOfComponents = source.indexOf('## Roadmap');
      expect(startOfComponents, greaterThan(0),
          reason: 'Ledger must have a `## Non-Detector Components` heading.');
      expect(endOfComponents, greaterThan(startOfComponents),
          reason: 'Ledger must have a `## Roadmap` section to bound the '
              'component section.');
      final componentSection =
          source.substring(startOfComponents, endOfComponents);

      final registered = ValidatedComponentRegistry.instance.all;
      final fromRegistry = <EvidenceTier, int>{
        for (final t in EvidenceTier.values) t: 0,
      };
      for (final meta in registered) {
        fromRegistry[meta.tier] = fromRegistry[meta.tier]! + 1;
      }

      final fromLedger = <EvidenceTier, int>{
        for (final t in EvidenceTier.values) t: 0,
      };
      for (final tier in EvidenceTier.values) {
        final pattern = RegExp('\\|\\s*`${tier.name}`\\s*\\|');
        fromLedger[tier] = pattern.allMatches(componentSection).length;
      }

      expect(fromLedger, equals(fromRegistry),
          reason: 'Component-ledger rows diverge from '
              'ValidatedComponentRegistry tier counts.\n'
              'Ledger counts: $fromLedger\n'
              'Registry counts: $fromRegistry\n'
              'If a component was registered with a stronger tier, update '
              'the Non-Detector Components table in validation_ledger.md. '
              'If the ledger promises a tier with no matching registration, '
              'roll the ledger back or register the component.');
    });

    test(
        'component-ledger summary matches registry size when non-empty '
        '(AB-7)', () {
      final ledgerFile = File('doc/validation_ledger.md');
      if (!ledgerFile.existsSync()) {
        markTestSkipped('CWD is not the package root; skipping.');
        return;
      }
      final source = ledgerFile.readAsStringSync();
      final startOfComponents = source.indexOf('## Non-Detector Components');
      final endOfComponents = source.indexOf('## Roadmap');
      final componentSection =
          source.substring(startOfComponents, endOfComponents);

      final total = ValidatedComponentRegistry.instance.all.length;

      // v0.16.2 registry is empty — the Non-Detector Components section
      // documents this explicitly ("0 components currently registered")
      // and `_(none yet)_` is the sole row. Pin both so a registration
      // that lands without updating the summary fails here, and a
      // summary edit that claims registrations before they exist also
      // fails.
      if (total == 0) {
        expect(componentSection, contains('0 components currently registered'),
            reason: 'Empty registry must be reflected by the summary line.');
        expect(componentSection, contains('_(none yet)_'),
            reason: 'Empty registry must leave the _(none yet)_ placeholder '
                'row in place.');
      } else {
        // When the first real registration lands (v0.16.6), extend this
        // block with a per-tier denominator check mirroring the detector
        // summary gate.
        final summaryLinePattern =
            RegExp(r'^\*\*Summary:\*\*\s+(.+)$', multiLine: true);
        final summaryMatch = summaryLinePattern.firstMatch(componentSection);
        expect(summaryMatch, isNotNull,
            reason: 'Component section must carry a `**Summary:**` line '
                'once the first component is registered.');
        final denominatorPattern = RegExp(r'/\s*(\d+)\s+at\s+`');
        for (final m
            in denominatorPattern.allMatches(summaryMatch!.group(1)!)) {
          expect(int.parse(m.group(1)!), total,
              reason: 'Component-summary denominator does not match the '
                  'registered component count ($total).');
        }
      }
    });
  });
}
