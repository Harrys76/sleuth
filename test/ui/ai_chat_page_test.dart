import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/models/ai_chat_adapter.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/ui/ai_chat_page.dart';
import 'package:sleuth/src/ui/issue_card.dart';

void main() {
  Widget wrap(Widget child) {
    return MaterialApp(home: Scaffold(body: child));
  }

  PerformanceIssue makeIssue({
    String? stableId,
    String title = 'Test Issue',
    String detail = 'Detail text',
    String fixHint = 'Fix hint text',
    IssueSeverity severity = IssueSeverity.warning,
    IssueCategory category = IssueCategory.memory,
    IssueConfidence confidence = IssueConfidence.confirmed,
    String? widgetName,
  }) {
    return PerformanceIssue(
      stableId: stableId,
      title: title,
      detail: detail,
      fixHint: fixHint,
      severity: severity,
      category: category,
      confidence: confidence,
      widgetName: widgetName,
    );
  }

  AiChatAdapter makeAdapter({
    Stream<String> Function(AiChatRequest)? sendMessage,
  }) {
    return AiChatAdapter(
      sendMessage:
          sendMessage ?? (req) => Stream.fromIterable(['Hello', ' world']),
    );
  }

  group('AiChatPage', () {
    testWidgets('renders header with Ask AI title', (tester) async {
      await tester.pumpWidget(wrap(
        AiChatPage(
          issue: makeIssue(),
          allIssues: const [],
          adapter: makeAdapter(),
          history: const [],
          onHistoryChanged: (_) {},
          onClose: () {},
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Ask AI'), findsOneWidget);
      expect(find.byIcon(Icons.auto_awesome), findsOneWidget);
    });

    testWidgets('back button calls onClose', (tester) async {
      var closed = false;
      await tester.pumpWidget(wrap(
        AiChatPage(
          issue: makeIssue(),
          allIssues: const [],
          adapter: makeAdapter(),
          history: const [],
          onHistoryChanged: (_) {},
          onClose: () => closed = true,
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.arrow_back));
      expect(closed, isTrue);
    });

    testWidgets('shows issue context card with title', (tester) async {
      await tester.pumpWidget(wrap(
        AiChatPage(
          issue: makeIssue(title: 'Heap Near Capacity'),
          allIssues: const [],
          adapter: makeAdapter(),
          history: const [],
          onHistoryChanged: (_) {},
          onClose: () {},
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Heap Near Capacity'), findsOneWidget);
    });

    testWidgets('shows starter questions on initial render', (tester) async {
      await tester.pumpWidget(wrap(
        AiChatPage(
          issue: makeIssue(category: IssueCategory.memory),
          allIssues: const [],
          adapter: makeAdapter(),
          history: const [],
          onHistoryChanged: (_) {},
          onClose: () {},
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Suggested questions'), findsOneWidget);
      expect(find.text('What is causing high memory usage?'), findsOneWidget);
    });

    testWidgets('tapping starter question sends it as user message',
        (tester) async {
      final controller = StreamController<String>();
      List<AiChatMessage>? lastHistory;

      await tester.pumpWidget(wrap(
        AiChatPage(
          issue: makeIssue(category: IssueCategory.memory),
          allIssues: const [],
          adapter: AiChatAdapter(sendMessage: (_) => controller.stream),
          history: const [],
          onHistoryChanged: (msgs) => lastHistory = msgs,
          onClose: () {},
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('What is causing high memory usage?'));
      await tester.pump();

      // User message appears
      expect(find.text('What is causing high memory usage?'), findsOneWidget);
      expect(lastHistory, isNotNull);
      expect(lastHistory!.last.role, AiChatRole.user);

      controller.close();
    });

    testWidgets('starter questions hidden after first message', (tester) async {
      final controller = StreamController<String>();

      await tester.pumpWidget(wrap(
        AiChatPage(
          issue: makeIssue(category: IssueCategory.memory),
          allIssues: const [],
          adapter: AiChatAdapter(sendMessage: (_) => controller.stream),
          history: const [],
          onHistoryChanged: (_) {},
          onClose: () {},
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Suggested questions'), findsOneWidget);

      // Send a message
      await tester.enterText(find.byType(TextField), 'Hello');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(find.text('Suggested questions'), findsNothing);

      controller.close();
    });

    testWidgets('starters hidden when history is non-empty', (tester) async {
      await tester.pumpWidget(wrap(
        AiChatPage(
          issue: makeIssue(),
          allIssues: const [],
          adapter: makeAdapter(),
          history: const [
            AiChatMessage(role: AiChatRole.user, text: 'Prior question'),
          ],
          onHistoryChanged: (_) {},
          onClose: () {},
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Suggested questions'), findsNothing);
      expect(find.text('Prior question'), findsOneWidget);
    });

    testWidgets('user message appears in chat after send', (tester) async {
      final controller = StreamController<String>();

      await tester.pumpWidget(wrap(
        AiChatPage(
          issue: makeIssue(),
          allIssues: const [],
          adapter: AiChatAdapter(sendMessage: (_) => controller.stream),
          history: const [],
          onHistoryChanged: (_) {},
          onClose: () {},
        ),
      ));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'My question');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(find.text('My question'), findsOneWidget);
      expect(find.text('You'), findsOneWidget);

      controller.close();
    });

    testWidgets('empty input does not send', (tester) async {
      List<AiChatMessage>? lastHistory;

      await tester.pumpWidget(wrap(
        AiChatPage(
          issue: makeIssue(),
          allIssues: const [],
          adapter: makeAdapter(),
          history: const [],
          onHistoryChanged: (msgs) => lastHistory = msgs,
          onClose: () {},
        ),
      ));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '   ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(lastHistory, isNull);
    });

    testWidgets('streaming response renders in AI bubble', (tester) async {
      final controller = StreamController<String>();

      await tester.pumpWidget(wrap(
        AiChatPage(
          issue: makeIssue(),
          allIssues: const [],
          adapter: AiChatAdapter(sendMessage: (_) => controller.stream),
          history: const [],
          onHistoryChanged: (_) {},
          onClose: () {},
        ),
      ));
      await tester.pumpAndSettle();

      // Send a message
      await tester.enterText(find.byType(TextField), 'Question');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      // Stream first token
      controller.add('Hello');
      await tester.pump();

      // Streaming bubble should show the token with cursor
      expect(find.textContaining('Hello'), findsOneWidget);

      // Stream more
      controller.add(' world');
      await tester.pump();
      expect(find.textContaining('Hello world'), findsOneWidget);

      // Complete
      await controller.close();
      await tester.pump();

      // Final message without cursor
      expect(find.text('Hello world'), findsOneWidget);
      // AI label should be visible
      expect(find.text('AI'), findsOneWidget);
    });

    testWidgets('thinking indicator visible before first token',
        (tester) async {
      final controller = StreamController<String>();

      await tester.pumpWidget(wrap(
        AiChatPage(
          issue: makeIssue(),
          allIssues: const [],
          adapter: AiChatAdapter(sendMessage: (_) => controller.stream),
          history: const [],
          onHistoryChanged: (_) {},
          onClose: () {},
        ),
      ));
      await tester.pumpAndSettle();

      // Send a message
      await tester.enterText(find.byType(TextField), 'Question');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      // Before any token arrives — thinking dots should be present
      // The pulsing dots are Container widgets with circle shape
      final dots = find.byWidgetPredicate(
        (w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).shape == BoxShape.circle,
      );
      expect(dots, findsNWidgets(3));

      // Send a token — thinking indicator should disappear
      controller.add('Token');
      await tester.pump();
      // Now streaming bubble is visible instead
      expect(find.textContaining('Token'), findsOneWidget);

      await controller.close();
      await tester.pump();
    });

    testWidgets('copy icon visible on AI messages', (tester) async {
      await tester.pumpWidget(wrap(
        AiChatPage(
          issue: makeIssue(),
          allIssues: const [],
          adapter: makeAdapter(),
          history: const [
            AiChatMessage(role: AiChatRole.user, text: 'Q'),
            AiChatMessage(role: AiChatRole.assistant, text: 'A'),
          ],
          onHistoryChanged: (_) {},
          onClose: () {},
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.copy), findsOneWidget);
    });

    testWidgets('onHistoryChanged called after user sends', (tester) async {
      final controller = StreamController<String>();
      final histories = <List<AiChatMessage>>[];

      await tester.pumpWidget(wrap(
        AiChatPage(
          issue: makeIssue(),
          allIssues: const [],
          adapter: AiChatAdapter(sendMessage: (_) => controller.stream),
          history: const [],
          onHistoryChanged: (msgs) => histories.add(List.of(msgs)),
          onClose: () {},
        ),
      ));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'Hello');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      // Called once with user message
      expect(histories, hasLength(1));
      expect(histories[0].last.role, AiChatRole.user);
      expect(histories[0].last.text, 'Hello');

      await controller.close();
      await tester.pump();
    });

    testWidgets('onHistoryChanged called after AI responds', (tester) async {
      final controller = StreamController<String>();
      final histories = <List<AiChatMessage>>[];

      await tester.pumpWidget(wrap(
        AiChatPage(
          issue: makeIssue(),
          allIssues: const [],
          adapter: AiChatAdapter(sendMessage: (_) => controller.stream),
          history: const [],
          onHistoryChanged: (msgs) => histories.add(List.of(msgs)),
          onClose: () {},
        ),
      ));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'Q');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      controller.add('Answer');
      await controller.close();
      await tester.pump();

      // Called twice: once for user, once for AI
      expect(histories, hasLength(2));
      expect(histories[1].last.role, AiChatRole.assistant);
      expect(histories[1].last.text, 'Answer');
    });

    testWidgets('error from adapter shows error message', (tester) async {
      final adapter = AiChatAdapter(
        sendMessage: (_) => Stream<String>.error(Exception('API key invalid')),
      );

      await tester.pumpWidget(wrap(
        AiChatPage(
          issue: makeIssue(),
          allIssues: const [],
          adapter: adapter,
          history: const [],
          onHistoryChanged: (_) {},
          onClose: () {},
        ),
      ));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'Q');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      // In debug mode, the actual error is shown
      expect(
        find.textContaining('API key invalid'),
        findsOneWidget,
      );
    });

    testWidgets('multiple messages render in order', (tester) async {
      await tester.pumpWidget(wrap(
        AiChatPage(
          issue: makeIssue(),
          allIssues: const [],
          adapter: makeAdapter(),
          history: const [
            AiChatMessage(role: AiChatRole.user, text: 'First'),
            AiChatMessage(role: AiChatRole.assistant, text: 'Reply 1'),
            AiChatMessage(role: AiChatRole.user, text: 'Second'),
            AiChatMessage(role: AiChatRole.assistant, text: 'Reply 2'),
          ],
          onHistoryChanged: (_) {},
          onClose: () {},
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('First'), findsOneWidget);
      expect(find.text('Reply 1'), findsOneWidget);
      expect(find.text('Second'), findsOneWidget);
      expect(find.text('Reply 2'), findsOneWidget);
    });

    testWidgets('second send ignored while streaming', (tester) async {
      final controller = StreamController<String>();
      final histories = <List<AiChatMessage>>[];

      await tester.pumpWidget(wrap(
        AiChatPage(
          issue: makeIssue(),
          allIssues: const [],
          adapter: AiChatAdapter(sendMessage: (_) => controller.stream),
          history: const [],
          onHistoryChanged: (msgs) => histories.add(List.of(msgs)),
          onClose: () {},
        ),
      ));
      await tester.pumpAndSettle();

      // Send first message
      await tester.enterText(find.byType(TextField), 'First');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(histories, hasLength(1));

      // Tap send button with second text while streaming
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();

      // History should still have only 1 entry (second send ignored)
      expect(histories, hasLength(1));

      controller.close();
    });

    testWidgets('input bar shows hint text', (tester) async {
      await tester.pumpWidget(wrap(
        AiChatPage(
          issue: makeIssue(),
          allIssues: const [],
          adapter: makeAdapter(),
          history: const [],
          onHistoryChanged: (_) {},
          onClose: () {},
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('Ask about this issue...'), findsOneWidget);
    });
  });

  group('IssueCard onAskAi', () {
    testWidgets('Ask AI link visible when onAskAi is provided', (tester) async {
      await tester.pumpWidget(wrap(
        SingleChildScrollView(
          child: IssueCard(
            issue: makeIssue(stableId: 'heap_near_capacity'),
            initiallyExpanded: true,
            onAskAi: () {},
          ),
        ),
      ));

      expect(find.text('Ask AI about this issue'), findsOneWidget);
    });

    testWidgets('Ask AI link hidden when onAskAi is null', (tester) async {
      await tester.pumpWidget(wrap(
        SingleChildScrollView(
          child: IssueCard(
            issue: makeIssue(stableId: 'heap_near_capacity'),
            initiallyExpanded: true,
          ),
        ),
      ));

      expect(find.text('Ask AI about this issue'), findsNothing);
    });

    testWidgets('tapping Ask AI calls callback', (tester) async {
      var tapped = false;
      await tester.pumpWidget(wrap(
        SingleChildScrollView(
          child: IssueCard(
            issue: makeIssue(stableId: 'heap_near_capacity'),
            initiallyExpanded: true,
            onAskAi: () => tapped = true,
          ),
        ),
      ));

      await tester.tap(find.text('Ask AI about this issue'));
      expect(tapped, isTrue);
    });
  });
}
