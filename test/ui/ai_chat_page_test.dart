import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleuth/src/ai/ai_providers.dart';
import 'package:sleuth/src/models/ai_chat_adapter.dart';
import 'package:sleuth/src/models/performance_issue.dart';
import 'package:sleuth/src/ui/ai_chat_page.dart';
import 'package:sleuth/src/ui/floating_issues_card.dart';
import 'package:sleuth/src/utils/ai_session_context.dart';
import 'package:sleuth/src/controller/sleuth_controller.dart';
import 'package:sleuth/src/ui/issue_card.dart';

import '../helpers/overlay_harness.dart';

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
      await tester.pumpWidget(
        wrap(
          AiChatPage(
            issue: makeIssue(),
            allIssues: const [],
            adapter: makeAdapter(),
            history: const [],
            onHistoryChanged: (_) {},
            onClose: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Ask AI'), findsOneWidget);
      expect(find.byIcon(Icons.auto_awesome), findsOneWidget);
    });

    testWidgets('back button calls onClose', (tester) async {
      var closed = false;
      await tester.pumpWidget(
        wrap(
          AiChatPage(
            issue: makeIssue(),
            allIssues: const [],
            adapter: makeAdapter(),
            history: const [],
            onHistoryChanged: (_) {},
            onClose: () => closed = true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.arrow_back));
      expect(closed, isTrue);
    });

    testWidgets('shows issue context card with title', (tester) async {
      await tester.pumpWidget(
        wrap(
          AiChatPage(
            issue: makeIssue(title: 'Heap Near Capacity'),
            allIssues: const [],
            adapter: makeAdapter(),
            history: const [],
            onHistoryChanged: (_) {},
            onClose: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Heap Near Capacity'), findsOneWidget);
    });

    testWidgets('shows starter questions on initial render', (tester) async {
      await tester.pumpWidget(
        wrap(
          AiChatPage(
            issue: makeIssue(category: IssueCategory.memory),
            allIssues: const [],
            adapter: makeAdapter(),
            history: const [],
            onHistoryChanged: (_) {},
            onClose: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Suggested questions'), findsOneWidget);
      expect(find.text('What is causing high memory usage?'), findsOneWidget);
    });

    testWidgets('tapping starter question sends it as user message', (
      tester,
    ) async {
      final controller = StreamController<String>();
      List<AiChatMessage>? lastHistory;

      await tester.pumpWidget(
        wrap(
          AiChatPage(
            issue: makeIssue(category: IssueCategory.memory),
            allIssues: const [],
            adapter: AiChatAdapter(sendMessage: (_) => controller.stream),
            history: const [],
            onHistoryChanged: (msgs) => lastHistory = msgs,
            onClose: () {},
          ),
        ),
      );
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

      await tester.pumpWidget(
        wrap(
          AiChatPage(
            issue: makeIssue(category: IssueCategory.memory),
            allIssues: const [],
            adapter: AiChatAdapter(sendMessage: (_) => controller.stream),
            history: const [],
            onHistoryChanged: (_) {},
            onClose: () {},
          ),
        ),
      );
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
      await tester.pumpWidget(
        wrap(
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
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Suggested questions'), findsNothing);
      expect(find.text('Prior question'), findsOneWidget);
    });

    testWidgets('user message appears in chat after send', (tester) async {
      final controller = StreamController<String>();

      await tester.pumpWidget(
        wrap(
          AiChatPage(
            issue: makeIssue(),
            allIssues: const [],
            adapter: AiChatAdapter(sendMessage: (_) => controller.stream),
            history: const [],
            onHistoryChanged: (_) {},
            onClose: () {},
          ),
        ),
      );
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

      await tester.pumpWidget(
        wrap(
          AiChatPage(
            issue: makeIssue(),
            allIssues: const [],
            adapter: makeAdapter(),
            history: const [],
            onHistoryChanged: (msgs) => lastHistory = msgs,
            onClose: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '   ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(lastHistory, isNull);
    });

    testWidgets('streaming response renders in AI bubble', (tester) async {
      final controller = StreamController<String>();

      await tester.pumpWidget(
        wrap(
          AiChatPage(
            issue: makeIssue(),
            allIssues: const [],
            adapter: AiChatAdapter(sendMessage: (_) => controller.stream),
            history: const [],
            onHistoryChanged: (_) {},
            onClose: () {},
          ),
        ),
      );
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

    testWidgets('thinking indicator visible before first token', (
      tester,
    ) async {
      final controller = StreamController<String>();

      await tester.pumpWidget(
        wrap(
          AiChatPage(
            issue: makeIssue(),
            allIssues: const [],
            adapter: AiChatAdapter(sendMessage: (_) => controller.stream),
            history: const [],
            onHistoryChanged: (_) {},
            onClose: () {},
          ),
        ),
      );
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
      await tester.pumpWidget(
        wrap(
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
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.copy), findsOneWidget);
    });

    testWidgets('onHistoryChanged called after user sends', (tester) async {
      final controller = StreamController<String>();
      final histories = <List<AiChatMessage>>[];

      await tester.pumpWidget(
        wrap(
          AiChatPage(
            issue: makeIssue(),
            allIssues: const [],
            adapter: AiChatAdapter(sendMessage: (_) => controller.stream),
            history: const [],
            onHistoryChanged: (msgs) => histories.add(List.of(msgs)),
            onClose: () {},
          ),
        ),
      );
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

      await tester.pumpWidget(
        wrap(
          AiChatPage(
            issue: makeIssue(),
            allIssues: const [],
            adapter: AiChatAdapter(sendMessage: (_) => controller.stream),
            history: const [],
            onHistoryChanged: (msgs) => histories.add(List.of(msgs)),
            onClose: () {},
          ),
        ),
      );
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

    testWidgets('a failed reply shows a short reason, not the error', (
      tester,
    ) async {
      final adapter = AiChatAdapter(
        sendMessage: (_) => Stream<String>.error(Exception('API key invalid')),
      );

      await tester.pumpWidget(
        wrap(
          AiChatPage(
            issue: makeIssue(),
            allIssues: const [],
            adapter: adapter,
            history: const [],
            onHistoryChanged: (_) {},
            onClose: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'Q');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(find.text('Reply failed'), findsOneWidget);
      expect(find.textContaining('API key invalid'), findsNothing);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Copy error'), findsOneWidget);
    });

    testWidgets('multiple messages render in order', (tester) async {
      await tester.pumpWidget(
        wrap(
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
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('First'), findsOneWidget);
      expect(find.text('Reply 1'), findsOneWidget);
      expect(find.text('Second'), findsOneWidget);
      expect(find.text('Reply 2'), findsOneWidget);
    });

    testWidgets('a send while a reply is in flight toasts and is not sent', (
      tester,
    ) async {
      final controller = StreamController<String>();
      final histories = <List<AiChatMessage>>[];
      final notes = <String>[];

      await tester.pumpWidget(
        wrap(
          AiChatPage(
            issue: makeIssue(),
            allIssues: const [],
            adapter: AiChatAdapter(sendMessage: (_) => controller.stream),
            history: const [],
            onHistoryChanged: (msgs) => histories.add(List.of(msgs)),
            onClose: () {},
            onNotify: notes.add,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'First');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(histories, hasLength(1));

      // The field stays editable; the send button is now Stop.
      await tester.enterText(find.byType(TextField), 'Second');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      expect(histories, hasLength(1));
      expect(notes, ['Wait for the reply, or stop it']);
      expect(find.byIcon(Icons.send), findsNothing);
      expect(find.bySemanticsLabel('Stop reply'), findsOneWidget);
      // The draft is kept.
      expect(find.widgetWithText(TextField, 'Second'), findsOneWidget);

      await controller.close();
      await tester.pump();
    });

    testWidgets('input bar shows hint text', (tester) async {
      await tester.pumpWidget(
        wrap(
          AiChatPage(
            issue: makeIssue(),
            allIssues: const [],
            adapter: makeAdapter(),
            history: const [],
            onHistoryChanged: (_) {},
            onClose: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Ask about this issue...'), findsOneWidget);
    });

    testWidgets('copy button disabled when no messages', (tester) async {
      await tester.pumpWidget(
        wrap(
          AiChatPage(
            issue: makeIssue(),
            allIssues: const [],
            adapter: makeAdapter(),
            history: const [],
            onHistoryChanged: (_) {},
            onClose: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Button icon should be present but visually disabled (quaternary color).
      expect(find.byIcon(Icons.copy_all_outlined), findsOneWidget);
    });

    testWidgets('copy button enabled after user sends message', (tester) async {
      final controller = StreamController<String>();

      await tester.pumpWidget(
        wrap(
          AiChatPage(
            issue: makeIssue(),
            allIssues: const [],
            adapter: AiChatAdapter(sendMessage: (_) => controller.stream),
            history: const [],
            onHistoryChanged: (_) {},
            onClose: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Send a message
      await tester.enterText(find.byType(TextField), 'Hello');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      // Now the button should be tappable (no crash = enabled).
      await tester.tap(find.byIcon(Icons.copy_all_outlined));
      await tester.pump();

      controller.close();
    });

    testWidgets('tap copy button writes markdown to clipboard', (tester) async {
      String? clipboardText;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall call) async {
          if (call.method == 'Clipboard.setData') {
            clipboardText =
                (call.arguments as Map<String, dynamic>)['text'] as String?;
          }
          return null;
        },
      );

      await tester.pumpWidget(
        wrap(
          AiChatPage(
            issue: makeIssue(
              title: 'Excessive GlobalKeys: 25',
              stableId: 'excessive_global_keys:0',
              confidence: IssueConfidence.possible,
            ),
            allIssues: const [],
            adapter: makeAdapter(),
            history: const [
              AiChatMessage(role: AiChatRole.user, text: 'Why is this bad?'),
              AiChatMessage(
                role: AiChatRole.assistant,
                text: 'GlobalKeys are expensive.',
              ),
            ],
            onHistoryChanged: (_) {},
            onClose: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.copy_all_outlined));
      await tester.pump();

      expect(clipboardText, isNotNull);
      expect(clipboardText!, contains('# Sleuth AI Conversation'));
      expect(clipboardText!, contains('**Issue:** Excessive GlobalKeys: 25'));
      expect(clipboardText!, contains('`excessive_global_keys:0`'));
      expect(clipboardText!, contains('POSSIBLE'));
      expect(clipboardText!, contains('---'));
      expect(clipboardText!, contains('User'));
      expect(clipboardText!, contains('Why is this bad?'));
      expect(clipboardText!, contains('Assistant'));
      expect(clipboardText!, contains('GlobalKeys are expensive.'));

      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    testWidgets('copy escapes markdown-significant characters', (tester) async {
      String? clipboardText;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall call) async {
          if (call.method == 'Clipboard.setData') {
            clipboardText =
                (call.arguments as Map<String, dynamic>)['text'] as String?;
          }
          return null;
        },
      );

      await tester.pumpWidget(
        wrap(
          AiChatPage(
            issue: makeIssue(title: 'Issue *bold* `code` #heading'),
            allIssues: const [],
            adapter: makeAdapter(),
            history: const [
              AiChatMessage(
                role: AiChatRole.user,
                text: 'What about [links] and <html>?',
              ),
            ],
            onHistoryChanged: (_) {},
            onClose: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.copy_all_outlined));
      await tester.pump();

      expect(clipboardText, isNotNull);
      // Title should have escaped markdown chars
      expect(clipboardText!, contains(r'Issue \*bold\* \`code\` \#heading'));
      // Message text should have escaped brackets and angle brackets
      expect(clipboardText!, contains(r'What about \[links\] and \<html\>?'));

      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    testWidgets('copy reports its confirmation through onNotify', (
      tester,
    ) async {
      final notes = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall call) async {
          return null;
        },
      );

      await tester.pumpWidget(
        wrap(
          AiChatPage(
            issue: makeIssue(),
            allIssues: const [],
            adapter: makeAdapter(),
            history: const [AiChatMessage(role: AiChatRole.user, text: 'Q')],
            onHistoryChanged: (_) {},
            onClose: () {},
            onNotify: notes.add,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.copy_all_outlined));
      await tester.pumpAndSettle();

      expect(notes, ['Conversation copied to clipboard']);

      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    testWidgets('handles large history without error', (tester) async {
      String? clipboardText;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall call) async {
          if (call.method == 'Clipboard.setData') {
            clipboardText =
                (call.arguments as Map<String, dynamic>)['text'] as String?;
          }
          return null;
        },
      );

      final largeHistory = List.generate(
        100,
        (i) => AiChatMessage(
          role: i.isEven ? AiChatRole.user : AiChatRole.assistant,
          text: 'Message $i with some content to make it realistic.',
        ),
      );

      await tester.pumpWidget(
        wrap(
          AiChatPage(
            issue: makeIssue(),
            allIssues: const [],
            adapter: makeAdapter(),
            history: largeHistory,
            onHistoryChanged: (_) {},
            onClose: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Tap copy — should not crash.
      await tester.tap(find.byIcon(Icons.copy_all_outlined));
      await tester.pump();

      expect(clipboardText, isNotNull);
      expect(clipboardText!, contains('Message 99'));

      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });
  });

  group('IssueCard onAskAi', () {
    testWidgets('Ask AI link visible when onAskAi is provided', (tester) async {
      await tester.pumpWidget(
        wrap(
          SingleChildScrollView(
            child: IssueCard(
              issue: makeIssue(stableId: 'heap_near_capacity'),
              initiallyExpanded: true,
              onAskAi: () {},
            ),
          ),
        ),
      );

      expect(find.text('Ask AI about this issue'), findsOneWidget);
    });

    testWidgets('Ask AI link hidden when onAskAi is null', (tester) async {
      await tester.pumpWidget(
        wrap(
          SingleChildScrollView(
            child: IssueCard(
              issue: makeIssue(stableId: 'heap_near_capacity'),
              initiallyExpanded: true,
            ),
          ),
        ),
      );

      expect(find.text('Ask AI about this issue'), findsNothing);
    });

    testWidgets('tapping Ask AI calls callback', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        wrap(
          SingleChildScrollView(
            child: IssueCard(
              issue: makeIssue(stableId: 'heap_near_capacity'),
              initiallyExpanded: true,
              onAskAi: () => tapped = true,
            ),
          ),
        ),
      );

      await tester.tap(find.text('Ask AI about this issue'));
      expect(tapped, isTrue);
    });
  });

  group('AiChatPage in the overlay', () {
    testWidgets('the input field has a Material ancestor', (tester) async {
      final controller = await pumpOverlay(
        tester,
        config: SleuthConfig(
          aiChat: AiChatAdapter(sendMessage: (_) => Stream.value('ok')),
          treeScanInterval: const Duration(hours: 1),
        ),
      );
      controller.issuesNotifier.value = [
        makeIssue(stableId: 'rebuild_activity', title: 'Rebuilds'),
      ];
      await openDashboard(tester, controller);
      await tester.tap(find.text('Rebuilds'));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.ensureVisible(find.text('Ask AI about this issue'));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.tap(find.text('Ask AI about this issue'));
      await tester.pump(const Duration(milliseconds: 600));

      expect(find.byType(AiChatPage), findsOneWidget);
      expect(
        find.ancestor(
          of: find.byType(TextField),
          matching: find.byType(Material),
        ),
        findsWidgets,
      );
      await tester.tap(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'Why?');
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('AiChatPage reply states', () {
    Widget page({
      required AiChatAdapter adapter,
      List<AiChatMessage> history = const [],
      ValueChanged<List<AiChatMessage>>? onHistoryChanged,
      ValueChanged<String>? onNotify,
    }) {
      return wrap(
        AiChatPage(
          issue: makeIssue(),
          allIssues: const [],
          adapter: adapter,
          history: history,
          onHistoryChanged: onHistoryChanged ?? (_) {},
          onClose: () {},
          onNotify: onNotify,
        ),
      );
    }

    Future<void> send(WidgetTester tester, String text) async {
      await tester.enterText(find.byType(TextField), text);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
    }

    testWidgets('a failure never enters the history or the next request', (
      tester,
    ) async {
      final requests = <AiChatRequest>[];
      final histories = <List<AiChatMessage>>[];
      var calls = 0;
      final adapter = AiChatAdapter(
        sendMessage: (request) {
          requests.add(request);
          calls++;
          if (calls == 1) {
            return Stream<String>.error(
              const AiProviderException('boom secret', statusCode: 500),
            );
          }
          return Stream.value('Fine');
        },
      );
      await tester.pumpWidget(
        page(adapter: adapter, onHistoryChanged: histories.add),
      );
      await tester.pumpAndSettle();

      await send(tester, 'Q1');
      expect(find.text('Provider error'), findsOneWidget);
      for (final h in histories) {
        expect(h.map((m) => m.text).join(), isNot(contains('boom')));
      }

      // A new question after the failure joins the unanswered one in
      // the request; the history keeps both bubbles.
      await send(tester, 'Q2');
      await tester.pump();
      expect(requests, hasLength(2));
      expect(requests[1].history, hasLength(1));
      expect(requests[1].history.single.role, AiChatRole.user);
      expect(requests[1].history.single.text, 'Q1\n\nQ2');
      expect(histories.last.map((m) => m.role), [
        AiChatRole.user,
        AiChatRole.user,
        AiChatRole.assistant,
      ]);
      expect(histories.last.last.text, 'Fine');
      expect(find.text('Provider error'), findsNothing);
    });

    testWidgets('Retry re-sends the same history without a new user turn', (
      tester,
    ) async {
      final requests = <AiChatRequest>[];
      final histories = <List<AiChatMessage>>[];
      final adapter = AiChatAdapter(
        sendMessage: (request) {
          requests.add(request);
          if (requests.length == 1) {
            return Stream<String>.error(
              const AiProviderException('limit', statusCode: 429),
            );
          }
          return Stream.fromIterable(['Second ', 'try']);
        },
      );
      await tester.pumpWidget(
        page(adapter: adapter, onHistoryChanged: histories.add),
      );
      await tester.pumpAndSettle();

      await send(tester, 'Why?');
      expect(find.text('Rate limited'), findsOneWidget);

      await tester.tap(find.text('Retry'));
      await tester.pump();
      await tester.pump();

      expect(requests, hasLength(2));
      expect(requests[1].history.map((m) => m.text), ['Why?']);
      expect(histories.last.map((m) => m.text), ['Why?', 'Second try']);
      expect(find.text('Rate limited'), findsNothing);
      // Focus is back on the input after a Retry.
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.focusNode!.hasFocus, isTrue);
    });

    testWidgets('Stop keeps the partial reply, marked stopped', (tester) async {
      final controller = StreamController<String>();
      final histories = <List<AiChatMessage>>[];
      await tester.pumpWidget(
        page(
          adapter: AiChatAdapter(sendMessage: (_) => controller.stream),
          onHistoryChanged: histories.add,
        ),
      );
      await tester.pumpAndSettle();

      await send(tester, 'Q');
      controller.add('Partial answer');
      await tester.pump();

      await tester.tap(find.byIcon(Icons.stop));
      await tester.pump();

      expect(controller.hasListener, isFalse);
      expect(histories.last.last.role, AiChatRole.assistant);
      expect(histories.last.last.text, 'Partial answer (stopped)');
      expect(find.text('Partial answer (stopped)'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
      expect(find.byIcon(Icons.send), findsOneWidget);
    });

    testWidgets('Stop before any text leaves a quiet note with Retry', (
      tester,
    ) async {
      final controller = StreamController<String>();
      final histories = <List<AiChatMessage>>[];
      await tester.pumpWidget(
        page(
          adapter: AiChatAdapter(sendMessage: (_) => controller.stream),
          onHistoryChanged: histories.add,
        ),
      );
      await tester.pumpAndSettle();

      await send(tester, 'Q');
      await tester.tap(find.byIcon(Icons.stop));
      await tester.pump();

      expect(histories, hasLength(1));
      expect(find.text('Stopped'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });

    testWidgets('Stop and Retry give a selection click', (tester) async {
      final haptics = <Object?>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            haptics.add(call.arguments);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final controller = StreamController<String>.broadcast();
      await tester.pumpWidget(
        page(adapter: AiChatAdapter(sendMessage: (_) => controller.stream)),
      );
      await tester.pumpAndSettle();

      await send(tester, 'Q');
      await tester.tap(find.byIcon(Icons.stop));
      await tester.pump();
      expect(haptics, ['HapticFeedbackType.selectionClick']);

      await tester.tap(find.text('Retry'));
      await tester.pump();
      expect(haptics, hasLength(2));
      await tester.tap(find.byIcon(Icons.stop));
      await tester.pump();
    });

    testWidgets('disposing mid-reply commits the partial text once', (
      tester,
    ) async {
      final controller = StreamController<String>();
      final histories = <List<AiChatMessage>>[];
      await tester.pumpWidget(
        page(
          adapter: AiChatAdapter(sendMessage: (_) => controller.stream),
          onHistoryChanged: histories.add,
        ),
      );
      await tester.pumpAndSettle();

      await send(tester, 'Q');
      controller.add('Half');
      await tester.pump();

      await tester.pumpWidget(const SizedBox());
      // A late token or close after dispose changes nothing.
      controller.add(' more');
      // Not awaited: a cancelled controller never completes its close.
      unawaited(controller.close());
      await tester.pump();

      final commits = histories.where(
        (h) => h.isNotEmpty && h.last.role == AiChatRole.assistant,
      );
      expect(commits, hasLength(1));
      expect(commits.single.last.text, 'Half (stopped)');
    });

    testWidgets('a history ending with a question offers Retry', (
      tester,
    ) async {
      final requests = <AiChatRequest>[];
      await tester.pumpWidget(
        page(
          adapter: AiChatAdapter(
            sendMessage: (request) {
              requests.add(request);
              return Stream.value('Answer');
            },
          ),
          history: const [
            AiChatMessage(role: AiChatRole.user, text: 'Unanswered'),
          ],
        ),
      );
      await tester.pumpAndSettle();

      // A question carried over from an earlier visit gets the quiet
      // row, not the failure row.
      expect(find.text('Reply did not finish'), findsOneWidget);
      expect(find.text('Copy error'), findsNothing);
      expect(find.byIcon(Icons.error_outline), findsNothing);

      await tester.tap(find.text('Retry'));
      await tester.pump();
      await tester.pump();
      expect(requests.single.history.map((m) => m.text), ['Unanswered']);
      expect(find.text('Answer'), findsOneWidget);
    });

    testWidgets('a new question after an unanswered one is merged', (
      tester,
    ) async {
      final requests = <AiChatRequest>[];
      await tester.pumpWidget(
        page(
          adapter: AiChatAdapter(
            sendMessage: (request) {
              requests.add(request);
              return Stream.value('Answer');
            },
          ),
          history: const [
            AiChatMessage(role: AiChatRole.user, text: 'A'),
            AiChatMessage(role: AiChatRole.assistant, text: 'B'),
            AiChatMessage(role: AiChatRole.user, text: 'C'),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await send(tester, 'D');
      await tester.pump();
      expect(requests.single.history.map((m) => m.role), [
        AiChatRole.user,
        AiChatRole.assistant,
        AiChatRole.user,
      ]);
      expect(requests.single.history.last.text, 'C\n\nD');
      // Both questions keep their own bubble.
      expect(find.text('C'), findsOneWidget);
      expect(find.text('D'), findsOneWidget);
    });

    testWidgets('a merged send keeps both questions in the history', (
      tester,
    ) async {
      final requests = <AiChatRequest>[];
      final histories = <List<AiChatMessage>>[];
      await tester.pumpWidget(
        page(
          adapter: AiChatAdapter(
            sendMessage: (request) {
              requests.add(request);
              if (requests.length == 1) {
                return Stream<String>.error(
                  const AiProviderException('down', statusCode: 503),
                );
              }
              return Stream.value('Answer');
            },
          ),
          history: const [AiChatMessage(role: AiChatRole.user, text: 'First')],
          onHistoryChanged: histories.add,
        ),
      );
      await tester.pumpAndSettle();

      await send(tester, 'Second');
      expect(find.text('Provider error'), findsOneWidget);
      expect(histories.last.map((m) => m.text), ['First', 'Second']);
      expect(requests.single.history.map((m) => m.text), ['First\n\nSecond']);

      // Retry sends the same joined turn and adds no user turn.
      await tester.tap(find.text('Retry'));
      await tester.pump();
      await tester.pump();
      expect(requests, hasLength(2));
      expect(requests[1].history.map((m) => m.role), [AiChatRole.user]);
      expect(requests[1].history.single.text, 'First\n\nSecond');
      expect(histories.last.map((m) => m.text), ['First', 'Second', 'Answer']);
    });

    testWidgets('Copy conversation lists both bubbles of a merged send', (
      tester,
    ) async {
      String? clipboardText;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall call) async {
          if (call.method == 'Clipboard.setData') {
            clipboardText =
                (call.arguments as Map<String, dynamic>)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        page(
          adapter: AiChatAdapter(sendMessage: (_) => Stream.value('Answer')),
          history: const [AiChatMessage(role: AiChatRole.user, text: 'First')],
        ),
      );
      await tester.pumpAndSettle();
      await send(tester, 'Second');
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.copy_all_outlined));
      await tester.pump();
      final text = clipboardText!;
      expect('### \u{1F9D1} User'.allMatches(text), hasLength(2));
      expect(text.indexOf('First'), lessThan(text.indexOf('Second')));
      // Nothing was sent with a session provider: no context section.
      expect(text, isNot(contains('## Context sent')));
    });

    testWidgets('the in-flight notice offers Stop', (tester) async {
      final controller = StreamController<String>();
      final actions = <String>[];
      VoidCallback? stop;
      await tester.pumpWidget(
        wrap(
          AiChatPage(
            issue: makeIssue(),
            allIssues: const [],
            adapter: AiChatAdapter(sendMessage: (_) => controller.stream),
            history: const [],
            onHistoryChanged: (_) {},
            onClose: () {},
            onNotifyAction: (message, label, onAction) {
              actions.add('$message|$label');
              stop = onAction;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await send(tester, 'First');
      await send(tester, 'Second');
      expect(actions, ['Wait for the reply, or stop it|Stop']);

      stop!();
      await tester.pump();
      expect(controller.hasListener, isFalse);
      expect(find.text('Stopped'), findsOneWidget);
      expect(find.byIcon(Icons.send), findsOneWidget);
    });

    testWidgets('a cancel error from the adapter does not escape', (
      tester,
    ) async {
      final controller = StreamController<String>(
        onCancel: () => Future<void>.error(StateError('cancel failed')),
      );
      await tester.pumpWidget(
        page(adapter: AiChatAdapter(sendMessage: (_) => controller.stream)),
      );
      await tester.pumpAndSettle();
      await send(tester, 'Q');
      await tester.tap(find.byIcon(Icons.stop));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('Stopped'), findsOneWidget);
    });

    testWidgets('no first token in 30 s fails the reply', (tester) async {
      final controller = StreamController<String>();
      final histories = <List<AiChatMessage>>[];
      await tester.pumpWidget(
        page(
          adapter: AiChatAdapter(sendMessage: (_) => controller.stream),
          onHistoryChanged: histories.add,
        ),
      );
      await tester.pumpAndSettle();

      await send(tester, 'Q');
      expect(find.text('Still waiting for a reply'), findsNothing);
      await tester.pump(const Duration(seconds: 5));
      expect(find.text('Still waiting for a reply'), findsOneWidget);

      await tester.pump(const Duration(seconds: 25));
      expect(find.text('No reply in 30 s'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(controller.hasListener, isFalse);
      expect(histories.single.map((m) => m.text), ['Q']);
    });

    testWidgets('a 15 s gap between tokens fails the reply', (tester) async {
      final controller = StreamController<String>();
      final histories = <List<AiChatMessage>>[];
      await tester.pumpWidget(
        page(
          adapter: AiChatAdapter(sendMessage: (_) => controller.stream),
          onHistoryChanged: histories.add,
        ),
      );
      await tester.pumpAndSettle();

      await send(tester, 'Q');
      controller.add('Some text');
      await tester.pump();
      await tester.pump(const Duration(seconds: 14));
      expect(find.text('Reply stalled'), findsNothing);
      await tester.pump(const Duration(seconds: 1));

      expect(find.text('Reply stalled'), findsOneWidget);
      // The partial text stays on screen, not in the history.
      expect(find.text('Some text'), findsOneWidget);
      expect(histories.single.map((m) => m.text), ['Q']);
      expect(controller.hasListener, isFalse);
    });

    testWidgets('the streaming live region changes at most every 2 s', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final controller = StreamController<String>();
      await tester.pumpWidget(
        page(adapter: AiChatAdapter(sendMessage: (_) => controller.stream)),
      );
      await tester.pumpAndSettle();

      await send(tester, 'Q');
      controller.add('One. ');
      await tester.pump();
      expect(
        find.bySemanticsLabel('Reply in progress, 1 sentence'),
        findsOneWidget,
      );

      controller.add('Two. ');
      await tester.pump();
      expect(
        find.bySemanticsLabel('Reply in progress, 1 sentence'),
        findsOneWidget,
      );

      await tester.pump(const Duration(seconds: 2));
      expect(
        find.bySemanticsLabel('Reply in progress, 2 sentences'),
        findsOneWidget,
      );

      await controller.close();
      await tester.pump();
      handle.dispose();
    });

    testWidgets('the input is capped at 4000 characters', (tester) async {
      await tester.pumpWidget(page(adapter: makeAdapter()));
      await tester.pumpAndSettle();

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.maxLength, 4000);
      expect(find.text('0 / 4000'), findsNothing);

      await tester.enterText(find.byType(TextField), 'x' * 3300);
      await tester.pump();
      expect(find.text('3300 / 4000'), findsOneWidget);
    });

    testWidgets('the failure row meets the tap target guideline', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        page(
          adapter: AiChatAdapter(
            sendMessage: (_) => Stream<String>.error(Exception('x')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await send(tester, 'Q');

      final retry = tester.getSize(
        find.ancestor(
          of: find.text('Retry'),
          matching: find.byType(GestureDetector),
        ),
      );
      expect(retry.width, greaterThanOrEqualTo(48));
      expect(retry.height, greaterThanOrEqualTo(48));
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      handle.dispose();
    });

    testWidgets('the failure row fits a 220 px card at 2x text', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(220, 800),
              textScaler: TextScaler.linear(2),
            ),
            child: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 220,
                  child: AiChatPage(
                    issue: makeIssue(),
                    allIssues: const [],
                    adapter: AiChatAdapter(
                      sendMessage: (_) => Stream<String>.error(
                        const AiProviderException('limit', statusCode: 429),
                      ),
                    ),
                    history: const [],
                    onHistoryChanged: (_) {},
                    onClose: () {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await send(tester, 'Q');
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('Rate limited'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Copy error'), findsOneWidget);
      // The reason has its own line above the actions.
      final reason = tester.getRect(find.text('Rate limited'));
      final retry = tester.getRect(find.text('Retry'));
      expect(retry.top, greaterThanOrEqualTo(reason.bottom));
    });
  });

  group('AiChatPage session context', () {
    const session = AiSessionContext(
      route: '/home',
      throughputFps: 57.6,
      fpsTarget: 60,
      warningCount: 3,
      hiddenCount: 1,
    );

    testWidgets('the caption shows what the next message carries', (
      tester,
    ) async {
      final requests = <AiChatRequest>[];
      await tester.pumpWidget(
        wrap(
          AiChatPage(
            issue: makeIssue(),
            allIssues: const [],
            adapter: AiChatAdapter(
              sendMessage: (request) {
                requests.add(request);
                return Stream.value('ok');
              },
            ),
            history: const [],
            onHistoryChanged: (_) {},
            onClose: () {},
            sessionContext: () => session,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Context: /home · 58 FPS · 3 issues'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'Q');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(requests.single.systemPrompt, contains('## Session'));
      expect(requests.single.systemPrompt, contains('Hidden by user: 1'));
    });

    testWidgets('no caption without a session provider', (tester) async {
      await tester.pumpWidget(
        wrap(
          AiChatPage(
            issue: makeIssue(),
            allIssues: const [],
            adapter: makeAdapter(),
            history: const [],
            onHistoryChanged: (_) {},
            onClose: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Context:'), findsNothing);
    });

    testWidgets('Copy conversation ends with the context sent', (tester) async {
      String? clipboardText;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall call) async {
          if (call.method == 'Clipboard.setData') {
            clipboardText =
                (call.arguments as Map<String, dynamic>)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        wrap(
          AiChatPage(
            issue: makeIssue(),
            allIssues: const [],
            adapter: makeAdapter(),
            history: const [],
            onHistoryChanged: (_) {},
            onClose: () {},
            sessionContext: () => session,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Q');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.copy_all_outlined));
      await tester.pump();

      final text = clipboardText!;
      final section = text.indexOf('## Context sent');
      expect(section, greaterThan(text.indexOf('Hello world')));
      expect(text, contains('- Current route: /home'));
      expect(text, contains('- Hidden by user: 1'));
    });
  });

  group('AiChatPage session context in the overlay', () {
    testWidgets('the prompt counts hidden issues without naming them', (
      tester,
    ) async {
      final requests = <AiChatRequest>[];
      final controller = await pumpOverlay(
        tester,
        config: SleuthConfig(
          aiChat: AiChatAdapter(
            sendMessage: (request) {
              requests.add(request);
              return Stream.value('ok');
            },
          ),
          treeScanInterval: const Duration(hours: 1),
        ),
      );
      controller.issuesNotifier.value = [
        makeIssue(stableId: 'rebuild_activity', title: 'Rebuilds'),
        makeIssue(stableId: 'secret_issue', title: 'Hidden secret title'),
        makeIssue(stableId: 'gc_pressure', title: 'Other visible'),
      ];
      controller.overlayUiState.hide('secret_issue');
      // A key for an issue no longer reported is not counted.
      controller.overlayUiState.hide('gone_issue');
      await openDashboard(tester, controller);
      await tester.tap(find.text('Rebuilds'));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.ensureVisible(find.text('Ask AI about this issue'));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.tap(find.text('Ask AI about this issue'));
      await tester.pump(const Duration(milliseconds: 600));

      expect(find.textContaining('Context: '), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Why?');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      final prompt = requests.single.systemPrompt;
      expect(prompt, contains('Hidden by user: 1'));
      expect(prompt, contains('Active issues: 3 (0 critical, 3 warning'));
      expect(prompt, contains('- Other visible'));
      // Nowhere in the prompt, including the other-issues list.
      expect(prompt, isNot(contains('Hidden secret title')));
    });
  });

  group('aiFailureReason', () {
    test('maps status codes and offline errors to short reasons', () {
      expect(
        aiFailureReason(const AiProviderException('x', statusCode: 401)),
        'API key rejected',
      );
      expect(
        aiFailureReason(const AiProviderException('x', statusCode: 403)),
        'API key rejected',
      );
      expect(
        aiFailureReason(const AiProviderException('x', statusCode: 429)),
        'Rate limited',
      );
      expect(
        aiFailureReason(const AiProviderException('x', statusCode: 529)),
        'Provider error',
      );
      expect(
        aiFailureReason(const HttpException('AI provider returned 503: busy')),
        'Provider error',
      );
      expect(
        aiFailureReason(const SocketException('Connection refused')),
        'Offline',
      );
      expect(aiFailureReason(Exception('weird')), 'Reply failed');
      expect(
        aiFailureReason(const AiProviderException('bad', statusCode: 400)),
        'Reply failed',
      );
    });
  });

  group('AiChatPage in the overlay, interrupted', () {
    Future<SleuthController> openChat(
      WidgetTester tester,
      StreamController<String> stream,
    ) async {
      final controller = await pumpOverlay(
        tester,
        config: SleuthConfig(
          aiChat: AiChatAdapter(sendMessage: (_) => stream.stream),
          treeScanInterval: const Duration(hours: 1),
        ),
      );
      controller.issuesNotifier.value = [
        makeIssue(stableId: 'rebuild_activity', title: 'Rebuilds'),
      ];
      await openDashboard(tester, controller);
      await tester.tap(find.text('Rebuilds'));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.ensureVisible(find.text('Ask AI about this issue'));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.tap(find.text('Ask AI about this issue'));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(AiChatPage), findsOneWidget);
      return controller;
    }

    testWidgets('closing mid-reply keeps the partial text for reopening', (
      tester,
    ) async {
      final stream = StreamController<String>();
      await openChat(tester, stream);

      await tester.enterText(find.byType(TextField), 'Why?');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      stream.add('Because');
      await tester.pump();

      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(AiChatPage), findsNothing);
      expect(tester.takeException(), isNull);
      expect(stream.hasListener, isFalse);

      await tester.ensureVisible(find.text('Ask AI about this issue'));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.tap(find.text('Ask AI about this issue'));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Because (stopped)'), findsOneWidget);
      expect(find.text('Reply did not finish'), findsNothing);
    });

    testWidgets('a controller swap closes the chat', (tester) async {
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SleuthController make() {
        final c = SleuthController(
          config: SleuthConfig(
            aiChat: AiChatAdapter(sendMessage: (_) => Stream.value('ok')),
            treeScanInterval: const Duration(hours: 1),
          ),
        )..initializeDetectorsForTest();
        addTearDown(c.dispose);
        c.issuesNotifier.value = [
          makeIssue(stableId: 'rebuild_activity', title: 'Rebuilds'),
        ];
        return c;
      }

      Widget host(SleuthController c) => MaterialApp(
        home: Scaffold(
          body: FloatingIssuesCard(controller: c, onClose: () {}),
        ),
      );
      final first = make();
      await tester.pumpWidget(host(first));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rebuilds'));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.ensureVisible(find.text('Ask AI about this issue'));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.tap(find.text('Ask AI about this issue'));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(AiChatPage), findsOneWidget);

      await tester.pumpWidget(host(make()));
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.takeException(), isNull);
      expect(find.byType(AiChatPage), findsNothing);
    });

    testWidgets('a pruned issue closes the chat mid-reply without error', (
      tester,
    ) async {
      final stream = StreamController<String>();
      final controller = await openChat(tester, stream);

      await tester.enterText(find.byType(TextField), 'Why?');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      stream.add('Because');
      await tester.pump();

      controller.issuesNotifier.value = const [];
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(AiChatPage), findsNothing);
      expect(tester.takeException(), isNull);
      expect(stream.hasListener, isFalse);

      // The issue comes back: the late write was dropped with it.
      controller.issuesNotifier.value = [
        makeIssue(stableId: 'rebuild_activity', title: 'Rebuilds'),
      ];
      await tester.pump(const Duration(milliseconds: 600));
      await tester.tap(find.text('Rebuilds'));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.ensureVisible(find.text('Ask AI about this issue'));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.tap(find.text('Ask AI about this issue'));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Because (stopped)'), findsNothing);
    });
  });
}
