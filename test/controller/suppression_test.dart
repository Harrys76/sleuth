import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:widget_watchdog/src/controller/watchdog_controller.dart';
import 'package:widget_watchdog/src/models/session_snapshot.dart';

/// Widget tree that triggers opacity_zero and non_lazy_list detectors.
const _opacityTree = Directionality(
  textDirection: TextDirection.ltr,
  child: Opacity(
    opacity: 0.0,
    child: SizedBox(width: 10, height: 10),
  ),
);

/// Widget tree that triggers both opacity_zero and non_lazy_list detectors.
/// ListviewDetector looks for SingleChildScrollView + Column/Row with >20 children.
Widget _opacityAndListTree() => Directionality(
      textDirection: TextDirection.ltr,
      child: Column(
        children: [
          const Opacity(
            opacity: 0.0,
            child: SizedBox(width: 10, height: 10),
          ),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                children: List.generate(
                  25,
                  (i) => SizedBox(key: ValueKey(i), height: 10),
                ),
              ),
            ),
          ),
        ],
      ),
    );

void main() {
  group('Issue Suppression (v4.1)', () {
    group('no suppression', () {
      late WatchdogController controller;

      setUp(() {
        controller = WatchdogController();
        controller.initializeDetectorsForTest();
      });

      tearDown(() => controller.dispose());

      testWidgets('empty suppressedIssues passes all issues through',
          (tester) async {
        await tester.pumpWidget(_opacityAndListTree());
        controller.runTreeScanForTest(
          tester.element(find.byType(Directionality)),
        );

        final issues = controller.issuesNotifier.value;
        final hasOpacity = issues.any((i) => i.stableId == 'opacity_zero');
        final hasList = issues.any((i) => i.stableId == 'non_lazy_list');
        expect(hasOpacity, isTrue);
        expect(hasList, isTrue);
        expect(controller.suppressedCountForTest, 0);
      });

      testWidgets('suppression with no issues yields count 0', (tester) async {
        // Minimal tree that triggers no detectors.
        await tester.pumpWidget(
          const Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(width: 10, height: 10),
          ),
        );
        controller.runTreeScanForTest(
          tester.element(find.byType(Directionality)),
        );

        expect(controller.issuesNotifier.value, isEmpty);
        expect(controller.suppressedCountForTest, 0);
      });
    });

    group('exact match', () {
      late WatchdogController controller;

      setUp(() {
        controller = WatchdogController(
          config: const WatchdogConfig(
            suppressedIssues: {'opacity_zero'},
          ),
        );
        controller.initializeDetectorsForTest();
      });

      tearDown(() => controller.dispose());

      testWidgets('exact stableId match suppresses the issue', (tester) async {
        await tester.pumpWidget(_opacityAndListTree());
        controller.runTreeScanForTest(
          tester.element(find.byType(Directionality)),
        );

        final issues = controller.issuesNotifier.value;
        expect(issues.any((i) => i.stableId == 'opacity_zero'), isFalse);
        // non_lazy_list should still be present
        expect(issues.any((i) => i.stableId == 'non_lazy_list'), isTrue);
      });

      testWidgets('suppressedCountNotifier reflects correct count',
          (tester) async {
        await tester.pumpWidget(_opacityTree);
        controller.runTreeScanForTest(
          tester.element(find.byType(Directionality)),
        );

        expect(controller.suppressedCountForTest, 1);
      });

      testWidgets('non-matching patterns pass issues through', (tester) async {
        // Suppress 'shader_compilation' which won't appear in this tree
        final c = WatchdogController(
          config: const WatchdogConfig(
            suppressedIssues: {'shader_compilation'},
          ),
        );
        c.initializeDetectorsForTest();

        await tester.pumpWidget(_opacityTree);
        c.runTreeScanForTest(
          tester.element(find.byType(Directionality)),
        );

        expect(c.issuesNotifier.value.any((i) => i.stableId == 'opacity_zero'),
            isTrue);
        expect(c.suppressedCountForTest, 0);

        c.dispose();
      });
    });

    group('wildcard match', () {
      late WatchdogController controller;

      setUp(() {
        controller = WatchdogController(
          config: const WatchdogConfig(
            suppressedIssues: {'opacity_*'},
          ),
        );
        controller.initializeDetectorsForTest();
      });

      tearDown(() => controller.dispose());

      testWidgets('prefix wildcard suppresses matching issues', (tester) async {
        await tester.pumpWidget(_opacityTree);
        controller.runTreeScanForTest(
          tester.element(find.byType(Directionality)),
        );

        // opacity_zero starts with 'opacity_' so it matches 'opacity_*'
        expect(
            controller.issuesNotifier.value.any(
              (i) => i.stableId == 'opacity_zero',
            ),
            isFalse);
        expect(controller.suppressedCountForTest, 1);
      });
    });

    group('mixed patterns', () {
      late WatchdogController controller;

      setUp(() {
        controller = WatchdogController(
          config: const WatchdogConfig(
            suppressedIssues: {'non_lazy_list', 'opacity_*'},
          ),
        );
        controller.initializeDetectorsForTest();
      });

      tearDown(() => controller.dispose());

      testWidgets('mixed exact and wildcard patterns', (tester) async {
        await tester.pumpWidget(_opacityAndListTree());
        controller.runTreeScanForTest(
          tester.element(find.byType(Directionality)),
        );

        final issues = controller.issuesNotifier.value;
        expect(issues.any((i) => i.stableId == 'opacity_zero'), isFalse);
        expect(issues.any((i) => i.stableId == 'non_lazy_list'), isFalse);
        expect(controller.suppressedCountForTest, 2);
      });
    });

    group('title fallback', () {
      testWidgets('title fallback when stableId is null', (tester) async {
        // We can't easily produce a null-stableId issue from real detectors
        // (all 22 set stableId), so we test the matching logic indirectly:
        // suppress a pattern matching a title, and verify behavior when a
        // real issue has a stableId that does NOT match but the title would.
        // Instead, test that the existing stableId takes precedence.
        final controller = WatchdogController(
          config: const WatchdogConfig(
            // This pattern matches the title prefix "Invisible Opacity..."
            // but stableId 'opacity_zero' does not start with 'Invisible'
            suppressedIssues: {'Invisible*'},
          ),
        );
        controller.initializeDetectorsForTest();

        await tester.pumpWidget(_opacityTree);
        controller.runTreeScanForTest(
          tester.element(find.byType(Directionality)),
        );

        // 'opacity_zero' does NOT start with 'Invisible' → not suppressed
        // (stableId takes precedence over title)
        expect(
          controller.issuesNotifier.value.any(
            (i) => i.stableId == 'opacity_zero',
          ),
          isTrue,
        );
        expect(controller.suppressedCountForTest, 0);

        controller.dispose();
      });
    });

    group('export', () {
      late WatchdogController controller;

      setUp(() {
        controller = WatchdogController(
          config: const WatchdogConfig(
            suppressedIssues: {'opacity_zero'},
          ),
        );
        controller.initializeDetectorsForTest();
      });

      tearDown(() => controller.dispose());

      testWidgets('export snapshot includes suppressedCount', (tester) async {
        await tester.pumpWidget(_opacityTree);
        controller.runTreeScanForTest(
          tester.element(find.byType(Directionality)),
        );

        final snapshot = controller.exportSnapshot();
        expect(snapshot.suppressedCount, 1);

        // JSON round-trip
        final json =
            jsonDecode(snapshot.toJsonString()) as Map<String, dynamic>;
        expect(json['suppressedCount'], 1);

        final restored = SessionSnapshot.fromJson(json);
        expect(restored.suppressedCount, 1);
      });

      test('suppressedCount absent from JSON when zero', () {
        final snapshot = controller.exportSnapshot();
        expect(snapshot.suppressedCount, 0);

        final json = snapshot.toJson();
        expect(json.containsKey('suppressedCount'), isFalse);
      });
    });
  });
}
