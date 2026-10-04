import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/sleuth.dart' show Sleuth;
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/models/ai_chat_adapter.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/models/recurrence_trend.dart';
import 'package:sleuth/src/models/startup_metrics.dart';
import 'package:sleuth/src/ui/ai_chat_page.dart';
import 'package:sleuth/src/ui/issue_card.dart';
import 'package:sleuth/src/ui/overlay_ui_state.dart';
import 'package:sleuth/src/ui/sleuth_theme.dart';
import 'package:sleuth/src/utils/ai_context_builder.dart';

import '../helpers/overlay_harness.dart';

/// Labels of every node in the semantics tree.
List<String> _labels(WidgetTester tester) {
  final labels = <String>[];
  bool visit(SemanticsNode node) {
    labels.add(node.label);
    node.visitChildren(visit);
    return true;
  }

  final owner = tester.binding.renderViews.first.owner!.semanticsOwner!;
  visit(owner.rootSemanticsNode!);
  return labels;
}

SemanticsData _data(WidgetTester tester, Finder finder) =>
    tester.getSemantics(finder).getSemanticsData();

/// Whether [finder]'s node has [flag]. `flagsCollection` is not available
/// on the 3.32 floor.
bool _hasFlag(WidgetTester tester, Finder finder, SemanticsFlag flag) =>
    // ignore: deprecated_member_use
    _data(tester, finder).hasFlag(flag);

void main() {
  group('Full-screen pages', () {
    testWidgets('block the app below; the card does not', (tester) async {
      final handle = tester.ensureSemantics();
      final controller = await pumpOverlay(tester);
      await openDashboard(tester, controller);
      expect(_labels(tester), contains('app'));

      await tester.tap(find.bySemanticsLabel('Guide'));
      await tester.pumpAndSettle();
      expect(find.text('Sleuth Guide'), findsOneWidget);
      expect(_labels(tester), isNot(contains('app')));

      await systemBack(tester);
      expect(_labels(tester), contains('app'));
      handle.dispose();
    });
  });

  group('Card header and grip', () {
    Future<SleuthController> pumpCard(WidgetTester tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = await pumpOverlay(tester);
      controller.overlayUiState.setCardGeometry(
        offset: const Offset(40, 100),
        width: 300,
        height: 400,
        windowState: CardWindowState.normal,
      );
      await openDashboard(tester, controller);
      return controller;
    }

    testWidgets('expose no scroll actions and read the size back', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpCard(tester);
      final header = find.bySemanticsLabel('Sleuth');
      final grip = find.bySemanticsLabel('Resize card');
      for (final node in [_data(tester, header), _data(tester, grip)]) {
        for (final action in [
          SemanticsAction.scrollUp,
          SemanticsAction.scrollDown,
          SemanticsAction.scrollLeft,
          SemanticsAction.scrollRight,
        ]) {
          expect(node.hasAction(action), isFalse, reason: '$action');
        }
      }
      expect(_data(tester, header).value, '300 by 400 points, at 40, 100');
      expect(_data(tester, grip).value, '300 by 400 points');

      await performCustomAction(tester, grip, 'Taller');
      expect(_data(tester, grip).value, '300 by 448 points');
      await performCustomAction(tester, header, 'Move to top left');
      expect(_data(tester, header).value, '300 by 448 points, at 0, 0');
      handle.dispose();
    });

    testWidgets('the theme toggle has a value and no hint', (tester) async {
      await pumpCard(tester);
      final toggle = _data(tester, find.bySemanticsLabel('Toggle theme'));
      expect(toggle.value, 'System');
      expect(toggle.hint, isEmpty);
    });

    testWidgets('the minimized count reads as issues', (tester) async {
      final controller = await pumpCard(tester);
      controller.issuesNotifier.value = mixedOverlayIssues();
      await tester.tap(find.bySemanticsLabel('Minimize'));
      await tester.pump();
      final visible = controller.overlayUiState
          .visibleIssues(controller.issuesNotifier.value)
          .length;
      expect(find.bySemanticsLabel('$visible issues'), findsOneWidget);
    });
  });

  group('Startup banner', () {
    tearDown(Sleuth.resetStartupForTest);

    testWidgets('is a 48 px target', (tester) async {
      Sleuth.setStartupMetricsForTest(
        StartupMetrics(dartEntryTimestamp: DateTime(2026), ttffMs: 420),
      );
      final controller = await pumpOverlay(tester);
      await openDashboard(tester, controller);
      final banner = find.byWidgetPredicate(
        (w) =>
            w is Semantics &&
            w.properties.label == 'Startup metrics, tap for details',
      );
      expect(tester.getSize(banner).height, greaterThanOrEqualTo(48));
    });
  });

  group('Issue card', () {
    Widget card(
      PerformanceIssue issue, {
      SleuthThemeData theme = const SleuthThemeData(),
      VoidCallback? onCopy,
      RecurrenceTrend? trend,
      bool expanded = false,
    }) => MaterialApp(
      home: Scaffold(
        body: SleuthTheme(
          data: theme,
          child: SingleChildScrollView(
            child: IssueCard(
              issue: issue,
              onCopy: onCopy,
              recurrenceTrend: trend,
              initiallyExpanded: expanded,
            ),
          ),
        ),
      ),
    );

    const issue = PerformanceIssue(
      severity: IssueSeverity.warning,
      category: IssueCategory.build,
      confidence: IssueConfidence.confirmed,
      confidenceReason: 'Measured on the VM timeline',
      title: 'Rebuilds in PriceTag',
      detail: 'd',
      fixHint: 'f',
      stableId: 'rebuild_activity',
    );

    testWidgets('Copy details is a custom action', (tester) async {
      final handle = tester.ensureSemantics();
      var copies = 0;
      await tester.pumpWidget(card(issue, onCopy: () => copies++));
      await performCustomAction(
        tester,
        find.bySemanticsLabel('Rebuilds in PriceTag'),
        'Copy details',
      );
      expect(copies, 1);
      handle.dispose();
    });

    testWidgets('the confidence badge is read once', (tester) async {
      await tester.pumpWidget(card(issue));
      final all = _labels(tester).join('\n');
      expect(all, contains('CONFIRMED: Measured on the VM timeline'));
      expect('CONFIRMED'.allMatches(all), hasLength(1));
    });

    testWidgets('the recurrence badge matches the other badges', (
      tester,
    ) async {
      final trend = RecurrenceTrend(capacity: 4);
      for (var i = 0; i < 4; i++) {
        trend.recordPresent(i, severityIndex: 2);
      }
      await tester.pumpWidget(card(issue, trend: trend));
      final recurrence = tester.widget<Text>(find.textContaining('Seen'));
      final category = tester.widget<Text>(find.text('BUILD'));
      expect(recurrence.style!.fontSize, category.style!.fontSize);
      final box = tester.widget<DecoratedBox>(
        find
            .ancestor(
              of: find.textContaining('Seen'),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      expect((box.decoration as BoxDecoration).border, isNotNull);
    });

    testWidgets('high contrast draws the pin at full opacity', (tester) async {
      await tester.pumpWidget(
        card(
          issue,
          theme: const SleuthThemeData.highContrastDark(),
          expanded: true,
        ),
      );
      final pin = tester.widget<Icon>(find.byIcon(Icons.push_pin));
      expect(pin.color!.a, 1);
    });
  });

  group('AI chat', () {
    PerformanceIssue chatIssue() => const PerformanceIssue(
      severity: IssueSeverity.warning,
      category: IssueCategory.memory,
      confidence: IssueConfidence.confirmed,
      title: 'Heap growing',
      detail: 'd',
      fixHint: 'f',
      stableId: 'heap_growing',
    );

    testWidgets('keeps focus while a reply streams and announces it', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final replies = StreamController<String>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AiChatPage(
              issue: chatIssue(),
              allIssues: const [],
              adapter: AiChatAdapter(sendMessage: (_) => replies.stream),
              history: const [],
              onHistoryChanged: (_) {},
              onClose: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'Why?');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.readOnly, isTrue);
      expect(field.enabled, isNot(false));
      final editable = tester.state<EditableTextState>(
        find.byType(EditableText),
      );
      expect(editable.widget.focusNode.hasFocus, isTrue);

      expect(
        _hasFlag(
          tester,
          find.bySemanticsLabel('Thinking'),
          SemanticsFlag.isLiveRegion,
        ),
        isTrue,
      );

      replies.add('Because.');
      await replies.close();
      await tester.pump();
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).readOnly,
        isFalse,
      );
      expect(editable.widget.focusNode.hasFocus, isTrue);
      expect(
        _hasFlag(
          tester,
          find.bySemanticsLabel('Because.'),
          SemanticsFlag.isLiveRegion,
        ),
        isTrue,
      );
      handle.dispose();
    });

    testWidgets('starter chips are buttons', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AiChatPage(
              issue: chatIssue(),
              allIssues: const [],
              adapter: AiChatAdapter(sendMessage: (_) => const Stream.empty()),
              history: const [],
              onHistoryChanged: (_) {},
              onClose: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final first = find.bySemanticsLabel(
        AiContextBuilder.starterQuestions(chatIssue()).first,
      );
      expect(_hasFlag(tester, first, SemanticsFlag.isButton), isTrue);
    });
  });
}
