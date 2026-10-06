import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/detectors/listview_detector.dart';
import 'package:sleuth/src/models/ai_chat_adapter.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/ui/ai_chat_page.dart';
import 'package:sleuth/src/ui/floating_issues_card.dart';
import 'package:sleuth/src/ui/issue_card.dart';

import '../helpers/overlay_harness.dart';

/// Shrink-wrapped lists in a Column inside a SingleChildScrollView, one
/// per `(key, rows)` entry. Each list above 20 rows is reported as its own
/// `non_lazy_shrinkwrap` issue under one list key; equal row counts give
/// equal titles.
class _Sections extends StatelessWidget {
  const _Sections(this.lists);

  final List<(String, int)> lists;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    child: Column(
      children: [
        for (final (key, rows) in lists)
          ListView(
            key: ValueKey(key),
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            children: [for (var i = 0; i < rows; i++) Text('$key $i')],
          ),
      ],
    ),
  );
}

void main() {
  group('Ask AI on cards that share a list key', () {
    late ValueNotifier<List<(String, int)>> lists;
    late SleuthController controller;

    setUp(() => lists = ValueNotifier([('a', 30), ('b', 30)]));
    tearDown(() => lists.dispose());

    Future<void> pumpApp(WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      controller = await pumpOverlay(
        tester,
        config: SleuthConfig(
          aiChat: AiChatAdapter(
            sendMessage: (request) =>
                Stream.value('Answer to ${request.history.last.text}'),
          ),
          treeScanInterval: const Duration(hours: 1),
        ),
        app: MaterialApp(
          home: Scaffold(
            body: ValueListenableBuilder<List<(String, int)>>(
              valueListenable: lists,
              builder: (_, value, _) => _Sections(value),
            ),
          ),
        ),
      );
    }

    /// Runs the ListView detector over the app and publishes its
    /// `non_lazy_shrinkwrap` issues, in tree order.
    Future<List<PerformanceIssue>> scan(WidgetTester tester) async {
      final detector = ListviewDetector()
        ..scanTree(tester.element(find.byType(_Sections)));
      final issues = [
        for (final i in detector.issues)
          if (i.stableId == 'non_lazy_shrinkwrap') i,
      ];
      controller.issuesNotifier.value = issues;
      await tester.pump(const Duration(milliseconds: 600));
      return issues;
    }

    Finder cardOf(PerformanceIssue issue) => find.byWidgetPredicate(
      (w) => w is IssueCard && identical(w.issue, issue),
    );

    /// Expands the card of [issue] when it is collapsed, then taps its Ask
    /// AI link.
    Future<void> askAi(WidgetTester tester, PerformanceIssue issue) async {
      final card = cardOf(issue);
      expect(card, findsOneWidget);
      final link = find.descendant(
        of: card,
        matching: find.bySemanticsLabel('Ask AI about this issue'),
      );
      if (link.evaluate().isEmpty) {
        final title = find.descendant(
          of: card,
          matching: find.text(issue.title),
        );
        await tester.ensureVisible(title);
        await tester.pump(const Duration(milliseconds: 600));
        await tester.tap(title);
        await tester.pump(const Duration(milliseconds: 600));
      }
      await tester.ensureVisible(link);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.tap(link);
      await tester.pump();
      // The page fades in from its first frame.
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(AiChatPage), findsOneWidget);
    }

    Future<void> send(WidgetTester tester, String text) async {
      await tester.enterText(find.byType(TextField), text);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
    }

    Future<void> closeChat(WidgetTester tester) async {
      await tester.tap(find.bySemanticsLabel('Close AI chat'));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(AiChatPage), findsNothing);
    }

    /// Collapses the expanded card of [issue], so the short list keeps
    /// both cards in view.
    Future<void> collapse(WidgetTester tester, PerformanceIssue issue) async {
      final title = find.descendant(
        of: cardOf(issue),
        matching: find.text(issue.title),
      );
      await tester.ensureVisible(title);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.tap(title);
      await tester.pump(const Duration(milliseconds: 600));
    }

    PerformanceIssue chatIssue(WidgetTester tester) =>
        tester.widget<AiChatPage>(find.byType(AiChatPage)).issue;

    testWidgets('two equal shrink-wrapped lists make two cards, and Ask AI '
        'on the second opens a chat about the second', (tester) async {
      await pumpApp(tester);
      final issues = await scan(tester);
      expect(issues, hasLength(2));
      expect(issues[0].title, issues[1].title);
      expect(listKeyFor(issues[0]), listKeyFor(issues[1]));
      await openDashboard(tester, controller);
      expect(find.byType(IssueCard), findsNWidgets(2));

      await askAi(tester, issues[1]);
      expect(tester.takeException(), isNull);
      expect(chatIssue(tester), same(issues[1]));
    });

    testWidgets('a conversation on one card is not shown on the other', (
      tester,
    ) async {
      await pumpApp(tester);
      final issues = await scan(tester);
      await openDashboard(tester, controller);

      await askAi(tester, issues[0]);
      await send(tester, 'Why is the first list slow?');
      expect(
        find.text('Answer to Why is the first list slow?'),
        findsOneWidget,
      );
      await closeChat(tester);
      await collapse(tester, issues[0]);

      await askAi(tester, issues[1]);
      expect(chatIssue(tester), same(issues[1]));
      expect(find.text('Why is the first list slow?'), findsNothing);
      expect(find.text('Answer to Why is the first list slow?'), findsNothing);
      await closeChat(tester);
      await collapse(tester, issues[1]);

      // The first card still has its own conversation.
      await askAi(tester, issues[0]);
      expect(find.text('Why is the first list slow?'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the chat follows its list through a title change', (
      tester,
    ) async {
      await pumpApp(tester);
      final issues = await scan(tester);
      await openDashboard(tester, controller);
      await askAi(tester, issues[0]);

      // The same list grows by one row: a new title, the same element.
      lists.value = [('a', 31), ('b', 30)];
      await tester.pump();
      final rescanned = await scan(tester);
      expect(rescanned[0].title, isNot(issues[0].title));
      expect(rescanned[1].title, issues[0].title);

      expect(chatIssue(tester), same(rescanned[0]));
      expect(
        find.descendant(
          of: find.byType(AiChatPage),
          matching: find.text(rescanned[0].title),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('the chat follows its list when the order changes', (
      tester,
    ) async {
      await pumpApp(tester);
      final issues = await scan(tester);
      await openDashboard(tester, controller);
      await askAi(tester, issues[0]);
      expect(chatIssue(tester), same(issues[0]));

      lists.value = [('b', 30), ('a', 30)];
      await tester.pump();
      final reordered = await scan(tester);
      expect(reordered[0].title, reordered[1].title);

      // The first list is now reported second.
      expect(chatIssue(tester), same(reordered[1]));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a chat whose list goes away keeps that list and does not '
        'move to the other', (tester) async {
      await pumpApp(tester);
      final issues = await scan(tester);
      await openDashboard(tester, controller);
      await askAi(tester, issues[0]);

      lists.value = [('b', 30)];
      await tester.pump();
      final remaining = await scan(tester);
      expect(remaining, hasLength(1));
      expect(find.byType(AiChatPage), findsOneWidget);
      expect(chatIssue(tester), same(issues[0]));

      // The conversation stays with the list that went away.
      await send(tester, 'Was the first list fixed?');
      expect(find.text('Answer to Was the first list fixed?'), findsOneWidget);
      await closeChat(tester);
      await askAi(tester, remaining.single);
      expect(chatIssue(tester), same(remaining.single));
      expect(find.text('Was the first list fixed?'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('a reply cut off by a controller swap does not reach the new '
      "controller's chat", (tester) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const issue = PerformanceIssue(
      severity: IssueSeverity.warning,
      category: IssueCategory.build,
      confidence: IssueConfidence.confirmed,
      title: 'Rebuilds',
      detail: 'Detail',
      fixHint: 'Fix',
      stableId: 'rebuild_activity',
    );
    SleuthController make(AiChatAdapter adapter) {
      final c = SleuthController(
        config: SleuthConfig(
          aiChat: adapter,
          treeScanInterval: const Duration(hours: 1),
        ),
      )..initializeDetectorsForTest();
      addTearDown(c.dispose);
      c.issuesNotifier.value = [issue];
      return c;
    }

    Widget host(SleuthController c) => MaterialApp(
      home: Scaffold(
        body: FloatingIssuesCard(controller: c, onClose: () {}),
      ),
    );
    Future<void> askAi() async {
      final link = find.bySemanticsLabel('Ask AI about this issue');
      if (link.evaluate().isEmpty) {
        await tester.tap(find.text('Rebuilds'));
        await tester.pump(const Duration(milliseconds: 600));
      }
      await tester.ensureVisible(link);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.tap(link);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(AiChatPage), findsOneWidget);
    }

    final stream = StreamController<String>();
    await tester.pumpWidget(
      host(make(AiChatAdapter(sendMessage: (_) => stream.stream))),
    );
    await tester.pumpAndSettle();
    await askAi();
    await tester.enterText(find.byType(TextField), 'Why?');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    stream.add('Partial');
    await tester.pump();
    expect(stream.hasListener, isTrue);

    // The swap closes the chat mid-reply; the page commits the partial
    // reply as it goes.
    await tester.pumpWidget(
      host(make(AiChatAdapter(sendMessage: (_) => Stream.value('ok')))),
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(AiChatPage), findsNothing);
    expect(stream.hasListener, isFalse);

    await askAi();
    expect(find.text('Why?'), findsNothing);
    expect(find.textContaining('Partial'), findsNothing);
    expect(tester.takeException(), isNull);
    // Not awaited: a cancelled controller never completes its close.
    unawaited(stream.close());
  });
}
