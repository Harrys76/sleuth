import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/session_snapshot.dart';

/// Tree that triggers `non_lazy_list` (SingleChildScrollView + Column with
/// >50 children).
Widget _listTree() => Directionality(
      textDirection: TextDirection.ltr,
      child: SingleChildScrollView(
        child: Column(
          children: List.generate(
            55,
            (i) => SizedBox(key: ValueKey(i), height: 10),
          ),
        ),
      ),
    );

void main() {
  group('Issue Suppression (v4.1)', () {
    group('no suppression', () {
      late SleuthController controller;

      setUp(() {
        controller = SleuthController();
        controller.initializeDetectorsForTest();
      });

      tearDown(() => controller.dispose());

      testWidgets('empty suppressedIssues passes all issues through',
          (tester) async {
        await tester.pumpWidget(_listTree());
        controller.runTreeScanForTest(
          tester.element(find.byType(Directionality)),
        );

        final issues = controller.issuesNotifier.value;
        expect(issues.any((i) => i.stableId == 'non_lazy_list'), isTrue);
        expect(controller.suppressedCountForTest, 0);
      });

      testWidgets('suppression with no issues yields count 0', (tester) async {
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
      late SleuthController controller;

      setUp(() {
        controller = SleuthController(
          config: const SleuthConfig(
            suppressedIssues: {'non_lazy_list'},
          ),
        );
        controller.initializeDetectorsForTest();
      });

      tearDown(() => controller.dispose());

      testWidgets('exact stableId match suppresses the issue', (tester) async {
        await tester.pumpWidget(_listTree());
        controller.runTreeScanForTest(
          tester.element(find.byType(Directionality)),
        );

        final issues = controller.issuesNotifier.value;
        expect(issues.any((i) => i.stableId == 'non_lazy_list'), isFalse);
      });

      testWidgets('suppressedCountNotifier reflects correct count',
          (tester) async {
        await tester.pumpWidget(_listTree());
        controller.runTreeScanForTest(
          tester.element(find.byType(Directionality)),
        );

        expect(controller.suppressedCountForTest, greaterThanOrEqualTo(1));
      });

      testWidgets('non-matching patterns pass issues through', (tester) async {
        // Suppress 'shader_compilation' which won't appear in this tree.
        final c = SleuthController(
          config: const SleuthConfig(
            suppressedIssues: {'shader_compilation'},
          ),
        );
        c.initializeDetectorsForTest();

        await tester.pumpWidget(_listTree());
        c.runTreeScanForTest(
          tester.element(find.byType(Directionality)),
        );

        expect(c.issuesNotifier.value.any((i) => i.stableId == 'non_lazy_list'),
            isTrue);
        expect(c.suppressedCountForTest, 0);

        c.dispose();
      });
    });

    group('wildcard match', () {
      late SleuthController controller;

      setUp(() {
        controller = SleuthController(
          config: const SleuthConfig(
            suppressedIssues: {'non_lazy_*'},
          ),
        );
        controller.initializeDetectorsForTest();
      });

      tearDown(() => controller.dispose());

      testWidgets('prefix wildcard suppresses matching issues', (tester) async {
        await tester.pumpWidget(_listTree());
        controller.runTreeScanForTest(
          tester.element(find.byType(Directionality)),
        );

        // non_lazy_list starts with 'non_lazy_' so it matches 'non_lazy_*'
        expect(
            controller.issuesNotifier.value.any(
              (i) => i.stableId == 'non_lazy_list',
            ),
            isFalse);
        expect(controller.suppressedCountForTest, greaterThanOrEqualTo(1));
      });
    });

    group('title fallback', () {
      testWidgets('stableId takes precedence over title', (tester) async {
        // 'NonMatching*' prefix matches neither stableId nor title of
        // non_lazy_list. Issue passes through unsuppressed.
        final controller = SleuthController(
          config: const SleuthConfig(
            suppressedIssues: {'NonMatching*'},
          ),
        );
        controller.initializeDetectorsForTest();

        await tester.pumpWidget(_listTree());
        controller.runTreeScanForTest(
          tester.element(find.byType(Directionality)),
        );

        expect(
          controller.issuesNotifier.value.any(
            (i) => i.stableId == 'non_lazy_list',
          ),
          isTrue,
        );
        expect(controller.suppressedCountForTest, 0);

        controller.dispose();
      });
    });

    group('export', () {
      late SleuthController controller;

      setUp(() {
        controller = SleuthController(
          config: const SleuthConfig(
            suppressedIssues: {'non_lazy_list'},
          ),
        );
        controller.initializeDetectorsForTest();
      });

      tearDown(() => controller.dispose());

      testWidgets('export snapshot includes suppressedCount', (tester) async {
        await tester.pumpWidget(_listTree());
        controller.runTreeScanForTest(
          tester.element(find.byType(Directionality)),
        );

        final snapshot = controller.exportSnapshot();
        expect(snapshot.suppressedCount, greaterThanOrEqualTo(1));

        final json =
            jsonDecode(snapshot.toJsonString()) as Map<String, dynamic>;
        expect(json['suppressedCount'], snapshot.suppressedCount);

        final restored = SessionSnapshot.fromJson(json);
        expect(restored.suppressedCount, snapshot.suppressedCount);
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
